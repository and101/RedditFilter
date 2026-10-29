// JSONFilter.m
//
// Edits Reddit's GraphQL responses before the app sees them. See JSONFilter.h.
//
// Every lookup below is type-checked, so a JSON null (NSNull), a missing key,
// or a renamed key can never crash the app; the worst case is "nothing gets
// filtered" (which the debug menu will then show as a miss).

#import "JSONFilter.h"
#import "DebugMenu.h"

static NSString *const kAutoModAccountId = @"t2_6l4z3";

#pragma mark - Type-safe helpers

static NSDictionary *RFDict(id value) { return [value isKindOfClass:NSDictionary.class] ? value : nil; }
static NSMutableDictionary *RFMutableDict(id value) {
  return [value isKindOfClass:NSMutableDictionary.class] ? value : nil;
}
static NSArray *RFArray(id value) { return [value isKindOfClass:NSArray.class] ? value : nil; }
static NSString *RFString(id value) { return [value isKindOfClass:NSString.class] ? value : nil; }
static BOOL RFTrue(id value) { return [value isKindOfClass:NSNumber.class] && [value boolValue]; }

// Like -valueForKeyPath:, but only walks dictionaries and returns nil (instead
// of throwing) when it hits a null or a missing key.
static id RFValueAtPath(id root, NSString *path) {
  id value = root;
  for (NSString *key in [path componentsSeparatedByString:@"."]) {
    value = [RFDict(value) objectForKey:key];
    if (!value) return nil;
  }
  return value;
}

BOOL RFPrefsAnyEnabled(RFPrefs p) {
  return p.promoted || p.recommended || p.nsfw || p.awards || p.scores || p.automod || p.videosForYou || p.keywords ||
         p.redgifsDirect;
}

#pragma mark - Filtering single objects

typedef struct {
  RFPrefs prefs;
  NSRegularExpression *keywords; // nil when there are no keywords
} RFContext;

#pragma mark - Keywords

static NSString *RFFolded(NSString *text) {
  NSString *folded = [text stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch
                                               locale:nil];
  return [folded stringByReplacingOccurrencesOfString:@"\u2019" withString:@"'"]; // curly apostrophe
}

static NSRegularExpression *gKeywordRegex;
static NSObject *RFKeywordLock(void) {
  static NSObject *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ lock = [NSObject new]; });
  return lock;
}

static NSRegularExpression *RFCurrentKeywords(RFPrefs prefs) {
  if (!prefs.keywords) return nil;
  @synchronized(RFKeywordLock()) {
    return gKeywordRegex;
  }
}

void RFSetFilterKeywords(NSArray<NSString *> *keywords) {
  NSMutableArray *patterns = [NSMutableArray array];
  for (id keyword in keywords) {
    NSString *trimmed = [RFString(keyword) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) continue;
    // Any run of spaces in a phrase matches any whitespace in the post.
    NSArray *words = [RFFolded(trimmed) componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSMutableArray *escaped = [NSMutableArray array];
    for (NSString *word in words)
      if (word.length) [escaped addObject:[NSRegularExpression escapedPatternForString:word]];
    [patterns addObject:[escaped componentsJoinedByString:@"\\s+"]];
  }
  NSRegularExpression *regex = nil;
  if (patterns.count) {
    // Whole words: no letter or digit right before or after the keyword.
    NSString *pattern = [NSString stringWithFormat:@"(?<![\\p{L}\\p{N}])(?:%@)(?![\\p{L}\\p{N}])",
                                                   [patterns componentsJoinedByString:@"|"]];
    regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
  }
  @synchronized(RFKeywordLock()) {
    gKeywordRegex = regex;
  }
}

// Post text shown in a feed card: titles (also nested in thumbnail and ad cells)
// and the body preview.
static void RFCollectPostText(id object, NSMutableArray<NSString *> *texts) {
  if (RFArray(object)) {
    for (id item in object) RFCollectPostText(item, texts);
    return;
  }
  NSDictionary *dict = RFDict(object);
  if (!dict) return;
  NSString *title = RFString(dict[@"title"]);
  if (title) [texts addObject:title];
  if ([RFString(dict[@"__typename"]) isEqualToString:@"PreviewTextCell"] && RFString(dict[@"text"]))
    [texts addObject:dict[@"text"]];
  for (NSString *key in @[ @"titleCell", @"previewTextCell" ]) RFCollectPostText(dict[key], texts);
}

static BOOL RFTextsMatchKeywords(NSArray<NSString *> *texts, NSRegularExpression *regex) {
  for (NSString *text in texts) {
    NSString *folded = RFFolded(text);
    if ([regex firstMatchInString:folded options:0 range:NSMakeRange(0, folded.length)]) return YES;
  }
  return NO;
}

static BOOL RFMatchesKeywords(NSArray *cells, NSRegularExpression *regex) {
  NSMutableArray<NSString *> *texts = [NSMutableArray array];
  RFCollectPostText(cells, texts);
  return RFTextsMatchKeywords(texts, regex);
}

// Markdown links show their label, not where they go: "[here](https://example.com/cat)" -> "[here]".
static NSString *RFWithoutLinkTargets(NSString *markdown) {
  if (![markdown containsString:@"]("]) return markdown;
  static NSRegularExpression *regex;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // "](url)" or "](url "title")"
    regex = [NSRegularExpression regularExpressionWithPattern:@"\\]\\([^)\\s]*(?:\\s+\"[^\"]*\")?\\)" options:0 error:NULL];
  });
  return [regex stringByReplacingMatchesInString:markdown
                                         options:0
                                           range:NSMakeRange(0, markdown.length)
                                    withTemplate:@"]"];
}

