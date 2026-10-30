#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif
// The update found by the last check, as "1.3.2 for Reddit 2026.43.0", or nil if there is none.
NSString *RFAvailableUpdate(void);
// Its release page, or the releases page if there's no update.
NSURL *RFUpdateURL(void);
#ifdef __cplusplus
}
#endif
