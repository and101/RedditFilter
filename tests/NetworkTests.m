// Run in the iOS Simulator: ./tests/run-sim.sh
//
// Drives the real NSURLSession hook from Tweak.xm against stubbed Reddit responses, to check that a
// feed page is handed to the app once, and never held back long by RedditFilter's extra requests.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "DebugMenu.h"
#import "Preferences.h"
#import "Redgifs.h"
#import "UpdateChecker.h"

// Browser login lives in LoginHelper.x, which isn't part of this test.
NSString *RFPendingWebSession(void) { return nil; }
void RFClearPendingWebSession(void) {}

// The browser sheet for the app's own login (sideloaded builds): counts how often it's asked and
// answers with gBrowserSession, as the sheet does, on the main queue.
static NSUInteger gBrowserLogins;
static NSString *gBrowserUsername, *gBrowserPassword, *gBrowserSession;
void RFBrowserLoginWithCredentials(NSString *username, NSString *password, void (^completion)(NSString *session)) {
  gBrowserLogins++;
  gBrowserUsername = username;
  gBrowserPassword = password;
  NSString *session = gBrowserSession;
  dispatch_async(dispatch_get_main_queue(), ^{
    completion(session);
  });
}
void RFSetColoredComments(BOOL enabled, BOOL apolloStyle) {}
void RFSetSwipeCollapse(BOOL enabled, BOOL tapToo, BOOL haptics) {}

static void Check(BOOL condition, NSString *message) {
  if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}

#pragma mark - Stubbed server

// operation, request body, URL -> @[status, delay in seconds, JSON]
static NSArray *(^gRoute)(NSString *operation, NSDictionary *body, NSURL *url);

@interface RFStubProtocol : NSURLProtocol
@end

@implementation RFStubProtocol {
  BOOL _stopped;
}
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
  NSData *bodyData = self.request.HTTPBody;
  NSInputStream *stream = self.request.HTTPBodyStream;
  if (!bodyData && stream) {
    NSMutableData *read = [NSMutableData data];
    uint8_t buffer[4096];
    [stream open];
    for (NSInteger n; (n = [stream read:buffer maxLength:sizeof buffer]) > 0;) [read appendBytes:buffer length:n];
    [stream close];
    bodyData = read;
  }
  NSDictionary *body = bodyData.length ? [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:NULL] : nil;
  NSArray *reply = gRoute([self.request valueForHTTPHeaderField:@"X-APOLLO-OPERATION-NAME"], body, self.request.URL);
  NSData *data = [NSJSONSerialization dataWithJSONObject:reply[2] options:0 error:NULL];
  NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                            statusCode:[reply[0] integerValue]
                                                           HTTPVersion:@"HTTP/1.1"
                                                          headerFields:@{@"Content-Type" : @"application/json"}];
  // The client expects to hear back on the thread that started loading.
  CFRunLoopRef loop = CFRunLoopGetCurrent();
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([reply[1] doubleValue] * NSEC_PER_SEC)),
                 dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                   CFRunLoopPerformBlock(loop, kCFRunLoopCommonModes, ^{
                     if (self->_stopped) return;
                     [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
                     [self.client URLProtocol:self didLoadData:data];
                     [self.client URLProtocolDidFinishLoading:self];
                   });
                   CFRunLoopWakeUp(loop);
                 });
}
- (void)stopLoading {
  _stopped = YES;
}
@end

// RedGIFs has a session of its own, which doesn't ask registered protocols, so give every new
// ephemeral configuration the stub too.
@implementation NSURLSessionConfiguration (RFStub)
+ (NSURLSessionConfiguration *)rf_ephemeralSessionConfiguration {
  NSURLSessionConfiguration *config = [self rf_ephemeralSessionConfiguration]; // the original
  config.protocolClasses = [@[ RFStubProtocol.class ] arrayByAddingObjectsFromArray:config.protocolClasses];
  return config;
}
+ (void)load {
  method_exchangeImplementations(class_getClassMethod(self, @selector(ephemeralSessionConfiguration)),
                                 class_getClassMethod(self, @selector(rf_ephemeralSessionConfiguration)));
}
@end

