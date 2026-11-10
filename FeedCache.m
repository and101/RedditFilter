// FeedCache.m
//
// When iOS closes Reddit in the background, it starts again from the top of Home. So the pages of
// Home's feeds (For You, Following, Popular) are kept, and when the app goes to the background the
// post at the top of each feed (and how far into it you'd scrolled) is noted and everything is saved.
// Each feed's first page after the next launch is then the kept feed, followed by the fresh page's own
// posts, and FeedPosition.x scrolls back to the noted post once it's on screen. Paging carries on from the fresh page, so nothing depends on
// an old page cursor still working, and pull to refresh at the top refreshes as usual.
//
// Every lookup is type-checked, so a changed response can only mean nothing is restored.

#import "FeedCache.h"
#import <os/lock.h>
#import <stdatomic.h>

static NSString *const kRFCacheAccount = @"account";
static NSString *const kRFCacheKey = @"key"; // a community feed: "name|SORT", name lowercased
static NSString *const kRFCacheCursor = @"cursor"; // the next page's cursor
static NSString *const kRFCacheEdges = @"edges";
static NSString *const kRFCachePosition = @"position"; // post at the top of the screen when left
static NSString *const kRFCacheOffset = @"offset"; // how far into that post you'd scrolled (points)
static NSString *const kRFCacheLeftAt = @"leftAt"; // when the app went to the background (seconds since 1970)

// Enough for a long scroll, small enough to save quickly (a post card is a few KB).
static const NSUInteger kRFCacheMaxEdges = 300;

static NSDictionary *RFDict(id value) { return [value isKindOfClass:NSDictionary.class] ? value : nil; }
static NSArray *RFArray(id value) { return [value isKindOfClass:NSArray.class] ? value : nil; }
static NSString *RFString(id value) { return [value isKindOfClass:NSString.class] ? value : nil; }
static BOOL RFTrue(id value) { return [value isKindOfClass:NSNumber.class] && [value boolValue]; }

static id RFJSON(NSData *data, NSJSONReadingOptions options) {
  return data.length ? [NSJSONSerialization JSONObjectWithData:data options:options error:NULL] : nil;
}

#pragma mark - Building blocks

