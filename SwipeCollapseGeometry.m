#import "SwipeCollapse.h"

// Require a deliberate horizontal gesture. The larger ratio keeps vertical comment
// scrolling and small diagonal finger movement from collapsing a comment by accident.
static const CGFloat kRFCollapseDistance = 48.0;
static const CGFloat kRFCollapseVelocity = 500.0;
static const CGFloat kRFHorizontalRatio = 1.4;
static const CGFloat kRFThreadMinimumDistance = 120.0;
static const CGFloat kRFThreadWidthFraction = 0.35;
// Right swipes starting this close to the left of the screen stay as Reddit's back gesture.
static const CGFloat kRFBackEdgeWidth = 24.0;

CGPoint RFMirroredSwipeVector(CGPoint vector) {
  return CGPointMake(-vector.x, vector.y);
}

// UIKit asks shouldBegin after only a few points of movement. Use the current
// direction there; the deliberate short/long distance checks happen at the end.
BOOL RFHasLeftSwipeDirection(CGPoint translation, CGPoint velocity) {
  CGFloat dx = -translation.x;
  CGFloat dy = fabs(translation.y);
  CGFloat vx = -velocity.x;
  CGFloat vy = fabs(velocity.y);
  BOOL movedLeft = translation.x < 0 && dx >= dy * 1.05;
  BOOL movingLeft = velocity.x < 0 && vx >= vy * 1.05;
  return movedLeft || movingLeft;
}

NSInteger RFSwipeDirectionToClaim(CGPoint translation, CGPoint velocity, CGFloat startX, BOOL rightToo,
                                  BOOL rightOnly) {
  if (RFHasLeftSwipeDirection(translation, velocity)) return rightToo && rightOnly ? 0 : -1;
  if (!rightToo || startX < kRFBackEdgeWidth) return 0;
  return RFHasLeftSwipeDirection(RFMirroredSwipeVector(translation), RFMirroredSwipeVector(velocity)) ? 1 : 0;
}

BOOL RFShouldCollapseForSwipe(CGPoint translation, CGPoint velocity) {
  CGFloat dx = -translation.x;
  CGFloat dy = fabs(translation.y);
  CGFloat vx = -velocity.x;
  CGFloat vy = fabs(velocity.y);
  BOOL travelledLeft = translation.x < 0 && dx >= dy * kRFHorizontalRatio;
  BOOL farEnough = dx >= kRFCollapseDistance;
  BOOL fastEnough = velocity.x < 0 && vx >= kRFCollapseVelocity && vx >= vy * kRFHorizontalRatio;
  return travelledLeft && (farEnough || fastEnough);
}

CGFloat RFThreadCollapseDistance(CGFloat headerWidth) {
  return MAX(kRFThreadMinimumDistance, headerWidth * kRFThreadWidthFraction);
}

BOOL RFShouldCollapseThreadForSwipe(CGPoint translation, CGFloat headerWidth) {
  CGFloat dx = -translation.x;
  CGFloat dy = fabs(translation.y);
  BOOL travelledLeft = translation.x < 0 && dx >= dy * kRFHorizontalRatio;
  return travelledLeft && dx >= RFThreadCollapseDistance(headerWidth);
}

NSInteger RFSwipeCollapseStage(CGPoint translation, CGFloat headerWidth, BOOL threadAllowed) {
  if (threadAllowed && RFShouldCollapseThreadForSwipe(translation, headerWidth)) return 2;
  return RFShouldCollapseForSwipe(translation, CGPointZero) ? 1 : 0;
}

NSInteger RFCommentLevelFromLabel(NSString *label) {
  if (![label isKindOfClass:NSString.class]) return 0;
  NSRange range = [label rangeOfString:@"Level " options:NSCaseInsensitiveSearch | NSBackwardsSearch];
  if (range.location == NSNotFound) return 0;
  NSScanner *scanner = [NSScanner scannerWithString:[label substringFromIndex:NSMaxRange(range)]];
  NSInteger level = 0;
  return [scanner scanInteger:&level] && level >= 1 ? level : 0;
}

BOOL RFIsExpandedCommentHeaderLabel(NSString *label) {
  if (![label isKindOfClass:NSString.class]) return NO;
  BOOL comment = [label hasPrefix:@"By "] || [label hasPrefix:@"Comment by "];
  return comment && RFCommentLevelFromLabel(label) >= 1;
}