#pragma mark - Fixtures

static NSString *CardId(NSString *postId) {
  return [[postId dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
}

// A Home page with these posts, and a next page after it when cursor is set.
static NSDictionary *Page(NSArray<NSString *> *postIds, NSString *cursor) {
  NSMutableArray *edges = [NSMutableArray array];
  for (NSString *postId in postIds)
    [edges addObject:@{@"node" : @{@"__typename" : @"CellGroup", @"id" : CardId(postId),
                                   @"cells" : @[ @{@"__typename" : @"TitleCell", @"title" : @"Car advice"} ]}}];
  NSDictionary *pageInfo = @{@"endCursor" : cursor ?: NSNull.null, @"hasNextPage" : @(cursor != nil)};
  return @{@"data" : @{@"homeV3" : @{@"elements" : @{@"edges" : edges, @"pageInfo" : pageInfo}}}};
}

static NSDictionary *Details(NSString *postId, NSString *text) {
  return @{@"data" : @{@"postsInfoByIds" : @[ @{@"id" : postId, @"content" : @{@"markdown" : text}} ]}};
}

static NSArray *Edges(NSDictionary *json) { return json[@"data"][@"homeV3"][@"elements"][@"edges"]; }

static void SetPrefs(NSArray *keywords, BOOL redgifs) {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  [defaults setBool:YES forKey:kRedditFilterPromoted];
  [defaults setBool:redgifs forKey:kRedditFilterRedgifsDirect];
  [defaults setObject:keywords forKey:kRedditFilterKeywords];
  RFReloadPreferences();
}

#pragma mark - Running a request

typedef struct {
  NSTimeInterval seconds; // until the app got the page
  NSUInteger calls;       // times the app's completion handler ran
} RFTiming;

static NSString *gHost = @"gql-fed.reddit.com";

// Marks the session's delegate queue, where NSURLSession calls completion handlers (on its dispatch
// queue, not as operations), so the tests can tell a page arrived there.
static char kRFDelegateQueueKey;

// Loads a Home page the way the app does and returns what the app got. Waits `settle` seconds after
// the page arrives to catch a second delivery.
static NSDictionary *LoadHome(NSURLSession *session, NSTimeInterval settle, RFTiming *timing) {
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/", gHost]]];
  request.HTTPMethod = @"POST";
  [request setValue:@"HomeFeedSdui" forHTTPHeaderField:@"X-APOLLO-OPERATION-NAME"];
  request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"operationName" : @"HomeFeedSdui", @"variables" : @{}}
                                                     options:0
                                                       error:NULL];
  dispatch_semaphore_t arrived = dispatch_semaphore_create(0);
  NSObject *lock = [NSObject new];
  __block NSUInteger calls = 0;
  __block NSData *page = nil;
  NSDate *start = [NSDate date];
  __block NSTimeInterval seconds = -1;
  __block BOOL onDelegateQueue = NO;
  [[session dataTaskWithRequest:request
              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                @synchronized(lock) {
                  if (++calls > 1) return;
                  seconds = -start.timeIntervalSinceNow;
                  page = data;
                  onDelegateQueue = dispatch_get_specific(&kRFDelegateQueueKey) != NULL;
                }
                dispatch_semaphore_signal(arrived);
              }] resume];
  Check(dispatch_semaphore_wait(arrived, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) == 0, @"The page arrives");
  @synchronized(lock) {
    Check(onDelegateQueue, [NSString stringWithFormat:@"Hand the page from %@ over on the session's delegate queue", gHost]);
  }
  [NSThread sleepForTimeInterval:settle];
  @synchronized(lock) {
    timing->seconds = seconds;
    timing->calls = calls;
  }
  return [NSJSONSerialization JSONObjectWithData:page options:0 error:NULL];
}

