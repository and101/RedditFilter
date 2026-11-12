#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif
// Hides the floating "new posts" button Reddit shows at the top of Home (tapping it reloads the feed).
void RFSetHideRefreshPill(BOOL hide);
#ifdef __cplusplus
}
#endif
