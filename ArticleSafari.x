// Use Safari for article links: intercept the legacy route, or hand off the initial article
// after a modern post-page push. Other web views (especially login) and videos stay native.
#import <SafariServices/SafariServices.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <string.h>
#import "PreferenceKeys.h"
#import "DebugMenu.h"

@interface RFArticlePost : NSObject
@property(nonatomic, readonly) NSURL *linkURL;
@end

// The setting, kept up to date as the defaults change (read on every push in Home's stack, so not looked
// up each time).
static atomic_bool gRFSafariLinks;

static void RFArticleReadSetting(void) {
  atomic_store(&gRFSafariLinks, [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterSafariLinks]);
}

static BOOL RFArticleSafariLinksOn(void) { return atomic_load(&gRFSafariLinks); }

static void RFArticleRecordResult(RFArticleSafariResult result) {
  if (RFDiagnosticsEnabled()) [[RFSchemaDebug shared] recordArticleSafariResult:result];
}

static BOOL RFArticleFallback(RFArticleSafariResult result) {
  RFArticleRecordResult(result);
  return NO;
}

@interface RFArticleNavigator : NSObject
@property(nonatomic, readonly) UIViewController *vc;
@end

static NSURL *RFArticleValidURL(id url) {
  if (![url isKindOfClass:NSURL.class]) return nil;
  NSString *scheme = [(NSURL *)url scheme].lowercaseString;
  if ((![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"]) || ![(NSURL *)url host].length)
    return nil;
  return url;
}

static NSURL *RFArticleURL(id post) {
  return [post respondsToSelector:@selector(linkURL)] ? RFArticleValidURL([(RFArticlePost *)post linkURL]) : nil;
}

static BOOL RFOpenArticleInSafari(id navigator, id post) {
  if (![NSThread isMainThread]) return RFArticleFallback(RFArticleSafariPresenterUnavailable);
  if (!RFArticleSafariLinksOn())
    return RFArticleFallback(RFArticleSafariDisabledOrCancelled);
  NSURL *url = RFArticleURL(post);
  if (!url) return RFArticleFallback(RFArticleSafariInvalidURL);
  if (![navigator respondsToSelector:@selector(vc)]) return RFArticleFallback(RFArticleSafariMissingGetter);
  UIViewController *presenter = [(RFArticleNavigator *)navigator vc];
  if (![presenter isKindOfClass:UIViewController.class]) return RFArticleFallback(RFArticleSafariPresenterUnavailable);
  UIWindow *window = presenter.viewIfLoaded.window;
  if (!window || window.hidden || presenter.presentedViewController || presenter.isBeingPresented ||
      presenter.isBeingDismissed || presenter.transitionCoordinator ||
      (window.windowScene && window.windowScene.activationState != UISceneActivationStateForegroundActive))
    return RFArticleFallback(RFArticleSafariPresenterUnavailable);

  SFSafariViewController *safari = [[SFSafariViewController alloc] initWithURL:url];
  [presenter presentViewController:safari animated:YES completion:nil];
  BOOL presented = safari.presentingViewController != nil || presenter.presentedViewController == safari;
  RFArticleRecordResult(presented ? RFArticleSafariLegacyPresented : RFArticleSafariPresentationDeclined);
  return presented;
}

// The modern post route is Swift-only. Observe its initial native push, then replace only a
// proven visible article. A marker expires at the first inspection, even if that screen is a video.
@interface RFArticlePushMarker : NSObject
@property(nonatomic, weak) UINavigationController *navigation;
@property(nonatomic, weak) UIViewController *destination;
@property(nonatomic, copy) NSArray<UIViewController *> *originalStack;
@property(nonatomic, strong) NSMapTable<WKWebView *, id> *urls;
@property(nonatomic) BOOL inspected;
@property(nonatomic) BOOL cancelled;
@end
@implementation RFArticlePushMarker
- (instancetype)init {
  if ((self = [super init])) _urls = [NSMapTable weakToStrongObjectsMapTable];
  return self;
}
@end

static char kRFArticlePushMarker;
static NSString *const kRFArticleControllerName =
    @"_TtGC14RedditSliceKit24RedditBaseViewControllerC14Video_FBP_Impl16FBPListViewModel_";

static BOOL RFArticleStackMatches(UINavigationController *navigation, NSArray<UIViewController *> *originalStack,
                                  UIViewController *destination) {
  NSArray *current = navigation.viewControllers;
  if (!originalStack.count || !destination || current.count != originalStack.count + 1 ||
      current.lastObject != destination || navigation.topViewController != destination) return NO;
  for (NSUInteger i = 0; i < originalStack.count; i++)
    if (current[i] != originalStack[i]) return NO;
  return YES;
}

static UIViewController *RFArticleOwner(UIView *view) {
  UIResponder *node = view;
  for (NSUInteger i = 0; node && i < 32; i++, node = node.nextResponder)
    if ([node isKindOfClass:UIViewController.class]) return (UIViewController *)node;
  return nil;
}

static BOOL RFArticleWebViewIsVisible(WKWebView *webView, UIViewController *destination, Class articleClass) {
  UIView *root = destination.viewIfLoaded;
  if (!articleClass || !webView.window || webView.window != root.window || RFArticleOwner(webView) != destination)
    return NO;
  UIView *article = nil;
  UICollectionViewCell *cell = nil;
  UICollectionView *collection = nil;
  BOOL reachedRoot = NO;
  for (UIView *view = webView; view; view = view.superview) {
    // Reddit keeps the web view itself hidden until the page has loaded, so only its ancestors count.
    if (view != webView && (view.hidden || view.alpha <= 0.01)) return NO;
    if (!article && [view isKindOfClass:articleClass]) article = view;
    if (!cell && [view isKindOfClass:UICollectionViewCell.class]) cell = (UICollectionViewCell *)view;
    if (!collection && [view isKindOfClass:UICollectionView.class]) collection = (UICollectionView *)view;
    if (view == root) { reachedRoot = YES; break; }
  }
  if (!reachedRoot || !article || !cell || !collection || ![collection.visibleCells containsObject:cell]) return NO;
  // Adjacent/preloaded cells may be attached too; only the article occupying the viewport centre qualifies.
  CGPoint centre = CGPointMake(CGRectGetMidX(collection.bounds), CGRectGetMidY(collection.bounds));
  CGRect articleFrame = [article convertRect:article.bounds toView:collection];
  CGRect webFrame = [webView convertRect:webView.bounds toView:collection];
  return CGRectContainsPoint(articleFrame, centre) && !CGRectIsEmpty(webFrame) &&
         CGRectIntersectsRect(webFrame, collection.bounds);
}

static void RFRecordArticleWebView(WKWebView *webView, id url) {
  if (!NSThread.isMainThread) return;
  UIViewController *owner = RFArticleOwner(webView);
  RFArticlePushMarker *marker = objc_getAssociatedObject(owner, &kRFArticlePushMarker);
  if (!marker || marker.inspected || marker.destination != owner) return;
  id previous = [marker.urls objectForKey:webView];
  NSURL *valid = RFArticleValidURL(url);
  if (!previous || (!RFArticleValidURL(previous) && valid)) {
    [marker.urls setObject:valid ?: (id)NSNull.null forKey:webView];
  }
}

static NSArray<WKWebView *> *RFInitialArticleWebViews(UIViewController *destination) {
  UIView *root = destination.viewIfLoaded;
  if (!root) return @[];
  NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:root];
  NSMutableArray<WKWebView *> *webViews = [NSMutableArray array];
  while (pending.count) {
    UIView *view = pending.lastObject;
    [pending removeLastObject];
    if ([view isKindOfClass:WKWebView.class]) [webViews addObject:(WKWebView *)view];
    else [pending addObjectsFromArray:view.subviews]; // no need to traverse WebKit's own internal views
  }
  return webViews;
}

static BOOL RFInspectArticlePush(RFArticlePushMarker *marker, Class articleClass) {
  if (!marker || marker.inspected) return NO;
  marker.inspected = YES;
  UIViewController *destination = marker.destination;
  UINavigationController *navigation = marker.navigation;
  if (destination && objc_getAssociatedObject(destination, &kRFArticlePushMarker) == marker)
    objc_setAssociatedObject(destination, &kRFArticlePushMarker, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  // Consume first: no later video swipe, preload, redirect or back-navigation can revive this attempt.
  if (!NSThread.isMainThread || marker.cancelled ||
      !RFArticleSafariLinksOn()) {
    return RFArticleFallback(RFArticleSafariDisabledOrCancelled);
  }
  if (!RFArticleStackMatches(navigation, marker.originalStack, destination)) {
    return RFArticleFallback(RFArticleSafariStackChanged);
  }
  UIWindow *window = destination.viewIfLoaded.window;
  if (!window || window.hidden || navigation.viewIfLoaded.window != window ||
      (window.windowScene && window.windowScene.activationState != UISceneActivationStateForegroundActive) ||
      navigation.presentedViewController || navigation.isBeingPresented || navigation.isBeingDismissed ||
      destination.isBeingPresented || destination.isBeingDismissed ||
      navigation.transitionCoordinator || destination.transitionCoordinator) {
    return RFArticleFallback(RFArticleSafariPresenterUnavailable);
  }
  WKWebView *article = nil;
  NSURL *url = nil;
  BOOL visibleArticle = NO;
  // WebKit can send its first callbacks before the view has an owner, so no marker captured them.
  // Inspect the initial loaded hierarchy too; visibility and owner checks remain unchanged.
  for (WKWebView *view in RFInitialArticleWebViews(destination)) {
    if (!RFArticleWebViewIsVisible(view, destination, articleClass)) continue;
    visibleArticle = YES;
    NSURL *candidate = RFArticleValidURL([marker.urls objectForKey:view]) ?: RFArticleValidURL(view.URL);
    if (!candidate) continue;
    if (article) {
      return RFArticleFallback(RFArticleSafariAmbiguousArticle);
    }
    article = view;
    url = candidate;
  }
  if (!article) {
    return RFArticleFallback(visibleArticle ? RFArticleSafariURLNotReady : RFArticleSafariNoVisibleArticle);
  }
  SFSafariViewController *safari = [[SFSafariViewController alloc] initWithURL:url];
  [navigation presentViewController:safari animated:YES completion:^{
    // Present from the persistent navigation controller, then remove only our captured destination.
    // If presentation or navigation changed, leave the native stack intact.
    if ((safari.presentingViewController || navigation.presentedViewController == safari) &&
        RFArticleStackMatches(navigation, marker.originalStack, destination)) {
      [navigation popViewControllerAnimated:NO];
      RFArticleRecordResult(RFArticleSafariReturnedToPost);
    } else {
      RFArticleRecordResult(RFArticleSafariReturnSkipped);
    }
  }];
  BOOL accepted = safari.presentingViewController != nil || navigation.presentedViewController == safari;
  if (accepted) [article stopLoading];
  RFArticleRecordResult(accepted ? RFArticleSafariModernPresented : RFArticleSafariPresentationDeclined);
  return accepted;
}

static void RFScheduleArticleInspection(RFArticlePushMarker *marker,
                                        id<UIViewControllerTransitionCoordinator> coordinator, Class articleClass) {
  void (^inspect)(void) = ^{
    dispatch_async(dispatch_get_main_queue(), ^{
      // The Swift view class may first become available while the pushed screen loads.
      RFInspectArticlePush(marker, articleClass ?: NSClassFromString(@"Video_FBP_Impl.FBPArticleLinkConsumptionView"));
    });
  };
  if (!coordinator || ![coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
    marker.cancelled = context.isCancelled;
    inspect();
  }]) inspect();
}

%group RFArticlePush
%hook RFArticleNavigationController
- (void)pushViewController:(UIViewController *)destination animated:(BOOL)animated {
  UINavigationController *navigation = (UINavigationController *)self;
  RFArticlePushMarker *marker = nil;
  if (NSThread.isMainThread && RFArticleSafariLinksOn() &&
      [NSStringFromClass(destination.class) isEqualToString:kRFArticleControllerName] &&
      navigation.topViewController && navigation.topViewController != destination) {
    marker = [RFArticlePushMarker new];
    marker.navigation = navigation;
    marker.destination = destination;
    marker.originalStack = navigation.viewControllers;
    objc_setAssociatedObject(destination, &kRFArticlePushMarker, marker, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  %orig;
  if (!marker) return;
  RFScheduleArticleInspection(marker, navigation.transitionCoordinator, Nil);
}
%end
%end

%group RFArticleSafari
%hook RFArticleNavigator
- (void)navigateArticleLinkExperienceForPost:(id)post
                           feedContextInfo:(id)feedContextInfo
                           videoPlayerView:(id)videoPlayerView
                         navigationSession:(id)navigationSession
                                 servingID:(id)servingID
                     analyticsReferrerInfo:(id)analyticsReferrerInfo {
  if (!RFOpenArticleInSafari(self, post)) %orig;
}
%end
%end

%group RFArticleWebViewStart
%hook RFArticleWebViewModel
- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
  RFRecordArticleWebView(webView, webView.URL);
  %orig;
}
%end
%end

%group RFArticleWebViewPolicy
%hook RFArticleWebViewModel
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
 decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
  if (action.targetFrame.isMainFrame) RFRecordArticleWebView(webView, action.request.URL);
  %orig;
}
%end
%end

%ctor {
  RFArticleReadSetting();
  [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification
                                                  object:nil
                                                   queue:nil
                                              usingBlock:^(NSNotification *note) {
                                                RFArticleReadSetting();
                                              }];
  RFArticleSafariHooks hooks = 0;
  Class navigator = NSClassFromString(@"Video_OldVideo_OldVideoLegacy.VideoPostNavigatorImpl");
  SEL route = @selector(navigateArticleLinkExperienceForPost:feedContextInfo:videoPlayerView:navigationSession:servingID:analyticsReferrerInfo:);
  Method method = class_getInstanceMethod(navigator, route);
  // Only install the hook for the object-argument ABI checked in Reddit 2026.44.
  if (method && strcmp(method_getTypeEncoding(method), "v64@0:8@16@24@32@40@48@56") == 0) {
    %init(RFArticleSafari, RFArticleNavigator = navigator);
    hooks |= RFArticleSafariHookLegacy;
  }
  Class navigation = NSClassFromString(@"MainTabBar.MainTabBarNavigationController");
  Method push = class_getInstanceMethod(navigation, @selector(pushViewController:animated:));
  if (push && strcmp(method_getTypeEncoding(push), "v28@0:8@16B24") == 0) {
    %init(RFArticlePush, RFArticleNavigationController = navigation);
    hooks |= RFArticleSafariHookPush;
  }
  Class web = NSClassFromString(@"Video_FBP_Impl.FBPArticleLinkConsumptionViewModel");
  Method start = class_getInstanceMethod(web, @selector(webView:didStartProvisionalNavigation:));
  if (start && strcmp(method_getTypeEncoding(start), "v32@0:8@16@24") == 0) {
    %init(RFArticleWebViewStart, RFArticleWebViewModel = web);
    hooks |= RFArticleSafariHookStart;
  }
  Method policy = class_getInstanceMethod(web, @selector(webView:decidePolicyForNavigationAction:decisionHandler:));
  // Reddit 2026.44 reports the long form (with class names); the plain form is the same method.
  const char *policyTypes = policy ? method_getTypeEncoding(policy) : NULL;
  if (policyTypes && (strcmp(policyTypes, "v40@0:8@\"WKWebView\"16@\"WKNavigationAction\"24@?<v@?q>32") == 0 ||
                      strcmp(policyTypes, "v40@0:8@16@24@?32") == 0)) {
    %init(RFArticleWebViewPolicy, RFArticleWebViewModel = web);
    hooks |= RFArticleSafariHookPolicy;
  }
  [[RFSchemaDebug shared] setArticleSafariHooks:hooks];
}
