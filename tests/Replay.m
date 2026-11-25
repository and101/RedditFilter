// Replays captured Reddit responses through the filter: tests/replay.sh <folder> [ads expected]
//
// Each file is one raw GraphQL response, named after its operation (HomeFeedSdui-123.json). For each:
//   * Ads: what's still showing with Promoted filtered. Ads are found here by their own markers, anywhere
//     in the response, not with the filter's code, so an ad somewhere the filter doesn't look is found.
//   * Feeds: that no filter changes a response in a way that could stop a feed loading: lists, page info
//     and card fields stay as they were, and filtering twice gives the same result.
//   * Posts: filters not meant to hide posts that hide most of a page's.
//
// It can't see requests made without a completion handler (they're never captured), and an ad left in
// place but marked hidden counts as hidden: only the app shows whether it honours that. Keywords and
// RedGIFs aren't replayed.
#import <Foundation/Foundation.h>
#import "JSONFilter.h"
#import "RFStats.h"

static NSDictionary *Dict(id value) { return [value isKindOfClass:NSDictionary.class] ? value : nil; }
static NSArray *List(id value) { return [value isKindOfClass:NSArray.class] ? value : nil; }
static NSString *Type(id value) {
  NSString *type = Dict(value)[@"__typename"];
  return [type isKindOfClass:NSString.class] ? type : @"";
}
static BOOL True(id value) { return [value isKindOfClass:NSNumber.class] && [value boolValue]; }

static void Print(NSString *format, ...) {
  va_list args;
  va_start(args, format);
  NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  printf("%s\n", line.UTF8String);
}

#pragma mark - Ads

// What marks this object as an ad, or nil.
static NSString *AdMarker(NSDictionary *object) {
  NSString *type = Type(object);
  if (Dict(object[@"adPayload"])) return [NSString stringWithFormat:@"%@ with adPayload", type];
  for (NSString *name in @[ @"AdPost", @"SearchAdPost", @"ConversationAdFeedUnit" ])
    if ([type isEqualToString:name]) return type;
  if ([type rangeOfString:@"^Ad[A-Z]\\w*Cell$" options:NSRegularExpressionSearch].location != NSNotFound) return type;
  if (True(object[@"isAdPost"])) return [NSString stringWithFormat:@"%@ with isAdPost", type];
  return nil;
}

// How the filter hides an ad it leaves in place: an empty card, or a post marked hidden. An ad post inside
// another card doesn't count as hidden by being marked: the card would still show.
static BOOL IsHiddenAd(NSDictionary *object) {
  if ([Type(object) isEqualToString:@"CellGroup"]) return List(object[@"cells"]) && ![List(object[@"cells"]) count];
  return True(object[@"isHidden"]);
}

// Lists of ads on post pages.
static BOOL IsAdList(NSString *key) {
  return [@[ @"adPosts", @"commentsPageAds", @"commentTreeAds", @"pdpCommentsAds" ] containsObject:key];
}

// Adds "path: marker" for each ad in `object` to `found`. Doesn't look inside an ad for more of them.
static void FindAds(id object, NSString *path, BOOL skipHidden, NSMutableArray<NSString *> *found) {
  if (List(object)) {
    for (id item in object) FindAds(item, [path stringByAppendingString:@"[]"], skipHidden, found);
    return;
  }
  NSDictionary *dict = Dict(object);
  if (!dict) return;
  NSString *marker = AdMarker(dict);
  if (marker) {
    if (!skipHidden || !IsHiddenAd(dict)) [found addObject:[NSString stringWithFormat:@"%@: %@", path, marker]];
    return;
  }
  for (NSString *key in dict) {
    NSString *inner = [NSString stringWithFormat:@"%@.%@", path, key];
    if (IsAdList(key) && List(dict[key])) {
      for (id ad in dict[key]) [found addObject:[NSString stringWithFormat:@"%@[]: %@", inner, Type(ad)]];
      continue;
    }
    FindAds(dict[key], inner, skipHidden, found);
  }
}

// The post IDs of the ad cards in a response.
static void CollectAdIds(id object, NSMutableSet *ids) {
  if (List(object)) {
    for (id item in object) CollectAdIds(item, ids);
    return;
  }
  NSDictionary *dict = Dict(object);
  if (dict && AdMarker(dict))
    for (NSString *key in @[ @"id", @"groupId" ])
      if (dict[key]) [ids addObject:dict[key]];
  for (id value in dict.allValues) CollectAdIds(value, ids);
}

