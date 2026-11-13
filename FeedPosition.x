// Keep feed position.
//
// While the app is running: Reddit reloads Home, and jumps back to the top, when the app returns after
// 10 minutes or more in the background (the time comes from the ios_ads_feed_refresh_timeouts
// experiment; its longest group is 20 minutes). The check runs in Swift, but it only happens after
// Reddit's scene delegate passes on sceneWillResignActive:. Skipping that call leaves the feed where it
// was. UIKit's own resign notifications still go out, and pull to refresh and tapping Home twice still
// refresh.
//
// After iOS closes the app in the background: FeedCache.m keeps the pages of Home's feeds (For You,
// Following, Popular, and Latest from the side menu), and this notes which post is at the top of each
// when the app goes to the background, from the posts' accessibility labels ("r/sub, title, 12 upvotes,
// ..."), and how far into it you'd scrolled. After the next launch each feed shows its kept posts from the top when it first
// loads, and this scrolls it back to that post before it's drawn (the list is hidden until then), so
// scrolling up goes back through what you'd seen. Popular and Latest from the side menu are the exception:
// the side menu opens them fresh, so they only come back when Reopen community and post reopens them.
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import "FeedCache.h"
#import "FeedPosition.h"

@interface RFSceneDelegate : NSObject
@end

@interface RFListCollectionView : UICollectionView
@end

// Reddit's own feed screens (Popular, Latest from the side menu, News, Games): all one class.
@interface RFBridgedFeedScreen : UIViewController
@end

static BOOL gKeepFeedPosition;
static NSHashTable<UICollectionView *> *gFeedLists; // main thread only


static void RFFeedCancelAll(void);

void RFSetKeepFeedPosition(BOOL keep) {
  gKeepFeedPosition = keep;
  RFFeedCacheSetEnabled(keep);
  if (!keep) dispatch_async(dispatch_get_main_queue(), ^{
    RFFeedCancelAll();
  });
}

%group RFSceneDelegateHooks
%hook RFSceneDelegate
- (void)sceneWillResignActive:(UIScene *)scene {
  if (!gKeepFeedPosition) %orig;
}
%end
%end

// One of Reddit's own feed screens: a child of Home where the account still has the For You, Following and
// Popular tabs, or a screen pushed on a tab by the side menu's rows (Popular, Latest). A pushed one starts
// at the top, so its kept feed only comes back when the restore reopens it (FeedCache.m).
%group RFBridgedFeedScreenHooks
%hook RFBridgedFeedScreen
- (void)viewDidLoad {
  %orig;
  UIViewController *screen = (UIViewController *)self;
  UINavigationController *nav = screen.navigationController;
  if (nav && [nav.viewControllers indexOfObjectIdenticalTo:screen] != NSNotFound) RFFeedCacheNotePushedFeedScreen();
}
%end
%end

// Every list Reddit builds with SliceKit (Home's feeds among them), so the one showing Home can be read
// even while a post is open on top of it.
%group RFFeedListHooks
%hook RFListCollectionView
- (void)didMoveToWindow {
  %orig;
  UICollectionView *list = (UICollectionView *)self;
  if (list.window) [gFeedLists addObject:list];
}
%end
%end

// The accessibility label of a feed cell: its post card's, which is the first one under the cell.
NSString *RFCellLabel(UICollectionViewCell *cell) {
  if (!cell.contentView) return nil;
  NSMutableArray<UIView *> *level = [NSMutableArray arrayWithObject:cell.contentView];
  for (int depth = 0; depth < 3 && level.count; depth++) {
    NSMutableArray<UIView *> *next = [NSMutableArray array];
    for (UIView *view in level) {
      NSString *label = view.accessibilityLabel;
      if (label.length) return label;
      [next addObjectsFromArray:view.subviews];
    }
    level = next;
  }
  return nil;
}

// Whether a feed cell is a post card: it has the vote bar (Community highlights and carousel cards
// don't). Read from the views, not the label's words, so it works in any app language.
static BOOL RFIsPostCard(UICollectionViewCell *cell, NSString *label) {
  static Class actionBar;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    actionBar = NSClassFromString(@"RedditSliceKit_RPLActionBarSlice.RPLActionBarSliceView");
  });
  if (!label.length || !cell.contentView) return NO;
  // Without the class (a later Reddit), the English label's votes.
  if (!actionBar) return [label rangeOfString:@"upvote" options:NSCaseInsensitiveSearch].location != NSNotFound;
  NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:cell.contentView];
  for (NSUInteger seen = 0; queue.count && seen < 120; seen++) {
    UIView *view = queue.firstObject;
    [queue removeObjectAtIndex:0];
    if ([view isKindOfClass:actionBar]) return YES;
    [queue addObjectsFromArray:view.subviews];
  }
  return NO;
}

