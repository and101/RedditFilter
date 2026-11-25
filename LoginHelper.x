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

// Why the cover lifted, which picks the banner shown over the page.
typedef NS_ENUM(NSInteger, RFHandOverReason) {
  RFHandOverError,  // reddit.com shows an error, such as a wrong password
  RFHandOverCode,   // the 2FA step
  RFHandOverStep,   // some other step, or a page RedditFilter doesn't recognise
  RFHandOverSlow,   // the page didn't load, or reddit.com didn't answer, in time
};

@interface RFWebLoginViewController
    : UIViewController <WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver,
                        UIAdaptivePresentationControllerDelegate>
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, copy) void (^completion)(NSString *session, NSString *username);
@property(nonatomic, assign) BOOL finished;
// Logged in: the sheet is closing to hand the session over.
@property(nonatomic, assign) BOOL succeeded;
// reddit.com has set a session cookie: the account check that closes the sheet is under way.
@property(nonatomic, assign) BOOL sessionSeen;
// When an account check first found no logged-in account (see checkForSession).
@property(nonatomic, strong) NSDate *firstEmptySessionCheck;
// The next account check is already due.
@property(nonatomic, assign) BOOL sessionCheckScheduled;
// Called once if the sheet closes without logging in.
@property(nonatomic, copy) void (^cancellation)(void);
// Filled in on reddit.com/login and submitted once the page is ready. Cleared once used.
@property(nonatomic, copy) NSString *prefillUsername;
@property(nonatomic, copy) NSString *prefillPassword;
@property(nonatomic, assign) BOOL autofillScheduled;
// How many more times to fill in and submit again if the page wipes the form after a submit.
@property(nonatomic, assign) NSInteger resubmitsLeft;
// Over the page while RedditFilter fills it in by itself.
@property(nonatomic, strong) UIView *cover;
// The cover's progress rows: an indicator and a label each, and which row is under way.
@property(nonatomic, strong) NSArray<UIView *> *stepIndicators;
@property(nonatomic, strong) NSArray<UILabel *> *stepLabels;
@property(nonatomic, strong) UIStackView *stepStack;
@property(nonatomic, assign) NSInteger coverStep;
// The page went on to reddit.com's feed, and was covered for it (see coverFeedPage).
@property(nonatomic, assign) BOOL feedPageCovered;
// The login form has turned up on the page.
@property(nonatomic, assign) BOOL formFound;
// Windows the page opened, such as Continue with Google or Apple, shown on top of it.
@property(nonatomic, strong) NSMutableArray<WKWebView *> *popups;
@end

// reddit.com's own feeds, where its login page goes once it's done: a page with ads on it, not a login step.
static BOOL RFIsFeedPage(NSURL *url) {
  NSString *host = url.host.lowercaseString;
  if (![host isEqualToString:@"reddit.com"] && ![host hasSuffix:@".reddit.com"]) return NO;
  NSArray<NSString *> *parts = url.pathComponents; // the first is "/"
  if (parts.count < 2) return YES;
  return [@[ @"best", @"hot", @"new", @"top", @"rising", @"home", @"popular", @"r" ] containsObject:parts[1]];
}

static void *kRFLoginURLContext = &kRFLoginURLContext;

@implementation RFWebLoginViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = self.prefillPassword ? @"Log in" : @"Log in with browser";
  self.resubmitsLeft = 2;
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  self.navigationItem.leftBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                    target:self
                                                    action:@selector(cancel)];

  // A fresh, non-persistent store so an old web session can't be picked up by mistake.
  WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
  configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
  // The store starts empty, so reddit.com asks about cookies every time and its banner covers the
  // form. Answer it with Reject Optional Cookies, which only turns off the optional ones. The banner
  // can turn up late (after reddit.com's script check, on a slow connection) and ignores a click
  // before it's ready, so keep at it until reddit.com has the answer (its eu_cookie_opted cookie).
  [configuration.userContentController
      addUserScript:[[WKUserScript alloc]
                          initWithSource:@"(() => {"
                                         @"  let tries = 0;"
                                         @"  const timer = setInterval(() => {"
                                         @"    if (/(^|; )eu_cookie_opted=/.test(document.cookie) || ++tries > 120)"
                                         @"      return clearInterval(timer);"
                                         @"    const reject = [...document.querySelectorAll('button[slot=\"secondary-button\"]')]"
                                         @"      .find((button) => /reject/i.test(button.textContent));"
                                         @"    if (reject) reject.click();"
                                         @"  }, 500);"
                                         @"})();"
                           injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                        forMainFrameOnly:YES
                          inContentWorld:WKContentWorld.defaultClientWorld]];
  // A video on the page must not open full screen, over the cover.
  configuration.allowsInlineMediaPlayback = YES;
  configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeAll;
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
  [self.webView addObserver:self forKeyPath:@"URL" options:0 context:kRFLoginURLContext];
  [self.view addSubview:self.webView];
  if (self.prefillPassword) [self showCover];
  [self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:kWebLoginURL]]];
}

