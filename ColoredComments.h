#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif
// Turns colored comment thread lines on or off, recoloring the lines already on screen. Apollo style
// colors only each comment's own line and leaves the lines of the comments above it grey.
void RFSetColoredComments(BOOL enabled, BOOL apolloStyle);
#ifdef __cplusplus
}
#endif
