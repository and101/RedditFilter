#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif
// The RedditFilter version in a release tag like "v2026.43.0-1.3.1" (Reddit version, then
// RedditFilter's), or nil for tags without one.
NSString *RFTweakVersionFromTag(NSString *tag);

// YES if `candidate` is a later version than `current`. "1.3.2-beta2" is later than "1.3.1" but
// earlier than "1.3.2". NO if either isn't a version.
BOOL RFVersionIsNewer(NSString *candidate, NSString *current);
#ifdef __cplusplus
}
#endif