static NSString *RFBase64URLDecoded(NSString *text) {
  NSString *base64 = [[text stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
      stringByReplacingOccurrencesOfString:@"_"
                                withString:@"/"];
  while (base64.length % 4) base64 = [base64 stringByAppendingString:@"="];
  NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

NSString *RFFeedAccount(NSURLRequest *request) {
  // "Bearer <JWT>": its "lid" is the account (t2_...), or the logged-out ID.
  NSString *token = [[request valueForHTTPHeaderField:@"Authorization"] componentsSeparatedByString:@" "].lastObject;
  NSArray *parts = [token componentsSeparatedByString:@"."];
  if (parts.count == 3) {
    NSString *claims = RFBase64URLDecoded(parts[1]);
    NSString *lid = RFString(RFDict(RFJSON([claims dataUsingEncoding:NSUTF8StringEncoding], 0))[@"lid"]);
    if (lid.length) return lid;
  }
  NSString *loid = [request valueForHTTPHeaderField:@"x-reddit-loid"];
  return loid.length ? loid : nil;
}

// The kind of login token a request carries: "user" (logged in) or "loid" (logged out, or incognito).
static NSString *RFTokenKind(NSString *authorization) {
  NSArray *parts = [[authorization componentsSeparatedByString:@" "].lastObject componentsSeparatedByString:@"."];
  if (parts.count != 3) return nil;
  NSString *claims = RFBase64URLDecoded(parts[1]);
  return RFString(RFDict(RFJSON([claims dataUsingEncoding:NSUTF8StringEncoding], 0))[@"sub"]);
}

static NSMutableDictionary *RFFeedElements(NSDictionary *json) {
  for (id root in RFDict(json[@"data"]).allValues) {
    NSDictionary *elements = RFDict(RFDict(root)[@"elements"]);
    if (RFArray(elements[@"edges"])) return [elements isKindOfClass:NSMutableDictionary.class] ? (id)elements : nil;
  }
  return nil;
}

// Ads would be counted again, and hidden posts take no space, so neither is kept.
static BOOL RFIsKeptEdge(id edge) {
  NSDictionary *node = RFDict(RFDict(edge)[@"node"]);
  if (!node) return NO;
  NSString *type = RFString(node[@"__typename"]);
  if ([type isEqualToString:@"AdPost"] || RFDict(node[@"adPayload"]) || RFTrue(node[@"isHidden"])) return NO;
  NSArray *cells = RFArray(node[@"cells"]);
  return !([type isEqualToString:@"CellGroup"] && cells && cells.count == 0);
}

// The post a feed card shows (t3_...): its groupId, or the start of its base64 ID ("t3_abc-...").
static NSString *RFEdgePostId(id edge) {
  NSDictionary *node = RFDict(RFDict(edge)[@"node"]);
  NSString *group = RFString(node[@"groupId"]);
  if ([group hasPrefix:@"t3_"]) return group;
  NSString *identifier = RFString(node[@"id"]);
  if (!identifier) return nil;
  NSData *decoded = [[NSData alloc] initWithBase64EncodedString:identifier options:0];
  NSString *text = decoded ? [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding] : identifier;
  NSString *postId = [text componentsSeparatedByString:@"-"].firstObject;
  return [postId hasPrefix:@"t3_"] ? postId : nil;
}

// A card's title (its TitleCell, or its post's title) and community ("r/..."), as its accessibility label shows them.
static void RFFindTitle(id object, NSString **title, NSString **community) {
  if (*title && *community) return;
  if (RFArray(object)) {
    for (id item in object) RFFindTitle(item, title, community);
    return;
  }
  NSDictionary *dict = RFDict(object);
  if (!dict) return;
  NSString *type = RFString(dict[@"__typename"]);
  if (!*title && [type isEqualToString:@"TitleCell"]) *title = RFString(dict[@"title"]);
  // Newer cards (PostPreviewComponent, in Following) carry the post itself: SubredditPost, ProfilePost.
  if (!*title && [type hasSuffix:@"Post"] && RFString(dict[@"title"])) {
    *title = RFString(dict[@"title"]);
    if (!*community) *community = RFString(RFDict(dict[@"subreddit"])[@"prefixedName"]);
  }
  if (!*community) *community = RFString(dict[@"subredditName"]);
  for (id value in dict.allValues)
    if (RFDict(value) || RFArray(value)) RFFindTitle(value, title, community);
}

static NSString *RFSquashed(NSString *text) {
  // Runs for every visible card on each frame while scrolling back, so no predicate parsing.
  NSMutableArray<NSString *> *kept = [NSMutableArray array];
  for (NSString *word in [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet])
    if (word.length) [kept addObject:word];
  return [kept componentsJoinedByString:@" "];
}

// What a card's label is matched on, worked out once per card: @[title, community] (squashed), or NSNull
// for a card that isn't a post.
static NSArray *RFEdgeDescriptors(NSArray *edges) {
  NSMutableArray *descriptors = [NSMutableArray arrayWithCapacity:edges.count];
  for (id edge in edges) {
    NSString *title = nil, *community = nil;
    if (RFEdgePostId(edge)) RFFindTitle(RFDict(edge)[@"node"], &title, &community);
    title = RFSquashed(title);
    [descriptors addObject:title.length ? @[ title, community ?: @"" ] : NSNull.null];
  }
  return descriptors;
}

static BOOL RFLabelShowsDescriptor(NSString *label, id descriptor) {
  NSArray *parts = RFArray(descriptor);
  if (!parts) return NO;
  NSString *title = parts[0], *community = parts[1];
  NSStringCompareOptions options = NSCaseInsensitiveSearch;
  if ([label rangeOfString:title options:options].location == NSNotFound) return NO;
  // A community's own feed leaves its name out of the labels ("author, 9h, title, ...").
  if (!community.length || [label rangeOfString:@"r/"].location == NSNotFound) return YES;
  return [label rangeOfString:community options:options].location != NSNotFound;
}

NSDictionary *RFFeedCacheAddingPage(NSDictionary *cache, NSString *account, NSString *after, NSData *page) {
  if (!account.length) return nil;
  NSDictionary *elements = RFFeedElements(RFJSON(page, NSJSONReadingMutableContainers));
  if (!elements) return nil;
  NSMutableArray *edges;
  NSMutableDictionary *updated;
  if (!after) {
    updated = [NSMutableDictionary dictionaryWithObject:account forKey:kRFCacheAccount];
    edges = [NSMutableArray array];
  } else {
    if (![RFString(cache[kRFCacheAccount]) isEqualToString:account] ||
        ![RFString(cache[kRFCacheCursor]) isEqualToString:after])
      return nil;
    updated = [cache mutableCopy];
    edges = [RFArray(cache[kRFCacheEdges]) mutableCopy] ?: [NSMutableArray array];
  }
  for (id edge in RFArray(elements[@"edges"]))
    if (RFIsKeptEdge(edge)) [edges addObject:edge];
  if (edges.count > kRFCacheMaxEdges) [edges removeObjectsInRange:NSMakeRange(0, edges.count - kRFCacheMaxEdges)];
  updated[kRFCacheEdges] = edges;
  NSDictionary *pageInfo = RFDict(elements[@"pageInfo"]);
  NSString *cursor = RFTrue(pageInfo[@"hasNextPage"]) ? RFString(pageInfo[@"endCursor"]) : nil;
  if (cursor) updated[kRFCacheCursor] = cursor;
  else [updated removeObjectForKey:kRFCacheCursor];
  return updated;
}

// The first card a label belongs to, or NSNotFound.
static NSUInteger RFDescriptorIndexForLabel(NSArray *descriptors, NSString *label) {
  NSString *squashed = RFSquashed(RFString(label));
  if (!squashed.length) return NSNotFound;
  for (NSUInteger i = 0; i < descriptors.count; i++)
    if (RFLabelShowsDescriptor(squashed, descriptors[i])) return i;
  return NSNotFound;
}

static NSArray *RFMatchingPosts(NSArray *edges, NSArray *descriptors, NSArray<NSString *> *labels) {
  NSMutableArray *posts = [NSMutableArray array];
  for (NSString *label in labels) {
    NSUInteger index = RFDescriptorIndexForLabel(descriptors, label);
    [posts addObject:index == NSNotFound ? NSNull.null : RFEdgePostId(edges[index])];
  }
  return posts;
}

NSArray *RFFeedCacheMatchingPosts(NSDictionary *cache, NSArray<NSString *> *labels) {
  NSArray *edges = RFArray(cache[kRFCacheEdges]);
  return RFMatchingPosts(edges, RFEdgeDescriptors(edges), labels);
}

NSDictionary *RFFeedCacheLeftAt(NSDictionary *cache, NSString *postId, double offset, NSDate *date) {
  NSMutableDictionary *updated = [cache mutableCopy];
  if (postId) {
    updated[kRFCachePosition] = postId;
    updated[kRFCacheOffset] = @(offset);
  } else {
    [updated removeObjectForKey:kRFCachePosition];
    [updated removeObjectForKey:kRFCacheOffset];
  }
  updated[kRFCacheLeftAt] = @(date.timeIntervalSince1970);
  return updated;
}

NSData *RFFeedReplayPage(NSDictionary *cache, NSData *freshPage, NSArray **keptEdges, NSUInteger *positionIndex) {
  NSString *position = RFString(cache[kRFCachePosition]);
  NSArray *kept = RFArray(cache[kRFCacheEdges]);
  if (!position || !kept.count) return nil;

  // Each post once (the server can send one again on a later page), so the app's list stays sane.
  NSMutableArray *edges = [NSMutableArray array];
  NSMutableSet *shown = [NSMutableSet set];
  NSUInteger start = NSNotFound;
  for (id edge in kept) {
    NSString *postId = RFEdgePostId(edge);
    if (postId && [shown containsObject:postId]) continue;
    if (postId) [shown addObject:postId];
    if (start == NSNotFound && [postId isEqualToString:position]) start = edges.count;
    [edges addObject:edge];
  }
  if (start == NSNotFound) return nil;

  NSMutableDictionary *json = RFJSON(freshPage, NSJSONReadingMutableContainers);
  NSMutableDictionary *elements = RFFeedElements(json);
  if (!elements) return nil;
  NSArray *replayedKept = [edges copy];
  for (id edge in RFArray(elements[@"edges"])) {
    NSString *postId = RFEdgePostId(edge);
    if (!postId || ![shown containsObject:postId]) [edges addObject:edge];
  }
  elements[@"edges"] = edges;
  // A community pages by post (its cursor names the last post), so it carries on after the kept posts.
  // From the fresh page's cursor, the next pages would be posts already kept, and Reddit can take a page
  // with nothing new as the end of the feed. Home's cursors aren't kept for later, so they page on fresh.
  NSString *keptCursor = RFString(cache[kRFCacheCursor]);
  NSMutableDictionary *pageInfo = (NSMutableDictionary *)RFDict(elements[@"pageInfo"]); // mutable: read with mutable containers
  if (RFString(cache[kRFCacheKey]) && keptCursor && [pageInfo isKindOfClass:NSMutableDictionary.class]) {
    pageInfo[@"endCursor"] = keptCursor;
    pageInfo[@"hasNextPage"] = @YES;
  }
  NSData *page = [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL];
  if (page && keptEdges) *keptEdges = replayedKept;
  if (page && positionIndex) *positionIndex = start;
  return page;
}

#pragma mark - Comments

NSArray<NSDictionary *> *RFCommentRows(NSData *response) {
  NSDictionary *forest = RFDict(RFDict(RFDict(RFDict(RFJSON(response, 0))[@"data"])[@"postInfoById"])[@"commentForest"]);
  NSArray *trees = RFArray(forest[@"trees"]);
  if (!trees) return nil;
  NSMutableArray *rows = [NSMutableArray array];
  for (id tree in trees) {
    NSDictionary *row = RFDict(tree);
    NSNumber *depth = [row[@"depth"] isKindOfClass:NSNumber.class] ? row[@"depth"] : @0;
    NSDictionary *node = RFDict(row[@"node"]);
    NSString *identifier = RFString(node[@"id"]);
    if (RFDict(row[@"more"]) || ![identifier hasPrefix:@"t1_"]) {
      [rows addObject:@{@"more" : @YES, @"depth" : depth}];
      continue;
    }
    NSString *author = RFString(RFDict(node[@"authorInfo"])[@"displayName"]) ?: @"";
    [rows addObject:@{@"id" : identifier, @"author" : author, @"depth" : depth}];
  }
  return rows;
}

// The row nearest `near` by one of `authors` (at `depth`, unless that's -1).
static NSUInteger RFNearestCommentRow(NSArray<NSDictionary *> *rows, NSSet<NSString *> *authors, NSInteger depth,
                                      NSUInteger near) {
  NSUInteger best = NSNotFound, bestGap = NSUIntegerMax;
  for (NSUInteger i = 0; i < rows.count; i++) {
    NSDictionary *row = rows[i];
    NSString *author = row[@"author"];
    if (!author.length || ![authors containsObject:author]) continue;
    if (depth >= 0 && [row[@"depth"] integerValue] != depth) continue;
    NSUInteger gap = near == NSNotFound ? 0 : (i > near ? i - near : near - i);
    if (gap >= bestGap) continue;
    best = i;
    bestGap = gap;
  }
  return best;
}

// The author and level in an English comment label ("By <author>, <age>, <votes>, Level <n>[, ...]").
static BOOL RFParseCommentLabel(NSString *label, NSString **author, NSInteger *depth) {
  if (![label hasPrefix:@"By "]) return NO;
  NSRange comma = [label rangeOfString:@", "];
  if (comma.location == NSNotFound) return NO;
  NSRange level = [label rangeOfString:@", Level "];
  if (level.location == NSNotFound) return NO;
  NSInteger value = [[label substringFromIndex:NSMaxRange(level)] integerValue] - 1;
  if (value < 0) return NO;
  if (author) *author = [label substringWithRange:NSMakeRange(3, comma.location - 3)];
  if (depth) *depth = value;
  return YES;
}

NSUInteger RFCommentRowForLabel(NSArray<NSDictionary *> *rows, NSString *label, NSUInteger near) {
  NSString *author = nil;
  NSInteger depth = -1;
  if (!RFParseCommentLabel(label, &author, &depth)) return NSNotFound;
  return RFNearestCommentRow(rows, [NSSet setWithObject:author], depth, near);
}

NSUInteger RFCommentRowForCell(NSArray<NSDictionary *> *rows, NSArray<NSString *> *texts, NSArray<NSString *> *words,
                               NSString *label, NSUInteger near) {
  NSInteger depth = -1;
  RFParseCommentLabel(label, NULL, &depth);
  // The username label first: words of the description can include other people's names (in the text).
  NSUInteger row = texts.count ? RFNearestCommentRow(rows, [NSSet setWithArray:texts], depth, near) : NSNotFound;
  if (row == NSNotFound && words.count) row = RFNearestCommentRow(rows, [NSSet setWithArray:words], depth, near);
  return row != NSNotFound ? row : RFCommentRowForLabel(rows, label, near);
}

#pragma mark - The kept feeds

// One per feed, in the order of kRFFeeds. Guarded by gLock.
typedef struct {
  NSDictionary *cache;
  BOOL loaded, replayTried;
  NSArray *restoreEdges; // the kept posts as replayed, until the scroll back is done
  NSArray *restoreDescriptors; // what their labels are matched on
  NSArray *matchesFor;           // the descriptors `matches` belongs to
  NSMutableDictionary<NSString *, NSNumber *> *matches; // label -> index found (labels repeat every frame)
  NSUInteger restoreIndex;
  double restoreOffset;
  NSString *armedName; // community feed: replays only the community the restore opens (lowercased)
} RFFeedState;

static const struct {
  NSString *operation, *file;
} kRFFeeds[] = {
    {@"HomeFeedSdui", @"HomeFeed.json"},       // For You
    {@"FollowingFeed", @"FollowingFeed.json"}, // Following
    {@"PopularFeedSdui", @"PopularFeed.json"}, // Popular
    {@"SubredditFeedSdui", @"CommunityFeed.json"}, // the last community opened (Restore open community and post)
};
static const NSInteger kRFCommunityFeed = 3;
enum { kRFFeedCount = sizeof(kRFFeeds) / sizeof(kRFFeeds[0]) };

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static RFFeedState gFeeds[kRFFeedCount];
static NSString *gDirectory; // guarded by gLock
static atomic_bool gEnabled, gKeepsCommunities, gColdReplayAllowed;
static atomic_bool gIncognito, gSawUserToken;
// Goes up whenever what's kept is thrown away (turned off, forgotten, another account): a save or a page
// from before that is dropped instead of bringing it back.
static atomic_uint gGeneration;
static NSString *gLastAuthorization; // guarded by gLock
static NSString *gCurrentAccount;    // guarded by gLock

NSNotificationName const RFFeedCacheAccountDidChangeNotification = @"RFFeedCacheAccountDidChangeNotification";
static _Atomic double gMaxAge = 12 * 60 * 60; // after this long away the feeds start fresh; 0 = no limit

NSNotificationName const RFFeedCacheDidReplayNotification = @"RFFeedCacheDidReplayNotification";

static NSInteger RFFeedIndex(NSString *operation) {
  for (NSInteger i = 0; i < kRFFeedCount; i++)
    if ([kRFFeeds[i].operation isEqualToString:operation]) return i;
  return -1;
}

BOOL RFFeedCacheKeepsOperation(NSString *operation) {
  NSInteger feed = operation ? RFFeedIndex(operation) : -1;
  return feed >= 0 && (feed != kRFCommunityFeed || atomic_load(&gKeepsCommunities));
}

static dispatch_queue_t RFFeedCacheQueue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("RedditFilter.FeedCache", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

// Call with gLock held.
static NSString *RFFeedCachePathLocked(NSInteger feed) {
  if (!gDirectory) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    gDirectory = [caches stringByAppendingPathComponent:@"RedditFilter"];
  }
  return [gDirectory stringByAppendingPathComponent:kRFFeeds[feed].file];
}

// Call with gLock held. Reads the saved feed the first time it's needed.
static NSDictionary *RFFeedCacheLocked(NSInteger feed) {
  if (!gFeeds[feed].loaded) {
    gFeeds[feed].loaded = YES;
    gFeeds[feed].cache = RFDict(RFJSON([NSData dataWithContentsOfFile:RFFeedCachePathLocked(feed)], 0));
  }
  return gFeeds[feed].cache;
}

// Saves (or with nil, removes) a kept feed, in order with every other save. A save from an earlier
// generation is dropped (a removal always happens).
static void RFFeedCacheWrite(NSDictionary *cache, NSString *path, unsigned generation, void (^completion)(void)) {
  dispatch_async(RFFeedCacheQueue(), ^{
    NSFileManager *fm = NSFileManager.defaultManager;
    if (cache && generation != atomic_load(&gGeneration)) {
      if (completion) completion();
      return;
    }
    NSData *data = cache ? [NSJSONSerialization dataWithJSONObject:cache options:0 error:NULL] : nil;
    if (data) {
      [fm createDirectoryAtPath:path.stringByDeletingLastPathComponent
          withIntermediateDirectories:YES
                           attributes:nil
                                error:NULL];
      [data writeToFile:path options:NSDataWritingAtomic error:NULL];
    } else if ([fm fileExistsAtPath:path]) {
      [fm removeItemAtPath:path error:NULL];
    }
    if (completion) completion();
  });
}

// Settings are applied again whenever any of them changes: what's kept is only forgotten when this one
// actually goes off (or is off from the start), so an in-flight page isn't dropped for nothing.
static atomic_bool gEnabledSet, gKeepsCommunitiesSet;

void RFFeedCacheSetEnabled(BOOL enabled) {
  BOOL was = atomic_exchange(&gEnabled, enabled);
  BOOL first = !atomic_exchange(&gEnabledSet, YES);
  if (enabled || (!was && !first)) return;
  // Off: forget the kept feeds.
  NSMutableArray *paths = [NSMutableArray array];
  os_unfair_lock_lock(&gLock);
  atomic_fetch_add(&gGeneration, 1);
  for (NSInteger feed = 0; feed < kRFFeedCount; feed++) {
    gFeeds[feed].cache = nil;
    gFeeds[feed].restoreEdges = nil;
    gFeeds[feed].restoreDescriptors = nil;
    gFeeds[feed].loaded = YES;
    [paths addObject:RFFeedCachePathLocked(feed)];
  }
  os_unfair_lock_unlock(&gLock);
  for (NSString *path in paths) RFFeedCacheWrite(nil, path, 0, nil);
}

BOOL RFFeedCacheEnabled(void) { return atomic_load(&gEnabled); }

NSNotificationName const RFFeedCacheDidForgetNotification = @"RFFeedCacheDidForgetNotification";

void RFFeedCacheForget(void) {
  NSMutableArray *paths = [NSMutableArray array];
  os_unfair_lock_lock(&gLock);
  atomic_fetch_add(&gGeneration, 1);
  for (NSInteger feed = 0; feed < kRFFeedCount; feed++) {
    gFeeds[feed].cache = nil;
    gFeeds[feed].restoreEdges = nil; // a scroll back still due would use the forgotten posts
    gFeeds[feed].restoreDescriptors = nil;
    gFeeds[feed].loaded = YES;
    [paths addObject:RFFeedCachePathLocked(feed)];
  }
  os_unfair_lock_unlock(&gLock);
  for (NSString *path in paths) RFFeedCacheWrite(nil, path, 0, nil);
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSNotificationCenter.defaultCenter postNotificationName:RFFeedCacheDidForgetNotification object:nil];
  });
}

