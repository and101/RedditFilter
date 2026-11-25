// SavedPosts.h
//
// Which posts are saved, so that Swipe posts can say "Unsave" (FeedSwipe.x). Kept in memory only, from the
// posts' details as feeds load them (FeedPostDetailsByIds) and the saves made since (UpdatePostSaveState),
// wherever they're made. Pure Foundation, so it can be tested on its own. Thread-safe.

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Call as each of those requests is made. Forgets everything when it's for another account, and gives the
// request's place in line for RFSavedPostsNoteDetails.
unsigned long long RFSavedPostsNoteRequest(NSURLRequest *request);

// The answer to a FeedPostDetailsByIds request. Posts saved or unsaved since it was made keep that.
void RFSavedPostsNoteDetails(NSURLRequest *request, NSData *response, unsigned long long order);

// The answer to an UpdatePostSaveState request.
void RFSavedPostsNoteChange(NSURLRequest *request, NSData *response);

// Whether the post with this title is known to be saved. When several have the title, the community in the
// card's label ("r/name, ..." or "r slash name, ...") decides; NO when it can't be told.
BOOL RFSavedPostsIsSaved(NSString *title, NSString *cardLabel);

// Forgets everything (Swipe posts turned off).
void RFSavedPostsForget(void);

#ifdef __cplusplus
}
#endif
