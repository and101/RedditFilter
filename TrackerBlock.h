// TrackerBlock.h
//
// Block trackers: requests to analytics, ad-conversion and crash-report services (RFIsTrackerURL in
// JSONFilter.h) are answered on the device with an empty "OK", so they never leave it and the app doesn't
// keep retrying them. Reddit's own event logging is left alone: Home needs its "seen" events.

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Turns blocking on or off; called whenever the settings are reloaded. Thread-safe.
void RFSetTrackerBlocking(BOOL enabled);

#ifdef __cplusplus
}
#endif
