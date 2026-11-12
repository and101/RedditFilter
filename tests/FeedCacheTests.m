// Run with ./tests/run.sh
//
// Keep feed position after iOS closes the app (FeedCache.m): keeping Home pages, finding the post on
// screen from its label, and starting the first page after a relaunch there.
#import <Foundation/Foundation.h>
#import "FeedCache.h"

static void Check(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

static NSString *Base64URL(NSString *text) {
  NSString *base64 = [[text dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
  return [[[base64 stringByReplacingOccurrencesOfString:@"+" withString:@"-"]
      stringByReplacingOccurrencesOfString:@"/"
                                withString:@"_"] stringByReplacingOccurrencesOfString:@"="
                                                                           withString:@""];
}

static NSString *gTokenKind = @"user"; // the "sub" of the login token test requests carry

static NSURLRequest *FeedRequest(NSString *operation, NSString *account, NSString *after) {
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://gql-fed.reddit.com/"]];
  NSMutableDictionary *variables = [NSMutableDictionary dictionaryWithObject:@[] forKey:@"filterPosts"];
  if (after) variables[@"after"] = after;
  request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"operationName": operation, @"variables": variables}
                                                     options:0
                                                       error:NULL];
  if (account) {
    NSString *claims = [NSString stringWithFormat:@"{\"sub\":\"%@\",\"lid\":\"%@\"}", gTokenKind, account];
    NSString *token = [NSString stringWithFormat:@"%@.%@.signature", Base64URL(@"{\"alg\":\"RS256\"}"), Base64URL(claims)];
    [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
  }
  return request;
}

static NSURLRequest *Request(NSString *account, NSString *after) { return FeedRequest(@"HomeFeedSdui", account, after); }

// A post card as Home sends it (classic layout cells).
static NSDictionary *Card(NSString *postId, NSString *community, NSString *title) {
  return @{@"node": @{
    @"__typename": @"CellGroup",
    @"id": [[[postId stringByAppendingString:@"-x"] dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0],
    @"groupId": postId,
    @"cells": @[@{
      @"__typename": @"ClassicCell",
      @"metadataCell": @{@"__typename": @"ClassicMetadataCell", @"subredditName": community},
      @"titleCell": @{@"__typename": @"TitleCell", @"title": title},
    }],
  }};
}

// A post card as Following sends some of them.
static NSDictionary *Preview(NSString *postId, NSString *community, NSString *title) {
  return @{@"node": @{
    @"__typename": @"PostPreviewComponent",
    @"id": postId,
    @"post": @{@"__typename": @"SubredditPost", @"title": title,
               @"subreddit": @{@"__typename": @"Subreddit", @"prefixedName": community}},
  }};
}

static NSDictionary *Ad(void) {
  return @{@"node": @{@"__typename": @"CellGroup", @"id": @"ad", @"adPayload": @{}, @"cells": @[@{@"__typename": @"TitleCell", @"title": @"Buy"}]}};
}

static NSData *PageIn(NSString *root, NSArray *edges, NSString *cursor) {
  NSDictionary *json = @{@"data": @{root: @{@"__typename": @"Feed", @"elements": @{
    @"edges": edges,
    @"pageInfo": cursor ? @{@"endCursor": cursor, @"hasNextPage": @YES} : @{@"hasNextPage": @NO},
  }}}};
  return [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL];
}

static NSData *Page(NSArray *edges, NSString *cursor) { return PageIn(@"homeV3", edges, cursor); }

static NSArray<NSString *> *PostIds(NSData *page) {
  NSDictionary *json = [NSJSONSerialization JSONObjectWithData:page options:0 error:NULL];
  NSDictionary *elements = [[json[@"data"] allValues].firstObject objectForKey:@"elements"];
  NSMutableArray *ids = [NSMutableArray array];
  for (NSDictionary *edge in elements[@"edges"]) [ids addObject:edge[@"node"][@"groupId"] ?: edge[@"node"][@"id"] ?: @"?"];
  return ids;
}

static NSString *Cursor(NSData *page) {
  NSDictionary *json = [NSJSONSerialization JSONObjectWithData:page options:0 error:NULL];
  return json[@"data"][@"homeV3"][@"elements"][@"pageInfo"][@"endCursor"];
}

int main(void) {
  @autoreleasepool {
    // Account
    Check([RFFeedAccount(Request(@"t2_me", nil)) isEqualToString:@"t2_me"], @"Read the account from the login token");
    NSMutableURLRequest *loggedOut = [Request(nil, nil) mutableCopy];
    [loggedOut setValue:@"loid123" forHTTPHeaderField:@"x-reddit-loid"];
    Check([RFFeedAccount(loggedOut) isEqualToString:@"loid123"], @"Use the logged-out ID without a login token");
    Check(RFFeedAccount(Request(nil, nil)) == nil, @"No account without either");

    // Keeping pages
    NSData *first = Page(@[ Card(@"t3_a", @"r/one", @"Alpha"), Ad(), Card(@"t3_b", @"r/two", @"Beta") ], @"c1");
    NSDictionary *cache = RFFeedCacheAddingPage(nil, @"t2_me", nil, first);
    Check([cache[@"edges"] count] == 2 && [cache[@"cursor"] isEqualToString:@"c1"], @"Keep a first page without its ads");
    NSData *second = Page(@[ Card(@"t3_c", @"r/three", @"Gamma"), Card(@"t3_d", @"r/four", @"Delta") ], @"c2");
    Check(RFFeedCacheAddingPage(cache, @"t2_me", @"other", second) == nil, @"Ignore a page that doesn't follow the kept ones");
    Check(RFFeedCacheAddingPage(cache, @"t2_you", @"c1", second) == nil, @"Ignore another account's next page");
    cache = RFFeedCacheAddingPage(cache, @"t2_me", @"c1", second);
    Check([cache[@"edges"] count] == 4 && [cache[@"cursor"] isEqualToString:@"c2"], @"Add the next page");
    NSMutableArray *many = [NSMutableArray array];
    for (int i = 0; i < 400; i++) [many addObject:Card([NSString stringWithFormat:@"t3_m%d", i], @"r/x", @"Many")];
    NSDictionary *big = RFFeedCacheAddingPage(cache, @"t2_me", @"c2", Page(many, @"c3"));
    Check([big[@"edges"] count] == 300 && [[big[@"edges"] lastObject][@"node"][@"groupId"] isEqual:@"t3_m399"],
          @"Keep only the newest posts");

    // Finding the post on screen
    NSArray *labels = @[ @"u/advertiser, Promoted, Buy", @"r/three, Gamma, 4 upvotes, 2 comments", @"r/four, Delta, 1 upvote" ];
    Check([RFFeedCacheMatchingPosts(cache, labels) isEqual:(@[ NSNull.null, @"t3_c", @"t3_d" ])],
          @"Find kept posts from their labels");
    Check([RFFeedCacheMatchingPosts(cache, @[ @"r/other, Gamma, 4 upvotes" ]) isEqual:@[ NSNull.null ]],
          @"Don't match the same title in another community");
    Check([RFFeedCacheMatchingPosts(cache, @[ @"r/two,   beta\n, 3 upvotes" ]) isEqual:@[ @"t3_b" ]],
          @"Match regardless of spacing and capitals");

    // The kept feed after a relaunch
    NSDictionary *left = RFFeedCacheLeftAt(cache, @"t3_c", 40, NSDate.date);
    NSData *fresh = Page(@[ Card(@"t3_d", @"r/four", @"Delta"), Card(@"t3_e", @"r/five", @"Epsilon") ], @"f1");
    NSArray *keptEdges = nil;
    NSUInteger index = 0;
    NSData *replayed = RFFeedReplayPage(left, fresh, &keptEdges, &index);
    Check([PostIds(replayed) isEqual:(@[ @"t3_a", @"t3_b", @"t3_c", @"t3_d", @"t3_e" ])],
          @"Replay the whole kept feed, then the fresh posts without repeats");
    Check(keptEdges.count == 4 && index == 2, @"Say where the noted post is");
    Check([Cursor(replayed) isEqualToString:@"f1"], @"Carry on paging from the fresh page");
    NSMutableDictionary *keptCommunity = [left mutableCopy];
    keptCommunity[@"key"] = @"one|HOT";
    Check([Cursor(RFFeedReplayPage(keptCommunity, fresh, NULL, NULL)) isEqualToString:@"c2"],
          @"A community carries on paging after the kept posts");
    NSDictionary *twice = RFFeedCacheAddingPage(cache, @"t2_me", @"c2", Page(@[ Card(@"t3_a", @"r/one", @"Alpha"), Card(@"t3_f", @"r/six", @"Zeta") ], nil));
    NSData *once = RFFeedReplayPage(RFFeedCacheLeftAt(twice, @"t3_f", 0, NSDate.date), fresh, &keptEdges, &index);
    Check([PostIds(once) isEqual:(@[ @"t3_a", @"t3_b", @"t3_c", @"t3_d", @"t3_f", @"t3_e" ])] && index == 4,
          @"Replay a post the server sent twice once");
    Check(RFFeedReplayPage(RFFeedCacheLeftAt(cache, @"t3_zzz", 0, NSDate.date), fresh, NULL, NULL) == nil,
          @"Don't replay when the noted post isn't kept");
    Check(RFFeedReplayPage(RFFeedCacheLeftAt(cache, nil, 0, NSDate.date), fresh, NULL, NULL) == nil,
          @"Don't replay without a noted post");

    // The kept feed, across a relaunch
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                                      [NSString stringWithFormat:@"feedcache-%@", NSUUID.UUID.UUIDString]];
    NSString *path = [directory stringByAppendingPathComponent:@"HomeFeed.json"];
    RFFeedCacheSetDirectory(directory);
    RFFeedCacheSetEnabled(YES);
    RFFeedCacheSetColdReplayAllowed(YES);
    Check(RFFeedCachePage(@"HomeFeedSdui", Request(@"t2_me", nil), first) == nil, @"Hand the first page over as it is with nothing kept");
    Check(RFFeedCachePage(@"HomeFeedSdui", Request(@"t2_me", @"c1"), second) == nil, @"Hand the next page over as it is");
    dispatch_semaphore_t saved = dispatch_semaphore_create(0);
    RFFeedCacheNoteLeaving(@[ @[ @"r/other, Unknown" ], @[ @"u/ad, Promoted", @"r/two, Beta, 1 upvote", @"r/three, Gamma" ] ],
                           @[ @[ @5 ], @[ @-80, @25, @-300 ] ], ^{
      dispatch_semaphore_signal(saved);
    });
    Check(dispatch_semaphore_wait(saved, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0, @"Save when leaving");
    NSDictionary *onDisk = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:NULL];
    Check([onDisk[@"position"] isEqual:@"t3_b"] && [onDisk[@"offset"] isEqual:@25],
          @"Note the top post of the feed with kept posts, and how far into it you were");

    RFFeedCacheSetDirectory(directory); // relaunch
    Check(RFFeedCachePage(@"HomeFeedSdui", Request(@"t2_you", nil), fresh) == nil, @"Don't replay for another account");
    RFFeedCacheSetDirectory(directory);
    Check(RFFeedCachePage(@"HomeFeedSdui", Request(@"t2_me", @"f1"), second) == nil, @"Only replay a first page");
    __block BOOL announced = NO;
    id observer = [NSNotificationCenter.defaultCenter addObserverForName:RFFeedCacheDidReplayNotification
                                                                  object:nil
                                                                   queue:nil
                                                              usingBlock:^(NSNotification *note) {
                                                                announced = [note.object isEqual:@"HomeFeedSdui"];
                                                              }];
    // Latest (Home's feed sorted by new, from the side menu) uses the same operation: not For You.
    NSMutableURLRequest *latest = [Request(@"t2_me", nil) mutableCopy];
    NSMutableDictionary *latestBody = [NSJSONSerialization JSONObjectWithData:latest.HTTPBody options:NSJSONReadingMutableContainers error:NULL];
    latestBody[@"variables"][@"sort"] = @"NEW";
    latest.HTTPBody = [NSJSONSerialization dataWithJSONObject:latestBody options:0 error:NULL];
    Check(RFFeedCachePage(@"HomeFeedSdui", latest, fresh) == nil, @"Don't replay For You into Latest");
    NSData *restored = RFFeedCachePage(@"HomeFeedSdui", Request(@"t2_me", nil), fresh);
    Check([PostIds(restored) isEqual:(@[ @"t3_a", @"t3_b", @"t3_c", @"t3_d", @"t3_e" ])],
          @"Show the kept feed in the first page after a relaunch");
    double offset = 0;
    Check(RFFeedCacheRestoreTarget(@"HomeFeedSdui", &index, &offset) && index == 1 && offset == 25, @"Ask for a scroll back to the noted post");
    Check(RFFeedCacheReplayedIndex(@"HomeFeedSdui", @"r/three, Gamma, 2 upvotes") == 2 && RFFeedCacheReplayedIndex(@"HomeFeedSdui", @"r/x, Nope") == NSNotFound,
          @"Place labels on screen in the replayed feed");
    for (int i = 0; i < 50 && !announced; i++) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    Check(announced, @"Announce the replay on the main queue, with its feed");
    Check([RFFeedCacheRestoringFeeds() isEqual:@[ @"HomeFeedSdui" ]], @"Only For You is waiting to scroll back");
    [NSNotificationCenter.defaultCenter removeObserver:observer];
    // A fresh first page meanwhile (pull to refresh): the scroll back still due is out of date.
    RFFeedCachePage(@"HomeFeedSdui", Request(@"t2_me", nil), fresh);
    Check(!RFFeedCacheRestoreTarget(@"HomeFeedSdui", NULL, NULL), @"A refresh cancels the scroll back");
    RFFeedCacheEndRestore(@"HomeFeedSdui");
    Check(!RFFeedCacheRestoreTarget(@"HomeFeedSdui", NULL, NULL), @"Stop once scrolled back");
    Check(RFFeedCachePage(@"HomeFeedSdui", Request(@"t2_me", nil), fresh) == nil, @"Refresh as usual after that");
    RFFeedCacheForget();
    for (int i = 0; i < 50 && [NSFileManager.defaultManager fileExistsAtPath:path]; i++) usleep(20000);
    Check(![NSFileManager.defaultManager fileExistsAtPath:path] && RFFeedCacheEnabled(), @"Forget the kept feeds, staying on");
    [[NSJSONSerialization dataWithJSONObject:onDisk options:0 error:NULL] writeToFile:path atomically:YES];

    NSMutableDictionary *stale = [onDisk mutableCopy];
    stale[@"leftAt"] = @(NSDate.date.timeIntervalSince1970 - 13 * 60 * 60);
    [[NSJSONSerialization dataWithJSONObject:stale options:0 error:NULL] writeToFile:path atomically:YES];
    RFFeedCacheSetDirectory(directory);
    Check(RFFeedCachePage(@"HomeFeedSdui", Request(@"t2_me", nil), fresh) == nil, @"Start fresh after a long time away");
    RFFeedCacheSetDirectory(directory);
    RFFeedCacheSetMaxAge(24 * 60 * 60);
    Check(RFFeedCachePage(@"HomeFeedSdui", Request(@"t2_me", nil), fresh) != nil, @"Restore after 13 hours with 24 hours set");
    RFFeedCacheEndRestore(@"HomeFeedSdui");
    usleep(300000); // the replay saves the kept feed in the background; let it land before rewriting it
    [[NSJSONSerialization dataWithJSONObject:stale options:0 error:NULL] writeToFile:path atomically:YES];
    RFFeedCacheSetDirectory(directory);
    RFFeedCacheSetMaxAge(0);
    Check(RFFeedCachePage(@"HomeFeedSdui", Request(@"t2_me", nil), fresh) != nil, @"Restore after any time with no limit");
    RFFeedCacheEndRestore(@"HomeFeedSdui");
    RFFeedCacheSetMaxAge(12 * 60 * 60);
    usleep(300000);
    [[NSJSONSerialization dataWithJSONObject:onDisk options:0 error:NULL] writeToFile:path atomically:YES];
    RFFeedCacheSetDirectory(directory);
    RFFeedCacheSetColdReplayAllowed(NO);
    Check(RFFeedCachePage(@"HomeFeedSdui", Request(@"t2_me", nil), fresh) == nil, @"Don't restore when this launch may not");
    RFFeedCacheSetColdReplayAllowed(YES);

    RFFeedCacheSetEnabled(NO);
    for (int i = 0; i < 50 && [NSFileManager.defaultManager fileExistsAtPath:path]; i++) usleep(20000);
    Check(![NSFileManager.defaultManager fileExistsAtPath:path], @"Forget the kept feed when turned off");
    Check(RFFeedCachePage(@"HomeFeedSdui", Request(@"t2_me", nil), first) == nil, @"Keep nothing while off");

    // Following and Popular are kept apart from For You, and each takes its own list when leaving.
    RFFeedCacheSetDirectory(directory);
    RFFeedCacheSetEnabled(YES);
    Check(RFFeedCacheKeepsOperation(@"FollowingFeed") && RFFeedCacheKeepsOperation(@"PopularFeedSdui") &&
              !RFFeedCacheKeepsOperation(@"SubredditFeed") && !RFFeedCacheKeepsOperation(nil),
          @"Keep Home's three feeds only");
    NSData *forYou = Page(@[ Card(@"t3_a", @"r/one", @"Alpha"), Card(@"t3_b", @"r/two", @"Beta"), Card(@"t3_s", @"r/s", @"Shared") ], nil);
    NSData *following = Page(@[ Card(@"t3_s", @"r/s", @"Shared"), Preview(@"t3_g", @"r/g", @"Gee") ], nil);
    NSDictionary *previews = RFFeedCacheAddingPage(nil, @"t2_me", nil, following);
    Check([RFFeedCacheMatchingPosts(previews, @[ @"r/g, Gee, 3 upvotes", @"r/x, Gee" ]) isEqual:(@[ @"t3_g", NSNull.null ])],
          @"Find posts in Following's newer cards");
    NSData *popular = PageIn(@"popularV3", @[ Card(@"t3_p", @"r/p", @"Pop"), Card(@"t3_q", @"r/q", @"Queue") ], nil);
    RFFeedCachePage(@"HomeFeedSdui", Request(@"t2_me", nil), forYou);
    RFFeedCachePage(@"FollowingFeed", FeedRequest(@"FollowingFeed", @"t2_me", nil), following);
    RFFeedCachePage(@"PopularFeedSdui", FeedRequest(@"PopularFeedSdui", @"t2_me", nil), popular);
    saved = dispatch_semaphore_create(0);
    // Following's list (Shared, Gee) also has a For You post, and For You's list (Beta, Shared) a
    // Following one: each still takes its own.
    RFFeedCacheNoteLeaving(@[ @[ @"r/s, Shared", @"r/g, Gee" ], @[ @"r/two, Beta", @"r/s, Shared" ], @[ @"r/q, Queue" ] ],
                           @[ @[ @1, @2 ], @[ @3, @4 ], @[ @5 ] ], ^{
      dispatch_semaphore_signal(saved);
    });
    Check(dispatch_semaphore_wait(saved, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0, @"Save all feeds when leaving");
    NSDictionary *(^saved_)(NSString *) = ^NSDictionary *(NSString *file) {
      NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:file]];
      return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    };
    Check([saved_(@"HomeFeed.json")[@"position"] isEqual:@"t3_b"] && [saved_(@"HomeFeed.json")[@"offset"] isEqual:@3],
          @"Note For You's place from its own list");
    Check([saved_(@"FollowingFeed.json")[@"position"] isEqual:@"t3_s"] && [saved_(@"FollowingFeed.json")[@"offset"] isEqual:@1],
          @"Note Following's place from its own list");
    Check([saved_(@"PopularFeed.json")[@"position"] isEqual:@"t3_q"], @"Note Popular's place");

    RFFeedCacheSetDirectory(directory); // relaunch: Reddit opens on Following
    NSData *freshFollowing = Page(@[ Card(@"t3_h", @"r/h", @"Aitch") ], nil);
    NSData *back = RFFeedCachePage(@"FollowingFeed", FeedRequest(@"FollowingFeed", @"t2_me", nil), freshFollowing);
    Check([PostIds(back) isEqual:(@[ @"t3_s", @"t3_g", @"t3_h" ])], @"Restore Following on its own first page");
    Check([RFFeedCacheRestoringFeeds() isEqual:@[ @"FollowingFeed" ]] &&
              RFFeedCacheReplayedIndex(@"HomeFeedSdui", @"r/s, Shared") == NSNotFound,
          @"Only Following is waiting to scroll back");
    NSData *pop = RFFeedCachePage(@"PopularFeedSdui", FeedRequest(@"PopularFeedSdui", @"t2_me", nil),
                                  PageIn(@"popularV3", @[ Card(@"t3_z", @"r/z", @"Zed") ], nil));
    Check([PostIds(pop) isEqual:(@[ @"t3_p", @"t3_q", @"t3_z" ])], @"Restore Popular when it's first opened");
    NSData *home = RFFeedCachePage(@"HomeFeedSdui", Request(@"t2_me", nil), Page(@[ Card(@"t3_y", @"r/y", @"Why") ], nil));
    Check([PostIds(home) isEqual:(@[ @"t3_a", @"t3_b", @"t3_s", @"t3_y" ])], @"Restore For You when it's first opened");
    for (NSString *feed in RFFeedCacheRestoringFeeds()) RFFeedCacheEndRestore(feed);

    saved = dispatch_semaphore_create(0);
    RFFeedCacheNoteLeaving(@[ @[ @"r/y, Why" ] ], @[ @[ @0 ] ], ^{
      dispatch_semaphore_signal(saved);
    });
    dispatch_semaphore_wait(saved, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    Check(saved_(@"PopularFeed.json") && !saved_(@"PopularFeed.json")[@"position"], @"Popular's replay was saved without its place");
    Check([saved_(@"HomeFeed.json")[@"position"] isEqual:@"t3_y"], @"A feed with its list on screen gets its new place");

    // A community's feed: kept while the restore is on, replayed only for the community it opens.
    Check(!RFFeedCacheKeepsOperation(@"SubredditFeedSdui"), @"Don't keep communities unless asked");
    RFFeedCacheSetKeepsCommunities(YES);
    Check(RFFeedCacheKeepsOperation(@"SubredditFeedSdui"), @"Keep the last community when asked");
    NSURLRequest *(^community)(NSString *, NSString *, NSString *) = ^NSURLRequest *(NSString *name, NSString *sort, NSString *after) {
      NSMutableURLRequest *r = [FeedRequest(@"SubredditFeedSdui", @"t2_me", after) mutableCopy];
      NSMutableDictionary *body = [[NSJSONSerialization JSONObjectWithData:r.HTTPBody options:0 error:NULL] mutableCopy];
      NSMutableDictionary *vars = [body[@"variables"] mutableCopy];
      vars[@"subredditName"] = name;
      vars[@"sort"] = sort;
      body[@"variables"] = vars;
      r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
      return r;
    };
    NSData *iphone = PageIn(@"subredditV3", @[ Card(@"t3_i1", @"r/iphone", @"Battery tips"), Card(@"t3_i2", @"r/iphone", @"Case advice") ], @"ic1");
    RFFeedCachePage(@"SubredditFeedSdui", community(@"iPhone", @"BEST", nil), iphone);
    NSString *sort = nil;
    Check([RFFeedCacheCommunity(&sort) isEqual:@"iphone"] && [sort isEqual:@"BEST"], @"Name the kept community and its sort");
    saved = dispatch_semaphore_create(0);
    RFFeedCacheNoteLeaving(@[ @[ @"GGPlatino, 9h, Case advice, Flair: Help, 3 upvotes" ] ], @[ @[ @7 ] ], ^{
      dispatch_semaphore_signal(saved);
    });
    dispatch_semaphore_wait(saved, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    Check([saved_(@"CommunityFeed.json")[@"position"] isEqual:@"t3_i2"], @"Find a community's posts from labels without the community");
    NSData *freshIphone = PageIn(@"subredditV3", @[ Card(@"t3_i3", @"r/iphone", @"New") ], nil);
    RFFeedCacheSetDirectory(directory); // relaunch
    RFFeedCacheSetKeepsCommunities(YES);
    Check(RFFeedCachePage(@"SubredditFeedSdui", community(@"iphone", @"BEST", nil), freshIphone) == nil,
          @"Don't replay a community the restore didn't open");
    RFFeedCacheSetDirectory(directory);
    RFFeedCacheArmCommunity(@"iphone");
    Check(RFFeedCachePage(@"SubredditFeedSdui", community(@"iphone", @"NEW", nil), freshIphone) == nil,
          @"Don't replay a community in another sort");
    RFFeedCacheSetDirectory(directory);
    RFFeedCacheArmCommunity(@"iPhone");
    Check(RFFeedCachePage(@"SubredditFeedSdui", community(@"android", @"BEST", nil), freshIphone) == nil,
          @"Don't replay another community");
    RFFeedCacheSetDirectory(directory);
    RFFeedCacheArmCommunity(@"iPhone");
    NSData *backIphone = RFFeedCachePage(@"SubredditFeedSdui", community(@"iphone", @"BEST", nil), freshIphone);
    Check([PostIds(backIphone) isEqual:(@[ @"t3_i1", @"t3_i2", @"t3_i3" ])] &&
              [RFFeedCacheRestoringFeeds() containsObject:@"SubredditFeedSdui"],
          @"Replay the community the restore opened");
    RFFeedCacheEndRestore(@"SubredditFeedSdui");
    RFFeedCacheSetKeepsCommunities(NO);

    RFFeedCacheSetEnabled(NO);
    for (int i = 0; i < 50 && [NSFileManager.defaultManager fileExistsAtPath:[directory stringByAppendingPathComponent:@"FollowingFeed.json"]]; i++)
      usleep(20000);
    Check(!saved_(@"HomeFeed.json") && !saved_(@"FollowingFeed.json") && !saved_(@"PopularFeed.json"),
          @"Forget every kept feed when turned off");

    // Incognito: a logged-out token after a logged-in one in the same run keeps, notes and restores nothing.
    RFFeedCacheSetDirectory(directory);
    RFFeedCacheSetEnabled(YES);
    RFFeedCacheSetColdReplayAllowed(YES);
    NSData *normal = Page(@[ Card(@"t3_n1", @"r/n", @"Normal one"), Card(@"t3_n2", @"r/n", @"Normal two") ], nil);
    NSURLRequest *normalRequest = Request(@"t2_me", nil);
    RFFeedCacheNoteRequest(@"HomeFeedSdui", normalRequest); // as it's made
    Check(!RFFeedCacheIncognito() && [RFFeedCacheCurrentAccount() isEqual:@"t2_me"], @"Not incognito with a logged-in token");
    gTokenKind = @"loid";
    NSData *secret = Page(@[ Card(@"t3_s1", @"r/s", @"Secret") ], nil);
    NSURLRequest *secretRequest = Request(@"t2_fresh", nil);
    RFFeedCacheNoteRequest(@"HomeFeedSdui", secretRequest);
    Check(RFFeedCachePage(@"HomeFeedSdui", secretRequest, secret) == nil && RFFeedCacheIncognito(),
          @"A logged-out token after a logged-in one is incognito");
    // A reply to a request made before incognito started doesn't end it.
    RFFeedCachePage(@"HomeFeedSdui", normalRequest, normal);
    Check(RFFeedCacheIncognito() && [RFFeedCacheCurrentAccount() isEqual:@"t2_me"],
          @"A late reply from before incognito doesn't end it");
    RFFeedCacheNoteRequest(@"GetAllExperimentVariants", Request(@"t2_me", nil));
    Check(RFFeedCacheIncognito(), @"Other requests don't count");
    saved = dispatch_semaphore_create(0);
    RFFeedCacheNoteLeaving(@[ @[ @"r/s, Secret, 1 upvote" ] ], @[ @[ @0 ] ], ^{
      dispatch_semaphore_signal(saved);
    });
    dispatch_semaphore_wait(saved, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    usleep(100000);
    NSDictionary *kept = saved_(@"HomeFeed.json");
    Check(![[kept description] containsString:@"t3_s1"] && ![[kept description] containsString:@"t2_fresh"],
          @"Incognito pages and places aren't kept");
    gTokenKind = @"user";
    RFFeedCacheNoteRequest(@"HomeFeedSdui", Request(@"t2_me", nil));
    Check(!RFFeedCacheIncognito(), @"Back to the account ends incognito");
    __block NSString *changedTo = nil;
    id accountObserver = [NSNotificationCenter.defaultCenter addObserverForName:RFFeedCacheAccountDidChangeNotification
                                                                         object:nil
                                                                          queue:nil
                                                                     usingBlock:^(NSNotification *note) {
                                                                       changedTo = note.object;
                                                                     }];
    RFFeedCacheNoteRequest(@"HomeFeedSdui", Request(@"t2_other", nil));
    for (int i = 0; i < 50 && !changedTo; i++) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    Check([changedTo isEqual:@"t2_other"], @"Announce a switch to another account");
    [NSNotificationCenter.defaultCenter removeObserver:accountObserver];
    RFFeedCacheSetDirectory(directory); // relaunch: a logged-out user's first token isn't incognito
    gTokenKind = @"loid";
    RFFeedCacheNoteRequest(@"HomeFeedSdui", Request(@"loid_user", nil));
    Check(!RFFeedCacheIncognito() && !RFFeedCacheRequestIsIncognito(Request(@"loid_user", nil)), @"A logged-out user isn't incognito");
    gTokenKind = @"user";
    RFFeedCacheSetEnabled(NO);
    [NSFileManager.defaultManager removeItemAtPath:directory error:NULL];

    // Settings are applied again on every change: only a real switch off forgets.
    RFFeedCacheSetEnabled(YES);
    RFFeedCacheSetKeepsCommunities(NO); // off already (or first time): may forget once
    unsigned before = RFFeedCacheGeneration();
    RFFeedCacheSetEnabled(YES);
    RFFeedCacheSetKeepsCommunities(NO);
    RFFeedCacheSetKeepsCommunities(NO);
    Check(RFFeedCacheGeneration() == before, @"Applying the same settings again keeps what's kept");
    RFFeedCacheSetKeepsCommunities(YES);
    RFFeedCacheSetKeepsCommunities(NO);
    Check(RFFeedCacheGeneration() == before + 1, @"Turning communities off forgets once");
    RFFeedCacheSetEnabled(NO);
    unsigned off = RFFeedCacheGeneration();
    RFFeedCacheSetEnabled(NO);
    Check(RFFeedCacheGeneration() == off && off == before + 2, @"Turning it off forgets once, not on every reapply");
    RFFeedCacheSetEnabled(YES);

    // Comments
    NSDictionary *(^tree)(NSString *, NSString *, int) = ^NSDictionary *(NSString *cid, NSString *author, int depth) {
      return @{@"depth": @(depth), @"more": NSNull.null,
               @"node": @{@"__typename": @"Comment", @"id": cid, @"authorInfo": @{@"displayName": author}}};
    };
    NSDictionary *commentsJSON = @{@"data": @{@"postInfoById": @{@"commentForest": @{@"trees": @[
      tree(@"t1_a", @"ann", 0), tree(@"t1_b", @"bob", 1), @{@"depth": @2, @"more": @{@"count": @3}, @"node": NSNull.null},
      tree(@"t1_c", @"ann", 0), tree(@"t1_d", @"ann", 1),
    ]}}}};
    NSArray *rows = RFCommentRows([NSJSONSerialization dataWithJSONObject:commentsJSON options:0 error:NULL]);
    Check(rows.count == 5 && [rows[1][@"id"] isEqual:@"t1_b"] && [rows[2][@"more"] boolValue], @"Read comment rows in order, with more-replies rows");
    Check(RFCommentRowForLabel(rows, @"By bob, 2 hours ago, seven votes, Level 2", NSNotFound) == 1, @"Find a comment from its label");
    Check(RFCommentRowForLabel(rows, @"By ann, 1 hour ago, one vote, Level 1, Online status on", 3) == 3 &&
              RFCommentRowForLabel(rows, @"By ann, 1 hour ago, one vote, Level 1", 0) == 0,
          @"Pick the nearest of an author's comments at that level");
    Check(RFCommentRowForLabel(rows, @"By bob, 2 hours ago, Level 1", NSNotFound) == NSNotFound &&
              RFCommentRowForLabel(rows, @"3 more replies", NSNotFound) == NSNotFound,
          @"Don't match another level or a more-replies row");
    // Any app language: the cell's username label, nearest to where the cell sits.
    Check(RFCommentRowForCell(rows, @[ @"Kommentar", @"bob", @"vor 2 Stunden" ], nil, @"von bob, vor 2 Stunden, Level 2", NSNotFound) == 1,
          @"Find a comment from its username label in another language");
    Check(RFCommentRowForCell(rows, @[ @"ann" ], nil, @"von ann, vor 1 Stunde, Level 2", 4) == 4 &&
              RFCommentRowForCell(rows, @[ @"ann" ], nil, nil, 0) == 0,
          @"Pick the author's comment nearest the cell's place");
    Check(RFCommentRowForCell(rows, @[ @"ann" ], nil, @"By ann, 1 hour ago, one vote, Level 1", 4) == 3,
          @"Use the English label's level when there is one");
    Check(RFCommentRowForCell(rows, @[ @"3 weitere Antworten" ], nil, @"3 weitere Antworten", 2) == NSNotFound &&
              RFCommentRowForCell(rows, @[], nil, @"By bob, 2 hours ago, seven votes, Level 2", NSNotFound) == 1,
          @"No match from a more-replies row; the English label alone still works");
    // A comment that mentions someone else: its username label wins over the names in its text.
    Check(RFCommentRowForCell(rows, @[ @"ann" ], @[ @"von", @"ann", @"bob" ], nil, 1) == 0,
          @"The username label wins over names in the text");
    Check(RFCommentRowForCell(rows, @[], @[ @"von", @"bob", @"vor" ], nil, NSNotFound) == 1,
          @"Words of the description when there's no username label");
    Check(RFCommentRows([@"{}" dataUsingEncoding:NSUTF8StringEncoding]) == nil, @"No rows from something else");
    // "N more replies" opened: its row becomes what Reddit sent, in the same place.
    NSDictionary *moreJSON = @{@"data": @{@"postInfoById": @{@"commentForest": @{@"trees": @[
      tree(@"t1_a", @"ann", 0), @{@"depth": @1, @"more": @{@"count": @2, @"cursor": @"commenttree:x"}, @"node": NSNull.null},
      tree(@"t1_c", @"cat", 0), @{@"depth": @0, @"more": @{@"count": @9, @"cursor": @"commenttree:end"}, @"node": NSNull.null},
    ]}}}};
    NSArray *withMore = RFCommentRows([NSJSONSerialization dataWithJSONObject:moreJSON options:0 error:NULL]);
    Check([withMore[1][@"cursor"] isEqual:@"commenttree:x"], @"A more-replies row keeps its cursor");
    NSArray *opened = @[ @{@"id": @"t1_x", @"author": @"xan", @"depth": @1}, @{@"id": @"t1_y", @"author": @"yul", @"depth": @2} ];
    NSArray *merged = RFMergeCommentRows(withMore, @"commenttree:x", opened);
    Check(merged.count == 5 && [merged[1][@"id"] isEqual:@"t1_x"] && [merged[2][@"id"] isEqual:@"t1_y"] &&
              [merged[3][@"id"] isEqual:@"t1_c"], @"Opened replies go where their row was");
    NSArray *paged = RFMergeCommentRows(merged, @"commenttree:end", @[ @{@"id": @"t1_z", @"author": @"zed", @"depth": @0} ]);
    Check(paged.count == 5 && [paged.lastObject[@"id"] isEqual:@"t1_z"], @"The next page goes at the end");
    Check([merged[1][@"inReplies"] boolValue] && ![paged.lastObject[@"inReplies"] boolValue],
          @"Replies opened under a comment are marked, the next page isn't");
    Check(RFCommentRowsHaveNextPage(withMore) && !RFCommentRowsHaveNextPage(paged), @"Tell whether there's a next page");
    // Replies opened inside opened replies stay marked, even from a top-level cursor's level.
    NSArray *nestedMore = RFMergeCommentRows(withMore, @"commenttree:x",
        @[ @{@"id": @"t1_x", @"author": @"xan", @"depth": @1}, @{@"more": @YES, @"depth": @2, @"cursor": @"commenttree:deep"} ]);
    NSArray *nested = RFMergeCommentRows(nestedMore, @"commenttree:deep", @[ @{@"id": @"t1_w", @"author": @"wil", @"depth": @2} ]);
    Check([nested[2][@"inReplies"] boolValue] && [nested[2][@"id"] isEqual:@"t1_w"], @"Replies opened inside opened replies are marked");
    Check(RFMergeCommentRows(merged, @"commenttree:gone", opened) == nil && RFMergeCommentRows(merged, nil, opened) == nil,
          @"No merge for a cursor that isn't there");

    // Search results: each post once, with its community when one copy gives it.
    NSDictionary *searchJSON = @{@"data": @{@"search": @{@"dynamic": @{@"components": @{@"main": @{@"edges": @[
      @{@"node": @{@"children": @[
        @{@"behaviors": @{@"title": @{@"post": @{@"id": @"t3_a", @"title": @"The best apple pie ever"}},
                          @"community": @{@"post": @{@"id": @"t3_a", @"title": @"The best apple pie ever", @"subreddit": @{@"name": @"Baking"}}}}},
        @{@"post": @{@"id": @"t3_b", @"title": @"Same title", @"subreddit": @{@"name": @"Cooking"}}},
        @{@"post": @{@"id": @"t3_c", @"title": @"Same title", @"subreddit": @{@"name": @"Baking"}}},
        @{@"comment": @{@"id": @"t1_x", @"title": @"not a post"}},
      ]}},
    ]}}}}}};
    NSArray *searchPosts = RFSearchResultPosts([NSJSONSerialization dataWithJSONObject:searchJSON options:0 error:NULL]);
    Check(searchPosts.count == 3 && [searchPosts[0][@"id"] isEqual:@"t3_a"] && [searchPosts[0][@"community"] isEqual:@"Baking"],
          @"Read a search's posts once each, with their community");
    Check([RFSearchPostForTexts(searchPosts, @[ @"u/someone", @"The best apple pie ever", @"1/3" ]) isEqual:@"t3_a"],
          @"Name the post a screen shows from its title");
    Check([RFSearchPostForTexts(searchPosts, @[ @"Same title", @"\ufffc r/Cooking" ]) isEqual:@"t3_b"] &&
              RFSearchPostForTexts(searchPosts, @[ @"Same title" ]) == nil,
          @"Two posts with one title: told apart by the community shown, or not at all");
    Check(RFSearchPostForTexts(searchPosts, @[ @"Something else" ]) == nil &&
              RFSearchResultPosts([@"[]" dataUsingEncoding:NSUTF8StringEncoding]) == nil,
          @"No post from other texts or another response");
    // The same post recorded twice (a search repeated) is still one post.
    NSArray *searchTwice = [searchPosts arrayByAddingObject:@{@"id": @"t3_a", @"title": @"The best apple pie ever"}];
    Check([RFSearchPostForTexts(searchTwice, @[ @"The best apple pie ever" ]) isEqual:@"t3_a"],
          @"Copies of one post still name it");
    Check(RFSearchPostForTexts(searchPosts, @[ @"The best apple pie ever", @"r/Cooking" ]) == nil &&
              [RFSearchPostForTexts(searchPosts, @[ @"The best apple pie ever", @"r/Baking" ]) isEqual:@"t3_a"],
          @"A title match in another community shown isn't it");
    // Where a search looked: a community (subreddit_names filter) or all of Reddit.
    NSData *(^searchBody)(NSDictionary *) = ^NSData *(NSDictionary *variables) {
      return [NSJSONSerialization dataWithJSONObject:@{@"operationName": @"SearchDynamic", @"variables": variables} options:0 error:NULL];
    };
    NSDictionary *scope = RFSearchRequestScope(searchBody(@{@"query": @" cats ", @"filters": @[
      @{@"key": @"safe_search", @"value": @"unset"}, @{@"key": @"subreddit_names", @"value": @"askreddit"}]}));
    Check([scope[@"query"] isEqual:@"cats"] && [scope[@"community"] isEqual:@"askreddit"], @"Read a search in a community");
    scope = RFSearchRequestScope(searchBody(@{@"query": @"cats", @"filters": @[@{@"key": @"safe_search", @"value": @"unset"}]}));
    Check([scope[@"community"] isEqual:@""], @"Read a search of all of Reddit");
    Check([RFSearchRequestScope(searchBody(@{@"query": @"cats", @"after": NSNull.null}))[@"query"] isEqual:@"cats"] &&
              [RFSearchRequestScope(searchBody(@{@"query": @"cats", @"after": @""}))[@"query"] isEqual:@"cats"],
          @"An empty or null after is still the first page");
    Check(RFSearchRequestScope(searchBody(@{@"query": @"cats", @"after": @"x"})) == nil &&
              RFSearchRequestScope(searchBody(@{@"query": @""})) == nil && RFSearchRequestScope(nil) == nil &&
              [RFSearchRequestScope(searchBody(@{@"query": @"cats", @"filters": @[
                @{@"key": @"subreddit_names", @"value": @"a,b"}]}))[@"community"] isEqual:@""],
          @"No scope from a later page, an empty query or no body; several communities count as all");
    [NSFileManager.defaultManager removeItemAtPath:directory error:NULL];

    puts("All feed cache tests passed.");
  }
  return 0;
}
