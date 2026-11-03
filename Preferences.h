#import <UIKit/UIKit.h>

#define kRedditFilterPromoted @"kRedditFilterPromoted"
#define kRedditFilterRecommended @"kRedditFilterRecommended"
#define kRedditFilterNSFW @"kRedditFilterNSFW"
#define kRedditFilterAwards @"kRedditFilterAwards"
#define kRedditFilterScores @"kRedditFilterScores"
#define kRedditFilterAutoCollapseAutoMod @"kRedditFilterAutoCollapseAutoMod"
#define kRedditFilterSwipeToCollapse @"kRedditFilterSwipeToCollapse"
#define kRedditFilterSwipeCollapseHaptics @"kRedditFilterSwipeCollapseHaptics"
#define kRedditFilterTapToCollapse @"kRedditFilterTapToCollapse" // with swipe on, keep tap and long press too
#define kRedditFilterVideosForYou @"kRedditFilterVideosForYou"
#define kRedditFilterKeywords @"kRedditFilterKeywords" // array of strings
#define kRedditFilterKeywordComments @"kRedditFilterKeywordComments"
#define kRedditFilterKeywordCommentReplies @"kRedditFilterKeywordCommentReplies"
#define kRedditFilterRedgifsDirect @"kRedditFilterRedgifsDirect"
#define kRedditFilterRedgifsHD @"kRedditFilterRedgifsHD"
#define kRedditFilterRedgifsHDWiFiOnly @"kRedditFilterRedgifsHDWiFiOnly"
#define kRedditFilterColoredComments @"kRedditFilterColoredComments"
#define kRedditFilterColoredCommentsApollo @"kRedditFilterColoredCommentsApollo"
#define kRedditFilterCheckUpdates @"kRedditFilterCheckUpdates"
#define kRedditFilterDiagnostics @"kRedditFilterDiagnostics" // record schema paths for bug reports

#define kToggleCellID @"kToggleCellID"

// Defined in Tweak.xm, used by the settings screen.
#ifdef __cplusplus
extern "C" {
#endif
void RFReloadPreferences(void); // call after changing a setting
BOOL RFCleanCachedExperiments(void); // YES if it removed experiments the running app may still use
UIImage *iconWithName(NSString *iconName);
Class CoreClass(NSString *name);
#ifdef __cplusplus
}
#endif
