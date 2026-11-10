// Restore open community and post.
//
// Keep feed position brings Home's feeds back after iOS closes Reddit in the background. This goes one
// step further: the communities, profiles and posts open on Home (in any order, a few deep), or on top
// of your own profile in the You tab, are opened again, and the top post offers to jump back to where
// you were in its comments.
//
// How the app was closed: iOS keeps a snapshot of the app's window for its card in the app switcher.
// When iOS closes the app in the background the card stays, and so does the snapshot; swiping the card
// away removes it. (The scene session survives both on iPhone, so its ID can't tell them apart.) What was
// kept (the feeds, and these screens) is only restored after iOS closed the app, unless Restore after
// swiping away is on.
//
// Screens are reopened with Reddit's own links (as if a reddit.com link was opened), which push onto
// Home: Home -> community -> post, so going back works as usual. For the You tab they're then moved over
// on top of your profile, and the tab's selected. While that happens a cover hides the app: for a feed or
// community, a picture of the screen as it was left, so you see where you were straight away.
//
// The community comes back in its default sort: Reddit's links don't carry one. Its kept posts are only
// replayed if they were in that sort.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <os/lock.h>
#import "FeedCache.h"
#import "FeedPosition.h"
#import "ScreenRestore.h"

typedef NS_ENUM(NSInteger, RFLastClose) {
  RFLastCloseUnknown,      // first launch with this, or nothing saved
  RFLastCloseByIOS,        // closed in the background by iOS (same scene session)
  RFLastCloseSwipedAway,   // swiped away in the app switcher (new scene session)
  RFLastCloseInForeground, // ended while open (a crash, or stopped from a computer)
};

// The whole restore gives up after this long, and each step after its own limit.
static const NSTimeInterval kRFRestoreMaxTime = 12; // a little more for each screen past two
static const NSUInteger kRFMaxScreens = 6;          // screens kept above Home or your profile
static const NSTimeInterval kRFStepMaxTime = 6;
static const NSTimeInterval kRFAccountWait = 8; // for the first request to say which account it is

static NSString *const kRFHomeClass = @"Home_Impl.PerFeedScreenviewHomeScreenViewController";
static NSString *const kRFCommunityClass = @"Subreddit_Internal.SubredditScreenViewController";
static NSString *const kRFProfileClass = @"Profiles.ProfileCoreStackViewController";
static NSString *const kRFPreviewClass = @"PreviewModeViewController.PreviewModeViewControllerImpl";
static NSString *const kRFPostClass = @"PDP_Impl.PDPViewController";
static NSString *const kRFYouTabID = @"reddit_tab_bar__profile_button";

static BOOL gRestoreScreens; // the setting; main thread, like the two below
static BOOL gAfterSwipe;       // restore even after Reddit was swiped away (or ended while open)
static NSTimeInterval gMaxAge = 12 * 60 * 60; // restore for this long after leaving; 0 = always
static BOOL gLaunchDecided;    // the scene has connected, so how the app was last closed is known
static RFLastClose gLastClose;
static NSDictionary *gLastSession; // Session.json as the previous run left it

// Comment rows of the last few posts opened, so the comment at the top of the screen can be named.
static os_unfair_lock gRowsLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, NSArray *> *gCommentRows; // post ID -> rows; guarded by gRowsLock
static NSMutableArray<NSString *> *gCommentPosts;                // oldest first; guarded by gRowsLock
static NSMutableSet<NSString *> *gTruncatedPosts;                // posts with only the first few comments; guarded by gRowsLock
static NSMutableDictionary<NSString *, NSDate *> *gRowsAt;        // when each post's rows came; guarded by gRowsLock
static NSMutableDictionary<NSString *, NSString *> *gCommentAccounts; // and the account that asked; guarded by gRowsLock

#pragma mark - Small helpers

static NSString *RFRestoreDirectory(void) {
  NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
  return [caches stringByAppendingPathComponent:@"RedditFilter"];
}
static NSString *RFRestorePath(NSString *file) { return [RFRestoreDirectory() stringByAppendingPathComponent:file]; }

static NSDictionary *RFReadJSON(NSString *file) {
  NSData *data = [NSData dataWithContentsOfFile:RFRestorePath(file)];
  id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  return [json isKindOfClass:NSDictionary.class] ? json : nil;
}