unsigned RFFeedCacheGeneration(void) { return atomic_load(&gGeneration); }

// Requests made as whoever's using the app: the feeds and a post's comments. (Others, like experiments,
// carry a logged-out token even when logged in.)
static BOOL RFIsAccountOperation(NSString *operation) {
  return RFFeedIndex(operation) >= 0 || [operation isEqualToString:@"PostInfoByIdComments"];
}

void RFFeedCacheNoteRequest(NSString *operation, NSURLRequest *request) {
  if (!RFIsAccountOperation(operation)) return;
  NSString *authorization = [request valueForHTTPHeaderField:@"Authorization"];
  if (!authorization.length) return;
  // Only as requests are made, never when their replies come (a reply from before incognito mustn't end it).
  // Incognito starts from a logged-in app and ends when the app's closed, so a logged-out token after a
  // logged-in one in the same run is incognito (or logging out, which is treated the same until the next
  // launch). Back to a logged-in token ends it.
  NSString *previous = nil, *account = nil;
  BOOL startedIncognito = NO;
  os_unfair_lock_lock(&gLock);
  if (![gLastAuthorization isEqualToString:authorization]) {
    gLastAuthorization = [authorization copy];
    NSString *kind = RFTokenKind(authorization);
    if ([kind isEqualToString:@"user"]) {
      atomic_store(&gSawUserToken, YES);
      atomic_store(&gIncognito, NO);
    } else if ([kind isEqualToString:@"loid"] && atomic_load(&gSawUserToken)) {
      startedIncognito = !atomic_exchange(&gIncognito, YES);
      if (startedIncognito) atomic_fetch_add(&gGeneration, 1); // replies from before don't restore anything
    }
    account = atomic_load(&gIncognito) ? nil : RFFeedAccount(request);
    if (account && ![account isEqualToString:gCurrentAccount]) {
      previous = gCurrentAccount;
      gCurrentAccount = account;
    }
    if (previous) atomic_fetch_add(&gGeneration, 1);
  }
  os_unfair_lock_unlock(&gLock);
  // Another account (or logged out), or incognito: what's kept or due to be restored mustn't show here.
  if (previous || startedIncognito)
    dispatch_async(dispatch_get_main_queue(), ^{
      [NSNotificationCenter.defaultCenter postNotificationName:RFFeedCacheAccountDidChangeNotification object:account];
    });
}