#pragma mark Popups

// Continue with Google and Continue with Apple sign in in a new window, which reports back to the
// login page when it closes. Show it on top of the page and remove it when it closes.
- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures {
  if (self.finished || self.cover) return nil; // under the cover, nobody tapped anything
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
  [self.webView removeObserver:self forKeyPath:@"URL" context:kRFLoginURLContext];
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
// that only appear once the page has set itself up, so this returns 'waiting' until they're there,
// then 'found' once (until `fill` is set) so the cover can move on to its next step.
// The address is checked here, right before filling in, so the password only ever goes into
// reddit.com. Anywhere else, 'elsewhere' ends the autofill like any other final answer.
static NSString *const kAutofillScript =
    @"const site = location.hostname;"
    @"if (location.protocol !== 'https:' || (site !== 'reddit.com' && !site.endsWith('.reddit.com')))"
    @"  return 'elsewhere';"
    @"const field = (name) => {"
    @"  const host = document.querySelector(`faceplate-text-input[name='${name}']`);"
    @"  return host && host.shadowRoot && host.shadowRoot.querySelector('input');"
    @"};"
    @"const username = field('username'), password = field('password');"
    @"if (!username || !password) return 'waiting';"
    // Say the form's there before filling it in, so the cover can show the next step.
    @"if (!fill) return 'found';"
    @"for (const [input, value] of [[username, user], [password, pass]]) {"
    @"  input.focus();"
    @"  input.value = value;"
    @"  input.dispatchEvent(new Event('input', {bubbles: true, composed: true}));"
    @"  input.dispatchEvent(new Event('change', {bubbles: true, composed: true}));"
    @"  input.blur();"
    @"}"
    @"await new Promise((resolve) => setTimeout(resolve, 400));"
    // The page can still be setting the form up, which empties it again. Fill it in once it stays filled.
    @"if (username.value !== user || password.value !== pass) return 'waiting';"
    @"const button = document.querySelector('faceplate-form#login button.login') ||"
    @"               document.querySelector('auth-flow-login button.login');"
    @"if (!button) return 'filled';"
    @"button.click();"
    @"return 'submitted';";

// After a submit, what the page shows now:
// - 'code': the 2FA step (a code from an authenticator app, or a backup code).
// - 'invalid': a field marked invalid but no message (yet).
// - 'error:<message>': a message by a field, such as "Invalid username or password." It sits in the shadow root
//   of the field's helper text, itself in the field's shadow root, so innerText on the host misses it.
// - 'wiped': both fields emptied without moving on, which the page does when the form was submitted
//   while still being set up.
// - 'moved': the form's gone without a 2FA step, such as another check, or the page moving on after
//   logging in.
// - 'kept': still the filled-in form, most likely waiting for reddit.com's answer.
static NSString *const kSubmittedCheckScript =
    @"const shown = (el) => !!el && el.getClientRects().length > 0;"
    @"if ([...document.querySelectorAll(\"faceplate-form[id*='otp']\")].some(shown)) return 'code';"
    @"const host = (name) => document.querySelector(`faceplate-text-input[name='${name}']`);"
    @"const field = (name) => { const h = host(name); return h && h.shadowRoot && h.shadowRoot.querySelector('input'); };"
    @"const username = field('username'), password = field('password');"
    @"if (!username || !password || !shown(password)) return 'moved';"
    @"if (!username.value && !password.value) return 'wiped';"
    @"const message = (name) => {"
    @"  const h = host(name);"
    @"  const helper = h.shadowRoot && h.shadowRoot.querySelector('faceplate-form-helper-text');"
    @"  const text = helper && helper.shadowRoot && helper.shadowRoot.querySelector('#helper-text');"
    @"  return (text && text.textContent.trim()) || '';"
    @"};"
    @"const text = message('password') || message('username');"
    @"const invalid = [host('username'), host('password')].some((h) => h.getAttribute('faceplate-validity') === 'invalid');"
    @"return text ? 'error:' + text : invalid ? 'invalid' : 'kept';";

// How often to look at the page after a submit, and for how long while it still shows the filled-in form.
static const NSTimeInterval kSubmittedCheckInterval = 0.25;
static const NSTimeInterval kSubmittedCheckLimit = 12;

// Looks at the page every quarter of a second after a submit, so an error or a 2FA step is shown as soon
// as it appears. `checksLeft`: how many more looks while the page still shows the filled-in form.
// `lastResult`: the previous look's answer; 'wiped' and 'moved' only count when seen twice in a row,
// since the page passes through both briefly while re-rendering or moving on after logging in.
- (void)checkSubmissionWithChecksLeft:(NSInteger)checksLeft lastResult:(NSString *)lastResult {
  // A session cookie means reddit.com logged in: checkForSession closes the sheet from here.
  if (self.finished || !self.prefillPassword || self.sessionSeen) return;
  __weak RFWebLoginViewController *weakSelf = self;
  [self.webView callAsyncJavaScript:kSubmittedCheckScript
                          arguments:@{}
                            inFrame:nil
                     inContentWorld:WKContentWorld.defaultClientWorld
                  completionHandler:^(id result, NSError *error) {
                    RFWebLoginViewController *strongSelf = weakSelf;
                    if (!strongSelf || strongSelf.finished || strongSelf.sessionSeen) return;
                    NSString *state = [result isKindOfClass:NSString.class] ? result : @"kept";
                    if ([state isEqual:@"code"]) return [strongSelf handOverToUser:RFHandOverCode message:nil];
                    if ([state hasPrefix:@"error:"])
                      return [strongSelf handOverToUser:RFHandOverError message:[state substringFromIndex:6]];
                    BOOL confirmed = [state isEqual:lastResult];
                    // A field marked invalid with no message yet: wait for a second look, as a resubmit
                    // after 'wiped' can briefly leave the emptied fields marked.
                    if ([state isEqual:@"invalid"] && confirmed)
                      return [strongSelf handOverToUser:RFHandOverError message:nil];
                    if ([state isEqual:@"wiped"] && confirmed && strongSelf.resubmitsLeft > 0) {
                      strongSelf.resubmitsLeft--;
                      [strongSelf autofillWithAttemptsLeft:20];
                      return;
                    }
                    // On to the feed isn't a step for the user: coverFeedPage waits for the session.
                    if (([state isEqual:@"wiped"] || [state isEqual:@"moved"]) && confirmed &&
                        !RFIsFeedPage(strongSelf.webView.URL))
                      return [strongSelf handOverToUser:RFHandOverStep message:nil];
                    if (checksLeft <= 0) return [strongSelf handOverToUser:RFHandOverSlow message:nil];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSubmittedCheckInterval * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                                     [weakSelf checkSubmissionWithChecksLeft:checksLeft - 1 lastResult:state];
                                   });
                  }];
}