static dispatch_queue_t RFRestoreQueue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("RedditFilter.ScreenRestore", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

// Writes (or with nil, removes) a file now. Only on RFRestoreQueue.
static void RFWriteNow(NSString *file, NSData *data) {
  NSString *path = RFRestorePath(file);
  NSFileManager *fm = NSFileManager.defaultManager;
  if (data) {
    [fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    [data writeToFile:path options:NSDataWritingAtomic error:NULL];
  } else if ([fm fileExistsAtPath:path]) {
    [fm removeItemAtPath:path error:NULL];
  }
}

// Writes (or with nil, removes) a file in the background, in order with every other write.
static void RFWriteFile(NSString *file, NSData *data, void (^completion)(void)) {
  dispatch_async(RFRestoreQueue(), ^{
    RFWriteNow(file, data);
    if (completion) completion();
  });
}

// Removes what's kept of the open screens (turned off, incognito, another account).
static void RFForgetScreens(void) {
  dispatch_async(RFRestoreQueue(), ^{
    for (NSString *file in @[ @"Screens.json", @"LastScreen.jpg", @"Comments.json" ]) RFWriteNow(file, nil);
  });
}

static void RFWriteJSON(NSString *file, NSDictionary *json, void (^completion)(void)) {
  RFWriteFile(file, json ? [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL] : nil, completion);
}

static id RFCall(id object, NSString *getter) {
  SEL selector = NSSelectorFromString(getter);
  return [object respondsToSelector:selector] ? ((id(*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static NSString *RFCommunityName(id holder) {
  id subreddit = RFCall(holder, @"subreddit");
  id name = nil;
  @try {
    name = [subreddit valueForKey:@"displayName"];
  } @catch (NSException *e) {
  }
  return [name isKindOfClass:NSString.class] && [name length] ? name : nil;
}

// A Reddit username: what a profile link can be made from.
static BOOL RFIsUsername(id name) {
  static NSCharacterSet *other;
  if (!other) other = [NSCharacterSet characterSetWithCharactersInString:
                          @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"].invertedSet;
  return [name isKindOfClass:NSString.class] && [name length] >= 3 && [name length] <= 20 &&
         [name rangeOfCharacterFromSet:other].location == NSNotFound;
}

static const void *kRFProfileNameKey = &kRFProfileNameKey;
static UICollectionView *RFListIn(UIViewController *vc);

// A profile's username. Its Swift properties aren't readable, so it comes from the screen: the topmost
// "u/name" label (the header; "u/" isn't translated), or the English Share button's "Share name profile".
// Remembered on the screen once read (it's read as the profile appears), so scrolling the header away
// later doesn't lose it.
static NSString *RFProfileName(UIViewController *profile) {
  NSString *known = objc_getAssociatedObject(profile, kRFProfileNameKey);
  if (known) return known;
  UIView *root = profile.viewIfLoaded;
  if (!root) return nil;
  NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:root];
  NSString *best = nil, *shared = nil;
  CGFloat bestY = CGFLOAT_MAX;
  for (NSUInteger seen = 0; pending.count && seen < 600; seen++) {
    UIView *view = pending.firstObject;
    [pending removeObjectAtIndex:0];
    if (view.hidden) continue;
    NSString *text = [view isKindOfClass:UILabel.class] ? ((UILabel *)view).text : nil;
    if ([text hasPrefix:@"u/"] && RFIsUsername([text substringFromIndex:2])) {
      CGFloat y = [view convertPoint:CGPointZero toView:root].y;
      if (y < bestY) {
        best = [text substringFromIndex:2];
        bestY = y;
      }
    }
    NSString *label = view.accessibilityLabel;
    if (!shared && [label hasPrefix:@"Share "] && [label hasSuffix:@" profile"] && label.length > 14) {
      NSString *name = [label substringWithRange:NSMakeRange(6, label.length - 14)];
      if (RFIsUsername(name)) shared = name;
    }
    [pending addObjectsFromArray:view.subviews];
  }
  NSString *name = best ?: shared;
  // Remembered only while the profile's at its top, where the topmost "u/" is its header (further down
  // it can be a post's or a comment's).
  UICollectionView *list = RFListIn(profile);
  BOOL atTop = !list || list.contentOffset.y <= -list.adjustedContentInset.top + 40;
  if (name && atTop) objc_setAssociatedObject(profile, kRFProfileNameKey, name, OBJC_ASSOCIATION_COPY_NONATOMIC);
  return name;
}

static BOOL RFIsClass(id object, NSString *name) {
  // Looked up once per name: this runs many times on every tick of a restore. Main thread only.
  static NSMutableDictionary<NSString *, id> *classes;
  if (!classes) classes = [NSMutableDictionary dictionary];
  id class = classes[name];
  if (!class) {
    class = (id)NSClassFromString(name) ?: NSNull.null;
    classes[name] = class;
  }
  return class != NSNull.null && [object isKindOfClass:class];
}

static NSArray<UIWindow *> *RFWindows(void) {
  NSMutableArray *windows = [NSMutableArray array];
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
    if ([scene isKindOfClass:UIWindowScene.class]) [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
  return windows;
}

static NSString *RFCurrentSessionID(void) {
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
    if ([scene.session.role isEqualToString:UIWindowSceneSessionRoleApplication]) return scene.session.persistentIdentifier;
  return nil;
}

#pragma mark - How the app was last closed

// The newest app switcher snapshot iOS keeps for the app's window (Library/SplashBoard/Snapshots/
// sceneID:<bundle>-default/*.ktx), taken when the app last went to the background. Read before this
// launch can add one. Swiping the app away may remove it, as its card goes; iOS closing the app keeps it.
static NSDate *RFNewestSwitcherSnapshot(void) {
  NSString *library = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
  NSString *snapshots = [library stringByAppendingPathComponent:@"SplashBoard/Snapshots"];
  NSFileManager *fm = NSFileManager.defaultManager;
  NSDate *newest = nil;
  for (NSString *folder in [fm contentsOfDirectoryAtPath:snapshots error:NULL]) {
    if (![folder hasPrefix:@"sceneID:"]) continue;
    NSString *path = [snapshots stringByAppendingPathComponent:folder];
    for (NSString *file in [fm contentsOfDirectoryAtPath:path error:NULL]) {
      NSDate *date = [fm attributesOfItemAtPath:[path stringByAppendingPathComponent:file] error:NULL].fileModificationDate;
      if (date && (!newest || [date compare:newest] == NSOrderedDescending)) newest = date;
    }
  }
  return newest;
}

static NSDate *gSnapshotAtLaunch;    // newest switcher snapshot when this run started
static BOOL gSameSession;            // the same scene session as last time
static NSString *gSignals = @"";     // for Diagnostics
static NSString *gOutcome = @""; // what the restore at this launch did, for Diagnostics
static BOOL gReopened;       // the restore opened everything it set out to
static BOOL gStoppedForUser; // stopped for another account, incognito or turned off: nothing's moved to You
static NSString *gLeft = @""; // what was open when the app was last left (this run), for Diagnostics

// Saved on every trip to the background and back, whatever the settings (Diagnostics shows it).
static void RFSaveSession(BOOL background) {
  NSString *session = RFCurrentSessionID();
  if (!session) return;
  RFWriteJSON(@"Session.json",
              @{@"session" : session, @"background" : @(background), @"at" : @(NSDate.date.timeIntervalSince1970), @"left" : gLeft ?: @""},
              nil);
}

static void RFNoteLaunchSession(UISceneSession *session) {
  gSameSession = [gLastSession[@"session"] isEqual:session.persistentIdentifier];
  NSNumber *leftAt = gLastSession[@"at"];
  // The snapshot is taken a moment after the app goes to the background.
  BOOL snapshotKept = [leftAt isKindOfClass:NSNumber.class] && gSnapshotAtLaunch &&
                      gSnapshotAtLaunch.timeIntervalSince1970 >= leftAt.doubleValue - 2;
  gSignals = [NSString stringWithFormat:@"snapshot %@ · %@ session", snapshotKept ? @"kept" : @"gone",
                                        gSameSession ? @"same" : @"new"];
  if (!gLastSession) gLastClose = RFLastCloseUnknown;
  else if (![gLastSession[@"background"] boolValue]) gLastClose = RFLastCloseInForeground;
  else gLastClose = snapshotKept ? RFLastCloseByIOS : RFLastCloseSwipedAway;
}

// Whether this launch restores what was kept (the feeds, and the screens if that's on).
static BOOL RFMayRestore(void) { return gLastClose == RFLastCloseByIOS || gAfterSwipe; }

static void RFUpdateColdReplay(void) {
  if (gLaunchDecided) RFFeedCacheSetColdReplayAllowed(RFMayRestore());
}

static NSString *RFLastCloseName(void) {
  switch (gLastClose) {
    case RFLastCloseByIOS: return @"Closed by iOS";
    case RFLastCloseSwipedAway: return @"Swiped away";
    case RFLastCloseInForeground: return @"Crashed or stopped while open";
    default: return @"Unknown (first launch)";
  }
}

NSString *RFLastCloseDescription(void) {
  // "Closed by iOS · snapshot kept · same session", then one "Label: value" per line.
  NSString *first = gSignals.length ? [NSString stringWithFormat:@"%@ · %@", RFLastCloseName(), gSignals] : RFLastCloseName();
  NSMutableArray *lines = [NSMutableArray arrayWithObject:first];
  NSString *left = [gLastSession[@"left"] isKindOfClass:NSString.class] ? gLastSession[@"left"] : nil;
  if (left.length) [lines addObject:[@"Left open: " stringByAppendingString:left]];
  if (gOutcome.length) [lines addObject:[@"At launch: " stringByAppendingString:gOutcome]];
  return [lines componentsJoinedByString:@"\n"];
}

#pragma mark - Comments

BOOL RFScreenRestoreWantsComments(void) { return gRestoreScreens && RFFeedCacheEnabled(); }

// Notes a post's comments (as handed to the app) for the account that asked for them.
static void RFRecordComments(NSString *post, NSArray *rows, BOOL truncated, NSString *account) {
  os_unfair_lock_lock(&gRowsLock);
  // Another account's comments for this post (a late answer from before a switch): start it again.
  if (account && gCommentAccounts[post] && ![gCommentAccounts[post] isEqualToString:account]) {
    [gCommentRows removeObjectForKey:post];
    [gTruncatedPosts removeObject:post];
    [gRowsAt removeObjectForKey:post];
  }
  if (account) gCommentAccounts[post] = account;
  // Only the first few after all of them would lose the rest.
  if (truncated && gCommentRows[post] && ![gTruncatedPosts containsObject:post]) {
    os_unfair_lock_unlock(&gRowsLock);
    return;
  }
  if (truncated) [gTruncatedPosts addObject:post];
  else [gTruncatedPosts removeObject:post];
  gCommentRows[post] = rows;
  gRowsAt[post] = NSDate.date;
  [gCommentPosts removeObject:post];
  [gCommentPosts addObject:post];
  while (gCommentPosts.count > 5) {
    NSString *oldest = gCommentPosts.firstObject;
    [gCommentRows removeObjectForKey:oldest];
    [gTruncatedPosts removeObject:oldest];
    [gRowsAt removeObjectForKey:oldest];
    [gCommentAccounts removeObjectForKey:oldest];
    [gCommentPosts removeObjectAtIndex:0];
  }
  os_unfair_lock_unlock(&gRowsLock);
}

// The variables of a comments request, if it's for a post's comments from the start (not a later page).
static NSDictionary *RFCommentVariables(NSURLRequest *request) {
  NSDictionary *body = request.HTTPBody.length ? [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:NULL] : nil;
  NSDictionary *variables = [body isKindOfClass:NSDictionary.class] ? body[@"variables"] : nil;
  if (![variables isKindOfClass:NSDictionary.class] || variables[@"after"] || variables[@"cursor"]) return nil;
  NSString *post = variables[@"id"];
  return [post isKindOfClass:NSString.class] && [post hasPrefix:@"t3_"] ? variables : nil;
}

NSData *RFScreenRestoreCommentsPage(NSURLRequest *request, NSData *page) {
  NSDictionary *variables = RFCommentVariables(request);
  if (!variables || RFFeedCacheRequestIsIncognito(request)) return nil;
  NSArray *rows = RFCommentRows(page);
  // Reddit first asks for the first few comments (isTruncatedFetch), and for all of them once you get
  // near the comments. The first few are the start of the same list, so they do until then.
  if (rows)
    RFRecordComments(variables[@"id"], rows, [variables[@"isTruncatedFetch"] boolValue], RFFeedAccount(request));
  return nil;
}

// Forgets every post's comments (another account, incognito, or the comment filters changed).
void RFScreenRestoreForgetComments(void) {
  os_unfair_lock_lock(&gRowsLock);
  [gCommentRows removeAllObjects];
  [gCommentPosts removeAllObjects];
  [gTruncatedPosts removeAllObjects];
  [gRowsAt removeAllObjects];
  [gCommentAccounts removeAllObjects];
  os_unfair_lock_unlock(&gRowsLock);
}

static BOOL RFRowsTruncated(NSString *post) {
  os_unfair_lock_lock(&gRowsLock);
  BOOL truncated = [gTruncatedPosts containsObject:post];
  os_unfair_lock_unlock(&gRowsLock);
  return truncated;
}

// Whether a post's comments are all in: the whole list, or the first few with nothing more for a while
// (Reddit doesn't always ask for the rest).
static BOOL RFRowsSettled(NSString *post) {
  os_unfair_lock_lock(&gRowsLock);
  BOOL settled = gCommentRows[post] && (![gTruncatedPosts containsObject:post] ||
                                        -[gRowsAt[post] timeIntervalSinceNow] > 1.2);
  os_unfair_lock_unlock(&gRowsLock);
  return settled;
}

static NSArray *RFRowsForPost(NSString *post) {
  os_unfair_lock_lock(&gRowsLock);
  NSArray *rows = gCommentRows[post];
  os_unfair_lock_unlock(&gRowsLock);
  return rows;
}

static void RFForgetRows(NSString *post) {
  os_unfair_lock_lock(&gRowsLock);
  [gCommentRows removeObjectForKey:post];
  [gCommentPosts removeObject:post];
  [gTruncatedPosts removeObject:post];
  [gRowsAt removeObjectForKey:post];
  [gCommentAccounts removeObjectForKey:post];
  os_unfair_lock_unlock(&gRowsLock);
}

// Which of a post's comment rows a cell shows, the one nearest `near`: matched on the username label the
// cell shows (so it works in any app language), and on the English label's level when there is one.
static NSUInteger RFRowOfCommentCell(NSArray *rows, UICollectionViewCell *cell, NSUInteger near) {
  if (!rows || !cell.contentView) return NSNotFound;
  static NSCharacterSet *separators;
  if (!separators) separators = [NSCharacterSet characterSetWithCharactersInString:@" ,\u00a0"];
  NSMutableArray<NSString *> *texts = [NSMutableArray array], *words = [NSMutableArray array];
  NSString *label = nil;
  NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:cell.contentView];
  for (NSUInteger seen = 0; queue.count && seen < 80; seen++) {
    UIView *view = queue.firstObject;
    [queue removeObjectAtIndex:0];
    NSString *spoken = view.accessibilityLabel;
    if (!label && [spoken hasPrefix:@"By "]) label = spoken;
    // The comment's description names its author in any language ("von name, vor 1 Woche, ..."): its words
    // are candidates too (the username's own label can sit deeper than this looks).
    if (spoken.length && spoken.length <= 200)
      for (NSString *word in [spoken componentsSeparatedByCharactersInSet:separators])
        if (word.length >= 3 && word.length <= 20) [words addObject:word];
    NSString *text = [view isKindOfClass:UILabel.class] ? ((UILabel *)view).text : nil;
    if (text.length && text.length <= 40) [texts addObject:text];
    [queue addObjectsFromArray:view.subviews];
  }
  return RFCommentRowForCell(rows, texts, words, label, near);
}

#pragma mark - The screens open on Home

// The navigation stack of Home's tab, if it's the tab on screen.
static UINavigationController *RFHomeNavigation(void) {
  for (UIWindow *window in RFWindows()) {
    NSMutableArray<UIViewController *> *queue = [NSMutableArray array];
    if (window.rootViewController) [queue addObject:window.rootViewController];
    while (queue.count) {
      UIViewController *vc = queue.firstObject;
      [queue removeObjectAtIndex:0];
      if ([vc isKindOfClass:UINavigationController.class] && vc.viewIfLoaded.window &&
          RFIsClass(((UINavigationController *)vc).viewControllers.firstObject, kRFHomeClass))
        return (UINavigationController *)vc;
      [queue addObjectsFromArray:vc.childViewControllers];
    }
  }
  return nil;
}

static UITabBarController *RFTabBar(void) {
  for (UIWindow *window in RFWindows()) {
    NSMutableArray<UIViewController *> *queue = [NSMutableArray array];
    if (window.rootViewController) [queue addObject:window.rootViewController];
    while (queue.count) {
      UIViewController *vc = queue.firstObject;
      [queue removeObjectAtIndex:0];
      if ([vc isKindOfClass:UITabBarController.class]) return (UITabBarController *)vc;
      [queue addObjectsFromArray:vc.childViewControllers];
    }
  }
  return nil;
}

// The You tab's stack (your own profile at its root).
static UINavigationController *RFYouNavigation(UITabBarController *tabs) {
  for (UIViewController *tab in tabs.viewControllers)
    if ([tab isKindOfClass:UINavigationController.class] && [tab.tabBarItem.accessibilityIdentifier isEqualToString:kRFYouTabID])
      return (UINavigationController *)tab;
  return nil;
}

// The post screen in a pushed screen: itself, or the page on screen of a post pager.
static UIViewController *RFPostScreen(UIViewController *vc) {
  if (RFIsClass(vc, kRFPostClass)) return vc;
  if (!RFIsClass(vc, kRFPreviewClass)) return nil;
  UIViewController *best = nil;
  CGFloat bestArea = 0;
  NSMutableArray<UIViewController *> *queue = [vc.childViewControllers mutableCopy];
  while (queue.count) {
    UIViewController *child = queue.firstObject;
    [queue removeObjectAtIndex:0];
    // Measured in the pager, so a pager under other screens (not in the window) works too.
    if (RFIsClass(child, kRFPostClass) && child.isViewLoaded && vc.isViewLoaded && [child.view isDescendantOfView:vc.view]) {
      CGRect shown = CGRectIntersection([child.view convertRect:child.view.bounds toView:vc.view], vc.view.bounds);
      CGFloat area = CGRectIsNull(shown) ? 0 : shown.size.width * shown.size.height;
      if (area > bestArea) {
        best = child;
        bestArea = area;
      }
    }
    [queue addObjectsFromArray:child.childViewControllers];
  }
  return best;
}

// The SliceKit list inside a screen with the most on screen.
static UICollectionView *RFListIn(UIViewController *vc) {
  UICollectionView *best = nil;
  CGFloat bestArea = 0;
  for (UICollectionView *list in RFFeedLists()) {
    if (!list.window || ![list isDescendantOfView:vc.view]) continue;
    CGRect shown = CGRectIntersection([list convertRect:list.bounds toView:nil], list.window.bounds);
    CGFloat area = CGRectIsNull(shown) ? 0 : shown.size.width * shown.size.height;
    if (area > bestArea) {
      best = list;
      bestArea = area;
    }
  }
  return best;
}

// The comments list has a section per top-level thread (the comment, then its replies and "more
// replies" rows, then a thin separator), after the post's own. Counting items straight through,
// leaving out the separators, they line up with the rows of RFCommentRows, after the post.
static NSInteger RFRowItems(UICollectionView *list, NSInteger section) {
  NSInteger count = [list numberOfItemsInSection:section];
  return section > 0 && count > 1 ? count - 1 : count;
}

static NSInteger RFFlatIndex(UICollectionView *list, NSIndexPath *path) {
  NSInteger flat = path.item;
  for (NSInteger section = 0; section < path.section && section < list.numberOfSections; section++)
    flat += RFRowItems(list, section);
  return flat;
}

static NSIndexPath *RFPathForFlatIndex(UICollectionView *list, NSInteger flat) {
  if (flat < 0) return nil;
  for (NSInteger section = 0; section < list.numberOfSections; section++) {
    NSInteger count = RFRowItems(list, section);
    if (flat < count) return [NSIndexPath indexPathForItem:flat inSection:section];
    flat -= count;
  }
  return nil;
}

// Where in a post's comments you were: the comment at the top of the screen (or the post itself) and
// how far into it.
static NSDictionary *RFCommentPosition(UIViewController *post, NSString *postId) {
  UICollectionView *list = RFListIn(post);
  if (!list) return nil;
  NSArray *rows = RFRowsForPost(postId);
  CGFloat top = RFVisibleTop(list);
  NSUInteger tried = 0;
  for (UICollectionViewCell *cell in RFCellsTopFirst(list)) {
    if (cell.hidden || CGRectGetMidY(cell.frame) < top) continue;
    if (++tried > 8) break;
    NSIndexPath *path = [list indexPathForCell:cell];
    if (!path) continue;
    double offset = top - CGRectGetMinY(cell.frame);
    NSInteger flat = RFFlatIndex(list, path);
    if (flat == 0) return @{@"offset" : @(offset)};
    NSUInteger row = RFRowOfCommentCell(rows, cell, flat - 1);
    NSString *comment = row == NSNotFound ? nil : rows[row][@"id"];
    if (comment) return @{@"comment" : comment, @"offset" : @(offset)};
  }
  return nil;
}

// Short names of screens for Diagnostics ("SubredditScreenViewController").
static NSString *RFScreenNames(NSArray<UIViewController *> *screens) {
  NSMutableArray *names = [NSMutableArray array];
  for (UIViewController *vc in screens)
    [names addObject:[NSStringFromClass(vc.class) componentsSeparatedByString:@"."].lastObject ?: @"?"];
  return [names componentsJoinedByString:@" > "];
}

// One pushed screen as it's kept: @{community: name}, @{profile: name} or @{post: {id, community, and for
// the top one where you were}}. nil if it isn't one of those, with why in `left`.
static NSDictionary *RFKeptScreen(UIViewController *vc, BOOL top, NSString **part, NSString **left) {
  if (RFIsClass(vc, kRFCommunityClass)) {
    NSString *name = RFCommunityName(vc);
    if (!name) return *left = @"couldn't read a community", nil;
    *part = [@"r/" stringByAppendingString:name];
    return @{@"community" : name};
  }
  if (RFIsClass(vc, kRFProfileClass)) {
    NSString *name = RFProfileName(vc);
    if (!name) return *left = @"couldn't read a profile", nil;
    *part = [@"u/" stringByAppendingString:name];
    return @{@"profile" : name};
  }
  UIViewController *post = RFPostScreen(vc);
  if (!post) return *left = [NSString stringWithFormat:@"not supported (%@)", RFScreenNames(@[ vc ])], nil;
  NSString *postId = RFCall(post, @"initialPostPk");
  if (![postId isKindOfClass:NSString.class] || ![postId hasPrefix:@"t3_"] || postId.length < 4)
    return *left = @"couldn't read a post", nil;
  // The community makes the usual link; without it (not always known) the post's own link does.
  NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObject:postId forKey:@"id"];
  entry[@"community"] = RFCommunityName(post);
  // Where you were only matters for the post on top (it's the one with the jump button).
  NSDictionary *position = top ? RFCommentPosition(post, postId) : nil;
  [entry addEntriesFromDictionary:position ?: @{}];
  NSString *where = !top ? @"" : position[@"comment"] ? @" (at a comment)" : position ? @" (in the post)" : @" (position not found)";
  *part = [NSString stringWithFormat:@"post %@%@", postId, where];
  return @{@"post" : entry};
}

// What's open: the tab ("home", or "you" for your own profile) and the screens above its root (on Home at
// least one; nothing above your profile still reopens the You tab). nil for anything else, with why in
// `left` (and what's kept, when there's something).
static NSDictionary *RFOpenScreens(NSString **left) {
  UITabBarController *tabs = RFTabBar();
  UINavigationController *nav = RFHomeNavigation();
  NSString *tab = @"home";
  if (!nav) {
    UINavigationController *you = RFYouNavigation(tabs);
    if (!you || tabs.selectedViewController != you || !RFIsClass(you.viewControllers.firstObject, kRFProfileClass) ||
        !you.viewIfLoaded.window)
      return *left = @"Home or You not showing", nil;
    nav = you;
    tab = @"you";
  }
  NSArray<UIViewController *> *stack = nav.viewControllers;
  BOOL you = [tab isEqualToString:@"you"];
  if (stack.count < 2 && !you) return *left = @"Home", nil;
  if (stack.count - 1 > kRFMaxScreens) return *left = [NSString stringWithFormat:@"more than %lu screens", (unsigned long)kRFMaxScreens], nil;
  NSMutableArray *screens = [NSMutableArray array];
  NSMutableArray *parts = [NSMutableArray arrayWithObject:you ? @"You" : @"Home"];
  for (NSUInteger i = 1; i < stack.count; i++) {
    NSString *part = nil;
    NSDictionary *screen = RFKeptScreen(stack[i], i == stack.count - 1, &part, left);
    if (!screen) return nil;
    [screens addObject:screen];
    [parts addObject:part];
  }
  *left = [parts componentsJoinedByString:@" > "];
  return @{@"tab" : tab, @"screens" : screens};
}

// Whether you'd been further down a post than its top (a comment, or past the first 80 pt). It reopens at
// the top then, with the button to jump back.
static BOOL RFPostWasScrolled(NSDictionary *post) {
  return post[@"comment"] || [post[@"offset"] doubleValue] >= 80;
}

static UIImage *RFSnapshot(UIWindow *window) {
  UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
  format.opaque = YES;
  UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:window.bounds.size format:format];
  __block BOOL drawn = NO;
  UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
    drawn = [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
  }];
  return drawn ? image : nil; // a failed capture would cover the screen in black
}

static UIWindow *RFMainWindow(void) {
  for (UIWindow *window in RFWindows())
    if (window.isKeyWindow) return window;
  return RFWindows().firstObject;
}


static BOOL gSavedSinceActive; // main thread; saved once per trip away (inactive, then background)

static void RFNoteLeavingScreens(void) {
  if (gSavedSinceActive) return;
  gSavedSinceActive = YES;
  if (!gRestoreScreens || !RFFeedCacheEnabled()) {
    gLeft = @"not saved (feature off)";
    return;
  }
  // Incognito: nothing is kept, and what was kept before it goes (it's out of date anyway).
  if (RFFeedCacheIncognito()) {
    gLeft = @"not saved (incognito)";
    RFForgetScreens();
    return;
  }
  NSString *left = nil;
  NSDictionary *screens = RFOpenScreens(&left);
  gLeft = left ?: @"";
  NSString *account = RFFeedCacheCurrentAccount();
  if (!screens || !account) {
    RFForgetScreens();
    return;
  }
  NSMutableDictionary *saved = [screens mutableCopy];
  saved[@"leftAt"] = @(NSDate.date.timeIntervalSince1970);
  saved[@"account"] = account;
  UIWindow *window = RFMainWindow();
  // The picture covers the launch only for a community on top of Home, which comes back exactly as it
  // was. A post or profile loads afresh (and opens at the top), so it shows a plain cover instead.
  BOOL community = [screens[@"tab"] isEqualToString:@"home"] && [screens[@"screens"] lastObject][@"community"];
  UIImage *picture = window && community ? RFSnapshot(window) : nil;
  if (picture) saved[@"pictureSize"] = @[ @(window.bounds.size.width), @(window.bounds.size.height) ];
  UIApplication *app = UIApplication.sharedApplication;
  __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
  void (^finish)(void) = ^{
    dispatch_async(dispatch_get_main_queue(), ^{
      if (task == UIBackgroundTaskInvalid) return;
      [app endBackgroundTask:task];
      task = UIBackgroundTaskInvalid;
    });
  };
  task = [app beginBackgroundTaskWithName:@"RedditFilter screens" expirationHandler:finish];
  // One block for all of it, so a removal queued meanwhile (turned off, incognito) comes after, not between.
  dispatch_async(RFRestoreQueue(), ^{
    RFWriteNow(@"LastScreen.jpg", picture ? UIImageJPEGRepresentation(picture, 0.85) : nil);
    RFWriteNow(@"Comments.json", nil); // kept by earlier versions
    RFWriteNow(@"Screens.json", [NSJSONSerialization dataWithJSONObject:saved options:0 error:NULL]);
    finish();
  });
}

#pragma mark - Restoring at launch

// The restore's steps: Home (kRFStepHome), then each kept screen in turn (its index), then done.
static const NSInteger kRFStepHome = -1;

#define kRFHomeFeeds (@[ @"HomeFeedSdui", @"FollowingFeed", @"PopularFeedSdui" ])
#define kRFCommunityFeed @"SubredditFeedSdui"
static NSUInteger gUndeferGeneration;
static NSString *gDeferredCommunity; // the community whose feed is waiting under a post

// Covered feeds are scrolled back when their screen appears again (RFScreenAppearing); not back within 10
// minutes, they're left as they are.
static void RFWatchCoveredFeeds(void) {
  if (!RFFeedHasDeferred()) return;
  NSUInteger generation = ++gUndeferGeneration;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    if (generation != gUndeferGeneration) return;
    RFFeedUndefer(kRFHomeFeeds, nil);
    RFFeedUndefer(@[ kRFCommunityFeed ], nil);
  });
}

static void RFReleaseCoveredFeeds(void) {
  gUndeferGeneration++;
  RFFeedUndefer(kRFHomeFeeds, nil);
  RFFeedUndefer(@[ kRFCommunityFeed ], nil);
}

// The swipe back was cancelled: the screen's still covered, so a scroll back still due waits again.
static void RFScreenReturnCancelled(UIViewController *screen) {
  NSArray *feeds = RFIsClass(screen, kRFHomeClass) ? kRFHomeFeeds : @[ kRFCommunityFeed ];
  NSMutableArray *due = [NSMutableArray array];
  for (NSString *feed in feeds)
    if (RFFeedCacheRestoreTarget(feed, NULL, NULL)) [due addObject:feed];
  if (due.count) RFFeedDefer(due);
}

// Home or a community is appearing (also as you start swiping back to it): its covered feed, if any.
static void RFScreenAppearing(UIViewController *screen) {
  if (!RFFeedHasDeferred()) return;
  if (RFIsClass(screen, kRFHomeClass)) RFFeedUndefer(kRFHomeFeeds, screen);
  else if (RFIsClass(screen, kRFCommunityClass) &&
           [RFCommunityName(screen).lowercaseString isEqualToString:gDeferredCommunity.lowercaseString])
    RFFeedUndefer(@[ kRFCommunityFeed ], screen);
}

static NSDictionary *gPlan; // Screens.json, while restoring; main thread like the rest
static NSInteger gStep; // kRFStepHome, a screen's index, or the screen count once done
static BOOL gWaitingForYou; // the screens are open; waiting for the You tab to show your profile
static NSDate *gRestoreStart, *gStepStart, *gPlanStart;
static NSInteger gSteady; // ticks in a row that the current step looked finished
static NSTimer *gRestoreTimer;
static UIView *gCover; // the picture of the screen as it was left, with the Restoring pill
static __weak UICollectionView *gProbeList; // the post's list, if it was scrolled down looking for the comment
// The jump button: offered on the reopened post when you'd been further down it.
static __weak UIViewController *gJumpScreen;
static NSDictionary *gJumpPlan;
static BOOL gJumping, gJumpFound;
static CGFloat gProbeStart, gProbeHeight;

static void RFOpenLink(NSString *link) {
  NSURL *url = [NSURL URLWithString:link];
  id<UIApplicationDelegate> delegate = UIApplication.sharedApplication.delegate;
  if (url && [delegate respondsToSelector:@selector(application:openURL:options:)])
    [delegate application:UIApplication.sharedApplication openURL:url options:@{}];
}

static NSArray<NSDictionary *> *RFPlanScreens(void) { return gPlan[@"screens"]; }
static BOOL RFRestoreDone(void) { return !gWaitingForYou && gStep >= (NSInteger)RFPlanScreens().count; }
static NSDictionary *RFStepScreen(void) {
  return gStep >= 0 && gStep < (NSInteger)RFPlanScreens().count ? RFPlanScreens()[gStep] : nil;
}

static NSString *RFScreenKind(NSDictionary *screen) {
  return screen[@"community"] ? @"the community" : screen[@"profile"] ? @"the profile" : screen[@"post"] ? @"the post" : @"";
}

static UINavigationController *RFTabWithRoot(UITabBarController *tabs, NSString *rootClass) {
  for (UIViewController *tab in tabs.viewControllers)
    if ([tab isKindOfClass:UINavigationController.class] &&
        RFIsClass(((UINavigationController *)tab).viewControllers.firstObject, rootClass))
      return (UINavigationController *)tab;
  return nil;
}

// Selects the You tab (as a tap on it would).
static void RFSelectYouTab(void) {
  UITabBarController *tabs = RFTabBar();
  UINavigationController *you = RFYouNavigation(tabs);
  if (!you || tabs.selectedViewController == you) return;
  id<UITabBarControllerDelegate> delegate = tabs.delegate;
  if ([delegate respondsToSelector:@selector(tabBarController:shouldSelectViewController:)] &&
      ![delegate tabBarController:tabs shouldSelectViewController:you])
    return;
  tabs.selectedViewController = you;
  if ([delegate respondsToSelector:@selector(tabBarController:didSelectViewController:)])
    [delegate tabBarController:tabs didSelectViewController:you];
}

// Whether the You tab has your profile at its root yet: until it's first shown it holds a placeholder,
// which is replaced (with anything pushed on it) once it is.
static BOOL RFYouTabReady(void) {
  return RFIsClass(RFYouNavigation(RFTabBar()).viewControllers.firstObject, kRFProfileClass);
}

// The screens opened on Home go over to the You tab, on top of your profile, and the tab's selected. Going
// back then works as it does there; Home is left at its feed (scrolled back when you go to it). Tried
// again for a moment if your profile isn't in place yet.
static void RFMoveToYouTab(NSInteger tries) {
  RFSelectYouTab();
  UITabBarController *tabs = RFTabBar();
  UINavigationController *you = RFYouNavigation(tabs), *home = RFTabWithRoot(tabs, kRFHomeClass);
  if (!you || !home || you == home) return;
  if (!RFYouTabReady()) {
    if (tries > 0)
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RFMoveToYouTab(tries - 1);
      });
    return;
  }
  NSArray<UIViewController *> *stack = home.viewControllers;
  if (stack.count < 2) return;
  NSArray<UIViewController *> *moved = [stack subarrayWithRange:NSMakeRange(1, stack.count - 1)];
  [home setViewControllers:@[ stack.firstObject ] animated:NO];
  [you setViewControllers:[@[ you.viewControllers.firstObject ] arrayByAddingObjectsFromArray:moved] animated:NO];
}

