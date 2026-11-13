// Restore open community and post.
//
// Keep feed position brings Home's feeds back after iOS closes Reddit in the background. This goes one
// step further: the communities, custom feeds, profiles, searches and posts open on Home (in any order, a
// few deep), or on top of your own profile in the You tab or the Inbox, are opened again, and the top post offers to jump
// back to where you were in its comments. The screen where a search is typed is skipped, and a screen that
// can't be reopened ends what's kept (the screens below it still are). If Reddit opens a screen of its own
// at launch (a notification or a link), what was open waits until you go back to Home.
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
#import <objc/runtime.h>
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
// The base of Home's screens (PerFeedScreenviewHomeScreenViewController, the one in use, and
// SingleScreenviewHomeScreenViewController are kinds of it). Only matched here, never hooked as well as
// kRFHomeClass: a hook on both would run twice for each appearance of the one in use.
static NSString *const kRFHomeTabClass = @"Home_Impl.HomeScreenViewController";
static NSString *const kRFCommunityClass = @"Subreddit_Internal.SubredditScreenViewController";
static NSString *const kRFProfileClass = @"Profiles.ProfileCoreStackViewController";
static NSString *const kRFPreviewClass = @"PreviewModeViewController.PreviewModeViewControllerImpl";
static NSString *const kRFPostClass = @"PDP_Impl.PDPViewController";
static NSString *const kRFSearchClass = @"Search_Core_Impl.SearchResultsViewController"; // a search's results
static NSString *const kRFTypeaheadClass = @"Search_Core_Impl.TypeaheadViewController";   // typing a search
static NSString *const kRFCustomFeedClass = @"MultiFeed.MultiPageViewController";         // a custom feed
// Reddit's own feed screens: Popular and Latest (from the side menu), News and Games. All one class, titled
// in the app's language, so which feed one shows is noted from its first page's request.
static NSString *const kRFLegacyFeedClass = @"FeedKit_LegacyBridge.BridgedFeedViewController";
static NSString *const kRFYouTabID = @"reddit_tab_bar__profile_button";
static NSString *const kRFInboxTabID = @"reddit_tab_bar__inbox_button";
static NSString *const kRFInboxClass = @"MainTabBar_Inbox.InboxViewController";

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
// The comment a post was opened at (from the Inbox, or a comment link): Reddit shows that comment's thread
// first, highlighted. Post ID -> comment ID, from its latest comments asked for; guarded by gRowsLock.
static NSMutableDictionary<NSString *, NSString *> *gCommentFocus;
static NSArray<NSDictionary *> *gSearchPosts; // the posts of the last few searches' results; guarded by gRowsLock
// Where a search results screen looked: a community, or "" for all of Reddit (an associated object, set
// from its request; RFNoteSearchScope).
static const void *kRFSearchScopeKey = &kRFSearchScopeKey;
static unsigned gSearchGeneration; // goes up as the searches are forgotten; guarded by gRowsLock

// Each search request's number, in the order they're made: an older answer doesn't undo a newer one's
// scope on the same screen (kRFSearchScopeOrderKey).
static const void *kRFSearchScopeOrderKey = &kRFSearchScopeOrderKey;
static unsigned long long gSearchOrder; // guarded by gRowsLock

unsigned long long RFScreenRestoreNextSearchOrder(void) {
  os_unfair_lock_lock(&gRowsLock);
  unsigned long long order = ++gSearchOrder;
  os_unfair_lock_unlock(&gRowsLock);
  return order;
}

unsigned RFScreenRestoreSearchGeneration(void) {
  os_unfair_lock_lock(&gRowsLock);
  unsigned generation = gSearchGeneration;
  os_unfair_lock_unlock(&gRowsLock);
  return generation;
}

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
    for (NSString *file in @[ @"Screens.json", @"LastScreen.jpg", @"Comments.json", @"Parked.json" ]) RFWriteNow(file, nil);
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

// Text that can go into a link as it is: letters, digits, "_" (and "-" if `dash`), min to max long.
static BOOL RFIsLinkName(id name, NSUInteger min, NSUInteger max, BOOL dash) {
  static NSCharacterSet *plain, *dashed;
  if (!plain) {
    NSString *letters = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_";
    plain = [NSCharacterSet characterSetWithCharactersInString:letters].invertedSet;
    dashed = [NSCharacterSet characterSetWithCharactersInString:[letters stringByAppendingString:@"-"]].invertedSet;
  }
  return [name isKindOfClass:NSString.class] && [name length] >= min && [name length] <= max &&
         [name rangeOfCharacterFromSet:dash ? dashed : plain].location == NSNotFound;
}

// A Reddit username: what a profile link can be made from.
static BOOL RFIsUsername(id name) { return RFIsLinkName(name, 3, 20, YES); }
// A community's name: what a community link can be made from (a profile's own is "u_" and its username).
static BOOL RFIsCommunityName(id name) { return RFIsLinkName(name, 2, 22, YES); }
// A custom feed's name (its link is /user/<owner>/m/<name>/).
static BOOL RFIsCustomFeedName(id name) { return RFIsLinkName(name, 1, 50, NO); }

// A custom feed screen's owner and name, noted as it's set up: @{user, name}, or nil.
static const void *kRFCustomFeedKey = &kRFCustomFeedKey;
static NSDictionary *RFCustomFeed(UIViewController *vc) {
  return objc_getAssociatedObject(vc, kRFCustomFeedKey);
}

static void RFNoteCustomFeed(UIViewController *vc, NSString *path) {
  // "/user/<owner>/m/<name>/"
  NSArray *parts = [[path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]]
      componentsSeparatedByString:@"/"];
  if (parts.count != 4 || ![[parts[0] lowercaseString] isEqualToString:@"user"] || ![[parts[2] lowercaseString] isEqualToString:@"m"])
    return;
  if (RFIsUsername(parts[1]) && RFIsCustomFeedName(parts[3]))
    objc_setAssociatedObject(vc, kRFCustomFeedKey, @{@"user" : parts[1], @"name" : parts[3]}, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

// Whether a screen is Home (whichever kind of Home the account has).
static BOOL RFIsHomeScreen(id screen) { return RFIsClass(screen, kRFHomeClass) || RFIsClass(screen, kRFHomeTabClass); }

static NSArray<UIWindow *> *RFWindows(void) {
  NSMutableArray *windows = [NSMutableArray array];
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
    if ([scene isKindOfClass:UIWindowScene.class]) [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
  return windows;
}

static UITabBarController *RFTabBar(void);
static UINavigationController *RFHomeNavigation(void);

// A Home feed screen pushed on Home (Popular, or Latest from the side menu), and which feed it shows:
// @"popular" or @"latest", from its first page's request (RFNoteHomeFeedScreen), else nil.
static const void *kRFHomeFeedScreenKey = &kRFHomeFeedScreenKey;
static NSString *const kRFPopularScreen = @"popular";
static NSString *const kRFLatestScreen = @"latest";
static NSString *const kRFPopularFeed = @"PopularFeedSdui"; // as FeedCache names the feeds
static NSString *const kRFLatestFeed = @"LatestFeed";

static NSString *RFHomeFeedScreen(UIViewController *screen) {
  if (!RFIsClass(screen, kRFLegacyFeedClass)) return nil;
  NSString *feed = objc_getAssociatedObject(screen, kRFHomeFeedScreenKey);
  return [feed isKindOfClass:NSString.class] ? feed : nil;
}

// The feed a kept screen shows, as FeedCache names it, or nil if it isn't one.
static NSString *RFScreenFeedName(UIViewController *screen) {
  NSString *feed = RFHomeFeedScreen(screen);
  return [feed isEqualToString:kRFPopularScreen] ? kRFPopularFeed
         : [feed isEqualToString:kRFLatestScreen] ? kRFLatestFeed
                                                  : nil;
}

// The pushed feed screen its first page is for, if it hasn't been named yet: the top screen of the tab on
// screen (Reddit asks for the page as the screen opens, so it's the one on top), or of Home's stack. A tab's
// own root is never one (where the account still has the feed strip, Popular is a tab). Main thread.
static BOOL RFNoteHomeFeedScreen(NSString *feed) {
  NSMutableArray<UINavigationController *> *stacks = [NSMutableArray array];
  UITabBarController *tabs = RFTabBar();
  if ([tabs.selectedViewController isKindOfClass:UINavigationController.class])
    [stacks addObject:(UINavigationController *)tabs.selectedViewController];
  UINavigationController *home = RFHomeNavigation();
  if (home && ![stacks containsObject:home]) [stacks addObject:home];
  for (UINavigationController *nav in stacks) {
    NSArray<UIViewController *> *stack = nav.viewControllers;
    UIViewController *screen = stack.lastObject;
    // Only what's pushed on a tab's root, and only while it's on screen.
    if (stack.count < 2 || !screen.viewIfLoaded.window || !RFIsClass(screen, kRFLegacyFeedClass)) continue;
    if (objc_getAssociatedObject(screen, kRFHomeFeedScreenKey)) continue;
    objc_setAssociatedObject(screen, kRFHomeFeedScreenKey, feed, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
  }
  return NO;
}

// A feed's first page names the screen it's for (see RFScreenRestoreFeedPage). Main thread.
static void RFNoteHomeFeedPage(NSString *feed) {
  if (RFNoteHomeFeedScreen(feed)) return;
  // The screen may still be on its way (a link's push): once more, a moment later.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    RFNoteHomeFeedScreen(feed);
  });
}

void RFScreenRestoreFeedPage(NSString *operation, NSURLRequest *request) {
  if (!gRestoreScreens || !RFFeedCacheEnabled() || RFFeedCacheRequestIsIncognito(request)) return;
  NSString *name = RFFeedNameForPage(operation, request);
  NSString *feed = [name isEqualToString:kRFPopularFeed] ? kRFPopularScreen
                   : [name isEqualToString:kRFLatestFeed] ? kRFLatestScreen
                                                          : nil;
  if (!feed) return;
  // Only the first page: a later one is the screen's own paging, and the screen's named by then.
  NSData *body = request.HTTPBody;
  NSDictionary *json = body.length ? [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL] : nil;
  id variables = [json isKindOfClass:NSDictionary.class] ? json[@"variables"] : nil;
  id after = [variables isKindOfClass:NSDictionary.class] ? variables[@"after"] : nil;
  if ([after isKindOfClass:NSString.class] && [after length]) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    RFNoteHomeFeedPage(feed);
  });
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
// Reddit opened a screen of its own at launch (a notification or a link): what was open before waits here,
// and is reopened once you go back to Home (RFResumeParked). Main thread.
static NSDictionary *gParked;
static __weak UINavigationController *gParkedNav; // where Reddit's screen is, and how many screens deep:
static NSUInteger gParkedDepth;                   // going further than that drops what's waiting
static NSDate *gParkedAt;
static NSDictionary *gParkAfter; // waiting from the last run, to wait again once this launch's restore is done
static BOOL gResumed; // the restore under way is of those, back on Home
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
static void RFRecordComments(NSString *post, NSArray *rows, BOOL truncated, NSString *account, NSString *focus) {
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
  if (focus) gCommentFocus[post] = focus;
  else [gCommentFocus removeObjectForKey:post];
  gRowsAt[post] = NSDate.date;
  [gCommentPosts removeObject:post];
  [gCommentPosts addObject:post];
  while (gCommentPosts.count > 5) {
    NSString *oldest = gCommentPosts.firstObject;
    [gCommentRows removeObjectForKey:oldest];
    [gTruncatedPosts removeObject:oldest];
    [gRowsAt removeObjectForKey:oldest];
    [gCommentAccounts removeObjectForKey:oldest];
    [gCommentFocus removeObjectForKey:oldest];
    [gCommentPosts removeObjectAtIndex:0];
  }
  os_unfair_lock_unlock(&gRowsLock);
}

