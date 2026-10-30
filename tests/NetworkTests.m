// Run in the iOS Simulator: ./tests/run-sim.sh
//
// Drives the real NSURLSession hook from Tweak.xm against stubbed Reddit responses, to check that a
// feed page is handed to the app once, and never held back long by RedditFilter's extra requests.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "Preferences.h"

// Browser login lives in LoginHelper.x, which isn't part of this test.
NSString *RFPendingWebSession(void) { return nil; }
void RFClearPendingWebSession(void) {}

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
  [[session dataTaskWithRequest:request
              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                @synchronized(lock) {
                  if (++calls > 1) return;
                  seconds = -start.timeIntervalSinceNow;
                  page = data;
                }
                dispatch_semaphore_signal(arrived);
              }] resume];
  Check(dispatch_semaphore_wait(arrived, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) == 0, @"The page arrives");
  [NSThread sleepForTimeInterval:settle];
  @synchronized(lock) {
    timing->seconds = seconds;
    timing->calls = calls;
  }
  return [NSJSONSerialization JSONObjectWithData:page options:0 error:NULL];
}

int main(void) {
  @autoreleasepool {
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    RFTiming timing;
    NSArray *full = @[ @"t3_a", @"t3_b" ]; // no next page, so no top-up

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

    NSLog(@"All network pipeline tests passed.");
  }
  return 0;
}