static NSString *RFStepName(void) {
  if (gStep == kRFStepHome) return @"Home";
  if (gWaitingForYou) return @"the You tab";
  NSDictionary *screen = RFStepScreen();
  if (!screen) return @"";
  NSUInteger count = RFPlanScreens().count;
  return count > 1 ? [NSString stringWithFormat:@"%@ (screen %ld of %lu)", RFScreenKind(screen), (long)gStep + 1, (unsigned long)count]
                   : RFScreenKind(screen);
}

static BOOL RFScrollComments(UIViewController *post, NSDictionary *plan);

// "Back to where you were": a system capsule button above the bottom of the reopened post (Liquid Glass
// where iOS has it). Tapping it scrolls to the noted comment, showing the system spinner while Reddit lays
// the comments out; scrolling yourself, or 30 seconds without a tap, puts it away.
@interface RFJumpButton : NSObject
@end

static UIButton *gJumpButton;
static NSTimer *gJumpTimer;
static NSDate *gJumpStart, *gJumpOffered;

static void RFHideJump(NSTimeInterval delay) {
  [gJumpTimer invalidate];
  gJumpTimer = nil;
  gJumping = NO;
  UIButton *button = gJumpButton;
  gJumpButton = nil;
  gJumpScreen = nil;
  gJumpPlan = nil;
  button.userInteractionEnabled = NO;
  [UIView animateWithDuration:0.25
      delay:delay
      options:UIViewAnimationOptionCurveEaseIn
      animations:^{
        button.alpha = 0;
        button.transform = CGAffineTransformMakeScale(0.9, 0.9);
      }
      completion:^(BOOL finished) {
        [button removeFromSuperview];
      }];
}

