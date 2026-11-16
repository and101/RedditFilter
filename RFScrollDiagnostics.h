// RFScrollDiagnostics.h
//
// Records why a RedditFilter settings page might not scroll, for the Diagnostics report. Only while
// Diagnostics is on. It keeps sizes, positions, page titles and gesture class names, nothing else.

#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif
// Called when a settings page appears: starts watching touches on its sheet.
void RFScrollDiagnosticsAttach(UIViewController *controller);
// Called when the settings page changes its table's top inset to line up with the bar.
void RFScrollDiagnosticsInsetChanged(UIViewController *controller, CGFloat from, CGFloat to, BOOL resetOffset);
// A one-line event, such as the window changing size.
void RFScrollDiagnosticsNote(UIViewController *controller, NSString *event);
#ifdef __cplusplus
}
#endif