BOOL RFFeedCacheRequestIsIncognito(NSURLRequest *request) {
  NSString *kind = RFTokenKind([request valueForHTTPHeaderField:@"Authorization"]);
  return [kind isEqualToString:@"loid"] && atomic_load(&gSawUserToken);
}

NSString *RFFeedCacheCurrentAccount(void) {
  os_unfair_lock_lock(&gLock);
  NSString *account = gCurrentAccount;
  os_unfair_lock_unlock(&gLock);
  return account;
}

BOOL RFFeedCacheIncognito(void) { return atomic_load(&gIncognito); }

void RFFeedCacheSetMaxAge(NSTimeInterval maxAge) { atomic_store(&gMaxAge, maxAge > 0 ? maxAge : 0); }

void RFFeedCacheSetColdReplayAllowed(BOOL allowed) { atomic_store(&gColdReplayAllowed, allowed); }

void RFFeedCacheSetKeepsCommunities(BOOL keeps) {
  BOOL was = atomic_exchange(&gKeepsCommunities, keeps);
  BOOL first = !atomic_exchange(&gKeepsCommunitiesSet, YES);
  if (keeps || (!was && !first)) return;
  os_unfair_lock_lock(&gLock);
  atomic_fetch_add(&gGeneration, 1);
  gFeeds[kRFCommunityFeed].cache = nil;
  gFeeds[kRFCommunityFeed].restoreEdges = nil;
  gFeeds[kRFCommunityFeed].loaded = YES;
  NSString *path = RFFeedCachePathLocked(kRFCommunityFeed);
  os_unfair_lock_unlock(&gLock);
  RFFeedCacheWrite(nil, path, 0, nil);
}

