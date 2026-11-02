#import <Foundation/Foundation.h>
#import "SwipeCollapse.h"

static void Check(BOOL condition, NSString *message) {
  if (condition) return;
  NSLog(@"FAIL: %@", message);
  exit(1);
}

int main(void) {
  @autoreleasepool {
    Check(RFHasLeftSwipeDirection(CGPointMake(-1.3, 0), CGPointZero),
          @"UIKit can ask shouldBegin after a few horizontal points");
    Check(RFHasLeftSwipeDirection(CGPointZero, CGPointMake(-200, 0)),
          @"A leftward initial velocity should begin");
    Check(!RFHasLeftSwipeDirection(CGPointMake(-2, 4), CGPointZero),
          @"An initial vertical direction should not begin");
    Check(!RFHasLeftSwipeDirection(CGPointZero, CGPointMake(200, 0)),
          @"A rightward initial velocity should not begin");

    Check(RFShouldCollapseForSwipe(CGPointMake(-60, 8), CGPointZero), @"A far left swipe should collapse");
    Check(RFShouldCollapseForSwipe(CGPointMake(-18, 2), CGPointMake(-700, 0)), @"A left flick should collapse");
    Check(!RFShouldCollapseForSwipe(CGPointMake(60, 2), CGPointZero), @"A right swipe should not collapse");
    Check(!RFShouldCollapseForSwipe(CGPointMake(-60, 50), CGPointZero), @"A diagonal gesture should not collapse");
    Check(!RFShouldCollapseForSwipe(CGPointMake(-20, 2), CGPointMake(-300, 0)), @"A short slow swipe should not collapse");
    Check(RFShouldCollapseForSwipe(CGPointMake(-60, 2), CGPointMake(700, 0)), @"Left travel still wins if the finger rebounds");

    Check(RFThreadCollapseDistance(300) == 120, @"Narrow headers use the minimum thread threshold");
    Check(RFThreadCollapseDistance(400) == 140, @"Wide headers use 35 percent of their width");
    Check(!RFShouldCollapseThreadForSwipe(CGPointMake(-100, 2), 300), @"A short swipe should collapse only the comment");
    Check(RFShouldCollapseThreadForSwipe(CGPointMake(-121, 2), 300), @"A long swipe should collapse the thread");
    Check(!RFShouldCollapseThreadForSwipe(CGPointMake(140, 2), 400), @"A right swipe should not collapse the thread");
    Check(!RFShouldCollapseThreadForSwipe(CGPointMake(-140, 120), 400), @"A diagonal swipe should not collapse the thread");

    Check(RFSwipeCollapseStage(CGPointMake(-30, 2), 300, YES) == 0, @"A short drag has crossed no threshold");
    Check(RFSwipeCollapseStage(CGPointMake(-60, 2), 300, YES) == 1, @"Past the collapse distance is the first threshold");
    Check(RFSwipeCollapseStage(CGPointMake(-121, 2), 300, YES) == 2, @"Past the thread distance is the second threshold");
    Check(RFSwipeCollapseStage(CGPointMake(-121, 2), 300, NO) == 1, @"A top-level comment has no thread threshold");
    Check(RFSwipeCollapseStage(CGPointMake(-60, 50), 300, YES) == 0, @"A diagonal drag crosses no threshold");

    Check(RFCommentLevelFromLabel(@"Comment by user, 1h ago, 10 votes, Level 3") == 3,
          @"A comment label exposes its reply level");
    Check(RFCommentLevelFromLabel(@"Comment by user, 1h ago") == 0,
          @"A collapsed comment has no reply level");
    Check(RFCommentLevelFromLabel(@"r/apple, A post title, 10 votes") == 0,
          @"A post is not a comment header");
    Check(RFIsExpandedCommentHeaderLabel(@"By user, 1h ago, 10 votes, Level 2"), @"Expanded legacy header");
    Check(RFIsExpandedCommentHeaderLabel(@"Comment by user, 1h ago, 10 votes, Level 2"), @"Expanded tree header");
    Check(!RFIsExpandedCommentHeaderLabel(@"Comment by user, 1h ago"), @"Collapsed comment has no level");
    Check(!RFIsExpandedCommentHeaderLabel(@"r/apple, A post title, 10 votes"), @"Feed post is not a comment header");
    puts("All swipe-to-collapse tests passed.");
  }
  return 0;
}