- (void)autofillWithAttemptsLeft:(NSInteger)attemptsLeft {
  if (self.finished || !self.prefillPassword) return;
  __weak RFWebLoginViewController *weakSelf = self;
  [self.webView callAsyncJavaScript:kAutofillScript
                          arguments:@{
                            @"user" : self.prefillUsername ?: @"",
                            @"pass" : self.prefillPassword,
                            @"fill" : @(self.formFound)
                          }
                            inFrame:nil
                     inContentWorld:WKContentWorld.defaultClientWorld
                  completionHandler:^(id result, NSError *error) {
                    RFWebLoginViewController *strongSelf = weakSelf;
                    if (!strongSelf || strongSelf.finished) return;
                    if ([result isEqual:@"found"]) {
                      strongSelf.formFound = YES;
                      [strongSelf advanceCoverToStep:1];
                      [strongSelf autofillWithAttemptsLeft:attemptsLeft];
                      return;
                    }
                    if ([result isEqual:@"waiting"] || error) {
                      // Leave the page for the user to fill in.
                      if (attemptsLeft <= 0) return [strongSelf handOverToUser:RFHandOverSlow message:nil];
                      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                                     dispatch_get_main_queue(), ^{
                                       [weakSelf autofillWithAttemptsLeft:attemptsLeft - 1];
                                     });
                      return;
                    }
                    // Submitted: check back, in case the page wiped the form, shows an error or asks
                    // for a code. Otherwise (no Log In button, or not reddit.com) show the page.
                    if ([result isEqual:@"submitted"]) {
                      [strongSelf advanceCoverToStep:2];
                      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSubmittedCheckInterval * NSEC_PER_SEC)),
                                     dispatch_get_main_queue(), ^{
                                       [weakSelf checkSubmissionWithChecksLeft:kSubmittedCheckLimit / kSubmittedCheckInterval
                                                                    lastResult:nil];
                                     });
                      return;
                    }
                    [strongSelf handOverToUser:RFHandOverStep message:nil];
                  }];
}

