// DebugMenu.h
//
// Lightweight, self-contained instrumentation for the GraphQL "schema paths"
// used by RedditFilter's NSURLSession hook.
//
// Reddit periodically renames pieces of its GraphQL schema (e.g. `homeV3` ->
// `homeV4`). When that happens the hardcoded key paths in Tweak.xm silently
// stop resolving and filtering breaks with no visible signal. This tracker:
//
//   * records, per operation, whether the hardcoded fast-path resolved (hit)
//     or returned nil (miss),
//   * on the first miss, walks the live response to auto-discover where the
//     data moved to, and
//   * surfaces all of that in a debug section of the RedditFilter menu so the
//     corrected path can be copied straight out of the app.
//
// It's in every build but only records while the Diagnostics switch at the end
// of the settings screen is on. Off, each request costs one flag check.
// What it records stays in memory: it's cleared when Reddit closes or the switch
// is turned off.

#import <Foundation/Foundation.h>

// Only the login notes in Tweak.xm still need a build with DEBUG_MENU=1.
#ifndef REDDITFILTER_DEBUG
#define REDDITFILTER_DEBUG 0
#endif

// Identifies the *shape* of the data that is expected at a given schema path so
// that, on a miss, discovery knows what it is looking for. These constants are
// always defined (they are cheap and only ever appear as dropped macro
// arguments in a release build), which keeps the call sites in Tweak.xm
// identical regardless of the flag.
typedef NS_ENUM(NSInteger, RFSchemaSig) {
  RFSchemaSigEdges = 0,   // an array of `{ node: {...} }` (home / popular feeds)
  RFSchemaSigTrees,       // an array of comment-forest trees: `{ node: {...} }`
  RFSchemaSigNodeArray,   // an array of post nodes, each with a `__typename`
  RFSchemaSigCommentsAds, // an ad array or a PdpAds object containing adPosts
};

#ifdef __cplusplus
extern "C" {
#endif
// Whether the Diagnostics switch is on. Thread-safe.
BOOL RFDiagnosticsEnabled(void);
// Called when the settings are read. Turning it off clears what was recorded.
void RFSetDiagnosticsEnabled(BOOL enabled);
#ifdef __cplusplus
}
#endif

// Keys used in the dictionaries returned by -snapshot.
extern NSString *const kRFDebugOp;            // NSString  operation name
extern NSString *const kRFDebugExpected;      // NSString  hardcoded schema path
extern NSString *const kRFDebugHits;          // NSNumber  times the path resolved
extern NSString *const kRFDebugMisses;        // NSNumber  times the path was nil
extern NSString *const kRFDebugErrors;        // NSNumber  times Reddit answered with an error instead
extern NSString *const kRFDebugDiscovered;    // NSString  auto-found path (or absent)
extern NSString *const kRFDebugLastResolved;  // NSNumber  BOOL, last probe outcome
extern NSString *const kRFDebugSeen;          // NSNumber  BOOL, any traffic observed
extern NSString *const kRFDebugFailedJSON;    // NSString  captured JSON on failure
extern NSString *const kRFDebugUnfiltered;    // NSArray   on the unfiltered-requests row only:
                                              //           one line per address, most requests first
extern NSString *const kRFDebugFeedCards;     // NSArray   on the feed cards row only: one line per card type,
                                              //           starting "? " if Extra cards can't hide it, else "\u2713 "
extern NSString *const kRFDebugSummary;       // NSString  compatibility summary, never response or browsing data

typedef NS_OPTIONS(NSUInteger, RFArticleSafariHooks) {
  RFArticleSafariHookLegacy = 1 << 0,
  RFArticleSafariHookPush = 1 << 1,
  RFArticleSafariHookStart = 1 << 2,
  RFArticleSafariHookPolicy = 1 << 3,
};
// Fixed outcomes keep URLs, page contents and account data out of the compatibility report.
typedef NS_ENUM(NSUInteger, RFArticleSafariResult) {
  RFArticleSafariNotObserved,
  RFArticleSafariLegacyPresented,
  RFArticleSafariModernPresented,
  RFArticleSafariDisabledOrCancelled,
  RFArticleSafariInvalidURL,
  RFArticleSafariMissingGetter,
  RFArticleSafariPresenterUnavailable,
  RFArticleSafariStackChanged,
  RFArticleSafariNoVisibleArticle,
  RFArticleSafariURLNotReady,
  RFArticleSafariAmbiguousArticle,
  RFArticleSafariPresentationDeclined,
  RFArticleSafariReturnedToPost,
  RFArticleSafariReturnSkipped,
};

@interface RFSchemaDebug : NSObject

+ (instancetype)shared;

// Called from the network hook for every probed operation. Thread-safe.
// `resolved` is the result of testing the hardcoded path against `json`.
// On the first miss for an operation, `json` and `signature` are used to try
// to locate where the data moved to.
- (void)recordOperation:(NSString *)operation
           expectedPath:(NSString *)expectedPath
               resolved:(BOOL)resolved
                   json:(id)json
              signature:(RFSchemaSig)signature;

// Ordered, immutable view of the current stats for the menu (seed order first,
// then any operations discovered at runtime). Thread-safe.
- (NSArray<NSDictionary *> *)snapshot;

// Called from the network hook for requests it passes through unfiltered. Records GraphQL
// requests (they carry Apollo's operation header) to a Reddit address: either one RFIsAPIHost in
// Tweak.xm doesn't accept, like cf.gql-fed.reddit.com before 1.3.1, or one with no completion
// handler. Thread-safe.
- (void)recordUnfilteredRequest:(NSURLRequest *)request hasHandler:(BOOL)hasHandler;

// Called for each feed card that isn't a post or an ad. `known` means Extra cards can hide it.
// Keeps a short list of types, so nothing in the card itself is stored. Thread-safe.
- (void)recordFeedCardType:(NSString *)type known:(BOOL)known operation:(NSString *)operation;

// Hook availability is static compatibility information. Only the latest outcome is recorded,
// while Diagnostics is on; reset/off clears that outcome. No URL or arbitrary text is accepted.
- (void)setArticleSafariHooks:(RFArticleSafariHooks)hooks;
- (void)recordArticleSafariResult:(RFArticleSafariResult)result;

// What -snapshot shows, as plain text for a bug report. It holds operation names, schema paths,
// Reddit API addresses, card types and article compatibility only: captured JSON is never included.
// The settings share sheet adds the RedditFilter, Reddit and iOS versions. Thread-safe.
- (NSString *)reportText;

// Zero all counters and clear discovered paths (re-arm the probes).
- (void)reset;

@end

// Recording macros used at the call sites. They do nothing unless Diagnostics is on.
// (Parameter names start with an underscore so they can't collide with the
// selector keywords below, e.g. `resolved:` and `json:`.)
#define RF_RECORD_SCHEMA(_op, _expected, _resolved, _json, _sig)               \
  do {                                                                         \
    if (RFDiagnosticsEnabled())                                                \
      [[RFSchemaDebug shared] recordOperation:(_op)                            \
                                 expectedPath:(_expected)                      \
                                     resolved:(_resolved)                      \
                                         json:(_json)                          \
                                    signature:(_sig)];                         \
  } while (0)

#define RF_RECORD_UNFILTERED(_request, _hasHandler)                           \
  do {                                                                         \
    if (RFDiagnosticsEnabled())                                                \
      [[RFSchemaDebug shared] recordUnfilteredRequest:(_request) hasHandler:(_hasHandler)]; \
  } while (0)