// The full text of a post or comment: its title (posts only) and its whole body.
static BOOL RFContentMatchesKeywords(NSDictionary *node, NSRegularExpression *regex) {
  NSMutableArray<NSString *> *texts = [NSMutableArray array];
  NSString *title = RFString(node[@"title"]);
  if (title) [texts addObject:title];
  NSDictionary *content = RFDict(node[@"content"]);
  NSString *body = RFString(content[@"markdown"]) ?: RFString(content[@"preview"]);
  if (body) [texts addObject:RFWithoutLinkTargets(body)];
  return RFTextsMatchKeywords(texts, regex);
}

// New feed cards keep their NSFW marker in an IndicatorsCell, sometimes nested
// inside a title, thumbnail, or video cell.
static BOOL RFHasNSFWIndicator(id object) {
  NSDictionary *cell = RFDict(object);
  for (id value in @[ cell ?: @{}, RFDict(cell[@"indicatorsCell"]) ?: @{} ])
    for (id indicator in RFArray(RFDict(value)[@"indicators"])) {
      NSString *text = RFString(indicator);
      if (text && [text rangeOfString:@"nsfw" options:NSCaseInsensitiveSearch].location != NSNotFound)
        return YES;
    }
  return NO;
}

// Returns YES if it changed anything.
static BOOL RFFilterNode(id object, const RFContext *ctx) {
  NSMutableDictionary *node = RFMutableDict(object);
  NSString *type = RFString(node[@"__typename"]);
  if (!type) return NO;
  RFPrefs p = ctx->prefs;
  BOOL changed = NO;

  BOOL isPost = [type isEqualToString:@"SubredditPost"];
  if (isPost || [type isEqualToString:@"Comment"]) {
    if (p.awards) {
      node[@"awardings"] = @[];
      node[@"isGildable"] = @NO;
      changed = YES;
    }
    if (p.scores) {
      node[@"isScoreHidden"] = @YES;
      changed = YES;
    }
    if (isPost && p.nsfw && RFTrue(node[@"isNsfw"])) {
      node[@"isHidden"] = @YES;
      changed = YES;
    }
    if (!isPost && p.automod &&
        [RFString(RFDict(node[@"authorInfo"])[@"id"]) isEqualToString:kAutoModAccountId]) {
      node[@"isInitiallyCollapsed"] = @YES;
      changed = YES;
    }
    return changed;
  }

  if ([type isEqualToString:@"AdPost"]) {
    if (!p.promoted) return NO;
    node[@"isHidden"] = @YES;
    return YES;
  }

  if (![type isEqualToString:@"CellGroup"]) return NO;

  // Promoted: ads carry an adPayload. Emptying the cells hides the whole post.
  if (p.promoted && RFDict(node[@"adPayload"])) {
    node[@"cells"] = @[];
    return YES;
  }

  if (ctx->keywords && RFMatchesKeywords(RFArray(node[@"cells"]), ctx->keywords)) {
    node[@"cells"] = @[];
    return YES;
  }

  // Feed posts aren't checked for recommendations. Since 2026.43 the For You feed is
  // almost all recommendations (subscriptions moved to Following), so hiding them
  // emptied the feed and stopped it loading more pages.

  if (p.nsfw) {
    for (id cell in RFArray(node[@"cells"])) {
      if (!RFHasNSFWIndicator(cell)) continue;
      node[@"cells"] = @[];
      return YES;
    }
  }

  if (p.awards || p.scores) {
    for (id item in RFArray(node[@"cells"])) {
      NSMutableDictionary *cell = RFMutableDict(item);
      if (![RFString(cell[@"__typename"]) isEqualToString:@"ActionCell"]) continue;
      if (p.awards) {
        cell[@"isAwardHidden"] = @YES;
        [RFMutableDict(cell[@"goldenUpvoteInfo"]) setObject:@NO forKey:@"isGildable"];
      }
      if (p.scores) cell[@"isScoreHidden"] = @YES;
      changed = YES;
    }
  }
  return changed;
}

// An array of nodes, e.g. postsInfoByIds.
static BOOL RFFilterNodes(NSArray *nodes, const RFContext *ctx) {
  BOOL changed = NO;
  for (id node in nodes) changed |= RFFilterNode(node, ctx);
  return changed;
}

// The "Videos for you" carousel: a PostCarousel feed element of type VIDEO_RECOMMENDATIONS.
static BOOL RFIsVideosForYou(id node) {
  NSDictionary *carousel = RFDict(node);
  return [RFString(carousel[@"__typename"]) isEqualToString:@"PostCarousel"] &&
         [RFString(carousel[@"type"]) isEqualToString:@"VIDEO_RECOMMENDATIONS"];
}

// Some feed cards hold the whole post, title and full text included.
static BOOL RFIsKeywordPostPreview(id node, const RFContext *ctx) {
  NSDictionary *preview = RFDict(node);
  return ctx->keywords && [RFString(preview[@"__typename"]) isEqualToString:@"PostPreviewComponent"] &&
         RFContentMatchesKeywords(RFDict(preview[@"post"]), ctx->keywords);
}

