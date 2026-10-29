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
} RFPrefs;

#ifdef __cplusplus
extern "C" {
#endif

// YES if at least one filter is switched on.
BOOL RFPrefsAnyEnabled(RFPrefs prefs);

// Posts whose title or preview text contains one of these words or phrases are
// hidden. Matching is whole-word and ignores case and accents. Thread-safe.
void RFSetFilterKeywords(NSArray<NSString *> *keywords);

// Best-effort GraphQL operation name for a request: the Apollo
// X-APOLLO-OPERATION-NAME header, then "operationName" in the JSON body, then
// the ?operationName= query item. Returns @"Unknown" when none is found.
NSString *RFOperationName(NSURLRequest *request);

// Filters a GraphQL response. Returns the new response bytes, or nil when the
// response was left untouched (not JSON, ignored operation, nothing to change),
// in which case the caller should pass the original data through.
NSData *RFFilteredResponseData(NSData *data, NSString *operationName, RFPrefs prefs);

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
