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
  if (![NSThread isMainThread] ||
      ![NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterSafariLinks]) return NO;
  NSURL *url = RFArticleURL(post);
  if (!url || ![navigator respondsToSelector:@selector(vc)]) return NO;
  UIViewController *presenter = [(RFArticleNavigator *)navigator vc];
  if (![presenter isKindOfClass:UIViewController.class]) return NO;
  UIWindow *window = presenter.viewIfLoaded.window;
  if (!window || window.hidden || presenter.presentedViewController || presenter.isBeingPresented ||
      presenter.isBeingDismissed || presenter.transitionCoordinator) return NO;
  if (window.windowScene && window.windowScene.activationState != UISceneActivationStateForegroundActive)
    return NO;

  SFSafariViewController *safari = [[SFSafariViewController alloc] initWithURL:url];
  [presenter presentViewController:safari animated:YES completion:nil];
  return safari.presentingViewController != nil || presenter.presentedViewController == safari;
}

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

%ctor {
  Class navigator = NSClassFromString(@"Video_OldVideo_OldVideoLegacy.VideoPostNavigatorImpl");
  SEL route = @selector(navigateArticleLinkExperienceForPost:feedContextInfo:videoPlayerView:navigationSession:servingID:analyticsReferrerInfo:);
  Method method = class_getInstanceMethod(navigator, route);
  // Only install the hook for the object-argument ABI checked in Reddit 2026.44.
  if (method && strcmp(method_getTypeEncoding(method), "v64@0:8@16@24@32@40@48@56") == 0)
    %init(RFArticleSafari, RFArticleNavigator = navigator);
}