// The top of what's on screen in a list (below the bars it scrolls under), in its own coordinates.
CGFloat RFVisibleTop(UICollectionView *list) { return list.contentOffset.y + list.adjustedContentInset.top; }

NSArray<UICollectionViewCell *> *RFCellsTopFirst(UICollectionView *list) {
  return [list.visibleCells sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
    return [@(CGRectGetMinY(a.frame)) compare:@(CGRectGetMinY(b.frame))];
  }];
}

// The labels of the first few posts on screen in a list, top first, with how far each is above the
// top of the screen. A post that's mostly scrolled past doesn't count.
static NSArray<NSString *> *RFTopLabels(UICollectionView *list, NSMutableArray<NSNumber *> *offsets) {
  CGFloat top = RFVisibleTop(list);
  NSMutableArray<NSString *> *labels = [NSMutableArray array];
  for (UICollectionViewCell *cell in RFCellsTopFirst(list)) {
    // Pinned posts can sit in the list as empty slivers (they're shown in Community highlights).
    if (cell.hidden || CGRectGetHeight(cell.frame) < 40 || CGRectGetMidY(cell.frame) < top) continue;
    // Only post cards: not Community highlights and its cards, which have no votes.
    NSString *label = RFCellLabel(cell);
    if (!RFIsPostCard(cell, label)) continue;
    [labels addObject:label];
    [offsets addObject:@(top - CGRectGetMinY(cell.frame))];
    if (labels.count == 6) break;
  }
  return labels;
}

static BOOL gNotedSinceActive; // main thread; noted once per trip away (inactive, then background)

static void RFNoteLeaving(void) {
  if (!gKeepFeedPosition || gNotedSinceActive) return;
  gNotedSinceActive = YES;
  NSMutableArray<NSArray<NSString *> *> *lists = [NSMutableArray array];
  NSMutableArray<NSArray<NSNumber *> *> *offsetLists = [NSMutableArray array];
  for (UICollectionView *list in gFeedLists.allObjects) {
    NSMutableArray<NSNumber *> *offsets = [NSMutableArray array];
    NSArray<NSString *> *labels = RFTopLabels(list, offsets);
    if (!labels.count) continue;
    [lists addObject:labels];
    [offsetLists addObject:offsets];
  }
  UIApplication *app = UIApplication.sharedApplication;
  __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
  void (^finish)(void) = ^{
    dispatch_async(dispatch_get_main_queue(), ^{
      if (task == UIBackgroundTaskInvalid) return;
      [app endBackgroundTask:task];
      task = UIBackgroundTaskInvalid;
    });
  };
  task = [app beginBackgroundTaskWithName:@"RedditFilter feed position" expirationHandler:finish];
  RFFeedCacheNoteLeaving(lists, offsetLists, finish);
}

#pragma mark - Scrolling back after a relaunch

// Whether a list is showing a feed's replayed posts: all its posts on screen are replayed ones, bar one
// (another tab can share the odd post). Gives the top one found and its place in the replayed feed.
static BOOL RFListShowsFeed(UICollectionView *list, NSString *feed, NSIndexPath **seen, NSUInteger *seenIndex) {
  NSUInteger labelled = 0, matched = 0;
  for (UICollectionViewCell *cell in RFCellsTopFirst(list)) {
    NSString *label = RFCellLabel(cell);
    // Only post cards count, not Community highlights or carousels. A replayed post is one (and its match
    // is remembered), so the views are only looked through for the others.
    NSUInteger index = label ? RFFeedCacheReplayedIndex(feed, label) : NSNotFound;
    if (index == NSNotFound && !RFIsPostCard(cell, label)) continue;
    labelled++;
    NSIndexPath *path = index == NSNotFound ? nil : [list indexPathForCell:cell];
    if (!path) continue;
    matched++;
    if (seen && !*seen) {
      *seen = path;
      if (seenIndex) *seenIndex = index;
    }
  }
  return matched > 0 && (matched == labelled || (matched >= 2 && matched + 1 >= labelled));
}

