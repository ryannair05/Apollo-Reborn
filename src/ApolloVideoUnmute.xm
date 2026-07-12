#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

// =============================================================================
// MARK: - Overview
// =============================================================================
//
// "Unmute Videos in Comments" — controls header video mute behavior.
//   Default (0):                    Native behavior (always muted).
//   Remember from Full Screen (1):  After fullscreen dismiss, match the
//                                   mute state the user had in fullscreen.
//   Always (2):                     Auto-unmute on comments entry +
//                                   always re-unmute after fullscreen.
//
// Architecture:
//   1. Hook RichMediaHeaderCellNode.cellNodeVisibilityEvent: — fires when the
//      comments header video cell becomes visible in the scroll view. This is
//      event-driven (no polling/delays) and the player is guaranteed to exist.
//   2. Get the AVPlayer via [[videoNode playerLayer] player] — the native code
//      (sub_10058b800) uses this exact path. For shareable v.redd.it videos,
//      the player lives on the AVPlayerLayer, NOT on [videoNode player].
//   3. Hook AVAudioSession to block Apollo's reversion to Ambient category.
//   4. Hook AVPlayer.setMuted: to detect user manual mute.
//
// =============================================================================

// =============================================================================
// MARK: - Picture-in-Picture coordination (ApolloPictureInPicture.xm)
// =============================================================================
//
// The PiP module owns the floating-player feature; this module consults it at
// the points where the two features' policies meet (see docs/pip-design.md):
//   - ApolloPiP_HandleCommentsVisibilityEvent: called BEFORE %orig in the
//     comments visibility hooks. Returns YES when PiP owns that cell's player,
//     in which case %orig must be skipped — Apollo's midpoint-test pause/play
//     runs synchronously inside %orig (sub_1002060bc) and must not touch a
//     PiP-owned player. The ASCellNode base implementation is a single ret,
//     so skipping loses nothing else.
//   - ApolloPiP_IsOwnedPlayer: exempts the PiP player from the post-pop
//     "prevent invisible background audio" kill below.
//   - ApolloPiP_ShouldBlockAudioSessionDowngrade: extends the AVAudioSession
//     blocking predicates while PiP plays audibly.
//   - ApolloPiP_ShouldBlockMuteOfPlayer: extends the AVPlayer.setMuted: block
//     to the inline-armed native-PiP player during background handoff.
//   - ApolloPiP_YieldAudioToPlayer: mutes an audible PiP card when a tweak
//     unmute path makes a different video audible (audio arbitration).
//   - ApolloPiP_NoteInlineVideoAudible: lets the inline native-PiP controller
//     arm on unmutes, which produce no scroll/visibility event.
// Both files are Logos/ObjC++, so these declarations mangle identically.
extern BOOL ApolloPiP_HandleCommentsVisibilityEvent(id cellNode, id richMediaNode,
                                                    unsigned long long event);
extern BOOL ApolloPiP_IsOwnedPlayer(AVPlayer *player);
extern BOOL ApolloPiP_ShouldBlockAudioSessionDowngrade(void);
extern BOOL ApolloPiP_ShouldBlockMuteOfPlayer(AVPlayer *player);
extern void ApolloPiP_YieldAudioToPlayer(AVPlayer *newAudiblePlayer);
extern void ApolloPiP_NoteInlineVideoAudible(id videoNode, AVPlayer *player);
extern void ApolloPiP_NoteInlinePlayerMuted(AVPlayer *player);
// YES while a fullscreen→PiP button dismissal is in flight: the PiP side owns
// the post-dismissal mute/session state, so the "Remember/Always from Full
// Screen" re-unmute below must stand down for that one dismissal.
extern BOOL ApolloPiP_WillHandleFullscreenDismiss(void);

// =============================================================================
// MARK: - State Variables
// =============================================================================

// Per-cell flag: prevents re-unmuting on subsequent visibility events or when
// returning from MediaViewerController. Set on the RichMediaHeaderCellNode
// instance via objc_setAssociatedObject.
static const void *kAutoUnmuteAppliedKey = &kAutoUnmuteAppliedKey;

// The AVPlayer we auto-unmuted. Used by AVAudioSession hooks to block
// reversion to Ambient. __weak so it auto-nils when player deallocates
// (e.g. when leaving the CommentsViewController).
static __weak AVPlayer *sAutoUnmutedPlayer = nil;

// Guard: YES only during our programmatic unmute. Lets the AVPlayer.setMuted:
// hook distinguish our unmute from user tapping the mute button.
static BOOL sIsAutoUnmuting = NO;

// Flag: YES when CommentsVC is being popped (back navigation via swipe or
// back button). Prevents the cellNodeVisibilityEvent event=2 handler from
// clearing sAutoUnmutedPlayer during the back transition animation.
// Without this, the mute dance (triggered by TouchHintVideoNode.didExitVisibleState
// → sub_10058cb30) would re-mute the player because our AVPlayer/AVAudioSession
// hooks only block muting when sAutoUnmutedPlayer is set.
static BOOL sIsNavigatingBack = NO;

// Saved references from the comments header video cell. Used for re-unmute
// after returning from fullscreen MediaViewer. Set in cellNodeVisibilityEvent:
// which fires before the user can open fullscreen, so always available.
static __weak id sCommentsRichMediaNode = nil;
static __weak id sCommentsVideoNode = nil;

// Tracks which CommentsVC instance owns the saved refs above. When navigating
// CommentsVC #1 → CommentsVC #2 (via tapping a link), CommentsVC #2's
// cellNodeVisibilityEvent saves refs BEFORE CommentsVC #1's viewDidDisappear
// fires. Without this guard, CommentsVC #1's viewDidDisappear would clear
// refs that belong to CommentsVC #2, breaking re-unmute after fullscreen.
static __weak id sCommentsVCOwner = nil;

// =============================================================================
// MARK: - Helpers
// =============================================================================

static AVPlayer *GetPlayerFromVideoNode(id videoNode);
static void SyncMuteButtonIcon(id richMediaNode, BOOL isMuted);

// Safely read an ObjC object ivar by name. class_getInstanceVariable walks
// the superclass chain, so this works for inherited ivars too.
static id GetIvarObject(id obj, const char *ivarName) {
    if (!obj) return nil;
    Ivar ivar = class_getInstanceVariable([obj class], ivarName);
    if (!ivar) {
        ApolloLog(@"[VideoUnmute] GetIvarObject: ivar '%s' not found on %@", ivarName, [obj class]);
        return nil;
    }
    return object_getIvar(obj, ivar);
}

static id GetIvarObjectQuiet(id obj, const char *ivarName) {
    if (!obj) return nil;
    Ivar ivar = class_getInstanceVariable([obj class], ivarName);
    return ivar ? object_getIvar(obj, ivar) : nil;
}

// Read a Swift Bool ivar (1 byte) from an object. Returns NO if ivar not found.
static BOOL GetIvarBool(id obj, const char *ivarName) {
    if (!obj) return NO;
    Ivar ivar = class_getInstanceVariable([obj class], ivarName);
    if (!ivar) return NO;
    ptrdiff_t offset = ivar_getOffset(ivar);
    return *(BOOL *)((uint8_t *)(__bridge void *)obj + offset);
}

static id GetVideoNodeFromRichMediaNode(id richMediaNode) {
    return richMediaNode ? GetIvarObjectQuiet(richMediaNode, "videoNode") : nil;
}

static id GetCrosspostRichMediaNodeFromOwner(id owner) {
    id crosspostNode = GetIvarObjectQuiet(owner, "crosspostNode");
    return crosspostNode ? GetIvarObjectQuiet(crosspostNode, "richMediaNode") : nil;
}

static BOOL ObjectsMatch(id lhs, id rhs) {
    return lhs && rhs && (lhs == rhs || [lhs isEqual:rhs]);
}

static UITableView *GetTableViewFromViewController(UIViewController *viewController) {
    UIView *rootView = [viewController view];
    if (!rootView) return nil;

    // PostsSearchResultsViewController is an ASDKViewController whose node IS
    // the table node, so its root view is the ASTableView itself (confirmed by
    // on-device diagnostics). PostsViewController et al. instead host the
    // ASTableView as a direct subview of a plain root view.
    if ([rootView isKindOfClass:[UITableView class]]) {
        return (UITableView *)rootView;
    }

    for (UIView *subview in [rootView subviews]) {
        if ([subview isKindOfClass:[UITableView class]]) {
            return (UITableView *)subview;
        }
    }

    return nil;
}

// Enumerate the rich media nodes (own + crosspost) of every visible cell.
// Shared by the mute-button sync, capture, and reclaim passes below.
static void EnumerateVisibleRichMediaNodes(UITableView *tableView, void (^block)(id richMediaNode)) {
    for (UITableViewCell *cell in [tableView visibleCells]) {
        SEL nodeSel = NSSelectorFromString(@"node");
        if (![cell respondsToSelector:nodeSel]) continue;

        id cellNode = ((id (*)(id, SEL))objc_msgSend)(cell, nodeSel);
        if (!cellNode) continue;

        id richMediaNode = GetIvarObjectQuiet(cellNode, "richMediaNode");
        if (richMediaNode) block(richMediaNode);

        id crosspostRichMediaNode = GetCrosspostRichMediaNodeFromOwner(cellNode);
        if (crosspostRichMediaNode) block(crosspostRichMediaNode);
    }
}

// Single home for the version-fragile mangled Swift class name (previously
// resolved independently at four call sites).
static Class MediaPageViewControllerClass(void) {
    static Class cls = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = objc_getClass("_TtC6Apollo23MediaPageViewController");
    });
    return cls;
}

static BOOL IsCommentsOwnerShowingSameLinkAsMediaPage(id mediaPageVC) {
    if (!mediaPageVC || !sCommentsVCOwner) return NO;

    id mediaPageLink = GetIvarObjectQuiet(mediaPageVC, "link");
    id commentsLink = GetIvarObjectQuiet(sCommentsVCOwner, "link");
    return ObjectsMatch(mediaPageLink, commentsLink);
}

// Saved nav controller reference for the 200ms dispatch_after in
// viewDidDisappear. Must be captured in viewWillDisappear (still non-nil
// during pop) — by viewDidDisappear the CommentsVC is already removed
// from the nav stack and self.navigationController returns nil.
static __weak UINavigationController *sSavedNavControllerForPop = nil;

static BOOL RichMediaNodeContainsPlayer(id richMediaNode, AVPlayer *targetPlayer) {
    if (!richMediaNode || !targetPlayer) return NO;

    id videoNode = GetVideoNodeFromRichMediaNode(richMediaNode);
    if (!videoNode) return NO;

    AVPlayer *player = GetPlayerFromVideoNode(videoNode);
    return player && player == targetPlayer;
}

