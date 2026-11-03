// RFStatsViewController.h
//
// What RedditFilter has hidden: a total and a breakdown per filter (RFStats.h).

#import <UIKit/UIKit.h>

@interface RFStatsViewController : UITableViewController
@end

#ifdef __cplusplus
extern "C" {
#endif
// "1,284"
NSString *RFStatsFormattedCount(unsigned long long count);
// "since 3 November 2026", or "since today"
NSString *RFStatsSinceText(NSDate *since);
#ifdef __cplusplus
}
#endif