// Swaps a feed element for an empty post card, the same thing the other filters leave behind for a
// hidden post. Removing the element, or emptying it in place, can stop the feed loading more posts.
static NSDictionary *RFEmptyCard(NSDictionary *element) {
  NSString *identifier = [@"redditfilter-" stringByAppendingString:RFString(element[@"id"]) ?: @"video_in_feed_unit"];
  return [@{
    @"__typename" : @"CellGroup",
    @"id" : identifier,
    @"groupId" : identifier,
    @"cells" : @[],
    @"adPayload" : NSNull.null,
    @"recommendationContext" : NSNull.null,
  } mutableCopy];
}

// An array of { node: ... } wrappers: feed edges and comment trees.
static BOOL RFFilterEdges(NSArray *edges, const RFContext *ctx) {
  BOOL changed = NO;
  for (id edge in edges) {
    NSMutableDictionary *wrapper = RFMutableDict(edge);
    if (wrapper && ((ctx->prefs.videosForYou && RFIsVideosForYou(wrapper[@"node"])) ||
                    RFIsKeywordPostPreview(wrapper[@"node"], ctx))) {
      wrapper[@"node"] = RFEmptyCard(wrapper[@"node"]);
      changed = YES;
      continue;
    }
    changed |= RFFilterNode(RFDict(edge)[@"node"], ctx);
  }
  return changed;
}

static NSString *const kRFHiddenCommentText = @"Hidden by keyword filter";

// Keeps the comment's place in the thread so its replies still show, but without its text or author.
static void RFMakePlaceholderComment(NSMutableDictionary *comment) {
  NSString *richtext = [NSString stringWithFormat:@"{\"document\":[{\"c\":[{\"e\":\"text\",\"t\":\"%@\"}],\"e\":\"par\"}]}",
                                                  kRFHiddenCommentText];
  NSMutableDictionary *content = [RFDict(comment[@"content"]) mutableCopy] ?: [NSMutableDictionary dictionary];
  [content addEntriesFromDictionary:@{
    @"markdown" : kRFHiddenCommentText,
    @"preview" : kRFHiddenCommentText,
    @"richtext" : richtext,
    @"richtextMedia" : @[],
  }];
  comment[@"content"] = content;
  comment[@"authorInfo"] = NSNull.null;
  comment[@"authorFlair"] = NSNull.null;
  comment[@"authorCommunityBadge"] = NSNull.null;
}

// Comments come as a flat list in display order, each with its depth. A hidden comment takes its
// replies with it, and the reply counts of the comments above it go down to match. With
// keywordCommentReplies off, it's swapped for a placeholder instead and its replies stay.
static BOOL RFHideKeywordComments(NSMutableDictionary *forest, const RFContext *ctx) {
  NSArray *trees = RFArray(forest[@"trees"]);
  if (!ctx->prefs.keywordComments || !ctx->keywords || !trees) return NO;
  NSMutableArray *kept = [NSMutableArray arrayWithCapacity:trees.count];
  NSMutableArray<NSMutableDictionary *> *parents = [NSMutableArray array]; // kept comments above this one
  NSInteger hiddenDepth = -1; // depth of the hidden comment whose replies are being skipped
  BOOL replaced = NO;
  for (id edge in trees) {
    NSMutableDictionary *tree = RFMutableDict(edge);
    id depthValue = tree[@"depth"];
    if (![depthValue isKindOfClass:NSNumber.class]) { // can't tell where it belongs: keep it
      [kept addObject:edge];
      hiddenDepth = -1;
      continue;
    }
    NSInteger depth = [depthValue integerValue];
    while (parents.count && [parents.lastObject[@"depth"] integerValue] >= depth) [parents removeLastObject];

    BOOL hide = hiddenDepth >= 0 && depth > hiddenDepth;
    if (!hide) {
      hiddenDepth = -1;
      NSDictionary *node = RFDict(tree[@"node"]);
      if ([RFString(node[@"__typename"]) isEqualToString:@"Comment"] &&
          RFContentMatchesKeywords(node, ctx->keywords)) {
        NSMutableDictionary *comment = RFMutableDict(node);
        if (!ctx->prefs.keywordCommentReplies && comment) {
          RFMakePlaceholderComment(comment);
          replaced = YES;
          [kept addObject:edge];
          [parents addObject:tree];
          continue;
        }
        hide = YES;
        hiddenDepth = depth;
      }
    }
    if (hide) {
      for (NSMutableDictionary *parent in parents) {
        id count = parent[@"childCount"];
        if ([count isKindOfClass:NSNumber.class] && [count integerValue] > 0)
          parent[@"childCount"] = @([count integerValue] - 1);
      }
      continue;
    }
    [kept addObject:edge];
    if (tree) [parents addObject:tree];
  }
  if (kept.count == trees.count) return replaced;
  forest[@"trees"] = kept;
  return YES;
}

static BOOL RFClearKeys(NSMutableDictionary *dict, NSArray *keys) {
  BOOL changed = NO;
  for (NSString *key in keys) {
    if (![dict objectForKey:key]) continue;
    [dict setObject:@[] forKey:key];
    changed = YES;
  }
  return changed;
}

// Older responses use an array; newer ones wrap adPosts in a PdpAds object.
// Keep the wrapper and pagination fields so Apollo can still decode the response.
static BOOL RFClearAdKeys(NSMutableDictionary *dict, NSArray *keys) {
  BOOL changed = NO;
  for (NSString *key in keys) {
    id ads = dict[key];
    if (RFArray(ads)) {
      dict[key] = @[];
      changed = YES;
    } else if (RFMutableDict(ads) && RFArray(ads[@"adPosts"])) {
      ads[@"adPosts"] = @[];
      changed = YES;
    }
  }
  return changed;
}

