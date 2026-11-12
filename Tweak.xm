#import <Comment.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import "ColoredComments.h"
#import "DebugMenu.h"
#import "FeedCache.h"
#import "FeedPosition.h"
#import "JSONFilter.h"
#import "LinkPanel.h"
#import "RefreshPill.h"
#import "Preferences.h"
#import "PostPageFeed.h"
#import "ScreenRestore.h"
#import "Redgifs.h"
#import "SwipeCollapse.h"

#pragma mark - Preferences

// Cached copy of the settings, read by the network hook on background threads.
static RFPrefs globalPrefs;
static os_unfair_lock globalPrefsLock = OS_UNFAIR_LOCK_INIT;

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
  prefs.extraCards = [defaults boolForKey:kRedditFilterExtraCards];
  NSArray *keywords = [defaults arrayForKey:kRedditFilterKeywords];
  RFSetFilterKeywords(keywords);
  prefs.keywords = keywords.count > 0;
  prefs.keywordComments = [defaults boolForKey:kRedditFilterKeywordComments];
  prefs.keywordCommentReplies = [defaults boolForKey:kRedditFilterKeywordCommentReplies];
  prefs.redgifsDirect = [defaults boolForKey:kRedditFilterRedgifsDirect];
  prefs.redgifsHD = [defaults boolForKey:kRedditFilterRedgifsHD];
  prefs.redgifsHDWiFiOnly = [defaults boolForKey:kRedditFilterRedgifsHDWiFiOnly];
  // Keep feed position: the kept posts were filtered with the old settings, so a change forgets them
  // (otherwise posts the new settings hide could come back). Not at launch, only when they change.
  static NSArray *lastFilters;
  NSArray *filters = @[ @(prefs.promoted), @(prefs.recommended), @(prefs.nsfw), @(prefs.videosForYou),
                        @(prefs.extraCards), keywords ?: @[] ];
  if (lastFilters && ![lastFilters isEqualToArray:filters]) RFFeedCacheForget();
  lastFilters = filters;
  // Likewise the kept comments, filtered with the old comment settings.
  static NSArray *lastCommentFilters;
  NSArray *commentFilters = @[ @(prefs.keywordComments), @(prefs.keywordCommentReplies), keywords ?: @[] ];
  if (lastCommentFilters && ![lastCommentFilters isEqualToArray:commentFilters]) RFScreenRestoreForgetComments();
  lastCommentFilters = commentFilters;
  os_unfair_lock_lock(&globalPrefsLock);
  globalPrefs = prefs;
  os_unfair_lock_unlock(&globalPrefsLock);
  RFSetDiagnosticsEnabled([defaults boolForKey:kRedditFilterDiagnostics]);
  // Start watching the network now, so the first page already knows whether it's on Wi-Fi.
  if (prefs.redgifsDirect && prefs.redgifsHD && prefs.redgifsHDWiFiOnly) RFRedgifsOnWiFi();
  RFSetColoredComments([defaults boolForKey:kRedditFilterColoredComments],
                       [defaults boolForKey:kRedditFilterColoredCommentsApollo]);
  RFSetHideLinkPanel([defaults boolForKey:kRedditFilterHideLinkPanel]);
  RFSetHideRefreshPill([defaults boolForKey:kRedditFilterRefreshPill]);
  RFSetHidePostPageFeed(prefs.recommended); // "From your feed" below a post's comments
  RFSetKeepFeedPosition([defaults boolForKey:kRedditFilterKeepFeedPosition]);
  RFSetRestoreScreens([defaults boolForKey:kRedditFilterKeepFeedPosition] &&
                      [defaults boolForKey:kRedditFilterRestoreScreens]);
  RFSetRestoreOptions([defaults boolForKey:kRedditFilterRestoreAfterSwipe], [defaults integerForKey:kRedditFilterRestoreHours]);
  RFSetSwipeCollapse([defaults boolForKey:kRedditFilterSwipeToCollapse],
                     [defaults boolForKey:kRedditFilterTapToCollapse],
                     [defaults boolForKey:kRedditFilterSwipeCollapseHaptics],
                     [defaults boolForKey:kRedditFilterSwipeLeftToCollapse],
                     [defaults boolForKey:kRedditFilterSwipeRightToCollapse]);
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

