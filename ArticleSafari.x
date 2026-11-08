// Use Safari for article links: intercept the legacy route, or hand off the initial article
// after a modern post-page push. Other web views (especially login) and videos stay native.
#import <SafariServices/SafariServices.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <string.h>
#import "PreferenceKeys.h"

@interface RFArticlePost : NSObject
@property(nonatomic, readonly) NSURL *linkURL;
@end

@interface RFArticleNavigator : NSObject
@property(nonatomic, readonly) UIViewController *vc;
@end

#ifdef RF_ARTICLE_TRACE
// Temporary, opt-in build diagnostic. Only fixed event names, flags and class names are recorded.
static void RFArticleTrace(NSString *event, NSString *reason, UIViewController *presenter, UIView *view) {
  BOOL mainThread = NSThread.isMainThread;
  NSMutableDictionary *entry = [@{@"event" : event, @"reason" : reason, @"mainThread" : @(mainThread),
      @"enabled" : @([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterSafariLinks])} mutableCopy];
  if (mainThread) {
    if ([presenter isKindOfClass:UIViewController.class]) {
      entry[@"presenter"] = NSStringFromClass(presenter.class);
      UIViewController *presented = presenter.presentedViewController;
      if (presented) entry[@"presented"] = NSStringFromClass(presented.class);
    }
    if (view) {
      entry[@"attached"] = @(view.window != nil);
      NSMutableArray *responders = [NSMutableArray array], *ancestors = [NSMutableArray array];
      UIViewController *owner = nil;
      for (UIResponder *node = view; node && responders.count < 16; node = node.nextResponder) {
        [responders addObject:NSStringFromClass(node.class)];
        if (!owner && [node isKindOfClass:UIViewController.class]) owner = (UIViewController *)node;
      }
      for (UIView *node = view; node && ancestors.count < 16; node = node.superview)
        [ancestors addObject:NSStringFromClass(node.class)];
      entry[@"responders"] = responders;
      entry[@"viewAncestors"] = ancestors;
      NSMutableArray *parents = [NSMutableArray array];
      for (UIViewController *node = owner; node && parents.count < 12; node = node.parentViewController)
        [parents addObject:NSStringFromClass(node.class)];
      entry[@"controllerParents"] = parents;
      if (owner.presentingViewController)
        entry[@"ownerPresenting"] = NSStringFromClass(owner.presentingViewController.class);
    }
  }
  static dispatch_queue_t queue;
  static NSMutableArray *entries;
  static NSString *path;
  static NSUInteger sequence;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("com.and101.RedditFilter.article-trace", DISPATCH_QUEUE_SERIAL);
    entries = [NSMutableArray array];
    NSString *directory = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (directory) {
      [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
      path = [directory stringByAppendingPathComponent:@"RedditFilterArticleTrace.plist"];
    }
  });
  dispatch_async(queue, ^{
    entry[@"sequence"] = @(++sequence);
    [entries addObject:entry];
    if (entries.count > 40) [entries removeObjectAtIndex:0];
    if (path) [entries writeToFile:path atomically:YES];
  });
}

static UIViewController *RFArticleTracePresenter(id navigator) {
  if (!NSThread.isMainThread || ![navigator respondsToSelector:@selector(vc)]) return nil;
  id presenter = [(RFArticleNavigator *)navigator vc];
  return [presenter isKindOfClass:UIViewController.class] ? presenter : nil;
}

