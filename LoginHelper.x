// Alternative login methods for sideloaded installs, where Reddit rejects the app's password login.
//
// - Log in with browser: log in on reddit.com in an in-app browser, then hand its reddit_session
//   cookie to the app. The app's password request is answered locally with that cookie, and the app
//   exchanges it for its own token as it does after a normal login.
// - Open login link: paste the link from Reddit's "Email me a login link" email and pass it to the
//   app as if it had been opened from Mail.
// - Sideloaded builds also do the browser login for the app's own form: when the user taps Log in,
//   the username and password are filled in on reddit.com in the browser sheet, which submits them
//   and closes itself once logged in (see RFBrowserLoginWithCredentials and the hook in Tweak.xm).
//   The password stays in memory only, for as long as it takes to fill in the page.
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

@interface RFWebLoginViewController
    : UIViewController <WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver,
                        UIAdaptivePresentationControllerDelegate>
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, copy) void (^completion)(NSString *session, NSString *username);
@property(nonatomic, assign) BOOL finished;
// Logged in: the sheet is closing to hand the session over.
@property(nonatomic, assign) BOOL succeeded;
// Called once if the sheet closes without logging in.
@property(nonatomic, copy) void (^cancellation)(void);
// Filled in on reddit.com/login and submitted once the page is ready. Cleared once used.
@property(nonatomic, copy) NSString *prefillUsername;
@property(nonatomic, copy) NSString *prefillPassword;
@property(nonatomic, assign) BOOL autofillScheduled;
// Windows the page opened, such as Continue with Google or Apple, shown on top of it.
@property(nonatomic, strong) NSMutableArray<WKWebView *> *popups;
@end

@implementation RFWebLoginViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = self.prefillPassword ? @"Log in" : @"Log in with browser";
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  self.navigationItem.leftBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                    target:self
                                                    action:@selector(cancel)];

  // A fresh, non-persistent store so an old web session can't be picked up by mistake.
  WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
  configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
  // The store starts empty, so reddit.com asks about cookies every time and its banner covers the
  // form. Answer it with Reject Optional Cookies, which only turns off the optional ones.
  [configuration.userContentController
      addUserScript:[[WKUserScript alloc]
                          initWithSource:@"(() => {"
                                         @"  let tries = 0;"
                                         @"  const timer = setInterval(() => {"
                                         @"    const reject = [...document.querySelectorAll('button[slot=\"secondary-button\"]')]"
                                         @"      .find((button) => /reject/i.test(button.textContent));"
                                         @"    if (reject) reject.click();"
                                         @"    if (reject || ++tries > 40) clearInterval(timer);"
                                         @"  }, 250);"
                                         @"})();"
                           injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                        forMainFrameOnly:YES
                          inContentWorld:WKContentWorld.defaultClientWorld]];
  self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:configuration];
  self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.webView.navigationDelegate = self;
  self.webView.UIDelegate = self;
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

#pragma mark Popups

// Continue with Google and Continue with Apple sign in in a new window, which reports back to the
// login page when it closes. Show it on top of the page and remove it when it closes.
- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures {
  if (self.finished) return nil;
  WKWebView *popup = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:configuration];
  popup.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  popup.customUserAgent = self.webView.customUserAgent;
  popup.UIDelegate = self;
  popup.navigationDelegate = self;
  if (!self.popups) self.popups = [NSMutableArray array];
  [self.popups addObject:popup];
  [self.view addSubview:popup];
  return popup;
}

- (void)webViewDidClose:(WKWebView *)webView {
  if (webView == self.webView) return;
  [webView removeFromSuperview];
  [self.popups removeObject:webView];
}

- (void)dealloc {
  [self.webView.configuration.websiteDataStore.httpCookieStore removeObserver:self];
}

- (void)cancel {
  self.finished = YES;
  [self dismissViewControllerAnimated:YES completion:^{
    [self reportCancellation];
  }];
}

- (void)reportCancellation {
  self.prefillPassword = nil;
  if (self.succeeded) return;
  void (^cancellation)(void) = self.cancellation;
  self.cancellation = nil;
  if (cancellation) cancellation();
}

#pragma mark Filling in the page

// Fills reddit.com's username and password fields and taps Log In. The fields are web components
// that only appear once the page has set itself up, so this returns 'waiting' until they're there.
static NSString *const kAutofillScript =
    @"const field = (name) => {"
    @"  const host = document.querySelector(`faceplate-text-input[name='${name}']`);"
    @"  return host && host.shadowRoot && host.shadowRoot.querySelector('input');"
    @"};"
    @"const username = field('username'), password = field('password');"
    @"if (!username || !password) return 'waiting';"
    @"for (const [input, value] of [[username, user], [password, pass]]) {"
    @"  input.focus();"
    @"  input.value = value;"
    @"  input.dispatchEvent(new Event('input', {bubbles: true, composed: true}));"
    @"  input.dispatchEvent(new Event('change', {bubbles: true, composed: true}));"
    @"  input.blur();"
    @"}"
    @"await new Promise((resolve) => setTimeout(resolve, 400));"
    @"const button = document.querySelector('faceplate-form#login button.login') ||"
    @"               document.querySelector('auth-flow-login button.login');"
    @"if (!button) return 'filled';"
    @"button.click();"
    @"return 'submitted';";

