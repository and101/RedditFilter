#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#ifdef __cplusplus
extern "C" {
#endif

// tapToo keeps Reddit's tap and long press on expanded comments while swipe is on.
void RFSetSwipeCollapse(BOOL enabled, BOOL tapToo, BOOL haptics);

// Pure gesture/label rules, kept separate so their edge cases can be tested.
BOOL RFHasLeftSwipeDirection(CGPoint translation, CGPoint velocity);
BOOL RFShouldCollapseForSwipe(CGPoint translation, CGPoint velocity);
BOOL RFShouldCollapseThreadForSwipe(CGPoint translation, CGFloat headerWidth);
CGFloat RFThreadCollapseDistance(CGFloat headerWidth);
// 0 before any threshold, 1 past Collapse, 2 past Collapse thread (only when allowed).
NSInteger RFSwipeCollapseStage(CGPoint translation, CGFloat headerWidth, BOOL threadAllowed);
BOOL RFIsExpandedCommentHeaderLabel(NSString *label);
NSInteger RFCommentLevelFromLabel(NSString *label);

#ifdef __cplusplus
}
#endif