// The variables of a comments request for a post, and the cursor of the "more" row it opens ("N more
// replies", or the next page at the end), if it's not the post's comments from the start.
static NSDictionary *RFCommentVariables(NSURLRequest *request, NSString **opens) {
  NSDictionary *body = request.HTTPBody.length ? [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:NULL] : nil;
  NSDictionary *variables = [body isKindOfClass:NSDictionary.class] ? body[@"variables"] : nil;
  if (![variables isKindOfClass:NSDictionary.class]) return nil;
  id after = variables[@"after"], cursor = variables[@"cursor"];
  *opens = [after isKindOfClass:NSString.class] && [after length] ? after
         : [cursor isKindOfClass:NSString.class] && [cursor length] ? cursor : nil;
  NSString *post = variables[@"id"];
  return [post isKindOfClass:NSString.class] && [post hasPrefix:@"t3_"] ? variables : nil;
}

// Comments Reddit opened in a post already noted: they go in place of the row they open, so a place in
// them can be saved too.
static void RFRecordOpenedComments(NSString *post, NSString *cursor, NSArray *opened, NSString *account) {
  os_unfair_lock_lock(&gRowsLock);
  NSArray *rows = gCommentRows[post];
  BOOL sameAccount = !account || !gCommentAccounts[post] || [gCommentAccounts[post] isEqualToString:account];
  NSArray *merged = rows && sameAccount ? RFMergeCommentRows(rows, cursor, opened) : nil;
  if (merged) {
    gCommentRows[post] = merged;
    // In use: the last to go when other posts' comments come in.
    [gCommentPosts removeObject:post];
    [gCommentPosts addObject:post];
  }
  os_unfair_lock_unlock(&gRowsLock);
}

static UITabBarController *RFTabBar(void);
static UIViewController *RFPostScreen(UIViewController *vc);

// The comment a post screen was opened at (NSNull for none): an associated object, from its first answer.
static const void *kRFPostFocusKey = &kRFPostFocusKey;

// A first page of a post's comments goes to the post screen that asked: the one showing that post on top of
// its tab (the selected tab first) not yet told. Main thread.
static BOOL RFNotePostFocus(NSString *post, id focus) {
  UITabBarController *tabs = RFTabBar();
  NSMutableArray *order = [NSMutableArray array];
  if (tabs.selectedViewController) [order addObject:tabs.selectedViewController];
  for (UIViewController *tab in tabs.viewControllers)
    if (tab != tabs.selectedViewController) [order addObject:tab];
  for (UIViewController *tab in order) {
    if (![tab isKindOfClass:UINavigationController.class]) continue;
    UIViewController *screen = RFPostScreen(((UINavigationController *)tab).topViewController);
    if (!screen || objc_getAssociatedObject(screen, kRFPostFocusKey)) continue;
    id shown = RFCall(screen, @"initialPostPk");
    if (![shown isKindOfClass:NSString.class] || ![shown isEqualToString:post]) continue;
    objc_setAssociatedObject(screen, kRFPostFocusKey, focus, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
  }
  return NO;
}

NSData *RFScreenRestoreCommentsPage(NSURLRequest *request, NSData *page) {
  NSString *opens = nil;
  NSDictionary *variables = RFCommentVariables(request, &opens);
  if (!variables || RFFeedCacheRequestIsIncognito(request)) return nil;
  NSArray *rows = RFCommentRows(page);
  if (opens) {
    if (rows) RFRecordOpenedComments(variables[@"id"], opens, rows, RFFeedAccount(request));
    return nil;
  }
  // Reddit first asks for the first few comments (isTruncatedFetch), and for all of them once you get
  // near the comments. The first few are the start of the same list, so they do until then.
  // The comment it was opened at, if any ("t1_/" is Reddit's "none").
  id focusContext = variables[@"focusedCommentContext"];
  NSString *focus = [focusContext isKindOfClass:NSDictionary.class] ? focusContext[@"commentId"] : nil;
  BOOL focused = [focus isKindOfClass:NSString.class] && [focus hasPrefix:@"t1_"] && RFIsLinkName([focus substringFromIndex:3], 1, 20, NO);
  if (!rows) return nil;
  RFRecordComments(variables[@"id"], rows,
                   [variables[@"isTruncatedFetch"] isKindOfClass:NSNumber.class] && [variables[@"isTruncatedFetch"] boolValue],
                   RFFeedAccount(request), focused ? focus : nil);
  // The same post can be open more than once (from the Inbox at a reply, and from Home): the post screen
  // that asked keeps its own.
  NSString *post = variables[@"id"];
  id kept = focused ? focus : (id)NSNull.null;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (RFNotePostFocus(post, kept)) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      RFNotePostFocus(post, kept);
    });
  });
  return nil;
}

static NSString *RFSearchQuery(UIViewController *results);
static UITabBarController *RFTabBar(void);

// A search's answer names where it looked: that goes on the results screen showing that query (the one on
// top of its tab, which is the one that asked, the selected tab first; or else the topmost one not yet
// told). If none shows it yet (its search bar not filled in), once more a moment later.
// Puts a search's scope on a results screen unless a newer search's answer already did. Main thread.
static void RFSetSearchScope(UIViewController *vc, NSDictionary *scope, unsigned long long order) {
  NSNumber *told = objc_getAssociatedObject(vc, kRFSearchScopeOrderKey);
  if (told && told.unsignedLongLongValue > order) return;
  objc_setAssociatedObject(vc, kRFSearchScopeKey, scope[@"community"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(vc, kRFSearchScopeOrderKey, @(order), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL RFNoteSearchScope(NSDictionary *scope, unsigned long long searchOrder) {
  NSString *query = [scope[@"query"] lowercaseString];
  UITabBarController *tabs = RFTabBar();
  NSMutableArray *order = [NSMutableArray array];
  if (tabs.selectedViewController) [order addObject:tabs.selectedViewController];
  for (UIViewController *tab in tabs.viewControllers)
    if (tab != tabs.selectedViewController) [order addObject:tab];
  UIViewController *untold = nil;
  for (UIViewController *tab in order) {
    if (![tab isKindOfClass:UINavigationController.class]) continue;
    NSArray<UIViewController *> *stack = ((UINavigationController *)tab).viewControllers;
    for (NSInteger i = (NSInteger)stack.count - 1; i >= 0; i--) {
      UIViewController *vc = stack[i];
      if (!RFIsClass(vc, kRFSearchClass) || ![RFSearchQuery(vc).lowercaseString isEqualToString:query]) continue;
      if (i == (NSInteger)stack.count - 1) {
        RFSetSearchScope(vc, scope, searchOrder);
        return YES;
      }
      if (!untold && !objc_getAssociatedObject(vc, kRFSearchScopeKey)) untold = vc;
    }
  }
  if (untold) RFSetSearchScope(untold, scope, searchOrder);
  return untold != nil;
}

static BOOL RFSearchGenerationIs(unsigned generation) { return RFScreenRestoreSearchGeneration() == generation; }

// Called off the main thread, after the app has the results.
NSData *RFScreenRestoreSearchPage(NSURLRequest *request, NSData *page, unsigned generation, unsigned long long order) {
  if (RFFeedCacheRequestIsIncognito(request) || !RFSearchGenerationIs(generation)) return nil;
  NSDictionary *scope = RFSearchRequestScope(request.HTTPBody);
  if (scope)
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!RFSearchGenerationIs(generation) || RFNoteSearchScope(scope, order)) return;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (RFSearchGenerationIs(generation)) RFNoteSearchScope(scope, order);
      });
    });
  NSArray *posts = RFSearchResultPosts(page);
  if (!posts.count) return nil;
  NSMutableSet *ids = [NSMutableSet set];
  for (NSDictionary *post in posts)
    if (post[@"id"]) [ids addObject:post[@"id"]];
  os_unfair_lock_lock(&gRowsLock);
  if (gSearchGeneration != generation) {
    os_unfair_lock_unlock(&gRowsLock);
    return nil;
  }
  // Newest first, each post once, and only so many (a few searches' worth).
  NSMutableArray *kept = [posts mutableCopy];
  for (NSDictionary *post in gSearchPosts ?: @[])
    if (![ids containsObject:post[@"id"]]) [kept addObject:post];
  if (kept.count > 400) [kept removeObjectsInRange:NSMakeRange(400, kept.count - 400)];
  gSearchPosts = kept;
  os_unfair_lock_unlock(&gRowsLock);
  return nil;
}