void RFFeedCacheArmCommunity(NSString *name) {
  os_unfair_lock_lock(&gLock);
  gFeeds[kRFCommunityFeed].armedName = name.lowercaseString;
  gFeeds[kRFCommunityFeed].replayTried = NO;
  os_unfair_lock_unlock(&gLock);
}

NSString *RFFeedCacheCommunity(NSString **sort) {
  os_unfair_lock_lock(&gLock);
  NSString *key = RFString(RFFeedCacheLocked(kRFCommunityFeed)[kRFCacheKey]);
  os_unfair_lock_unlock(&gLock);
  NSArray *parts = [key componentsSeparatedByString:@"|"];
  if (parts.count != 2) return nil;
  if (sort) *sort = parts[1];
  return parts[0];
}

void RFFeedCacheSetDirectory(NSString *directory) {
  os_unfair_lock_lock(&gLock);
  gDirectory = [directory copy];
  for (NSInteger feed = 0; feed < kRFFeedCount; feed++) gFeeds[feed] = (RFFeedState){0};
  gLastAuthorization = nil;
  gCurrentAccount = nil;
  atomic_fetch_add(&gGeneration, 1);
  os_unfair_lock_unlock(&gLock);
  atomic_store(&gIncognito, NO);
  atomic_store(&gSawUserToken, NO);
}