#pragma mark Cover

static UIImageView *symbolView(NSString *name, UIColor *color, UIFontTextStyle style, UIImageSymbolWeight weight) {
  UIImageSymbolConfiguration *configuration =
      [[UIImageSymbolConfiguration configurationWithTextStyle:style]
          configurationByApplyingConfiguration:[UIImageSymbolConfiguration configurationWithWeight:weight]];
  UIImageView *view = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:name withConfiguration:configuration]];
  view.tintColor = color;
  view.contentMode = UIViewContentModeScaleAspectFit;
  return view;
}

// While RedditFilter logs in by itself, the page sits under a "Logging in" cover, so the cookie banner,
// the reloads and the form filling itself in aren't shown. It lists the steps and ticks each one off.
// Cancel stays in the bar above it.
- (void)showCover {
  [self.view endEditing:YES];
  UIView *cover = [[UIView alloc] initWithFrame:self.view.bounds];
  cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  cover.backgroundColor = UIColor.systemBackgroundColor;
  self.cover = cover;

  // A shield in a tinted circle, with a soft pulse around it.
  UIColor *accent = UIColor.systemOrangeColor;
  const CGFloat badgeSize = 64;
  UIView *badge = [UIView new];
  badge.translatesAutoresizingMaskIntoConstraints = NO;
  UIView *halo = [UIView new];
  UIView *circle = [UIView new];
  for (UIView *view in @[ halo, circle ]) {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    view.layer.cornerRadius = badgeSize / 2;
    [badge addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
      [view.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
      [view.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
      [view.widthAnchor constraintEqualToConstant:badgeSize],
      [view.heightAnchor constraintEqualToConstant:badgeSize],
    ]];
  }
  halo.backgroundColor = [accent colorWithAlphaComponent:0.3];
  halo.alpha = 0;
  circle.backgroundColor = [accent colorWithAlphaComponent:0.16];
  UIImageView *shield = symbolView(@"checkmark.shield", accent, UIFontTextStyleTitle1, UIImageSymbolWeightMedium);
  shield.translatesAutoresizingMaskIntoConstraints = NO;
  [badge addSubview:shield];
  [NSLayoutConstraint activateConstraints:@[
    [badge.widthAnchor constraintEqualToConstant:badgeSize + 24],
    [badge.heightAnchor constraintEqualToConstant:badgeSize + 24],
    [shield.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
    [shield.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
  ]];
  if (!UIAccessibilityIsReduceMotionEnabled()) {
    halo.alpha = 1;
    CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    grow.fromValue = @1;
    grow.toValue = @1.35;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @1;
    fade.toValue = @0;
    CAAnimationGroup *pulse = [CAAnimationGroup animation];
    pulse.animations = @[ grow, fade ];
    pulse.duration = 1.8;
    pulse.repeatCount = HUGE_VALF;
    pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [halo.layer addAnimation:pulse forKey:@"pulse"];
  }

  // "Logging in as u/name", with the account in the accent colour.
  UILabel *title = [UILabel new];
  UIFont *titleFont = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
  NSString *name = [self.prefillUsername stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  for (NSString *prefix in @[ @"/u/", @"u/" ])
    if ([name.lowercaseString hasPrefix:prefix]) name = [name substringFromIndex:prefix.length];
  if (name.length) {
    if (![name containsString:@"@"]) name = [@"u/" stringByAppendingString:name];
    NSMutableAttributedString *text =
        [[NSMutableAttributedString alloc] initWithString:@"Logging in as "
                                               attributes:@{NSForegroundColorAttributeName : UIColor.labelColor}];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:name
                                                                 attributes:@{NSForegroundColorAttributeName : accent}]];
    title.attributedText = text;
  } else {
    title.text = @"Logging in…";
  }
  title.font = titleFont;
  title.adjustsFontForContentSizeCategory = YES;
  title.textAlignment = NSTextAlignmentCenter;
  title.numberOfLines = 0;

  UILabel *detail = [UILabel new];
  detail.text = @"This takes a few seconds.";
  detail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
  detail.adjustsFontForContentSizeCategory = YES;
  detail.textColor = UIColor.secondaryLabelColor;
  detail.textAlignment = NSTextAlignmentCenter;
  detail.numberOfLines = 0;

  // The steps, ticked off as they finish (see advanceCoverToStep:).
  NSMutableArray *indicators = [NSMutableArray array], *labels = [NSMutableArray array], *rows = [NSMutableArray array];
  for (NSString *text in @[ @"Opening reddit.com", @"Entering your details", @"Checking your account" ]) {
    UIView *indicator = [UIView new];
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
      [indicator.widthAnchor constraintEqualToConstant:20],
      [indicator.heightAnchor constraintEqualToConstant:20],
    ]];
    UILabel *label = [UILabel new];
    label.text = text;
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ indicator, label ]];
    row.spacing = 10;
    row.alignment = UIStackViewAlignmentCenter;
    [indicators addObject:indicator];
    [labels addObject:label];
    [rows addObject:row];
  }
  UIStackView *steps = [[UIStackView alloc] initWithArrangedSubviews:rows];
  steps.axis = UILayoutConstraintAxisVertical;
  steps.alignment = UIStackViewAlignmentLeading;
  steps.spacing = 12;
  self.stepIndicators = indicators;
  self.stepLabels = labels;
  self.stepStack = steps;
  self.coverStep = -1;
  [self advanceCoverToStep:0];

  UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ badge, title, detail, steps ]];
  stack.axis = UILayoutConstraintAxisVertical;
  stack.alignment = UIStackViewAlignmentCenter;
  stack.spacing = 6;
  [stack setCustomSpacing:4 afterView:badge];
  [stack setCustomSpacing:28 afterView:detail];
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [cover addSubview:stack];
  UILayoutGuide *safe = cover.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [stack.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
    [stack.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor constant:-20],
    [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:32],
    [stack.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-32],
  ]];
  [self.view addSubview:cover];

  // However the page behaves, don't keep it covered for long.
  __weak RFWebLoginViewController *weakSelf = self;
  __weak UIView *weakCover = cover;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    RFWebLoginViewController *strongSelf = weakSelf;
    if (strongSelf && !strongSelf.succeeded && weakCover && strongSelf.cover == weakCover) [strongSelf handOverToUser:RFHandOverSlow message:nil];
  });
}