static void RFSetJumpLook(NSString *title, BOOL busy) {
  UIButtonConfiguration *config = gJumpButton.configuration;
  config.title = title;
  config.showsActivityIndicator = busy;
  gJumpButton.configuration = config;
  gJumpButton.accessibilityLabel = title;
  [gJumpButton sizeToFit];
  UIView *container = gJumpButton.superview;
  if (container)
    gJumpButton.center = CGPointMake(container.bounds.size.width / 2, gJumpButton.center.y);
}

static void RFJumpTick(void) {
  UIViewController *post = gJumpScreen;
  if (!post || !post.view.window) return RFHideJump(0);
  UICollectionView *list = RFListIn(post);
  BOOL scrolledYourself = list.isTracking || list.isDragging;
  if (!gJumping) {
    // Offered, not tapped: away once you scroll yourself, or after a while.
    if (scrolledYourself || -[gJumpOffered timeIntervalSinceNow] > 30) RFHideJump(0);
    return;
  }
  if (!RFScrollComments(post, gJumpPlan) && -[gJumpStart timeIntervalSinceNow] < 15) return;
  scrolledYourself = scrolledYourself || list.isDecelerating;
  // Not found: back to where it started (unless you've taken over).
  if (!gJumpFound && gProbeList && !scrolledYourself)
    gProbeList.contentOffset = CGPointMake(gProbeList.contentOffset.x, gProbeStart);
  gProbeList = nil;
  gJumping = NO;
  if (gJumpFound || scrolledYourself) return RFHideJump(0);
  RFSetJumpLook(@"Couldn't find your place", NO);
  RFHideJump(1.5);
}