// Moves a list as if it was dragged there, when asDrag: a community's screen puts its list back at the
// top after any other scroll (and only then folds its header away).
static void RFSetOffset(UICollectionView *list, CGFloat y, BOOL asDrag) {
  id<UIScrollViewDelegate> delegate = asDrag ? list.delegate : nil;
  if ([delegate respondsToSelector:@selector(scrollViewWillBeginDragging:)]) [delegate scrollViewWillBeginDragging:list];
  list.contentOffset = CGPointMake(list.contentOffset.x, y);
  if ([delegate respondsToSelector:@selector(scrollViewDidEndDragging:willDecelerate:)])
    [delegate scrollViewDidEndDragging:list willDecelerate:NO];
}

RFScrollResult RFScrollListToItem(UICollectionView *list, NSIndexPath *path, double offset, BOOL asDrag,
                                  BOOL (^isTarget)(UICollectionViewCell *cell)) {
  // Scrolled already: leave it be.
  if (list.isTracking || list.isDragging || list.isDecelerating) return RFScrollDone;
  if (path.section >= list.numberOfSections || path.item < 0 || path.item >= [list numberOfItemsInSection:path.section])
    return RFScrollDone;
  // Brings the item on screen first (items are sized as they're laid out, so its place isn't known
  // until then), then lines it up from where its cell really is. Uses the plain contentOffset setter:
  // SliceKit's list overrides setContentOffset:animated: (which scrollToItemAtIndexPath: uses too),
  // and at times turns it into an animation that never gets anywhere.
  CGFloat minY = -list.adjustedContentInset.top;
  CGFloat maxY = MAX(minY, list.contentSize.height + list.adjustedContentInset.bottom - list.bounds.size.height);
  UICollectionViewCell *cell = [list cellForItemAtIndexPath:path];
  if (!cell) {
    UICollectionViewLayoutAttributes *attributes = [list layoutAttributesForItemAtIndexPath:path];
    if (!attributes) return RFScrollDone;
    CGFloat y = CGRectGetMinY(attributes.frame) + offset - list.adjustedContentInset.top;
    RFSetOffset(list, MIN(MAX(y, minY), maxY), asDrag);
    [list layoutIfNeeded];
    cell = [list cellForItemAtIndexPath:path];
    if (!cell) return RFScrollPending;
    maxY = MAX(minY, list.contentSize.height + list.adjustedContentInset.bottom - list.bounds.size.height);
  }
  CGFloat y = list.contentOffset.y + CGRectGetMinY(cell.frame) + offset - RFVisibleTop(list);
  y = MIN(MAX(y, minY), maxY);
  if (fabs(y - list.contentOffset.y) >= 0.5) {
    RFSetOffset(list, y, asDrag);
    [list layoutIfNeeded];
    cell = [list cellForItemAtIndexPath:path];
  }
  if (!cell || !isTarget(cell)) return RFScrollPending;
  // In place once it's as far up as it was (or as far as the list goes).
  CGFloat shownOffset = RFVisibleTop(list) - CGRectGetMinY(cell.frame);
  BOOL atEdge = list.contentOffset.y >= maxY - 1 || list.contentOffset.y <= minY + 1;
  return fabs(shownOffset - offset) < 2 || atEdge ? RFScrollPlaced : RFScrollPending;
}

// Tries to scroll one list back to a feed's noted post. The list's items are the replayed posts in
// order, but it can have other items first (a header), so the gap between a post's item and its place
// in the kept feed is measured from a post on screen.
static RFScrollResult RFScrollList(UICollectionView *list, NSString *feed) {
  NSUInteger target;
  double offset;
  if (!RFFeedCacheRestoreTarget(feed, &target, &offset)) return RFScrollDone;
  if (!list.window || list.hidden) return RFScrollNotHere;
  NSIndexPath *seen = nil;
  NSUInteger seenIndex = NSNotFound;
  if (!RFListShowsFeed(list, feed, &seen, &seenIndex)) return RFScrollNotHere;
  // Measured from the post on screen nearest the noted one (the noted one itself once it's there): some
  // cards take two items (Suggested communities), so the gap is only right nearby.
  for (UICollectionViewCell *cell in list.visibleCells) {
    NSString *label = RFCellLabel(cell);
    NSUInteger index = label ? RFFeedCacheReplayedIndex(feed, label) : NSNotFound;
    NSIndexPath *path = index == NSNotFound ? nil : [list indexPathForCell:cell];
    if (!path) continue;
    NSUInteger gap = index > target ? index - target : target - index;
    NSUInteger seenGap = seenIndex > target ? seenIndex - target : target - seenIndex;
    if (gap >= seenGap) continue;
    seen = path;
    seenIndex = index;
  }
  NSInteger item = seen.item + ((NSInteger)target - (NSInteger)seenIndex);
  if (item < 0) return RFScrollDone;
  return RFScrollListToItem(list, [NSIndexPath indexPathForItem:item inSection:seen.section], offset,
                            [feed isEqualToString:@"SubredditFeedSdui"], ^BOOL(UICollectionViewCell *cell) {
                              NSString *label = RFCellLabel(cell);
                              return label && RFFeedCacheReplayedIndex(feed, label) == target;
                            });
}