// Check if a specific AVPlayer is on any visible feed cell's playerLayer.
// Used after back navigation to determine if the player is visible on the
// feed (non-compact: feed has inline video cells) or orphaned (compact:
// no inline video on feed). Walks the feed VC's table view visible cells.
static BOOL IsPlayerOnVisibleFeedCell(UIViewController *feedVC, AVPlayer *targetPlayer) {
    if (!feedVC || !targetPlayer) return NO;

    UITableView *tableView = GetTableViewFromViewController(feedVC);
    if (!tableView) return NO;

    for (UITableViewCell *cell in [tableView visibleCells]) {
        SEL nodeSel = NSSelectorFromString(@"node");
        if (![cell respondsToSelector:nodeSel]) continue;

        id cellNode = ((id (*)(id, SEL))objc_msgSend)(cell, nodeSel);
        if (!cellNode) continue;

        if (RichMediaNodeContainsPlayer(GetIvarObjectQuiet(cellNode, "richMediaNode"), targetPlayer)) {
            return YES;
        }
        if (RichMediaNodeContainsPlayer(GetCrosspostRichMediaNodeFromOwner(cellNode), targetPlayer)) {
            return YES;
        }
    }

    return NO;
}

// YES when `layer`'s superlayer chain reaches `ancestor` — i.e. the layer is
// visibly attached inside that layer tree.
static BOOL LayerIsInLayerTreeOf(CALayer *layer, CALayer *ancestor) {
    if (!layer || !ancestor) return NO;
    for (CALayer *walk = [layer superlayer]; walk; walk = [walk superlayer]) {
        if (walk == ancestor) return YES;
    }
    return NO;
}

// Move a (shared) AVPlayerLayer into a videoNode's backing layer, sized to it
// and unhidden — the recovery step for a layer stranded by a missing reclaim.
static void ReparentPlayerLayerIntoVideoNodeLayer(CALayer *pLayer, CALayer *vnLayer) {
    [pLayer removeFromSuperlayer];
    [vnLayer addSublayer:pLayer];
    [pLayer setFrame:[vnLayer bounds]];
    [pLayer setHidden:NO];
}

// Recursively search a view hierarchy for a subview of a given class.
// Used to find PlayerLayerContainerView in the transition container after
// animateTransition: (before the ivar on MediaViewerController is set).
static UIView *FindSubviewOfClass(UIView *root, Class cls) {
    if (!root || !cls) return nil;
    for (UIView *subview in [root subviews]) {
        if ([subview isKindOfClass:cls]) return subview;
        UIView *found = FindSubviewOfClass(subview, cls);
        if (found) return found;
    }
    return nil;
}

// Get the AVPlayer from an ASVideoNode. Handles both shareable (playerLayer)
// and non-shareable (direct player property) paths.
//
// For shareable v.redd.it videos: player is on [[videoNode playerLayer] player]
//   - The AVPlayerLayer is shared from the feed cell; the ASVideoNode's _player
//     ivar is nil. The native button tap handler (sub_10058b800) uses this path.
//
// For non-shareable GIFs/Streamable/etc: player is on [videoNode player]
//   - A new AVPlayer is created via prepareToPlayAsset:withKeys: → setPlayer:.
// The videoNode's AVPlayerLayer (nil when playback isn't running through the
// shared-layer path). Shared by GetPlayerFromVideoNode and the search-results
// capture/reclaim passes, which need the LAYER itself (no [videoNode player]
// fallback — a fallback player has no layer to re-parent).
static AVPlayerLayer *GetPlayerLayerFromVideoNode(id videoNode) {
    if (!videoNode) return nil;
    SEL playerLayerSel = NSSelectorFromString(@"playerLayer");
    if (![videoNode respondsToSelector:playerLayerSel]) return nil;
    CALayer *layer = ((CALayer *(*)(id, SEL))objc_msgSend)(videoNode, playerLayerSel);
    return [layer isKindOfClass:[AVPlayerLayer class]] ? (AVPlayerLayer *)layer : nil;
}

static AVPlayer *GetPlayerFromVideoNode(id videoNode) {
    if (!videoNode) return nil;

    // Primary path: shareable videos — player is on the AVPlayerLayer.
    // This mirrors the native code: [r21 playerLayer] → [playerLayer player]
    AVPlayer *player = [GetPlayerLayerFromVideoNode(videoNode) player];
    if (player) return player;

    // Fallback: non-shareable videos — player is directly on videoNode
    SEL playerSel = NSSelectorFromString(@"player");
    if ([videoNode respondsToSelector:playerSel]) {
        player = ((id (*)(id, SEL))objc_msgSend)(videoNode, playerSel);
        if (player) return player;
    }

    return nil;
}

// Get the AVPlayer from a MediaPageViewController's currently-displayed child
// MediaViewerController. Returns nil if the child is showing an image (no player)
// or if the child VC isn't a MediaViewerController. Used to restrict our
// MediaPageVC hooks to video-only content.
static AVPlayer *GetPlayerFromMediaPageVC(id mediaPageVC) {
    static Class sMediaViewerClass = nil;
    if (!sMediaViewerClass) {
        sMediaViewerClass = objc_getClass("_TtC6Apollo21MediaViewerController");
    }
    if (!sMediaViewerClass) {
        ApolloLog(@"[VideoUnmute] GetPlayerFromMediaPageVC: MediaViewerController class not found");
        return nil;
    }

    NSArray *vcs = ((NSArray *(*)(id, SEL))objc_msgSend)(mediaPageVC, @selector(viewControllers));
    id mediaVC = [vcs firstObject];
    if (!mediaVC || ![mediaVC isKindOfClass:sMediaViewerClass]) return nil;

    // Direct player ivar (non-shareable videos)
    AVPlayer *player = GetIvarObject(mediaVC, "player");
    if (player) return player;

    // Shareable videos: player on playerLayerContainerView.playerLayer
    id container = GetIvarObject(mediaVC, "playerLayerContainerView");
    if (container) {
        id playerLayer = GetIvarObject(container, "playerLayer");
        if ([playerLayer isKindOfClass:[AVPlayerLayer class]]) {
            player = [(AVPlayerLayer *)playerLayer player];
            if (player) return player;
        }
    }

    return nil;
}

// Update the MuteUnmuteVideoButtonNode's visual state to match actual mute state.
// Sets the `isMuted` ivar (Swift Bool) and updates the `icon` ASImageNode's image.
//
// Icon names decoded from the binary (sub_10058b800 assembly):
//   Muted:   "small-mute"   (0xea prefix, 10 chars)
//   Unmuted: "small-unmute" (0xec prefix, 12 chars)
static void SyncMuteButtonIcon(id richMediaNode, BOOL isMuted) {
    id muteButtonNode = GetIvarObject(richMediaNode, "muteUnmuteButtonNode");
    if (!muteButtonNode) return;

    // Skip if button state already matches — avoids redundant work during scroll
    BOOL currentIsMuted = GetIvarBool(muteButtonNode, "isMuted");
    if (currentIsMuted == isMuted) return;

    ApolloLog(@"[VideoUnmute] SyncMuteButtonIcon: %@ → %@",
              currentIsMuted ? @"muted" : @"unmuted",
              isMuted ? @"muted" : @"unmuted");

    // Write the isMuted ivar (Swift Bool = 1 byte at ivar offset)
    Ivar isMutedIvar = class_getInstanceVariable([muteButtonNode class], "isMuted");
    if (isMutedIvar) {
        ptrdiff_t offset = ivar_getOffset(isMutedIvar);
        *(BOOL *)((uint8_t *)(__bridge void *)muteButtonNode + offset) = isMuted;
    }

    // Update the icon ASImageNode's image to match
    id iconNode = GetIvarObject(muteButtonNode, "icon");
    if (iconNode && [iconNode respondsToSelector:@selector(setImage:)]) {
        NSString *imageName = isMuted ? @"small-mute" : @"small-unmute";
        UIImage *image = [UIImage imageNamed:imageName];
        if (image) {
            ((void (*)(id, SEL, id))objc_msgSend)(iconNode, @selector(setImage:), image);
        }
    }
}

static void SyncRichMediaNodeMuteButton(id richMediaNode) {
    id videoNode = GetVideoNodeFromRichMediaNode(richMediaNode);
    if (!videoNode) return;

    AVPlayer *player = GetPlayerFromVideoNode(videoNode);
    if (!player) return;

    SyncMuteButtonIcon(richMediaNode, [player isMuted]);
}

static void SyncVisibleCellMuteButtons(id cellNode) {
    if (!cellNode) return;

    SyncRichMediaNodeMuteButton(GetIvarObjectQuiet(cellNode, "richMediaNode"));
    SyncRichMediaNodeMuteButton(GetCrosspostRichMediaNodeFromOwner(cellNode));
}

static void SyncVisibleFeedMuteButtons(UIViewController *feedVC) {
    UITableView *tableView = GetTableViewFromViewController(feedVC);
    if (!tableView) {
        ApolloLog(@"[VideoUnmute] SyncVisibleFeedMuteButtons: no tableView found on %@", [feedVC class]);
        return;
    }

    for (UITableViewCell *cell in [tableView visibleCells]) {
        SEL nodeSel = NSSelectorFromString(@"node");
        if (![cell respondsToSelector:nodeSel]) continue;

        id cellNode = ((id (*)(id, SEL))objc_msgSend)(cell, nodeSel);
        if (!cellNode) continue;

        SyncVisibleCellMuteButtons(cellNode);
    }
}

