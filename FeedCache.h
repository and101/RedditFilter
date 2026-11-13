// FeedCache.h
//
// Brings Home's feeds back to where you were after iOS closed Reddit in the background (Keep feed
// position). Pure Foundation, so it can be tested on its own; FeedPosition.x reads the screen and
// Tweak.xm feeds it the pages.

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - Building blocks (no state)

// The account a request is for: the account ID in its login token, or the logged-out ID. nil if
// neither is there.
NSString *RFFeedAccount(NSURLRequest *request);

// A kept feed with a page added: a first page (after == nil) starts it again, and the page
// that follows the kept ones (after == its cursor, same account) is added to the end. Ads and hidden
// posts aren't kept, and only the newest posts are. nil if the page doesn't belong.
NSDictionary *RFFeedCacheAddingPage(NSDictionary *cache, NSString *account, NSString *after, NSData *page);

// The kept post each of the screen's post labels ("r/sub, title, ...") belongs to, or NSNull.
NSArray *RFFeedCacheMatchingPosts(NSDictionary *cache, NSArray<NSString *> *labels);

// The kept feed with the post at the top of the screen, how far into it you'd scrolled, and when the
// app was left.
NSDictionary *RFFeedCacheLeftAt(NSDictionary *cache, NSString *postId, double offset, NSDate *date);

// A feed's first page after a relaunch: the fresh page with all the kept posts (each once) in front of
// its own posts (minus repeats). Paging carries on from the fresh page. Gives the kept posts as
// replayed and where the noted post is among them. nil if the noted post isn't kept or the page can't
// be read.
NSData *RFFeedReplayPage(NSDictionary *cache, NSData *freshPage, NSArray **keptEdges, NSUInteger *positionIndex);

#pragma mark - Comments (no state)

// The rows of a post's comments as PostInfoByIdComments sends them, in the order they're shown: one per
// comment (@"id": t1_..., @"author", @"depth": 0 for top level) and one per "N more replies" row
// (@"more": @YES). nil if the response can't be read.
NSArray<NSDictionary *> *RFCommentRows(NSData *response);
// `rows` with the "more" row Reddit opened with `cursor` ("N more replies", or the next page at the end)
// replaced by what it got (`opened`, rows of the answer to that request), as the page shows them. nil if no
// row has that cursor. Rows opened under a comment (not the next page) get "inReplies": YES.
NSArray<NSDictionary *> *RFMergeCommentRows(NSArray<NSDictionary *> *rows, NSString *cursor, NSArray<NSDictionary *> *opened);
// Whether Reddit has another page of comments for the end of `rows` (it loads it as you get there).
BOOL RFCommentRowsHaveNextPage(NSArray<NSDictionary *> *rows);

// Which row a comment's label on screen belongs to ("By author, 2 hours ago, 7 votes, Level 2"), the one
// nearest `near` if the author has more than one at that level. NSNotFound if none.
NSUInteger RFCommentRowForLabel(NSArray<NSDictionary *> *rows, NSString *label, NSUInteger near);

// Which row a comment cell on screen belongs to, in any app language: the row nearest `near` whose
// author is one of the texts the cell shows (its username label), or failing that one of the words of
// its descriptions. The English label's level narrows it when there is one. Falls back to
// RFCommentRowForLabel. NSNotFound if none.
NSUInteger RFCommentRowForCell(NSArray<NSDictionary *> *rows, NSArray<NSString *> *texts, NSArray<NSString *> *words,
                               NSString *label, NSUInteger near);

// The posts in a search's results (SearchDynamic): @{@"id": t3_..., @"title", @"community" (when given)}, once
// each. nil if the response can't be read.
NSArray<NSDictionary *> *RFSearchResultPosts(NSData *response);

// What a search request (SearchDynamic's body) searched for, and in which community: @{@"query": text,
// @"community": name, or "" for all of Reddit}. nil if it can't be read, or for a later page of results.
NSDictionary<NSString *, NSString *> *RFSearchRequestScope(NSData *body);

// Which of those posts a screen shows: the one whose title is among the screen's texts, and (when two share
// a title) whose community is too. nil if none, or it can't be told.
NSString *RFSearchPostForTexts(NSArray<NSDictionary *> *posts, NSArray<NSString *> *texts);

#pragma mark - The kept feeds (thread-safe)

// Home's feeds are kept separately, each with its own name: For You ("HomeFeedSdui"), Latest
// ("LatestFeed", Home's feed sorted by new, from the side menu), Following ("FollowingFeed") and
// Popular ("PopularFeedSdui"). Each is restored the first time it loads after a relaunch, and the
// last community opened is the fifth ("SubredditFeedSdui", see below). Latest and Popular from the side
// menu are restored when the screen restore reopens them (see RFFeedCacheArmFeed).
BOOL RFFeedCacheKeepsOperation(NSString *operation);
// Which of those a request's page is for, as a feed's name, or nil if it isn't one of them.
NSString *RFFeedNameForPage(NSString *operation, NSURLRequest *request);

