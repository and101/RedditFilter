#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#ifdef __cplusplus
extern "C" {
#endif

void RFSetSwipeCollapse(BOOL enabled);

// Pure gesture/label rules, kept separate so their edge cases can be tested.
BOOL RFHasLeftSwipeDirection(CGPoint translation, CGPoint velocity);
BOOL RFShouldCollapseForSwipe(CGPoint translation, CGPoint velocity);
BOOL RFShouldCollapseThreadForSwipe(CGPoint translation, CGFloat headerWidth);
CGFloat RFThreadCollapseDistance(CGFloat headerWidth);
BOOL RFIsExpandedCommentHeaderLabel(NSString *label);
NSInteger RFCommentLevelFromLabel(NSString *label);

#ifdef __cplusplus
}
#endif
