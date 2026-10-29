// Redgifs.h
//
// Looks up RedGIFs' own video files, which keep the sound that Reddit's copies drop.

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Calls completion with {RedGIFs ID: video URL} for the IDs that have sound. Videos that couldn't
// be looked up are left out, so the caller keeps Reddit's version for them. Never fails, and gives
// up after a few seconds.
void RFFetchRedgifsVideos(NSArray<NSString *> *ids, void (^completion)(NSDictionary<NSString *, NSString *> *videoURLs));

#ifdef __cplusplus
}
#endif