// The last community opened is kept too while this is on (Restore open community and post). It's only
// replayed when RFFeedCacheArmCommunity asked for it, and only in the sort it was kept in. Off forgets it.
void RFFeedCacheSetKeepsCommunities(BOOL keeps);
// The next first page of this community's feed is replayed (once).
void RFFeedCacheArmCommunity(NSString *name);
// The kept community (lowercased) and its sort, or nil.
NSString *RFFeedCacheCommunity(NSString **sort);

// Latest, and Popular when the side menu opens it as a screen pushed on Home, are only replayed when the
// restore reopens that screen: opening them starts at the top, so a feed kept hours ago doesn't come back
// with the newest posts below it (Latest is sorted by new). The restore arms it with RFFeedCacheArmFeed;
// Popular as one of Home's own tabs replays on its first page as before.
void RFFeedCacheArmFeed(NSString *feed);
// Takes the arm back (the screen couldn't be opened), so a screen opened later doesn't use it.
void RFFeedCacheDisarmFeed(NSString *feed);
// A feed screen (Popular, Latest) has been pushed on a tab, as the side menu's rows do: the first page of a
// feed that comes now is for it, not for one of Home's tabs.
void RFFeedCacheNotePushedFeedScreen(void);

// Takes the login token of each request (only the feeds' and comments' count): incognito (a logged-out
// token after a logged-in one in the same run) keeps and notes nothing, and restores nothing.
void RFFeedCacheNoteRequest(NSString *operation, NSURLRequest *request);
BOOL RFFeedCacheIncognito(void);
// Whether a request was made in incognito (by its own token, whatever's current now).
BOOL RFFeedCacheRequestIsIncognito(NSURLRequest *request);
// The account the app's using (not incognito), from its requests; nil until one's been made. When it
// changes, or incognito starts, RFFeedCacheAccountDidChangeNotification goes out on the main queue
// (object: the new account, nil for incognito).
NSString *RFFeedCacheCurrentAccount(void);
extern NSNotificationName const RFFeedCacheAccountDidChangeNotification;
// Forgets the kept feeds and any scroll back due (when the filters change, so posts they'd now hide aren't
// replayed); RFFeedCacheDidForgetNotification then goes out on the main queue.
void RFFeedCacheForget(void);
extern NSNotificationName const RFFeedCacheDidForgetNotification;
// Goes up whenever what's kept is thrown away; a request remembers it as it's made, for RFFeedCachePageFrom.
unsigned RFFeedCacheGeneration(void);
// RFFeedCachePage for a page whose request was made in `generation`: dropped if that's over.
NSData *RFFeedCachePageFrom(NSString *operation, NSURLRequest *request, NSData *page, unsigned generation);

// How long after leaving the kept feeds are still restored (default 12 hours); 0 for no limit.
void RFFeedCacheSetMaxAge(NSTimeInterval maxAge);
// Whether this launch may restore the kept feeds at all (decided from how the app was last closed).
// Off until it's set.
void RFFeedCacheSetColdReplayAllowed(BOOL allowed);

// Turns keeping the feeds on or off. Off forgets them.
void RFFeedCacheSetEnabled(BOOL enabled);
BOOL RFFeedCacheEnabled(void);

// Where the kept feeds are saved (default: Library/Caches/RedditFilter). For tests; also acts as a
// relaunch (forgets what's in memory).
void RFFeedCacheSetDirectory(NSString *directory);

// Takes a feed page as it's handed to the app. Returns the page to hand over instead (the feed's
// first page after a relaunch, with the kept feed), or nil to hand it over as it is. After a replay,
// RFFeedCacheDidReplayNotification goes out on the main queue (object: the feed's name) so the list
// can be scrolled back.
NSData *RFFeedCachePage(NSString *operation, NSURLRequest *request, NSData *page);
extern NSNotificationName const RFFeedCacheDidReplayNotification;

// The feeds waiting to be scrolled back.
NSArray<NSString *> *RFFeedCacheRestoringFeeds(void);
// While a feed's scroll back is due: where its noted post is among the replayed kept posts, and how
// far into it to scroll. NO once it's done. `feed` is one of the names above.
BOOL RFFeedCacheRestoreTarget(NSString *feed, NSUInteger *index, double *offset);
// Which of a feed's replayed kept posts a label on screen belongs to, or NSNotFound.
NSUInteger RFFeedCacheReplayedIndex(NSString *feed, NSString *label);
// The feed's scroll back is done (or given up).
void RFFeedCacheEndRestore(NSString *feed);

// The app is going to the background: notes the post at the top of each kept feed, found from the
// post labels of each list on screen (each feed takes the list with the most of its posts), and how
// far into it you'd scrolled (offsetLists: one per label, the points from the top of its cell to the
// top of the screen), then saves the feeds. completion runs once they're saved (on any thread).
void RFFeedCacheNoteLeaving(NSArray<NSArray<NSString *> *> *labelLists, NSArray<NSArray<NSNumber *> *> *offsetLists,
                            void (^completion)(void));

#ifdef __cplusplus
}
#endif
