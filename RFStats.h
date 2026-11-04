// RFStats.h
//
// Counts what RedditFilter hides, per filter, so the settings can show it working. Kept on the
// device only (in NSUserDefaults) and survives restarts until the user resets it. Counts are
// approximate: an item with an ID is counted once per launch, but one Reddit sends again after a
// restart counts again.

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, RFStat) {
  RFStatFeedAds,         // promoted posts in feeds
  RFStatCommentAds,      // ads on post pages, between comments
  RFStatRecommended,     // recommendations on post pages
  RFStatVideosForYou,    // the Videos for you carousel
  RFStatNSFW,            // NSFW posts
  RFStatKeywordPosts,    // posts that mention a keyword
  RFStatKeywordComments, // comments that mention a keyword, and replies hidden with them
  RFStatExtraCards,      // suggestion, promo and survey cards in feeds
  RFStatCount
};

// Keys of RFStatsSnapshot()
extern NSString *const kRFStatsCounts; // NSArray<NSNumber *>, indexed by RFStat
extern NSString *const kRFStatsDays;   // NSDictionary<NSString *, NSNumber *>: "yyyy-MM-dd" -> total that day
extern NSString *const kRFStatsSince;  // NSDate: first launch with stats, or the last reset

// Posted on the main queue shortly after the counts change.
extern NSString *const RFStatsDidChangeNotification;

#ifdef __cplusplus
extern "C" {
#endif

// Counts one hidden item. With an identifier, the same item is only counted once per launch
// (Reddit often sends a post twice: in the feed, then again with its details). Thread-safe.
void RFStatsRecord(RFStat stat, NSString *identifier);

// Current counts and when they started. Thread-safe.
NSDictionary *RFStatsSnapshot(void);

// Sets everything back to zero, from now.
void RFStatsReset(void);

// "yyyy-MM-dd" for a date in the device's time zone, as used by kRFStatsDays.
NSString *RFStatsDayKey(NSDate *date);

// For tests: keep counts in memory only.
void RFStatsDisableSaving(void);

#ifdef __cplusplus
}
#endif
