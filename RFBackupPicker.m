// RFBackupPicker.m
//
// See RFBackupPicker.h.

#import "RFBackupPicker.h"

@interface RFBackupPicker ()
@property(nonatomic, copy) void (^completion)(NSURL *url);
@end

@implementation RFBackupPicker

- (instancetype)initWithCompletion:(void (^)(NSURL *url))completion {
  if ((self = [super init])) _completion = [completion copy];
  return self;
}

// Runs the completion once, whether the picker finished or was cancelled.
- (void)finishWithURL:(NSURL *)url {
  void (^completion)(NSURL *) = self.completion;
  self.completion = nil;
  if (completion) completion(url);
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  [self finishWithURL:urls.firstObject];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
  [self finishWithURL:nil];
}

@end
