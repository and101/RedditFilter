#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif
// The RedditFilter version in a release tag like "v2026.43.0-1.3.1" (Reddit version, then
// RedditFilter's), or nil for tags without one.
NSString *RFTweakVersionFromTag(NSString *tag);
// The Reddit version in such a tag ("2026.43.0"), or nil.
NSString *RFRedditVersionFromTag(NSString *tag);

// YES if `candidate` is a later version than `current`. "1.3.2-beta2" is later than "1.3.1" but
// earlier than "1.3.2". NO if either isn't a version.
BOOL RFVersionIsNewer(NSString *candidate, NSString *current);

// YES if the release tagged `tag` is an update for RedditFilter `tweak` installed in Reddit `reddit`:
// a later RedditFilter, or the same RedditFilter built for a later Reddit. NO for development builds.
BOOL RFReleaseIsNewer(NSString *tag, NSString *tweak, NSString *reddit);
#ifdef __cplusplus
}
#endif
