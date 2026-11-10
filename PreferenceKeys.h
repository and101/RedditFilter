// PreferenceKeys.h
//
// The keys of RedditFilter's own settings. Kept Foundation only (unlike Preferences.h, which
// imports UIKit) so the macOS tests and the backup code can use them.

#import <Foundation/Foundation.h>

#define kRedditFilterPromoted @"kRedditFilterPromoted"
#define kRedditFilterRecommended @"kRedditFilterRecommended"
#define kRedditFilterNSFW @"kRedditFilterNSFW"
#define kRedditFilterAwards @"kRedditFilterAwards"
#define kRedditFilterScores @"kRedditFilterScores"
#define kRedditFilterAutoCollapseAutoMod @"kRedditFilterAutoCollapseAutoMod"
#define kRedditFilterSwipeToCollapse @"kRedditFilterSwipeToCollapse"
#define kRedditFilterSwipeCollapseHaptics @"kRedditFilterSwipeCollapseHaptics"
#define kRedditFilterTapToCollapse @"kRedditFilterTapToCollapse" // with swipe on, keep tap and long press too
#define kRedditFilterSwipeLeftToCollapse @"kRedditFilterSwipeLeftToCollapse" // with swipe on, left swipes collapse
#define kRedditFilterSwipeRightToCollapse @"kRedditFilterSwipeRightToCollapse" // with swipe on, right swipes collapse
#define kRedditFilterVideosForYou @"kRedditFilterVideosForYou"
#define kRedditFilterExtraCards @"kRedditFilterExtraCards" // hide suggestion, promo and survey cards in feeds
#define kRedditFilterKeywords @"kRedditFilterKeywords" // array of strings
#define kRedditFilterKeywordComments @"kRedditFilterKeywordComments"
#define kRedditFilterKeywordCommentReplies @"kRedditFilterKeywordCommentReplies"
#define kRedditFilterRedgifsDirect @"kRedditFilterRedgifsDirect"
#define kRedditFilterRedgifsHD @"kRedditFilterRedgifsHD"
#define kRedditFilterRedgifsHDWiFiOnly @"kRedditFilterRedgifsHDWiFiOnly"
#define kRedditFilterColoredComments @"kRedditFilterColoredComments"
#define kRedditFilterColoredCommentsApollo @"kRedditFilterColoredCommentsApollo"
#define kRedditFilterHideLinkPanel @"kRedditFilterHideLinkPanel"
#define kRedditFilterKeepFeedPosition @"kRedditFilterKeepFeedPosition" // don't reload Home after time away
#define kRedditFilterRestoreScreens @"kRedditFilterRestoreScreens" // reopen the community and post left open
#define kRedditFilterRestoreAfterSwipe @"kRedditFilterRestoreAfterSwipe" // restore even after Reddit was swiped away
#define kRedditFilterRestoreHours @"kRedditFilterRestoreHours" // restore for 12 or 24 hours after leaving, 0 = always
#define kRedditFilterSafariLinks @"kRedditFilterSafariLinks"
#define kRedditFilterCheckUpdates @"kRedditFilterCheckUpdates"
#define kRedditFilterDiagnostics @"kRedditFilterDiagnostics" // record schema paths for bug reports
