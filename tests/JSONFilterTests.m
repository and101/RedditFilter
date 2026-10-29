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

    // Full post text: cards only carry the start, so the full posts are fetched and checked.
    RFSetFilterKeywords(@[@"tesla"]);
    NSString *(^CardId)(NSString *) = ^NSString *(NSString *postId) {
      return [[postId dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    };
    NSDictionary *bodyFeed = Feed(@[
      @{@"__typename": @"CellGroup", @"id": CardId(@"t3_a"), @"cells": @[@{@"__typename": @"TitleCell", @"title": @"Car advice"}]},
      @{@"__typename": @"CellGroup", @"id": CardId(@"t3_b-1234"), @"cells": @[@{@"__typename": @"TitleCell", @"title": @"Other"}]},
      @{@"__typename": @"CellGroup", @"id": CardId(@"t3_c"), @"cells": @[], @"adPayload": NSNull.null},
      @{@"__typename": @"CellGroup", @"id": CardId(@"t3_d"), @"cells": @[@1], @"adPayload": @{@"x": @1}},
    ]);
    NSURLRequest *detailsRequest = RFPostDetailsRequest(feedRequest, Data(bodyFeed), keywords);
    NSDictionary *detailsBody = [NSJSONSerialization JSONObjectWithData:detailsRequest.HTTPBody options:0 error:NULL];
    NSSet *askedIds = [NSSet setWithArray:detailsBody[@"variables"][@"ids"]];
    Check([askedIds isEqual:[NSSet setWithArray:@[@"t3_a", @"t3_b"]]], @"Ask for the full text of visible posts only");
    Check([detailsBody[@"operationName"] isEqual:@"FeedPostDetailsByIds"] && detailsBody[@"extensions"][@"persistedQuery"][@"sha256Hash"],
          @"Ask the way the app does");
    Check([[detailsRequest valueForHTTPHeaderField:@"X-APOLLO-OPERATION-NAME"] isEqual:@"FeedPostDetailsByIds"], @"Label the request");
    Check([detailsRequest.URL isEqual:feedRequest.URL], @"Use the feed's server");
    Check(RFPostDetailsRequest(feedRequest, Data(bodyFeed), off) == nil, @"No full-text check without keywords");
    Check(RFPostDetailsRequest(topUp, Data(bodyFeed), keywords) != nil, @"Check later pages too");

    NSDictionary *details = @{@"data": @{@"postsInfoByIds": @[
      @{@"id": @"t3_a", @"title": @"Car advice", @"content": @{@"markdown": @"Long story... I ended up buying a Tesla."}},
      @{@"id": @"t3_b", @"title": @"Other", @"content": NSNull.null},
    ]}};
    NSDictionary *checked = [NSJSONSerialization JSONObjectWithData:RFFeedHidingFullTextMatches(Data(bodyFeed), Data(details), keywords) options:0 error:NULL];
    NSArray *checkedEdges = checked[@"data"][@"homeV3"][@"elements"][@"edges"];
    Check([checkedEdges[0][@"node"][@"cells"] count] == 0, @"Hide posts with a keyword further down their text");
    Check([checkedEdges[1][@"node"][@"cells"] count] == 1, @"Keep posts without keywords in their full text");
    NSDictionary *previews = Feed(@[
      @{@"__typename": @"PostPreviewComponent", @"id": @"t3_e", @"post": @{@"title": @"Hi", @"content": @{@"markdown": @"...a tesla"}}},
      @{@"__typename": @"PostPreviewComponent", @"id": @"t3_f", @"post": @{@"title": @"Hi", @"content": NSNull.null}},
    ]);
    NSArray *previewEdges = Filter(previews, @"HomeFeedSdui", keywords)[@"data"][@"homeV3"][@"elements"][@"edges"];
    Check([previewEdges[0][@"node"][@"__typename"] isEqual:@"CellGroup"] && [previewEdges[0][@"node"][@"cells"] count] == 0,
          @"Swap whole-post cards with a keyword for an empty card");
    Check([previewEdges[1][@"node"][@"__typename"] isEqual:@"PostPreviewComponent"], @"Keep whole-post cards without keywords");
    NSDictionary *noMatch = @{@"data": @{@"postsInfoByIds": @[@{@"id": @"t3_a", @"content": @{@"markdown": @"Fine"}}]}};
    Check(RFFeedHidingFullTextMatches(Data(bodyFeed), Data(noMatch), keywords) == nil, @"Leave the page alone when nothing matches");
    Check(RFFeedHidingFullTextMatches(Data(bodyFeed), Data(@{@"data": NSNull.null}), keywords) == nil, @"Ignore a failed full-text check");

    // Comments
    RFPrefs keywordComments = {.keywords = YES, .keywordComments = YES, .keywordCommentReplies = YES};
    RFPrefs keepReplies = {.keywords = YES, .keywordComments = YES};
    NSDictionary *(^Tree)(NSInteger, NSInteger, NSString *) = ^NSDictionary *(NSInteger depth, NSInteger children, NSString *text) {
      return @{@"__typename": @"CommentTree", @"depth": @(depth), @"childCount": @(children),
               @"node": text ? @{@"__typename": @"Comment", @"content": @{@"markdown": text}} : NSNull.null};
    };
    NSDictionary *comments = Post(@{@"commentForest": @{@"trees": @[
      Tree(0, 4, @"Top"),
      Tree(1, 2, @"My TESLA broke"),
      Tree(2, 0, @"Sorry to hear"),
      Tree(2, 0, nil), // "more replies"
      Tree(1, 0, @"Unrelated reply"),
      Tree(0, 0, @"Tesla again"),
      Tree(0, 0, @"Teslas are different"),
    ]}});
    for (NSString *op in @[@"PostInfoByIdComments", @"Unknown"]) {
      NSArray *trees = Filter(comments, op, keywordComments)[@"data"][@"postInfoById"][@"commentForest"][@"trees"];
      Check(trees.count == 3, @"Hide comments with a keyword along with their replies");
      Check([trees[0][@"node"][@"content"][@"markdown"] isEqual:@"Top"] && [trees[0][@"childCount"] isEqual:@1],
            @"Lower the reply count of the comments above");
      Check([trees[1][@"node"][@"content"][@"markdown"] isEqual:@"Unrelated reply"], @"Keep other replies");
      Check([trees[2][@"node"][@"content"][@"markdown"] isEqual:@"Teslas are different"], @"Comments match whole words only");
      Check([Filter(comments, op, keywords) isEqual:comments], @"Comments are kept unless the comments switch is on");
      NSArray *placeheld = Filter(comments, op, keepReplies)[@"data"][@"postInfoById"][@"commentForest"][@"trees"];
      Check(placeheld.count == 7 && [placeheld[0][@"childCount"] isEqual:@4], @"Keep every reply when replies aren't hidden");
      Check([placeheld[1][@"node"][@"content"][@"markdown"] isEqual:@"Hidden by keyword filter"] &&
            placeheld[1][@"node"][@"authorInfo"] == NSNull.null &&
            [placeheld[1][@"node"][@"content"][@"richtext"] containsString:@"Hidden by keyword filter"],
            @"Swap a matching comment's text and author for a placeholder");
      Check([placeheld[2][@"node"][@"content"][@"markdown"] isEqual:@"Sorry to hear"], @"Keep its replies");
      Check([placeheld[5][@"node"][@"content"][@"markdown"] isEqual:@"Hidden by keyword filter"], @"Placehold every match");
    }
    RFSetFilterKeywords(@[]);
    Check([Filter(comments, @"PostInfoByIdComments", keywordComments) isEqual:comments], @"No keywords, no hidden comments");

    // RedGIFs: swap Reddit's silent copy for RedGIFs' own video.
    NSDictionary *(^RedgifsPost)(NSString *, NSString *) = ^NSDictionary *(NSString *postId, NSString *link) {
      return @{@"id": postId, @"domain": @"redgifs.com", @"url": link, @"media": @{
        @"typeHint": @"EMBED",
        @"video": @{@"url": link},
        @"download": @{@"url": @"https://packaged-media.redd.it/x/dl.mp4"},
        @"streaming": @{@"hlsUrl": @"https://v.redd.it/x/HLSPlaylist.m3u8", @"isGif": @YES, @"scrubberMediaUrl": @"https://v.redd.it/x/CMAF_96.mp4"}}};
    };
    NSDictionary *redgifsDetails = @{@"data": @{@"postsInfoByIds": @[
      RedgifsPost(@"t3_r1", @"https://www.redgifs.com/watch/JovialRewardingEnglishsetter"),
      RedgifsPost(@"t3_r2", @"https://www.redgifs.com/watch/scientificsupportivelark?utm=x"),
      RedgifsPost(@"t3_r3", @"https://www.redgifs.com/watch/jovialrewardingenglishsetter"),
      @{@"id": @"t3_v", @"domain": @"v.redd.it", @"url": @"https://v.redd.it/abc", @"media": @{@"streaming": @{@"hlsUrl": @"keep", @"isGif": @NO}}},
      @{@"id": @"t3_l", @"domain": @"redgifs.com", @"url": @"https://www.redgifs.com/watch/nostream", @"media": NSNull.null},
    ]}};
    NSArray *redgifsIds = RFRedgifsIds(Data(redgifsDetails));
    Check([redgifsIds isEqual:(@[@"jovialrewardingenglishsetter", @"scientificsupportivelark"])],
          @"Find each RedGIFs video Reddit streams, once");
    Check(RFRedgifsIds(Data(Feed(keywordCards))) == nil, @"No RedGIFs, nothing to look up");
    NSString *sound = @"https://media.redgifs.com/JovialRewardingEnglishsetter.mp4";
    NSDictionary *swapped = [NSJSONSerialization JSONObjectWithData:RFRedgifsResponse(Data(redgifsDetails), @{@"jovialrewardingenglishsetter": sound}) options:0 error:NULL];
    NSArray *swappedPosts = swapped[@"data"][@"postsInfoByIds"];
    for (NSUInteger i = 0; i < 3; i += 2) {
      NSDictionary *media = swappedPosts[i][@"media"];
      Check([media[@"streaming"][@"hlsUrl"] isEqual:sound] && [media[@"streaming"][@"isGif"] isEqual:@YES],
            @"Play RedGIFs' own video, still looping like a GIF");
      Check([media[@"download"][@"url"] isEqual:sound], @"Save the version with sound");
      Check([media[@"streaming"][@"scrubberMediaUrl"] hasPrefix:@"https://v.redd.it"], @"Keep Reddit's scrubbing previews");
    }
    Check([swappedPosts[1][@"media"][@"streaming"][@"hlsUrl"] hasPrefix:@"https://v.redd.it"], @"Keep Reddit's version when RedGIFs had nothing");
    Check([swappedPosts[3][@"media"][@"streaming"][@"hlsUrl"] isEqual:@"keep"], @"Leave other videos alone");
    Check(RFRedgifsResponse(Data(redgifsDetails), @{}) == nil, @"Nothing found, nothing changed");
    NSDictionary *cardFeed = Feed(@[@{@"__typename": @"CellGroup", @"cells": @[
      @{@"__typename": @"MetadataCell", @"mediaDomain": @"redgifs", @"mediaPath": @"https://www.redgifs.com/watch/jovialrewardingenglishsetter"},
      @{@"__typename": @"LegacyVideoCell", @"isGif": @YES, @"type": @"HLS", @"media": @{@"path": @"https://v.redd.it/x/HLSPlaylist.m3u8"}},
    ]}]);
    Check([RFRedgifsIds(Data(cardFeed)) isEqual:@[@"jovialrewardingenglishsetter"]], @"Find RedGIFs videos in card view");
    NSDictionary *cardCell = [NSJSONSerialization JSONObjectWithData:RFRedgifsResponse(Data(cardFeed), @{@"jovialrewardingenglishsetter": sound}) options:0 error:NULL][@"data"][@"homeV3"][@"elements"][@"edges"][0][@"node"][@"cells"][1];
    Check([cardCell[@"media"][@"path"] isEqual:sound] && [cardCell[@"isGif"] isEqual:@YES], @"Play RedGIFs' own video in card view");

    puts("All JSON filtering regression tests passed.");
  }
  return 0;
}
