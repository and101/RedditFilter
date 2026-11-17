// TrackerBlock.x
//
// Block trackers (TrackerBlock.h). A URL protocol answers the blocked requests: added to every session
// the app makes (the SDKs each make their own) and registered for the shared one. Background sessions
// can't use one, but none of the trackers use those.

#import "TrackerBlock.h"
#import "JSONFilter.h"
#import "RFStats.h"
#import <stdatomic.h>

static atomic_bool gBlockTrackers;

void RFSetTrackerBlocking(BOOL enabled) { atomic_store(&gBlockTrackers, enabled); }

@interface RFTrackerBlockProtocol : NSURLProtocol
@end

@implementation RFTrackerBlockProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
  return atomic_load(&gBlockTrackers) && RFIsTrackerURL(request.URL);
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
  return request;
}

- (void)startLoading {
  RFStatsRecord(RFStatTrackers, nil);
  NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                            statusCode:200
                                                           HTTPVersion:@"HTTP/1.1"
                                                          headerFields:@{@"Content-Length" : @"0"}];
  [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
  [self.client URLProtocol:self didLoadData:[NSData data]];
  [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
}

@end

static NSURLSessionConfiguration *RFWithTrackerBlock(NSURLSessionConfiguration *configuration) {
  if (!configuration || configuration.identifier) return configuration; // background sessions can't
  NSArray *classes = configuration.protocolClasses ?: @[];
  if ([classes containsObject:RFTrackerBlockProtocol.class]) return configuration;
  // The session keeps its own copy, so changing the app's configuration here would be seen by nobody else
  // anyway; copy it so the app's object stays as it made it.
  NSURLSessionConfiguration *copy = [configuration copy];
  copy.protocolClasses = [@[ RFTrackerBlockProtocol.class ] arrayByAddingObjectsFromArray:classes];
  return copy;
}

%hook NSURLSession
+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration {
  return %orig(RFWithTrackerBlock(configuration));
}
+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration
                                  delegate:(id<NSURLSessionDelegate>)delegate
                             delegateQueue:(NSOperationQueue *)queue {
  return %orig(RFWithTrackerBlock(configuration), delegate, queue);
}
%end

%ctor {
  [NSURLProtocol registerClass:RFTrackerBlockProtocol.class];
  %init;
}
