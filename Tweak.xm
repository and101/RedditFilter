#import <Comment.h>
#import <ToggleImageTableViewCell.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "JSONFilter.h"
#import "Preferences.h"
#import "Redgifs.h"

#pragma mark - Preferences

// Cached copy of the settings, read by the network hook on background threads.
static RFPrefs globalPrefs;

extern "C" void RFReloadPreferences(void) {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  RFPrefs prefs;
  prefs.promoted = [defaults boolForKey:kRedditFilterPromoted];
  prefs.recommended = [defaults boolForKey:kRedditFilterRecommended];
  prefs.nsfw = [defaults boolForKey:kRedditFilterNSFW];
  prefs.awards = [defaults boolForKey:kRedditFilterAwards];
  prefs.scores = [defaults boolForKey:kRedditFilterScores];
  prefs.automod = [defaults boolForKey:kRedditFilterAutoCollapseAutoMod];
  prefs.videosForYou = [defaults boolForKey:kRedditFilterVideosForYou];
  NSArray *keywords = [defaults arrayForKey:kRedditFilterKeywords];
  RFSetFilterKeywords(keywords);
  prefs.keywords = keywords.count > 0;
  prefs.keywordComments = [defaults boolForKey:kRedditFilterKeywordComments];
  prefs.keywordCommentReplies = [defaults boolForKey:kRedditFilterKeywordCommentReplies];
  prefs.redgifsDirect = [defaults boolForKey:kRedditFilterRedgifsDirect];
  globalPrefs = prefs;
}

#pragma mark - Helpers shared with the settings screen

extern "C" Class CoreClass(NSString *name) {
  Class cls = NSClassFromString(name);
  for (NSString *prefix in @[ @"Reddit.", @"RedditCore.", @"RedditCoreModels.", @"RedditCore_RedditCoreModels.",
                              @"RedditUI.", @"Palette_RedditPalette." ]) {
    if (cls) break;
    cls = NSClassFromString([prefix stringByAppendingString:name]);
  }
  return cls;
}

@interface CUICatalog : NSObject
- (NSArray<NSString *> *)allImageNames;
- (instancetype)initWithName:(NSString *)name fromBundle:(NSBundle *)bundle error:(NSError **)error;
@end

// Every bundle in the app that can hold icons. Built the first time an icon is
// needed (when the settings screen opens) instead of on every app launch.
static NSArray<NSBundle *> *RFAssetBundles(void) {
  static NSArray *bundles;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableArray *found = [NSMutableArray arrayWithObject:NSBundle.mainBundle];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *appPath = NSBundle.mainBundle.bundlePath;
    NSString *frameworksPath = [appPath stringByAppendingPathComponent:@"Frameworks"];
    NSMutableArray *dirs = [NSMutableArray arrayWithObject:appPath];
    for (NSString *file in [fm contentsOfDirectoryAtPath:frameworksPath error:nil])
      if ([file hasSuffix:@".framework"]) [dirs addObject:[frameworksPath stringByAppendingPathComponent:file]];
    for (NSString *dir in dirs) {
      if (dir != appPath) {
        NSBundle *framework = [NSBundle bundleWithPath:dir];
        if (framework) [found addObject:framework];
      }
      for (NSString *file in [fm contentsOfDirectoryAtPath:dir error:nil]) {
        if (![file hasSuffix:@".bundle"]) continue;
        NSBundle *bundle = [NSBundle bundleWithPath:[dir stringByAppendingPathComponent:file]];
        if (bundle) [found addObject:bundle];
      }
    }
    bundles = found;
  });
  return bundles;
}

static NSArray<CUICatalog *> *RFAssetCatalogs(void) {
  static NSArray *catalogs;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableArray *found = [NSMutableArray array];
    Class catalogClass = objc_getClass("CUICatalog");
    for (NSBundle *bundle in RFAssetBundles()) {
      NSError *error = nil;
      CUICatalog *catalog = [[catalogClass alloc] initWithName:@"Assets" fromBundle:bundle error:&error];
      if (catalog && !error) [found addObject:catalog];
    }
    catalogs = found;
  });
  return catalogs;
}