// Marks the steps before `step` done and `step` itself under way; 3 marks them all done.
- (void)advanceCoverToStep:(NSInteger)step {
  if (!self.cover || step <= self.coverStep) return;
  self.coverStep = step;
  UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
  UIFont *bold = [UIFont fontWithDescriptor:[font.fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold]
                                       size:0];
  void (^update)(void) = ^{
    for (NSUInteger i = 0; i < self.stepIndicators.count; i++) {
      UIView *indicator = self.stepIndicators[i];
      UILabel *label = self.stepLabels[i];
      for (UIView *view in indicator.subviews) [view removeFromSuperview];
      UIView *content;
      CGFloat side = 20;
      if ((NSInteger)i < step) {
        content = symbolView(@"checkmark.circle.fill", UIColor.systemGreenColor, UIFontTextStyleBody,
                             UIImageSymbolWeightRegular);
        label.font = font;
        label.textColor = UIColor.secondaryLabelColor;
      } else if ((NSInteger)i == step) {
        UIActivityIndicatorView *spinner =
            [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        spinner.color = UIColor.systemOrangeColor;
        spinner.transform = CGAffineTransformMakeScale(0.8, 0.8);
        [spinner startAnimating];
        content = spinner;
        label.font = bold;
        label.textColor = UIColor.labelColor;
      } else {
        content = [UIView new];
        content.layer.borderWidth = 1.5;
        content.layer.borderColor = UIColor.tertiaryLabelColor.CGColor;
        content.layer.cornerRadius = 8;
        side = 16;
        label.font = font;
        label.textColor = UIColor.tertiaryLabelColor;
      }
      content.translatesAutoresizingMaskIntoConstraints = NO;
      [indicator addSubview:content];
      [NSLayoutConstraint activateConstraints:@[
        [content.centerXAnchor constraintEqualToAnchor:indicator.centerXAnchor],
        [content.centerYAnchor constraintEqualToAnchor:indicator.centerYAnchor],
        [content.widthAnchor constraintEqualToConstant:side],
        [content.heightAnchor constraintEqualToConstant:side],
      ]];
    }
  };
  if (self.coverStep == 0)
    update();
  else
    [UIView transitionWithView:self.stepStack
                      duration:0.2
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:update
                    completion:nil];
}

// Stops filling in and shows the page, for the user to finish or fix: a 2FA code, a wrong password, or
// a page RedditFilter doesn't recognise. A banner says why the page appeared. Logging in from the page
// still closes the sheet as usual. `message`: the page's own error text, if it showed one.
- (void)handOverToUser:(RFHandOverReason)reason message:(NSString *)message {
  self.prefillPassword = nil;
  UIView *cover = self.cover;
  if (!cover) return;
  self.cover = nil;
  [UIView animateWithDuration:0.25
      animations:^{
        cover.alpha = 0;
      }
      completion:^(BOOL done) {
        [cover removeFromSuperview];
      }];
  [self showBannerForReason:reason message:message];
}

- (void)showBannerForReason:(RFHandOverReason)reason message:(NSString *)message {
  NSString *heading, *body, *symbol;
  UIColor *color;
  UINotificationFeedbackType feedback = UINotificationFeedbackTypeWarning;
  switch (reason) {
  case RFHandOverError:
    symbol = @"exclamationmark.circle.fill";
    color = UIColor.systemRedColor;
    feedback = UINotificationFeedbackTypeError;
    if (!message.length || [message rangeOfString:@"username or password" options:NSCaseInsensitiveSearch].location != NSNotFound) {
      heading = @"Wrong username or password";
      body = @"Fix it below and tap \"Log In\".";
    } else {
      heading = @"Reddit couldn't log you in";
      body = message;
    }
    break;
  case RFHandOverCode:
    symbol = @"number.circle.fill";
    color = UIColor.systemBlueColor;
    heading = @"One more step";
    body = @"Enter the code from your authenticator app.";
    break;
  case RFHandOverStep:
    symbol = @"arrow.down.circle.fill";
    color = UIColor.systemBlueColor;
    heading = @"One more step";
    body = @"Finish logging in below.";
    break;
  case RFHandOverSlow:
    symbol = @"clock.fill";
    color = UIColor.systemOrangeColor;
    heading = @"Taking longer than usual";
    body = @"You can finish logging in below.";
    break;
  }

  UIVisualEffectView *banner =
      [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterial]];
  banner.translatesAutoresizingMaskIntoConstraints = NO;
  banner.layer.cornerRadius = 14;
  banner.layer.cornerCurve = kCACornerCurveContinuous;
  banner.layer.borderWidth = 0.5;
  banner.layer.borderColor = [color colorWithAlphaComponent:0.45].CGColor;
  banner.clipsToBounds = YES;
  banner.contentView.backgroundColor = [color colorWithAlphaComponent:0.14];

  UIImageView *icon = symbolView(symbol, color, UIFontTextStyleTitle3, UIImageSymbolWeightRegular);
  [icon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  UILabel *headingLabel = [UILabel new];
  headingLabel.text = heading;
  headingLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
  UILabel *bodyLabel = [UILabel new];
  bodyLabel.text = body;
  bodyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
  bodyLabel.textColor = UIColor.secondaryLabelColor;
  for (UILabel *label in @[ headingLabel, bodyLabel ]) {
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;
  }
  UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[ headingLabel, bodyLabel ]];
  texts.axis = UILayoutConstraintAxisVertical;
  texts.spacing = 2;
  UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ icon, texts ]];
  row.spacing = 12;
  row.alignment = UIStackViewAlignmentCenter;
  row.translatesAutoresizingMaskIntoConstraints = NO;
  [banner.contentView addSubview:row];
  [self.view addSubview:banner];
  UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [row.topAnchor constraintEqualToAnchor:banner.contentView.topAnchor constant:12],
    [row.bottomAnchor constraintEqualToAnchor:banner.contentView.bottomAnchor constant:-12],
    [row.leadingAnchor constraintEqualToAnchor:banner.contentView.leadingAnchor constant:14],
    [row.trailingAnchor constraintEqualToAnchor:banner.contentView.trailingAnchor constant:-14],
    [banner.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
    [banner.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
    [banner.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
  ]];
  banner.isAccessibilityElement = YES;
  banner.accessibilityLabel = [NSString stringWithFormat:@"%@. %@", heading, body];

  // Slides down and fades in, stays a few seconds, and goes on a tap or by itself.
  banner.alpha = 0;
  banner.transform = CGAffineTransformMakeTranslation(0, -16);
  [UIView animateWithDuration:0.35
                        delay:0
       usingSpringWithDamping:0.8
        initialSpringVelocity:0
                      options:0
                   animations:^{
                     banner.alpha = 1;
                     banner.transform = CGAffineTransformIdentity;
                   }
                   completion:nil];
  [[UINotificationFeedbackGenerator new] notificationOccurred:feedback];
  UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, banner.accessibilityLabel);

  [banner addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bannerTapped:)]];
  __weak UIVisualEffectView *weakBanner = banner;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [RFWebLoginViewController hideBanner:weakBanner];
  });
}