// The bundle holding Reddit's current icons. The app has so many bundles that going through them
// took about 55ms for each icon, so look here first.
static NSBundle *RFIconBundle(void) {
  static NSBundle *iconBundle;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    for (NSBundle *bundle in RFAssetBundles()) {
      if (![UIImage imageNamed:@"rpl3/filter" inBundle:bundle compatibleWithTraitCollection:nil]) continue;
      iconBundle = bundle;
      break;
    }
  });
  return iconBundle;
}

extern "C" void RFWarmIcons(void) {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ RFIconBundle(); });
}

static UIImage *RFFindIcon(NSString *iconName) {
  UIImage *found = [UIImage imageNamed:iconName inBundle:RFIconBundle() compatibleWithTraitCollection:nil];
  if (found) return found;
  for (NSBundle *bundle in RFAssetBundles()) {
    UIImage *image = [UIImage imageNamed:iconName inBundle:bundle compatibleWithTraitCollection:nil];
    if (image) return image;
  }
  // Fallback: search the private asset catalogs for a name like "icon_tag" or "icon_tag_20".
  for (CUICatalog *catalog in RFAssetCatalogs()) {
    Ivar bundleIvar = class_getInstanceVariable(object_getClass(catalog), "_bundle");
    NSBundle *bundle = bundleIvar ? object_getIvar(catalog, bundleIvar) : nil;
    if (!bundle || ![catalog respondsToSelector:@selector(allImageNames)]) continue;
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
extern "C" void RFBrowserLoginWithCredentials(NSString *username, NSString *password,
                                              void (^completion)(NSString *session));

// Reddit's answer to a password login, as if it had accepted it and set this session cookie.
static NSHTTPURLResponse *RFLoginResponse(NSURL *url, NSString *session) {
  return [[NSHTTPURLResponse alloc]
       initWithURL:url
        statusCode:200
       HTTPVersion:@"HTTP/1.1"
      headerFields:@{
        @"Content-Type" : @"application/json",
        @"Set-Cookie" : [NSString stringWithFormat:@"reddit_session=%@; Domain=.reddit.com; Path=/; Secure; HttpOnly",
                                                   session],
      }];
}

#if RF_SIDELOADED
// Login notes for testing: field names, statuses and Reddit's error codes only, never what was typed.
#if REDDITFILTER_DEBUG
#import <os/log.h>
// os_log with public text, so the notes aren't shown as <private> on a device.
#define RFLoginLog(...) os_log(OS_LOG_DEFAULT, "%{public}@", [NSString stringWithFormat:__VA_ARGS__])
#else
#define RFLoginLog(...) ((void)0)
#endif

// The username and password from the app's password login request, or NO if they aren't there.
// A streamed body is read into *request so it can still be sent if they aren't.
static BOOL RFLoginCredentials(NSURLRequest **request, NSString **username, NSString **password) {
  NSData *body = (*request).HTTPBody;
  if (!body && (*request).HTTPBodyStream) {
    NSMutableData *read = [NSMutableData data];
    NSInputStream *stream = (*request).HTTPBodyStream;
    uint8_t buffer[4096];
    NSInteger n;
    [stream open];
    while ((n = [stream read:buffer maxLength:sizeof buffer]) > 0) [read appendBytes:buffer length:n];
    BOOL complete = n == 0 && !stream.streamError;
    [stream close];
    // Only part of it could be read: send what there is rather than nothing, and leave it to Reddit.
    if (!complete) RFLoginLog(@"[RedditFilter] Couldn't read the whole password login request");
    NSMutableURLRequest *copy = [*request mutableCopy];
    copy.HTTPBodyStream = nil;
    copy.HTTPBody = read;
    *request = copy;
    if (!complete) return NO;
    body = read;
  }
  if (!body.length) return NO;
  NSDictionary *fields = nil;
  id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
  if ([json isKindOfClass:NSDictionary.class]) {
    fields = json;
  } else {
    NSURLComponents *form = [NSURLComponents new];
    // In a form body, + stands for a space.
    form.percentEncodedQuery = [[[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding]
        stringByReplacingOccurrencesOfString:@"+"
                                  withString:@"%20"];
    NSMutableDictionary *parsed = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in form.queryItems)
      if (item.value) parsed[item.name] = item.value;
    fields = parsed;
  }
  id user = nil;
  for (NSString *key in @[ @"username", @"identifier", @"email", @"login" ])
    if ((user = fields[key])) break;
  id pass = fields[@"password"];
  if (![user isKindOfClass:NSString.class] || ![pass isKindOfClass:NSString.class] || ![user length] ||
      ![pass length]) {
    // Field names only, never their values.
    RFLoginLog(@"[RedditFilter] Password login request without a username and password: %@", fields.allKeys);
    return NO;
  }
  *username = user;
  *password = pass;
  return YES;
}

// Whether logging in through reddit.com could get past Reddit refusing the app's password login.
// Not when it's about the username or password themselves, or too many tries: reddit.com would only
// say the same, so the app shows Reddit's answer. When unsure, try the browser.
// A wrong username or password gets 401 {"error":{"message":"unauthorized"}}; a refused attestation
// gets the same plus "params":{"recaptcha_token":"INVALID"}, so check for captcha first.
static BOOL RFBrowserCanHelpWithLogin(NSInteger status, NSData *data) {
  if (status == 429) return NO;
  NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].lowercaseString : nil;
  if (!text.length) return YES;
  for (NSString *word in @[ @"captcha", @"attest", @"integrity" ])
    if ([text containsString:word]) return YES;
  for (NSString *word in @[ @"unauthorized", @"password", @"identifier", @"username", @"credential", @"otp" ])
    if ([text containsString:word]) return NO;
  return YES;
}
#endif

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
      NSHTTPURLResponse *response = RFLoginResponse(request.URL, webSession);
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

#if RF_SIDELOADED
  // Sideloaded, Reddit may reject the app's own password login. Send it as usual, and if Reddit turns
  // it down, log in with the same username and password in the browser sheet (LoginHelper.x) and
  // answer the app with that session instead.
  if (!webSession && completionHandler && [request.URL.path isEqualToString:@"/auth/v2/login/password"] &&
      ([host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"])) {
    NSString *username, *password;
    if (!RFLoginCredentials(&request, &username, &password)) return %orig(request, completionHandler);
    NSURL *url = request.URL;
    NSOperationQueue *queue = self.delegateQueue;
    return %orig(request, ^(NSData *data, NSURLResponse *response, NSError *error) {
      NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
      // Logged in, or the connection failed and the browser wouldn't do any better.
      if (error || status < 400 || status >= 500) {
        RFLoginLog(@"[RedditFilter] Password login: %ld", (long)status);
        return completionHandler(data, response, error);
      }
#if REDDITFILTER_DEBUG
      id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
      id reason = [json isKindOfClass:NSDictionary.class] ? json[@"error"] : nil; // for the login notes
#endif
      // A wrong password, for one: the app shows Reddit's own message.
      if (!RFBrowserCanHelpWithLogin(status, data)) {
        RFLoginLog(@"[RedditFilter] Password login refused (%ld): %@", (long)status, reason);
        return completionHandler(data, response, error);
      }
      RFLoginLog(@"[RedditFilter] Password login refused (%ld): %@; trying the browser", (long)status, reason);
      RFBrowserLoginWithCredentials(username, password, ^(NSString *session) {
        void (^answer)(void) = ^{
          if (session)
            completionHandler([@"{}" dataUsingEncoding:NSUTF8StringEncoding], RFLoginResponse(url, session), nil);
          else
            completionHandler(data, response, error); // closed: show Reddit's own answer
        };
        if (queue) [queue addOperationWithBlock:answer];
        else answer();
      });
    });
  }
#endif

  // Debug builds: note GraphQL requests that would skip the filter, e.g. to a new Reddit address.
  if (!RFIsAPIHost(host) || !completionHandler) RF_RECORD_UNFILTERED(request, completionHandler != nil);

  // One copy of the settings for this request, so a switch flipped halfway through doesn't mix them.
  os_unfair_lock_lock(&globalPrefsLock);
  RFPrefs prefs = globalPrefs;
  os_unfair_lock_unlock(&globalPrefsLock);
  NSString *operation = completionHandler && RFIsAPIHost(host) ? RFOperationName(request) : nil;
  // Keep feed position: every request's login token says whether Reddit's in incognito.
  if (operation && RFFeedCacheEnabled()) RFFeedCacheNoteRequest(operation, request);


  // Keep feed position: the pages of Home's feeds are kept, and each feed's first page after iOS closed
  // the app starts where you were (FeedCache.m). Wraps the app's handler, so it sees each page as it's
  // finally handed over (filtered, so kept posts aren't filtered or counted twice).
  if (RFFeedCacheEnabled() && RFFeedCacheKeepsOperation(operation)) {
    void (^appHandler)(NSData *, NSURLResponse *, NSError *) = completionHandler;
    unsigned generation = RFFeedCacheGeneration(); // as it's asked for, with these filters and this account
    completionHandler = ^(NSData *data, NSURLResponse *response, NSError *error) {
      if (RFIsOK(response, error)) data = RFFeedCachePageFrom(operation, request, data, generation) ?: data;
      appHandler(data, response, error);
    };
  }
  // Restore open community and post: the comments of each post opened, to note where you were in them.
  BOOL restoreWatches = RFScreenRestoreWantsComments();
  if (restoreWatches && [operation isEqualToString:@"PostInfoByIdComments"]) {
    void (^appHandler)(NSData *, NSURLResponse *, NSError *) = completionHandler;
    completionHandler = ^(NSData *data, NSURLResponse *response, NSError *error) {
      if (RFIsOK(response, error)) RFScreenRestoreCommentsPage(request, data);
      appHandler(data, response, error);
    };
  }
  // and each custom feed's request, to name the custom feed screen it's for,
  if (restoreWatches && ([operation isEqualToString:@"FetchMulti"] || [operation isEqualToString:@"MultiredditPostsSdui"]))
    RFScreenRestoreCustomFeedRequest(request);
  // and each search's results, to name a post opened from them in the full-screen viewer (only needed
  // when leaving, so read after the app has them).
  if (restoreWatches && [operation isEqualToString:@"SearchDynamic"]) {
    void (^appHandler)(NSData *, NSURLResponse *, NSError *) = completionHandler;
    unsigned searchGeneration = RFScreenRestoreSearchGeneration();
    unsigned long long searchOrder = RFScreenRestoreNextSearchOrder();
    completionHandler = ^(NSData *data, NSURLResponse *response, NSError *error) {
      appHandler(data, response, error);
      if (RFIsOK(response, error))
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
          RFScreenRestoreSearchPage(request, data, searchGeneration, searchOrder);
        });
    };
  }

  if (!completionHandler || !RFPrefsAnyEnabled(prefs) || !RFIsAPIHost(host)) return %orig(request, completionHandler);

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
        // Handed over on NSURLSession's delegate operation queue, whichever step finished last.
        NSOperationQueue *queue = session.delegateQueue;
        void (^deliver)(NSData *) = ^(NSData *page) {
          @synchronized(lock) {
            if (delivered) return;
            delivered = YES;
          }
          void (^hand)(void) = ^{
            completionHandler(page, response, nil);
          };
          if (queue) [queue addOperationWithBlock:hand];
          else hand();
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
        BOOL hd = prefs.redgifsHD && (!prefs.redgifsHDWiFiOnly || RFRedgifsOnWiFi());
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
          RFFetchRedgifsVideos(redgifs, hd, ^(NSDictionary *found) {
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
            updated = latest;
          }
          topUpAndFinish(updated);
        });
      };
  return %orig(request, filteringHandler);
}
%end

