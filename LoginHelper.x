// Alternative login methods for sideloaded installs, where Reddit rejects the app's password login.
//
// - Log in with browser: log in on reddit.com in an in-app browser, then hand its reddit_session
//   cookie to the app. The app's password request is answered locally with that cookie, and the app
//   exchanges it for its own token as it does after a normal login.
// - Open login link: paste the link from Reddit's "Email me a login link" email and pass it to the
//   app as if it had been opened from Mail.
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <string.h>

static NSString *const kWebLoginURL = @"https://www.reddit.com/login/";
static NSString *const kPlaceholderPassword = @"RedditFilterBrowserLogin";
static const NSTimeInterval kWebSessionLifetime = 10 * 60;

static NSString *webSession;
static NSDate *webSessionDate;

static void setWebSession(NSString *session) {
  @synchronized(NSProcessInfo.processInfo) {
    webSession = session;
    webSessionDate = session ? [NSDate date] : nil;
  }
}

// Session captured by the browser, if the user started a browser login in the last few minutes.
NSString *RFPendingWebSession(void) {
  @synchronized(NSProcessInfo.processInfo) {
    if (webSessionDate && -webSessionDate.timeIntervalSinceNow > kWebSessionLifetime) setWebSession(nil);
    return webSession;
  }
}

void RFClearPendingWebSession(void) {
  setWebSession(nil);
}

#pragma mark - Browser

@interface RFWebLoginViewController : UIViewController <WKNavigationDelegate, WKHTTPCookieStoreObserver>
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, copy) void (^completion)(NSString *session, NSString *username);
@property(nonatomic, assign) BOOL finished;
@end

@implementation RFWebLoginViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Log in with browser";
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  self.navigationItem.leftBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                    target:self
                                                    action:@selector(cancel)];

  // A fresh, non-persistent store so an old web session can't be picked up by mistake.
  WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
  configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
  self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:configuration];
  self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.webView.navigationDelegate = self;
  self.webView.customUserAgent =
      [NSString stringWithFormat:@"Mozilla/5.0 (iPhone; CPU iPhone OS %@ like Mac OS X) "
                                 @"AppleWebKit/605.1.15 (KHTML, like Gecko) Version/%@ Mobile/15E148 "
                                 @"Safari/604.1",
                                 [UIDevice.currentDevice.systemVersion
                                     stringByReplacingOccurrencesOfString:@"."
                                                               withString:@"_"],
                                 [UIDevice.currentDevice.systemVersion
                                     componentsSeparatedByString:@"."]
                                     .firstObject];
  [configuration.websiteDataStore.httpCookieStore addObserver:self];
  [self.view addSubview:self.webView];
  [self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:kWebLoginURL]]];
}

- (void)dealloc {
  [self.webView.configuration.websiteDataStore.httpCookieStore removeObserver:self];
}

- (void)cancel {
  self.finished = YES;
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)cookiesDidChangeInCookieStore:(WKHTTPCookieStore *)cookieStore {
  [self checkForSession];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
  [self checkForSession];
}

- (void)checkForSession {
  if (self.finished) return;
  [self.webView.configuration.websiteDataStore.httpCookieStore
      getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        NSString *session;
        for (NSHTTPCookie *cookie in cookies)
          if ([cookie.name isEqualToString:@"reddit_session"] &&
              [cookie.domain hasSuffix:@"reddit.com"] && cookie.value.length)
            session = cookie.value;
        if (!session || self.finished) return;
        // Confirm the session belongs to a logged-in account and get its username.
        [self.webView
            callAsyncJavaScript:@"try {"
                                @"  const response = await fetch('/api/me.json', {credentials: 'include'});"
                                @"  const json = await response.json();"
                                @"  return (json && json.data && json.data.name) || '';"
                                @"} catch (e) { return ''; }"
                      arguments:@{}
                        inFrame:nil
                 inContentWorld:WKContentWorld.defaultClientWorld
              completionHandler:^(id result, NSError *error) {
               if (self.finished) return;
               NSString *username = [result isKindOfClass:NSString.class] ? result : nil;
               if (!username.length) return;
               self.finished = YES;
               void (^completion)(NSString *, NSString *) = self.completion;
               [self dismissViewControllerAnimated:YES
                                        completion:^{
                                          if (completion) completion(session, username);
                                        }];
             }];
      }];
}

@end

#pragma mark - Login form