// Looks up videos without going through the page hook, so the quality choice can be checked directly.
static NSDictionary *FetchRedgifs(NSArray<NSString *> *ids, BOOL hd) {
  dispatch_semaphore_t finished = dispatch_semaphore_create(0);
  __block NSDictionary *found = nil;
  RFFetchRedgifsVideos(ids, hd, ^(NSDictionary *videoURLs) {
    found = videoURLs;
    dispatch_semaphore_signal(finished);
  });
  Check(dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0,
        @"RedGIFs lookup finishes");
  return found;
}

// Checks GitHub for the latest release, as tapping "Check for updates" does. Its answer comes on the
// main queue, so keep the main run loop going until then.
static RFUpdateStatus FetchLatestRelease(void) {
  __block BOOL done = NO;
  __block RFUpdateStatus result = RFUpdateStatusFailed;
  RFFetchLatestRelease(^(RFUpdateStatus status) {
    result = status;
    done = YES;
  });
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
  while (!done && deadline.timeIntervalSinceNow > 0)
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  Check(done, @"The update check finishes");
  return result;
}

// Sends the app's password login with this body and returns what the app got back. The browser
// sheet answers on the main queue, so keep the main run loop going until then.
static NSHTTPURLResponse *PasswordLogin(NSURLSession *session, NSData *body, NSString *contentType) {
  NSMutableURLRequest *request =
      [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://www.reddit.com/auth/v2/login/password"]];
  request.HTTPMethod = @"POST";
  [request setValue:contentType forHTTPHeaderField:@"Content-Type"];
  request.HTTPBody = body;
  __block NSHTTPURLResponse *answer = nil;
  __block NSUInteger calls = 0;
  [[session dataTaskWithRequest:request
              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                calls++;
                answer = (NSHTTPURLResponse *)response;
              }] resume];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
  while (!calls && deadline.timeIntervalSinceNow > 0)
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
  Check(calls == 1, @"Answer the app's password login exactly once");
  return answer;
}

static NSData *JSONBody(NSDictionary *fields) {
  return [NSJSONSerialization dataWithJSONObject:fields options:0 error:NULL];
}

