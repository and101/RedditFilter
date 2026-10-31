#import <Foundation/Foundation.h>

// Safari needs a native handler for every web extension. This one has nothing to do: all the work
// happens in the extension's JavaScript.
@interface SafariWebExtensionHandler : NSObject <NSExtensionRequestHandling>
@end

@implementation SafariWebExtensionHandler
- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
  [context completeRequestReturningItems:@[] completionHandler:nil];
}
@end