NSData *RFFeedCachePageFrom(NSString *operation, NSURLRequest *request, NSData *page, unsigned generation);

NSData *RFFeedCachePage(NSString *operation, NSURLRequest *request, NSData *page) {
  return RFFeedCachePageFrom(operation, request, page, RFFeedCacheGeneration());
}

NSData *RFFeedCachePageFrom(NSString *operation, NSURLRequest *request, NSData *page, unsigned generation) {
  NSInteger feed = RFFeedIndex(operation);
  if (feed < 0 || !RFFeedCacheEnabled() || !page.length) return nil;
  // Asked for before what was kept was thrown away (filters changed, another account): not used.
  if (generation != RFFeedCacheGeneration()) return nil;
  // Incognito keeps nothing (and leaves what was kept before it alone): judged by this page's own request,
  // as it may have been asked for before or after incognito started.
  if (RFFeedCacheRequestIsIncognito(request)) return nil;
  NSString *account = RFFeedAccount(request);
  if (!account) return nil;
  NSDictionary *variables = RFDict(RFDict(RFJSON(request.HTTPBody, 0))[@"variables"]);
  if (!variables) return nil;
  NSString *after = RFString(variables[@"after"]);
  // A community feed is kept for one community and sort at a time.
  NSString *key = nil;
  if (feed == kRFCommunityFeed) {
    NSString *name = RFString(variables[@"subredditName"]).lowercaseString;
    if (!name.length) return nil;
    key = [NSString stringWithFormat:@"%@|%@", name, RFString(variables[@"sort"]) ?: @""];
  }

  os_unfair_lock_lock(&gLock);
  NSDictionary *cache = RFFeedCacheLocked(feed);
  // Only the feed's first page in this run of the app: pull to refresh asks for the same thing and
  // should refresh.
  BOOL replay = !after && !gFeeds[feed].replayTried;
  if (!after) gFeeds[feed].replayTried = YES;
  if (feed == kRFCommunityFeed) {
    // Only the community the restore opened, in the sort it was kept in.
    replay = replay && gFeeds[feed].armedName && [key hasPrefix:[gFeeds[feed].armedName stringByAppendingString:@"|"]] &&
             [RFString(cache[kRFCacheKey]) isEqualToString:key];
    if (!after) gFeeds[feed].armedName = nil;
  }
  os_unfair_lock_unlock(&gLock);

  NSData *replayed = nil;
  NSArray *keptEdges = nil;
  NSUInteger index = 0;
  if (replay && atomic_load(&gColdReplayAllowed) && [RFString(cache[kRFCacheAccount]) isEqualToString:account]) {
    NSNumber *leftAt = cache[kRFCacheLeftAt];
    NSTimeInterval away = [leftAt isKindOfClass:NSNumber.class] ? NSDate.date.timeIntervalSince1970 - leftAt.doubleValue : -1;
    double maxAge = atomic_load(&gMaxAge);
    if (away >= 0 && (maxAge == 0 || away < maxAge)) replayed = RFFeedReplayPage(cache, page, &keptEdges, &index);
  }
  if (replayed) {
    NSNumber *offset = cache[kRFCacheOffset];
    NSArray *descriptors = RFEdgeDescriptors(keptEdges);
    os_unfair_lock_lock(&gLock);
    // Thrown away meanwhile (another account, incognito, forgotten): no replay after all.
    if (generation != atomic_load(&gGeneration)) {
      os_unfair_lock_unlock(&gLock);
      return nil;
    }
    gFeeds[feed].restoreEdges = keptEdges;
    gFeeds[feed].restoreDescriptors = descriptors;
    gFeeds[feed].restoreIndex = index;
    gFeeds[feed].restoreOffset = [offset isKindOfClass:NSNumber.class] ? offset.doubleValue : 0;
    os_unfair_lock_unlock(&gLock);
    NSString *name = kRFFeeds[feed].operation;
    dispatch_async(dispatch_get_main_queue(), ^{
      [NSNotificationCenter.defaultCenter postNotificationName:RFFeedCacheDidReplayNotification object:name];
    });
  }
  if (after && feed == kRFCommunityFeed && ![RFString(cache[kRFCacheKey]) isEqualToString:key]) return replayed;
  NSMutableDictionary *updated = [RFFeedCacheAddingPage(cache, account, after, replayed ?: page) mutableCopy];
  if (!updated) return replayed;
  if (key) updated[kRFCacheKey] = key;

  os_unfair_lock_lock(&gLock);
  // A page that arrived meanwhile wins; this one is dropped from the kept feed (it's still shown). Turned
  // off meanwhile: nothing's kept.
  BOOL current = gFeeds[feed].cache == cache && RFFeedCacheEnabled() && generation == atomic_load(&gGeneration);
  if (current) gFeeds[feed].cache = updated;
  // A fresh start of the feed (pull to refresh, another account): a scroll back still due is out of date.
  if (!after && !replayed && generation == atomic_load(&gGeneration)) {
    gFeeds[feed].restoreEdges = nil;
    gFeeds[feed].restoreDescriptors = nil;
  }
  NSString *path = RFFeedCachePathLocked(feed);
  os_unfair_lock_unlock(&gLock);
  // Saved now too, so a crash before the next time the app's left doesn't bring the old place back.
  if (current && replay && cache[kRFCachePosition]) RFFeedCacheWrite(updated, path, generation, nil);
  return replayed;
}

