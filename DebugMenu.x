// DebugMenu.x
//
// Implementation of RFSchemaDebug, which records only while Diagnostics is on.

#import "DebugMenu.h"
#import "PreferenceKeys.h"
#include <stdatomic.h>

static atomic_bool gRFDiagnosticsEnabled;

BOOL RFDiagnosticsEnabled(void) { return atomic_load_explicit(&gRFDiagnosticsEnabled, memory_order_relaxed); }

void RFSetDiagnosticsEnabled(BOOL enabled) {
  BOOL was = atomic_exchange(&gRFDiagnosticsEnabled, (bool)enabled);
  if (was && !enabled) [[RFSchemaDebug shared] reset];
}

NSString *const kRFDebugOp = @"op";
NSString *const kRFDebugExpected = @"expected";
NSString *const kRFDebugHits = @"hits";
NSString *const kRFDebugMisses = @"misses";
NSString *const kRFDebugErrors = @"errors";
NSString *const kRFDebugDiscovered = @"discovered";
NSString *const kRFDebugLastResolved = @"lastResolved";
NSString *const kRFDebugSeen = @"seen";
NSString *const kRFDebugFailedJSON = @"failedJSON";
NSString *const kRFDebugUnfiltered = @"unfiltered";
NSString *const kRFDebugFeedCards = @"feedCards";
NSString *const kRFDebugSummary = @"summary";

// The row that lists GraphQL requests the filter let through. Always first.
static NSString *const kRFUnfilteredRow = @"Unfiltered requests";
// The row that lists feed cards that aren't posts or ads. Always last.
static NSString *const kRFFeedCardsRow = @"Other feed cards";
static NSString *const kRFArticleSafariRow = @"Article links in Safari";
static const NSUInteger kRFMaxCardTypes = 30;

// Bounds for discovery so a broken path can never turn into an expensive walk
// on every response.
static const NSInteger kRFMaxVisited = 6000; // total nodes inspected
static const NSInteger kRFMaxDepth = 9;      // key-path depth
static const NSUInteger kRFMaxArrayProbe = 6; // array elements descended into

@implementation RFSchemaDebug {
  dispatch_queue_t _queue;             // serializes all access to the stores
  NSMutableArray<NSString *> *_order;  // operation names, in display order
  NSMutableDictionary<NSString *, NSMutableDictionary *> *_records;
  // Address (plus why, if not the address) -> { count, last operation }
  NSMutableDictionary<NSString *, NSMutableDictionary *> *_unfiltered;
  // Card type -> { count, known, last operation }
  NSMutableDictionary<NSString *, NSMutableDictionary *> *_feedCards;
  RFArticleSafariHooks _articleSafariHooks;
  RFArticleSafariResult _articleSafariResult;
}

+ (instancetype)shared {
  static RFSchemaDebug *instance;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[RFSchemaDebug alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _queue = dispatch_queue_create("com.level3tjg.redditfilter.schemadebug", DISPATCH_QUEUE_SERIAL);
    _order = [NSMutableArray array];
    _records = [NSMutableDictionary dictionary];
    _unfiltered = [NSMutableDictionary dictionary];
    _feedCards = [NSMutableDictionary dictionary];
    [self seedOperation:kRFUnfilteredRow expected:@"no GraphQL requests to other Reddit addresses"];

    // Seed the known operations so the menu lists every path up front, even
    // before any matching traffic has been observed. Keep these in sync with
    // the hardcoded paths in JSONFilter.m.
    [self seedOperation:@"HomeFeedSdui" expected:@"data.homeV3.elements.edges"];
    [self seedOperation:@"PopularFeedSdui" expected:@"data.popularV3.elements.edges"];
    [self seedOperation:@"FollowingFeed" expected:@"data.homeV3.elements.edges"];
    [self seedOperation:@"FeedPostDetailsByIds" expected:@"data.postsInfoByIds"];
    [self seedOperation:@"PostInfoById" expected:@"data.postInfoById.commentForest.trees"];
    [self seedOperation:@"PdpCommentsAds" expected:@"data.*.pdpCommentsAds"];
    [self seedOperation:kRFArticleSafariRow expected:@"article hook compatibility"];
    [self seedOperation:kRFFeedCardsRow expected:@"feed cards that aren't posts or ads"];
  }
  return self;
}