// The community a search results screen looked in (nil for all of Reddit, or not known).
static NSString *RFSearchCommunity(UIViewController *results) {
  NSString *community = objc_getAssociatedObject(results, kRFSearchScopeKey);
  return community.length ? community : nil;
}

// Forgets the searches' posts (another account, or incognito), and answers still on their way.
static void RFForgetSearches(void) {
  os_unfair_lock_lock(&gRowsLock);
  gSearchPosts = nil;
  gSearchGeneration++;
  os_unfair_lock_unlock(&gRowsLock);
}

static NSArray<NSDictionary *> *RFKnownSearchPosts(void) {
  os_unfair_lock_lock(&gRowsLock);
  NSArray *posts = gSearchPosts;
  os_unfair_lock_unlock(&gRowsLock);
  return posts;
}

// Forgets every post's comments (another account, incognito, or the comment filters changed). Searches stay.
void RFScreenRestoreForgetComments(void) {
  os_unfair_lock_lock(&gRowsLock);
  [gCommentRows removeAllObjects];
  [gCommentFocus removeAllObjects];
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

static NSString *RFFocusForPost(NSString *post) {
  os_unfair_lock_lock(&gRowsLock);
  NSString *focus = gCommentFocus[post];
  os_unfair_lock_unlock(&gRowsLock);
  return focus;
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
  [gCommentFocus removeObjectForKey:post];
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
          RFIsHomeScreen(((UINavigationController *)vc).viewControllers.firstObject))
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

// A tab's stack by its button: the You tab (your own profile at its root) or the Inbox.
static UINavigationController *RFTabNamed(UITabBarController *tabs, NSString *identifier) {
  for (UIViewController *tab in tabs.viewControllers)
    if ([tab isKindOfClass:UINavigationController.class] && [tab.tabBarItem.accessibilityIdentifier isEqualToString:identifier])
      return (UINavigationController *)tab;
  return nil;
}

// What a kept plan's other tab is ("you" or "inbox"): its stack, and what's at its root once it's loaded.
static UINavigationController *RFPlanTabNavigation(NSString *tab) {
  return RFTabNamed(RFTabBar(), [tab isEqualToString:@"inbox"] ? kRFInboxTabID : kRFYouTabID);
}
static NSString *RFPlanTabRoot(NSString *tab) { return [tab isEqualToString:@"inbox"] ? kRFInboxClass : kRFProfileClass; }
static NSString *RFPlanTabName(NSString *tab) { return [tab isEqualToString:@"inbox"] ? @"Inbox" : @"You"; }

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
    if (comment)
      return [rows[row][@"inReplies"] boolValue] ? @{@"comment" : comment, @"offset" : @(offset), @"inReplies" : @YES}
                                                 : @{@"comment" : comment, @"offset" : @(offset)};
  }
  // Past the end of the comments (only the posts Reddit lists after them on screen): the last comment.
  BOOL pastComments = NO;
  for (UICollectionViewCell *cell in list.visibleCells)
    if ([NSStringFromClass(cell.class) containsString:@"FeedStackSliceViewModel"]) pastComments = YES; // hidden or not
  for (NSDictionary *row in pastComments ? rows.reverseObjectEnumerator : @[].objectEnumerator)
    if (row[@"id"])
      return [row[@"inReplies"] boolValue] ? @{@"comment" : row[@"id"], @"offset" : @0, @"inReplies" : @YES}
                                           : @{@"comment" : row[@"id"], @"offset" : @0};
  return nil;
}

// Short names of screens for Diagnostics ("SubredditScreenViewController").
static NSString *RFScreenNames(NSArray<UIViewController *> *screens) {
  NSMutableArray *names = [NSMutableArray array];
  for (UIViewController *vc in screens)
    [names addObject:[NSStringFromClass(vc.class) componentsSeparatedByString:@"."].lastObject ?: @"?"];
  return [names componentsJoinedByString:@" > "];
}