// Posts from the ads tool that aren't marked as ads, leaving out the details of an ad card that's in the
// captures (the card is what shows). Listed, but not failures.
static void FindFromAdsTool(id object, NSString *path, NSSet *adIds, NSMutableArray<NSString *> *found) {
  if (List(object)) {
    for (id item in object) FindFromAdsTool(item, [path stringByAppendingString:@"[]"], adIds, found);
    return;
  }
  NSDictionary *dict = Dict(object);
  if (!dict || AdMarker(dict)) return;
  if (True(dict[@"isCreatedFromAdsUi"]) && !True(dict[@"isHidden"]) && ![adIds containsObject:dict[@"id"] ?: @""])
    [found addObject:[NSString stringWithFormat:@"%@: %@ isCreatedFromAdsUi", path, Type(dict)]];
  for (NSString *key in dict) FindFromAdsTool(dict[key], [NSString stringWithFormat:@"%@.%@", path, key], adIds, found);
}

#pragma mark - Structure

// Keys the filter adds to a post that didn't ask for them.
static NSSet *AddedKeys(void) {
  return [NSSet setWithArray:@[ @"isHidden", @"isScoreHidden", @"isInitiallyCollapsed", @"isAwardHidden", @"awardings", @"isGildable" ]];
}
// Lists the filter may empty.
static NSSet *EmptiedLists(void) {
  return [NSSet setWithArray:@[ @"cells", @"awardings", @"recommendations", @"adPosts", @"commentsPageAds", @"commentTreeAds",
                                @"pdpCommentsAds" ]];
}

// The fields of every real post card in a list of edges.
static NSSet<NSSet *> *CardFields(NSArray *edges) {
  NSMutableSet *sets = [NSMutableSet set];
  for (id edge in edges)
    if ([Type(Dict(edge)[@"node"]) isEqualToString:@"CellGroup"])
      [sets addObject:[NSSet setWithArray:[Dict(Dict(edge)[@"node"]) allKeys]]];
  return sets;
}

static void Compare(id before, id after, NSString *path, NSString *key, NSString *op, NSMutableOrderedSet *problems) {
  NSArray *oldList = List(before);
  if (oldList) {
    NSArray *list = List(after);
    if (!list) {
      [problems addObject:[path stringByAppendingString:@": a list is no longer a list"]];
      return;
    }
    if (list.count != oldList.count) {
      BOOL emptied = !list.count && [EmptiedLists() containsObject:key ?: @""];
      // Search ads are taken out of their list; nothing else may be.
      NSUInteger ads = 0;
      for (id item in oldList)
        if (AdMarker(Dict(item)) || AdMarker(Dict(Dict(item)[@"node"]))) ads++;
      BOOL searchAds = [op hasPrefix:@"Search"] && ads && list.count == oldList.count - ads;
      // Dropped so the app loads Home in a way the filter can see (RFAdLeakExperiments).
      BOOL experiments = [key isEqualToString:@"experimentVariants"] && list.count < oldList.count;
      if (!emptied && !searchAds && !experiments)
        [problems addObject:[NSString stringWithFormat:@"%@: list length %lu -> %lu", path, (unsigned long)oldList.count, (unsigned long)list.count]];
      return;
    }
    BOOL edges = [key isEqualToString:@"edges"];
    NSSet *fields = edges ? CardFields(oldList) : nil;
    for (NSUInteger i = 0; i < list.count; i++) {
      NSDictionary *oldNode = Dict(Dict(oldList[i])[@"node"]), *node = Dict(Dict(list[i])[@"node"]);
      if (edges && oldNode && node && ![Type(oldNode) isEqualToString:Type(node)]) {
        // A card swapped for an empty one: Reddit's parser drops the page if it lacks a field.
        if (![Type(node) isEqualToString:@"CellGroup"])
          [problems addObject:[NSString stringWithFormat:@"%@[].node: %@ became %@", path, Type(oldNode), Type(node)]];
        else if (fields.count && ![fields containsObject:[NSSet setWithArray:node.allKeys]])
          [problems addObject:[path stringByAppendingString:@"[].node: an empty card's fields don't match the page's own cards"]];
        continue;
      }
      Compare(oldList[i], list[i], [path stringByAppendingString:@"[]"], nil, op, problems);
    }
    return;
  }
  NSDictionary *oldDict = Dict(before);
  if (!oldDict) {
    // Values: only these change. Page info is what loads the next page.
    if ([path containsString:@"pageInfo"] && ![before isEqual:after]) [problems addObject:[path stringByAppendingString:@": page info changed"]];
    return;
  }
  NSDictionary *dict = Dict(after);
  if (!dict) {
    [problems addObject:[path stringByAppendingString:@": an object is gone"]];
    return;
  }
  for (NSString *name in oldDict) {
    if (!dict[name]) [problems addObject:[NSString stringWithFormat:@"%@.%@: field removed", path, name]];
    else Compare(oldDict[name], dict[name], [NSString stringWithFormat:@"%@.%@", path, name], name, op, problems);
  }
  for (NSString *name in dict)
    if (!oldDict[name] && ![AddedKeys() containsObject:name])
      [problems addObject:[NSString stringWithFormat:@"%@.%@: field added", path, name]];
}