// Core unmute logic. Replicates the native unmute flow from sub_100341894
// (PostCellActionTaker.muteUnmuteTapped(player:)) without depending on the
// weak actionDelegate which may be nil in the comments header context.
//
// Steps in strict order (matching the native flow):
//   1. Set AVAudioSession to Playback (MUST be before unmuting — Apollo
//      defaults to Ambient which silences AVPlayer audio)
//   2. Unmute the AVPlayer directly (for shareable videos, ASVideoNode's
//      _player ivar is nil, so [videoNode setMuted:NO] alone won't work)
//   3. Also update ASVideoNode's internal _muted flag for consistency
//   4. Track the player for AVAudioSession hook scoping
//   5. Sync the mute button icon
static void UnmuteRichMediaNode(id richMediaNode, id videoNode) {
    AVPlayer *player = GetPlayerFromVideoNode(videoNode);
    if (!player) {
        ApolloLog(@"[VideoUnmute] UnmuteRichMediaNode: no player found, aborting");
        return;
    }

    BOOL alreadyUnmuted = ![player isMuted];

    // This video is about to play audibly — if a PiP card is playing a
    // DIFFERENT video with sound, mute it first (the native activeAudioPlayer
    // arbitration only covers Apollo's own unmute path, not ours).
    ApolloPiP_YieldAudioToPlayer(player);

    // Even when the player is already unmuted (e.g. re-entry from feed where
    // audio was playing), we must establish protection (sAutoUnmutedPlayer +
    // Playback session). Without this, the mute dance from the feed cell
    // exiting visibility would kill audio ~350-500ms into the push animation.
    // Steps 2-3 (setMuted:NO) are skipped when redundant to avoid triggering
    // ASVideoNode internals (KVO, layout) unnecessarily.

    ApolloLog(@"[VideoUnmute] UnmuteRichMediaNode: %@",
              alreadyUnmuted ? @"player already unmuted, establishing protection"
                             : @"starting unmute sequence...");

    // Step 1: AVAudioSession → Playback (always — session may be Ambient)
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    [session setCategory:AVAudioSessionCategoryPlayback
                    mode:AVAudioSessionModeDefault
                 options:0
                   error:&error];
    if (error) ApolloLog(@"[VideoUnmute] setCategory:Playback error: %@", error);
    error = nil;
    [session setActive:YES withOptions:0 error:&error];
    if (error) ApolloLog(@"[VideoUnmute] setActive:YES error: %@", error);

    if (!alreadyUnmuted) {
        // Step 2: Unmute the AVPlayer directly. For shareable videos, the
        // ASVideoNode's _player ivar is nil — only the playerLayer has the player.
        // We must unmute the player object directly.
        sIsAutoUnmuting = YES;
        [player setMuted:NO];

        // Step 3: Also update ASVideoNode's internal _muted ivar for consistency.
        // [videoNode setMuted:NO] sets _muted=NO and also [_player setMuted:NO]
        // if _player is non-nil. For shareable videos, _player is nil so only
        // _muted gets updated — but that's fine, we already unmuted the real
        // player above.
        SEL setMutedSel = NSSelectorFromString(@"setMuted:");
        if ([videoNode respondsToSelector:setMutedSel]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(videoNode, setMutedSel, NO);
        }
        sIsAutoUnmuting = NO;
    }

    // Step 4: Track this player so AVAudioSession hooks block Ambient reversion
    // (always — the core of the re-entry fix)
    sAutoUnmutedPlayer = player;

    // Step 5: Sync the mute button icon to "unmuted" state (always)
    SyncMuteButtonIcon(richMediaNode, NO);

    // Now audible — let the inline native-PiP controller arm if enabled
    // (no scroll event fires for a programmatic unmute).
    ApolloPiP_NoteInlineVideoAudible(videoNode, player);

    ApolloLog(@"[VideoUnmute] Auto-unmute complete for player %p", player);
}

static void ReUnmuteAfterFullscreenWhenReady(id richMediaNode, id videoNode, NSUInteger attemptsRemaining) {
    id rmNode = richMediaNode;
    id vNode = videoNode;
    if (!rmNode || !vNode) {
        ApolloLog(@"[VideoUnmute] Re-unmute after fullscreen: nodes deallocated, aborting");
        return;
    }

    AVPlayer *player = GetPlayerFromVideoNode(vNode);
    if (!player) {
        if (attemptsRemaining > 0) {
            ApolloLog(@"[VideoUnmute] Re-unmute after fullscreen: player not ready, retrying (%lu left)",
                      (unsigned long)attemptsRemaining);
            __weak id weakRichMediaNode = rmNode;
            __weak id weakVideoNode = vNode;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                ReUnmuteAfterFullscreenWhenReady(weakRichMediaNode, weakVideoNode, attemptsRemaining - 1);
            });
        } else {
            ApolloLog(@"[VideoUnmute] Re-unmute after fullscreen: no player found, aborting");
        }
        return;
    }

    ApolloLog(@"[VideoUnmute] Re-unmuting after fullscreen dismiss");
    UnmuteRichMediaNode(rmNode, vNode);
}

static void HandleCommentsRichMediaVisibilityEvent(id visibilityOwner,
                                                   id richMediaNode,
                                                   unsigned long long event,
                                                   NSString *contextLabel) {
    if (!visibilityOwner || !richMediaNode) return;

    // ASCellNodeVisibilityEventInvisible (2): cell scrolled out of view.
    // Clear auto-unmute protection AND saved refs — the video is no longer
    // visible, so MediaPageVC dismiss should not re-unmute it.
    if (event == 2) {
        if (sIsNavigatingBack) {
            ApolloLog(@"[VideoUnmute] %@ cell invisible during back navigation — keeping protection", contextLabel);
            return;
        }
        ApolloLog(@"[VideoUnmute] %@ cell invisible — clearing protection and refs", contextLabel);

        sAutoUnmutedPlayer = nil;  // Clear first so our setMuted: hook doesn't block

        id videoNode = GetVideoNodeFromRichMediaNode(richMediaNode);
        if (videoNode) {
            SEL setMutedSel = NSSelectorFromString(@"setMuted:");
            if ([videoNode respondsToSelector:setMutedSel]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(videoNode, setMutedSel, YES);
            }

            AVPlayer *player = GetPlayerFromVideoNode(videoNode);
            if (player) [player setMuted:YES];
        }

        sCommentsRichMediaNode = nil;
        sCommentsVideoNode = nil;
        return;
    }

    BOOL unmuteApplied = objc_getAssociatedObject(visibilityOwner, kAutoUnmuteAppliedKey) != nil;
    id videoNode = GetVideoNodeFromRichMediaNode(richMediaNode);
    if (!videoNode) return;

    if (sUnmuteCommentsVideos >= 1) {
        sCommentsRichMediaNode = richMediaNode;
        sCommentsVideoNode = videoNode;
    }

    AVPlayer *player = GetPlayerFromVideoNode(videoNode);
    if (!player) {
        ApolloLog(@"[VideoUnmute] %@ player not ready (event=%llu), scheduling retry",
                  contextLabel, event);

        __weak id weakOwner = visibilityOwner;
        __weak id weakRichMediaNode = richMediaNode;
        __weak id weakVideoNode = videoNode;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            id strongOwner = weakOwner;
            id rmNode = weakRichMediaNode;
            id vNode = weakVideoNode;
            if (!strongOwner || !rmNode || !vNode) return;

            AVPlayer *retryPlayer = GetPlayerFromVideoNode(vNode);
            if (!retryPlayer) {
                ApolloLog(@"[VideoUnmute] %@ retry: player still not ready after 500ms", contextLabel);
                return;
            }

            SyncMuteButtonIcon(rmNode, [retryPlayer isMuted]);

            if (sUnmuteCommentsVideos == 2
                && !objc_getAssociatedObject(strongOwner, kAutoUnmuteAppliedKey)) {
                objc_setAssociatedObject(strongOwner, kAutoUnmuteAppliedKey, @YES,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                ApolloLog(@"[VideoUnmute] %@ retry: unmuting after delay (muted=%d)",
                          contextLabel, [retryPlayer isMuted]);
                UnmuteRichMediaNode(rmNode, vNode);
            }
        });
        return;
    }

    SyncMuteButtonIcon(richMediaNode, [player isMuted]);

    if (sUnmuteCommentsVideos != 2) return;
    if (unmuteApplied) return;

    objc_setAssociatedObject(visibilityOwner, kAutoUnmuteAppliedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    ApolloLog(@"[VideoUnmute] %@ auto-unmuting (event=%llu, muted=%d)",
              contextLabel, event, [player isMuted]);
    UnmuteRichMediaNode(richMediaNode, videoNode);
}

// =============================================================================
// MARK: - Hooks
// =============================================================================

// ---------------------------------------------------------------------------
// RichMediaHeaderCellNode: the comments header video cell
// ---------------------------------------------------------------------------
// cellNodeVisibilityEvent: fires when the cell's visibility changes in the
// scroll view (visible, invisible, rect changed, etc). Two responsibilities
// (both skipped while PiP owns this cell's player, and on event=1 ticks):
//
// 1. Icon sync (native bug fix, runs on visible/invisible events):
//    For shareable videos, the button setup code (sub_100582a0c) checks
//    [videoNode player] to set the initial isMuted state. But for shareable
//    videos, [videoNode player] is nil (the player is on the playerLayer).
//    The code defaults to isMuted=false (unmuted icon) even though the player
//    is actually muted. We correct this on every visibility event so the icon
//    stays in sync — including after returning from MediaViewer, which
//    force-mutes the player via viewDidDisappear.
//
// 2. Auto-unmute (only if toggle enabled, one-shot per cell instance):
//    Unmutes the player and syncs the icon to "unmuted" state.
// ---------------------------------------------------------------------------
%hook RichMediaHeaderCellNode

- (void)cellNodeVisibilityEvent:(unsigned long long)event
                   inScrollView:(id)scrollView
                  withCellFrame:(CGRect)frame {
    id richMediaNode = GetIvarObject(self, "richMediaNode");
    // PiP first: it may take over (scroll-away) or restore (scroll-back) on
    // this event. YES = PiP owns this cell's player and %orig must be skipped
    // so Apollo's synchronous play/pause never touches it. The unmute handling
    // below is also skipped — protection state must not change under PiP.
    if (ApolloPiP_HandleCommentsVisibilityEvent(self, richMediaNode, event)) {
        return;
    }
    %orig;
    // event=1 (VisibleRectChanged) fires on every layout tick during scroll.
    // Skip the verbose path entirely — the icon-sync inside SyncMuteButtonIcon
    // is a no-op when state already matches, but the log line itself floods.
    if (event == 1) return;
    HandleCommentsRichMediaVisibilityEvent(self, richMediaNode, event,
                                           @"comments header video");
}

%end

%hook CommentsHeaderCellNode

- (void)cellNodeVisibilityEvent:(unsigned long long)event
                   inScrollView:(id)scrollView
                  withCellFrame:(CGRect)frame {
    id crosspostRichMediaNode = GetCrosspostRichMediaNodeFromOwner(self);
    // PiP first (see RichMediaHeaderCellNode above) — covers crosspost videos.
    if (ApolloPiP_HandleCommentsVisibilityEvent(self, crosspostRichMediaNode, event)) {
        return;
    }
    %orig;

    // event=1 (VisibleRectChanged) fires on every layout tick during scroll.
    // Skip entirely — nothing for us to do on rect-change ticks.
    if (event == 1) return;

    if (!crosspostRichMediaNode) return;

    ApolloLog(@"[VideoUnmute] CommentsHeaderCellNode visibility event=%llu for crosspost rich media",
              event);
    HandleCommentsRichMediaVisibilityEvent(self, crosspostRichMediaNode, event,
                                           @"comments crosspost video");
}

%end

// =============================================================================
// MARK: - RichMediaNode Hooks
// =============================================================================

%hook RichMediaNode