static BOOL RFFilterPostExtras(NSMutableDictionary *root, const RFContext *ctx) {
  BOOL changed = NO;
  NSMutableDictionary *components = RFMutableDict(RFValueAtPath(root, @"detailComponents.components"));
  NSArray *edges = RFArray(components[@"edges"]);
  if (ctx->prefs.recommended && edges) {
    NSArray *filtered = [edges filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id edge, NSDictionary *bindings) {
      return ![RFString(RFValueAtPath(edge, @"node.__typename")) isEqualToString:@"RelatedAnswersFeedUnit"];
    }]];
    if (filtered.count != edges.count) {
      components[@"edges"] = filtered;
      changed = YES;
    }
  }
  NSArray *highlights = RFArray(root[@"highlightedPosts"]);
  if (ctx->prefs.nsfw && highlights) {
    NSArray *filtered = [highlights filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id item, NSDictionary *bindings) {
      return !RFTrue(RFValueAtPath(item, @"post.isNsfw"));
    }]];
    if (filtered.count != highlights.count) {
      root[@"highlightedPosts"] = filtered;
      changed = YES;
    }
  }
  return changed;
}

#pragma mark - Filtering whole responses

// Schema-agnostic fallback for operations without a fast path, or when a fast
// path stops resolving (e.g. Reddit renames homeV3 to homeV4).
static BOOL RFFilterGeneric(NSDictionary *payload, const RFContext *ctx) {
  BOOL changed = NO;
  for (id root in payload.allValues) {
    if (RFArray(root)) {
      changed |= RFFilterNodes(root, ctx);
      continue;
    }
    NSMutableDictionary *dict = RFMutableDict(root);
    if (!dict) continue;

    // Feeds: <root>.<any key>.edges. Every key is checked because dictionary
    // order is random and nearly every object also has a __typename key.
    for (id child in dict.allValues) changed |= RFFilterEdges(RFArray(RFDict(child)[@"edges"]), ctx);

    // Comments: <root>.commentForest.trees
    changed |= RFFilterEdges(RFArray(RFValueAtPath(dict, @"commentForest.trees")), ctx);
    changed |= RFHideKeywordComments(RFMutableDict(dict[@"commentForest"]), ctx);

    if (ctx->prefs.promoted)
      changed |= RFClearAdKeys(dict, @[ @"commentsPageAds", @"commentTreeAds", @"pdpCommentsAds" ]);
    if (ctx->prefs.recommended) changed |= RFClearKeys(dict, @[ @"recommendations" ]);
    changed |= RFFilterPostExtras(dict, ctx);
  }
  return changed;
}

// Operations whose data lives in one fixed list. If the path stops resolving,
// the generic filter takes over and the debug menu records a miss.
typedef struct {
  __unsafe_unretained NSString *operation;
  __unsafe_unretained NSString *path;
  RFSchemaSig signature;
  BOOL isEdges; // YES: list of { node: ... }, NO: list of nodes
} RFFastPath;

static const RFFastPath kFastPaths[] = {
    {@"HomeFeedSdui", @"data.homeV3.elements.edges", RFSchemaSigEdges, YES},
    {@"PopularFeedSdui", @"data.popularV3.elements.edges", RFSchemaSigEdges, YES},
    {@"FeedPostDetailsByIds", @"data.postsInfoByIds", RFSchemaSigNodeArray, NO},
};

static BOOL RFFilterPostInfo(NSMutableDictionary *json, NSDictionary *payload, const RFContext *ctx) {
  id raw = payload[@"postInfoById"];
  if (raw == [NSNull null]) return NO; // deleted/removed post: nothing to do
  NSMutableDictionary *post = RFMutableDict(raw);
  id forest = post[@"commentForest"];
  NSArray *trees = RFArray(RFDict(forest)[@"trees"]);
  // A post with zero comments has no commentForest at all; that still counts as a hit.
  BOOL resolved = trees || (post && (!forest || forest == [NSNull null]));
  RF_RECORD_SCHEMA(@"PostInfoById", @"data.postInfoById.commentForest.trees", resolved, json, RFSchemaSigTrees);

  BOOL changed = resolved ? RFFilterEdges(trees, ctx) : RFFilterGeneric(payload, ctx);
  if (resolved) changed |= RFHideKeywordComments(RFMutableDict(forest), ctx);
  changed |= RFFilterNode(post, ctx);
  if (ctx->prefs.promoted)
    changed |= RFClearAdKeys(post, @[ @"commentsPageAds", @"commentTreeAds", @"pdpCommentsAds" ]);
  changed |= RFFilterPostExtras(post, ctx);
  return changed;
}

static BOOL RFFilterCommentAds(NSMutableDictionary *json, NSDictionary *payload, const RFContext *ctx) {
  NSMutableDictionary *container = nil;
  for (id value in payload.allValues) {
    NSMutableDictionary *dict = RFMutableDict(value);
    if ([dict objectForKey:@"pdpCommentsAds"]) {
      container = dict;
      break;
    }
  }
  RF_RECORD_SCHEMA(@"PdpCommentsAds", @"data.*.pdpCommentsAds", container != nil, json, RFSchemaSigCommentsAds);
  if (!ctx->prefs.promoted) return NO;
  if (!container) return RFFilterGeneric(payload, ctx);
  return RFClearAdKeys(container, @[ @"pdpCommentsAds" ]);
}