// What a search results screen searched for: the text in its search bar (its navigation item's title view,
// which it keeps while another screen is on top).
static NSString *RFSearchQuery(UIViewController *results) {
  UIView *bar = results.navigationItem.titleView;
  NSMutableArray<UIView *> *queue = bar ? [NSMutableArray arrayWithObject:bar] : [NSMutableArray array];
  for (NSUInteger seen = 0; queue.count && seen < 60; seen++) {
    UIView *view = queue.firstObject;
    [queue removeObjectAtIndex:0];
    if ([view isKindOfClass:UITextField.class]) {
      NSString *text = [((UITextField *)view).text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
      return text.length && text.length <= 512 ? text : nil;
    }
    [queue addObjectsFromArray:view.subviews];
  }
  return nil;
}

// Reddit's full-screen viewer, which posts open in from search results (a list of posts, one per page).
static BOOL RFIsFullScreenViewer(UIViewController *vc) {
  return [NSStringFromClass(vc.class) containsString:@"FBPListViewModel"];
}

// The post the full-screen viewer shows: the texts of its page on screen (the post's title among them),
// matched against the posts of the searches' results.
static NSString *RFFullScreenViewerPost(UIViewController *viewer) {
  UICollectionView *list = nil;
  CGFloat listArea = 0;
  NSMutableArray<UIView *> *queue = viewer.viewIfLoaded ? [NSMutableArray arrayWithObject:viewer.viewIfLoaded] : [NSMutableArray array];
  for (NSUInteger seen = 0; queue.count && seen < 300; seen++) {
    UIView *view = queue.firstObject;
    [queue removeObjectAtIndex:0];
    if ([view isKindOfClass:UICollectionView.class] && view.bounds.size.width * view.bounds.size.height > listArea) {
      list = (UICollectionView *)view;
      listArea = view.bounds.size.width * view.bounds.size.height;
      continue;
    }
    [queue addObjectsFromArray:view.subviews];
  }
  UICollectionViewCell *page = nil;
  CGFloat pageArea = 0;
  for (UICollectionViewCell *cell in list.visibleCells) {
    CGRect shown = CGRectIntersection(cell.frame, list.bounds);
    CGFloat area = CGRectIsNull(shown) ? 0 : shown.size.width * shown.size.height;
    if (area > pageArea) {
      page = cell;
      pageArea = area;
    }
  }
  if (!page) return nil;
  NSMutableArray<NSString *> *texts = [NSMutableArray array];
  queue = [NSMutableArray arrayWithObject:page];
  for (NSUInteger seen = 0; queue.count && seen < 300; seen++) {
    UIView *view = queue.firstObject;
    [queue removeObjectAtIndex:0];
    NSString *text = [view isKindOfClass:UILabel.class] ? ((UILabel *)view).text : nil;
    if (text.length) [texts addObject:text];
    [queue addObjectsFromArray:view.subviews];
  }
  // The community shows in the viewer's top bar, outside the page.
  queue = [NSMutableArray arrayWithObject:viewer.viewIfLoaded];
  for (NSUInteger seen = 0; queue.count && seen < 300; seen++) {
    UIView *view = queue.firstObject;
    [queue removeObjectAtIndex:0];
    if (view == page) continue;
    NSString *text = [view isKindOfClass:UILabel.class] ? ((UILabel *)view).text : nil;
    if ([text containsString:@"r/"]) [texts addObject:text];
    [queue addObjectsFromArray:view.subviews];
  }
  return RFSearchPostForTexts(RFKnownSearchPosts(), texts);
}

// One pushed screen as it's kept: @{community: name}, @{feed: {user, name}}, @{profile: name},
// @{search: query} (and "in": community for a search in one) or @{post: {id, community, and for the top
// one where you were}}. nil if it isn't one of those, with why in `left`. `afterSearch`: a search's results
// are below it (only then can the full-screen viewer's post be named).
static NSDictionary *RFKeptScreen(UIViewController *vc, BOOL top, BOOL afterSearch, NSString **part, NSString **left) {
  if (RFIsFullScreenViewer(vc)) {
    if (!afterSearch) return *left = @"full-screen viewer not opened from a search", nil;
    // Reopened as an ordinary post page (the viewer can't be opened from a link).
    NSString *postId = RFFullScreenViewerPost(vc);
    if (!postId) return *left = @"couldn't read a post in the full-screen viewer", nil;
    *part = [NSString stringWithFormat:@"post %@ (full-screen viewer)", postId];
    return @{@"post" : @{@"id" : postId}};
  }
  if (RFIsClass(vc, kRFSearchClass)) {
    NSString *query = RFSearchQuery(vc);
    if (!query) return *left = @"couldn't read a search", nil;
    // A search in a community (kept under "in", as "community" is a community screen).
    NSString *community = RFSearchCommunity(vc);
    if (community && RFIsCommunityName(community)) {
      *part = [NSString stringWithFormat:@"search \u201c%@\u201d in r/%@", query, community];
      return @{@"search" : query, @"in" : community};
    }
    *part = [NSString stringWithFormat:@"search \u201c%@\u201d", query];
    return @{@"search" : query};
  }
  if (RFIsClass(vc, kRFCustomFeedClass)) {
    NSDictionary *feed = RFCustomFeed(vc);
    if (!feed) return *left = @"couldn't read a custom feed", nil;
    *part = [NSString stringWithFormat:@"custom feed u/%@/m/%@", feed[@"user"], feed[@"name"]];
    return @{@"feed" : feed};
  }
  if (RFIsClass(vc, kRFLegacyFeedClass)) {
    // Popular, or Latest from the side menu: reopened as it was, its place kept.
    NSString *feed = RFHomeFeedScreen(vc);
    BOOL popular = [feed isEqualToString:kRFPopularScreen];
    if (!popular && ![feed isEqualToString:kRFLatestScreen]) return *left = @"couldn't tell which feed screen it was", nil;
    *part = popular ? @"Popular" : @"Latest";
    return @{@"homeFeed" : feed};
  }
  if (RFIsClass(vc, kRFCommunityClass)) {
    NSString *name = RFCommunityName(vc);
    if (!RFIsCommunityName(name)) return *left = @"couldn't read a community", nil;
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
  NSString *postCommunity = RFCommunityName(post);
  if (RFIsCommunityName(postCommunity)) entry[@"community"] = postCommunity;
  // Opened at a comment: reopened the same way (that comment's thread first, highlighted).
  // The screen's own when it was told (the same post may be open elsewhere at another comment), else the
  // post's latest.
  id ownFocus = objc_getAssociatedObject(post, kRFPostFocusKey);
  NSString *focus = [ownFocus isKindOfClass:NSString.class] ? ownFocus : ownFocus ? nil : RFFocusForPost(postId);
  if (focus) entry[@"focus"] = focus;
  // Where you were only matters for the post on top (it's the one with the jump button).
  NSDictionary *position = top ? RFCommentPosition(post, postId) : nil;
  [entry addEntriesFromDictionary:position ?: @{}];
  NSString *where = !top ? @"" : position[@"comment"] ? @" (at a comment)" : position ? @" (in the post)" : @" (position not found)";
  if (focus) where = [where stringByAppendingString:@", opened at a comment"];
  *part = [NSString stringWithFormat:@"post %@%@", postId, where];
  return @{@"post" : entry};
}

// What's open: the tab ("home", or "you" for your own profile) and the screens above its root (on Home at
// least one; nothing above your profile still reopens the You tab). A screen that can't be kept (or one
// past the first six) ends it: the screens below it are kept, and `cut` is set (as it is when the top
// screen, a search being typed, isn't kept: what's kept isn't what's on screen). nil when nothing can be
// kept, with why in `left` (and what's kept, when there's something).
static NSDictionary *RFOpenScreens(NSString **left, BOOL *cut) {
  *cut = NO;
  UITabBarController *tabs = RFTabBar();
  UINavigationController *nav = RFHomeNavigation();
  NSString *tab = @"home";
  // Or the You tab, or the Inbox (what's opened from them is on their own stack).
  for (NSString *other in nav ? @[] : @[ @"you", @"inbox" ]) {
    UINavigationController *shown = RFPlanTabNavigation(other);
    if (shown && tabs.selectedViewController == shown && RFIsClass(shown.viewControllers.firstObject, RFPlanTabRoot(other)) &&
        shown.viewIfLoaded.window) {
      nav = shown;
      tab = other;
    }
  }
  if (!nav) return *left = @"Home, You or Inbox not showing", nil;
  NSArray<UIViewController *> *stack = nav.viewControllers;
  BOOL you = [tab isEqualToString:@"you"];
  // The screen where a search is typed isn't kept (what was opened from it is).
  NSMutableArray<UIViewController *> *kept = [NSMutableArray array];
  for (NSUInteger i = 1; i < stack.count; i++)
    if (!RFIsClass(stack[i], kRFTypeaheadClass)) [kept addObject:stack[i]];
  if (!kept.count && !you) return *left = [tab isEqualToString:@"inbox"] ? @"Inbox" : @"Home", nil;
  if (stack.count > 1 && RFIsClass(stack.lastObject, kRFTypeaheadClass)) *cut = YES;
  NSMutableArray *screens = [NSMutableArray array];
  BOOL afterSearch = NO;
  NSMutableArray *parts = [NSMutableArray arrayWithObject:[tab isEqualToString:@"home"] ? @"Home" : RFPlanTabName(tab)];
  NSString *stop = nil;
  for (NSUInteger i = 0; i < kept.count; i++) {
    if (i == kRFMaxScreens) {
      stop = [NSString stringWithFormat:@"more than %lu screens", (unsigned long)kRFMaxScreens];
      break;
    }
    NSString *part = nil;
    // Where you were in a post is only read for the screen on top (the others aren't in the window).
    NSDictionary *screen = RFKeptScreen(kept[i], i == kept.count - 1, afterSearch, &part, &stop);
    if (!screen) break;
    if (screen[@"search"]) afterSearch = YES;
    [screens addObject:screen];
    [parts addObject:part];
  }
  NSString *keptText = [parts componentsJoinedByString:@" > "];
  if (stop) {
    *cut = YES;
    // Nothing kept on Home: there's nothing to reopen.
    if (!screens.count && !you) return *left = [NSString stringWithFormat:@"%@ (then %@)", parts.firstObject, stop], nil;
    *left = [NSString stringWithFormat:@"%@ (then stopped: %@)", keptText, stop];
  } else {
    *left = keptText;
  }
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

// What's waiting for a return to Home, as it's kept for the next launch (nil if nothing, or incognito).
static NSData *RFParkedData(void) {
  if (!gParked || RFFeedCacheIncognito()) return nil;
  NSMutableDictionary *parked = [gParked mutableCopy];
  [parked removeObjectForKey:@"pictureSize"];
  return [NSJSONSerialization dataWithJSONObject:parked options:0 error:NULL];
}

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
  BOOL cut = NO;
  NSDictionary *screens = RFOpenScreens(&left, &cut);
  gLeft = left ?: @"";
  NSString *account = RFFeedCacheCurrentAccount();
  // What's waiting for a return to Home is kept with it (or goes, if nothing is), in the same block.
  NSData *parked = RFParkedData();
  if (!screens || !account) {
    dispatch_async(RFRestoreQueue(), ^{
      for (NSString *file in @[ @"Screens.json", @"LastScreen.jpg", @"Comments.json" ]) RFWriteNow(file, nil);
      RFWriteNow(@"Parked.json", parked);
    });
    return;
  }
  NSMutableDictionary *saved = [screens mutableCopy];
  saved[@"leftAt"] = @(NSDate.date.timeIntervalSince1970);
  saved[@"account"] = account;
  UIWindow *window = RFMainWindow();
  // The picture covers the launch only for a community on top of Home, which comes back exactly as it
  // was. A post or profile loads afresh (and opens at the top), so it shows a plain cover instead, as
  // does a cut stack (the picture is of a screen that won't come back).
  BOOL community = !cut && [screens[@"tab"] isEqualToString:@"home"] && [screens[@"screens"] lastObject][@"community"];
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
    RFWriteNow(@"Parked.json", parked);
    finish();
  });
}

#pragma mark - Restoring at launch

// The restore's steps: Home (kRFStepHome), then each kept screen in turn (its index), then done.
static const NSInteger kRFStepHome = -1;

#define kRFHomeFeeds (@[ @"HomeFeedSdui", @"FollowingFeed", @"PopularFeedSdui" ])
#define kRFCommunityFeed @"SubredditFeedSdui"
// The feeds whose screens are pushed on Home and can have others opened on top of them.
#define kRFFeedScreens (@[ kRFPopularFeed, kRFLatestFeed ])
static NSUInteger gUndeferGeneration;
static NSString *gDeferredCommunity; // the community whose feed is waiting under a post

// The feeds whose screen is covered, all told: Home's tabs, a community and the feed screens pushed on Home.
static NSArray<NSString *> *RFCoveredFeeds(void) {
  return [kRFHomeFeeds arrayByAddingObjectsFromArray:[@[ kRFCommunityFeed ] arrayByAddingObjectsFromArray:kRFFeedScreens]];
}

// Covered feeds are scrolled back when their screen appears again (RFScreenAppearing); not back within 10
// minutes, they're left as they are.
static void RFWatchCoveredFeeds(void) {
  if (!RFFeedHasDeferred()) return;
  NSUInteger generation = ++gUndeferGeneration;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    if (generation != gUndeferGeneration) return;
    for (NSString *feed in RFCoveredFeeds()) RFFeedUndefer(@[ feed ], nil);
  });
}

static void RFReleaseCoveredFeeds(void) {
  gUndeferGeneration++;
  for (NSString *feed in RFCoveredFeeds()) RFFeedUndefer(@[ feed ], nil);
}

// The swipe back was cancelled: the screen's still covered, so a scroll back still due waits again.
static void RFScreenReturnCancelled(UIViewController *screen) {
  NSString *feedName = RFScreenFeedName(screen);
  NSArray *feeds = RFIsHomeScreen(screen) ? kRFHomeFeeds : feedName ? @[ feedName ] : @[ kRFCommunityFeed ];
  NSMutableArray *due = [NSMutableArray array];
  for (NSString *feed in feeds)
    if (RFFeedCacheRestoreTarget(feed, NULL, NULL)) [due addObject:feed];
  if (due.count) RFFeedDefer(due);
}