#pragma mark - Cached experiments

// Reddit keeps each account's experiments in <group container>/Library/Application Support/<account>/
// ExperimentVariants and applies them at launch, before it fetches fresh ones. Cleaned here so the
// ad-leaking experiments are gone from the first launch, not just the one after. Returns YES if any
// were removed (an app that has already read them keeps using them until it's reopened).
BOOL RFCleanCachedExperiments(void) {
  BOOL removed = NO;
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *group = @"group.com.reddit.Reddit";
  NSMutableOrderedSet<NSString *> *containers = [NSMutableOrderedSet orderedSet];
  NSString *shared = [fm containerURLForSecurityApplicationGroupIdentifier:group].path;
  if (shared) [containers addObject:shared];
  // Sideloaded: RedditSideloadFix moves the group container here, and may load after this tweak.
  [containers addObject:[NSHomeDirectory() stringByAppendingPathComponent:
                                               [@"Documents/FakeGroupContainers" stringByAppendingPathComponent:group]]];
  for (NSString *container in containers) {
    NSString *support = [container stringByAppendingPathComponent:@"Library/Application Support"];
    for (NSString *account in [fm contentsOfDirectoryAtPath:support error:nil]) {
      NSString *path = [[support stringByAppendingPathComponent:account] stringByAppendingPathComponent:@"ExperimentVariants"];
      NSData *cleaned = RFCachedExperimentsWithoutAdLeaks([NSData dataWithContentsOfFile:path]);
      if (cleaned && [cleaned writeToFile:path options:NSDataWritingAtomic error:nil]) removed = YES;
    }
  }
  return removed;
}

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


