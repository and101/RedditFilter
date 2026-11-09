// Real UIKit/SafariServices objects, with a presenter that records presentation without loading a
// remote Safari service. Run through tests/run-sim.sh; the Reddit-only hook is absent in this process.
#include ARTICLE_SAFARI_SOURCE

static void Check(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

@interface TestArticle : NSObject
@property(nonatomic, strong) id linkURL;
@end
@implementation TestArticle
@end

@interface TestNavigator : NSObject
@property(nonatomic, strong) UIViewController *vc;
@end
@implementation TestNavigator
@end

@interface TestPresenter : UIViewController
@property(nonatomic, strong) UIViewController *shown;
@property(nonatomic) NSUInteger presentations;
@property(nonatomic) BOOL declining;
@property(nonatomic) BOOL dismissing;
@end
@implementation TestPresenter
- (UIViewController *)presentedViewController { return self.shown; }
- (BOOL)isBeingDismissed { return self.dismissing; }
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
  self.presentations++;
  if (!self.declining) self.shown = controller;
}
@end

@interface TestArticleNavigation : UINavigationController
@property(nonatomic, copy) NSArray<UIViewController *> *testStack;
@property(nonatomic, strong) UIViewController *shown;
@property(nonatomic, copy) void (^presentationCompletion)(void);
@property(nonatomic) NSUInteger presentations, pops;
@property(nonatomic) BOOL declining;
@end
@implementation TestArticleNavigation
- (NSArray<UIViewController *> *)viewControllers { return self.testStack ?: @[]; }
- (UIViewController *)topViewController { return self.testStack.lastObject; }
- (UIViewController *)presentedViewController { return self.shown; }
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
  self.presentations++;
  if (!self.declining) {
    self.shown = controller;
    self.presentationCompletion = completion;
  }
}
- (UIViewController *)popViewControllerAnimated:(BOOL)animated {
  Check(!animated, @"Remove the captured article screen without a second navigation animation");
  self.pops++;
  UIViewController *removed = self.testStack.lastObject;
  self.testStack = [self.testStack subarrayWithRange:NSMakeRange(0, self.testStack.count - 1)];
  return removed;
}
- (void)finishPresentation {
  void (^completion)(void) = self.presentationCompletion;
  self.presentationCompletion = nil;
  if (completion) completion();
}
@end

@interface TestArticleDestination : UIViewController
@property(nonatomic, weak) UINavigationController *testNavigation;
@end
@implementation TestArticleDestination
- (UINavigationController *)navigationController { return self.testNavigation; }
@end

@interface TestArticleView : UIView
@end
@implementation TestArticleView
@end

@interface TestArticleWebView : WKWebView
@property(nonatomic) NSUInteger stops;
@property(nonatomic, strong) NSURL *testURL;
@end
@implementation TestArticleWebView
- (void)stopLoading { self.stops++; }
- (NSURL *)URL { return self.testURL; }
@end

@interface TestArticleCollection : UICollectionView
@property(nonatomic, copy) NSArray<UICollectionViewCell *> *testVisibleCells;
@end
@implementation TestArticleCollection
- (NSArray<UICollectionViewCell *> *)visibleCells { return self.testVisibleCells ?: @[]; }
@end

// Exercise the production scheduling helper with callbacks delivered before/after completion.
@interface TestArticleTransition : NSObject
@property(nonatomic) BOOL cancelled, immediate, acceptsCompletion;
@property(nonatomic, copy) void (^completion)(id<UIViewControllerTransitionCoordinatorContext>);
- (void)finish;
@end
@implementation TestArticleTransition
- (instancetype)init {
  if ((self = [super init])) _acceptsCompletion = YES;
  return self;
}
- (BOOL)animateAlongsideTransition:(void (^)(id<UIViewControllerTransitionCoordinatorContext>))animation
                       completion:(void (^)(id<UIViewControllerTransitionCoordinatorContext>))completion {
  self.completion = completion;
  if (self.immediate) [self finish];
  return self.acceptsCompletion;
}
- (void)finish {
  void (^completion)(id<UIViewControllerTransitionCoordinatorContext>) = self.completion;
  self.completion = nil;
  if (completion) completion((id<UIViewControllerTransitionCoordinatorContext>)self);
}
- (BOOL)isCancelled { return self.cancelled; }
@end

static void DrainArticleQueue(void) {
  __block BOOL drained = NO;
  dispatch_async(dispatch_get_main_queue(), ^{ drained = YES; });
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
  while (!drained && deadline.timeIntervalSinceNow > 0)
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  Check(drained, @"The queued initial inspection runs");
}