static void TestPasswordLogin(NSURLSession *session) {
  __block NSArray *reddit = nil;
  __block NSDictionary *sent = nil;
  gRoute = ^NSArray *(NSString *operation, NSDictionary *body, NSURL *url) {
    sent = body;
    return reddit;
  };
  NSData *credentials = JSONBody(@{@"username" : @"someone", @"password" : @"pass word+1"});

  // Accepted: the app gets Reddit's answer and the browser isn't involved.
  gBrowserLogins = 0;
  reddit = @[ @200, @0.01, @{@"success" : @YES} ];
  NSHTTPURLResponse *answer = PasswordLogin(session, credentials, @"application/json");
  Check(answer.statusCode == 200 && gBrowserLogins == 0, @"Pass an accepted login straight through");
  Check([sent[@"password"] isEqual:@"pass word+1"], @"Send the app's login to Reddit unchanged");

  // A wrong password, or too many tries: reddit.com would say the same, so show Reddit's answer.
  reddit = @[ @400, @0.01, @{@"error" : @{@"params" : @{@"password" : @"INCORRECT"}}} ];
  answer = PasswordLogin(session, credentials, @"application/json");
  Check(answer.statusCode == 400 && gBrowserLogins == 0, @"Show Reddit's answer for a wrong password");
  // What Reddit actually answers for a wrong username or password.
  reddit = @[ @401, @0.01, @{@"error" : @{@"message" : @"unauthorized", @"id" : @"KWZcMt"}} ];
  answer = PasswordLogin(session, credentials, @"application/json");
  Check(answer.statusCode == 401 && gBrowserLogins == 0, @"Show Reddit's answer for an unauthorised login");
  reddit = @[ @429, @0.01, @{} ];
  answer = PasswordLogin(session, credentials, @"application/json");
  Check(answer.statusCode == 429 && gBrowserLogins == 0, @"Show Reddit's answer for too many tries");

  // Refused over the app itself: log in through the browser and hand its session to the app.
  reddit = @[ @400, @0.01, @{@"error" : @{@"params" : @{@"identifier" : @"OK", @"recaptcha_token" : @"INVALID"}}} ];
  gBrowserSession = @"browser-session";
  answer = PasswordLogin(session, credentials, @"application/json");
  Check(gBrowserLogins == 1 && [gBrowserUsername isEqual:@"someone"] && [gBrowserPassword isEqual:@"pass word+1"],
        @"Log in through the browser with the same username and password");
  Check(answer.statusCode == 200 &&
            [[answer valueForHTTPHeaderField:@"Set-Cookie"] hasPrefix:@"reddit_session=browser-session;"],
        @"Answer the app with the browser's session");
  // What Reddit actually answers when the app's attestation is refused: also 401 unauthorized, but
  // the reCAPTCHA token is named, so it isn't taken for a wrong password.
  reddit = @[ @401, @0.01, @{@"error" : @{@"message" : @"unauthorized", @"params" : @{@"recaptcha_token" : @"INVALID"}, @"id" : @"cQ3qdR"}} ];
  answer = PasswordLogin(session, credentials, @"application/json");
  Check(gBrowserLogins == 2 && answer.statusCode == 200, @"Log in through the browser when the attestation is refused");

  // Browser closed without logging in: the app gets Reddit's own answer.
  gBrowserSession = nil;
  answer = PasswordLogin(session, credentials, @"application/json");
  Check(gBrowserLogins == 3 && answer.statusCode == 401, @"Show Reddit's answer when the browser is closed");

  // A form body: + is a space.
  gBrowserSession = @"browser-session";
  NSData *form = [@"username=some+one&password=a+b%2Bc" dataUsingEncoding:NSUTF8StringEncoding];
  answer = PasswordLogin(session, form, @"application/x-www-form-urlencoded");
  Check([gBrowserUsername isEqual:@"some one"] && [gBrowserPassword isEqual:@"a b+c"],
        @"Read + as a space in a form body");
  gBrowserSession = nil;
}

