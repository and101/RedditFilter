#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif
// The newer RedditFilter version found by the last update check, or nil if this one is the latest.
NSString *RFAvailableUpdate(void);
// Its release page, or the releases page if there's no update.
NSURL *RFUpdateURL(void);
#ifdef __cplusplus
}
#endif