NSArray<NSString *> *RFFeedCacheRestoringFeeds(void) {
  NSMutableArray *feeds = [NSMutableArray array];
  os_unfair_lock_lock(&gLock);
  for (NSInteger feed = 0; feed < kRFFeedCount; feed++)
    if (gFeeds[feed].restoreEdges) [feeds addObject:kRFFeeds[feed].operation];
  os_unfair_lock_unlock(&gLock);
  return feeds;
}

BOOL RFFeedCacheRestoreTarget(NSString *operation, NSUInteger *index, double *offset) {
  NSInteger feed = RFFeedIndex(operation);
  if (feed < 0) return NO;
  os_unfair_lock_lock(&gLock);
  BOOL pending = gFeeds[feed].restoreEdges != nil;
  if (index) *index = gFeeds[feed].restoreIndex;
  if (offset) *offset = gFeeds[feed].restoreOffset;
  os_unfair_lock_unlock(&gLock);
  return pending;
}

NSUInteger RFFeedCacheReplayedIndex(NSString *operation, NSString *label) {
  NSInteger feed = RFFeedIndex(operation);
  if (feed < 0) return NSNotFound;
  if (!label.length) return NSNotFound;
  os_unfair_lock_lock(&gLock);
  NSArray *descriptors = gFeeds[feed].restoreEdges ? gFeeds[feed].restoreDescriptors : nil;
  NSNumber *known = gFeeds[feed].matchesFor == descriptors ? gFeeds[feed].matches[label] : nil;
  os_unfair_lock_unlock(&gLock);
  if (!descriptors) return NSNotFound;
  if (known) return known.unsignedIntegerValue;
  // Each label is matched once against the replayed posts, not on every frame of the scroll back.
  NSUInteger index = RFDescriptorIndexForLabel(descriptors, label);
  os_unfair_lock_lock(&gLock);
  if (gFeeds[feed].restoreDescriptors == descriptors) {
    if (gFeeds[feed].matchesFor != descriptors) {
      gFeeds[feed].matchesFor = descriptors;
      gFeeds[feed].matches = [NSMutableDictionary dictionary];
    }
    gFeeds[feed].matches[label] = @(index);
  }
  os_unfair_lock_unlock(&gLock);
  return index;
}