@implementation RFJumpButton
+ (void)jump:(id)sender {
  if (gJumping || !gJumpScreen) return;
  gJumping = YES;
  gJumpFound = NO;
  gSteady = 0;
  gProbeList = nil;
  gProbeHeight = 0;
  gJumpStart = NSDate.date;
  RFSetJumpLook(@"Finding your place…", YES);
}
@end

static UIButtonConfiguration *RFJumpConfiguration(void) {
  // Liquid Glass on iOS 26, otherwise a filled capsule in the system's grouped background.
  UIButtonConfiguration *config = nil;
  SEL glass = NSSelectorFromString(@"glassButtonConfiguration");
  if ([UIButtonConfiguration respondsToSelector:glass])
    config = ((UIButtonConfiguration * (*)(id, SEL))objc_msgSend)(UIButtonConfiguration.class, glass);
  if (!config) {
    config = [UIButtonConfiguration filledButtonConfiguration];
    config.baseBackgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    config.baseForegroundColor = UIColor.labelColor;
  }
  config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
  config.image = [UIImage systemImageNamed:@"arrow.down"];
  config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleSubheadline
                                                                                                scale:UIImageSymbolScaleSmall];
  config.imagePadding = 6;
  config.contentInsets = NSDirectionalEdgeInsetsMake(10, 16, 10, 16);
  config.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
    NSMutableDictionary *styled = [attributes mutableCopy];
    styled[NSFontAttributeName] = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline compatibleWithTraitCollection:nil];
    UIFontDescriptor *bold = [[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline].fontDescriptor
        fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
    if (bold) styled[NSFontAttributeName] = [UIFont fontWithDescriptor:bold size:0];
    return styled;
  };
  return config;
}

static void RFOfferJump(NSInteger tries) {
  UIViewController *post = gJumpScreen;
  NSDictionary *plan = gJumpPlan;
  // Just moved to the You tab, the post can take a moment to be on screen.
  if (post && !post.view.window && tries > 0 && plan[@"offset"] && RFPostWasScrolled(plan)) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      if (gJumpScreen == post && !gJumpButton && !gPlan) RFOfferJump(tries - 1);
    });
    return;
  }
  // Only when you'd been further down than its top.
  if (!post.view.window || !plan[@"offset"] || !RFPostWasScrolled(plan)) {
    gJumpScreen = nil;
    gJumpPlan = nil;
    return;
  }
  UIButton *button = [UIButton buttonWithConfiguration:RFJumpConfiguration() primaryAction:nil];
  [button addTarget:RFJumpButton.class action:@selector(jump:) forControlEvents:UIControlEventTouchUpInside];
  gJumpButton = button;
  UIView *container = post.view;
  [container addSubview:button];
  RFSetJumpLook(@"Back to where you were", NO);
  // Above the comment bar, like the system's "new messages" pills.
  button.center = CGPointMake(container.bounds.size.width / 2,
                              container.bounds.size.height - container.safeAreaInsets.bottom - 72 - button.bounds.size.height / 2);
  button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin;
  if (!UIAccessibilityIsReduceMotionEnabled()) {
    button.alpha = 0;
    button.transform = CGAffineTransformMakeTranslation(0, 12);
    [UIView animateWithDuration:0.35
                          delay:0
         usingSpringWithDamping:0.8
          initialSpringVelocity:0
                        options:0
                     animations:^{
                       button.alpha = 1;
                       button.transform = CGAffineTransformIdentity;
                     }
                     completion:nil];
  }
  gJumpOffered = NSDate.date;
  gJumpTimer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                               repeats:YES
                                                 block:^(NSTimer *timer) {
                                                   RFJumpTick();
                                                 }];
}

static UIImageView *gCoverPicture; // shown once the account's confirmed

