#import <UIKit/UIKit.h>
#import "PreferenceKeys.h"

#define kToggleCellID @"kToggleCellID"

// Defined in Tweak.xm, used by the settings screen.
#ifdef __cplusplus
extern "C" {
#endif
void RFReloadPreferences(void); // call after changing a setting
BOOL RFCleanCachedExperiments(void); // YES if it removed experiments the running app may still use
UIImage *iconWithName(NSString *iconName);
void RFWarmIcons(void);
Class CoreClass(NSString *name);
// Defined in FeedFilterSettingsViewController.x, so every settings screen matches.
void RFApplySettingsTheme(UIView *view, SEL setter, SEL themeGetter);
void RFApplySettingsCardTheme(UIView *view);
#ifdef __cplusplus
}
#endif
