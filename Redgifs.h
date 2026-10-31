// Redgifs.h
//
// Looks up RedGIFs' own video files, which keep the sound that Reddit's copies drop.

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Calls completion with {RedGIFs ID: video URL} for the IDs that have sound. With hd, uses each
// video's HD file when there is one, then SD. Otherwise prefers SD, then HD. Videos that couldn't be
// looked up are left out, so the caller keeps Reddit's version for them. Never fails, and gives up
// after a few seconds.
void RFFetchRedgifsVideos(NSArray<NSString *> *ids, BOOL hd,
                          void (^completion)(NSDictionary<NSString *, NSString *> *videoURLs));

// YES on Wi-Fi, without Low Data Mode. Starts a network monitor on first use, and is NO until it has
// heard from the network, so a caller preferring HD falls back to SD rather than using extra data.
BOOL RFRedgifsOnWiFi(void);

#ifdef __cplusplus
}
#endif
