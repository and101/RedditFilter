// Redgifs.m
//
// Uses RedGIFs' public API (https://github.com/Redgifs/api/wiki). Every request needs a temporary
// token, which RedGIFs hands to anyone. It's tied to the IP address and user agent it was issued to,
// so a new one is fetched when it's rejected, e.g. after switching networks.

#import "Redgifs.h"

static NSString *const kRFRedgifsAPI = @"https://api.redgifs.com/v2";

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

// Looked-up videos: ID -> URL, or NSNull when it has no sound (Reddit's version is just as good).
static NSCache *RFRedgifsCache(void) {
  static NSCache *cache;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ cache = [NSCache new]; });
  return cache;
}

static NSString *gToken;
static NSObject *RFTokenLock(void) {
  static NSObject *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ lock = [NSObject new]; });
  return lock;
}

static void RFWithToken(BOOL fresh, void (^completion)(NSString *token)) {
  NSString *token;
  @synchronized(RFTokenLock()) {
    if (fresh) gToken = nil;
    token = gToken;
  }
  if (token) return completion(token);
  NSURL *url = [NSURL URLWithString:[kRFRedgifsAPI stringByAppendingString:@"/auth/temporary"]];
  [[RFRedgifsSession() dataTaskWithURL:url
                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                       NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
                       NSString *token = [json isKindOfClass:NSDictionary.class] ? json[@"token"] : nil;
                       if (![token isKindOfClass:NSString.class] || !token.length) return completion(nil);
                       @synchronized(RFTokenLock()) {
                         gToken = token;
                       }
                       completion(token);
                     }] resume];
}

// Calls completion with the video URL, NSNull if it has no sound, or nil if the lookup failed.
// Retries once with a new token if the current one is rejected.
static void RFLookUp(NSString *identifier, BOOL retried, void (^completion)(id result)) {
  RFWithToken(retried, ^(NSString *token) {
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
                             if ((status == 401 || status == 403) && !retried) return RFLookUp(identifier, YES, completion);
                             NSDictionary *json = status == 200 && data
                                                      ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]
                                                      : nil;
                             NSDictionary *gif = [json isKindOfClass:NSDictionary.class] ? json[@"gif"] : nil;
                             if (![gif isKindOfClass:NSDictionary.class]) return completion(nil);
                             id hasAudio = gif[@"hasAudio"];
                             if ([hasAudio isKindOfClass:NSNumber.class] && ![hasAudio boolValue])
                               return completion(NSNull.null);
                             NSDictionary *urls = [gif[@"urls"] isKindOfClass:NSDictionary.class] ? gif[@"urls"] : nil;
                             id url = urls[@"hd"] ?: urls[@"sd"];
                             completion([url isKindOfClass:NSString.class] && [url hasPrefix:@"https://"] ? url : nil);
                           }] resume];
  });
}

// How long a page waits for RedGIFs before it's shown with Reddit's versions of what's missing.
static const double kRFRedgifsDeadline = 4.0;

void RFFetchRedgifsVideos(NSArray<NSString *> *ids, void (^completion)(NSDictionary<NSString *, NSString *> *videoURLs)) {
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
      if ([cached isKindOfClass:NSString.class]) found[identifier] = cached; // nothing else has started yet
      continue;
    }
    dispatch_group_enter(group);
    RFLookUp(identifier, NO, ^(id result) {
      if (result) [RFRedgifsCache() setObject:result forKey:identifier]; // failures are tried again next time
      if ([result isKindOfClass:NSString.class]) {
        @synchronized(found) {
          found[identifier] = result;
        }
      }
      dispatch_group_leave(group);
    });
  }
  dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
  dispatch_group_notify(group, queue, finish);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRFRedgifsDeadline * NSEC_PER_SEC)), queue, finish);
}
