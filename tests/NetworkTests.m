// Run in the iOS Simulator: ./tests/run-sim.sh
//
// Drives the real NSURLSession hook from Tweak.xm against stubbed Reddit responses, to check that a
// feed page is handed to the app once, and never held back long by RedditFilter's extra requests.
#import <Foundation/Foundation.h>
#import "Preferences.h"

// Browser login lives in LoginHelper.x, which isn't part of this test.
NSString *RFPendingWebSession(void) { return nil; }
void RFClearPendingWebSession(void) {}

static void Check(BOOL condition, NSString *message) {
  if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}

#pragma mark - Stubbed server

// operation, request body -> @[status, delay in seconds, JSON]
static NSArray *(^gRoute)(NSString *operation, NSDictionary *body);

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
  NSArray *reply = gRoute([self.request valueForHTTPHeaderField:@"X-APOLLO-OPERATION-NAME"], body);
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

static void SetPrefs(NSArray *keywords) {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  [defaults setBool:YES forKey:kRedditFilterPromoted];
  [defaults setObject:keywords forKey:kRedditFilterKeywords];
  RFReloadPreferences();
}

#pragma mark - Running a request

typedef struct {
  NSTimeInterval seconds; // until the app got the page
  NSUInteger calls;       // times the app's completion handler ran
} RFTiming;

// Loads a Home page the way the app does and returns what the app got. Waits `settle` seconds after
// the page arrives to catch a second delivery.
static NSDictionary *LoadHome(NSURLSession *session, NSTimeInterval settle, RFTiming *timing) {
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://gql-fed.reddit.com/"]];
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
    config.protocolClasses = @[ RFStubProtocol.class ];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    RFTiming timing;
    NSArray *full = @[ @"t3_a", @"t3_b" ]; // no next page, so no top-up

    // Full post text
    SetPrefs(@[ @"tesla" ]);
    __block NSTimeInterval detailsDelay = 0.1;
    __block NSInteger detailsStatus = 200;
    gRoute = ^NSArray *(NSString *operation, NSDictionary *body) {
      if ([operation isEqualToString:@"FeedPostDetailsByIds"])
        return @[ @(detailsStatus), @(detailsDelay), Details(@"t3_a", @"...ended up buying a Tesla.") ];
      return @[ @200, @0.05, Page(full, nil) ];
    };
    NSDictionary *json = LoadHome(session, 0.5, &timing);
    NSLog(@"full text, quick: %.2fs, %lu call(s)", timing.seconds, (unsigned long)timing.calls);
    Check([Edges(json)[0][@"node"][@"cells"] count] == 0, @"Hide a post with a keyword further down its text");
    Check([Edges(json)[1][@"node"][@"cells"] count] == 1, @"Keep other posts");
    Check(timing.seconds < 1.5 && timing.calls == 1, @"Hand over a quickly checked page once, right away");

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
    SetPrefs(@[]);
    __block NSTimeInterval topUpDelay = 0.1;
    gRoute = ^NSArray *(NSString *operation, NSDictionary *body) {
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

    NSLog(@"All network pipeline tests passed.");
  }
  return 0;
}