// Caller must be on _queue (or constructing, as in init where there is no
// contention yet).
- (void)seedOperation:(NSString *)op expected:(NSString *)expected {
  if (_records[op]) {
    _records[op][kRFDebugExpected] = expected;
    return;
  }
  [_order addObject:op];
  _records[op] = [@{
    kRFDebugOp : op,
    kRFDebugExpected : expected,
    kRFDebugHits : @0,
    kRFDebugMisses : @0,
    kRFDebugErrors : @0,
    kRFDebugLastResolved : @NO,
    kRFDebugSeen : @NO,
  } mutableCopy];
}

- (void)recordOperation:(NSString *)operation
           expectedPath:(NSString *)expectedPath
               resolved:(BOOL)resolved
                   json:(id)json
              signature:(RFSchemaSig)signature {
  if (operation.length == 0) return;

  // An error instead of the data says nothing about where the data lives now.
  id errors = [json isKindOfClass:NSDictionary.class] ? json[@"errors"] : nil;
  BOOL redditError = !resolved && [errors isKindOfClass:NSArray.class] && [errors count] > 0;

  __block BOOL needsDiscovery = NO;
  dispatch_sync(_queue, ^{
    NSMutableDictionary *record = _records[operation];
    if (record && redditError) {
      record[kRFDebugSeen] = @YES;
      record[kRFDebugErrors] = @([record[kRFDebugErrors] integerValue] + 1);
    } else if (record) {
        // 1. Update the stats so it no longer says "untested"
        record[kRFDebugSeen] = @YES;
        record[kRFDebugLastResolved] = @(resolved);
        
        if (resolved) {
            record[kRFDebugHits] = @([record[kRFDebugHits] integerValue] + 1);
        } else {
            record[kRFDebugMisses] = @([record[kRFDebugMisses] integerValue] + 1);
            // If it missed and we haven't discovered a new path yet, arm discovery
            if (!record[kRFDebugDiscovered]) {
                needsDiscovery = YES;
            }
        }
    }
  });

  if (!needsDiscovery) return;

  // 2. Run the actual discovery process outside the lock
  NSString *discovered = [[self class] discoverPathForSignature:signature in:json];
  
  dispatch_sync(_queue, ^{
    NSMutableDictionary *record = _records[operation];
    // Re-check: another thread may have filled it in the meantime.
    if (record && !record[kRFDebugDiscovered]) {
      if (discovered.length) {
        record[kRFDebugDiscovered] = discovered;
      } else {
        // 3. If discovery failed, capture the raw JSON so you can inspect it
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil];
        if (jsonData) {
            record[kRFDebugFailedJSON] = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        }
      }
    }
  });
}