// ---------------------------------------------------------------------------
// unpauseAllAVPlayersNotificationReceivedWithNotification: — native bug fix:
// shareable comments header videos are skipped by the native unpause handler
// (sub_10058249c). Resume them ourselves. Unconditional (not behind the
// unmute toggle) since it's a native bug fix.
// ---------------------------------------------------------------------------
- (void)unpauseAllAVPlayersNotificationReceivedWithNotification:(id)notification {
    %orig;

    // Only fix for comments header videos
    if (!GetIvarBool(self, "isShownInCommentsHeader") && self != sCommentsRichMediaNode) return;

    id videoNode = GetIvarObject(self, "videoNode");
    if (!videoNode) return;

    // Only fix for shareable videos (non-shareable already handled by native code)
    SEL shareableSel = NSSelectorFromString(@"allowPlayerLayerToBeShareable");
    if (![videoNode respondsToSelector:shareableSel]) return;
    BOOL isShareable = ((BOOL (*)(id, SEL))objc_msgSend)(videoNode, shareableSel);
    if (!isShareable) return;

    AVPlayer *player = GetPlayerFromVideoNode(videoNode);
    if (!player) return;

    ApolloLog(@"[VideoUnmute] unpauseAllAVPlayers: resuming shareable comments header video");
    [player play];
}

// ---------------------------------------------------------------------------
// muteUnmuteButtonTappedWithSender: — detect user manually tapping the mute
// button. Clears sAutoUnmutedPlayer BEFORE %orig so the mute dance that
// follows (triggered by the native handler) can proceed normally.
//
// This is the counterpart to the AVPlayer.setMuted: hook which BLOCKS mute
// on the auto-unmuted player. Without this, the user couldn't manually mute.
// ---------------------------------------------------------------------------
- (void)muteUnmuteButtonTappedWithSender:(id)sender {
    // Clear auto-unmute protection if this cell's player matches the
    // protected player. No context check (isShownInCommentsHeader) — for
    // shareable videos the same AVPlayer is shared between feed and comments
    // cells, so the user must be able to mute from either context.
    if (sAutoUnmutedPlayer) {
        id videoNode = GetIvarObject(self, "videoNode");
        AVPlayer *player = GetPlayerFromVideoNode(videoNode);
        if (player && player == sAutoUnmutedPlayer) {
            ApolloLog(@"[VideoUnmute] User tapped mute button — clearing auto-unmute protection");
            sAutoUnmutedPlayer = nil;
        }
    }

    // Capture player state before the tap handler runs.
    // sub_10058cb30 (called from TouchHintVideoNode.didExitVisibleState) force-
    // mutes AND pauses unmuted videos when the feed VC leaves the view hierarchy
    // (e.g. navigating back to RedditListVC). When the user returns and taps the
    // mute button to unmute, the native handler (sub_100341894) unmutes the player
    // but does NOT call [player play], leaving the video frozen. Detect this state
    // so we can resume playback after %orig.
    id videoNodeForResume = GetIvarObject(self, "videoNode");
    AVPlayer *playerForResume = GetPlayerFromVideoNode(videoNodeForResume);
    BOOL wasMutedAndPaused = playerForResume
        && [playerForResume isMuted]
        && [playerForResume rate] == 0.0f;

    %orig;

    // If the tap just unmuted a force-paused video, resume playback.
    if (wasMutedAndPaused && playerForResume && ![playerForResume isMuted]) {
        ApolloLog(@"[VideoUnmute] Mute button unmuted a force-paused video — resuming playback");
        [playerForResume play];
    }

    // If the tap unmuted this video, mute any audible PiP card playing a
    // different video (native activeAudioPlayer arbitration misses players
    // that were unmuted by the tweak rather than by Apollo), and give the
    // inline native-PiP controller a chance to arm (no scroll event fires
    // for a mute-button tap).
    if (playerForResume && ![playerForResume isMuted]) {
        ApolloPiP_YieldAudioToPlayer(playerForResume);
        ApolloPiP_NoteInlineVideoAudible(videoNodeForResume, playerForResume);
    }
}

%end

// ---------------------------------------------------------------------------
// MediaPageViewController: manage auto-unmute around fullscreen transitions
// ---------------------------------------------------------------------------
// MediaPageViewController is used for ALL media types (images, videos, GIFs).
// Our hooks are guarded by GetPlayerFromMediaPageVC() to only fire for video
// content — opening/closing an image viewer must not disrupt the comments
// header video's audio protection.
//
// viewWillAppear: Suspends auto-unmute protection ONLY when the fullscreen
//   viewer shows the same video we're protecting (player identity check).
//   This lets the user freely mute/unmute in fullscreen. Image viewers and
//   different videos leave sAutoUnmutedPlayer intact.
//
// viewDidDisappear: The native dismiss code (sub_10025ce28) unconditionally:
//   1. [player setMuted:YES] — force-mutes the shared player
//   2. Sets muteUnmuteButtonNode.isMuted = true + updates icon to "small-mute"
//   3. Triggers the "mute dance" (sub_10025d84c):
//      T+0ms:   isDancing=true, posts pauseAllAVPlayers
//      T+50ms:  AVAudioSession → Ambient, setActive:NO
//      T+100ms: [player setMuted:YES] again, posts unpauseAllAVPlayers
//
//   If the player was unmuted at dismiss time (user had sound on), we schedule
//   a re-unmute after the mute dance completes (200ms) to restore audio.
// ---------------------------------------------------------------------------
%hook MediaPageViewController

// - (void)viewWillAppear:(BOOL)animated {
//     %orig;
//     if (sAutoUnmutedPlayer) {
//         // Only suspend protection if the fullscreen viewer is showing the SAME
//         // video we're protecting. Opening an image viewer (no player) or a
//         // different video should not disrupt the comments header's audio.
//         AVPlayer *fullscreenPlayer = GetPlayerFromMediaPageVC(self);
//         if (fullscreenPlayer && fullscreenPlayer == sAutoUnmutedPlayer) {
//             ApolloLog(@"[VideoUnmute] MediaPageVC appearing with protected player — suspending protection for fullscreen");
//             sAutoUnmutedPlayer = nil;
//         } else {
//             ApolloLog(@"[VideoUnmute] MediaPageVC appearing (image or different video) — keeping protection");
//         }
//     }
// }

- (void)viewDidDisappear:(BOOL)animated {
    // Only process re-unmute for video content. Image viewers have no player
    // and should not trigger any mute/unmute logic.
    AVPlayer *fullscreenPlayer = GetPlayerFromMediaPageVC(self);
    if (!fullscreenPlayer) {
        ApolloLog(@"[VideoUnmute] MediaPageVC disappearing — no video player (image viewer), skipping");
        %orig;
        return;
    }

    // The fullscreen PiP button owns this dismissal: it restores the user's
    // fullscreen mute state onto the card itself. Mode 2 ("Always") would
    // otherwise force-unmute a video the user muted before pressing PiP.
    if (ApolloPiP_WillHandleFullscreenDismiss()) {
        ApolloLog(@"[VideoUnmute] MediaPageVC disappearing — fullscreen PiP handoff owns mute state, skipping re-unmute");
        %orig;
        return;
    }

    // Normally we only process re-unmute when fullscreen is showing the SAME
    // player as the comments header. Compact-mode entry via the fullscreen
    // comments button is different: MediaPageVC.commentsButtonTapped pushes a
    // new CommentsVC using the SAME RDKLink object (sub_100270ab0 →
    // sub_100725044), but the comments header creates a fresh AVPlayer, so the
    // player identity check fails. Detect that same-link handoff explicitly.
    AVPlayer *headerPlayer = sCommentsVideoNode ? GetPlayerFromVideoNode(sCommentsVideoNode) : nil;
    BOOL sameLinkCommentsTransition = IsCommentsOwnerShowingSameLinkAsMediaPage(self);
    if (headerPlayer && fullscreenPlayer != headerPlayer && !sameLinkCommentsTransition) {
        ApolloLog(@"[VideoUnmute] MediaPageVC disappearing — different video than header, skipping re-unmute");
        %orig;
        return;
    }

    if (sameLinkCommentsTransition && (!headerPlayer || fullscreenPlayer != headerPlayer)) {
        ApolloLog(@"[VideoUnmute] MediaPageVC disappearing — compact-mode same-link transition, allowing re-unmute with new player");
    }

    // BEFORE %orig: check if the player in the fullscreen viewer is unmuted.
    // Used by "Remember from Full Screen" mode (1) to decide whether to
    // re-unmute. "Always" mode (2) re-unmutes regardless.
    BOOL shouldReUnmute = NO;

    ApolloLog(@"[VideoUnmute] MediaPageVC disappearing — checking if re-unmute needed (mode=%ld)", (long)sUnmuteCommentsVideos);

    if (sUnmuteCommentsVideos >= 1 && sCommentsRichMediaNode && sCommentsVideoNode) {
        if (sUnmuteCommentsVideos == 2) {
            // Always mode: re-unmute regardless of fullscreen mute state
            shouldReUnmute = YES;
            ApolloLog(@"[VideoUnmute] MediaPageVC dismissing — Always mode, will re-unmute");
        } else {
            // Remember mode: check what the user did in fullscreen
            if (![fullscreenPlayer isMuted]) {
                shouldReUnmute = YES;
                ApolloLog(@"[VideoUnmute] MediaPageVC dismissing — player was unmuted, will re-unmute (Remember mode)");
            } else {
                ApolloLog(@"[VideoUnmute] MediaPageVC dismissing — player was muted (user choice), skipping re-unmute");
            }
        }
    } else {
        if (!sCommentsRichMediaNode) ApolloLog(@"[VideoUnmute] MediaPageVC disappearing — no saved richMediaNode, skipping re-unmute");
        if (!sCommentsVideoNode) ApolloLog(@"[VideoUnmute] MediaPageVC disappearing — no saved videoNode, skipping re-unmute");
    }

    %orig;  // Native: [player setMuted:YES] + mute dance (T+50ms, T+100ms)

    if (shouldReUnmute) {
        __weak id weakRichMediaNode = sCommentsRichMediaNode;
        __weak id weakVideoNode = sCommentsVideoNode;
        // Wait 200ms for the mute dance to finish (last step at T+100ms).
        // Then re-unmute the player and re-establish audio session protection.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ReUnmuteAfterFullscreenWhenReady(weakRichMediaNode, weakVideoNode, 3);
        });
    }
}

%end

// ---------------------------------------------------------------------------
// MediaViewerAnimationController: suspend protection during fullscreen
// ---------------------------------------------------------------------------
// For shareable videos, the playerLayerContainerView on MediaViewerController
// is created in animateTransition: (by the transition animation controller),
// NOT during viewDidLoad/viewWillAppear/viewDidAppear. So we can't use VC
// lifecycle hooks to find the fullscreen player reliably.
//
// Instead, hook animateTransition: directly. After %orig, the player layer
// has been transferred from the comments header to the fullscreen container.
// We check if the comments header's player matches our protected player —
// if so, the fullscreen viewer is showing the same video, and we suspend
// protection so the user can freely mute/unmute in fullscreen.
//
// This only fires for PRESENT transitions (the "to" VC is a MediaPageVC).
// Dismiss transitions have a different "to" VC and are handled by
// MediaPageViewController.viewDidDisappear.
// ---------------------------------------------------------------------------
%hook MediaViewerAnimationController