#pragma mark - Posts

// The posts (not ads) in a response's feed lists, and how many still show.
static void CountPosts(id object, NSUInteger *shown) {
  if (List(object)) {
    for (id item in object) CountPosts(item, shown);
    return;
  }
  NSDictionary *dict = Dict(object);
  for (id edge in List(dict[@"edges"])) {
    NSDictionary *node = Dict(Dict(edge)[@"node"]);
    if (AdMarker(node)) continue;
    NSString *type = Type(node);
    if ([type isEqualToString:@"CellGroup"]) {
      for (id cell in List(node[@"cells"]))
        if ([Type(cell) isEqualToString:@"ActionCell"]) {
          (*shown)++;
          break;
        }
    } else if ([@[ @"SubredditPost", @"ProfilePost", @"PostPreviewComponent" ] containsObject:type] && !True(node[@"isHidden"])) {
      (*shown)++;
    }
  }
  for (id value in dict.allValues) CountPosts(value, shown);
}

#pragma mark - Running

typedef struct {
  __unsafe_unretained NSString *name;
  RFPrefs prefs;
  BOOL hidesPosts; // meant to hide ordinary posts
} Filter;

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc != 2 && argc != 3) {
      fprintf(stderr, "usage: tests/replay.sh <folder of captured responses> [ads expected]\n");
      return 2;
    }
    RFStatsDisableSaving();
    NSString *folder = @(argv[1]);
    NSArray *names = [[[NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:NULL]
        filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF ENDSWITH '.json'"]]
        sortedArrayUsingSelector:@selector(compare:)];
    if (!names.count) {
      fprintf(stderr, "No .json files in %s\n", argv[1]);
      return 2;
    }

    const Filter filters[] = {
        {@"Promoted", {.promoted = YES}},
        {@"Recommended", {.recommended = YES}},
        {@"NSFW", {.nsfw = YES}, YES},
        {@"Awards", {.awards = YES}},
        {@"Scores", {.scores = YES}},
        {@"AutoMod", {.automod = YES}},
        {@"Videos for you", {.videosForYou = YES}},
        {@"Extra cards", {.extraCards = YES}},
        {@"everything", {.promoted = YES, .recommended = YES, .nsfw = YES, .awards = YES, .scores = YES, .automod = YES,
                         .videosForYou = YES, .extraCards = YES}, YES},
    };
    const size_t filterCount = sizeof(filters) / sizeof(filters[0]);

    NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *totals = [NSMutableDictionary dictionary]; // op: files, ads, left
    NSCountedSet *left = [NSCountedSet set], *fromAdsTool = [NSCountedSet set];
    NSMutableOrderedSet *problems = [NSMutableOrderedSet orderedSet], *emptied = [NSMutableOrderedSet orderedSet];
    NSUInteger skipped = 0;

    NSMutableSet *adIds = [NSMutableSet set];
    for (NSString *name in names) {
      @autoreleasepool {
        NSData *data = [NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:name]];
        if (data) CollectAdIds([NSJSONSerialization JSONObjectWithData:data options:0 error:NULL], adIds);
      }
    }

    for (NSString *name in names) {
      @autoreleasepool {
        NSData *data = [NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:name]];
        NSDictionary *json = data ? Dict([NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]) : nil;
        if (!Dict(json[@"data"])) {
          skipped++; // an error, or not GraphQL
          continue;
        }
        NSString *op = [name componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"-."]].firstObject;
        NSMutableArray *ads = [NSMutableArray array];
        FindAds(json[@"data"], @"data", NO, ads);
        NSUInteger posts = 0;
        CountPosts(json, &posts);

        NSData *unchanged = RFFilteredResponseData(data, op, (RFPrefs){0});
        if (unchanged && ![[NSJSONSerialization JSONObjectWithData:unchanged options:0 error:NULL] isEqual:json])
          [problems addObject:[NSString stringWithFormat:@"%@: changed with every filter off", op]];

        for (size_t i = 0; i < filterCount; i++) {
          NSData *output = RFFilteredResponseData(data, op, filters[i].prefs);
          NSDictionary *result = output ? Dict([NSJSONSerialization JSONObjectWithData:output options:0 error:NULL]) : json;
          NSString *where = [NSString stringWithFormat:@"%@ (%@)", op, filters[i].name];
          if (!result) {
            [problems addObject:[where stringByAppendingString:@": the result isn't readable"]];
            continue;
          }
          NSMutableOrderedSet *found = [NSMutableOrderedSet orderedSet];
          Compare(json, result, @"", nil, op, found);
          for (NSString *problem in found) [problems addObject:[NSString stringWithFormat:@"%@ %@", where, problem]];
          if (output) {
            NSData *again = RFFilteredResponseData(output, op, filters[i].prefs);
            if (again && ![[NSJSONSerialization JSONObjectWithData:again options:0 error:NULL] isEqual:result])
              [problems addObject:[where stringByAppendingString:@": filtering again changes it"]];
          }
          NSUInteger shown = 0;
          CountPosts(result, &shown);
          if (!filters[i].hidesPosts && shown * 2 < posts)
            [emptied addObject:[NSString stringWithFormat:@"%@: %lu of %lu posts left in %@", where, (unsigned long)shown, (unsigned long)posts, name]];

          if (i) continue; // ads: Promoted only
          NSMutableArray *remaining = [NSMutableArray array];
          FindAds(result[@"data"], @"data", YES, remaining);
          for (NSString *ad in remaining) [left addObject:[NSString stringWithFormat:@"%@ %@", op, ad]];
          NSMutableArray *maybe = [NSMutableArray array];
          FindFromAdsTool(result[@"data"], @"data", adIds, maybe);
          for (NSString *post in maybe) [fromAdsTool addObject:[NSString stringWithFormat:@"%@ %@", op, post]];
          NSMutableArray *row = totals[op] ?: (totals[op] = [@[ @0, @0, @0 ] mutableCopy]);
          row[0] = @([row[0] integerValue] + 1);
          row[1] = @([row[1] integerValue] + ads.count);
          row[2] = @([row[2] integerValue] + remaining.count);
        }
      }
    }

    Print(@"%-34s %9s %6s %12s", "Operation", "responses", "ads", "still shown");
    for (NSString *op in [totals.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      NSArray *row = totals[op];
      if ([row[1] integerValue])
        Print(@"%-34s %9ld %6ld %12ld", op.UTF8String, (long)[row[0] integerValue], (long)[row[1] integerValue], (long)[row[2] integerValue]);
    }
    NSMutableArray *none = [NSMutableArray array];
    for (NSString *op in [totals.allKeys sortedArrayUsingSelector:@selector(compare:)])
      if (![totals[op][1] integerValue]) [none addObject:[NSString stringWithFormat:@"%@ (%@)", op, totals[op][0]]];
    if (none.count) Print(@"\nNo ads in: %@", [none componentsJoinedByString:@", "]);
    if (skipped) Print(@"Skipped %lu response(s) with no data.", (unsigned long)skipped);

    void (^section)(NSString *, NSArray *) = ^(NSString *title, NSArray *lines) {
      if (!lines.count) return;
      Print(@"\n%@", title);
      for (NSString *line in [lines sortedArrayUsingSelector:@selector(compare:)]) Print(@"  %@", line);
    };
    NSArray *(^counted)(NSCountedSet *) = ^(NSCountedSet *set) {
      NSMutableArray *lines = [NSMutableArray array];
      for (NSString *line in set) [lines addObject:[NSString stringWithFormat:@"%@ (x%lu)", line, (unsigned long)[set countForObject:line]]];
      return lines;
    };
    section(@"FAIL: ads still shown with Promoted filtered", counted(left));
    section(@"FAIL: changes that could stop a feed loading", problems.array);
    section(@"FAIL: a filter not meant to hide posts hid most of a page's", emptied.array);
    section(@"REVIEW: posts from the ads tool that aren't marked as ads", counted(fromAdsTool));
    NSInteger adCount = 0;
    for (NSArray *row in totals.allValues) adCount += [row[1] integerValue];
    BOOL missing = argc == 3 && adCount != atoi(argv[2]);
    if (missing) Print(@"\nFAIL: expected %s ads in the responses, found %ld", argv[2], (long)adCount);
    BOOL failed = missing || left.count || problems.count || emptied.count;
    Print(failed ? @"\nReplay failed." : @"\nReplay passed.");
    return failed ? 1 : 0;
  }
}