static BOOL RFFilterResponse(NSMutableDictionary *json, NSDictionary *payload, NSString *op, const RFContext *ctx) {
  for (size_t i = 0; i < sizeof(kFastPaths) / sizeof(kFastPaths[0]); i++) {
    const RFFastPath *fast = &kFastPaths[i];
    if (![op isEqualToString:fast->operation]) continue;
    NSArray *list = RFArray(RFValueAtPath(json, fast->path));
    RF_RECORD_SCHEMA(fast->operation, fast->path, list != nil, json, fast->signature);
    if (!list) return RFFilterGeneric(payload, ctx);
    return fast->isEdges ? RFFilterEdges(list, ctx) : RFFilterNodes(list, ctx);
  }
  if ([op isEqualToString:@"PostInfoById"] || [op isEqualToString:@"PostInfoByIdComments"])
    return RFFilterPostInfo(json, payload, ctx);
  if ([op isEqualToString:@"PdpCommentsAds"]) return RFFilterCommentAds(json, payload, ctx);
  return RFFilterGeneric(payload, ctx); // e.g. ProfileFeedSdui, HomeFeedSduiBg
}

// Telemetry and config calls that never contain posts: skip them before parsing.
static NSSet<NSString *> *RFIgnoredOperations(void) {
  static NSSet *set;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    set = [[NSSet alloc] initWithObjects:
        @"GetAccount", @"FetchIdentityPreferences", @"DynamicConfigsByNames",
        @"GetAllExperimentVariants", @"AdsOffRedditLocation", @"UserLocation",
        @"CookiePreferences", @"FetchSubscribedSubreddits", @"AdsOffRedditPreferences",
        @"Age", @"RecommendedPrompts", @"EnrollInGamification", @"BadgeCounts",
        @"GetEligibleUXExperiences", @"GetUserAdEligibility", @"GoldBalances",
        @"PaymentSubscriptions", @"FeaturedDevvitGame", @"ModQueueNewItemCount",
        @"LastModeratedSubredditName", @"AwardProductOffers", @"BlockedRedditors",
        @"GamesPreferences", @"GetRedditUsersByIds", @"SubredditsForNames",
        @"SubredditsForIds", @"ExposeExperimentBatch", @"GetProfilePostFlairTemplates",
        @"GetRedditorByNameApollo", @"GetActiveSubreddits", @"GetMyShowcaseCarousel",
        @"UserPublicTrophies", @"PostDraftsCount", @"BrandToolsStatus",
        @"NotificationInbox", @"TrendingSearchesQuery", nil];
  });
  return set;
}

NSData *RFFilteredResponseData(NSData *data, NSString *operationName, RFPrefs prefs) {
  if (!data.length || [RFIgnoredOperations() containsObject:operationName]) return nil;

  NSMutableDictionary *json = RFMutableDict([NSJSONSerialization JSONObjectWithData:data
                                                                            options:NSJSONReadingMutableContainers
                                                                              error:NULL]);
  NSDictionary *payload = RFDict(json[@"data"]);
  if (!payload) return nil; // not GraphQL, or an error response like {"data": null}

  RFContext ctx = {prefs, RFCurrentKeywords(prefs)};
  if (!RFFilterResponse(json, payload, operationName, &ctx)) return nil; // unchanged: skip re-encoding
  return [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL];
}

#pragma mark - Topping up short first pages

static const NSUInteger kRFMinimumVisiblePosts = 10;

static NSMutableDictionary *RFFeedElements(NSDictionary *json) {
  for (id root in RFDict(json[@"data"]).allValues) {
    NSMutableDictionary *elements = RFMutableDict(RFDict(root)[@"elements"]);
    if (RFArray(elements[@"edges"])) return elements;
  }
  return nil;
}

static BOOL RFIsHiddenFeedElement(NSDictionary *node) {
  if (RFTrue(node[@"isHidden"])) return YES;
  NSArray *cells = RFArray(node[@"cells"]);
  return [RFString(node[@"__typename"]) isEqualToString:@"CellGroup"] && cells && cells.count == 0;
}

NSURLRequest *RFFeedTopUpRequest(NSURLRequest *request, NSData *filteredData) {
  if (![RFOperationName(request) isEqualToString:@"HomeFeedSdui"] || !request.HTTPBody.length || !filteredData.length)
    return nil;
  NSMutableDictionary *body = RFMutableDict([NSJSONSerialization JSONObjectWithData:request.HTTPBody
                                                                            options:NSJSONReadingMutableContainers
                                                                              error:NULL]);
  NSMutableDictionary *variables = RFMutableDict(body[@"variables"]);
  if (!variables || RFString(variables[@"after"])) return nil; // only the first page

  NSDictionary *json = RFDict([NSJSONSerialization JSONObjectWithData:filteredData
                                                             options:NSJSONReadingMutableContainers
                                                               error:NULL]);
  NSDictionary *elements = RFFeedElements(json);
  NSDictionary *pageInfo = RFDict(elements[@"pageInfo"]);
  NSString *cursor = RFString(pageInfo[@"endCursor"]);
  if (!RFTrue(pageInfo[@"hasNextPage"]) || !cursor.length) return nil;

  NSUInteger visible = 0;
  for (id edge in RFArray(elements[@"edges"]))
    if (!RFIsHiddenFeedElement(RFDict(RFDict(edge)[@"node"]))) visible++;
  if (visible >= kRFMinimumVisiblePosts) return nil;

  variables[@"after"] = cursor;
  NSData *newBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
  if (!newBody) return nil;
  NSMutableURLRequest *next = [request mutableCopy];
  next.HTTPBody = newBody;
  [next setValue:[NSString stringWithFormat:@"%lu", (unsigned long)newBody.length] forHTTPHeaderField:@"Content-Length"];
  return next;
}

