#import "Preferences.h"
#import <BaseTableViewController.h>

@interface UIView ()
- (void)associatePropertySetter:(SEL)propertySetter
        withThemePropertyGetter:(SEL)themePropertyGetter;
@end

@interface FeedFilterSettingsViewController : BaseTableViewController
@end