static NSArray *subviewsOfClassIncludingHidden(UIView *root, Class cls, BOOL includeHidden) {
  NSMutableArray *found = [NSMutableArray array];
  NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
  while (queue.count) {
    UIView *view = queue.firstObject;
    [queue removeObjectAtIndex:0];
    if (view.hidden && !includeHidden) continue;
    if ([view isKindOfClass:cls]) [found addObject:view];
    [queue addObjectsFromArray:view.subviews];
  }
  return found;
}

static NSArray *subviewsOfClass(UIView *root, Class cls) { return subviewsOfClassIncludingHidden(root, cls, NO); }

static void fillTextField(UITextField *textField, NSString *text) {
  [textField becomeFirstResponder];
  textField.text = @"";
  [textField insertText:text];
  [textField sendActionsForControlEvents:UIControlEventEditingChanged];
}

static UIControl *controlLabeled(UIView *root, NSString *label, BOOL includeHidden) {
  for (UIControl *control in subviewsOfClassIncludingHidden(root, UIControl.class, includeHidden)) {
    NSMutableArray *titles = [NSMutableArray array];
    if (control.accessibilityLabel) [titles addObject:control.accessibilityLabel];
    if ([control isKindOfClass:UIButton.class]) {
      UIButton *button = (UIButton *)control;
      if (button.currentTitle) [titles addObject:button.currentTitle];
      if (button.currentAttributedTitle.string) [titles addObject:button.currentAttributedTitle.string];
      if (button.titleLabel.text) [titles addObject:button.titleLabel.text];
    }
    for (UILabel *text in subviewsOfClassIncludingHidden(control, UILabel.class, YES))
      if (text.text) [titles addObject:text.text];
    if ([titles containsObject:label]) return control;
  }
  return nil;
}

static void showAlert(UIViewController *viewController, NSString *title, NSString *message);

// The form enables its button a moment after the fields change, so keep checking for a few seconds.
// The add-account Log in screen doesn't mark its button enabled for filled-in text, but still accepts the tap.
static void tapWhenEnabled(UIViewController *viewController, NSInteger attemptsLeft) {
  __weak UIViewController *weakController = viewController;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    UIViewController *controller = weakController;
    if (!controller.view.window) return;
    // The add-account screen puts its button above the keyboard, as an input accessory view.
    NSMutableArray<UIView *> *roots = [NSMutableArray arrayWithObject:controller.view];
    if (controller.inputAccessoryView) [roots addObject:controller.inputAccessoryView];
    for (UITextField *field in subviewsOfClass(controller.view, UITextField.class))
      if (field.inputAccessoryView) [roots addObject:field.inputAccessoryView];
    UIControl *button = nil;
    for (NSNumber *includeHidden in @[ @NO, @YES ]) {
      for (UIView *root in roots) {
        button = controlLabeled(root, @"Continue", includeHidden.boolValue)
                     ?: controlLabeled(root, @"Log in", includeHidden.boolValue);
        if (button) break;
      }
      if (button) break;
    }
    if (button && (button.enabled || attemptsLeft == 0)) {
      [button sendActionsForControlEvents:UIControlEventTouchUpInside];
    } else if (attemptsLeft > 0) {
      tapWhenEnabled(controller, attemptsLeft - 1);
    } else {
      showAlert(controller, @"Log in with browser", @"Your browser login is ready. Tap Continue to finish logging in.");
    }
  });
}

// The username and password form: its own screen on first login ("Use email or username"),
// or part of the main Log in screen when adding another account.
static BOOL isPasswordLoginController(UIViewController *viewController) {
  const char *name = class_getName(object_getClass(viewController));
  if (!strstr(name, "AuthenticationKit")) return NO;
  return strstr(name, "LoginWithPasswordViewModel") || !strcmp(name, "AuthenticationKit.LoginViewController");
}

static void showAlert(UIViewController *viewController, NSString *title, NSString *message) {
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                 message:message
                                                          preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
  [viewController presentViewController:alert animated:YES completion:nil];
}

// Fills the app's login form and submits it. The password request is then answered with the browser
// session (see the NSURLSession hook in Tweak.xm), so the placeholder password is never sent.
static void submitLoginForm(UIViewController *viewController, NSString *username) {
  NSArray *textFields = subviewsOfClass(viewController.view, UITextField.class);
  if (textFields.count < 2) {
    showAlert(viewController, @"Log in with browser",
              @"Couldn't find the login form. Open \"Use email or username\" and try again.");
    return;
  }
  fillTextField(textFields[0], username);
  fillTextField(textFields[1], kPlaceholderPassword);
  [viewController.view endEditing:YES];
  tapWhenEnabled(viewController, 10);
}