// Main thread only. When a feed's replayed page arrives, the feed list on screen is hidden until it's
// scrolled back, so neither the top of the feed nor the jump is seen. Its posts' labels fill in a
// moment after it lays out, so that's the only way to hide it from the first frame.
static NSMutableDictionary<NSString *, NSDate *> *gRestoreStarted; // feed -> when its replay arrived
static NSMapTable<NSString *, UICollectionView *> *gHiddenLists;   // feed -> its hidden list
static NSMutableDictionary<NSString *, NSDate *> *gHiddenSince;    // feed -> when its list was hidden
static NSMutableDictionary<NSString *, NSDate *> *gShown; // feed -> when its list first showed the replayed posts
static NSMutableSet<NSString *> *gPlaced; // feeds whose noted post was in place last frame
static CADisplayLink *gRestoreTicker;
// Once in place, a feed is held there a moment: a community's feed can still put things above the post
// (Suggested communities arrives late), which would push it down. Ends early if the list's touched.
static NSMutableDictionary<NSString *, NSDate *> *gHoldUntil;    // feed -> end of its hold
static NSMapTable<NSString *, UICollectionView *> *gHeldLists;   // feed -> its list
static const NSTimeInterval kRFHoldTime = 1.2;
// Feeds whose screen is covered by others the restore opened on top (Home under a community or post, a
// community under a post): scrolled back when their screen's on top again (RFFeedUndefer).
static NSMutableSet<NSString *> *gDeferred;

NSArray<UICollectionView *> *RFFeedLists(void) { return gFeedLists.allObjects ?: @[]; }

BOOL RFFeedRestoring(void) { return gRestoreStarted.count > 0; }


// Whether another feed than this one has the list hidden (one feed owns a list's hiding at a time).
static BOOL RFHiddenByOther(NSString *feed, UICollectionView *list) {
  for (NSString *other in gHiddenLists.keyEnumerator)
    if (![other isEqualToString:feed] && [gHiddenLists objectForKey:other] == list) return YES;
  return NO;
}

static void RFHide(NSString *feed, UICollectionView *list, NSDate *now) {
  if (!list || RFHiddenByOther(feed, list)) return;
  list.alpha = 0;
  [gHiddenLists setObject:list forKey:feed];
  gHiddenSince[feed] = now;
}

static void RFUnhide(NSString *feed) {
  UICollectionView *list = [gHiddenLists objectForKey:feed];
  [gHiddenLists removeObjectForKey:feed];
  if (list && !RFHiddenByOther(feed, list)) list.alpha = 1;
  [gHiddenSince removeObjectForKey:feed];
  [gShown removeObjectForKey:feed];
  [gPlaced removeObject:feed];
}

static void RFEndScrollBack(NSString *feed) {
  RFFeedCacheEndRestore(feed);
  RFUnhide(feed);
  [gRestoreStarted removeObjectForKey:feed];
  [gHoldUntil removeObjectForKey:feed];
  [gHeldLists removeObjectForKey:feed];
  if (!gRestoreStarted.count) {
    [gRestoreTicker invalidate];
    gRestoreTicker = nil;
  }
}

// The feed list taking up most of the screen, if any.
UICollectionView *RFListOnScreen(void) {
  UICollectionView *best = nil;
  CGFloat bestArea = 0;
  for (UICollectionView *list in gFeedLists.allObjects) {
    UIWindow *window = list.window;
    if (!window || list.hidden || list.alpha < 0.01) continue;
    CGRect shown = CGRectIntersection([list convertRect:list.bounds toView:nil], window.bounds);
    CGFloat area = CGRectIsNull(shown) ? 0 : shown.size.width * shown.size.height;
    if (area <= bestArea || area < window.bounds.size.width * window.bounds.size.height / 3) continue;
    best = list;
    bestArea = area;
  }
  return best;
}

