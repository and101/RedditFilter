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

int main(void) {
  @autoreleasepool {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id saved = [defaults objectForKey:kRedditFilterSafariLinks];
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

    if (saved) [defaults setObject:saved forKey:kRedditFilterSafariLinks];
    else [defaults removeObjectForKey:kRedditFilterSafariLinks];
    puts("All article Safari tests passed.");
  }
  return 0;
}
