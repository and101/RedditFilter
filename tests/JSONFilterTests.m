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
    NSDictionary *forYou = Feed(@[@{@"__typename": @"CellGroup", @"cells": @[@{@"__typename": @"TitleCell"}],
                                     @"recommendationContext": @{@"typeName": @"DefaultRecommendationContext",
                                                                 @"typeIdentifier": @"user_to_post"}}]);
    Check([Filter(forYou, @"HomeFeedSdui", recommended) isEqual:forYou], @"Keep recommended posts in For You");

    RFPrefs keywords = {.keywords = YES};
    RFSetFilterKeywords(@[@" Cafe ", @"new  york", @"", @"c++"]);
    NSArray *keywordCards = @[
      Card(@{@"__typename": @"TitleCell", @"title": @"Best CAFÉ in town"}),
      Card(@{@"__typename": @"TitleWithThumbnailCell", @"titleCell": @{@"title": @"Moving to New\nYork soon"}}),
      Card(@{@"__typename": @"PreviewTextCell", @"text": @"Learning C++ today"}),
      Card(@{@"__typename": @"TitleCell", @"title": @"Cafeteria food and newyork"}),
      Card(@{@"__typename": @"TitleCell", @"title": @"Nothing to see"})
    ];
    NSArray *kept = Filter(Feed(keywordCards), @"HomeFeedSdui", keywords)[@"data"][@"homeV3"][@"elements"][@"edges"];
    for (NSUInteger i = 0; i < 3; i++) Check([kept[i][@"node"][@"cells"] count] == 0, @"Hide titles, nested titles and previews with a keyword");
    Check([kept[3][@"node"][@"cells"] count] == 1, @"Match whole words only");
    Check([kept[4][@"node"][@"cells"] count] == 1, @"Keep posts without keywords");
    Check([Filter(Feed(keywordCards), @"HomeFeedSdui", off) isEqual:Feed(keywordCards)], @"Keyword filter off leaves posts");
    RFSetFilterKeywords(@[]);
    Check([Filter(Feed(keywordCards), @"HomeFeedSdui", keywords) isEqual:Feed(keywordCards)], @"Cleared keywords hide nothing");

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
    RFPrefs videos = {.videosForYou = YES};
    NSDictionary *videoCarousel = @{@"__typename": @"PostCarousel", @"type": @"VIDEO_RECOMMENDATIONS",
                                    @"carouselTitle": @"Videos for you", @"videoCarouselPosts": @[@{@"id": @"v"}]};
    NSDictionary *otherCarousel = @{@"__typename": @"PostCarousel", @"type": @"OTHER", @"carouselPosts": @[@{@"id": @"o"}]};
    NSDictionary *withCarousels = Feed(@[Card(@{@"__typename": @"TitleCell"}), videoCarousel, otherCarousel]);
    for (NSString *op in @[@"HomeFeedSdui", @"PopularFeedSdui", @"Unknown"]) {
      NSArray *edges = Filter(withCarousels, op, videos)[@"data"][@"homeV3"][@"elements"][@"edges"];
      Check(edges.count == 3, @"Keep every feed element so the feed keeps loading");
      Check([edges[1][@"node"][@"__typename"] isEqual:@"CellGroup"] && [edges[1][@"node"][@"cells"] count] == 0,
            @"Swap the Videos for you carousel for an empty card");
      Check([edges[2][@"node"][@"carouselPosts"] count] == 1, @"Keep other carousels");
      Check([Filter(withCarousels, op, ads) isEqual:withCarousels], @"Other filters keep Videos for you");
      Check([Filter(withCarousels, op, off) isEqual:withCarousels], @"Disabled filter keeps Videos for you");
    }
    // Short first pages get topped up with the next page.
    NSMutableURLRequest *feedRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://gql-fed.reddit.com/"]];
    [feedRequest setValue:@"HomeFeedSdui" forHTTPHeaderField:@"X-APOLLO-OPERATION-NAME"];
    feedRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"operationName": @"HomeFeedSdui", @"variables": @{@"sort": @"BEST"}} options:0 error:NULL];
    NSDictionary *(^Page)(NSUInteger, NSUInteger, NSString *) = ^NSDictionary *(NSUInteger shown, NSUInteger hidden, NSString *cursor) {
      NSMutableArray *edges = [NSMutableArray array];
      for (NSUInteger i = 0; i < shown; i++) [edges addObject:@{@"node": Card(@{@"__typename": @"TitleCell"})}];
      for (NSUInteger i = 0; i < hidden; i++) [edges addObject:@{@"node": @{@"__typename": @"CellGroup", @"cells": @[]}}];
      return @{@"data": @{@"homeV3": @{@"elements": @{@"edges": edges,
        @"pageInfo": @{@"endCursor": cursor ?: NSNull.null, @"hasNextPage": @(cursor != nil)}}}}};
    };
    NSData *(^Data)(NSDictionary *) = ^NSData *(NSDictionary *o) { return [NSJSONSerialization dataWithJSONObject:o options:0 error:NULL]; };
    NSURLRequest *topUp = RFFeedTopUpRequest(feedRequest, Data(Page(6, 3, @"c1")));
    NSDictionary *topUpBody = [NSJSONSerialization JSONObjectWithData:topUp.HTTPBody options:0 error:NULL];
    Check([topUpBody[@"variables"][@"after"] isEqual:@"c1"] && [topUpBody[@"variables"][@"sort"] isEqual:@"BEST"], @"Ask for the next page after a short first page");
    Check(RFFeedTopUpRequest(feedRequest, Data(Page(12, 2, @"c1"))) == nil, @"Leave full first pages alone");
    Check(RFFeedTopUpRequest(feedRequest, Data(Page(3, 0, nil))) == nil, @"Stop at the end of the feed");
    NSURLRequest *nextPageRequest = topUp;
    Check(RFFeedTopUpRequest(nextPageRequest, Data(Page(1, 8, @"c2"))) == nil, @"Only top up the first page");
    NSDictionary *merged = [NSJSONSerialization JSONObjectWithData:RFMergedFeedPages(Data(Page(6, 3, @"c1")), Data(Page(20, 0, @"c2"))) options:0 error:NULL];
    Check([merged[@"data"][@"homeV3"][@"elements"][@"edges"] count] == 29, @"Merge both pages' posts");
    Check([merged[@"data"][@"homeV3"][@"elements"][@"pageInfo"][@"endCursor"] isEqual:@"c2"], @"Continue from the second page");
    Check(RFMergedFeedPages(Data(Page(6, 3, @"c1")), [@"oops" dataUsingEncoding:NSUTF8StringEncoding]) == nil, @"Ignore a bad second page");

    puts("All JSON filtering regression tests passed.");
  }
  return 0;
}
