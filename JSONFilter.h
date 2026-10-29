// JSONFilter.h
//
// Pure-Foundation response filtering used by the NSURLSession hook in
// Tweak.xm. Nothing in here touches UIKit or Reddit classes, which keeps the
// logic small, easy to read and testable on its own.

#import <Foundation/Foundation.h>

typedef struct {
  BOOL promoted;
  BOOL recommended;
  BOOL nsfw;
  BOOL awards;
  BOOL scores;
  BOOL automod;
  BOOL videosForYou;
  BOOL keywords; // YES when RFSetFilterKeywords was given at least one keyword
  BOOL keywordComments; // also hide comments that mention a keyword
  BOOL keywordCommentReplies; // ...and their replies. NO: leave a placeholder and keep the replies
  BOOL redgifsDirect; // play RedGIFs videos from RedGIFs, with sound, instead of Reddit's silent copy
} RFPrefs;

#ifdef __cplusplus
extern "C" {
#endif

// YES if at least one filter is switched on.
BOOL RFPrefsAnyEnabled(RFPrefs prefs);

// Posts whose title or text contains one of these words or phrases are hidden
// (and comments too with keywordComments). Matching is whole-word and ignores
// case and accents. Thread-safe.
void RFSetFilterKeywords(NSArray<NSString *> *keywords);

// Best-effort GraphQL operation name for a request: the Apollo
// X-APOLLO-OPERATION-NAME header, then "operationName" in the JSON body, then
// the ?operationName= query item. Returns @"Unknown" when none is found.
NSString *RFOperationName(NSURLRequest *request);

// Filters a GraphQL response. Returns the new response bytes, or nil when the
// response was left untouched (not JSON, ignored operation, nothing to change),
// in which case the caller should pass the original data through.
NSData *RFFilteredResponseData(NSData *data, NSString *operationName, RFPrefs prefs);

// Feed cards only carry the first 300 characters of a post's text. Returns a request for the full
// posts on a feed page (the one the app itself makes after showing the page), or nil when there are
// no keywords or no posts to check.
NSURLRequest *RFPostDetailsRequest(NSURLRequest *feedRequest, NSData *feedData, RFPrefs prefs);

// Hides the cards on a feed page whose full post text mentions a keyword. Returns nil if nothing
// changed.
NSData *RFFeedHidingFullTextMatches(NSData *feedData, NSData *detailsData, RFPrefs prefs);

// Keeps the app's own request for full posts as the model for RFPostDetailsRequest, so it stays
// right when Reddit changes it.
void RFRememberPostDetailsRequest(NSURLRequest *request);

// Reddit plays RedGIFs posts from its own copy of the video, which has no sound. Returns the
// RedGIFs IDs of those videos in a response (lowercase, no duplicates), or nil if there are none.
NSArray<NSString *> *RFRedgifsIds(NSData *data);

// Points those videos at RedGIFs' own files instead ({RedGIFs ID: video URL}). Returns nil if
// nothing changed.
NSData *RFRedgifsResponse(NSData *data, NSDictionary<NSString *, NSString *> *videoURLs);

// Hidden posts take no space, so a first Home page that's mostly hidden can be too short to scroll,
// and the app only loads more when you scroll. Returns the request for the next page when the
// (already filtered) first page has fewer than a screenful of visible posts, else nil.
NSURLRequest *RFFeedTopUpRequest(NSURLRequest *request, NSData *filteredData);

// Appends the next page's posts to the first page and takes its pagination info.
// Returns nil if either page can't be read.
NSData *RFMergedFeedPages(NSData *firstPage, NSData *nextPage);

#ifdef __cplusplus
}
#endif
