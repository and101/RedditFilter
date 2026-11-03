#import <Foundation/Foundation.h>

@class UIViewController;

typedef NS_ENUM(NSInteger, RFUpdateStatus) {
  RFUpdateStatusFailed,    // GitHub couldn't be reached, or sent something unexpected
  RFUpdateStatusUpToDate,  // the latest release isn't newer than this one
  RFUpdateStatusAvailable, // the latest release is newer (see RFAvailableUpdate)
};

#ifdef __cplusplus
extern "C" {
#endif
// The update found by the last check, as "1.3.2 for Reddit 2026.43.0", or nil if there is none.
NSString *RFAvailableUpdate(void);
// Its release page, or the releases page if there's no update.
NSURL *RFUpdateURL(void);
// Asks GitHub for the latest release now and saves it, as the daily check does. Calls completion on
// the main queue.
void RFFetchLatestRelease(void (^completion)(RFUpdateStatus status));
// "Check for updates" tapped: checks now, whether or not the daily check is on, and shows the result
// in an alert over `presenter`. Calls finished on the main queue once the result is known.
void RFCheckForUpdateNow(UIViewController *presenter, void (^finished)(void));
#ifdef __cplusplus
}
#endif