static RFArticlePushMarker *ArticleMarker(TestArticleNavigation *navigation, UIViewController *destination,
                                        NSArray<UIViewController *> *originalStack, WKWebView *webView) {
  RFArticlePushMarker *marker = [RFArticlePushMarker new];
  marker.navigation = navigation;
  marker.destination = destination;
  marker.originalStack = originalStack;
  marker.urls = [NSMapTable weakToStrongObjectsMapTable];
  [marker.urls setObject:[NSURL URLWithString:@"https://example.com/article?q=one#section"] forKey:webView];
  return marker;
}

static RFArticlePushMarker *PendingArticleMarker(TestArticleNavigation *navigation, UIViewController *destination,
                                               NSArray<UIViewController *> *originalStack) {
  RFArticlePushMarker *marker = [RFArticlePushMarker new];
  marker.navigation = navigation;
  marker.destination = destination;
  marker.originalStack = originalStack;
  objc_setAssociatedObject(destination, &kRFArticlePushMarker, marker, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return marker;
}

static void TestModernArticleFallback(UIWindow *window) {
  TestArticleNavigation *navigation = [TestArticleNavigation new];
  UIViewController *root = [UIViewController new], *post = [UIViewController new], *other = [UIViewController new];
  TestArticleDestination *destination = [TestArticleDestination new];
  destination.testNavigation = navigation;
  NSArray *originalStack = @[root, post], *pushedStack = @[root, post, destination];
  navigation.testStack = pushedStack;
  navigation.view.frame = window.bounds;
  destination.view.frame = navigation.view.bounds;
  [window addSubview:navigation.view];
  [navigation.view addSubview:destination.view];

  Check(RFArticleStackMatches(navigation, originalStack, destination), @"Match the exact original stack plus destination");
  navigation.testStack = @[other, post, destination];
  Check(!RFArticleStackMatches(navigation, originalStack, destination), @"Reject a changed earlier controller, even at the same depth");
  navigation.testStack = @[root, post, other];
  Check(!RFArticleStackMatches(navigation, originalStack, destination), @"Reject a replacement destination");
  navigation.testStack = @[root, post, destination, other];
  Check(!RFArticleStackMatches(navigation, originalStack, destination), @"Reject another screen pushed above the article");
  navigation.testStack = originalStack;
  Check(!RFArticleStackMatches(navigation, originalStack, destination), @"Reject an article screen already popped");
  navigation.testStack = pushedStack;

  TestArticleCollection *collection = [[TestArticleCollection alloc] initWithFrame:destination.view.bounds
      collectionViewLayout:[UICollectionViewFlowLayout new]];
  [destination.view addSubview:collection];
  UICollectionViewCell *cell = [[UICollectionViewCell alloc] initWithFrame:collection.bounds];
  [collection addSubview:cell];
  TestArticleView *article = [[TestArticleView alloc] initWithFrame:cell.bounds];
  [cell.contentView addSubview:article];
  TestArticleWebView *webView = [[TestArticleWebView alloc] initWithFrame:article.bounds];
  [article addSubview:webView];
  collection.testVisibleCells = @[cell];
  Check(RFArticleOwner(webView) == destination, @"Find the article's actual controller through its responder chain");
  Check(RFArticleWebViewIsVisible(webView, destination, TestArticleView.class), @"Accept the centered article in its own visible destination");
  Check(!RFArticleWebViewIsVisible(webView, other, TestArticleView.class), @"Reject a candidate owned by another controller");
  Check(!RFArticleWebViewIsVisible(webView, destination, UILabel.class), @"Reject a webview outside the expected article view");
  article.hidden = YES;
  Check(!RFArticleWebViewIsVisible(webView, destination, TestArticleView.class), @"Reject a hidden article ancestor");
  article.hidden = NO;
  cell.frame = CGRectOffset(collection.bounds, 0, CGRectGetHeight(collection.bounds));
  Check(!RFArticleWebViewIsVisible(webView, destination, TestArticleView.class), @"Reject an attached neighboring article outside the viewport center");
  cell.frame = collection.bounds;
  collection.testVisibleCells = @[];
  Check(webView.window == window && !RFArticleWebViewIsVisible(webView, destination, TestArticleView.class),
        @"An attached preload is not a visible article cell");

  RFArticlePushMarker *marker = ArticleMarker(navigation, destination, originalStack, webView);
  Check(!RFInspectArticlePush(marker, TestArticleView.class) && marker.inspected && navigation.presentations == 0,
        @"A video-first screen consumes its article fallback without presenting");
  collection.testVisibleCells = @[cell];
  Check(!RFInspectArticlePush(marker, TestArticleView.class) && navigation.presentations == 0,
        @"Swiping to an article later cannot reuse the consumed first-appearance marker");

  marker = ArticleMarker(navigation, destination, originalStack, webView);
  marker.cancelled = YES;
  Check(!RFInspectArticlePush(marker, TestArticleView.class) && navigation.presentations == 0 && navigation.pops == 0,
        @"A cancelled push never opens Safari or removes a native screen");

  [NSUserDefaults.standardUserDefaults setBool:NO forKey:kRedditFilterSafariLinks];
  marker = ArticleMarker(navigation, destination, originalStack, webView);
  Check(!RFInspectArticlePush(marker, TestArticleView.class) && marker.inspected && navigation.presentations == 0,
        @"Disabling the setting consumes the modern attempt without opening Safari");
  [NSUserDefaults.standardUserDefaults setBool:YES forKey:kRedditFilterSafariLinks];
  Check(!RFInspectArticlePush(marker, TestArticleView.class), @"Re-enabling does not revive an old article attempt");

  navigation.declining = YES;
  marker = ArticleMarker(navigation, destination, originalStack, webView);
  Check(!RFInspectArticlePush(marker, TestArticleView.class), @"Declined Safari presentation reports failure");
  Check(marker.inspected && webView.stops == 0 && navigation.pops == 0 && [navigation.testStack isEqualToArray:pushedStack],
        @"Declined presentation preserves the native article load and original post stack");
  navigation.declining = NO;

  marker = ArticleMarker(navigation, destination, originalStack, webView);
  Check(RFInspectArticlePush(marker, TestArticleView.class), @"Present Safari for the initial visible article");
  Check([navigation.shown isKindOfClass:SFSafariViewController.class] && webView.stops == 1 && navigation.pops == 0 &&
        navigation.presentationCompletion != nil, @"Keep the native screen until Safari presentation completes");
  [navigation finishPresentation];
  Check(navigation.pops == 1 && [navigation.testStack isEqualToArray:originalStack],
        @"After Safari appears, remove only the captured article and retain the original post");
  Check([RFSchemaDebug.shared.reportText containsString:@"original post restored"],
        @"Diagnostics report the completed handoff without its URL");
  Check(!RFInspectArticlePush(marker, TestArticleView.class), @"Accepted article presentation is also one-shot");

  navigation.shown = nil;
  navigation.testStack = pushedStack;
  marker = ArticleMarker(navigation, destination, originalStack, webView);
  Check(RFInspectArticlePush(marker, TestArticleView.class), @"Begin another eligible article presentation");
  navigation.testStack = @[root, post, other];
  [navigation finishPresentation];
  Check(navigation.pops == 1 && navigation.testStack.lastObject == other,
        @"A stack change during presentation must not pop the replacement screen");

  navigation.shown = nil;
  navigation.testStack = pushedStack;
  NSUInteger presentations = navigation.presentations;
  marker = PendingArticleMarker(navigation, destination, originalStack);
  [article removeFromSuperview];
  webView.testURL = [NSURL URLWithString:@"https://example.com/early?private=not-in-report#section"];
  RFRecordArticleWebView(webView, webView.URL);
  Check(marker.urls.count == 0, @"A callback before attachment cannot find the destination marker");
  [cell.contentView addSubview:article];
  RFScheduleArticleInspection(marker, nil, TestArticleView.class);
  Check(!marker.inspected && navigation.presentations == presentations, @"No-animation push still waits one main-queue turn");
  DrainArticleQueue();
  Check(marker.inspected && navigation.presentations == presentations + 1,
        @"Recover an initial visible article whose callback preceded attachment, without waiting for another callback");
  [navigation finishPresentation];

  navigation.shown = nil;
  navigation.testStack = pushedStack;
  presentations = navigation.presentations;
  webView.testURL = nil;
  marker = PendingArticleMarker(navigation, destination, originalStack);
  TestArticleTransition *transition = [TestArticleTransition new];
  RFScheduleArticleInspection(marker, (id<UIViewControllerTransitionCoordinator>)transition, TestArticleView.class);
  DrainArticleQueue();
  Check(!marker.inspected && navigation.presentations == presentations, @"An unfinished push does not inspect or present");
  webView.testURL = [NSURL URLWithString:@"https://example.com/ready-before-transition"];
  RFRecordArticleWebView(webView, webView.URL);
  [transition finish];
  Check(!marker.inspected, @"Transition completion queues rather than reenters presentation");
  DrainArticleQueue();
  Check(marker.inspected && navigation.presentations == presentations + 1,
        @"A URL arriving during a cold push is used after its transition completes");
  [navigation finishPresentation];

  navigation.shown = nil;
  navigation.testStack = pushedStack;
  presentations = navigation.presentations;
  marker = PendingArticleMarker(navigation, destination, originalStack);
  transition = [TestArticleTransition new];
  transition.immediate = YES;
  RFScheduleArticleInspection(marker, (id<UIViewControllerTransitionCoordinator>)transition, TestArticleView.class);
  Check(!marker.inspected, @"Synchronous transition completion still yields before inspection");
  DrainArticleQueue();
  Check(navigation.presentations == presentations + 1, @"Short transition uses the same initial-article guard");
  [navigation finishPresentation];

  navigation.shown = nil;
  navigation.testStack = pushedStack;
  presentations = navigation.presentations;
  webView.testURL = nil;
  marker = PendingArticleMarker(navigation, destination, originalStack);
  RFScheduleArticleInspection(marker, nil, TestArticleView.class);
  DrainArticleQueue();
  Check(marker.inspected && navigation.presentations == presentations, @"A genuinely unready initial URL preserves native browsing");
  Check([RFSchemaDebug.shared.reportText containsString:@"initial article URL not ready"],
        @"Diagnostics distinguish an unready URL from missing hooks");
  webView.testURL = [NSURL URLWithString:@"https://example.com/too-late"];
  RFRecordArticleWebView(webView, webView.URL);
  DrainArticleQueue();
  Check(!RFInspectArticlePush(marker, TestArticleView.class) && navigation.presentations == presentations,
        @"Late URLs cannot revive an expired attempt or interrupt later browsing");

  marker = PendingArticleMarker(navigation, destination, originalStack);
  transition = [TestArticleTransition new];
  transition.cancelled = YES;
  RFScheduleArticleInspection(marker, (id<UIViewControllerTransitionCoordinator>)transition, TestArticleView.class);
  [transition finish];
  DrainArticleQueue();
  Check(marker.inspected && marker.cancelled && navigation.presentations == presentations,
        @"A real completion callback reporting cancellation keeps native behavior");

  marker = PendingArticleMarker(navigation, destination, originalStack);
  transition = [TestArticleTransition new];
  transition.acceptsCompletion = NO;
  RFScheduleArticleInspection(marker, (id<UIViewControllerTransitionCoordinator>)transition, TestArticleView.class);
  DrainArticleQueue();
  Check(navigation.presentations == presentations + 1, @"An unavailable coordinator queues the initial inspection once");
  [transition finish];
  DrainArticleQueue();
  Check(navigation.presentations == presentations + 1, @"A late duplicate coordinator callback cannot present twice");
  [navigation finishPresentation];
  [navigation.view removeFromSuperview];
}

static void TestArticleDiagnostics(void) {
  RFSchemaDebug *debug = RFSchemaDebug.shared;
  RFSetDiagnosticsEnabled(YES);
  [debug setArticleSafariHooks:RFArticleSafariHookLegacy | RFArticleSafariHookPush | RFArticleSafariHookStart];
  [debug recordArticleSafariResult:RFArticleSafariModernPresented];
  NSString *report = debug.reportText;
  Check([report containsString:@"Article links in Safari:"] && [report containsString:@"Legacy hook: found"] &&
        [report containsString:@"Article policy hook: missing"] && [report containsString:@"Post-page article: Safari presented"],
        @"The existing report describes hook availability separately from the observed outcome");
  Check(![report containsString:@"example.com"] && ![report containsString:@"private="] &&
        ![report containsString:@"not-in-report"], @"Article diagnostics contain no URL, query or fragment history");
  [debug recordArticleSafariResult:(RFArticleSafariResult)999];
  Check([debug.reportText isEqualToString:report], @"Unknown outcome values cannot enter the report");
  [debug reset];
  Check([debug.reportText containsString:@"No article attempt observed"] && [debug.reportText containsString:@"Legacy hook: found"],
        @"Reset clears activity but retains static compatibility");
  [debug recordArticleSafariResult:RFArticleSafariURLNotReady];
  RFSetDiagnosticsEnabled(NO);
  [debug recordArticleSafariResult:RFArticleSafariPresentationDeclined];
  Check([debug.reportText containsString:@"No article attempt observed"] && ![debug.reportText containsString:@"presentation declined"],
        @"Turning Diagnostics off clears the last outcome and stops recording");
}

int main(void) {
  @autoreleasepool {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id saved = [defaults objectForKey:kRedditFilterSafariLinks];
    BOOL diagnosticsWasEnabled = RFDiagnosticsEnabled();
    RFSetDiagnosticsEnabled(YES);
    TestArticle *post = [TestArticle new];
    for (NSString *link in @[@"https://example.com/article?q=a%20b#section", @"http://example.com/"]) {
      post.linkURL = [NSURL URLWithString:link];
      Check([RFArticleURL(post).absoluteString isEqual:link], @"Preserve HTTP(S) URL, query and fragment");
    }
    for (id link in @[[NSNull null], @"https://example.com/", [NSURL URLWithString:@"file:///tmp/page.html"],
                       [NSURL URLWithString:@"javascript:alert(1)"], [NSURL URLWithString:@"reddit://r/test"],
                       [NSURL URLWithString:@"/relative"], [NSURL URLWithString:@"https:"]]) {
      post.linkURL = link;
      Check(!RFArticleURL(post), @"Reject non-URL objects, unsupported schemes and missing hosts");
    }
    Check(!RFArticleURL(nil) && !RFArticleURL([NSObject new]), @"Missing URL getter is safe");

    post.linkURL = [NSURL URLWithString:@"https://example.com/article"];
    TestNavigator *navigator = [TestNavigator new];
    TestPresenter *presenter = [TestPresenter new];
    navigator.vc = presenter;
    UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 402, 874)];
    window.hidden = NO;
    [window addSubview:presenter.view];

    [defaults setBool:NO forKey:kRedditFilterSafariLinks];
    Check(!RFOpenArticleInSafari(navigator, post) && presenter.presentations == 0, @"Off: leave original route alone");
    [defaults setBool:YES forKey:kRedditFilterSafariLinks];
    Check(!RFOpenArticleInSafari([NSObject new], post), @"Changed navigator falls back");
    Check(!RFOpenArticleInSafari(navigator, [NSObject new]), @"Changed post falls back");
    [presenter.view removeFromSuperview];
    Check(!RFOpenArticleInSafari(navigator, post), @"Detached presenter falls back");
    [window addSubview:presenter.view];
    window.hidden = YES;
    Check(!RFOpenArticleInSafari(navigator, post), @"Hidden window falls back");
    window.hidden = NO;
    presenter.dismissing = YES;
    Check(!RFOpenArticleInSafari(navigator, post), @"Dismissing screen falls back");
    presenter.dismissing = NO;
    presenter.shown = [UIViewController new];
    Check(!RFOpenArticleInSafari(navigator, post), @"Do not replace an unrelated sheet");
    presenter.shown = nil;
    dispatch_semaphore_t checked = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      Check(!RFOpenArticleInSafari(navigator, post), @"Never present UIKit off the main thread");
      dispatch_semaphore_signal(checked);
    });
    Check(dispatch_semaphore_wait(checked, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
          @"Background check finishes");

    Check(RFOpenArticleInSafari(navigator, post), @"Present an eligible article");
    Check([presenter.shown isKindOfClass:SFSafariViewController.class] && presenter.presentations == 1,
          @"Use Apple's Safari controller exactly once");
    Check(!RFOpenArticleInSafari(navigator, post) && presenter.presentations == 1, @"Do not stack Safari sheets");
    presenter.shown = nil;
    Check(RFOpenArticleInSafari(navigator, post) && presenter.presentations == 2, @"Can open another article after closing");
    presenter.shown = nil;
    presenter.declining = YES;
    Check(!RFOpenArticleInSafari(navigator, post), @"Failed presentation keeps the original route");

    [presenter.view removeFromSuperview];
    for (NSValue *size in @[[NSValue valueWithCGSize:CGSizeMake(402, 874)],
                           [NSValue valueWithCGSize:CGSizeMake(874, 402)],
                           [NSValue valueWithCGSize:CGSizeMake(1024, 1366)],
                           [NSValue valueWithCGSize:CGSizeMake(1366, 1024)],
                           [NSValue valueWithCGSize:CGSizeMake(375, 1024)]]) {
      window.frame = (CGRect){CGPointZero, size.CGSizeValue};
      TestModernArticleFallback(window);
    }
    TestArticleDiagnostics();
    RFSetDiagnosticsEnabled(diagnosticsWasEnabled);

    if (saved) [defaults setObject:saved forKey:kRedditFilterSafariLinks];
    else [defaults removeObjectForKey:kRedditFilterSafariLinks];
    puts("All article Safari tests passed.");
  }
  return 0;
}
