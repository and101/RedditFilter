// ScreenRestore.h
//
// Restore open community and post: after iOS closes Reddit in the background, reopens the communities,
// profiles and posts that were open on Home, in the You tab or in the Inbox, with a jump back to your comment.

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Turns the restore on or off (it also needs Keep feed position).
void RFSetRestoreScreens(BOOL restore);
// For the feeds and these screens: restore even after Reddit was swiped away (otherwise only after iOS
// closed it), and for how many hours after leaving (0 = always).
void RFSetRestoreOptions(BOOL afterSwipe, NSInteger hours);
// Whether comment pages should be passed to RFScreenRestoreCommentsPage.
BOOL RFScreenRestoreWantsComments(void);
// Takes a post's comments (PostInfoByIdComments) as they're handed to the app, to note where you are in
// them. Always returns nil.
NSData *RFScreenRestoreCommentsPage(NSURLRequest *request, NSData *page);
// Takes a search's results (SearchDynamic) as they're handed to the app, so a post opened from them in the
// full-screen viewer can be named. Always returns nil.
// `generation` is RFScreenRestoreSearchGeneration() as the request was made: an answer from before the
// searches were forgotten (another account) is dropped. `order` is RFScreenRestoreNextSearchOrder() as the
// request was made: an older answer arriving later doesn't change where a newer search looked.
NSData *RFScreenRestoreSearchPage(NSURLRequest *request, NSData *page, unsigned generation, unsigned long long order);
unsigned long long RFScreenRestoreNextSearchOrder(void);
unsigned RFScreenRestoreSearchGeneration(void);
// Takes a custom feed's request (FetchMulti, MultiredditPostsSdui) as it's made, to name the custom feed
// screen being opened.
void RFScreenRestoreCustomFeedRequest(NSURLRequest *request);
// Takes a feed's first page as it's handed to the app, to name the screen it's for: Popular, or Latest from
// the side menu (Reddit's own feed screens are all one class, titled in the app's language).
void RFScreenRestoreFeedPage(NSString *operation, NSURLRequest *request);
// Forgets every post's comments (the comment filters changed, another account, incognito).
void RFScreenRestoreForgetComments(void);

// How the app was last closed, for Diagnostics: "Closed by iOS", "Swiped away", ...
NSString *RFLastCloseDescription(void);

#ifdef __cplusplus
}
#endif
