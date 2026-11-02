// Redgifs.m
//
// Uses RedGIFs' public API (https://github.com/Redgifs/api/wiki). Every request needs a temporary
// token, which RedGIFs hands to anyone. It's tied to the IP address and user agent it was issued to,
// so a new one is fetched when it's rejected, e.g. after switching networks.

#import "Redgifs.h"
#import <Network/Network.h>
#import <stdatomic.h>

static NSString *const kRFRedgifsAPI = @"https://api.redgifs.com/v2";
static _Atomic BOOL gRFRedgifsOnWiFi;

BOOL RFRedgifsOnWiFi(void) {
  static dispatch_once_t once;
  static nw_path_monitor_t monitor;
  static dispatch_queue_t queue;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("com.and101.RedditFilter.redgifs-network", DISPATCH_QUEUE_SERIAL);
    monitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(monitor, queue);
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
      BOOL onWiFi = nw_path_get_status(path) == nw_path_status_satisfied &&
                    !nw_path_is_expensive(path) && !nw_path_is_constrained(path);
      atomic_store_explicit(&gRFRedgifsOnWiFi, onWiFi, memory_order_relaxed);
    });
    nw_path_monitor_start(monitor);
  });
  return atomic_load_explicit(&gRFRedgifsOnWiFi, memory_order_relaxed);
}

static NSURLSession *RFRedgifsSession(void) {
  static NSURLSession *session;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = 5.0;
    // The token is only valid with the same user agent, so always send this one.
    config.HTTPAdditionalHeaders = @{@"User-Agent" : @"RedditFilter"};
    session = [NSURLSession sessionWithConfiguration:config];
  });
  return session;
}

// Looked-up videos: ID -> {hd, sd} URLs, or NSNull when it has no sound (Reddit's version is just
// as good).
static NSCache *RFRedgifsCache(void) {
  static NSCache *cache;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ cache = [NSCache new]; });
  return cache;
}

static NSString *gToken;
static NSMutableArray *gTokenWaiters; // non-nil while a token is being fetched
static NSObject *RFTokenLock(void) {
  static NSObject *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ lock = [NSObject new]; });
  return lock;
}

// Calls completion with a token, or nil if none could be had. Pass the token RedGIFs just turned down
// to get a new one. Lookups that need a token at the same time share one request for it.
static void RFWithToken(NSString *rejected, void (^completion)(NSString *token)) {
  NSString *token;
  BOOL fetch = NO;
  @synchronized(RFTokenLock()) {
    if (rejected && [gToken isEqualToString:rejected]) gToken = nil;
    token = gToken;
    if (!token) {
      fetch = !gTokenWaiters;
      if (fetch) gTokenWaiters = [NSMutableArray array];
      [gTokenWaiters addObject:[completion copy]];
    }
  }
  if (token) return completion(token);
  if (!fetch) return;
  NSURL *url = [NSURL URLWithString:[kRFRedgifsAPI stringByAppendingString:@"/auth/temporary"]];
  [[RFRedgifsSession() dataTaskWithURL:url
                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                       NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
                       NSString *token = [json isKindOfClass:NSDictionary.class] ? json[@"token"] : nil;
                       if (![token isKindOfClass:NSString.class] || !token.length) token = nil;
                       NSArray *waiters;
                       @synchronized(RFTokenLock()) {
                         if (token) gToken = token;
                         waiters = gTokenWaiters;
                         gTokenWaiters = nil;
                       }
                       for (void (^waiter)(NSString *) in waiters) waiter(token);
                     }] resume];
}

// Calls completion with the video URLs, NSNull if it has no sound, or nil if the lookup failed.
// Retries once with a new token if the current one is rejected.
static void RFLookUp(NSString *identifier, NSString *rejected, void (^completion)(id result)) {
  RFWithToken(rejected, ^(NSString *token) {
    if (!token) return completion(nil);
    NSString *path = [NSString stringWithFormat:@"%@/gifs/%@", kRFRedgifsAPI,
                                                [identifier stringByAddingPercentEncodingWithAllowedCharacters:
                                                                NSCharacterSet.URLPathAllowedCharacterSet]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:path]];
    [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [[RFRedgifsSession() dataTaskWithRequest:request
                           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                             NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
                                                    ? ((NSHTTPURLResponse *)response).statusCode
                                                    : 0;
                             if ((status == 401 || status == 403) && !rejected) return RFLookUp(identifier, token, completion);
                             NSDictionary *json = status == 200 && data
                                                      ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]
                                                      : nil;
                             NSDictionary *gif = [json isKindOfClass:NSDictionary.class] ? json[@"gif"] : nil;
                             if (![gif isKindOfClass:NSDictionary.class]) return completion(nil);
                             id hasAudio = gif[@"hasAudio"];
                             if ([hasAudio isKindOfClass:NSNumber.class] && ![hasAudio boolValue])
                               return completion(NSNull.null);
                             NSDictionary *urls = [gif[@"urls"] isKindOfClass:NSDictionary.class] ? gif[@"urls"] : nil;
                             NSMutableDictionary *variants = [NSMutableDictionary dictionary];
                             for (NSString *quality in @[ @"hd", @"sd" ]) {
                               id url = urls[quality];
                               if ([url isKindOfClass:NSString.class] && [url hasPrefix:@"https://"])
                                 variants[quality] = url;
                             }
                             // Nothing playable is a failure too, so it isn't cached and is tried again.
                             completion(variants.count ? [variants copy] : nil);
                           }] resume];
  });
}

// How long a page waits for RedGIFs before it's shown with Reddit's versions of what's missing.
static const double kRFRedgifsDeadline = 4.0;

// Picks the preferred file, falling back to the other one when it's missing.
static NSString *RFRedgifsURL(NSDictionary *variants, BOOL hd) {
  NSString *first = hd ? @"hd" : @"sd";
  NSString *second = hd ? @"sd" : @"hd";
  return variants[first] ?: variants[second];
}

void RFFetchRedgifsVideos(NSArray<NSString *> *ids, BOOL hd,
                          void (^completion)(NSDictionary<NSString *, NSString *> *videoURLs)) {
  NSMutableDictionary *found = [NSMutableDictionary dictionary];
  __block BOOL finished = NO;
  void (^finish)(void) = ^{
    NSDictionary *result;
    @synchronized(found) {
      if (finished) return;
      finished = YES;
      result = [found copy];
    }
    completion(result);
  };
  dispatch_group_t group = dispatch_group_create();
  for (NSString *identifier in ids) {
    id cached = [RFRedgifsCache() objectForKey:identifier];
    if (cached) {
      if ([cached isKindOfClass:NSDictionary.class]) {
        NSString *url = RFRedgifsURL(cached, hd);
        if (url) found[identifier] = url; // nothing else has started yet
      }
      continue;
    }
    dispatch_group_enter(group);
    RFLookUp(identifier, nil, ^(id result) {
      if (result) [RFRedgifsCache() setObject:result forKey:identifier]; // failures are tried again next time
      if ([result isKindOfClass:NSDictionary.class]) {
        NSString *url = RFRedgifsURL(result, hd);
        @synchronized(found) {
          if (url) found[identifier] = url;
        }
      }
      dispatch_group_leave(group);
    });
  }
  dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
  dispatch_group_notify(group, queue, finish);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRFRedgifsDeadline * NSEC_PER_SEC)), queue, finish);
}
