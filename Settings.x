#import <objc/runtime.h>
#import <string.h>
#import "FeedFilterSettingsViewController.h"

// Reddit's own name for the button that opens the sidebar. Its label changes with the language.
static NSString *const kRFSidebarButtonID = @"reddit_community__community_drawer__bar_button";

@interface UIViewController (RFOpenSettings)
- (void)openRedditFilterFromNav;
@end

// Long pressing the sidebar button opens RedditFilter. A tap still opens the sidebar, as the long
// press cancels the touch before the button sees it end.
@interface RFSidebarLongPress : NSObject <UIGestureRecognizerDelegate>
@end

@implementation RFSidebarLongPress

+ (instancetype)shared {
  static RFSidebarLongPress *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [RFSidebarLongPress new]; });
  return shared;
}

// The top bar's other buttons are the same class.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
  if (![recognizer.view.accessibilityIdentifier isEqualToString:kRFSidebarButtonID]) return NO;
  RFWarmIcons();
  return YES;
}

- (void)pressed:(UILongPressGestureRecognizer *)recognizer {
  if (recognizer.state != UIGestureRecognizerStateBegan) return;
  UIResponder *responder = recognizer.view;
  while (responder && ![responder isKindOfClass:UIViewController.class]) responder = responder.nextResponder;
  UIViewController *controller = (UIViewController *)responder;
  if (!controller || controller.presentedViewController) return;
  [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
  [controller openRedditFilterFromNav];
}

@end

%group RFTopBarHooks
%hook RFTopAppBarButton

- (void)didMoveToWindow {
  %orig;
  UIView *button = (UIView *)self;
  if (!button.window) return;
  RFSidebarLongPress *handler = RFSidebarLongPress.shared;
  for (UIGestureRecognizer *recognizer in button.gestureRecognizers)
    if (recognizer.delegate == handler) return;
  UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:handler
                                                                                      action:@selector(pressed:)];
  press.minimumPressDuration = 0.4;
  press.delegate = handler;
  [button addGestureRecognizer:press];
}

%end
%end

// Adds a "RedditFilter" button to the top bar of Reddit's Settings screen.
%hook UIViewController

- (void)viewWillAppear:(BOOL)animated {
  %orig;

  // This runs for every screen in the app, so use cheap C string checks
  // instead of building an NSString each time.
  const char *name = class_getName([self class]);
  if (!strstr(name, "AppSettingsView") || !strstr(name, "HostingController") ||
      (!strstr(name, "RedditSliceKit") && !strstr(name, "RedditAppSettings")))
    return;

  for (UIBarButtonItem *item in self.navigationItem.rightBarButtonItems)
    if (item.tag == 1337) return; // already added

  // Get ready now, as the button is about to be tapped.
  RFWarmIcons();

  UIBarButtonItem *filterButton = [[UIBarButtonItem alloc] initWithTitle:@"RedditFilter"
                                                                   style:UIBarButtonItemStylePlain
                                                                  target:self
                                                                  action:@selector(openRedditFilterFromNav)];
  filterButton.tag = 1337;
  [filterButton setTitlePositionAdjustment:UIOffsetMake(0, 3.5) forBarMetrics:UIBarMetricsDefault];

  NSMutableArray *items = [self.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
  [items insertObject:filterButton atIndex:0];
  self.navigationItem.rightBarButtonItems = items;
}

// Opens RedditFilter in its own page sheet with a close button, over Settings.
%new
- (void)openRedditFilterFromNav {
  Class settingsClass = objc_getClass("FeedFilterSettingsViewController");
  FeedFilterSettingsViewController *settings =
      settingsClass ? [(FeedFilterSettingsViewController *)[settingsClass alloc] initWithStyle:UITableViewStyleGrouped]
                    : nil;
  if (!settings) return;
  UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:settings];
  __weak UINavigationController *weakNavigation = navigation;
  settings.navigationItem.leftBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                             primaryAction:[UIAction actionWithHandler:^(UIAction *action) {
                                               [weakNavigation dismissViewControllerAnimated:YES completion:nil];
                                             }]];
  navigation.modalPresentationStyle = UIModalPresentationPageSheet;
  [self presentViewController:navigation animated:YES completion:nil];
}

%end

%ctor {
  %init;
  Class topBarButton = NSClassFromString(@"RPLComponents.RPLTopAppBarButton");
  if (topBarButton) %init(RFTopBarHooks, RFTopAppBarButton = topBarButton);
}
