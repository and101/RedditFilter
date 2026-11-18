// Start on Following.
//
// Where an account still has Home's For You and Following tabs, Reddit opens Home on whichever of them
// was last open. It keeps that per account in the app's defaults: AccountSettings-<account> holds
// kLastVisitedHomeFeed, "forYou" or "following", read when Home is built (at launch, or after switching
// account). This sets it to "following" for every account at launch, when the setting is turned on, and
// whenever the app goes to the background, so a look at For You doesn't stick. Accounts without the tabs
// (a single Home feed) keep the key too but don't use it.
#import <UIKit/UIKit.h>
#import "HomeStartFeed.h"

static NSString *const kRFAccountSettingsPrefix = @"AccountSettings-";
static NSString *const kRFLastHomeFeedKey = @"kLastVisitedHomeFeed";
static NSString *const kRFFollowing = @"following";

static BOOL gStartOnFollowing;
static id gBackgroundObserver;

static void RFSetFollowingForEveryAccount(void) {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  for (NSString *key in defaults.dictionaryRepresentation.allKeys) {
    if (![key hasPrefix:kRFAccountSettingsPrefix]) continue;
    // Read just before writing, so nothing Reddit saved in the meantime is lost.
    NSDictionary *settings = [defaults objectForKey:key];
    // Only accounts Reddit has noted a Home feed for; the logged-out one has none.
    if (![settings isKindOfClass:NSDictionary.class] || ![settings[kRFLastHomeFeedKey] isKindOfClass:NSString.class] ||
        [settings[kRFLastHomeFeedKey] isEqualToString:kRFFollowing])
      continue;
    NSMutableDictionary *changed = [settings mutableCopy];
    changed[kRFLastHomeFeedKey] = kRFFollowing;
    [defaults setObject:changed forKey:key];
  }
}

void RFSetStartOnFollowing(BOOL start) {
  dispatch_block_t apply = ^{
    gStartOnFollowing = start;
    if (start) RFSetFollowingForEveryAccount();
    if (start && !gBackgroundObserver) {
      gBackgroundObserver = [NSNotificationCenter.defaultCenter
          addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue
                  usingBlock:^(NSNotification *note) {
                    if (gStartOnFollowing) RFSetFollowingForEveryAccount();
                  }];
    }
  };
  if (NSThread.isMainThread) apply();
  else dispatch_async(dispatch_get_main_queue(), apply);
}

// Home's feed tabs are RPLTab controls in Home's own view (none where the account has a single feed).
static NSUInteger RFCountTabs(UIView *root, Class tabClass) {
  NSUInteger tabs = 0, seen = 0;
  NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
  while (queue.count && seen++ < 3000) {
    UIView *view = queue.firstObject;
    [queue removeObjectAtIndex:0];
    if ([view isKindOfClass:tabClass]) {
      tabs++;
      continue;
    }
    [queue addObjectsFromArray:view.subviews];
  }
  return tabs;
}

BOOL RFHomeHasFeedTabs(void) {
  Class tabClass = NSClassFromString(@"RPLComponents.RPLTab");
  Class homeClass = NSClassFromString(@"Home_Impl.HomeScreenViewController");
  if (!tabClass || !homeClass) return NO;
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class]) continue;
    for (UIWindow *window in ((UIWindowScene *)scene).windows) {
      NSMutableArray<UIViewController *> *queue = [NSMutableArray array];
      if (window.rootViewController) [queue addObject:window.rootViewController];
      for (NSUInteger seen = 0; queue.count && seen < 200; seen++) {
        UIViewController *controller = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([controller isKindOfClass:homeClass]) return controller.isViewLoaded && RFCountTabs(controller.view, tabClass) >= 2;
        [queue addObjectsFromArray:controller.childViewControllers];
      }
    }
  }
  return NO;
}