static BOOL RFArticleTraceHookMatches(Class cls, SEL selector, const char *encoding, NSString *event) {
  Method method = class_getInstanceMethod(cls, selector);
  BOOL matches = method && strcmp(method_getTypeEncoding(method), encoding) == 0;
  RFArticleTrace(event, !cls ? @"missing-class" : !method ? @"missing-method" :
                       matches ? @"abi-matched" : @"abi-mismatch", nil, nil);
  return matches;
}
#define RF_ARTICLE_EVENT(...) RFArticleTrace(__VA_ARGS__)
#define RF_ARTICLE_REJECT(reason, presenter) do { RFArticleTrace(@"article-fallback", reason, presenter, nil); return NO; } while (0)
#else
#define RF_ARTICLE_EVENT(...) ((void)0)
#define RF_ARTICLE_REJECT(reason, presenter) return NO
#endif

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
  if (![NSThread isMainThread]) RF_ARTICLE_REJECT(@"off-main-thread", nil);
  if (![NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterSafariLinks])
    RF_ARTICLE_REJECT(@"option-off", nil);
  NSURL *url = RFArticleURL(post);
  if (!url) RF_ARTICLE_REJECT(@"invalid-article-url", nil);
  if (![navigator respondsToSelector:@selector(vc)]) RF_ARTICLE_REJECT(@"missing-presenter-getter", nil);
  UIViewController *presenter = [(RFArticleNavigator *)navigator vc];
  if (![presenter isKindOfClass:UIViewController.class]) RF_ARTICLE_REJECT(@"invalid-presenter", nil);
  UIWindow *window = presenter.viewIfLoaded.window;
  if (!window) RF_ARTICLE_REJECT(@"detached-presenter", presenter);
  if (window.hidden) RF_ARTICLE_REJECT(@"hidden-window", presenter);
  if (presenter.presentedViewController) RF_ARTICLE_REJECT(@"existing-presentation", presenter);
  if (presenter.isBeingPresented) RF_ARTICLE_REJECT(@"presenter-being-presented", presenter);
  if (presenter.isBeingDismissed) RF_ARTICLE_REJECT(@"presenter-being-dismissed", presenter);
  if (presenter.transitionCoordinator) RF_ARTICLE_REJECT(@"presenter-transition", presenter);
  if (window.windowScene && window.windowScene.activationState != UISceneActivationStateForegroundActive)
    RF_ARTICLE_REJECT(@"inactive-scene", presenter);

  SFSafariViewController *safari = [[SFSafariViewController alloc] initWithURL:url];
  [presenter presentViewController:safari animated:YES completion:nil];
  BOOL presented = safari.presentingViewController != nil || presenter.presentedViewController == safari;
  RF_ARTICLE_EVENT(@"article-presentation", presented ? @"accepted" : @"declined", presenter, nil);
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
    if (view.hidden || view.alpha <= 0.01) return NO;
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
    RF_ARTICLE_EVENT(@"modern-candidate", valid ? @"url-captured" : @"awaiting-url", owner, nil);
  }
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
      ![NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterSafariLinks]) {
    RF_ARTICLE_EVENT(@"modern-fallback", @"cancelled-or-disabled", nil, nil);
    return NO;
  }
  if (!RFArticleStackMatches(navigation, marker.originalStack, destination)) {
    RF_ARTICLE_EVENT(@"modern-fallback", @"stack-changed", navigation, nil);
    return NO;
  }
  UIWindow *window = destination.viewIfLoaded.window;
  if (!window || window.hidden || navigation.viewIfLoaded.window != window ||
      (window.windowScene && window.windowScene.activationState != UISceneActivationStateForegroundActive) ||
      navigation.presentedViewController || navigation.isBeingPresented || navigation.isBeingDismissed ||
      destination.isBeingPresented || destination.isBeingDismissed ||
      navigation.transitionCoordinator || destination.transitionCoordinator) {
    RF_ARTICLE_EVENT(@"modern-fallback", @"presenter-unavailable", navigation, nil);
    return NO;
  }
  WKWebView *article = nil;
  NSURL *url = nil;
  for (WKWebView *view in marker.urls.keyEnumerator.allObjects) {
    if (!RFArticleWebViewIsVisible(view, destination, articleClass)) continue;
    NSURL *candidate = RFArticleValidURL([marker.urls objectForKey:view]) ?: RFArticleValidURL(view.URL);
    if (!candidate) continue;
    if (article) {
      RF_ARTICLE_EVENT(@"modern-fallback", @"ambiguous-visible-article", navigation, nil);
      return NO;
    }
    article = view;
    url = candidate;
  }
  if (!article) {
    RF_ARTICLE_EVENT(@"modern-fallback", @"no-visible-article", navigation, nil);
    return NO;
  }
  SFSafariViewController *safari = [[SFSafariViewController alloc] initWithURL:url];
  [navigation presentViewController:safari animated:YES completion:^{
    // Present from the persistent navigation controller, then remove only our captured destination.
    // If presentation or navigation changed, leave the native stack intact.
    if ((safari.presentingViewController || navigation.presentedViewController == safari) &&
        RFArticleStackMatches(navigation, marker.originalStack, destination)) {
      [navigation popViewControllerAnimated:NO];
      RF_ARTICLE_EVENT(@"modern-return", @"captured-destination-popped", navigation, nil);
    } else {
      RF_ARTICLE_EVENT(@"modern-return", @"stack-or-presentation-changed", navigation, nil);
    }
  }];
  BOOL accepted = safari.presentingViewController != nil || navigation.presentedViewController == safari;
  if (accepted) [article stopLoading];
  RF_ARTICLE_EVENT(@"modern-presentation", accepted ? @"accepted" : @"declined", navigation, nil);
  return accepted;
}

%group RFArticlePush
%hook RFArticleNavigationController
- (void)pushViewController:(UIViewController *)destination animated:(BOOL)animated {
  UINavigationController *navigation = (UINavigationController *)self;
  RFArticlePushMarker *marker = nil;
  if (NSThread.isMainThread && [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterSafariLinks] &&
      [NSStringFromClass(destination.class) isEqualToString:kRFArticleControllerName] &&
      navigation.topViewController && navigation.topViewController != destination) {
    marker = [RFArticlePushMarker new];
    marker.navigation = navigation;
    marker.destination = destination;
    marker.originalStack = navigation.viewControllers;
    objc_setAssociatedObject(destination, &kRFArticlePushMarker, marker, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    RF_ARTICLE_EVENT(@"modern-push", @"captured", navigation, nil);
  }
  %orig;
  if (!marker) return;
  void (^inspect)(void) = ^{
    dispatch_async(dispatch_get_main_queue(), ^{
      RFInspectArticlePush(marker, NSClassFromString(@"Video_FBP_Impl.FBPArticleLinkConsumptionView"));
    });
  };
  id<UIViewControllerTransitionCoordinator> coordinator = navigation.transitionCoordinator;
  if (!coordinator || ![coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
    marker.cancelled = context.isCancelled;
    inspect();
  }]) inspect();
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
  RF_ARTICLE_EVENT(@"article-route", @"entered", nil, nil);
  if (!RFOpenArticleInSafari(self, post)) %orig;
}
%end
%end