static UIImage *RFFindIcon(NSString *iconName) {
  for (NSBundle *bundle in RFAssetBundles()) {
    UIImage *image = [UIImage imageNamed:iconName inBundle:bundle compatibleWithTraitCollection:nil];
    if (image) return image;
  }
  // Fallback: search the private asset catalogs for a name like "icon_tag" or "icon_tag_20".
  for (CUICatalog *catalog in RFAssetCatalogs()) {
    Ivar bundleIvar = class_getInstanceVariable(object_getClass(catalog), "_bundle");
    NSBundle *bundle = bundleIvar ? object_getIvar(catalog, bundleIvar) : nil;
    if (!bundle) continue;
    for (NSString *imageName in [catalog allImageNames]) {
      if (![imageName hasPrefix:iconName] ||
          (imageName.length != iconName.length && imageName.length != iconName.length + 3))
        continue;
      UIImage *image = [UIImage imageNamed:imageName inBundle:bundle compatibleWithTraitCollection:nil];
      if (image) return image;
    }
  }
  return nil;
}

extern "C" UIImage *iconWithName(NSString *iconName) {
  if (!iconName) return nil;
  static NSCache *cache;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ cache = [NSCache new]; });
  id cached = [cache objectForKey:iconName];
  if (cached) return cached == NSNull.null ? nil : cached;
  UIImage *image = RFFindIcon(iconName);
  [cache setObject:(image ?: NSNull.null) forKey:iconName]; // remember misses too
  return image;
}

#pragma mark - Network filtering

// Marks the requests RedditFilter makes itself. Kept on the device, never sent.
static NSString *const kRFOwnRequest = @"RedditFilterOwnRequest";

static NSURLRequest *RFOwnRequest(NSURLRequest *request) {
  NSMutableURLRequest *own = [request mutableCopy];
  [NSURLProtocol setProperty:@YES forKey:kRFOwnRequest inRequest:own];
  return own;
}

static BOOL RFIsOK(NSURLResponse *response, NSError *error) {
  return !error && [response isKindOfClass:NSHTTPURLResponse.class] &&
         ((NSHTTPURLResponse *)response).statusCode == 200;
}

// How long a page waits for RedditFilter's extra steps (RedGIFs videos, full post text, the next
// page) before it's shown without the ones that haven't finished.
static const double kRFExtraStepsDeadline = 5.0;

extern "C" NSString *RFPendingWebSession(void);
extern "C" void RFClearPendingWebSession(void);