#pragma mark - Login links

// Hands a link to the app the same way iOS does when a Reddit link is opened from Mail.
BOOL RFOpenLoginLink(UIWindowScene *scene, NSURL *url) {
  if (!url.scheme.length) return NO;
  if ([url.scheme isEqualToString:@"reddit"]) {
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    return YES;
  }
  if (![url.scheme hasPrefix:@"http"]) return NO;
  NSUserActivity *activity = [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
  activity.webpageURL = url;
  id<UIWindowSceneDelegate> sceneDelegate = (id<UIWindowSceneDelegate>)scene.delegate;
  if ([sceneDelegate respondsToSelector:@selector(scene:continueUserActivity:)]) {
    [sceneDelegate scene:scene continueUserActivity:activity];
    return YES;
  }
  id<UIApplicationDelegate> appDelegate = UIApplication.sharedApplication.delegate;
  if ([appDelegate respondsToSelector:@selector(application:continueUserActivity:restorationHandler:)])
    return [appDelegate application:UIApplication.sharedApplication
               continueUserActivity:activity
                 restorationHandler:^(NSArray *objects){
                 }];
  return NO;
}

void RFPromptForLoginLink(UIViewController *viewController) {
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:@"Open login link"
                                          message:@"Paste the link from Reddit's login email."
                                   preferredStyle:UIAlertControllerStyleAlert];
  [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
    textField.placeholder = @"https://";
    textField.keyboardType = UIKeyboardTypeURL;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
  }];
  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
  __weak UIAlertController *weakAlert = alert;
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"Open"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *action) {
                                 NSString *text = [weakAlert.textFields.firstObject.text
                                     stringByTrimmingCharactersInSet:NSCharacterSet
                                                                         .whitespaceAndNewlineCharacterSet];
                                 NSURL *url = text.length ? [NSURL URLWithString:text] : nil;
                                 UIWindowScene *scene = viewController.view.window.windowScene;
                                 // Close the login screens first so the app can show the result.
                                 UIViewController *presenter = viewController.presentingViewController;
                                 void (^open)(void) = ^{
                                   if (!RFOpenLoginLink(scene, url))
                                     showAlert(presenter ?: viewController, @"Open login link",
                                               @"That doesn't look like a Reddit link.");
                                 };
                                 if (presenter && isPasswordLoginController(viewController))
                                   [presenter dismissViewControllerAnimated:YES completion:open];
                                 else
                                   open();
                               }]];
  [viewController presentViewController:alert animated:YES completion:nil];
}

void RFStartBrowserLogin(UIViewController *viewController) {
  RFWebLoginViewController *webLogin = [RFWebLoginViewController new];
  __weak UIViewController *weakController = viewController;
  webLogin.completion = ^(NSString *session, NSString *username) {
    setWebSession(session);
    if (weakController) submitLoginForm(weakController, username);
  };
  UINavigationController *navigationController =
      [[UINavigationController alloc] initWithRootViewController:webLogin];
  [viewController presentViewController:navigationController animated:YES completion:nil];
}

%hook UIViewController
- (void)viewWillAppear:(BOOL)animated {
  %orig;
  if (!isPasswordLoginController(self)) return;
  for (UIBarButtonItem *item in self.navigationItem.rightBarButtonItems)
    if (item.tag == 1338) return;
  __weak UIViewController *weakSelf = self;
  UIMenu *menu = [UIMenu
      menuWithTitle:@"RedditFilter"
           children:@[
             [UIAction actionWithTitle:@"Log in with browser"
                                 image:[UIImage systemImageNamed:@"safari"]
                            identifier:nil
                               handler:^(UIAction *action) {
                                 if (weakSelf) RFStartBrowserLogin(weakSelf);
                               }],
             [UIAction actionWithTitle:@"Open login link"
                                 image:[UIImage systemImageNamed:@"link"]
                            identifier:nil
                               handler:^(UIAction *action) {
                                 if (weakSelf) RFPromptForLoginLink(weakSelf);
                               }],
           ]];
  UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:@"Other options" menu:menu];
  item.tag = 1338;
  item.accessibilityLabel = @"Other login options";
  NSMutableArray *items = [self.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
  [items addObject:item];
  self.navigationItem.rightBarButtonItems = items;
}
%end
