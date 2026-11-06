#import <UIKit/UIKit.h>

// Settings screen for the keyword filter: add, remove and clear keywords.
@interface RFKeywordsViewController : UITableViewController
@end

#ifdef __cplusplus
extern "C" {
#endif
NSArray<NSString *> *RFSavedKeywords(void);
UITableViewCell *RFKeywordSettingsCell(UITableView *table, NSInteger index, id target);
void RFKeywordSettingsChanged(UISwitch *sender, UITableView *table);
#ifdef __cplusplus
}
#endif