// Reddit's API hosts: gql-fed, oauth, and cf.gql-fed, the Cloudflare route that the ios_graphql_uri_v2
// experiment moves some users onto.
static BOOL RFIsAPIHost(NSString *host) {
  if (![host hasSuffix:@".reddit.com"]) return NO;
  for (NSString *label in [[host substringToIndex:host.length - 11] componentsSeparatedByString:@"."])
    if ([label hasPrefix:@"gql"] || [label hasPrefix:@"oauth"]) return YES;
  return NO;
}

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *data, NSURLResponse *response,
                                                        NSError *error))completionHandler {
  NSString *host = request.URL.host;

  // Browser login (LoginHelper.x): answer the app's password login with the session from the
  // browser instead of sending it to Reddit, then let the app exchange it for its token as usual.
  NSString *webSession = RFPendingWebSession();
  if (webSession && completionHandler && ([host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"])) {
    if ([request.URL.path isEqualToString:@"/auth/v2/login/password"]) {
      NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
           initWithURL:request.URL
            statusCode:200
           HTTPVersion:@"HTTP/1.1"
          headerFields:@{
            @"Content-Type" : @"application/json",
            @"Set-Cookie" : [NSString
                stringWithFormat:@"reddit_session=%@; Domain=.reddit.com; Path=/; Secure; HttpOnly",
                                 webSession],
          }];
      return %orig([NSURLRequest requestWithURL:[NSURL URLWithString:@"data:application/json,%7B%7D"]],
                   ^(NSData *data, NSURLResponse *_, NSError *error) {
                     completionHandler([@"{}" dataUsingEncoding:NSUTF8StringEncoding], response, nil);
                   });
    }
    if ([request.URL.path isEqualToString:@"/auth/v2/oauth/access-token/session"])
      return %orig(request, ^(NSData *data, NSURLResponse *response, NSError *error) {
        if ([response isKindOfClass:NSHTTPURLResponse.class] &&
            ((NSHTTPURLResponse *)response).statusCode == 200)
          RFClearPendingWebSession();
        completionHandler(data, response, error);
      });
  }

  // One copy of the settings for this request, so a switch flipped halfway through doesn't mix them.
  RFPrefs prefs = globalPrefs;
  if (!completionHandler || !RFPrefsAnyEnabled(prefs) || !RFIsAPIHost(host)) return %orig;

  NSString *operation = RFOperationName(request);
  if ([operation isEqualToString:@"FeedPostDetailsByIds"]) RFRememberPostDetailsRequest(request);

  NSURLSession *session = self;
  void (^filteringHandler)(NSData *, NSURLResponse *, NSError *) =
      ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && data.length) {
          NSData *filtered = RFFilteredResponseData(data, operation, prefs);
          if (filtered) data = filtered;
        }
        if (error) return completionHandler(data, response, error);

        // The extra steps below are optional, so the page never waits long for them: once the
        // deadline passes it's shown as far as it got, and whatever finishes later is dropped.
        NSObject *lock = [NSObject new];
        __block NSData *latest = data; // the page as far as it's got
        __block BOOL delivered = NO, deadlineSet = NO;
        void (^deliver)(NSData *) = ^(NSData *page) {
          @synchronized(lock) {
            if (delivered) return;
            delivered = YES;
          }
          completionHandler(page, response, nil);
        };
        void (^progress)(NSData *) = ^(NSData *page) {
          @synchronized(lock) {
            latest = page;
            if (deadlineSet) return;
            deadlineSet = YES;
          }
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRFExtraStepsDeadline * NSEC_PER_SEC)),
                         dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                           NSData *page;
                           @synchronized(lock) {
                             page = latest;
                           }
                           deliver(page);
                         });
        };

        // A first Home page that's mostly hidden posts can be too short to scroll, and the app only
        // loads more when you scroll. Fetch the next page now and hand both over together.
        void (^topUpAndFinish)(NSData *) = ^(NSData *firstPage) {
          NSURLRequest *topUp = RFFeedTopUpRequest(request, firstPage);
          if (!topUp) return deliver(firstPage);
          progress(firstPage);
          // Goes through this hook too, so the extra page is filtered as well.
          [[session dataTaskWithRequest:topUp
                      completionHandler:^(NSData *nextData, NSURLResponse *nextResponse, NSError *nextError) {
                        NSData *merged = RFIsOK(nextResponse, nextError) ? RFMergedFeedPages(firstPage, nextData) : nil;
                        deliver(merged ?: firstPage);
                      }] resume];
        };

        // Feed cards only have the start of each post, so fetch the full posts and check those too
        // before the page is shown. Reddit's copies of RedGIFs videos have no sound, so swap in
        // RedGIFs' own files (skipped for RedditFilter's own full-text checks, which never play
        // anything). The two are fetched side by side, so slow RedGIFs lookups can't use up the
        // keyword check's time, then applied to the page together.
        NSURLRequest *details = RFPostDetailsRequest(request, data, prefs);
        NSArray *redgifs = prefs.redgifsDirect && ![NSURLProtocol propertyForKey:kRFOwnRequest inRequest:request]
                               ? RFRedgifsIds(data)
                               : nil;
        if (!details && !redgifs) return topUpAndFinish(data);
        NSData *page = data;
        __block NSData *detailsData = nil;
        __block NSDictionary *videoURLs = nil;
        // The page with whatever has come back so far. Call with lock held (it's reentrant, so
        // progress can be called under it too, which keeps the latest page from going backwards).
        NSData *(^pageSoFar)(void) = ^NSData *{
          NSData *result = page;
          if (detailsData) result = RFFeedHidingFullTextMatches(result, detailsData, prefs) ?: result;
          if (videoURLs.count) result = RFRedgifsResponse(result, videoURLs) ?: result;
          return result;
        };
        dispatch_group_t group = dispatch_group_create();
        progress(page);
        if (details) {
          dispatch_group_enter(group);
          [[session dataTaskWithRequest:RFOwnRequest(details)
                      completionHandler:^(NSData *fetched, NSURLResponse *detailsResponse, NSError *detailsError) {
                        @synchronized(lock) {
                          if (RFIsOK(detailsResponse, detailsError)) detailsData = fetched;
                          progress(pageSoFar());
                        }
                        dispatch_group_leave(group);
                      }] resume];
        }
        if (redgifs) {
          dispatch_group_enter(group);
          RFFetchRedgifsVideos(redgifs, ^(NSDictionary *found) {
            @synchronized(lock) {
              videoURLs = found;
              progress(pageSoFar());
            }
            dispatch_group_leave(group);
          });
        }
        dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
          NSData *updated;
          @synchronized(lock) {
            updated = pageSoFar();
          }
          topUpAndFinish(updated);
        });
      };
  return %orig(request, filteringHandler);
}
%end