static void RFFinishRestore(void) {
  if (gPlan && !RFRestoreDone() && !gOutcome.length) gOutcome = [NSString stringWithFormat:@"stopped (left while opening %@)", RFStepName()];
  BOOL reopened = gReopened;
  // For the You tab, what's been opened (on Home) goes over to it, once it's the right account.
  // Not when it was stopped for another account or incognito: those screens aren't the new account's.
  if (gPlan && gStep != kRFStepHome && [gPlan[@"tab"] isEqualToString:@"you"] && !gStoppedForUser)
    RFMoveToYouTab(60);
  gWaitingForYou = NO;
  // The post was scrolled down looking for the comment and it wasn't found: back where it started.
  UICollectionView *probed = gProbeList;
  if (probed && !reopened) probed.contentOffset = CGPointMake(probed.contentOffset.x, gProbeStart);
  gProbeList = nil;
  [gRestoreTimer invalidate];
  gRestoreTimer = nil;
  gPlan = nil;
  gStep = 0;
  // The picture of the last screen is only for this cover: gone with it.
  gCoverPicture = nil;
  RFWriteFile(@"LastScreen.jpg", nil, nil);
  RFWatchCoveredFeeds();
  if (reopened) RFOfferJump(10);
  else gJumpScreen = nil;
  UIView *cover = gCover;
  gCover = nil;
  // A moment for the last of the page to settle (images, the comment box) before it shows.
  [UIView animateWithDuration:reopened ? 0.2 : 0.15
      delay:reopened ? 0.1 : 0
      options:0
      animations:^{
        cover.alpha = 0;
      }
      completion:^(BOOL finished) {
        [cover removeFromSuperview];
      }];
}

// Skip on the Restoring pill: stops the restore where it is and shows the app as it is now. (Other taps
// on the cover are ignored, as the screens underneath are still changing.)
@interface RFCoverSkip : NSObject
@end
@implementation RFCoverSkip
+ (void)skip:(UIButton *)button {
  if (!gPlan) return;
  gOutcome = @"skipped (you tapped Skip)";
  RFFinishRestore();
}
@end

// A capsule near the top: a spinner, "Restoring…" and Skip.
static UIView *RFRestoringPill(UIWindow *window) {
  UIVisualEffectView *pill = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
  pill.layer.cornerCurve = kCACornerCurveContinuous;
  pill.clipsToBounds = YES;

  UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
  [spinner startAnimating];
  UILabel *label = [UILabel new];
  label.text = @"Restoring…";
  label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
  label.textColor = UIColor.labelColor;
  label.adjustsFontForContentSizeCategory = NO;
  UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
  config.attributedTitle = [[NSAttributedString alloc]
      initWithString:@"Skip"
          attributes:@{NSFontAttributeName : [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]}];
  config.contentInsets = NSDirectionalEdgeInsetsMake(6, 10, 6, 10);
  UIButton *skip = [UIButton buttonWithConfiguration:config primaryAction:nil];
  [skip addTarget:RFCoverSkip.class action:@selector(skip:) forControlEvents:UIControlEventTouchUpInside];

  UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ spinner, label, skip ]];
  row.axis = UILayoutConstraintAxisHorizontal;
  row.alignment = UIStackViewAlignmentCenter;
  row.spacing = 10;
  row.layoutMargins = UIEdgeInsetsMake(6, 14, 6, 4);
  row.layoutMarginsRelativeArrangement = YES;
  [pill.contentView addSubview:row];
  CGSize size = [row systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
  size.width = MIN(size.width, window.bounds.size.width - 32);
  row.frame = CGRectMake(0, 0, size.width, size.height);
  pill.frame = CGRectMake((window.bounds.size.width - size.width) / 2, window.safeAreaInsets.top + 8, size.width, size.height);
  pill.layer.cornerRadius = size.height / 2;
  pill.layer.shadowOpacity = 0;
  pill.accessibilityViewIsModal = YES;
  return pill;
}


static void RFShowCover(UIWindow *window) {
  if (gCover || !gPlan) return;
  // The picture only if there's one, of a screen this size; otherwise the cover's plain.
  NSArray *size = gPlan[@"pictureSize"];
  BOOL picture = [size isKindOfClass:NSArray.class] && size.count == 2 &&
                 fabs([size[0] doubleValue] - window.bounds.size.width) <= 1 &&
                 fabs([size[1] doubleValue] - window.bounds.size.height) <= 1 &&
                 [NSFileManager.defaultManager fileExistsAtPath:RFRestorePath(@"LastScreen.jpg")];
  // Taps don't reach the screens changing underneath (only Skip does).
  gCover = [[UIView alloc] initWithFrame:window.bounds];
  gCover.userInteractionEnabled = YES;
  // Plain until it's known to be the same account (the picture is of that account's screen).
  gCover.backgroundColor = UIColor.systemBackgroundColor;
  // Loaded once it's the same account.
  if (picture) {
    UIImageView *image = [[UIImageView alloc] initWithFrame:window.bounds];
    image.contentMode = UIViewContentModeScaleToFill;
    image.accessibilityElementsHidden = YES;
    image.hidden = YES;
    gCoverPicture = image;
    [gCover addSubview:image];
  }
  // Dimmed a little, so it doesn't pass for the live app.
  UIView *dim = [[UIView alloc] initWithFrame:window.bounds];
  dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.18];
  [gCover addSubview:dim];
  [gCover addSubview:RFRestoringPill(window)];
  [window addSubview:gCover];
}

// Whether a post page shows the post yet: some text in its first section (the loading placeholder has none).
static BOOL RFPostShown(UICollectionView *list) {
  if (!list.numberOfSections) return NO;
  for (UICollectionViewCell *cell in list.visibleCells) {
    if ([list indexPathForCell:cell].section != 0 || !cell.contentView) continue;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:cell.contentView];
    for (NSUInteger seen = 0; queue.count && seen < 80; seen++) {
      UIView *view = queue.firstObject;
      [queue removeObjectAtIndex:0];
      if (view.accessibilityLabel.length || ([view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length)) return YES;
      [queue addObjectsFromArray:view.subviews];
    }
  }
  return NO;
}

// Whether a list shows real posts yet (not the loading placeholder).
static BOOL RFListShowsPosts(UICollectionView *list) {
  for (UICollectionViewCell *cell in list.visibleCells)
    if (RFCellLabel(cell)) return YES;
  return NO;
}

static void RFStartStep(NSInteger step) {
  gStep = step;
  gStepStart = NSDate.date;
  gSteady = 0;
  NSDictionary *screen = RFStepScreen();
  if (screen[@"community"]) {
    NSString *name = screen[@"community"];
    RFFeedCacheArmCommunity(name);
    RFOpenLink([NSString stringWithFormat:@"https://www.reddit.com/r/%@/", name]);
  } else if (screen[@"profile"]) {
    RFOpenLink([NSString stringWithFormat:@"https://www.reddit.com/user/%@/", screen[@"profile"]]);
  } else if (screen[@"post"]) {
    NSDictionary *post = screen[@"post"];
    NSString *postId = post[@"id"];
    gProbeList = nil;
    gProbeHeight = 0;
    RFForgetRows(postId); // only the comments it gets now count
    NSString *community = post[@"community"];
    RFOpenLink(community ? [NSString stringWithFormat:@"https://www.reddit.com/r/%@/comments/%@/", community, [postId substringFromIndex:3]]
                         : [NSString stringWithFormat:@"https://www.reddit.com/comments/%@/", [postId substringFromIndex:3]]);
  }
}

static void RFNextStep(void) {
  if (gStep + 1 < (NSInteger)RFPlanScreens().count) return RFStartStep(gStep + 1);
  // For the You tab: it's selected, and once your profile's in place what was opened goes over to it.
  if ([gPlan[@"tab"] isEqualToString:@"you"] && !gWaitingForYou && !RFYouTabReady()) {
    gWaitingForYou = YES;
    gStep = RFPlanScreens().count;
    gStepStart = NSDate.date;
    gSteady = 0;
    RFSelectYouTab();
    return;
  }
  gStep = RFPlanScreens().count;
  if (!gOutcome.length) {
    NSMutableArray *kinds = [NSMutableArray array];
    for (NSDictionary *screen in RFPlanScreens()) [kinds addObject:[RFScreenKind(screen) substringFromIndex:4]];
    if ([gPlan[@"tab"] isEqualToString:@"you"]) [kinds insertObject:@"You tab" atIndex:0];
    gOutcome = [@"reopened " stringByAppendingString:[kinds componentsJoinedByString:@" > "]];
    gReopened = YES;
  }
  RFFinishRestore();
}

// Scrolls the post down to the end of what's laid out, to have Reddit ask for (or lay out) more: only under
// the cover, untouched, and once each time there's more laid out. Where it started is kept, to go back to
// if the comment isn't found.
static void RFScrollToEnd(UICollectionView *list) {
  if ((!gCover && !gJumping) || list.isTracking || list.isDragging || list.contentSize.height <= gProbeHeight + 1) return;
  if (gProbeList != list) {
    gProbeList = list;
    gProbeStart = list.contentOffset.y;
  }
  gProbeHeight = list.contentSize.height;
  CGFloat bottom = list.contentSize.height + list.adjustedContentInset.bottom - list.bounds.size.height;
  if (bottom > list.contentOffset.y + 1) list.contentOffset = CGPointMake(list.contentOffset.x, bottom);
}