- (void)bannerTapped:(UITapGestureRecognizer *)tap {
  [RFWebLoginViewController hideBanner:tap.view];
}

+ (void)hideBanner:(UIView *)banner {
  if (!banner.superview) return;
  [UIView animateWithDuration:0.25
      animations:^{
        banner.alpha = 0;
        banner.transform = CGAffineTransformMakeTranslation(0, -16);
      }
      completion:^(BOOL done) {
        [banner removeFromSuperview];
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

// Watched rather than taken from a navigation: reddit.com goes to its feed without loading a new page.
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
  if (context != kRFLoginURLContext) return [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
  if (RFIsFeedPage(self.webView.URL)) [self coverFeedPage];
}

// Logged in, reddit.com goes on to its feed while the session is being checked. Its ads shouldn't show, so
// cover it. If there's no session after a few seconds (the page was left without logging in), show it.
- (void)coverFeedPage {
  if (self.finished || self.feedPageCovered) return;
  self.feedPageCovered = YES;
  if (!self.cover) [self showCover];
  [self advanceCoverToStep:2];
  [self checkForSession];
  __weak RFWebLoginViewController *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    RFWebLoginViewController *strongSelf = weakSelf;
    if (strongSelf && !strongSelf.finished && !strongSelf.sessionSeen)
      [strongSelf handOverToUser:RFHandOverStep message:nil];
  });
}

- (void)checkForSession {
  if (self.finished) return;
  [self.webView.configuration.websiteDataStore.httpCookieStore
      getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        NSString *session;
        for (NSHTTPCookie *cookie in cookies)
          if ([cookie.name isEqualToString:@"reddit_session"] &&
              ([cookie.domain isEqualToString:@"reddit.com"] || [cookie.domain hasSuffix:@".reddit.com"]) &&
              cookie.value.length)
            session = cookie.value;
        if (!session || self.finished) return;
        if (!self.sessionSeen) {
          self.sessionSeen = YES;
          if (!self.cover) [self showCover];
          [self advanceCoverToStep:2];
        }
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
               if (!username.length) {
                 // Right after logging in, reddit.com can take a few seconds to say who's logged in (2.5 s in
                 // one test). Look again every half second for up to 8 s. If there's still no account, the cookie
                 // isn't a logged-in session after all, so show the page rather than wait under the cover.
                 // Counted in time, not checks: every cookie the page sets brings another check.
                 if (!self.firstEmptySessionCheck) self.firstEmptySessionCheck = [NSDate date];
                 if (-self.firstEmptySessionCheck.timeIntervalSinceNow >= 8)
                   return [self handOverToUser:RFHandOverStep message:nil];
                 if (self.sessionCheckScheduled) return;
                 self.sessionCheckScheduled = YES;
                 __weak RFWebLoginViewController *weakSelf = self;
                 dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                   weakSelf.sessionCheckScheduled = NO;
                   [weakSelf checkForSession];
                 });
                 return;
               }
               self.finished = YES;
               self.succeeded = YES;
               [self.webView stopLoading];
               if (!self.cover) [self showCover];
               [self advanceCoverToStep:3];
               void (^completion)(NSString *, NSString *) = self.completion;
               // The app's own Log in button: answer the app now and keep the sheet up, covered, until
               // the app moves on to its "switching account" screen (the running mascot). Closing it first
               // would show the app's Log in screen again for a moment.
               if (self.prefillUsername) {
                 self.prefillPassword = nil;
                 if (completion) completion(session, username);
                 [self closeWhenWindow:self.view.window leaves:self.view.window.rootViewController checksLeft:80];
                 return;
               }
               [self dismissViewControllerAnimated:YES
                                        completion:^{
                                          if (completion) completion(session, username);
                                        }];
             }];
      }];
}