- (void)animateTransition:(id)transitionContext {
    %orig;

    if (!sAutoUnmutedPlayer) return;

    // Get the "to" VC to confirm this is a present (not dismiss) transition.
    SEL vcForKeySel = NSSelectorFromString(@"viewControllerForKey:");
    if (![transitionContext respondsToSelector:vcForKeySel]) return;

    id toVC = ((id (*)(id, SEL, id))objc_msgSend)(
        transitionContext, vcForKeySel, UITransitionContextToViewControllerKey);

    Class mediaPageVCClass = MediaPageViewControllerClass();
    if (!toVC || !mediaPageVCClass || ![toVC isKindOfClass:mediaPageVCClass]) return;

    // After %orig, the transition has created a PlayerLayerContainerView for
    // shareable videos and added it to the view hierarchy with its playerLayer
    // ivar set. However, the MediaViewerController's playerLayerContainerView
    // ivar is only set in the animation COMPLETION block, so
    // GetPlayerFromMediaPageVC can't find it via the ivar yet.
    //
    // Walk the transition container's view hierarchy to find the
    // PlayerLayerContainerView by class, then check its playerLayer's player
    // against our protected player.
    static Class sPlayerLayerContainerClass = nil;
    if (!sPlayerLayerContainerClass) {
        sPlayerLayerContainerClass = objc_getClass("_TtC6Apollo24PlayerLayerContainerView");
    }

    // First try GetPlayerFromMediaPageVC (works for non-shareable videos
    // where the player ivar is set directly). Fall back to hierarchy walk
    // for shareable videos.
    AVPlayer *fullscreenPlayer = GetPlayerFromMediaPageVC(toVC);

    if (!fullscreenPlayer && sPlayerLayerContainerClass) {
        // Walk the transition container view to find the PlayerLayerContainerView
        // that animateTransition: just created and added to the hierarchy.
        UIView *containerView = ((id (*)(id, SEL))objc_msgSend)(transitionContext, @selector(containerView));
        UIView *found = FindSubviewOfClass(containerView, sPlayerLayerContainerClass);
        if (found) {
            id playerLayer = GetIvarObject(found, "playerLayer");
            if ([playerLayer isKindOfClass:[AVPlayerLayer class]]) {
                fullscreenPlayer = [(AVPlayerLayer *)playerLayer player];
            }
        }
    }

    ApolloLog(@"[VideoUnmute] animateTransition: fullscreenPlayer=%p, sAutoUnmutedPlayer=%p",
              fullscreenPlayer, sAutoUnmutedPlayer);

    if (fullscreenPlayer && fullscreenPlayer == sAutoUnmutedPlayer) {
        ApolloLog(@"[VideoUnmute] animateTransition: same player — suspending protection for fullscreen");
        sAutoUnmutedPlayer = nil;
    } else if (!fullscreenPlayer) {
        ApolloLog(@"[VideoUnmute] animateTransition: no player found (image viewer) — keeping protection");
    } else {
        ApolloLog(@"[VideoUnmute] animateTransition: different player — keeping protection");
    }
}

%end

// ---------------------------------------------------------------------------
// AVPlayer: block mute-dance re-muting after auto-unmute
// ---------------------------------------------------------------------------
// After our auto-unmute, the mute dance from MediaPageViewController's
// viewDidDisappear (or TouchHintVideoNode.didExitVisibleState) fires and calls
// [player setMuted:YES]. Without blocking this, the player gets re-muted
// ~50-100ms after we unmuted it.
//
// We BLOCK setMuted:YES on the auto-unmuted player entirely. User manual mute
// is handled by the muteUnmuteButtonTappedWithSender: hook on RichMediaNode,
// which clears sAutoUnmutedPlayer BEFORE the mute dance runs, allowing it
// through.
//
// Safety: sAutoUnmutedPlayer is __weak — auto-nils on player dealloc.
// ---------------------------------------------------------------------------
%hook AVPlayer

- (void)setMuted:(BOOL)muted {
    // Block mute-dance re-muting on our auto-unmuted player.
    // User manual mute clears sAutoUnmutedPlayer via the button tap hook first.
    if (muted && !sIsAutoUnmuting && sAutoUnmutedPlayer && self == sAutoUnmutedPlayer) {
        ApolloLog(@"[VideoUnmute] AVPlayer.setMuted:YES — BLOCKED (protecting auto-unmuted player)");
        return;
    }
    // Same for the inline-armed native-PiP player during the background
    // handoff window (the dance's T+100ms setMuted:YES would silence the
    // system PiP that just took the video).
    if (muted && !sIsAutoUnmuting && ApolloPiP_ShouldBlockMuteOfPlayer(self)) {
        ApolloLog(@"[VideoUnmute] AVPlayer.setMuted:YES — BLOCKED (PiP background handoff shield)");
        return;
    }
    %orig;
    // The mute took effect (not blocked): if this is the inline-armed system-PiP
    // player, drop the arm so a home-swipe can't hand off a now-muted video.
    if (muted && !sIsAutoUnmuting) {
        ApolloPiP_NoteInlinePlayerMuted(self);
    }
}

%end

// ---------------------------------------------------------------------------
// AVAudioSession: block Apollo's reversion to Ambient
// ---------------------------------------------------------------------------
// Apollo's video setup code resets the audio session to Ambient after player
// creation, which silences audio even when player.muted == NO. We block this
// while our auto-unmuted player is active.
//
// Safety: sAutoUnmutedPlayer is __weak — auto-nils when the player deallocates,
// making these hooks transparent pass-throughs automatically.
// ---------------------------------------------------------------------------
// A PiP video playing audibly needs the same session protection as an
// auto-unmuted one: other videos' mute dances (T+50ms) downgrade the session
// to Ambient + inactive GLOBALLY, which would silence PiP audio.
static BOOL ShouldProtectAudioSession(void) {
    return sAutoUnmutedPlayer != nil || ApolloPiP_ShouldBlockAudioSessionDowngrade();
}

%hook AVAudioSession

- (BOOL)setCategory:(AVAudioSessionCategory)category
                mode:(AVAudioSessionMode)mode
             options:(AVAudioSessionCategoryOptions)options
               error:(NSError **)error {
    if (ShouldProtectAudioSession() && [category isEqualToString:AVAudioSessionCategoryAmbient]) {
        ApolloLog(@"[VideoUnmute] Blocking setCategory:Ambient (mode:options: variant)");
        return YES;
    }
    return %orig;
}

- (BOOL)setCategory:(AVAudioSessionCategory)category error:(NSError **)error {
    if (ShouldProtectAudioSession() && [category isEqualToString:AVAudioSessionCategoryAmbient]) {
        ApolloLog(@"[VideoUnmute] Blocking setCategory:Ambient (short variant)");
        return YES;
    }
    return %orig;
}

- (BOOL)setActive:(BOOL)active
      withOptions:(AVAudioSessionSetActiveOptions)options
            error:(NSError **)error {
    if (!active && ShouldProtectAudioSession()) {
        ApolloLog(@"[VideoUnmute] Blocking setActive:NO while protected player active");
        return YES;
    }
    return %orig;
}

%end

// ---------------------------------------------------------------------------
// _TtC6Apollo22CommentsViewController: manage auto-unmute through transitions
// ---------------------------------------------------------------------------
// Key insight: when swiping back from comments to feed, the mute dance
// (sub_1003414cc, triggered by TouchHintVideoNode.didExitVisibleState →
// sub_10058cb30) fires DURING the transition and asynchronously:
//   T+0ms:   isDancing=true, pauseAllAVPlayers
//   T+50ms:  setCategory:Ambient, setActive:NO
//   T+100ms: [player setMuted:YES], unpauseAllAVPlayers
//
// If sAutoUnmutedPlayer is cleared before the mute dance completes, our
// AVPlayer.setMuted: and AVAudioSession hooks can't block it, and the
// player gets re-muted. This matches the user-observed bug: audio mutes
// on swipe-back but persists when using native unmute (which registers
// with VideoSharingManager.activeAudioPlayer instead).
//
// Fix: during back navigation, keep sAutoUnmutedPlayer alive so the hooks
// block the mute dance. The player protection persists into the feed,
// matching native unmute behavior.
// ---------------------------------------------------------------------------
%hook _TtC6Apollo22CommentsViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;

    BOOL isSameVC = (sCommentsVCOwner == self);

    if (sIsNavigatingBack && isSameVC) {
        // Same CommentsVC reappearing while sIsNavigatingBack is set means
        // an interactive back gesture was cancelled — we're still in comments.
        // Reset so a subsequent scroll-out-of-view (event=2) can clear
        // sAutoUnmutedPlayer normally instead of keeping stale protection.
        ApolloLog(@"[VideoUnmute] CommentsVC viewWillAppear — back gesture cancelled, resetting navigation flag");
        sIsNavigatingBack = NO;
    }
    // Note: when a DIFFERENT CommentsVC appears (isSameVC=NO), do NOT reset
    // sIsNavigatingBack. The popping CommentsVC's mute dance may still be
    // in-flight, and sIsNavigatingBack must survive until its viewDidDisappear
    // to protect sAutoUnmutedPlayer from the event=2 handler.

    if (!isSameVC) {
        // Different CommentsVC is appearing (forward push or back to a
        // previous CommentsVC). Clear stale refs from the old CommentsVC —
        // they belong to an invisible video and would cause ghost audio if
        // MediaPageVC dismiss tried to re-unmute them.
        ApolloLog(@"[VideoUnmute] CommentsVC viewWillAppear — new CommentsVC, clearing stale refs from previous");
        sCommentsRichMediaNode = nil;
        sCommentsVideoNode = nil;
    }
    // When isSameVC=YES (returning from MediaPageVC or gesture cancel),
    // refs are preserved so MediaPageVC.viewDidDisappear's dispatch_after
    // can still use them for re-unmute.

    sCommentsVCOwner = self;
}

- (void)viewWillDisappear:(BOOL)animated {
    BOOL isPopping = [(UIViewController *)self isMovingFromParentViewController];
    ApolloLog(@"[VideoUnmute] CommentsVC viewWillDisappear (isPopping=%d)", isPopping);
    %orig;

    if (isPopping) {
        // Back navigation (swipe or back button tap). Keep sAutoUnmutedPlayer
        // set so our hooks block the mute dance through the transition.
        sIsNavigatingBack = YES;
        // Save nav controller now — by viewDidDisappear, self.navigationController is nil.
        sSavedNavControllerForPop = [(UIViewController *)self navigationController];
        ApolloLog(@"[VideoUnmute] CommentsVC popping — keeping auto-unmute protection for back transition");
    }
    // Note: sAutoUnmutedPlayer is NOT cleared here anymore.
    // - Back navigation: protection persists so audio survives the mute dance.
    // - MediaPageVC push: MediaPageVC.viewWillAppear clears it separately.
    // - Scroll out of view: cellNodeVisibilityEvent event=2 clears it.
}