void RFFeedCacheEndRestore(NSString *operation) {
  NSInteger feed = RFFeedIndex(operation);
  if (feed < 0) return;
  os_unfair_lock_lock(&gLock);
  gFeeds[feed].restoreEdges = nil;
  gFeeds[feed].restoreDescriptors = nil;
  gFeeds[feed].matchesFor = nil;
  gFeeds[feed].matches = nil;
  os_unfair_lock_unlock(&gLock);
}

static NSUInteger RFMatchCount(NSArray *posts) {
  NSUInteger count = 0;
  for (id post in posts) count += post != NSNull.null;
  return count;
}

void RFFeedCacheNoteLeaving(NSArray<NSArray<NSString *> *> *labelLists, NSArray<NSArray<NSNumber *> *> *offsetLists,
                            void (^completion)(void)) {
  if (!RFFeedCacheEnabled() || RFFeedCacheIncognito()) {
    if (completion) completion();
    return;
  }
  NSDictionary *caches[kRFFeedCount];
  os_unfair_lock_lock(&gLock);
  for (NSInteger feed = 0; feed < kRFFeedCount; feed++) caches[feed] = RFFeedCacheLocked(feed);
  os_unfair_lock_unlock(&gLock);

  // Each list on screen (another tab or a community can be open too) goes to the feed with the most of
  // its posts in it, best match first, so feeds that share posts don't take each other's list.
  NSUInteger listCount = labelLists.count;
  NSMutableArray *matches = [NSMutableArray array]; // [feed][list] -> posts
  for (NSInteger feed = 0; feed < kRFFeedCount; feed++) {
    NSMutableArray *row = [NSMutableArray array];
    NSArray *edges = RFArray(caches[feed][kRFCacheEdges]);
    NSArray *descriptors = edges.count && listCount ? RFEdgeDescriptors(edges) : nil;
    for (NSUInteger list = 0; list < listCount; list++)
      [row addObject:descriptors ? RFMatchingPosts(edges, descriptors, labelLists[list]) : @[]];
    [matches addObject:row];
  }
  NSInteger listOfFeed[kRFFeedCount];
  for (NSInteger feed = 0; feed < kRFFeedCount; feed++) listOfFeed[feed] = -1;
  NSMutableIndexSet *usedLists = [NSMutableIndexSet indexSet];
  for (;;) {
    NSUInteger best = 0;
    NSInteger bestFeed = -1, bestList = -1;
    for (NSInteger feed = 0; feed < kRFFeedCount; feed++) {
      if (listOfFeed[feed] >= 0) continue;
      for (NSUInteger list = 0; list < listCount; list++) {
        if ([usedLists containsIndex:list]) continue;
        NSUInteger count = RFMatchCount(matches[feed][list]);
        if (count <= best) continue;
        best = count;
        bestFeed = feed;
        bestList = (NSInteger)list;
      }
    }
    if (bestFeed < 0) break;
    listOfFeed[bestFeed] = bestList;
    [usedLists addIndex:bestList];
  }

  // A feed without a list on screen keeps what it had (say, a tab not opened since the last launch).
  dispatch_group_t saving = dispatch_group_create();
  NSDate *now = NSDate.date;
  for (NSInteger feed = 0; feed < kRFFeedCount; feed++) {
    NSInteger list = listOfFeed[feed];
    if (list < 0) continue;
    NSArray *posts = matches[feed][list];
    NSUInteger first = [posts indexOfObjectPassingTest:^BOOL(id post, NSUInteger i, BOOL *stop) {
      return post != NSNull.null;
    }];
    NSArray *offsets = (NSUInteger)list < offsetLists.count ? offsetLists[list] : nil;
    double offset = first < offsets.count ? [offsets[first] doubleValue] : 0;
    NSDictionary *updated = RFFeedCacheLeftAt(caches[feed], posts[first], offset, now);

    os_unfair_lock_lock(&gLock);
    if (gFeeds[feed].cache == caches[feed]) gFeeds[feed].cache = updated;
    else updated = nil; // a page arrived meanwhile: nothing to note until next time
    NSString *path = RFFeedCachePathLocked(feed);
    unsigned generation = atomic_load(&gGeneration);
    os_unfair_lock_unlock(&gLock);
    if (!updated) continue;
    dispatch_group_enter(saving);
    RFFeedCacheWrite(updated, path, generation, ^{
      dispatch_group_leave(saving);
    });
  }
  dispatch_group_notify(saving, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    if (completion) completion();
  });
}