// After logging in for the app's own Log in button. The app shows its "switching account" screen by
// replacing the window's root screen, which takes this sheet away with the old one, so there's nothing
// to close then. Checks every 0.1 s; if the app hasn't moved on by the last check, closes the sheet.
- (void)closeWhenWindow:(UIWindow *)window leaves:(UIViewController *)root checksLeft:(NSInteger)checksLeft {
  if (!self.view.window) return; // gone with the old root screen
  if (window.rootViewController != root || checksLeft <= 0) {
    [self dismissViewControllerAnimated:checksLeft <= 0 completion:nil];
    return;
  }
  __weak RFWebLoginViewController *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [weakSelf closeWhenWindow:window leaves:root checksLeft:checksLeft - 1];
  });
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
      showAlert(controller, @"Log in with browser", @"Your browser login is ready. Tap \"Continue\" to finish logging in.");
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

// The sheet opened by RFBrowserLoginWithCredentials, while it's open.
static __weak RFWebLoginViewController *activeCredentialsLogin;

// The app's own Log in button: log in with the same username and password in the browser sheet,
// which fills them in and submits them itself. Calls completion once, on the main queue, with the
// session, or nil if the sheet couldn't be shown, one is already open, or the user closed it.
void RFBrowserLoginWithCredentials(NSString *username, NSString *password, void (^completion)(NSString *session)) {
  dispatch_async(dispatch_get_main_queue(), ^{
    __block BOOL answered = NO;
    void (^answer)(NSString *) = ^(NSString *session) {
      if (answered) return;
      answered = YES;
      completion(session);
    };
    UIViewController *presenter = topViewController();
    if (!presenter.view.window || activeCredentialsLogin ||
        UIApplication.sharedApplication.applicationState == UIApplicationStateBackground)
      return answer(nil);
    [presenter.view endEditing:YES];
    RFWebLoginViewController *webLogin = [RFWebLoginViewController new];
    webLogin.prefillUsername = username;
    webLogin.prefillPassword = password;
    webLogin.completion = ^(NSString *session, NSString *loggedInAs) {
      answer(session);
    };
    webLogin.cancellation = ^{
      answer(nil);
    };
    UINavigationController *navigationController =
        [[UINavigationController alloc] initWithRootViewController:webLogin];
    navigationController.presentationController.delegate = webLogin;
    activeCredentialsLogin = webLogin;
    __block BOOL shown = NO, gaveUp = NO;
    [presenter presentViewController:navigationController
                            animated:YES
                          completion:^{
                            shown = YES;
                            // Shown too late, after the app was already answered: it would only sit
                            // there, so close it.
                            if (gaveUp) [navigationController dismissViewControllerAnimated:YES completion:nil];
                          }];
    // UIKit holds a presentation back while another screen is still animating in or out, and skips
    // one it can't make at all. Only give up when it still hasn't shown after a while, so the app's
    // login doesn't wait forever.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      if (shown || webLogin.finished) return;
      gaveUp = YES;
      webLogin.finished = YES;
      webLogin.prefillPassword = nil;
      answer(nil);
    });
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