- (void)viewDidDisappear:(BOOL)animated {
    BOOL wasNavigatingBack = sIsNavigatingBack;
    UINavigationController *navForPop = sSavedNavControllerForPop;
    ApolloLog(@"[VideoUnmute] CommentsVC viewDidDisappear (isOwner=%d, wasBack=%d)", self == sCommentsVCOwner, wasNavigatingBack);
    %orig;
    sIsNavigatingBack = NO;
    sSavedNavControllerForPop = nil;
    // Only clear saved refs if THIS CommentsVC owns them. When navigating
    // CommentsVC #1 → CommentsVC #2 (via link), CommentsVC #2's
    // cellNodeVisibilityEvent saves refs and viewWillAppear claims ownership
    // BEFORE CommentsVC #1's viewDidDisappear fires. Without this guard,
    // CommentsVC #1 would wipe CommentsVC #2's refs, breaking re-unmute
    // after fullscreen.
    if (self == sCommentsVCOwner) {
        sCommentsRichMediaNode = nil;
        sCommentsVideoNode = nil;
        sCommentsVCOwner = nil;

        if (wasNavigatingBack && sAutoUnmutedPlayer) {
            // Back navigation: keep sAutoUnmutedPlayer alive briefly so
            // our hooks block the post-pop setCategory:Ambient (from
            // player setup after the playerLayer reclaim) and any mute
            // dance steps that might still be in-flight.
            //
            // Expire after 200ms — the mute dance window is T+0..T+100ms,
            // so 200ms covers the worst case with margin.
            //
            // After expiry, check if a visible feed cell has our player on
            // its playerLayer. If yes (non-compact: feed has inline video),
            // audio continues. If no (compact: no inline video on feed),
            // mute + pause to prevent invisible background audio.
            ApolloLog(@"[VideoUnmute] CommentsVC popped — keeping auto-unmute protection, will expire after mute dance window");

            __weak AVPlayer *weakPlayer = sAutoUnmutedPlayer;
            __weak UINavigationController *weakNav = navForPop;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                // Only clear if the protected player hasn't changed
                // (e.g. a new CommentsVC might have set a new player)
                if (sAutoUnmutedPlayer && sAutoUnmutedPlayer == weakPlayer) {
                    sAutoUnmutedPlayer = nil;

                    // Walk visible feed cells to check if the player is
                    // displayed on an inline video cell.
                    UINavigationController *nav = weakNav;
                    UIViewController *feedVC = [nav topViewController];
                    AVPlayer *p = weakPlayer;
                    BOOL visibleOnFeed = p ? IsPlayerOnVisibleFeedCell(feedVC, p) : NO;

                    ApolloLog(@"[VideoUnmute] Mute dance window expired — clearing protection (visibleOnFeed=%d)", visibleOnFeed);

                    if (p && ApolloPiP_IsOwnedPlayer(p)) {
                        // The player lives on in the floating PiP card — it is
                        // intentionally audible/visible off-feed. Don't kill it.
                        ApolloLog(@"[VideoUnmute] Player is PiP-owned — skipping post-pop mute/pause");
                    } else if (!visibleOnFeed && p) {
                        // Player is not on any visible feed cell (compact mode
                        // or no matching cell). Mute + pause + reset audio
                        // session to prevent invisible background audio.
                        ApolloLog(@"[VideoUnmute] Player not on feed — muting to prevent background audio");
                        [p setMuted:YES];
                        [p pause];
                        AVAudioSession *session = [AVAudioSession sharedInstance];
                        [session setCategory:AVAudioSessionCategoryAmbient error:nil];
                        [session setActive:NO
                               withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                     error:nil];
                    }

                    if (feedVC) {
                        ApolloLog(@"[VideoUnmute] Syncing visible feed mute buttons after comments pop");
                        SyncVisibleFeedMuteButtons(feedVC);
                    }
                }
            });
        } else if (wasNavigatingBack) {
            __weak UINavigationController *weakNav = navForPop;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIViewController *feedVC = [weakNav topViewController];
                if (!feedVC) return;

                ApolloLog(@"[VideoUnmute] CommentsVC popped without protected player — syncing visible feed mute buttons");
                SyncVisibleFeedMuteButtons(feedVC);
            });
        } else if (sAutoUnmutedPlayer) {
            // Non-back transition (e.g. pushing MediaPageVC or another VC).
            // Drop protection so the native mute dance can proceed.
            ApolloLog(@"[VideoUnmute] CommentsVC disappeared (not back nav) — clearing auto-unmute protection");
            sAutoUnmutedPlayer = nil;
        }
    }
}

%end

// =============================================================================
// MARK: - Exported: Fix Disconnected PlayerLayer
// =============================================================================
//
// Called from ApolloVideoSwipeFix after the committed pop's reclaim.
// After fullscreen MediaPageVC transitions, the reclaim (sub_100561a40) puts
// the shared AVPlayerLayer into playerLayerSuperlayer — a container CALayer
// saved by PostCellActionTaker that can become DISCONNECTED from the window's
// layer tree. The reclaim's async block (sub_100562a80) also doesn't run
// because the sharing state was already cleared. This leaves the playerLayer
// invisible and the shareable flag stale.
//
// This function walks visible cells, finds the disconnected playerLayer, and
// replicates what the async block would have done:
//   1. Re-parent playerLayer into the videoNode's live layer tree
//   2. Set allowPlayerLayerToBeShareable:NO (enables native unpause handler)
//   3. Sync the mute button icon to the player's actual state
//
// See docs/frozen-video-root-cause.md for the full analysis.
// =============================================================================

void ApolloVideoUnmute_FixDisconnectedPlayerLayer(id postsViewController) {
    UITableView *tableView = GetTableViewFromViewController((UIViewController *)postsViewController);
    if (!tableView) {
        ApolloLog(@"[VideoUnmute] FixDisconnectedPlayerLayer: no tableView found");
        return;
    }

    BOOL foundDisconnected = NO;

    for (UITableViewCell *cell in [tableView visibleCells]) {
        SEL nodeSel = NSSelectorFromString(@"node");
        if (![cell respondsToSelector:nodeSel]) continue;

        id cellNode = ((id (*)(id, SEL))objc_msgSend)(cell, nodeSel);
        if (!cellNode) continue;

        for (id richMediaNode in @[
            GetIvarObjectQuiet(cellNode, "richMediaNode") ?: [NSNull null],
            GetCrosspostRichMediaNodeFromOwner(cellNode) ?: [NSNull null]
        ]) {
            if (richMediaNode == (id)[NSNull null]) continue;

            id videoNode = GetVideoNodeFromRichMediaNode(richMediaNode);
            if (!videoNode) continue;

            SEL playerLayerSel = NSSelectorFromString(@"playerLayer");
            if (![videoNode respondsToSelector:playerLayerSel]) continue;

            CALayer *pLayer = ((id (*)(id, SEL))objc_msgSend)(videoNode, playerLayerSel);
            CALayer *vnLayer = ((CALayer *(*)(id, SEL))objc_msgSend)(videoNode, @selector(layer));
            if (!pLayer || !vnLayer) continue;

            AVPlayer *player = [pLayer respondsToSelector:@selector(player)]
                ? [(AVPlayerLayer *)pLayer player] : nil;
            if (!player || [player rate] == 0.0f) continue;

            BOOL inTree = LayerIsInLayerTreeOf(pLayer, vnLayer);

            if (!inTree) {
                ApolloLog(@"[VideoUnmute] FixDisconnectedPlayerLayer: re-parenting playerLayer %p to videoNode %p",
                          pLayer, videoNode);
                [pLayer removeFromSuperlayer];
                [vnLayer addSublayer:pLayer];

                SEL setShareableSel = NSSelectorFromString(@"setAllowPlayerLayerToBeShareable:");
                if ([videoNode respondsToSelector:setShareableSel]) {
                    ((void (*)(id, SEL, BOOL))objc_msgSend)(videoNode, setShareableSel, NO);
                }

                foundDisconnected = YES;
            }

            SyncMuteButtonIcon(richMediaNode, [player isMuted]);
        }
    }

    if (!foundDisconnected) {
        ApolloLog(@"[VideoUnmute] FixDisconnectedPlayerLayer: no disconnected playerLayer found");
    }
}

// =============================================================================
// MARK: - Exported helpers for ApolloPictureInPicture.xm
// =============================================================================

AVPlayer *ApolloVideoUnmute_GetPlayerFromVideoNode(id videoNode) {
    return GetPlayerFromVideoNode(videoNode);
}

void ApolloVideoUnmute_SyncMuteButtonIcon(id richMediaNode, BOOL isMuted) {
    SyncMuteButtonIcon(richMediaNode, isMuted);
}

// Drops auto-unmute protection for a specific player so a deliberate mute
// (e.g. the PiP card's mute button / close) can pass the AVPlayer.setMuted:
// block above.
void ApolloVideoUnmute_ClearProtectionIfPlayer(AVPlayer *player) {
    if (player && sAutoUnmutedPlayer == player) {
        ApolloLog(@"[VideoUnmute] Clearing auto-unmute protection at PiP's request");
        sAutoUnmutedPlayer = nil;
    }
}

// YES while a CommentsVC is being popped back to its feed (set in
// viewWillDisappear when isMovingFromParentViewController, cleared in
// viewDidDisappear). The comments cell fires its Invisible event during the
// pop; PiP consults this so it does not disarm the inline system-PiP
// controller mid-reclaim — the same player keeps playing on the feed.
BOOL ApolloVideoUnmute_IsNavigatingBack(void) {
    return sIsNavigatingBack;
}

// =============================================================================
// MARK: - PostsSearchResultsViewController playerLayer reclaim (native bug fix)
// =============================================================================
//
// Frozen/grey inline videos after returning to search results (comments pop
// or fullscreen dismiss). Root cause (confirmed in Hopper + on-device
// diagnostics): Apollo's shared-playerLayer reclaim (sub_100561a40, a
// PostSectionController method) is invoked from BOTH viewWillAppear: and
// viewDidAppear: of PostsViewController, SavedPostsCommentsViewController and
// ProfileViewController — but PostsSearchResultsViewController overrides
// NEITHER lifecycle method, so a playerLayer stolen by the comments header or
// the fullscreen PlayerLayerContainerView is never returned to the search
// cell. The cell keeps showing its poster (frozen) or an empty container
// (grey) while the shared AVPlayer keeps running in a detached layer tree.
//
// The native reclaim is Swift-only (no selector), so we replicate it here:
// the search cell's videoNode still references the stolen AVPlayerLayer via
// [videoNode playerLayer] (verified on device), which lets us re-parent it
// into the videoNode's own backing layer — the same recovery strategy as
// ApolloVideoUnmute_FixDisconnectedPlayerLayer below. Differences from the
// native reclaim: we skip VideoSharingManager bookkeeping (not reachable from
// ObjC; stale sharing state is harmless — the next share simply re-registers)
// and we parent into the videoNode's layer instead of the orphanable
// playerLayerSuperlayer container.
//
// Invocation mirrors Apollo's own timing (viewWillAppear body sub_100599d4c,
// viewDidAppear body sub_100599fe4 — note their gates are OPPOSITE):
//   - viewWillAppear: non-interactive comments pop (instant restore, like the
//     native feed). Skipped while nav.presentedViewController != nil — the
//     native viewWillAppear loop reclaims only with nothing presented,
//     because during a fullscreen dismissal the layer is still animating in
//     the transition container.
//   - Interactive pop: deferred to the gesture-commit callback, mirroring
//     ApolloVideoSwipeFix — reclaiming at viewWillAppear would steal the
//     layer from the comments header on a gesture that later cancels.
//   - viewDidAppear: fullscreen dismissal completion. The native loop here
//     reclaims only when presentedViewController is STILL the dismissing
//     MediaPageViewController (UIKit tears the presentation down after the
//     presenter's viewDidAppear, so it is never nil on this path).
// =============================================================================

