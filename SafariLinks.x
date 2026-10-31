#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// Opens links from the RedditFilter Safari extension. The extension turns a Reddit page like
// https://www.reddit.com/r/pics into redditfilter://www.reddit.com/r/pics. Here it becomes the
// https link again and goes to the app as a universal link, the way iOS hands over Reddit links
// for the App Store version, so the app's own link handling opens the right screen.

static NSString *const kScheme = @"redditfilter";

// The https link for a redditfilter:// link, or nil if it isn't one for a Reddit page.
static NSURL *webURLForAppURL(NSURL *url) {
  if (![url.scheme.lowercaseString isEqualToString:kScheme]) return nil;
  NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
  NSString *host = components.host.lowercaseString;
  if (![host isEqualToString:@"reddit.com"] && ![host hasSuffix:@".reddit.com"]) return nil;
  components.scheme = @"https";
  return components.URL;
}

static NSUserActivity *activityForWebURL(NSURL *webURL) {
  NSUserActivity *activity = [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
  activity.webpageURL = webURL;
  return activity;
}

// Opening while the app is running.
%group Scene
%hook SceneDelegate
- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
  NSMutableSet *others = [NSMutableSet set];
  for (UIOpenURLContext *context in URLContexts) {
    NSURL *webURL = webURLForAppURL(context.URL);
    if (webURL && [self respondsToSelector:@selector(scene:continueUserActivity:)])
      [(id<UISceneDelegate>)self scene:scene continueUserActivity:activityForWebURL(webURL)];
    else if (!webURL)
      [others addObject:context];
  }
  if (others.count) %orig(scene, others);
}
%end
%end

// Opening when the app isn't running: the link comes with the scene's connection options, so
// the app sees it as a universal link instead.
static const void *kActivitiesKey = &kActivitiesKey;
static BOOL showAllURLContexts; // main thread only

%hook UISceneConnectionOptions
- (NSSet<UIOpenURLContext *> *)URLContexts {
  NSSet *contexts = %orig;
  if (showAllURLContexts) return contexts;
  return [contexts objectsPassingTest:^BOOL(UIOpenURLContext *context, BOOL *stop) {
    return webURLForAppURL(context.URL) == nil;
  }];
}

- (NSSet<NSUserActivity *> *)userActivities {
  NSSet *activities = %orig;
  NSSet *extra = objc_getAssociatedObject(self, kActivitiesKey);
  if (!extra) {
    NSMutableSet *made = [NSMutableSet set];
    showAllURLContexts = YES;
    NSSet *contexts = self.URLContexts;
    showAllURLContexts = NO;
    for (UIOpenURLContext *context in contexts) {
      NSURL *webURL = webURLForAppURL(context.URL);
      if (webURL) [made addObject:activityForWebURL(webURL)];
    }
    extra = made;
    objc_setAssociatedObject(self, kActivitiesKey, extra, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  if (!extra.count) return activities;
  return activities.count ? [activities setByAddingObjectsFromSet:extra] : extra;
}
%end

%ctor {
  %init;
  Class sceneDelegate = objc_getClass("_TtC6Reddit13SceneDelegate"); // Reddit.SceneDelegate
  if (sceneDelegate) %init(Scene, SceneDelegate = sceneDelegate);
}
