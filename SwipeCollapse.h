#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#ifdef __cplusplus
extern "C" {
#endif

// tapToo keeps Reddit's tap and long press on expanded comments while swipe is on.
// rightToo also collapses on right swipes that don't start at the screen's left edge.
// rightOnly leaves left swipes to Reddit, and needs rightToo.
void RFSetSwipeCollapse(BOOL enabled, BOOL tapToo, BOOL haptics, BOOL rightToo, BOOL rightOnly);

// Pure gesture/label rules, kept separate so their edge cases can be tested.
// The collapse rules below are written for left swipes; mirror a right swipe to use them.
CGPoint RFMirroredSwipeVector(CGPoint vector);
BOOL RFHasLeftSwipeDirection(CGPoint translation, CGPoint velocity);
// -1 for a left swipe to claim, 1 for a right one, 0 to leave it with Reddit.
// startX is where the finger first touched, in screen points.
NSInteger RFSwipeDirectionToClaim(CGPoint translation, CGPoint velocity, CGFloat startX, BOOL rightToo,
                                  BOOL rightOnly);
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