// Last-known playback refs per RichMediaNode, saved whenever a pass (or the
// viewWillDisappear capture) sees the cell with a live playerLayer + player.
// Needed because a fullscreen entry that takes the NON-shared path tears down
// the videoNode's own playerLayer/player references while the search view is
// out of the window — at dismissal there is nothing left on the node to
// reclaim (observed on device: playerLayer=0x0 player=0x0 on a cell that was
// rate=1.00 inTree=1 seconds earlier).
static const void *kSearchSavedPlayerLayerKey = &kSearchSavedPlayerLayerKey;
static const void *kSearchSavedPlayerKey = &kSearchSavedPlayerKey;
// NSNumber(BOOL): whether this cell's video was PLAYING when the search VC
// last left the window (captured in viewWillDisappear). Gates the resume
// below — Apollo autoplays only the one video at the table midpoint, so
// blanket-resuming every paused visible video creates stray concurrent
// players that Apollo's midpoint play/pause bookkeeping doesn't know about
// (observed on device: two cells at rate=1.00 simultaneously, followed by
// unreliable autoplay while scrolling). The flag is transition-scoped: the
// trailing re-check pass clears it so a later pass can never resume a video
// Apollo has since paused off stale data.
static const void *kSearchWasPlayingKey = &kSearchWasPlayingKey;
// Marker association on the AVPLAYER itself: set when another module reports
// the player was deliberately stopped (e.g. the user closed the floating PiP
// card, whose teardown applies Apollo's scrolled-away pause+mute state). The
// resume gates below must never restart such a player. The mark lifts as
// soon as a pass observes the player playing again (someone legitimately
// restarted it).
static const void *kSearchDeliberatelyStoppedKey = &kSearchDeliberatelyStoppedKey;

static BOOL PlayerWasDeliberatelyStopped(AVPlayer *player) {
    return player && objc_getAssociatedObject(player, kSearchDeliberatelyStoppedKey) != nil;
}

