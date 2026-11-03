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
extern NSString *const kRFDebugDiscovered;    // NSString  auto-found path (or absent)
extern NSString *const kRFDebugLastResolved;  // NSNumber  BOOL, last probe outcome
extern NSString *const kRFDebugSeen;          // NSNumber  BOOL, any traffic observed
extern NSString *const kRFDebugFailedJSON;    // NSString  captured JSON on failure
extern NSString *const kRFDebugUnfiltered;    // NSArray   on the unfiltered-requests row only:
                                              //           one line per address, most requests first

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