// Tries each feed still due. Runs every frame until they're all done.
static void RFScrollBack(void) {
  NSDate *now = NSDate.date;
  for (NSString *feed in gRestoreStarted.allKeys) {
    if (gHoldUntil[feed]) {
      // Holding: puts the post back if something moved it, until the time's up or the list's touched.
      UICollectionView *held = [gHeldLists objectForKey:feed];
      RFScrollResult result = held && !RFHiddenByOther(feed, held) ? RFScrollList(held, feed) : RFScrollDone;
      if (result == RFScrollDone || [now compare:gHoldUntil[feed]] == NSOrderedDescending) RFEndScrollBack(feed);
      continue;
    }
    RFScrollResult result = RFScrollNotHere;
    UICollectionView *hidden = [gHiddenLists objectForKey:feed];
    UICollectionView *placedList = hidden;
    if (hidden) {
      result = RFScrollList(hidden, feed);
      if (result != RFScrollNotHere && !gShown[feed]) gShown[feed] = now;
      // Hid the wrong list (or the feed is slow to show): show it again and look everywhere.
      else if (result == RFScrollNotHere && !gShown[feed] && [now timeIntervalSinceDate:gHiddenSince[feed]] > 1)
        RFUnhide(feed);
    } else {
      for (UICollectionView *list in gFeedLists.allObjects) {
        if (RFHiddenByOther(feed, list)) continue; // another feed's scrolling it back
        result = RFScrollList(list, feed);
        if (result == RFScrollNotHere) continue;
        placedList = list;
        if (result == RFScrollPending) {
          RFHide(feed, list, now);
          gShown[feed] = now;
        }
        break;
      }
    }
    // Finished once the post stays in place for two frames in a row (posts above it can still be
    // resizing as they're laid out).
    BOOL finished = result == RFScrollDone || (result == RFScrollPlaced && [gPlaced containsObject:feed]);
    if (result == RFScrollPlaced) [gPlaced addObject:feed];
    else [gPlaced removeObject:feed];
    // Gives up after 10s without the feed showing up, or 1.5s after it did, so it never stays blank.
    BOOL late = [now timeIntervalSinceDate:gRestoreStarted[feed]] > 10 ||
                (gShown[feed] && [now timeIntervalSinceDate:gShown[feed]] > 1.5);
    if (late || (finished && (result == RFScrollDone || !placedList))) {
      RFEndScrollBack(feed);
    } else if (finished) {
      RFUnhide(feed);
      [gHeldLists setObject:placedList forKey:feed];
      gHoldUntil[feed] = [now dateByAddingTimeInterval:kRFHoldTime];
    }
  }
}

@interface RFScrollBackTicker : NSObject
@end
@implementation RFScrollBackTicker
+ (void)tick:(CADisplayLink *)link {
  RFScrollBack();
}
@end