// Home, a community or one of Reddit's own feed screens is appearing (also as you start swiping back to
// it): its covered feed, if any.
static void RFScreenAppearing(UIViewController *screen) {
  if (!RFFeedHasDeferred()) return;
  if (RFIsHomeScreen(screen)) {
    RFFeedUndefer(kRFHomeFeeds, screen);
  } else if (RFIsClass(screen, kRFCommunityClass) &&
             [RFCommunityName(screen).lowercaseString isEqualToString:gDeferredCommunity.lowercaseString]) {
    RFFeedUndefer(@[ kRFCommunityFeed ], screen);
  } else {
    NSString *feed = RFScreenFeedName(screen);
    if (feed) RFFeedUndefer(@[ feed ], screen);
  }
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
// The list not moving while looking: how many steps in a row, at what offset (the page can end before
// its content does: RedditFilter's own end where "From your feed" was).
static CGFloat gStuckOffset;
static NSInteger gStuckTicks;
static NSInteger gFeedOnlyTicks; // looking, and only the posts after the comments on screen
static CGFloat gProbeStart, gProbeHeight;

static void RFOpenLink(NSString *link) {
  NSURL *url = [NSURL URLWithString:link];
  id<UIApplicationDelegate> delegate = UIApplication.sharedApplication.delegate;
  if (url && [delegate respondsToSelector:@selector(application:openURL:options:)])
    [delegate application:UIApplication.sharedApplication openURL:url options:@{}];
}

// The account the app's using, for the Latest factory. Reddit keeps it on the tab bar as a Swift property
// (there's no getter to call), and passes it to the factory as the app's account context. Only the tab
// bar's own value is taken: other view controllers can have a similar property (Games, say), and an object
// of another kind would be no use to the factory. nil if it isn't there or doesn't look like one.
static id RFAccountContext(void) {
  UITabBarController *tabs = RFTabBar();
  Ivar ivar = tabs ? class_getInstanceVariable(tabs.class, "accountContext") : NULL;
  if (!ivar) return nil;
  id value = (__bridge id)(*(void **)((uint8_t *)(__bridge void *)tabs + ivar_getOffset(ivar)));
  Class valueClass = object_getClass(value);
  // One object of a class (not a class itself nor a plain number), and the app's account context (Reddit's
  // own AccountContext class). Checked here so a renamed or moved property can't pass something else on.
  if (!value || !valueClass || class_isMetaClass(valueClass) || ![value isKindOfClass:NSObject.class]) return nil;
  if ([NSStringFromClass(valueClass) rangeOfString:@"AccountContext"].location == NSNotFound) return nil;
  return value;
}

// Latest (from the side menu). Reddit's feed screens are all one class, made by its own factory, and no link
// opens Latest (the drawer's row calls the factory directly), so it's opened the same way: Home's screen is
// pushed, as the row's does. Opening the drawer and tapping the row instead would go by its translated title.
static BOOL RFOpenLatestFeed(void) {
  Class factory = NSClassFromString(@"Feed_Legacy.FeedViewControllerFactory");
  SEL make = NSSelectorFromString(@"latestFeedViewControllerWithAccountContext:");
  id accountContext = RFAccountContext();
  UINavigationController *nav = RFHomeNavigation();
  if (!factory || !accountContext || ![factory respondsToSelector:make] || !nav) return NO;
  UIViewController *feed = ((id (*)(id, SEL, id))objc_msgSend)(factory, make, accountContext);
  if (![feed isKindOfClass:UIViewController.class]) return NO;
  [nav pushViewController:feed animated:NO];
  return YES;
}

static NSArray<NSDictionary *> *RFPlanScreens(void) { return gPlan[@"screens"]; }
static BOOL RFRestoreDone(void) { return !gWaitingForYou && gStep >= (NSInteger)RFPlanScreens().count; }
static NSDictionary *RFStepScreen(void) {
  return gStep >= 0 && gStep < (NSInteger)RFPlanScreens().count ? RFPlanScreens()[gStep] : nil;
}

static NSString *RFScreenKind(NSDictionary *screen) {
  return screen[@"community"] ? @"the community"
         : screen[@"feed"]    ? @"the custom feed"
         : screen[@"homeFeed"] ? ([screen[@"homeFeed"] isEqual:kRFPopularScreen] ? @"the Popular feed" : @"the Latest feed")
         : screen[@"profile"] ? @"the profile"
         : screen[@"search"]  ? @"the search"
         : screen[@"post"]    ? @"the post"
                              : @"";
}

// Home's tab's stack, whichever kind of Home the account has.
static UINavigationController *RFHomeNavigationIn(UITabBarController *tabs) {
  for (UIViewController *tab in tabs.viewControllers)
    if ([tab isKindOfClass:UINavigationController.class] &&
        RFIsHomeScreen(((UINavigationController *)tab).viewControllers.firstObject))
      return (UINavigationController *)tab;
  return nil;
}

// Selects the plan's other tab (the You tab or the Inbox), as a tap on it would.
static void RFSelectPlanTab(NSString *tab) {
  UITabBarController *tabs = RFTabBar();
  UINavigationController *other = RFPlanTabNavigation(tab);
  if (!other || tabs.selectedViewController == other) return;
  id<UITabBarControllerDelegate> delegate = tabs.delegate;
  if ([delegate respondsToSelector:@selector(tabBarController:shouldSelectViewController:)] &&
      ![delegate tabBarController:tabs shouldSelectViewController:other])
    return;
  tabs.selectedViewController = other;
  if ([delegate respondsToSelector:@selector(tabBarController:didSelectViewController:)])
    [delegate tabBarController:tabs didSelectViewController:other];
}

// Whether that tab has its own screen at its root yet (your profile, or the Inbox): until it's first shown
// it holds a placeholder, which is replaced (with anything pushed on it) once it is.
static BOOL RFPlanTabReady(NSString *tab) {
  return RFIsClass(RFPlanTabNavigation(tab).viewControllers.firstObject, RFPlanTabRoot(tab));
}

// Goes up whenever a move to the plan's tab still waiting must not happen any more (a new restore, a stop,
// another account). Main thread.
static unsigned gTabMoveGeneration;

// The screens opened on Home (`stack`, Home's whole stack as the restore left it) go over to that tab, on
// top of its own screen, and the tab's selected. Going back then works as it does there; Home is left at
// its feed (scrolled back when you go to it). Tried again for a moment if the tab's screen isn't in place
// yet, as long as nothing has changed meanwhile: the same restore, Home's stack as it was, the tab still
// selected.
static void RFMoveScreensToPlanTab(NSString *tab, NSArray<UIViewController *> *stack, unsigned generation, NSInteger tries) {
  if (generation != gTabMoveGeneration) return;
  UITabBarController *tabs = RFTabBar();
  UINavigationController *other = RFPlanTabNavigation(tab), *home = RFHomeNavigationIn(tabs);
  if (!other || !home || other == home || ![home.viewControllers isEqualToArray:stack]) return;
  if (!RFPlanTabReady(tab)) {
    // You went to another tab meanwhile: stays as you left it.
    if (tabs.selectedViewController != other || tries <= 0) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      RFMoveScreensToPlanTab(tab, stack, generation, tries - 1);
    });
    return;
  }
  if (tabs.selectedViewController != other) return;
  NSArray<UIViewController *> *moved = [stack subarrayWithRange:NSMakeRange(1, stack.count - 1)];
  [home setViewControllers:@[ stack.firstObject ] animated:NO];
  [other setViewControllers:[@[ other.viewControllers.firstObject ] arrayByAddingObjectsFromArray:moved] animated:NO];
}

static void RFMoveToPlanTab(NSString *tab, NSInteger tries) {
  UINavigationController *home = RFHomeNavigationIn(RFTabBar());
  NSArray<UIViewController *> *stack = home.viewControllers;
  if (stack.count < 2) return;
  RFSelectPlanTab(tab);
  RFMoveScreensToPlanTab(tab, stack, ++gTabMoveGeneration, tries);
}

static NSString *RFStepName(void) {
  if (gStep == kRFStepHome) return @"Home";
  if (gWaitingForYou) return [NSString stringWithFormat:@"the %@ tab", RFPlanTabName(gPlan[@"tab"])];
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

// Whether the comment you were at isn't among those the reopened post has (all of them in): it was in
// replies or a page Reddit only loads when asked.
static BOOL RFCommentNotLoaded(NSDictionary *plan) {
  NSString *postId = plan[@"id"], *comment = plan[@"comment"];
  if (!comment || !RFRowsSettled(postId) || RFRowsTruncated(postId)) return NO;
  NSArray *rows = RFRowsForPost(postId);
  return rows && [rows indexOfObjectPassingTest:^BOOL(NSDictionary *row, NSUInteger i, BOOL *stop) {
           return [row[@"id"] isEqual:comment];
         }] == NSNotFound;
}

// Reddit's own link to a comment opens the post at that comment (wherever it is, highlighted): that page
// takes the reopened one's place.
static __weak UIViewController *gLinkedFrom; // the reopened post, until its replacement is in
static NSDate *gLinkedAt;
static NSString *gLinkedPost;
static NSHashTable<UIViewController *> *gLinkedBefore; // Home's screens before the link opened

// Selects a tab as a tap on it would (asking Reddit first).
static void RFSelectTab(UIViewController *tab) {
  UITabBarController *tabs = RFTabBar();
  if (!tab || tabs.selectedViewController == tab) return;
  id<UITabBarControllerDelegate> delegate = tabs.delegate;
  if ([delegate respondsToSelector:@selector(tabBarController:shouldSelectViewController:)] &&
      ![delegate tabBarController:tabs shouldSelectViewController:tab])
    return;
  tabs.selectedViewController = tab;
  if ([delegate respondsToSelector:@selector(tabBarController:didSelectViewController:)])
    [delegate tabBarController:tabs didSelectViewController:tab];
}

static void RFReplaceWithLinked(void) {
  UIViewController *old = gLinkedFrom;
  if (!old || -gLinkedAt.timeIntervalSinceNow > 6) {
    gLinkedFrom = nil;
    gLinkedBefore = nil;
    return;
  }
  UINavigationController *home = RFHomeNavigationIn(RFTabBar());
  UIViewController *opened = home.viewControllers.lastObject;
  // A page that's new since the link opened, for that post, done arriving.
  BOOL arrived = opened && opened != old && ![gLinkedBefore containsObject:opened] &&
                 [RFCall(RFPostScreen(opened), @"initialPostPk") isEqual:gLinkedPost] && !opened.transitionCoordinator;
  if (!arrived) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      RFReplaceWithLinked();
    });
    return;
  }
  gLinkedFrom = nil;
  gLinkedBefore = nil;
  UINavigationController *nav = old.navigationController;
  // The reopened post as its stack holds it (itself, or the pager it's in).
  UIViewController *held = old;
  while (held && ![nav.viewControllers containsObject:held]) held = held.parentViewController;
  NSUInteger at = held ? [nav.viewControllers indexOfObject:held] : NSNotFound;
  if (!nav || at == NSNotFound) return; // gone meanwhile: the linked page just stays where it opened
  if (nav == home) {
    NSMutableArray *stack = [nav.viewControllers mutableCopy];
    [stack removeObject:opened];
    stack[at] = opened;
    [nav setViewControllers:stack animated:NO];
    return;
  }
  // Links always open on Home: on another tab (the You tab), the page moves over to it.
  NSMutableArray *homeStack = [home.viewControllers mutableCopy];
  [homeStack removeObject:opened];
  [home setViewControllers:homeStack animated:NO];
  NSMutableArray *stack = [nav.viewControllers mutableCopy];
  stack[at] = opened;
  [nav setViewControllers:stack animated:NO];
  RFSelectTab(nav);
}