NSData *RFMergedFeedPages(NSData *firstPage, NSData *nextPage) {
  if (!firstPage.length || !nextPage.length) return nil;
  NSMutableDictionary *first = RFMutableDict([NSJSONSerialization JSONObjectWithData:firstPage
                                                                             options:NSJSONReadingMutableContainers
                                                                               error:NULL]);
  NSDictionary *next = RFDict([NSJSONSerialization JSONObjectWithData:nextPage
                                                             options:NSJSONReadingMutableContainers
                                                               error:NULL]);
  NSMutableDictionary *firstElements = RFFeedElements(first);
  NSDictionary *nextElements = RFFeedElements(next);
  NSMutableArray *edges = RFArray(firstElements[@"edges"]) ? [firstElements[@"edges"] mutableCopy] : nil;
  NSArray *moreEdges = RFArray(nextElements[@"edges"]);
  NSDictionary *pageInfo = RFDict(nextElements[@"pageInfo"]);
  if (!edges || !moreEdges || !pageInfo) return nil;
  [edges addObjectsFromArray:moreEdges];
  firstElements[@"edges"] = edges;
  firstElements[@"pageInfo"] = pageInfo;
  return [NSJSONSerialization dataWithJSONObject:first options:0 error:NULL];
}

#pragma mark - Checking the full text of feed posts

static NSString *const kRFPostDetailsRequestKey = @"kRedditFilterPostDetailsRequest";

// The app's request for full posts, minus the post IDs, as seen in Reddit 2026.43. Replaced by the
// app's own request as soon as it makes one.
static NSDictionary *RFDefaultPostDetailsRequest(void) {
  NSMutableDictionary *variables = [NSMutableDictionary dictionary];
  for (NSString *flag in @[
         @"includeAuthorProfileExemptedExperiments", @"includeCommunityPermissions", @"includeCurrentUserAwards",
         @"includeDeletedPostInfo", @"includeDeletedPostSharePermalink", @"includeDownloadCount",
         @"includeFeatureVariants", @"includeIsTextEditable", @"includeLinkedCommentInfo", @"includePlaybackMp4s",
         @"includeRepostCount", @"includeSubredditChannelsState"
       ])
    variables[flag] = @YES;
  for (NSString *flag in @[
         @"includeCommentPostUnits", @"includeFeedTrend", @"includeLinkTitle", @"includeMediaAuth",
         @"includeProfileFlair", @"includePublisherAttribution", @"includeSubredditBackgroundColor"
       ])
    variables[flag] = @NO;
  variables[@"featureVariantNames"] =
      @[ @"mod_guide_subreddit_rollout", @"mediaf_video_in_comments_subreddit_allowlist" ];
  return @{
    @"body" : @{
      @"extensions" : @{
        @"persistedQuery" :
            @{@"sha256Hash" : @"d1229531c4120d3252591cc1e51ea3928cc068721f6c8b264a95183459f2fbd2", @"version" : @1}
      },
      @"operationName" : @"FeedPostDetailsByIds",
      @"variables" : variables,
    },
    @"headers" : @{@"X-APOLLO-OPERATION-NAME" : @"FeedPostDetailsByIds"},
  };
}

// { body: <request body without ids>, headers: <Apollo headers>, appBuild: <Reddit build it came from> }
static NSDictionary *gPostDetailsRequest;

// The installed Reddit build. A saved request from another build may no longer be accepted.
static NSString *RFAppBuild(void) {
  NSDictionary *info = NSBundle.mainBundle.infoDictionary;
  return [NSString stringWithFormat:@"%@ (%@)", info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"]];
}

static NSDictionary *RFPostDetailsTemplate(void) {
  @synchronized(kRFPostDetailsRequestKey) {
    if (!gPostDetailsRequest) {
      NSData *data = [NSUserDefaults.standardUserDefaults dataForKey:kRFPostDetailsRequestKey];
      NSDictionary *saved = data ? RFDict([NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]) : nil;
      BOOL current = [RFString(saved[@"appBuild"]) isEqualToString:RFAppBuild()];
      gPostDetailsRequest = current && RFDict(saved[@"body"]) ? saved : RFDefaultPostDetailsRequest();
    }
    return gPostDetailsRequest;
  }
}

void RFRememberPostDetailsRequest(NSURLRequest *request) {
  if (!request.HTTPBody.length) return;
  NSMutableDictionary *body = RFMutableDict([NSJSONSerialization JSONObjectWithData:request.HTTPBody
                                                                            options:NSJSONReadingMutableContainers
                                                                              error:NULL]);
  NSMutableDictionary *variables = RFMutableDict(body[@"variables"]);
  if (!variables || !RFArray(variables[@"ids"])) return;
  [variables removeObjectForKey:@"ids"];
  // Only the Apollo labels: the login headers are taken fresh from each feed request.
  NSMutableDictionary *headers = [NSMutableDictionary dictionary];
  [request.allHTTPHeaderFields enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
    if ([name.uppercaseString hasPrefix:@"X-APOLLO-"]) headers[name] = value;
  }];
  NSDictionary *template = @{@"body" : body, @"headers" : headers, @"appBuild" : RFAppBuild()};
  @synchronized(kRFPostDetailsRequestKey) {
    if ([gPostDetailsRequest isEqual:template]) return;
    gPostDetailsRequest = template;
  }
  // Saved as JSON: the body can hold nulls, which defaults can't store.
  NSData *data = [NSJSONSerialization dataWithJSONObject:template options:0 error:NULL];
  if (data) [NSUserDefaults.standardUserDefaults setObject:data forKey:kRFPostDetailsRequestKey];
}

