// SwipeGestures.h
//
// Gesture helpers from SwipeCollapse.x that the post swipes (FeedSwipe.x) share. UIKit, so kept out of
// SwipeCollapse.h, which the macOS tests compile.

#import <UIKit/UIKit.h>

// Whether a touch starts on something with its own sideways gesture (gallery, slider, player...).
BOOL RFTouchBelongsToOwnHorizontalGesture(UIView *view, UIView *card);
// Turns off the scrolling and paging pans above the card while a swipe runs; right swipes also hold
// off going back. Undo with RFRestorePagerRecognizersForSwipe.
void RFSuppressPagerRecognizersForSwipe(UIView *card, UIPanGestureRecognizer *swipe, BOOL right);
void RFRestorePagerRecognizersForSwipe(UIPanGestureRecognizer *swipe);
// Restores them if UIKit fails the swipe straight after it was allowed to begin.
void RFRestorePagersIfSwipeNeverBegan(UIPanGestureRecognizer *swipe, NSInteger checksLeft);