// One step of scrolling the post's comments back. YES when there's nothing more to do.
static BOOL RFScrollComments(UIViewController *post, NSDictionary *plan) {
  NSString *postId = plan[@"id"];
  double offset = [plan[@"offset"] doubleValue];
  NSString *comment = plan[@"comment"];
  // Reddit loads the first few comments, then all of them; the page lays itself out again when the rest
  // arrive, so the cover stays until then (or until the step runs out of time).
  BOOL allLoaded = RFRowsSettled(postId);
  if (!plan[@"offset"]) return allLoaded; // was at the top
  UICollectionView *list = RFListIn(post);
  if (!list || !list.numberOfSections) return NO;
  if (!comment) {
    RFScrollResult result = RFScrollListToItem(list, [NSIndexPath indexPathForItem:0 inSection:0], offset, NO,
                                               ^BOOL(UICollectionViewCell *cell) {
                                                 return YES;
                                               });
    if (result == RFScrollDone) return YES;
    return result == RFScrollPlaced && ++gSteady >= 2 && allLoaded;
  }
  NSArray *rows = RFRowsForPost(postId);
  if (!rows) return NO; // comments not loaded yet
  NSUInteger target = [rows indexOfObjectPassingTest:^BOOL(NSDictionary *row, NSUInteger i, BOOL *stop) {
    return [row[@"id"] isEqual:comment];
  }];
  // Not there: if only the first few are in, Reddit asks for the rest once the comments are scrolled to,
  // so the list is taken down to the end of them (under the cover); otherwise it's gone (or too far down).
  if (target == NSNotFound) {
    if (RFRowsTruncated(postId)) {
      RFScrollToEnd(list);
      return NO;
    }
    if (gProbeList) gProbeList.contentOffset = CGPointMake(gProbeList.contentOffset.x, gProbeStart);
    gProbeList = nil;
    return YES;
  }
  // Items are the post, then one per row; measured from a comment on screen in case there's more first.
  NSInteger base = 1;
  for (UICollectionViewCell *cell in RFCellsTopFirst(list)) {
    NSIndexPath *path = [list indexPathForCell:cell];
    NSInteger flat = path ? RFFlatIndex(list, path) : 0;
    if (flat == 0) continue;
    NSUInteger row = RFRowOfCommentCell(rows, cell, flat - 1);
    if (row == NSNotFound) continue;
    base = flat - (NSInteger)row;
    break;
  }
  // Which row a cell shows: the author and level on it, at about where it sits in the list (so another
  // comment by the same author at the same level isn't taken for it).
  NSUInteger (^rowOfCell)(UICollectionViewCell *) = ^NSUInteger(UICollectionViewCell *cell) {
    NSIndexPath *at = [list indexPathForCell:cell];
    if (!at) return NSNotFound;
    NSInteger near = RFFlatIndex(list, at) - base;
    return RFRowOfCommentCell(rows, cell, near < 0 ? 0 : (NSUInteger)near);
  };
  // The comment's own cell, once it's on screen.
  NSIndexPath *shown = nil;
  for (UICollectionViewCell *cell in list.visibleCells)
    if (rowOfCell(cell) == target) shown = [list indexPathForCell:cell];
  NSIndexPath *path = shown ?: RFPathForFlatIndex(list, base + (NSInteger)target);
  // The page lays its comments out a section at a time as it's scrolled: down to the end of them for more.
  if (!path) {
    RFScrollToEnd(list);
    return NO;
  }
  RFScrollResult result = RFScrollListToItem(list, path, offset, NO,
                                             ^BOOL(UICollectionViewCell *cell) {
                                               return rowOfCell(cell) == target;
                                             });
  if (result == RFScrollPlaced && ++gSteady >= 2 && allLoaded) {
    gProbeList = nil; // found: stays where it is
    gJumpFound = YES;
    return YES;
  }
  if (result == RFScrollPlaced) return NO;
  gSteady = 0;
  return result == RFScrollDone;
}

static void RFRestoreTick(void) {
  NSDate *now = NSDate.date;
  UIView *coverParent = gCover.superview;
  if (gCover) [coverParent bringSubviewToFront:gCover];
  NSUInteger count = RFPlanScreens().count;
  NSTimeInterval maxTime = kRFRestoreMaxTime + 4.0 * (count > 2 ? count - 2 : 0);
  if ([now timeIntervalSinceDate:gRestoreStart] > maxTime) {
    gOutcome = [@"timed out opening " stringByAppendingString:RFStepName()];
    return RFFinishRestore();
  }
  BOOL late = [now timeIntervalSinceDate:gStepStart] > kRFStepMaxTime;
  if (late && !gOutcome.length && gStep != kRFStepHome) gOutcome = [@"timed out opening " stringByAppendingString:RFStepName()];
  UINavigationController *nav = RFHomeNavigation();
  UIViewController *top = nav.viewControllers.lastObject;
  if (gStep == kRFStepHome) {
    // Reddit opened a screen itself (launched from a notification or a link): that's what you asked for,
    // so nothing's reopened on top of it.
    UIViewController *selected = RFTabBar().selectedViewController;
    BOOL otherTab = selected && [selected isKindOfClass:UINavigationController.class] &&
                    !RFIsClass(((UINavigationController *)selected).viewControllers.firstObject, kRFHomeClass);
    if (nav.viewControllers.count > 1 || otherTab) {
      gOutcome = @"skipped (Reddit opened a screen)";
      // Home's feed is under that screen: it's scrolled back when you go back to it.
      RFFeedDefer(kRFHomeFeeds);
      return RFFinishRestore();
    }
    // Home is up (its feed needn't have loaded: it's scrolled back when you go back to it), and it's the
    // account the screens were left in.
    NSString *account = RFFeedCacheCurrentAccount();
    if (account && ![account isEqualToString:gPlan[@"account"]]) {
      gOutcome = @"skipped (different account)";
      return RFFinishRestore();
    }
    // Until the account's known (the first feed asked for), the time limits don't run; that has its own.
    if (!account) {
      gRestoreStart = gStepStart = now;
      if (-[gPlanStart timeIntervalSinceNow] > kRFAccountWait) {
        gOutcome = @"skipped (account unknown)";
        RFFinishRestore();
      }
      return;
    }
    if (gCoverPicture && !gCoverPicture.image && !RFFeedCacheIncognito()) {
      gCoverPicture.image = [UIImage imageWithContentsOfFile:RFRestorePath(@"LastScreen.jpg")];
      gCoverPicture.hidden = NO;
    }
    BOOL ready = nav && nav.viewControllers.count == 1 && RFListIn(nav.viewControllers.firstObject);
    gSteady = ready ? gSteady + 1 : 0;
    if (gSteady >= 2) {
      RFFeedDefer(kRFHomeFeeds);
      RFNextStep();
    } else if (late) {
      gOutcome = @"timed out opening Home";
      RFFinishRestore();
    }
    return;
  }
  if (gWaitingForYou) {
    gSteady = RFYouTabReady() ? gSteady + 1 : 0;
    if (gSteady >= 2 || late) RFNextStep();
    return;
  }
  NSDictionary *screen = RFStepScreen();
  if (!screen) return RFFinishRestore();
  // More on Home than Home, the screens opened so far and this one: Reddit opened a screen of its own
  // (a link that arrived late), so nothing more is pushed on top of it.
  if (nav.viewControllers.count > (NSUInteger)gStep + 2) {
    gOutcome = @"stopped (Reddit opened a screen)";
    return RFFinishRestore();
  }
  BOOL last = gStep + 1 == (NSInteger)count;
  if (screen[@"community"]) {
    NSString *name = screen[@"community"];
    BOOL shown = RFIsClass(top, kRFCommunityClass) && [RFCommunityName(top).lowercaseString isEqualToString:name.lowercaseString];
    if (shown && !last) {
      // More goes on top: if it's the kept community, its feed is scrolled back when you go back to it.
      if ([RFFeedCacheCommunity(NULL) isEqualToString:name.lowercaseString]) {
        gDeferredCommunity = name;
        RFFeedDefer(@[ kRFCommunityFeed ]);
      }
      return RFNextStep();
    }
    UICollectionView *list = shown ? RFListIn(top) : nil;
    BOOL ready = list && RFListShowsPosts(list) && !RFFeedRestoring();
    gSteady = ready ? gSteady + 1 : 0;
    if (gSteady >= 2 || late) RFNextStep();
  } else if (screen[@"profile"]) {
    // Opens at its top (it isn't kept like a feed): done once its header has loaded (some profiles hide
    // their posts, so those can't be waited for).
    NSString *name = RFIsClass(top, kRFProfileClass) && top.viewIfLoaded.window ? RFProfileName(top) : nil;
    BOOL ready = [name.lowercaseString isEqualToString:[screen[@"profile"] lowercaseString]];
    gSteady = ready ? gSteady + 1 : 0;
    if (gSteady >= 2 || late) RFNextStep();
  } else {
    // Reopened at its top: done once the post's showing (finding the comment again is the jump button's,
    // on the top post).
    UIViewController *post = RFPostScreen(top);
    BOOL right = post && [RFCall(post, @"initialPostPk") isEqual:screen[@"post"][@"id"]];
    UICollectionView *list = right ? RFListIn(post) : nil;
    BOOL shown = list && RFPostShown(list);
    gSteady = shown ? gSteady + 1 : 0;
    if (gSteady >= 2) {
      if (last) {
        gJumpScreen = post;
        gJumpPlan = screen[@"post"];
      }
      RFNextStep();
    } else if (late) {
      RFNextStep();
    }
  }
}

static BOOL RFIsNumber(id value) { return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]); }
static BOOL RFIsText(id value) { return [value isKindOfClass:NSString.class] && [value length] > 0; }

// Screens.json if everything in it is what it should be (an older or damaged one isn't used).
static BOOL RFValidScreen(id screen) {
  if (![screen isKindOfClass:NSDictionary.class] || [screen count] != 1) return NO;
  id community = screen[@"community"], profile = screen[@"profile"], post = screen[@"post"];
  if (community) return RFIsText(community);
  if (profile) return RFIsUsername(profile);
  if (![post isKindOfClass:NSDictionary.class]) return NO;
  NSString *postId = post[@"id"];
  if (!RFIsText(postId) || ![postId hasPrefix:@"t3_"] || postId.length < 4) return NO;
  if (post[@"community"] && !RFIsText(post[@"community"])) return NO;
  return !(post[@"comment"] && !RFIsText(post[@"comment"])) && !(post[@"offset"] && !RFIsNumber(post[@"offset"]));
}