// Feed card IDs are base64 of the post ID, sometimes with "-<uuid>" after it.
static NSString *RFCardPostId(NSDictionary *card) {
  NSString *identifier = RFString(card[@"id"]);
  if (!identifier) return nil;
  NSData *decoded = [[NSData alloc] initWithBase64EncodedString:identifier options:0];
  NSString *text = decoded ? [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding] : identifier;
  NSString *postId = [text componentsSeparatedByString:@"-"].firstObject;
  return [postId hasPrefix:@"t3_"] ? postId : nil;
}

// Visible post cards on a feed page, by post ID.
static NSDictionary<NSString *, NSArray<NSMutableDictionary *> *> *RFVisibleFeedPosts(NSDictionary *json) {
  NSMutableDictionary *posts = [NSMutableDictionary dictionary];
  for (id edge in RFArray(RFFeedElements(json)[@"edges"])) {
    NSMutableDictionary *card = RFMutableDict(RFDict(edge)[@"node"]);
    if (![RFString(card[@"__typename"]) isEqualToString:@"CellGroup"] || RFIsHiddenFeedElement(card) ||
        RFDict(card[@"adPayload"]))
      continue;
    NSString *postId = RFCardPostId(card);
    if (!postId) continue;
    posts[postId] = [(posts[postId] ?: @[]) arrayByAddingObject:card];
  }
  return posts;
}

NSURLRequest *RFPostDetailsRequest(NSURLRequest *feedRequest, NSData *feedData, RFPrefs prefs) {
  if (!RFCurrentKeywords(prefs) || ![RFOperationName(feedRequest) hasSuffix:@"FeedSdui"] || !feedData.length)
    return nil;
  NSDictionary *json = RFDict([NSJSONSerialization JSONObjectWithData:feedData
                                                             options:NSJSONReadingMutableContainers
                                                               error:NULL]);
  NSArray *ids = RFVisibleFeedPosts(json).allKeys;
  if (!ids.count) return nil;

  NSDictionary *template = RFPostDetailsTemplate();
  NSMutableDictionary *body = [RFDict(template[@"body"]) mutableCopy];
  NSMutableDictionary *variables = [RFDict(body[@"variables"]) mutableCopy] ?: [NSMutableDictionary dictionary];
  variables[@"ids"] = ids;
  body[@"variables"] = variables;
  NSData *newBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
  if (!newBody) return nil;

  NSMutableURLRequest *request = [feedRequest mutableCopy];
  request.HTTPBody = newBody;
  NSMutableDictionary *headers = [request.allHTTPHeaderFields mutableCopy];
  for (NSString *name in request.allHTTPHeaderFields)
    if ([name.uppercaseString hasPrefix:@"X-APOLLO-"]) [headers removeObjectForKey:name];
  [headers addEntriesFromDictionary:RFDict(template[@"headers"])];
  headers[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)newBody.length];
  request.allHTTPHeaderFields = headers;
  return request;
}

NSData *RFFeedHidingFullTextMatches(NSData *feedData, NSData *detailsData, RFPrefs prefs) {
  NSRegularExpression *keywords = RFCurrentKeywords(prefs);
  if (!keywords || !feedData.length || !detailsData.length) return nil;
  NSDictionary *details = RFDict([NSJSONSerialization JSONObjectWithData:detailsData options:0 error:NULL]);
  NSArray *posts = RFArray(RFValueAtPath(details, @"data.postsInfoByIds"));
  if (!posts) return nil;
  NSMutableDictionary *json = RFMutableDict([NSJSONSerialization JSONObjectWithData:feedData
                                                                            options:NSJSONReadingMutableContainers
                                                                              error:NULL]);
  NSDictionary *cards = RFVisibleFeedPosts(json);
  BOOL changed = NO;
  for (id item in posts) {
    NSDictionary *post = RFDict(item);
    NSArray *matching = cards[RFString(post[@"id"]) ?: @""];
    if (!matching || !RFContentMatchesKeywords(post, keywords)) continue;
    for (NSMutableDictionary *card in matching) card[@"cells"] = @[];
    changed = YES;
  }
  return changed ? [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL] : nil;
}

#pragma mark - RedGIFs