#ifdef RF_ARTICLE_TRACE
%group RFArticleTraceFeedPost
%hook RFArticleFeedRouter
- (void)navigateToUrl:(id)url forPost:(id)post outboundSourceElement:(NSUInteger)element
 analyticsReferrerInfo:(id)referrer referrerServingID:(id)servingID {
  RFArticleTrace(@"feed-post-route", @"entered", RFArticleTracePresenter(self), nil);
  %orig;
}
%end
%end

%group RFArticleTraceFeedContext
%hook RFArticleFeedRouter
- (void)navigateToUrl:(id)url forPost:(id)post context:(NSInteger)context
 outboundSourceElement:(NSUInteger)element analyticsReferrerInfo:(id)referrer referrerServingID:(id)servingID {
  RFArticleTrace(@"feed-post-context-route", @"entered", RFArticleTracePresenter(self), nil);
  %orig;
}
%end
%end

#endif

%group RFArticleWebViewStart
%hook RFArticleWebViewModel
- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
  RF_ARTICLE_EVENT(@"article-webview", @"provisional-start", nil, webView);
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
  Class navigator = NSClassFromString(@"Video_OldVideo_OldVideoLegacy.VideoPostNavigatorImpl");
  SEL route = @selector(navigateArticleLinkExperienceForPost:feedContextInfo:videoPlayerView:navigationSession:servingID:analyticsReferrerInfo:);
  Method method = class_getInstanceMethod(navigator, route);
  // Only install the hook for the object-argument ABI checked in Reddit 2026.44.
  if (method && strcmp(method_getTypeEncoding(method), "v64@0:8@16@24@32@40@48@56") == 0) {
    %init(RFArticleSafari, RFArticleNavigator = navigator);
    RF_ARTICLE_EVENT(@"article-hook", @"installed", nil, nil);
  } else {
    RF_ARTICLE_EVENT(@"article-hook", !navigator ? @"missing-class" : !method ? @"missing-method" : @"abi-mismatch", nil, nil);
  }
#ifdef RF_ARTICLE_TRACE
  Class feed = NSClassFromString(@"Actions_FeedRouter_Impl.FeedRouterImpl");
  if (RFArticleTraceHookMatches(feed, @selector(navigateToUrl:forPost:outboundSourceElement:analyticsReferrerInfo:referrerServingID:),
                                "v56@0:8@16@24Q32@40@48", @"feed-post-hook")) {
    %init(RFArticleTraceFeedPost, RFArticleFeedRouter = feed);
  }
  if (RFArticleTraceHookMatches(feed, @selector(navigateToUrl:forPost:context:outboundSourceElement:analyticsReferrerInfo:referrerServingID:),
                                "v64@0:8@16@24q32Q40@48@56", @"feed-post-context-hook")) {
    %init(RFArticleTraceFeedContext, RFArticleFeedRouter = feed);
  }
#endif
  Class navigation = NSClassFromString(@"MainTabBar.MainTabBarNavigationController");
  Method push = class_getInstanceMethod(navigation, @selector(pushViewController:animated:));
  if (push && strcmp(method_getTypeEncoding(push), "v28@0:8@16B24") == 0) {
    %init(RFArticlePush, RFArticleNavigationController = navigation);
    RF_ARTICLE_EVENT(@"modern-push-hook", @"installed", nil, nil);
  } else RF_ARTICLE_EVENT(@"modern-push-hook", @"missing-or-abi-mismatch", nil, nil);
  Class web = NSClassFromString(@"Video_FBP_Impl.FBPArticleLinkConsumptionViewModel");
  Method start = class_getInstanceMethod(web, @selector(webView:didStartProvisionalNavigation:));
  if (start && strcmp(method_getTypeEncoding(start), "v32@0:8@16@24") == 0) {
    %init(RFArticleWebViewStart, RFArticleWebViewModel = web);
    RF_ARTICLE_EVENT(@"article-webview-hook", @"installed", nil, nil);
  } else RF_ARTICLE_EVENT(@"article-webview-hook", @"missing-or-abi-mismatch", nil, nil);
  Method policy = class_getInstanceMethod(web, @selector(webView:decidePolicyForNavigationAction:decisionHandler:));
  if (policy && strcmp(method_getTypeEncoding(policy), "v40@0:8@\"WKWebView\"16@\"WKNavigationAction\"24@?<v@?q>32") == 0) {
    %init(RFArticleWebViewPolicy, RFArticleWebViewModel = web);
    RF_ARTICLE_EVENT(@"article-policy-hook", @"installed", nil, nil);
  } else RF_ARTICLE_EVENT(@"article-policy-hook", @"missing-or-abi-mismatch", nil, nil);
}