int main(void) {
  @autoreleasepool {
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    Check(session.delegateQueue.underlyingQueue != nil, @"The session's delegate queue has a dispatch queue");
    dispatch_queue_set_specific(session.delegateQueue.underlyingQueue, &kRFDelegateQueueKey, &kRFDelegateQueueKey, NULL);
    RFTiming timing;
    NSArray *full = @[ @"t3_a", @"t3_b" ]; // no next page, so no top-up

    // RedGIFs quality: SD by default, HD when asked, and the other file when the preferred one is
    // missing. Each video has a separate server entry; RedGIFs IDs are lowercase in the cache.
    NSString *hdFile = @"https://media.redgifs.com/Both.mp4";
    NSString *sdFile = @"https://media.redgifs.com/Both-mobile.mp4";
    NSString *hdOnly = @"https://media.redgifs.com/HdOnly.mp4";
    NSString *sdOnly = @"https://media.redgifs.com/SdOnly-mobile.mp4";
    NSString *freshHD = @"https://media.redgifs.com/Fresh.mp4";
    gRoute = ^NSArray *(NSString *operation, NSDictionary *body, NSURL *url) {
      if ([url.path hasSuffix:@"/auth/temporary"]) return @[ @200, @0.01, @{@"token" : @"t"} ];
      NSString *identifier = url.path.lastPathComponent;
      NSDictionary *urls = @{
        @"both" : @{@"hd" : hdFile, @"sd" : sdFile},
        @"hdonly" : @{@"hd" : hdOnly},
        @"sdonly" : @{@"sd" : sdOnly},
        @"bothfresh" : @{@"hd" : freshHD, @"sd" : sdFile},
      }[identifier];
      return @[ @200, @0.01, @{@"gif" : @{@"hasAudio" : @YES, @"urls" : urls ?: @{}}} ];
    };
    NSArray *qualityIds = @[ @"both", @"hdonly", @"sdonly" ];
    NSDictionary *sd = FetchRedgifs(qualityIds, NO);
    Check([sd[@"both"] isEqual:sdFile], @"Use SD by default");
    Check([sd[@"hdonly"] isEqual:hdOnly], @"Fall back to HD when SD is missing");
    Check([sd[@"sdonly"] isEqual:sdOnly], @"Keep SD when HD is missing");

    NSDictionary *fresh = FetchRedgifs(@[ @"bothfresh" ], YES);
    Check([fresh[@"bothfresh"] isEqual:freshHD], @"Use HD when asked");

    NSDictionary *hd = FetchRedgifs(qualityIds, YES);
    Check([hd[@"both"] isEqual:hdFile], @"Use cached HD when asked");
    Check([hd[@"hdonly"] isEqual:hdOnly], @"Keep HD when SD is missing");
    Check([hd[@"sdonly"] isEqual:sdOnly], @"Fall back to SD when HD is missing");

    // A response without a usable file isn't cached, so the next page asks again.
    __block NSInteger lookups = 0;
    __block BOOL fixed = NO;
    gRoute = ^NSArray *(NSString *operation, NSDictionary *body, NSURL *url) {
      if ([url.path hasSuffix:@"/auth/temporary"]) return @[ @200, @0.01, @{@"token" : @"t"} ];
      lookups++;
      NSDictionary *urls = fixed ? @{@"sd" : sdOnly} : @{@"sd" : @"http://insecure.example/x.mp4"};
      return @[ @200, @0.01, @{@"gif" : @{@"hasAudio" : @YES, @"urls" : urls}} ];
    };
    Check(FetchRedgifs(@[ @"empty" ], NO).count == 0, @"Play nothing when no file is usable");
    fixed = YES;
    NSDictionary *retried = FetchRedgifs(@[ @"empty" ], NO);
    Check(lookups == 2 && [retried[@"empty"] isEqual:sdOnly], @"Look up again after a response without a usable file");

    // Full post text
    SetPrefs(@[ @"tesla" ], NO);
    __block NSTimeInterval detailsDelay = 0.1;
    __block NSInteger detailsStatus = 200;
    gRoute = ^NSArray *(NSString *operation, NSDictionary *body, NSURL *url) {
      if ([operation isEqualToString:@"FeedPostDetailsByIds"])
        return @[ @(detailsStatus), @(detailsDelay), Details(@"t3_a", @"...ended up buying a Tesla.") ];
      return @[ @200, @0.05, Page(full, nil) ];
    };
    NSDictionary *json = LoadHome(session, 0.5, &timing);
    NSLog(@"full text, quick: %.2fs, %lu call(s)", timing.seconds, (unsigned long)timing.calls);
    Check([Edges(json)[0][@"node"][@"cells"] count] == 0, @"Hide a post with a keyword further down its text");
    Check([Edges(json)[1][@"node"][@"cells"] count] == 1, @"Keep other posts");
    Check(timing.seconds < 1.5 && timing.calls == 1, @"Hand over a quickly checked page once, right away");

    // Every API address the app can use, e.g. cf.gql-fed, which the ios_graphql_uri_v2 experiment
    // moves some users onto. tests/check-ipa.sh passes the ones it finds in a new Reddit build.
    NSString *hosts = NSProcessInfo.processInfo.environment[@"RF_API_HOSTS"];
    if (!hosts.length) hosts = @"gql-fed.reddit.com,cf.gql-fed.reddit.com,gql-realtime.reddit.com,oauth.reddit.com";
    for (NSString *host in [hosts componentsSeparatedByString:@","]) {
      gHost = host;
      json = LoadHome(session, 0.5, &timing);
      Check([Edges(json)[0][@"node"][@"cells"] count] == 0, [NSString stringWithFormat:@"Filter responses from %@", host]);
    }

    // The debug menu lists GraphQL requests that skip the filter, so a new address shows up there
    NSArray *(^unfiltered)(void) = ^NSArray * {
      for (NSDictionary *row in [[RFSchemaDebug shared] snapshot])
        if (row[kRFDebugUnfiltered]) return row[kRFDebugUnfiltered];
      return nil;
    };
    Check(unfiltered().count == 0, @"Don't list addresses the filter handles as unfiltered");
    gHost = @"gql-new.example.reddit.com.evil.net";
    LoadHome(session, 0.2, &timing);
    gHost = @"api-v9.reddit.com";
    json = LoadHome(session, 0.2, &timing);
    Check([Edges(json)[0][@"node"][@"cells"] count] == 1, @"Pass requests to other addresses through");
    Check(unfiltered().count == 1 && [unfiltered()[0] hasPrefix:@"api-v9.reddit.com \u00b7 1 \u00b7 last HomeFeedSdui"],
          @"List a GraphQL request to an unknown Reddit address in the debug menu");
    gHost = @"gql-fed.reddit.com";

    detailsDelay = 8;
    json = LoadHome(session, 4.5, &timing);
    NSLog(@"full text, slow: %.2fs, %lu call(s)", timing.seconds, (unsigned long)timing.calls);
    Check(timing.seconds > 4.5 && timing.seconds < 6, @"Stop waiting for a slow full-text check after 5s");
    Check([Edges(json)[0][@"node"][@"cells"] count] == 1, @"Show the page unchecked when the check is too slow");
    Check(timing.calls == 1, @"Don't hand over the page again when the slow check finishes");

    detailsDelay = 0.1;
    detailsStatus = 500;
    json = LoadHome(session, 0.5, &timing);
    NSLog(@"full text, failed: %.2fs, %lu call(s)", timing.seconds, (unsigned long)timing.calls);
    Check(timing.seconds < 1.5 && timing.calls == 1 && [Edges(json)[0][@"node"][@"cells"] count] == 1,
          @"Show the page unchecked right away when the check fails");

    // Topping up a short first page
    SetPrefs(@[], NO);
    __block NSTimeInterval topUpDelay = 0.1;
    gRoute = ^NSArray *(NSString *operation, NSDictionary *body, NSURL *url) {
      if (body[@"variables"][@"after"]) return @[ @200, @(topUpDelay), Page(@[ @"t3_c", @"t3_d", @"t3_e" ], nil) ];
      return @[ @200, @0.05, Page(full, @"c1") ];
    };
    json = LoadHome(session, 0.5, &timing);
    NSLog(@"top-up, quick: %.2fs, %lu call(s)", timing.seconds, (unsigned long)timing.calls);
    Check(Edges(json).count == 5 && timing.calls == 1, @"Hand over both pages together, once");

    topUpDelay = 8;
    json = LoadHome(session, 4.5, &timing);
    NSLog(@"top-up, slow: %.2fs, %lu call(s)", timing.seconds, (unsigned long)timing.calls);
    Check(timing.seconds > 4.5 && timing.seconds < 6, @"Stop waiting for a slow next page after 5s");
    Check(Edges(json).count == 2 && timing.calls == 1, @"Show just the first page, once");

    // RedGIFs videos and the full text together: fetched side by side, so slow RedGIFs lookups
    // don't use up the keyword check's time.
    SetPrefs(@[ @"tesla" ], YES);
    NSString *sound = @"https://media.redgifs.com/Lark.mp4";
    gRoute = ^NSArray *(NSString *operation, NSDictionary *body, NSURL *url) {
      if ([url.path hasSuffix:@"/auth/temporary"]) return @[ @200, @0.05, @{@"token" : @"t"} ];
      if ([url.path hasPrefix:@"/v2/gifs/"])
        return @[ @200, @3.5, @{@"gif" : @{@"hasAudio" : @YES, @"urls" : @{@"hd" : sound}}} ];
      if ([operation isEqualToString:@"FeedPostDetailsByIds"])
        return @[ @200, @3, Details(@"t3_a", @"...ended up buying a Tesla.") ];
      NSMutableDictionary *video = [@{@"__typename" : @"CellGroup", @"id" : CardId(@"t3_v"), @"cells" : @[
        @{@"__typename" : @"MetadataCell", @"mediaDomain" : @"redgifs", @"mediaPath" : @"https://www.redgifs.com/watch/lark"},
        @{@"__typename" : @"LegacyVideoCell", @"isGif" : @YES, @"media" : @{@"path" : @"https://v.redd.it/x/HLSPlaylist.m3u8"}},
      ]} mutableCopy];
      NSMutableDictionary *home = [Page(@[ @"t3_a" ], nil) mutableCopy];
      NSArray *edges = [Edges(home) arrayByAddingObject:@{@"node" : video}];
      return @[ @200, @0.05, @{@"data" : @{@"homeV3" : @{@"elements" : @{@"edges" : edges,
                                                                       @"pageInfo" : @{@"hasNextPage" : @NO}}}}} ];
    };
    json = LoadHome(session, 0.5, &timing);
    NSLog(@"RedGIFs and full text, both slow: %.2fs, %lu call(s)", timing.seconds, (unsigned long)timing.calls);
    Check([Edges(json)[0][@"node"][@"cells"] count] == 0, @"Still hide keyword posts when RedGIFs is slow");
    Check([Edges(json)[1][@"node"][@"cells"][1][@"media"][@"path"] isEqual:sound], @"Swap in the RedGIFs video too");
    Check(timing.seconds < 4.5 && timing.calls == 1, @"Wait for the slower of the two, not both in turn");

    // Update check (built as RedditFilter 1.3.4). Pre-releases never come from /releases/latest.
    __block NSArray *github = nil;
    gRoute = ^NSArray *(NSString *operation, NSDictionary *body, NSURL *url) {
      Check([url.absoluteString isEqualToString:@"https://api.github.com/repos/and101/RedditFilter/releases/latest"],
            @"Ask GitHub for the latest release");
      return github;
    };
    NSString *page = @"https://github.com/and101/RedditFilter/releases/tag/v2026.44.0-1.3.5";
    github = @[ @200, @0.05, @{@"tag_name" : @"v2026.44.0-1.3.5", @"html_url" : page} ];
    Check(FetchLatestRelease() == RFUpdateStatusAvailable, @"Report a newer release");
    Check([RFAvailableUpdate() isEqual:@"1.3.5 for Reddit 2026.44.0"], @"Describe the newer release");
    Check([RFUpdateURL().absoluteString isEqual:page], @"Link to the newer release's page");
    github = @[ @403, @0.05, @{@"message" : @"API rate limit exceeded"} ];
    Check(FetchLatestRelease() == RFUpdateStatusFailed, @"Report a GitHub error as a failed check");
    Check([RFAvailableUpdate() isEqual:@"1.3.5 for Reddit 2026.44.0"] && [RFUpdateURL().absoluteString isEqual:page],
          @"Keep the last good answer after a failed check");
    github = @[ @200, @0.05, @{@"tag_name" : @"v2026.43.0-1.3.4", @"html_url" : @"https://github.com/x"} ];
    Check(FetchLatestRelease() == RFUpdateStatusUpToDate && RFAvailableUpdate() == nil, @"Report being up to date");
    github = @[ @200, @0.05, @{@"tag_name" : @"nightly"} ];
    Check(FetchLatestRelease() == RFUpdateStatusFailed, @"Ignore a tag that isn't a release");

    // The app's own password login, sideloaded.
    TestPasswordLogin(session);

    NSLog(@"All network pipeline tests passed.");
  }
  return 0;
}
