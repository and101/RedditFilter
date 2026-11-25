// RFDiagnosticDetail.h
//
// One Diagnostics check in full: its status and what it means, the technical details, and copying them.

#import <UIKit/UIKit.h>
#import "DebugMenu.h"

@interface RFDiagnosticDetail : UITableViewController
// For the check with this operation (see -[RFSchemaDebug snapshot]), or Last closed with nil.
- (instancetype)initWithOperation:(NSString *)operation;
@end

#ifdef __cplusplus
extern "C" {
#endif
// The colour of a check's status.
UIColor *RFDebugLevelColor(RFDebugLevel level);
// A status as VoiceOver should read it, without its tick or cross.
NSString *RFDebugSpokenStatus(NSString *status);
#ifdef __cplusplus
}
#endif