#pragma mark - Swift model and UI hooks

%group SwiftClasses

%hook Post
- (NSArray *)awardingTotals {
  return globalPrefs.awards ? nil : %orig;
}
- (NSUInteger)totalAwardsReceived {
  return globalPrefs.awards ? 0 : %orig;
}
- (BOOL)canAward {
  return globalPrefs.awards ? NO : %orig;
}
- (BOOL)isScoreHidden {
  return globalPrefs.scores ? YES : %orig;
}
%end

%hook Comment
- (NSArray *)awardingTotals {
  return globalPrefs.awards ? nil : %orig;
}
- (NSUInteger)totalAwardsReceived {
  return globalPrefs.awards ? 0 : %orig;
}
- (BOOL)canAward {
  return globalPrefs.awards ? NO : %orig;
}
- (BOOL)isScoreHidden {
  return globalPrefs.scores ? YES : %orig;
}
- (BOOL)shouldAutoCollapse {
  return (globalPrefs.automod && [((Comment *)self).authorPk isEqualToString:@"t2_6l4z3"]) ? YES : %orig;
}
%end

// Lays out the subtitle on RedditFilter's own toggle rows. Reddit's toggle
// cells elsewhere in the app are left alone (they aren't tagged).
%hook ToggleImageTableViewCell
- (void)updateConstraints {
  %orig;
  if (!objc_getAssociatedObject(self, @selector(rfOwnedCell))) return;

  NSArray<NSLayoutConstraint *> *constraints = objc_getAssociatedObject(self, @selector(rfSubtitleConstraints));
  UILabel *detailLabel = [self respondsToSelector:@selector(imageLabelView)] ? [self imageLabelView].detailLabel
                                                                              : [self detailLabel];
  if (!constraints) {
    Ivar stackIvar = class_getInstanceVariable(object_getClass(self), "horizontalStackView");
    UIStackView *stack = [self respondsToSelector:@selector(imageLabelView)]
                             ? [self imageLabelView].horizontalStackView
                             : (stackIvar ? object_getIvar(self, stackIvar) : nil);
    if (!stack || !detailLabel) return;
    UIView *contentView = [self contentView];
    constraints = @[
      [detailLabel.heightAnchor constraintEqualToAnchor:stack.heightAnchor multiplier:0.33],
      [stack.heightAnchor constraintEqualToAnchor:contentView.heightAnchor],
      [stack.centerYAnchor constraintEqualToAnchor:contentView.centerYAnchor],
    ];
    objc_setAssociatedObject(self, @selector(rfSubtitleConstraints), constraints,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  // Rows get reused, so switch the constraints on/off to match this row.
  BOOL hasSubtitle = detailLabel.text.length > 0;
  if (hasSubtitle) [NSLayoutConstraint activateConstraints:constraints];
  else [NSLayoutConstraint deactivateConstraints:constraints];
}
%end

%end

%ctor {
  [NSUserDefaults.standardUserDefaults registerDefaults:@{
    kRedditFilterPromoted : @YES,
    kRedditFilterRecommended : @NO,
    kRedditFilterNSFW : @NO,
    kRedditFilterAwards : @NO,
    kRedditFilterScores : @NO,
    kRedditFilterAutoCollapseAutoMod : @NO,
    kRedditFilterVideosForYou : @NO,
    kRedditFilterKeywordComments : @NO,
    kRedditFilterKeywordCommentReplies : @YES,
    kRedditFilterRedgifsDirect : @NO,
  }];
  RFReloadPreferences();

  %init;
  %init(SwiftClasses, Post = CoreClass(@"Post"), Comment = CoreClass(@"Comment"),
        ToggleImageTableViewCell = CoreClass(@"ToggleImageTableViewCell"));
}