// After a feed's replayed page is handed over (before the list has it): hides the feed on screen and
// tries every frame.
static void RFStartScrollBackIn(NSString *feed, UICollectionView *list) {
  NSDate *now = NSDate.date;
  gRestoreStarted[feed] = now;
  [gHoldUntil removeObjectForKey:feed];
  RFUnhide(feed);
  if (list) RFHide(feed, list, now);
  if (gRestoreTicker) return;
  gRestoreTicker = [CADisplayLink displayLinkWithTarget:RFScrollBackTicker.class selector:@selector(tick:)];
  [gRestoreTicker addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

// Whether a list is a post page's (opened from a notification, say), which a feed is never on.
static BOOL RFIsPostPageList(UICollectionView *list) {
  static Class postScreen;
  if (!postScreen) postScreen = NSClassFromString(@"PDP_Impl.PDPViewController");
  for (UIResponder *node = list.nextResponder; node; node = node.nextResponder)
    if ([node isKindOfClass:UIViewController.class]) return postScreen && [node isKindOfClass:postScreen];
  return NO;
}

static void RFStartScrollBack(NSString *feed) {
  if (![feed isKindOfClass:NSString.class]) return;
  // Its screen's covered: done when it's back on top.
  if ([gDeferred containsObject:feed]) return;
  UICollectionView *list = RFListOnScreen();
  RFStartScrollBackIn(feed, list && !RFIsPostPageList(list) ? list : nil);
}

void RFFeedDefer(NSArray<NSString *> *feeds) {
  for (NSString *feed in feeds) {
    [gDeferred addObject:feed];
    if (!gRestoreStarted[feed]) continue;
    // Already under way: stops (its list has just been covered), keeping where it's going.
    RFUnhide(feed);
    [gRestoreStarted removeObjectForKey:feed];
    [gHoldUntil removeObjectForKey:feed];
    [gHeldLists removeObjectForKey:feed];
  }
  if (!gRestoreStarted.count) {
    [gRestoreTicker invalidate];
    gRestoreTicker = nil;
  }
}

void RFFeedUndefer(NSArray<NSString *> *feeds, UIViewController *screen) {
  // The screen's list that's showing (not one of Home's other tabs, nor the screen sliding out). The
  // screen may still be sliding in, so it's measured inside the screen rather than the window.
  UICollectionView *best = nil;
  CGFloat bestArea = 0;
  for (UICollectionView *list in gFeedLists.allObjects) {
    if (!list.window || ![list isDescendantOfView:screen.view]) continue;
    CGRect shown = CGRectIntersection([list convertRect:list.bounds toView:screen.view], screen.view.bounds);
    CGFloat area = CGRectIsNull(shown) ? 0 : shown.size.width * shown.size.height;
    if (area <= bestArea) continue;
    best = list;
    bestArea = area;
  }
  for (NSString *feed in feeds) {
    if (![gDeferred containsObject:feed]) continue;
    [gDeferred removeObject:feed];
    // No screen: given up (never went back to it).
    if (!screen) RFFeedCacheEndRestore(feed);
    // Scrolled back now if its replay came while covered; otherwise as usual when it comes.
    else if (RFFeedCacheRestoreTarget(feed, NULL, NULL)) RFStartScrollBackIn(feed, best);
  }
}

BOOL RFFeedHasDeferred(void) { return gDeferred.count > 0; }

// Stops every scroll back, now and deferred (turned off, or another account).
static void RFFeedCancelAll(void) {
  for (NSString *feed in gRestoreStarted.allKeys) RFEndScrollBack(feed);
  for (NSString *feed in gDeferred) RFFeedCacheEndRestore(feed);
  [gDeferred removeAllObjects];
}


%ctor {
  Class sceneDelegate = NSClassFromString(@"_TtC6Reddit13SceneDelegate");
  if (sceneDelegate) %init(RFSceneDelegateHooks, RFSceneDelegate = sceneDelegate);
  Class list = NSClassFromString(@"_TtC8SliceKit18ListCollectionView");
  if ([list isSubclassOfClass:UICollectionView.class]) {
    gFeedLists = [NSHashTable weakObjectsHashTable];
    %init(RFFeedListHooks, RFListCollectionView = list);
    // Also when the app only goes inactive: from the app switcher, it can be swiped away (and killed)
    // without ever going to the background.
    for (NSNotificationName name in @[ UIApplicationWillResignActiveNotification, UIApplicationDidEnterBackgroundNotification ])
      [NSNotificationCenter.defaultCenter addObserverForName:name
                                                      object:nil
                                                       queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(NSNotification *note) {
                                                    RFNoteLeaving();
                                                  }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
                                                  gNotedSinceActive = NO;
                                                }];
    // Another account, incognito, or the kept feeds forgotten (filters changed): nothing's scrolled back.
    for (NSNotificationName name in @[ RFFeedCacheAccountDidChangeNotification, RFFeedCacheDidForgetNotification ])
      [NSNotificationCenter.defaultCenter addObserverForName:name
                                                      object:nil
                                                       queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(NSNotification *note) {
                                                    RFFeedCancelAll();
                                                  }];
    gRestoreStarted = [NSMutableDictionary dictionary];
    gHiddenSince = [NSMutableDictionary dictionary];
    gHiddenLists = [NSMapTable strongToWeakObjectsMapTable];
    gShown = [NSMutableDictionary dictionary];
    gHoldUntil = [NSMutableDictionary dictionary];
    gDeferred = [NSMutableSet set];
    gHeldLists = [NSMapTable strongToWeakObjectsMapTable];
    gPlaced = [NSMutableSet set];
    [NSNotificationCenter.defaultCenter addObserverForName:RFFeedCacheDidReplayNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
                                                  RFStartScrollBack(note.object);
                                                }];
  }
  Class feedScreen = NSClassFromString(@"FeedKit_LegacyBridge.BridgedFeedViewController");
  if ([feedScreen isSubclassOfClass:UIViewController.class]) %init(RFBridgedFeedScreenHooks, RFBridgedFeedScreen = feedScreen);
}
