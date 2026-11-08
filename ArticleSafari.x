// Replace the article route before Reddit opens its player. Other web views (especially login)
// and native video routes keep their original behavior.
#import <SafariServices/SafariServices.h>
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
#import <WebKit/WebKit.h>

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

static NSURL *RFArticleURL(id post) {
  if (![post respondsToSelector:@selector(linkURL)]) return nil;
  NSURL *url = [(RFArticlePost *)post linkURL];
  if (![url isKindOfClass:NSURL.class]) return nil;
  NSString *scheme = url.scheme.lowercaseString;
  if ((![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"]) || !url.host.length)
    return nil;
  return url;
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

%group RFArticleTraceWebView
%hook RFArticleWebViewModel
- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
  RFArticleTrace(@"article-webview", @"provisional-start", nil, webView);
  %orig;
}
%end
%end
#endif

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
  Class web = NSClassFromString(@"Video_FBP_Impl.FBPArticleLinkConsumptionViewModel");
  if (RFArticleTraceHookMatches(web, @selector(webView:didStartProvisionalNavigation:),
                                "v32@0:8@16@24", @"article-webview-hook")) {
    %init(RFArticleTraceWebView, RFArticleWebViewModel = web);
  }
#endif
}
