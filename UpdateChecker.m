// Update check: once a day, a few seconds after the app opens, asks GitHub for the latest
// RedditFilter release and, if it's newer, shows an alert once for that version. Turned off with
// "Check for updates" in RedditFilter settings. Pre-releases and drafts are never offered.
#import <UIKit/UIKit.h>
#import "Preferences.h"
#import "RFVersion.h"
#import "UpdateChecker.h"

#ifndef RF_VERSION
#define RF_VERSION "dev" // the Makefile passes the real version
#endif

static NSString *const kLatestReleaseURL = @"https://api.github.com/repos/and101/RedditFilter/releases/latest";
static NSString *const kReleasesPage = @"https://github.com/and101/RedditFilter/releases";
static NSString *const kLastCheckKey = @"kRedditFilterUpdateLastCheck";   // NSDate of the last successful check
static NSString *const kLastTryKey = @"kRedditFilterUpdateLastTry";       // NSDate of the last attempt
static NSString *const kLatestKey = @"kRedditFilterUpdateLatest";         // version string
static NSString *const kLatestPageKey = @"kRedditFilterUpdateLatestPage"; // release page URL string
static NSString *const kAlertedKey = @"kRedditFilterUpdateAlerted";       // version last alerted about
static const NSTimeInterval kCheckInterval = 24 * 60 * 60;
static const NSTimeInterval kRetryInterval = 60 * 60; // after a failed check, e.g. offline
static const NSTimeInterval kDelayAfterLaunch = 4;

NSString *RFAvailableUpdate(void) {
  NSString *latest = [NSUserDefaults.standardUserDefaults stringForKey:kLatestKey];
  return RFVersionIsNewer(latest, @RF_VERSION) ? latest : nil;
}

NSURL *RFUpdateURL(void) {
  NSString *page = RFAvailableUpdate() ? [NSUserDefaults.standardUserDefaults stringForKey:kLatestPageKey] : nil;
  return [NSURL URLWithString:page ?: kReleasesPage];
}

static UIViewController *RFTopViewController(void) {
  UIWindow *window = nil;
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive)
      continue;
    for (UIWindow *candidate in ((UIWindowScene *)scene).windows)
      if (candidate.isKeyWindow) window = candidate;
  }
  UIViewController *top = window.rootViewController;
  while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
  return top;
}

static BOOL RFChecksEnabled(void) {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterCheckUpdates];
}

// Waits while a screen is opening or closing, then gives up until the app next opens. The version only
// counts as alerted once the alert is on screen.
static void RFShowUpdateAlert(NSString *version, NSInteger attemptsLeft) {
  UIViewController *top = RFTopViewController();
  BOOL busy = !top || top.isBeingPresented || top.isBeingDismissed || top.transitionCoordinator ||
              [top isKindOfClass:UIAlertController.class];
  if (busy) {
    if (attemptsLeft > 0)
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (RFChecksEnabled()) RFShowUpdateAlert(version, attemptsLeft - 1);
      });
    return;
  }
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:[NSString stringWithFormat:@"RedditFilter %@ is available", version]
                       message:[NSString stringWithFormat:@"You have %s. Download the new IPA from GitHub and "
                                                          @"sign it like before. You can turn these alerts off "
                                                          @"in RedditFilter settings.",
                                                          RF_VERSION]
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"Not now" style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:@"View"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *action) {
                                            [UIApplication.sharedApplication openURL:RFUpdateURL()
                                                                             options:@{}
                                                                   completionHandler:nil];
                                          }]];
  [top presentViewController:alert
                    animated:YES
                  completion:^{
                    if (alert.presentingViewController)
                      [NSUserDefaults.standardUserDefaults setObject:version forKey:kAlertedKey];
                  }];
}

// Alerts once per version, including one found by an earlier check that couldn't show it.
// Checks the setting again too: it may have been turned off while a check was running.
static void RFAlertIfNeeded(void) {
  NSString *update = RFAvailableUpdate();
  if (RFChecksEnabled() && update &&
      ![update isEqualToString:[NSUserDefaults.standardUserDefaults stringForKey:kAlertedKey]])
    RFShowUpdateAlert(update, 5);
}

static BOOL RFRecently(NSString *key, NSTimeInterval interval) {
  NSDate *date = [NSUserDefaults.standardUserDefaults objectForKey:key];
  return [date isKindOfClass:NSDate.class] && -date.timeIntervalSinceNow < interval;
}

static void RFCheckForUpdate(void) {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  if (!RFChecksEnabled() || !RFVersionIsNewer(@RF_VERSION, @"0")) return;
  if (RFRecently(kLastCheckKey, kCheckInterval) || RFRecently(kLastTryKey, kRetryInterval)) {
    RFAlertIfNeeded();
    return;
  }
  [defaults setObject:[NSDate date] forKey:kLastTryKey];

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kLatestReleaseURL]];
  request.timeoutInterval = 15;
  [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
  NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
  [[session dataTaskWithRequest:request
              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                NSDictionary *release = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                NSString *tag = [release isKindOfClass:NSDictionary.class] ? release[@"tag_name"] : nil;
                NSString *version = [tag isKindOfClass:NSString.class] ? RFTweakVersionFromTag(tag) : nil;
                NSString *page = [release isKindOfClass:NSDictionary.class] ? release[@"html_url"] : nil;
                dispatch_async(dispatch_get_main_queue(), ^{
                  if (version) {
                    [defaults setObject:[NSDate date] forKey:kLastCheckKey];
                    [defaults setObject:version forKey:kLatestKey];
                    if ([page isKindOfClass:NSString.class] && [page hasPrefix:@"https://github.com/"])
                      [defaults setObject:page forKey:kLatestPageKey];
                  }
                  RFAlertIfNeeded();
                });
              }] resume];
  [session finishTasksAndInvalidate];
}

__attribute__((constructor)) static void RFUpdateCheckerInit(void) {
  [NSUserDefaults.standardUserDefaults registerDefaults:@{kRedditFilterCheckUpdates : @YES}];
  [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                  object:nil
                                                   queue:NSOperationQueue.mainQueue
                                              usingBlock:^(NSNotification *note) {
                                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                                             (int64_t)(kDelayAfterLaunch * NSEC_PER_SEC)),
                                                               dispatch_get_main_queue(), ^{
                                                                 RFCheckForUpdate();
                                                               });
                                              }];
}