%end

%ctor {
  [NSUserDefaults.standardUserDefaults registerDefaults:@{
    kRedditFilterPromoted : @YES,
    kRedditFilterRecommended : @NO,
    kRedditFilterNSFW : @NO,
    kRedditFilterAwards : @NO,
    kRedditFilterScores : @NO,
    kRedditFilterAutoCollapseAutoMod : @NO,
    kRedditFilterSwipeToCollapse : @NO,
    kRedditFilterSwipeCollapseHaptics : @YES,
    kRedditFilterTapToCollapse : @NO,
    kRedditFilterSwipeLeftToCollapse : @YES,
    kRedditFilterSwipeRightToCollapse : @NO,
    kRedditFilterVideosForYou : @NO,
    kRedditFilterExtraCards : @NO,
    kRedditFilterRefreshPill : @NO,
    kRedditFilterKeywordComments : @NO,
    kRedditFilterKeywordCommentReplies : @YES,
    kRedditFilterRedgifsDirect : @NO,
    kRedditFilterRedgifsHD : @NO,
    kRedditFilterRedgifsHDWiFiOnly : @YES,
    kRedditFilterColoredComments : @NO,
    kRedditFilterColoredCommentsApollo : @NO,
    kRedditFilterHideLinkPanel : @NO,
    kRedditFilterKeepFeedPosition : @NO,
    kRedditFilterRestoreScreens : @NO,
    kRedditFilterRestoreAfterSwipe : @NO,
    kRedditFilterRestoreHours : @12,
    kRedditFilterSafariLinks : @NO,
    kRedditFilterCheckUpdates : @YES,
  }];
  RFReloadPreferences();
  if (globalPrefs.promoted) RFCleanCachedExperiments();

  %init;
  %init(SwiftClasses, Post = CoreClass(@"Post"), Comment = CoreClass(@"Comment"));
}