static void RFJumpByLink(NSDictionary *plan) {
  NSString *postId = plan[@"id"], *community = plan[@"community"];
  NSString *link = community ? [NSString stringWithFormat:@"https://www.reddit.com/r/%@/comments/%@/_/%@/", community,
                                                          [postId substringFromIndex:3], [plan[@"comment"] substringFromIndex:3]]
                             : [NSString stringWithFormat:@"https://www.reddit.com/comments/%@/_/%@/", [postId substringFromIndex:3],
                                                          [plan[@"comment"] substringFromIndex:3]];
  gLinkedFrom = gJumpScreen;
  gLinkedAt = NSDate.date;
  gLinkedPost = postId;
  gLinkedBefore = [NSHashTable weakObjectsHashTable];
  for (UIViewController *vc in RFHomeNavigationIn(RFTabBar()).viewControllers) [gLinkedBefore addObject:vc];
  RFHideJump(0);
  RFOpenLink(link);
  RFReplaceWithLinked();
}

// Whether the jump can fall back on Reddit's link to the comment.
static BOOL RFCanJumpByLink(NSDictionary *plan) {
  return [plan[@"comment"] hasPrefix:@"t1_"] && [plan[@"comment"] length] > 3 && [plan[@"id"] length] > 3;
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
  // You've taken over (a drag, or its glide): it stops where you are, nothing more opened.
  if (scrolledYourself || list.isDecelerating) {
    gProbeList = nil;
    return RFHideJump(0);
  }
  // Not among the post's comments: in replies you'd opened, Reddit's link to it (the post can't open them
  // again); in a later page, the post is taken down until Reddit loads it (RFScrollComments).
  if (RFCanJumpByLink(gJumpPlan) && RFCommentNotLoaded(gJumpPlan) &&
      ([gJumpPlan[@"inReplies"] boolValue] || !RFCommentRowsHaveNextPage(RFRowsForPost(gJumpPlan[@"id"]))))
    return RFJumpByLink(gJumpPlan);
  // Longer when it may take a few pages to get there.
  if (!RFScrollComments(post, gJumpPlan) && -[gJumpStart timeIntervalSinceNow] < ([gJumpPlan[@"inReplies"] boolValue] ? 15 : 30)) return;
  scrolledYourself = scrolledYourself || list.isDecelerating;
  // Not found: back to where it started (unless you've taken over).
  if (!gJumpFound && gProbeList && !scrolledYourself)
    gProbeList.contentOffset = CGPointMake(gProbeList.contentOffset.x, gProbeStart);
  gProbeList = nil;
  gJumping = NO;
  if (gJumpFound || scrolledYourself) return RFHideJump(0);
  // Not found on the page as it is (its comments not all loaded, or not laid out): Reddit's link finds it.
  if (RFCanJumpByLink(gJumpPlan)) return RFJumpByLink(gJumpPlan);
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
  gStuckTicks = 0;
  gFeedOnlyTicks = 0;
  gStuckOffset = -CGFLOAT_MAX;
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

// What was open waits for a return to Home, above `nav` as it is now.
static void RFPark(NSDictionary *plan, UINavigationController *nav) {
  gParked = plan;
  gParkedNav = nav;
  gParkedDepth = nav.viewControllers.count;
  gParkedAt = NSDate.date;
}

// What was waiting for a return to Home won't be reopened: why, for Diagnostics.
static void RFDropParked(NSString *why) {
  if (!gParked && !gParkAfter) return;
  gParked = nil;
  gParkAfter = nil;
  gParkedNav = nil;
  if (why) gOutcome = why;
  RFWriteFile(@"Parked.json", nil, nil);
}

static void RFFinishRestore(void) {
  if (gPlan && !RFRestoreDone() && !gOutcome.length) gOutcome = [NSString stringWithFormat:@"stopped (left while opening %@)", RFStepName()];
  BOOL reopened = gReopened;
  NSString *planTab = gPlan[@"tab"];
  BOOL toYou = planTab && ![planTab isEqualToString:@"home"]; // the You tab or the Inbox
  // For the You tab, what's been opened (on Home) goes over to it, once it's the right account.
  // Not when it was stopped for another account or incognito: those screens aren't the new account's.
  if (gPlan && gStep != kRFStepHome && toYou && !gStoppedForUser) RFMoveToPlanTab(planTab, 60);
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
  gResumed = NO;
  // What was waiting when Reddit was last left waits again, above what's open now (unless this launch's own
  // screens are waiting instead).
  // Only once this launch's restore has finished: after Skip or a time-out, it's not brought up later.
  NSDictionary *parkAfter = gParkAfter;
  gParkAfter = nil;
  UINavigationController *home = RFHomeNavigationIn(RFTabBar());
  if (parkAfter && !gParked) {
    if (reopened && home) {
      RFPark(parkAfter, home);
      // Screens reopened for the You tab move off Home (later): Home is then just Home.
      if (toYou) gParkedDepth = 1;
    } else {
      RFWriteFile(@"Parked.json", nil, nil);
    }
  }
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

// Whether a post page shows the post yet: some text in its first section (the loading placeholder has none),
// or anywhere for a post opened at a comment (Reddit scrolls past the post to it).
static BOOL RFPostShown(UICollectionView *list, BOOL atComment) {
  if (!list.numberOfSections) return NO;
  for (UICollectionViewCell *cell in list.visibleCells) {
    if ((!atComment && [list indexPathForCell:cell].section != 0) || !cell.contentView) continue;
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
  } else if (screen[@"feed"]) {
    RFOpenLink([NSString stringWithFormat:@"https://www.reddit.com/user/%@/m/%@/", screen[@"feed"][@"user"], screen[@"feed"][@"name"]]);
  } else if (screen[@"profile"]) {
    RFOpenLink([NSString stringWithFormat:@"https://www.reddit.com/user/%@/", screen[@"profile"]]);
  } else if (screen[@"homeFeed"]) {
    // Its kept feed only comes back when the restore opens it (FeedCache.m): the side menu opens these
    // fresh, so a kept one would show hours-old posts with today's below them.
    BOOL popular = [screen[@"homeFeed"] isEqual:kRFPopularScreen];
    RFFeedCacheArmFeed(popular ? kRFPopularFeed : kRFLatestFeed);
    if (popular) {
      RFOpenLink(@"https://www.reddit.com/r/popular/");
    } else if (!RFOpenLatestFeed()) {
      // Nothing opened (no account context, or Reddit dropped the factory): the step times out as any does,
      // and Latest opened from the side menu meanwhile isn't a reopened one.
      RFFeedCacheDisarmFeed(kRFLatestFeed);
    }
  } else if (screen[@"search"]) {
    NSMutableCharacterSet *allowed = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
    [allowed removeCharactersInString:@"&+=?#"];
    NSString *query = [screen[@"search"] stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    NSString *base = screen[@"in"] ? [NSString stringWithFormat:@"https://www.reddit.com/r/%@/search/?q=", screen[@"in"]]
                                   : @"https://www.reddit.com/search/?q=";
    if (query) RFOpenLink([base stringByAppendingString:query]);
  } else if (screen[@"post"]) {
    NSDictionary *post = screen[@"post"];
    NSString *postId = post[@"id"];
    gProbeList = nil;
    gProbeHeight = 0;
    RFForgetRows(postId); // only the comments it gets now count
    NSString *community = post[@"community"];
    NSString *link = community ? [NSString stringWithFormat:@"https://www.reddit.com/r/%@/comments/%@/", community, [postId substringFromIndex:3]]
                               : [NSString stringWithFormat:@"https://www.reddit.com/comments/%@/", [postId substringFromIndex:3]];
    // Opened at a comment (from the Inbox, say): at that comment again.
    if (post[@"focus"]) link = [link stringByAppendingFormat:@"_/%@/", [post[@"focus"] substringFromIndex:3]];
    RFOpenLink(link);
  }
}

static void RFNextStep(void) {
  if (gStep + 1 < (NSInteger)RFPlanScreens().count) return RFStartStep(gStep + 1);
  // For the You tab or the Inbox: it's selected, and once its own screen's in place what was opened goes
  // over to it.
  NSString *tab = gPlan[@"tab"];
  if (![tab isEqualToString:@"home"] && !gWaitingForYou && !RFPlanTabReady(tab)) {
    gWaitingForYou = YES;
    gStep = RFPlanScreens().count;
    gStepStart = NSDate.date;
    gSteady = 0;
    RFSelectPlanTab(tab);
    return;
  }
  gStep = RFPlanScreens().count;
  if (!gOutcome.length) {
    NSMutableArray *kinds = [NSMutableArray array];
    for (NSDictionary *screen in RFPlanScreens()) [kinds addObject:[RFScreenKind(screen) substringFromIndex:4]];
    if (![tab isEqualToString:@"home"]) [kinds insertObject:[RFPlanTabName(tab) stringByAppendingString:@" tab"] atIndex:0];
    gOutcome = [NSString stringWithFormat:@"%@reopened %@", gResumed ? @"back on Home: " : @"", [kinds componentsJoinedByString:@" > "]];
    gReopened = YES;
  }
  RFFinishRestore();
}

// Scrolls the post down, to have Reddit ask for (or lay out) more: only under the cover or while jumping,
// untouched. Where it started is kept, to go back to if the comment isn't found.
static void RFScrollToEnd(UICollectionView *list, NSInteger direction) {
  if ((!gCover && !gJumping) || list.isTracking || list.isDragging || list.isDecelerating) return;
  if (gProbeList != list) {
    gProbeList = list;
    gProbeStart = list.contentOffset.y;
    gProbeHeight = 0;
  }
  // A screen at a time, not straight to the end: each section is laid out (and checked) on the way, and
  // the posts Reddit lists after the comments (which load more as they're reached) aren't run into.
  CGFloat top = -list.adjustedContentInset.top;
  CGFloat bottom = MAX(top, list.contentSize.height + list.adjustedContentInset.bottom - list.bounds.size.height);
  CGFloat next = MIN(bottom, MAX(top, list.contentOffset.y + direction * list.bounds.size.height * 0.8));
  if (fabs(next - list.contentOffset.y) > 1) list.contentOffset = CGPointMake(list.contentOffset.x, next);
}

static BOOL RFListStuck(UICollectionView *list, NSInteger ticks) {
  if (fabs(list.contentOffset.y - gStuckOffset) > 0.5) {
    gStuckOffset = list.contentOffset.y;
    gStuckTicks = 0;
  }
  return ++gStuckTicks >= ticks;
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
    // Or the first pages only: Reddit loads the next as the end is reached.
    if (RFRowsTruncated(postId) || (gJumping && ![plan[@"inReplies"] boolValue] && RFCommentRowsHaveNextPage(rows))) {
      RFScrollToEnd(list, 1);
      return NO;
    }
    if (gProbeList) gProbeList.contentOffset = CGPointMake(gProbeList.contentOffset.x, gProbeStart);
    gProbeList = nil;
    return YES;
  }
  // Items are the post, then one per row; measured from a comment on screen in case there's more first.
  // Measured from a comment whose author and level are the only ones in the thread (the same row nearest
  // either end), so it can't be taken for another; failing that, the first one recognised.
  NSInteger base = 1;
  BOOL measured = NO;
  for (UICollectionViewCell *cell in RFCellsTopFirst(list)) {
    NSIndexPath *path = [list indexPathForCell:cell];
    NSInteger flat = path ? RFFlatIndex(list, path) : 0;
    if (flat == 0) continue;
    NSUInteger row = RFRowOfCommentCell(rows, cell, 0);
    if (row == NSNotFound) continue;
    BOOL only = rows.count && RFRowOfCommentCell(rows, cell, rows.count - 1) == row;
    if (!only && measured) continue;
    if (!only) {
      row = RFRowOfCommentCell(rows, cell, flat - 1);
      if (row == NSNotFound) continue;
    }
    base = flat - (NSInteger)row;
    measured = YES;
    if (only) break;
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
  // Not on screen: a screen further, looking again each time (up if the comments on screen come after
  // it). Counting items to it doesn't work: Reddit collapses some replies, so there are fewer items than
  // rows, and past the comments come the posts Reddit lists after them.
  if (!shown) {
    NSUInteger onScreen = NSNotFound;
    BOOL feedShown = NO;
    for (UICollectionViewCell *cell in RFCellsTopFirst(list)) {
      if ([NSStringFromClass(cell.class) containsString:@"FeedStackSliceViewModel"]) {
        feedShown = YES;
        continue;
      }
      if (onScreen == NSNotFound) onScreen = rowOfCell(cell);
    }
    // Down to those posts with no comment of the post's on screen for a while (not just while a section
    // is laid out): it isn't there.
    gFeedOnlyTicks = feedShown && onScreen == NSNotFound ? gFeedOnlyTicks + 1 : 0;
    if (gFeedOnlyTicks >= 10) return YES;
    // At the end of the page with nothing more to come: it isn't there.
    if (RFListStuck(list, 30) && !RFRowsTruncated(postId) && !RFCommentRowsHaveNextPage(rows)) return YES;
    RFScrollToEnd(list, onScreen != NSNotFound && onScreen > target ? -1 : 1);
    return NO;
  }
  NSIndexPath *path = shown;
  RFScrollResult result = RFScrollListToItem(list, path, offset, NO,
                                             ^BOOL(UICollectionViewCell *cell) {
                                               return rowOfCell(cell) == target;
                                             });
  // On screen, but the page goes no further: it's as far up as it can be.
  if (result == RFScrollPending && RFListStuck(list, 4) && allLoaded) result = RFScrollPlaced;
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
                    !RFIsHomeScreen(((UINavigationController *)selected).viewControllers.firstObject);
    if (nav.viewControllers.count > 1 || otherTab) {
      // What was open on Home comes back when you go back to Home from that screen (not for the You tab,
      // which going back to Home has nothing to do with).
      if ([gPlan[@"tab"] isEqualToString:@"home"]) {
        UINavigationController *shown = otherTab ? (UINavigationController *)selected : nav;
        RFPark(gPlan, shown);
        gOutcome = @"waiting (Reddit opened a screen): reopens when you go back to Home";
      } else {
        gOutcome = @"skipped (Reddit opened a screen)";
      }
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
    gSteady = RFPlanTabReady(gPlan[@"tab"]) ? gSteady + 1 : 0;
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
  } else if (screen[@"feed"]) {
    // Opens at its top (it isn't kept like a community): done once its posts show.
    NSDictionary *feed = RFIsClass(top, kRFCustomFeedClass) && top.viewIfLoaded.window ? RFCustomFeed(top) : nil;
    BOOL right = [[feed[@"name"] lowercaseString] isEqualToString:[screen[@"feed"][@"name"] lowercaseString]] &&
                 [[feed[@"user"] lowercaseString] isEqualToString:[screen[@"feed"][@"user"] lowercaseString]];
    UICollectionView *list = right ? RFListIn(top) : nil;
    BOOL ready = list && RFListShowsPosts(list);
    gSteady = ready ? gSteady + 1 : 0;
    if (gSteady >= 2 || late) RFNextStep();
  } else if (screen[@"homeFeed"]) {
    // Popular, or Latest: opened as the app opens it, with its kept posts replayed and scrolled back.
    NSString *feed = [screen[@"homeFeed"] isEqual:kRFPopularScreen] ? kRFPopularFeed : kRFLatestFeed;
    BOOL shown = [RFHomeFeedScreen(top) isEqualToString:screen[@"homeFeed"]] && top.viewIfLoaded.window;
    if (shown && !last) {
      // More goes on top: its scroll back waits until you go back to it.
      RFFeedDefer(@[ feed ]);
      return RFNextStep();
    }
    UICollectionView *list = shown ? RFListIn(top) : nil;
    BOOL ready = list && RFListShowsPosts(list);
    gSteady = ready ? gSteady + 1 : 0;
    if (gSteady >= 2 || late) {
      // On top, so its scroll back can go ahead (Home's feeds waited to see if anything would cover them).
      if (shown) RFFeedUndefer(@[ feed ], top);
      RFNextStep();
    }
  } else if (screen[@"search"]) {
    // The results open at their top: done once the search is showing with its query.
    // In a community: once its answer has said so too (so the next screen doesn't take its answer).
    BOOL ready = RFIsClass(top, kRFSearchClass) && top.viewIfLoaded.window &&
                 [RFSearchQuery(top).lowercaseString isEqualToString:[screen[@"search"] lowercaseString]] &&
                 (!screen[@"in"] || [RFSearchCommunity(top).lowercaseString isEqualToString:[screen[@"in"] lowercaseString]]);
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
    BOOL shown = list && RFPostShown(list, screen[@"post"][@"focus"] != nil);
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
  if (![screen isKindOfClass:NSDictionary.class]) return NO;
  id community = screen[@"community"], profile = screen[@"profile"], post = screen[@"post"], search = screen[@"search"];
  // A search can say which community it was in; everything else is one thing.
  if (search && screen[@"in"]) return [screen count] == 2 && RFIsText(search) && [search length] <= 512 && RFIsCommunityName(screen[@"in"]);
  if ([screen count] != 1) return NO;
  if (community) return RFIsCommunityName(community);
  if (screen[@"feed"]) {
    NSDictionary *feed = screen[@"feed"];
    return [feed isKindOfClass:NSDictionary.class] && feed.count == 2 && RFIsUsername(feed[@"user"]) && RFIsCustomFeedName(feed[@"name"]);
  }
  if (search) return RFIsText(search) && [search length] <= 512;
  if (screen[@"homeFeed"])
    return [screen[@"homeFeed"] isEqual:kRFPopularScreen] || [screen[@"homeFeed"] isEqual:kRFLatestScreen];
  if (profile) return RFIsUsername(profile);
  if (![post isKindOfClass:NSDictionary.class]) return NO;
  NSString *postId = post[@"id"];
  if (!RFIsText(postId) || ![postId hasPrefix:@"t3_"] || postId.length < 4) return NO;
  if (post[@"community"] && !RFIsCommunityName(post[@"community"])) return NO;
  if (post[@"focus"] && !([post[@"focus"] isKindOfClass:NSString.class] && [post[@"focus"] hasPrefix:@"t1_"] &&
                           RFIsLinkName([post[@"focus"] substringFromIndex:3], 1, 20, NO)))
    return NO;
  return !(post[@"comment"] && !RFIsText(post[@"comment"])) && !(post[@"offset"] && !RFIsNumber(post[@"offset"]));
}

// Screens.json if everything in it is what it should be (an older or damaged one isn't used).
static NSDictionary *RFValidPlan(NSDictionary *plan) {
  if (!plan || !RFIsNumber(plan[@"leftAt"]) || !RFIsText(plan[@"account"])) return nil;
  NSString *tab = plan[@"tab"];
  NSArray *screens = plan[@"screens"];
  id size = plan[@"pictureSize"];
  if (![tab isEqual:@"home"] && ![tab isEqual:@"you"] && ![tab isEqual:@"inbox"]) return nil;
  if (![screens isKindOfClass:NSArray.class] || screens.count > kRFMaxScreens) return nil;
  if (!screens.count && ![tab isEqual:@"you"]) return nil;
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
  // Whatever happened, what was waiting last time has had its chance (a restore under way holds it).
  RFWriteFile(@"Parked.json", nil, nil);
}

// Starts reopening `plan` from the Home step, under a cover.
static void RFBeginRestore(NSDictionary *plan, UIWindow *window) {
  gTabMoveGeneration++;
  gPlan = plan;
  gOutcome = @"";
  gReopened = NO;
  gStoppedForUser = NO;
  gRestoreStart = gStepStart = gPlanStart = NSDate.date;
  gStep = kRFStepHome;
  gSteady = 0;
  gRestoreTimer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                                  repeats:YES
                                                    block:^(NSTimer *timer) {
                                                      RFRestoreTick();
                                                    }];
  [NSRunLoop.mainRunLoop addTimer:gRestoreTimer forMode:NSRunLoopCommonModes];
  if (window) RFShowCover(window);
}

// A kept plan that's still to be used: valid, and not left too long ago.
static NSDictionary *RFUsablePlan(NSDictionary *plan, BOOL *tooOld) {
  plan = RFValidPlan(plan);
  NSTimeInterval away = plan ? NSDate.date.timeIntervalSince1970 - [plan[@"leftAt"] doubleValue] : -1;
  if (plan && (away < 0 || (gMaxAge > 0 && away > gMaxAge))) {
    if (tooOld) *tooOld = YES;
    return nil;
  }
  return plan;
}

static void RFPlanRestoreNow(void) {
  if (!RFFeedCacheEnabled()) return (void)(gOutcome = @"nothing (Keep feed position off)");
  if (!RFMayRestore()) return (void)(gOutcome = @"skipped (swiped away)");
  if (!gRestoreScreens) return (void)(gOutcome = @"feeds only (Reopen community and post off)");
  BOOL tooOld = NO;
  NSDictionary *plan = RFUsablePlan(RFReadJSON(@"Screens.json"), &tooOld);
  // What was waiting for a return to Home when Reddit was left (only for a Home plan).
  NSDictionary *parked = RFUsablePlan(RFReadJSON(@"Parked.json"), NULL);
  if (![parked[@"tab"] isEqualToString:@"home"]) parked = nil;
  // Once only: a crash during the restore shouldn't bring it back again.
  RFWriteJSON(@"Screens.json", nil, nil);
  RFWriteJSON(@"Parked.json", nil, nil);
  // Left on Home with something waiting: that's what was open before.
  if (!plan && parked) {
    plan = parked;
    parked = nil;
  }
  if (!plan) return (void)(gOutcome = tooOld ? @"skipped (too long ago)" : @"nothing to reopen");
  RFBeginRestore(plan, RFMainWindow());
  gParkAfter = parked;
}

// Back on Home with nothing on top, after Reddit opened a screen at launch: what was open before is reopened
// now, as at launch (a plain cover; the picture was of a screen that's been replaced since).
static void RFResumeParked(UIViewController *home) {
  NSDictionary *plan = gParked;
  if (!plan || gPlan) return;
  UINavigationController *nav = home.navigationController;
  if (nav != RFHomeNavigation() || nav.viewControllers.count != 1 || !home.viewIfLoaded.window) return;
  if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
  if (!gRestoreScreens || !RFFeedCacheEnabled()) return RFDropParked(@"dropped (turned off)");
  if (RFFeedCacheIncognito()) return RFDropParked(@"dropped (incognito)");
  if (!RFUsablePlan(plan, NULL)) return RFDropParked(@"dropped (too long ago)");
  RFDropParked(nil);
  NSMutableDictionary *resumed = [plan mutableCopy];
  [resumed removeObjectForKey:@"pictureSize"];
  RFBeginRestore(resumed, home.view.window);
  gResumed = YES;
}

// Going further than the screen Reddit opened (another screen on top of it): what was waiting won't be
// reopened (Back then goes to that screen, not to Home).
%group RFParkedNavigationHooks
%hook UINavigationController
- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
  %orig;
  // (Not the page "Back to where you were" opens by link: it takes the reopened post's place.)
  BOOL linking = gLinkedFrom && -gLinkedAt.timeIntervalSinceNow < 6;
  if (gParked && self == gParkedNav && self.viewControllers.count > gParkedDepth && -gParkedAt.timeIntervalSinceNow > 1.5 &&
      !linking)
    RFDropParked(@"dropped (you went further than the screen Reddit opened)");
}
%end
%end

@interface RFHomeScreen : UIViewController
@end
@interface RFCommunityScreen : UIViewController
@end
@interface RFHomeFeedScreenClass : UIViewController
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

// Home, hooked on the class in use (kRFHomeClass) only: it's a subclass of kRFHomeTabClass, so hooking that
// too would run these twice.
%group RFHomeScreenHooks
%hook RFHomeScreen
- (void)viewWillAppear:(BOOL)animated {
  %orig;
  RFScreenAppearing((UIViewController *)self);
  RFWatchCancelledReturn((UIViewController *)self);
}
// Once a swipe back has finished, not as it starts (it can be cancelled).
- (void)viewDidAppear:(BOOL)animated {
  %orig;
  if (gParked) RFResumeParked((UIViewController *)self);
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

// One of Reddit's own feed screens (Popular, Latest) appearing again after a post was reopened on top of it:
// its feed is scrolled back.
%group RFHomeFeedScreenHooks
%hook RFHomeFeedScreenClass
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

// A custom feed screen notes which feed it is from the custom feed requests made as it opens (its link and
// Swift code don't go through anything readable): its own, made within a few seconds of it loading while
// it's on top, or failing that one made just before it loaded. See RFScreenRestoreCustomFeedRequest.
static __weak UIViewController *gOpeningCustomFeed; // main thread, like the rest
static NSDate *gOpeningCustomFeedAt;
static NSString *gCustomFeedPath; // a request with no screen to name yet, and when
static NSDate *gCustomFeedPathAt;
static NSString *gNamedPath;      // the last path that named a screen, and when (its own later requests
static NSDate *gNamedPathAt;      // aren't another screen's)

static const void *kRFCustomFeedOwnKey = &kRFCustomFeedOwnKey; // the path its own request had

static void RFNamedCustomFeed(UIViewController *feed, NSString *path) {
  RFNoteCustomFeed(feed, path);
  gNamedPath = path;
  gNamedPathAt = NSDate.date;
  gCustomFeedPath = nil;
}

%group RFCustomFeedHooks
%hook RFCustomFeedScreen
- (void)viewDidLoad {
  %orig;
  UIViewController *feed = (UIViewController *)self;
  // A request made just before (it can come first): a first guess, which its own request can still change.
  if (gCustomFeedPath && -gCustomFeedPathAt.timeIntervalSinceNow < 2) RFNamedCustomFeed(feed, gCustomFeedPath);
  gOpeningCustomFeed = feed;
  gOpeningCustomFeedAt = NSDate.date;
}
%end
%end

void RFScreenRestoreCustomFeedRequest(NSURLRequest *request) {
  if (RFFeedCacheRequestIsIncognito(request)) return;
  NSDictionary *body = request.HTTPBody.length ? [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:NULL] : nil;
  NSDictionary *variables = [body isKindOfClass:NSDictionary.class] ? body[@"variables"] : nil;
  NSString *path = [variables isKindOfClass:NSDictionary.class] ? variables[@"path"] : nil;
  id after = [variables isKindOfClass:NSDictionary.class] ? variables[@"after"] : nil;
  if (![path isKindOfClass:NSString.class] || ([after isKindOfClass:NSString.class] && [after length])) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    UIViewController *feed = gOpeningCustomFeed;
    if (feed && -gOpeningCustomFeedAt.timeIntervalSinceNow < 5 && feed.navigationController.topViewController == feed) {
      // Once its own request has named it, only that feed (a late one from the screen before isn't it).
      NSString *own = objc_getAssociatedObject(feed, kRFCustomFeedOwnKey);
      if (own && ![own isEqualToString:path]) return;
      objc_setAssociatedObject(feed, kRFCustomFeedOwnKey, path, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      // A path that can't be read: not the first guess either.
      objc_setAssociatedObject(feed, kRFCustomFeedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      RFNamedCustomFeed(feed, path);
      return;
    }
    gOpeningCustomFeed = nil;
    // The feed just named asking again (its posts, a refresh, another sort) isn't for the next screen.
    if ([path isEqualToString:gNamedPath] && -gNamedPathAt.timeIntervalSinceNow < 30) return;
    gCustomFeedPath = path;
    gCustomFeedPathAt = NSDate.date;
  });
}

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
  gTabMoveGeneration++; // a move to the You tab or the Inbox still waiting doesn't happen
  RFDropParked([why stringByReplacingOccurrencesOfString:@"stopped" withString:@"dropped"]);
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
  gCommentFocus = [NSMutableDictionary dictionary];
  gLastSession = RFReadJSON(@"Session.json");
  // Home and communities, to scroll back a feed that was covered by the screens reopened on top.
  Class home = NSClassFromString(kRFHomeClass), community = NSClassFromString(kRFCommunityClass);
  if ([home isSubclassOfClass:UIViewController.class]) %init(RFHomeScreenHooks, RFHomeScreen = home);
  if ([community isSubclassOfClass:UIViewController.class]) %init(RFCommunityScreenHooks, RFCommunityScreen = community);
  Class profile = NSClassFromString(kRFProfileClass);
  if ([profile isSubclassOfClass:UIViewController.class]) %init(RFProfileScreenHooks, RFProfileScreen = profile);
  Class homeFeed = NSClassFromString(kRFLegacyFeedClass);
  if ([homeFeed isSubclassOfClass:UIViewController.class]) %init(RFHomeFeedScreenHooks, RFHomeFeedScreenClass = homeFeed);
  %init(RFParkedNavigationHooks);
  Class customFeed = NSClassFromString(kRFCustomFeedClass);
  if ([customFeed isSubclassOfClass:UIViewController.class]) %init(RFCustomFeedHooks, RFCustomFeedScreen = customFeed);
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
                    RFForgetSearches();
                  }];
}
