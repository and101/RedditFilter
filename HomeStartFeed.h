#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif
// Start on Following: where an account has Home's For You and Following tabs, Home opens on Following.
void RFSetStartOnFollowing(BOOL start);
// Whether Home on screen has feed tabs (For You, Following). Main thread.
BOOL RFHomeHasFeedTabs(void);
#ifdef __cplusplus
}
#endif