// "https://www.redgifs.com/watch/<id>" (or /ifr/<id>) -> "<id>"
static NSString *RFRedgifsId(NSString *link) {
  NSURL *url = link ? [NSURL URLWithString:link] : nil;
  if (![url.host.lowercaseString hasSuffix:@"redgifs.com"]) return nil;
  NSArray *parts = url.pathComponents;
  NSUInteger index = [parts indexOfObjectPassingTest:^BOOL(NSString *part, NSUInteger i, BOOL *stop) {
    return [part isEqualToString:@"watch"] || [part isEqualToString:@"ifr"];
  }];
  if (index == NSNotFound || index + 1 >= parts.count) return nil;
  NSString *identifier = [parts[index + 1] lowercaseString];
  NSCharacterSet *invalid = [NSCharacterSet.alphanumericCharacterSet invertedSet];
  return identifier.length && [identifier rangeOfCharacterFromSet:invalid].location == NSNotFound ? identifier : nil;
}

typedef void (^RFVideoSwap)(NSString *videoURL);

// Calls block for every video in the response that Reddit plays from its copy of a RedGIFs video,
// with a way to point it at another file. Posts keep it in media.streaming; feed cards in card view
// keep it in a LegacyVideoCell, with the RedGIFs link in the card's MetadataCell.
static void RFForEachRedgifsVideo(id object, void (^block)(NSString *identifier, RFVideoSwap swap)) {
  if (RFArray(object)) {
    for (id item in object) RFForEachRedgifsVideo(item, block);
    return;
  }
  NSDictionary *dict = RFDict(object);
  if (!dict) return;

  NSMutableDictionary *media = RFMutableDict(dict[@"media"]);
  NSMutableDictionary *streaming = RFMutableDict(media[@"streaming"]);
  if (streaming) {
    NSString *identifier = RFRedgifsId(RFString(dict[@"url"])) ?: RFRedgifsId(RFString(RFDict(media[@"video"])[@"url"]));
    if (identifier)
      block(identifier, ^(NSString *videoURL) {
        // The player takes a plain MP4 here as well as a playlist. It stays marked as a GIF so it
        // keeps looping; the player still offers sound because the file has an audio track.
        streaming[@"hlsUrl"] = videoURL;
        if ([streaming objectForKey:@"hasAudio"]) streaming[@"hasAudio"] = @YES;
        // Saving the video saves the version with sound too.
        [RFMutableDict(media[@"download"]) setObject:videoURL forKey:@"url"];
      });
  }

  if ([RFString(dict[@"__typename"]) isEqualToString:@"CellGroup"]) {
    NSString *identifier = nil;
    NSMutableDictionary *videoCell = nil;
    for (id item in RFArray(dict[@"cells"])) {
      NSMutableDictionary *cell = RFMutableDict(item);
      NSString *type = RFString(cell[@"__typename"]);
      if ([type isEqualToString:@"MetadataCell"]) identifier = RFRedgifsId(RFString(cell[@"mediaPath"]));
      if ([type isEqualToString:@"LegacyVideoCell"] && RFMutableDict(cell[@"media"])) videoCell = cell;
    }
    if (identifier && videoCell)
      block(identifier, ^(NSString *videoURL) {
        videoCell[@"media"][@"path"] = videoURL;
      });
  }

  for (id value in dict.allValues)
    if (RFArray(value) || RFDict(value)) RFForEachRedgifsVideo(value, block);
}

static BOOL RFMightHaveRedgifs(NSData *data) {
  static NSData *needle;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ needle = [@"redgifs.com" dataUsingEncoding:NSUTF8StringEncoding]; });
  return data.length && [data rangeOfData:needle options:0 range:NSMakeRange(0, data.length)].location != NSNotFound;
}

NSArray<NSString *> *RFRedgifsIds(NSData *data) {
  if (!RFMightHaveRedgifs(data)) return nil;
  id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL];
  NSMutableOrderedSet *ids = [NSMutableOrderedSet orderedSet];
  RFForEachRedgifsVideo(RFDict(json)[@"data"], ^(NSString *identifier, RFVideoSwap swap) {
    [ids addObject:identifier];
  });
  return ids.count ? ids.array : nil;
}

NSData *RFRedgifsResponse(NSData *data, NSDictionary<NSString *, NSString *> *videoURLs) {
  if (!videoURLs.count || !RFMightHaveRedgifs(data)) return nil;
  NSMutableDictionary *json = RFMutableDict([NSJSONSerialization JSONObjectWithData:data
                                                                            options:NSJSONReadingMutableContainers
                                                                              error:NULL]);
  __block BOOL changed = NO;
  RFForEachRedgifsVideo(json[@"data"], ^(NSString *identifier, RFVideoSwap swap) {
    NSString *videoURL = RFString(videoURLs[identifier]);
    if (!videoURL) return;
    swap(videoURL);
    changed = YES;
  });
  return changed ? [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL] : nil;
}

#pragma mark - Operation name

NSString *RFOperationName(NSURLRequest *request) {
  // Apollo (Reddit's GraphQL client) labels every request with this header.
  NSString *name = [request valueForHTTPHeaderField:@"X-APOLLO-OPERATION-NAME"];
  if (name.length) return name;

  NSData *body = request.HTTPBody;
  if (body.length) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      regex = [[NSRegularExpression alloc] initWithPattern:@"\"operationName\"\\s*:\\s*\"([^\"]+)\""
                                                   options:0
                                                     error:NULL];
    });
    NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    NSTextCheckingResult *match = text ? [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] : nil;
    if (match.numberOfRanges > 1) return [text substringWithRange:[match rangeAtIndex:1]];
  }

  for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO].queryItems)
    if ([item.name isEqualToString:@"operationName"] && item.value.length) return item.value;

  return @"Unknown";
}
