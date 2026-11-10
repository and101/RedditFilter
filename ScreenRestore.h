// ScreenRestore.h
//
// Restore open community and post: after iOS closes Reddit in the background, reopens the communities,
// profiles and posts that were open on Home or in the You tab, with a jump back to your comment.

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
// Forgets every post's comments (the comment filters changed, another account, incognito).
void RFScreenRestoreForgetComments(void);

// How the app was last closed, for Diagnostics: "Closed by iOS", "Swiped away", ...
NSString *RFLastCloseDescription(void);

#ifdef __cplusplus
}
#endif