// Screens.json if everything in it is what it should be (an older or damaged one isn't used).
static NSDictionary *RFValidPlan(NSDictionary *plan) {
  if (!plan || !RFIsNumber(plan[@"leftAt"]) || !RFIsText(plan[@"account"])) return nil;
  NSString *tab = plan[@"tab"];
  NSArray *screens = plan[@"screens"];
  id size = plan[@"pictureSize"];
  if (![tab isEqual:@"home"] && ![tab isEqual:@"you"]) return nil;
  if (![screens isKindOfClass:NSArray.class] || screens.count > kRFMaxScreens) return nil;
  if (!screens.count && [tab isEqual:@"home"]) return nil;
  for (id screen in screens)
    if (!RFValidScreen(screen)) return nil;
  if (size && !([size isKindOfClass:NSArray.class] && [size count] == 2 && RFIsNumber(size[0]) && RFIsNumber(size[1]))) return nil;
  return plan;
}

static void RFPlanRestoreNow(void);

// At launch, once the scene's connected: restores if iOS closed the app and there's something to open.
// A picture of the last screen that won't be used isn't kept.
static void RFPlanRestore(void) {
  RFPlanRestoreNow();
  if (!gPlan) RFWriteFile(@"LastScreen.jpg", nil, nil);
}

static void RFPlanRestoreNow(void) {
  if (!RFFeedCacheEnabled()) return (void)(gOutcome = @"nothing (Keep feed position off)");
  if (!RFMayRestore()) return (void)(gOutcome = @"skipped (swiped away)");
  if (!gRestoreScreens) return (void)(gOutcome = @"feeds only (Reopen community and post off)");
  NSDictionary *plan = RFValidPlan(RFReadJSON(@"Screens.json"));
  if (!plan) return (void)(gOutcome = @"nothing to reopen");
  NSNumber *leftAt = plan[@"leftAt"];
  NSTimeInterval away = [leftAt isKindOfClass:NSNumber.class] ? NSDate.date.timeIntervalSince1970 - leftAt.doubleValue : -1;
  if (away < 0 || (gMaxAge > 0 && away > gMaxAge)) return (void)(gOutcome = @"skipped (too long ago)");
  // Once only: a crash during the restore shouldn't bring it back again.
  RFWriteJSON(@"Screens.json", nil, nil);
  gPlan = plan;
  gRestoreStart = gStepStart = gPlanStart = NSDate.date;
  gStep = kRFStepHome;
  gSteady = 0;
  gRestoreTimer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                                  repeats:YES
                                                    block:^(NSTimer *timer) {
                                                      RFRestoreTick();
                                                    }];
  [NSRunLoop.mainRunLoop addTimer:gRestoreTimer forMode:NSRunLoopCommonModes];
  UIWindow *window = RFMainWindow();
  if (window) RFShowCover(window);
}

@interface RFHomeScreen : UIViewController
@end
@interface RFCommunityScreen : UIViewController
@end
@interface RFProfileScreen : UIViewController
@end

// A swipe back to the screen that's cancelled: its feed waits again (it's still covered).
static void RFWatchCancelledReturn(UIViewController *screen) {
  id<UIViewControllerTransitionCoordinator> coordinator = screen.transitionCoordinator;
  if (!coordinator.isInteractive) return;
  [coordinator notifyWhenInteractionChangesUsingBlock:^(id<UIViewControllerTransitionCoordinatorContext> context) {
    if (context.isCancelled) RFScreenReturnCancelled(screen);
  }];
}

// One group per class: a Logos group initialised for two classes would share one %orig.
%group RFHomeScreenHooks
%hook RFHomeScreen
- (void)viewWillAppear:(BOOL)animated {
  %orig;
  RFScreenAppearing((UIViewController *)self);
  RFWatchCancelledReturn((UIViewController *)self);
}
%end
%end

%group RFCommunityScreenHooks
%hook RFCommunityScreen
- (void)viewWillAppear:(BOOL)animated {
  %orig;
  RFScreenAppearing((UIViewController *)self);
  RFWatchCancelledReturn((UIViewController *)self);
}
%end
%end

// A profile notes its username as it appears (its header's at the top then), for when it's left scrolled.
%group RFProfileScreenHooks
%hook RFProfileScreen
- (void)viewDidAppear:(BOOL)animated {
  %orig;
  if (!gRestoreScreens) return;
  UIViewController *profile = (UIViewController *)self;
  if (RFProfileName(profile)) return;
  // Its header may still be loading.
  __weak UIViewController *weakProfile = profile;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    UIViewController *later = weakProfile;
    if (later.viewIfLoaded.window) RFProfileName(later);
  });
}
%end
%end

void RFSetRestoreOptions(BOOL afterSwipe, NSInteger hours) {
  NSTimeInterval maxAge = hours > 0 ? hours * 60 * 60 : 0;
  RFFeedCacheSetMaxAge(maxAge);
  dispatch_block_t apply = ^{
    gAfterSwipe = afterSwipe;
    gMaxAge = maxAge;
    RFUpdateColdReplay();
  };
  if (NSThread.isMainThread) apply();
  else dispatch_async(dispatch_get_main_queue(), apply);
}

// Stops a restore under way and stops waiting for covered screens.
static void RFStopRestoring(NSString *why) {
  if (gPlan) {
    gOutcome = why;
    gStoppedForUser = YES;
    RFFinishRestore();
  }
  RFReleaseCoveredFeeds();
}

void RFSetRestoreScreens(BOOL restore) {
  dispatch_block_t apply = ^{
    // Settings are applied again whenever any of them changes: only a real switch off (or off from the
    // start) stops and forgets.
    static BOOL applied;
    BOOL was = gRestoreScreens, first = !applied;
    applied = YES;
    gRestoreScreens = restore;
    RFFeedCacheSetKeepsCommunities(restore);
    if (!restore && (was || first)) {
      RFStopRestoring(@"stopped (turned off)");
      RFForgetScreens();
    }
  };
  if (NSThread.isMainThread) apply();
  else dispatch_async(dispatch_get_main_queue(), apply);
}

%ctor {
  gCommentRows = [NSMutableDictionary dictionary];
  gCommentPosts = [NSMutableArray array];
  gTruncatedPosts = [NSMutableSet set];
  gRowsAt = [NSMutableDictionary dictionary];
  gCommentAccounts = [NSMutableDictionary dictionary];
  gLastSession = RFReadJSON(@"Session.json");
  // Home and communities, to scroll back a feed that was covered by the screens reopened on top.
  Class home = NSClassFromString(kRFHomeClass), community = NSClassFromString(kRFCommunityClass);
  if ([home isSubclassOfClass:UIViewController.class]) %init(RFHomeScreenHooks, RFHomeScreen = home);
  if ([community isSubclassOfClass:UIViewController.class]) %init(RFCommunityScreenHooks, RFCommunityScreen = community);
  Class profile = NSClassFromString(kRFProfileClass);
  if ([profile isSubclassOfClass:UIViewController.class]) %init(RFProfileScreenHooks, RFProfileScreen = profile);
  gSnapshotAtLaunch = RFNewestSwitcherSnapshot();
  NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
  NSOperationQueue *main = NSOperationQueue.mainQueue;
  __block BOOL connected = NO;
  [center addObserverForName:UISceneWillConnectNotification
                      object:nil
                       queue:main
                  usingBlock:^(NSNotification *note) {
                    UIScene *scene = note.object;
                    // Compared as text: the role isn't always the same string object (iOS 27.1).
                    if (connected || ![scene.session.role isEqualToString:UIWindowSceneSessionRoleApplication]) return;
                    connected = YES;
                    RFNoteLaunchSession(scene.session);
                    gLaunchDecided = YES;
                    RFUpdateColdReplay();
                    RFPlanRestore();
                  }];
  [center addObserverForName:UIWindowDidBecomeKeyNotification
                      object:nil
                       queue:main
                  usingBlock:^(NSNotification *note) {
                    if (gPlan) RFShowCover(note.object);
                  }];
  // Also when the app only goes inactive: from the app switcher, it can be swiped away (and killed)
  // without ever going to the background.
  for (NSNotificationName name in @[ UIApplicationWillResignActiveNotification, UIApplicationDidEnterBackgroundNotification ])
    [center addObserverForName:name
                        object:nil
                         queue:main
                    usingBlock:^(NSNotification *note) {
                      if (gPlan) RFFinishRestore();
                      RFNoteLeavingScreens();
                      RFSaveSession(YES);
                    }];
  [center addObserverForName:UIApplicationDidBecomeActiveNotification
                      object:nil
                       queue:main
                  usingBlock:^(NSNotification *note) {
                    gSavedSinceActive = NO;
                    RFSaveSession(NO);
                  }];
  // Another account (or logged out) in this run: what was kept is the other account's.
  [center addObserverForName:RFFeedCacheAccountDidChangeNotification
                      object:nil
                       queue:main
                  usingBlock:^(NSNotification *note) {
                    RFStopRestoring(note.object ? @"stopped (account changed)" : @"stopped (incognito)");
                    RFForgetScreens();
                    RFScreenRestoreForgetComments();
                  }];
}
