// FeedSwipe.h
//
// Swipe posts: in feeds, a short swipe left upvotes a post, a longer one downvotes it, and a swipe right
// saves it. Each presses the post's own button (or Save in its ⋯ menu), so a second swipe undoes it.

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

void RFSetFeedSwipe(BOOL enabled, BOOL haptics);
// Whether Swipe posts is on (any thread).
BOOL RFFeedSwipeEnabled(void);

#ifdef __cplusplus
}
#endif