static void ClearDeliberatelyStoppedMarkIfPlaying(AVPlayer *player) {
    if (player && [player rate] != 0.0f
        && objc_getAssociatedObject(player, kSearchDeliberatelyStoppedKey)) {
        objc_setAssociatedObject(player, kSearchDeliberatelyStoppedKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// Exported for ApolloPictureInPicture.xm: called when a PiP teardown pauses
// the player on purpose, so the search reclaim never resurrects it.
void ApolloVideoUnmute_NotePlayerDeliberatelyStopped(AVPlayer *player) {
    if (!player) return;
    ApolloLog(@"[VideoUnmute] SearchReclaim: player %p marked deliberately stopped", player);
    objc_setAssociatedObject(player, kSearchDeliberatelyStoppedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ClearSearchSavedRefs(id richMediaNode) {
    objc_setAssociatedObject(richMediaNode, kSearchSavedPlayerLayerKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(richMediaNode, kSearchSavedPlayerKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// After a resume that leaves the video audible, give the inline system-PiP
// controller its arming chance — no scroll/visibility event fires for a
// programmatic resume, mirroring the other deliberate resume paths in this
// file. Muted players must NOT arm (the feed arm path is unmuted-only by
// design and ApolloPiP_NoteInlineVideoAudible itself doesn't check muted).
static void NoteSearchResumeMaybeAudible(id videoNode, AVPlayer *player) {
    if (player && ![player isMuted]) {
        ApolloPiP_NoteInlineVideoAudible(videoNode, player);
    }
}

// Returns YES when the cell hosts a video node at all (drives whether a
// trailing re-check pass is worth scheduling).
static BOOL FixupSearchCellRichMediaNode(id richMediaNode, NSString *reason) {
    id videoNode = GetVideoNodeFromRichMediaNode(richMediaNode);
    if (!videoNode) return NO;

    AVPlayerLayer *pLayer = GetPlayerLayerFromVideoNode(videoNode);
    AVPlayer *player = [pLayer player];

    CALayer *vnLayer = ((CALayer *(*)(id, SEL))objc_msgSend)(videoNode, @selector(layer));
    if (!vnLayer) return YES;

    NSNumber *wasPlaying = objc_getAssociatedObject(richMediaNode, kSearchWasPlayingKey);

    if (!pLayer || !player) {
        // The node's own refs are gone (teardown while offscreen). Restore
        // from the refs we saved while the video was last visibly attached.
        CALayer *savedLayer = objc_getAssociatedObject(richMediaNode, kSearchSavedPlayerLayerKey);
        AVPlayer *savedPlayer = objc_getAssociatedObject(richMediaNode, kSearchSavedPlayerKey);
        if (!savedLayer || !savedPlayer || ApolloPiP_IsOwnedPlayer(savedPlayer)) {
            ApolloLog(@"[VideoUnmute] SearchReclaim(%@): videoNode=%p has playerLayer=%p player=%p, no saved refs — skipping",
                      reason, videoNode, pLayer, player);
            return YES;
        }
        if (![savedPlayer currentItem]) {
            // Dead playback pipeline — re-parenting its layer would draw a
            // black rectangle over the poster. Drop the refs for good.
            ApolloLog(@"[VideoUnmute] SearchReclaim(%@): videoNode=%p saved player %p has no item — clearing dead refs",
                      reason, videoNode, savedPlayer);
            ClearSearchSavedRefs(richMediaNode);
            return YES;
        }

        BOOL savedInTree = LayerIsInLayerTreeOf(savedLayer, vnLayer);

        ApolloLog(@"[VideoUnmute] SearchReclaim(%@): videoNode=%p refs torn down — restoring saved layer=%p player=%p (rate=%.2f wasPlaying=%@ inTree=%d)",
                  reason, videoNode, savedLayer, savedPlayer,
                  [savedPlayer rate], wasPlaying, savedInTree);

        if (!savedInTree) {
            ReparentPlayerLayerIntoVideoNodeLayer(savedLayer, vnLayer);
        }

        // Same resume gate as the normal path: only a video that was playing
        // at the last viewWillDisappear capture may come back playing —
        // teardown is not proof this cell was the transitioned video (all
        // offscreen cells can be torn down), and a player the user stopped
        // via PiP close must stay stopped.
        if ([savedPlayer rate] == 0.0f && [wasPlaying boolValue]
            && !PlayerWasDeliberatelyStopped(savedPlayer)) {
            ApolloLog(@"[VideoUnmute] SearchReclaim(%@): resuming restored player", reason);
            [savedPlayer play];
            // Keep the flag truthful for the trailing re-check of this same
            // transition (the mute dance may re-pause it once more; the node
            // re-adopts the grafted layer synchronously — the ASDK fork's
            // playerLayer getter scans sublayers — so that pass takes the
            // normal path).
            objc_setAssociatedObject(richMediaNode, kSearchWasPlayingKey, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NoteSearchResumeMaybeAudible(videoNode, savedPlayer);
        }

        // One-shot: the refs are consumed. The synchronous re-adoption above
        // means the next capture re-saves fresh refs from the node itself;
        // keeping consumed refs would let a much later pass resurrect a
        // player Apollo has long since released.
        ClearSearchSavedRefs(richMediaNode);
        return YES;
    }

    ClearDeliberatelyStoppedMarkIfPlaying(player);

    // A PiP-owned player intentionally lives off-cell in the floating card —
    // reclaiming it would rip the video out of the card.
    if (ApolloPiP_IsOwnedPlayer(player)) return YES;

    BOOL inTree = LayerIsInLayerTreeOf(pLayer, vnLayer);

    BOOL shareable = NO;
    SEL shareableSel = NSSelectorFromString(@"allowPlayerLayerToBeShareable");
    if ([videoNode respondsToSelector:shareableSel]) {
        shareable = ((BOOL (*)(id, SEL))objc_msgSend)(videoNode, shareableSel);
    }

    ApolloLog(@"[VideoUnmute] SearchReclaim(%@): videoNode=%p player=%p rate=%.2f muted=%d inTree=%d shareable=%d",
              reason, videoNode, player, [player rate], [player isMuted], inTree, shareable);

    BOOL didReparent = !inTree;
    if (!inTree) {
        ReparentPlayerLayerIntoVideoNodeLayer(pLayer, vnLayer);

        SyncMuteButtonIcon(richMediaNode, [player isMuted]);

        // NOTE: the native reclaim also calls setAllowPlayerLayerToBeShareable:NO
        // here, but it does so hand-in-hand with clearing the VideoSharingManager
        // registration (Swift-only, unreachable for us). Setting the flag alone
        // creates a hybrid state Apollo never produces: the next fullscreen tap
        // takes the non-shared path and tears down the inline player entirely
        // (the frozen "playerLayer=0x0" cycles observed on device). Leaving the
        // flag as-is keeps the node in the same "sharing active" state it has
        // during normal inline playback, which the share setup handles fine on
        // re-entry. Cost: the native unpause handler keeps skipping this node
        // after mute dances — covered by the resume below + post-dance pass.
    }

    // Transitions away from this cell force-pause the player (the mute
    // dance's T+0 pause fires async from MediaPageVC.viewDidDisappear /
    // TouchHintVideoNode.didExitVisibleState) and its T+100ms unpause skips
    // shareable nodes. Resume a paused player ONLY when this cell was the
    // one involved in the transition (its layer needed re-parenting) or it
    // was playing when the search VC left the window (viewWillDisappear
    // capture) — and never one the user deliberately stopped. A video Apollo
    // paused because it is not at the table midpoint must STAY paused —
    // force-playing it leaves a stray player that breaks Apollo's
    // one-at-a-time autoplay bookkeeping while scrolling.
    if ([player rate] == 0.0f) {
        if ((didReparent || [wasPlaying boolValue]) && !PlayerWasDeliberatelyStopped(player)) {
            ApolloLog(@"[VideoUnmute] SearchReclaim(%@): resuming force-paused player (didReparent=%d wasPlaying=%@)",
                      reason, didReparent, wasPlaying);
            [player play];
            // Keep the flag truthful for the trailing re-check of this
            // same transition (the dance may re-pause it once more).
            objc_setAssociatedObject(richMediaNode, kSearchWasPlayingKey, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NoteSearchResumeMaybeAudible(videoNode, player);
        } else {
            ApolloLog(@"[VideoUnmute] SearchReclaim(%@): leaving paused player alone (wasPlaying=%@ stopped=%d)",
                      reason, wasPlaying, PlayerWasDeliberatelyStopped(player));
        }
    }
    return YES;
}

// Save the playback refs of every visible video cell. Runs when the search VC
// is about to leave the window (fullscreen presentation / comments push) — the
// SINGLE writer of the saved refs and the wasPlaying flag, and it always runs
// before any offscreen teardown can occur.
static void CaptureSearchResultsPlayerRefs(UIViewController *searchVC) {
    UITableView *tableView = GetTableViewFromViewController(searchVC);
    if (!tableView) return;

    EnumerateVisibleRichMediaNodes(tableView, ^(id richMediaNode) {
        id videoNode = GetVideoNodeFromRichMediaNode(richMediaNode);
        if (!videoNode) return;

        AVPlayerLayer *pLayer = GetPlayerLayerFromVideoNode(videoNode);
        AVPlayer *player = [pLayer player];
        if (!pLayer || !player) return;

        // A PiP-owned player lives in the floating card; its lifecycle is the
        // card's business — never capture it for a later restore.
        if (ApolloPiP_IsOwnedPlayer(player)) return;

        ClearDeliberatelyStoppedMarkIfPlaying(player);

        objc_setAssociatedObject(richMediaNode, kSearchSavedPlayerLayerKey, pLayer,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(richMediaNode, kSearchSavedPlayerKey, player,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Pre-transition truth for the resume gating: only a video that was
        // playing when the view left the window may be force-resumed by the
        // fixup passes.
        BOOL isPlaying = [player rate] != 0.0f;
        objc_setAssociatedObject(richMediaNode, kSearchWasPlayingKey, @(isPlaying),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[VideoUnmute] SearchReclaim(capture): saved layer=%p player=%p playing=%d for videoNode=%p",
                  pLayer, player, isPlaying, videoNode);
    });
}

// One pass over the visible cells. Returns YES when any cell hosts a video
// node (i.e. a trailing re-check could have something to do).
static BOOL ReclaimSearchResultsPlayerLayersOnce(UIViewController *searchVC, NSString *reason) {
    UITableView *tableView = GetTableViewFromViewController(searchVC);
    if (!tableView) {
        ApolloLog(@"[VideoUnmute] SearchReclaim(%@): no tableView found on %@", reason, [searchVC class]);
        return NO;
    }

    // Without disabling actions, Core Animation would interpolate the
    // re-parent + frame change mid-transition (visible "zoom" artifact —
    // same reason ApolloVideoSwipeFix wraps its deferred reclaim).
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    __block BOOL sawVideoCell = NO;
    EnumerateVisibleRichMediaNodes(tableView, ^(id richMediaNode) {
        if (FixupSearchCellRichMediaNode(richMediaNode, reason)) {
            sawVideoCell = YES;
        }
    });

    [CATransaction commit];
    return sawVideoCell;
}

// Pending trailing re-check bookkeeping: a newer scheduled re-check
// supersedes any older pending one, so the two lifecycle callbacks of a
// single pop produce ONE trailing pass, anchored at the later (safer) time.
static NSUInteger sSearchReclaimRecheckGeneration = 0;

static void ClearSearchWasPlayingFlags(UIViewController *searchVC) {
    UITableView *tableView = GetTableViewFromViewController(searchVC);
    if (!tableView) return;
    EnumerateVisibleRichMediaNodes(tableView, ^(id richMediaNode) {
        objc_setAssociatedObject(richMediaNode, kSearchWasPlayingKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

// The mute dance triggered by the same transition runs asynchronously
// (T+0 pauseAll ... T+100ms unpauseAll after MediaPageVC.viewDidDisappear or
// the comments header's didExitVisibleState, the latter firing near POP
// COMPLETION — up to ~350ms after viewWillAppear). Its pause can land after
// an immediate pass, re-freezing the video it just resumed (observed on
// device). One re-check after the dance window has fully settled fixes the
// race; it is idempotent when nothing changed.
static void ScheduleSearchReclaimRecheck(UIViewController *searchVC, NSString *reason) {
    NSUInteger generation = ++sSearchReclaimRecheckGeneration;
    __weak UIViewController *weakVC = searchVC;
    NSString *recheckReason = [reason stringByAppendingString:@" post-dance"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != sSearchReclaimRecheckGeneration) return;  // superseded
        UIViewController *strongVC = weakVC;
        if (!strongVC || ![[strongVC viewIfLoaded] window]) return;
        ReclaimSearchResultsPlayerLayersOnce(strongVC, recheckReason);
        // The transition is over: drop the pre-transition wasPlaying flags so
        // no later pass can resume a video Apollo has since paused (e.g. the
        // user scrolled and the midpoint moved) off stale data.
        ClearSearchWasPlayingFlags(strongVC);
    });
}

static void ReclaimSearchResultsPlayerLayers(UIViewController *searchVC, NSString *reason) {
    if (ReclaimSearchResultsPlayerLayersOnce(searchVC, reason)) {
        ScheduleSearchReclaimRecheck(searchVC, reason);
    }
}

// PostsSearchResultsViewController implements neither viewWillAppear: nor
// viewDidAppear: (that is the bug) — these hooks land on the class itself and
// %orig dispatches to the inherited superclass implementation.
%group SearchResultsReclaim

%hook PostsSearchResultsViewController

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    // The view is about to leave the window (comments push or fullscreen
    // presentation). Snapshot playback refs now: a non-shared fullscreen
    // entry tears down the videoNode's playerLayer/player while offscreen,
    // and the restore path needs the refs from before that happens.
    CaptureSearchResultsPlayerRefs((UIViewController *)self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;

    UINavigationController *nav = [(UIViewController *)self navigationController];
    id<UIViewControllerTransitionCoordinator> coordinator = nav ? [nav transitionCoordinator] : nil;

    // Interactive pop in progress: defer to the commit callback. Reclaiming
    // now would steal the layer from the still-visible comments header, and a
    // cancelled gesture would leave IT grey (the bug ApolloVideoSwipeFix
    // exists to prevent on the main feed). No from-VC class check needed —
    // the reclaim is a no-op unless a visible cell has a disconnected layer.
    if (coordinator && [coordinator isInteractive]) {
        __weak UIViewController *weakSelf = (UIViewController *)self;
        [coordinator notifyWhenInteractionChangesUsingBlock:
            ^(id<UIViewControllerTransitionCoordinatorContext> context) {
                if ([context isCancelled]) return;
                UIViewController *strongSelf = weakSelf;
                if (!strongSelf) return;
                ReclaimSearchResultsPlayerLayers(strongSelf, @"interactive pop commit");
            }];
        return;
    }

    // Mid-fullscreen-dismissal (presentedViewController still set): the layer
    // is animating in the transition container — viewDidAppear handles it.
    // Same gate the native reclaim loop applies per section controller.
    if ([nav presentedViewController]) return;

    ReclaimSearchResultsPlayerLayers((UIViewController *)self, @"viewWillAppear");
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    // Apollo's own viewDidAppear reclaim body (sub_100599fe4) runs the
    // reclaim precisely when presentedViewController is STILL the dismissing
    // MediaPageViewController: UIKit keeps the presentation registered until
    // after the presenter's viewDidAppear, so during a fullscreen dismissal
    // this is the only appearance callback where the layer is free to take
    // back. Any other modal (e.g. a share sheet) means no dismissal of the
    // media viewer is happening — leave the layer alone.
    UINavigationController *nav = [(UIViewController *)self navigationController];
    UIViewController *presented = [nav presentedViewController];
    if (presented) {
        Class mediaPageVCClass = MediaPageViewControllerClass();
        if (!mediaPageVCClass || ![presented isKindOfClass:mediaPageVCClass]) return;
        ReclaimSearchResultsPlayerLayers((UIViewController *)self, @"fullscreen dismissal");
        return;
    }

    // Plain pop: viewWillAppear (or the interactive-commit callback) already
    // ran the immediate pass. Only (re)schedule the trailing re-check — its
    // completion-anchored timing is the one that reliably outlasts a mute
    // dance triggered at pop completion (didExitVisibleState), and the
    // generation counter supersedes the earlier-scheduled one so a pop ends
    // with a single trailing pass.
    ScheduleSearchReclaimRecheck((UIViewController *)self, @"viewDidAppear");
}

%end

%end

// =============================================================================
// MARK: - Constructor
// =============================================================================

%ctor {
    Class richMediaHeaderCellClass = objc_getClass("_TtC6Apollo23RichMediaHeaderCellNode");
    Class commentsHeaderCellClass = objc_getClass("_TtC6Apollo22CommentsHeaderCellNode");
    Class richMediaNodeClass = objc_getClass("_TtC6Apollo13RichMediaNode");
    Class mediaPageVCClass = MediaPageViewControllerClass();
    Class mediaViewerAnimClass = objc_getClass("_TtC6Apollo30MediaViewerAnimationController");

    ApolloLog(@"[VideoUnmute] ctor: RichMediaHeaderCellNode=%p, CommentsHeaderCellNode=%p, RichMediaNode=%p, MediaPageVC=%p, MediaViewerAnimCtrl=%p",
              (void *)richMediaHeaderCellClass, (void *)commentsHeaderCellClass, (void *)richMediaNodeClass,
              (void *)mediaPageVCClass, (void *)mediaViewerAnimClass);

    if (!richMediaHeaderCellClass || !commentsHeaderCellClass || !richMediaNodeClass
        || !mediaPageVCClass || !mediaViewerAnimClass) {
        ApolloLog(@"[VideoUnmute] ctor: FATAL - required classes not found!");
        return;
    }

    %init(
        RichMediaHeaderCellNode = richMediaHeaderCellClass,
        CommentsHeaderCellNode = commentsHeaderCellClass,
        RichMediaNode = richMediaNodeClass,
        MediaPageViewController = mediaPageVCClass,
        MediaViewerAnimationController = mediaViewerAnimClass
    );

    Class searchResultsVCClass = objc_getClass("_TtC6Apollo32PostsSearchResultsViewController");
    if (searchResultsVCClass) {
        %init(SearchResultsReclaim, PostsSearchResultsViewController = searchResultsVCClass);
        ApolloLog(@"[VideoUnmute] ctor: search results playerLayer reclaim installed");
    }

    ApolloLog(@"[VideoUnmute] ctor: hooks initialized");
}