- (void)recordUnfilteredRequest:(NSURLRequest *)request hasHandler:(BOOL)hasHandler {
  NSString *op = [request valueForHTTPHeaderField:@"X-APOLLO-OPERATION-NAME"];
  NSString *host = request.URL.host.lowercaseString;
  if (!op.length || !([host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"])) return;
  NSString *key = hasHandler ? host : [host stringByAppendingString:@" (no completion handler)"];
  dispatch_sync(_queue, ^{
    NSMutableDictionary *entry = _unfiltered[key];
    if (!entry) entry = _unfiltered[key] = [@{@"count" : @0} mutableCopy];
    entry[@"count"] = @([entry[@"count"] integerValue] + 1);
    entry[@"op"] = op;
    NSMutableDictionary *record = _records[kRFUnfilteredRow];
    record[kRFDebugSeen] = @YES;
    record[kRFDebugMisses] = @([record[kRFDebugMisses] integerValue] + 1);
  });
}

- (void)recordFeedCardType:(NSString *)type known:(BOOL)known operation:(NSString *)operation {
  if (!type.length) return;
  dispatch_sync(_queue, ^{
    NSMutableDictionary *entry = _feedCards[type];
    if (!entry) {
      if (_feedCards.count >= kRFMaxCardTypes) return;
      entry = _feedCards[type] = [@{@"count" : @0} mutableCopy];
    }
    entry[@"count"] = @([entry[@"count"] integerValue] + 1);
    entry[@"known"] = @(known);
    entry[@"op"] = operation ?: @"";
    _records[kRFFeedCardsRow][kRFDebugSeen] = @YES;
  });
}

- (void)setArticleSafariHooks:(RFArticleSafariHooks)hooks {
  dispatch_sync(_queue, ^{ _articleSafariHooks = hooks; });
}

- (void)recordArticleSafariResult:(RFArticleSafariResult)result {
  if (!RFDiagnosticsEnabled() || result > RFArticleSafariReturnSkipped) return;
  dispatch_sync(_queue, ^{
    if (RFDiagnosticsEnabled()) _articleSafariResult = result;
  });
}

// Caller is on _queue. This is a single fixed outcome, not a browsing history.
- (NSString *)articleSafariSummary {
  NSArray<NSString *> *results = @[
    @"No article attempt observed with Diagnostics on",
    @"Legacy article: Safari presented",
    @"Post-page article: Safari presented",
    @"Native behavior kept: option off or transition cancelled",
    @"Native behavior kept: URL is not eligible HTTP(S)",
    @"Native behavior kept: expected getter missing",
    @"Native behavior kept: presenter, scene or transition unavailable",
    @"Native behavior kept: navigation stack changed",
    @"Native behavior kept: no visible initial article",
    @"Native behavior kept: initial article URL not ready",
    @"Native behavior kept: multiple visible article candidates",
    @"Native behavior kept: Safari presentation declined",
    @"Post-page Safari presented; original post restored",
    @"Native stack preserved after presentation or navigation changed",
  ];
  NSString *(^found)(RFArticleSafariHooks) = ^NSString *(RFArticleSafariHooks hook) {
    return (_articleSafariHooks & hook) ? @"found" : @"missing";
  };
  return [NSString stringWithFormat:@"Setting: %@\nLegacy hook: %@\nPost-page push hook: %@\n"
                                    @"Article load hook: %@\nArticle policy hook: %@\nLast result: %@",
      [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterSafariLinks] ? @"on" : @"off",
      found(RFArticleSafariHookLegacy), found(RFArticleSafariHookPush), found(RFArticleSafariHookStart),
      found(RFArticleSafariHookPolicy), results[_articleSafariResult]];
}

// Caller must be on _queue.
- (NSArray<NSString *> *)feedCardLines {
  NSArray *types = [_feedCards.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
    NSComparisonResult order = [_feedCards[a][@"known"] compare:_feedCards[b][@"known"]]; // unknown first
    return order != NSOrderedSame ? order : [_feedCards[b][@"count"] compare:_feedCards[a][@"count"]];
  }];
  NSMutableArray *lines = [NSMutableArray array];
  for (NSString *type in types)
    [lines addObject:[NSString stringWithFormat:@"%@ %@ \u00b7 %@ \u00b7 %@",
                                                [_feedCards[type][@"known"] boolValue] ? @"\u2713" : @"?", type,
                                                _feedCards[type][@"count"], _feedCards[type][@"op"]]];
  return lines;
}

- (NSArray<NSDictionary *> *)snapshot {
  __block NSArray *result;
  dispatch_sync(_queue, ^{
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:_order.count];
    for (NSString *op in _order) {
      // Deep-ish copy: the values are immutable, so a shallow copy is a safe
      // immutable snapshot for the UI to read on the main thread.
      NSMutableDictionary *record = [_records[op] mutableCopy];
      if ([op isEqualToString:kRFArticleSafariRow]) record[kRFDebugSummary] = [self articleSafariSummary];
      if ([op isEqualToString:kRFUnfilteredRow]) {
        NSArray *keys = [_unfiltered keysSortedByValueUsingComparator:^NSComparisonResult(id a, id b) {
          return [b[@"count"] compare:a[@"count"]];
        }];
        NSMutableArray *lines = [NSMutableArray array];
        for (NSString *key in keys)
          [lines addObject:[NSString stringWithFormat:@"%@ \u00b7 %@ \u00b7 last %@", key, _unfiltered[key][@"count"],
                                                      _unfiltered[key][@"op"]]];
        record[kRFDebugUnfiltered] = lines;
      }
      if ([op isEqualToString:kRFFeedCardsRow]) record[kRFDebugFeedCards] = [self feedCardLines];
      [out addObject:[record copy]];
    }
    result = out;
  });
  return result;
}

- (NSString *)reportText {
  NSMutableArray<NSString *> *lines = [NSMutableArray array];
  for (NSDictionary *record in [self snapshot]) {
    NSString *op = record[kRFDebugOp];
    NSString *summary = record[kRFDebugSummary];
    NSArray<NSString *> *unfiltered = record[kRFDebugUnfiltered];
    NSArray<NSString *> *feedCards = record[kRFDebugFeedCards];
    NSInteger hits = [record[kRFDebugHits] integerValue], misses = [record[kRFDebugMisses] integerValue];
    NSInteger errors = [record[kRFDebugErrors] integerValue];
    NSString *errorNote = errors ? [NSString stringWithFormat:@", %ld Reddit error%@", (long)errors, errors == 1 ? @"" : @"s"] : @"";
    if (summary) {
      [lines addObject:[NSString stringWithFormat:@"%@:\n%@", op, summary]];
    } else if (unfiltered) {
      [lines addObject:[NSString stringWithFormat:@"%@: %@", op, unfiltered.count ? @"" : @"none"]];
      for (NSString *line in unfiltered) [lines addObject:[@"  " stringByAppendingString:line]];
    } else if (feedCards) {
      [lines addObject:[NSString stringWithFormat:@"%@: %@", op, feedCards.count ? @"" : @"none"]];
      for (NSString *line in feedCards)
        [lines addObject:[NSString stringWithFormat:@"  %@ %@", [line hasPrefix:@"?"] ? @"not recognised:" : @"known:",
                                                    [line substringFromIndex:2]]];
    } else if (![record[kRFDebugSeen] boolValue]) {
      [lines addObject:[NSString stringWithFormat:@"%@: untested", op]];
    } else if ([record[kRFDebugLastResolved] boolValue]) {
      [lines addObject:[NSString stringWithFormat:@"%@: OK, %ld hits, %ld misses%@", op, (long)hits, (long)misses, errorNote]];
    } else if (!misses) {
      [lines addObject:[NSString stringWithFormat:@"%@: only Reddit errors so far%@", op, errorNote]];
    } else {
      [lines addObject:[NSString stringWithFormat:@"%@: MISS, %ld hits, %ld misses%@", op, (long)hits, (long)misses, errorNote]];
      [lines addObject:[@"  expected: " stringByAppendingString:record[kRFDebugExpected] ?: @""]];
      if ([record[kRFDebugDiscovered] length])
        [lines addObject:[@"  found at: " stringByAppendingString:record[kRFDebugDiscovered]]];
    }
  }
  return [lines componentsJoinedByString:@"\n"];
}

- (void)reset {
  dispatch_sync(_queue, ^{
    for (NSString *op in _order) {
      NSMutableDictionary *record = _records[op];
      record[kRFDebugHits] = @0;
      record[kRFDebugMisses] = @0;
      record[kRFDebugErrors] = @0;
      record[kRFDebugLastResolved] = @NO;
      record[kRFDebugSeen] = @NO;
      [record removeObjectForKey:kRFDebugDiscovered];
	  [record removeObjectForKey:kRFDebugFailedJSON];
    }
    [_unfiltered removeAllObjects];
    [_feedCards removeAllObjects];
    _articleSafariResult = RFArticleSafariNotObserved;
  });
}

#pragma mark - Discovery

// Returns YES if `value` matches the shape described by `signature`.
+ (BOOL)value:(id)value matchesSignature:(RFSchemaSig)signature {
  switch (signature) {
    case RFSchemaSigEdges:
    case RFSchemaSigTrees: {
      if (![value isKindOfClass:NSArray.class]) return NO;
      for (id element in (NSArray *)value) {
        if (![element isKindOfClass:NSDictionary.class]) continue;
        if (((NSDictionary *)element)[@"node"]) return YES;
      }
      return NO;
    }
    case RFSchemaSigNodeArray: {
      if (![value isKindOfClass:NSArray.class]) return NO;
      for (id element in (NSArray *)value) {
        if (![element isKindOfClass:NSDictionary.class]) continue;
        if (((NSDictionary *)element)[@"__typename"]) return YES;
      }
      return NO;
    }
    case RFSchemaSigCommentsAds:
      return [value isKindOfClass:NSArray.class] ||
             ([value isKindOfClass:NSDictionary.class] &&
              [value[@"adPosts"] isKindOfClass:NSArray.class]);
  }
  return NO;
}

// The key that breakages most commonly leave intact (only the ancestors get
// renamed). Discovery prefers a key match so the suggested path stays a clean,
// index-free, drop-in replacement.
+ (NSString *)preferredKeyForSignature:(RFSchemaSig)signature {
  switch (signature) {
    case RFSchemaSigEdges:       return @"edges";
    case RFSchemaSigTrees:       return @"trees";
    case RFSchemaSigNodeArray:   return @"postsInfoByIds";
    case RFSchemaSigCommentsAds: return @"pdpCommentsAds";
  }
  return nil;
}

+ (NSString *)discoverPathForSignature:(RFSchemaSig)signature in:(id)json {
  if (![json isKindOfClass:NSDictionary.class] && ![json isKindOfClass:NSArray.class]) {
    return nil;
  }
  NSString *preferredKey = [self preferredKeyForSignature:signature];

  // First try to locate the data by its (stable) key, validating the value
  // against the expected shape. This is the common ancestor-rename case.
  if (preferredKey) {
    NSString *byKey = [self breadthFirstPathIn:json
                                       testing:^BOOL(NSString *key, id value) {
                                         return [key isEqualToString:preferredKey] &&
                                                [self value:value matchesSignature:signature];
                                       }];
    if (byKey) return byKey;
  }

  // Fall back to a purely structural search (the key itself was renamed).
  return [self breadthFirstPathIn:json
                          testing:^BOOL(NSString *key, id value) {
                            return [self value:value matchesSignature:signature];
                          }];
}

// Breadth-first walk that returns the shallowest key path whose (key, value)
// satisfies `test`. Dict children are addressed as `.key`; array elements as
// `[i]`. Because the search returns as soon as a matching *container* is
// dequeued, the resulting path points at that container and contains no array
// indices (making it a valid -valueForKeyPath: replacement).
+ (NSString *)breadthFirstPathIn:(id)root testing:(BOOL (^)(NSString *key, id value))test {
  // Each queue entry: @[ key-or-NSNull, value, pathString ].
  NSMutableArray *queue = [NSMutableArray array];
  [queue addObject:@[ [NSNull null], root, @"" ]];
  NSInteger visited = 0;

  while (queue.count) {
    NSArray *entry = queue.firstObject;
    [queue removeObjectAtIndex:0];
    id key = entry[0];
    id value = entry[1];
    NSString *path = entry[2];

    if (++visited > kRFMaxVisited) break;

    // Skip the synthetic root entry; only test real (key, value) pairs.
    if (path.length && test([key isKindOfClass:NSString.class] ? key : @"", value)) {
      return path;
    }

    if (path.length && [self depthOfPath:path] >= kRFMaxDepth) continue;

    if ([value isKindOfClass:NSDictionary.class]) {
      [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id childKey, id childValue, BOOL *stop) {
        if (![childKey isKindOfClass:NSString.class]) return;
        if (!path.length && [childKey isEqualToString:@"errors"]) return; // Reddit's errors, never its data
        NSString *childPath = path.length
                                  ? [NSString stringWithFormat:@"%@.%@", path, childKey]
                                  : (NSString *)childKey;
        [queue addObject:@[ childKey, childValue ?: [NSNull null], childPath ]];
      }];
    } else if ([value isKindOfClass:NSArray.class]) {
      NSArray *array = (NSArray *)value;
      NSUInteger limit = MIN(array.count, kRFMaxArrayProbe);
      for (NSUInteger i = 0; i < limit; i++) {
        NSString *childPath = [NSString stringWithFormat:@"%@[%lu]", path, (unsigned long)i];
        [queue addObject:@[ [NSNull null], array[i] ?: [NSNull null], childPath ]];
      }
    }
  }
  return nil;
}

+ (NSInteger)depthOfPath:(NSString *)path {
  if (path.length == 0) return 0;
  NSInteger depth = 1;
  NSUInteger length = path.length;
  for (NSUInteger i = 0; i < length; i++) {
    unichar c = [path characterAtIndex:i];
    if (c == '.' || c == '[') depth++;
  }
  return depth;
}

@end

