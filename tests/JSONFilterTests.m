// Run on macOS: ./tests/run.sh
#import <Foundation/Foundation.h>
#import "JSONFilter.h"

static void Check(BOOL condition, NSString *message) {
  if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}

static NSDictionary *Filter(NSDictionary *input, NSString *operation, RFPrefs prefs) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:input options:0 error:NULL];
  NSData *result = RFFilteredResponseData(data, operation, prefs);
  return [NSJSONSerialization JSONObjectWithData:result ?: data options:0 error:NULL];
}

static NSDictionary *Post(NSDictionary *fields) { return @{@"data": @{@"postInfoById": fields}}; }
static NSDictionary *Card(id cell) { return @{@"__typename": @"CellGroup", @"cells": @[cell]}; }
static NSDictionary *Feed(NSArray *cards) {
  NSMutableArray *edges = [NSMutableArray array];
  for (id card in cards) [edges addObject:@{@"node": card}];
  return @{@"data": @{@"homeV3": @{@"elements": @{@"edges": edges}}}};
}

int main(void) {
  @autoreleasepool {
    RFPrefs ads = {.promoted = YES};
    RFPrefs nsfw = {.nsfw = YES};
    RFPrefs recommended = {.recommended = YES};
    RFPrefs off = {0};
    NSDictionary *wrapped = @{@"__typename": @"PdpAds", @"adPosts": @[@{@"id": @"ad"}],
                              @"nextCommentsPageAdEligibility": @"keep"};
    for (NSString *op in @[@"PdpCommentsAds", @"PostInfoById", @"Unknown"]) {
      NSDictionary *input = Post(@{@"pdpCommentsAds": wrapped, @"title": @"keep"});
      NSDictionary *post = Filter(input, op, ads)[@"data"][@"postInfoById"];
      Check([post[@"pdpCommentsAds"][@"adPosts"] count] == 0, @"Clear wrapped comment ads");
      Check([post[@"pdpCommentsAds"][@"__typename"] isEqual:@"PdpAds"], @"Keep ad object type");
      Check([post[@"pdpCommentsAds"][@"nextCommentsPageAdEligibility"] isEqual:@"keep"], @"Keep ad pagination metadata");
      Check([post[@"title"] isEqual:@"keep"], @"Keep post content");
      Check([Filter(input, op, off) isEqual:input], @"Disabled filter leaves ads unchanged");
      Check([Filter(Post(@{@"pdpCommentsAds": NSNull.null}), op, ads)[@"data"][@"postInfoById"][@"pdpCommentsAds"] isEqual:NSNull.null], @"Keep null ad payloads");
      Check([Filter(Post(@{@"pdpCommentsAds": @[@1]}), op, ads)[@"data"][@"postInfoById"][@"pdpCommentsAds"] count] == 0, @"Support old ad arrays");
    }
    NSDictionary *unknownAds = Post(@{@"pdpCommentsAds": @{@"futureField": @YES}});
    Check([Filter(unknownAds, @"PdpCommentsAds", ads) isEqual:unknownAds], @"Keep unknown ad shapes");

    NSArray *cards = @[
      Card(@{@"__typename": @"IndicatorsCell", @"indicators": @[@"NSFW"]}),
      Card(@{@"__typename": @"TitleWithThumbnailCell", @"indicatorsCell": @{@"indicators": @[@"nsfw"]}}),
      Card(@{@"indicatorsCell": NSNull.null, @"indicators": @[@1, NSNull.null]}),
      Card(@{@"__typename": @"TitleCell", @"text": @"keep"})
    ];
    NSDictionary *feed = Feed(cards);
    for (NSString *op in @[@"HomeFeedSdui", @"Unknown"]) {
      NSArray *edges = Filter(feed, op, nsfw)[@"data"][@"homeV3"][@"elements"][@"edges"];
      Check([edges[0][@"node"][@"cells"] count] == 0 && [edges[1][@"node"][@"cells"] count] == 0, @"Hide direct and nested NSFW indicators");
      Check([edges[2][@"node"][@"cells"] count] == 1 && [edges[3][@"node"][@"cells"] count] == 1, @"Keep ordinary cards and tolerate malformed indicators");
      Check([Filter(feed, op, off) isEqual:feed], @"Disabled NSFW filter preserves cards");
    }
    NSDictionary *extras = Post(@{@"detailComponents": @{@"components": @{@"edges": @[
      @{@"node": @{@"__typename": @"RelatedAnswersFeedUnit"}},
      @{@"node": @{@"__typename": @"PostContent"}}
    ]}}});
    for (NSString *op in @[@"PostInfoById", @"Unknown"]) {
      NSArray *edges = Filter(extras, op, recommended)[@"data"][@"postInfoById"][@"detailComponents"][@"components"][@"edges"];
      Check(edges.count == 1 && [edges[0][@"node"][@"__typename"] isEqual:@"PostContent"], @"Remove related answers and preserve post content");
      Check([Filter(extras, op, off) isEqual:extras], @"Disabled recommendations preserve related answers");
    }
    NSDictionary *highlights = @{@"data": @{@"subredditInfoByName": @{@"highlightedPosts": @[
      @{@"post": @{@"isNsfw": @YES}}, @{@"post": @{@"isNsfw": @NO}}, NSNull.null
    ]}}};
    Check([Filter(highlights, @"Unknown", nsfw)[@"data"][@"subredditInfoByName"][@"highlightedPosts"] count] == 2, @"Filter NSFW highlights only");
    Check([Filter(highlights, @"Unknown", off) isEqual:highlights], @"Disabled filter preserves highlights");
    puts("All JSON filtering regression tests passed.");
  }
  return 0;
}