- (void)autofillWithAttemptsLeft:(NSInteger)attemptsLeft {
  if (self.finished || !self.prefillPassword) return;
  __weak RFWebLoginViewController *weakSelf = self;
  [self.webView callAsyncJavaScript:kAutofillScript
                          arguments:@{@"user" : self.prefillUsername ?: @"", @"pass" : self.prefillPassword}
                            inFrame:nil
                     inContentWorld:WKContentWorld.defaultClientWorld
                  completionHandler:^(id result, NSError *error) {
                    RFWebLoginViewController *strongSelf = weakSelf;
                    if (!strongSelf) return;
                    if ([result isEqual:@"waiting"] || error) {
                      if (attemptsLeft <= 0) {
                        // Leave the page for the user to fill in.
                        strongSelf.prefillPassword = nil;
                        return;
                      }
                      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                                     dispatch_get_main_queue(), ^{
                                       [weakSelf autofillWithAttemptsLeft:attemptsLeft - 1];
                                     });
                      return;
                    }
                    // Filled in (and submitted, unless the button wasn't found). From here on the
                    // user can see the page and finish anything it asks for, such as a 2FA code.
                    strongSelf.prefillPassword = nil;
                  }];
}

// Swiping the sheet away counts as cancelling, so a cookie or account check still on its way can't
// log in after it's gone. The swipe can still be cancelled by dragging back, so it only counts once
// the user lets go and the sheet carries on closing, not when the swipe starts.
- (void)presentationControllerWillDismiss:(UIPresentationController *)presentationController {
  id<UIViewControllerTransitionCoordinator> coordinator = presentationController.presentedViewController.transitionCoordinator;
  if (!coordinator.isInteractive) {
    self.finished = YES;
    return;
  }
  __weak RFWebLoginViewController *weakSelf = self;
  [coordinator notifyWhenInteractionChangesUsingBlock:^(id<UIViewControllerTransitionCoordinatorContext> context) {
    if (!context.isCancelled) weakSelf.finished = YES;
  }];
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
  self.finished = YES;
  [self reportCancellation];
}

- (void)cookiesDidChangeInCookieStore:(WKHTTPCookieStore *)cookieStore {
  [self checkForSession];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
  [self checkForSession];
  // reddit.com/login first loads a short check page, then the login page itself; start filling in
  // after the first load and keep trying for a while.
  if (webView == self.webView && self.prefillPassword && !self.autofillScheduled) {
    self.autofillScheduled = YES;
    [self autofillWithAttemptsLeft:40];
  }
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
               // Not while the sheet is being swiped away either.
               if (self.finished || self.navigationController.isBeingDismissed) return;
               NSString *username = [result isKindOfClass:NSString.class] ? result : nil;
               if (!username.length) return;
               self.finished = YES;
               self.succeeded = YES;
               self.prefillPassword = nil;
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
  navigationController.presentationController.delegate = webLogin;
  [viewController presentViewController:navigationController animated:YES completion:nil];
}

static UIViewController *topViewController(void) {
  UIWindow *window = nil;
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive)
      continue;
    for (UIWindow *candidate in ((UIWindowScene *)scene).windows)
      if (candidate.isKeyWindow) window = candidate;
    if (!window) window = ((UIWindowScene *)scene).windows.firstObject;
    if (window) break;
  }
  UIViewController *top = window.rootViewController;
  while (top.presentedViewController && !top.presentedViewController.isBeingDismissed)
    top = top.presentedViewController;
  return top;
}

// The app's own Log in button: log in with the same username and password in the browser sheet,
// which fills them in and submits them itself. Calls completion on the main queue with the session,
// or nil if the sheet couldn't be shown or the user closed it.
void RFBrowserLoginWithCredentials(NSString *username, NSString *password, void (^completion)(NSString *session)) {
  dispatch_async(dispatch_get_main_queue(), ^{
    UIViewController *presenter = topViewController();
    if (!presenter) return completion(nil);
    [presenter.view endEditing:YES];
    RFWebLoginViewController *webLogin = [RFWebLoginViewController new];
    webLogin.prefillUsername = username;
    webLogin.prefillPassword = password;
    webLogin.completion = ^(NSString *session, NSString *loggedInAs) {
      completion(session);
    };
    webLogin.cancellation = ^{
      completion(nil);
    };
    UINavigationController *navigationController =
        [[UINavigationController alloc] initWithRootViewController:webLogin];
    navigationController.presentationController.delegate = webLogin;
    [presenter presentViewController:navigationController animated:YES completion:nil];
  });
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
