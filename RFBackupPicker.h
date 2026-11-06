// RFBackupPicker.h
//
// A plain document-picker delegate, so the settings screen's Logos subclass doesn't have to
// conform to UIKit protocols. Keep it alive for as long as its picker is on screen.

#import <UIKit/UIKit.h>

@interface RFBackupPicker : NSObject <UIDocumentPickerDelegate>
- (instancetype)initWithCompletion:(void (^)(NSURL *url))completion;
@end
