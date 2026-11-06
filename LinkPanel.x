// A link opened from its post page shows in Reddit's full-screen player, with a panel for votes and
// comments along the bottom that can't be dismissed. This hides the panel and lets the page use the
// space. Videos use the same player, so nothing changes unless the link view is on screen.
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import "LinkPanel.h"

@interface RFLinkView : UIView
@end
@interface RFLinkPanelView : UIView
@end

static BOOL gHidePanel;
static Class gPanelClass;
static __weak UIView *gHiddenPanel, *gPanelOwner; // main thread: the panel, and the link view that hid it

// The panel sits beside the player's list, so look through the link view's ancestors for it.
static UIView *RFPanelNear(UIView *view) {
  for (UIView *ancestor = view.superview; ancestor; ancestor = ancestor.superview)
    for (UIView *sibling in ancestor.subviews)
      if ([sibling isKindOfClass:gPanelClass]) return sibling;
  return nil;
}

static void RFShowHiddenPanel(void) {
  UIView *panel = gHiddenPanel, *owner = gPanelOwner;
  gHiddenPanel = gPanelOwner = nil;
  panel.hidden = NO;
  [owner setNeedsLayout];
}

void RFSetHideLinkPanel(BOOL hide) {
  gHidePanel = hide;
  if (!hide) dispatch_async(dispatch_get_main_queue(), ^{ RFShowHiddenPanel(); });
}

static void RFHidePanelNear(UIView *linkView) {
  UIView *panel = RFPanelNear(linkView);
  if (!panel) return;
  if (gHiddenPanel != panel) RFShowHiddenPanel(); // only one link is on show, so the last one has gone
  gHiddenPanel = panel;
  gPanelOwner = linkView;
  panel.hidden = YES;
  for (UIView *subview in linkView.subviews) {
    if (![subview isKindOfClass:WKWebView.class]) continue;
    CGRect frame = subview.frame;
    frame.size.height = CGRectGetHeight(linkView.bounds) - CGRectGetMinY(frame);
    if (!CGRectEqualToRect(frame, subview.frame)) subview.frame = frame;
  }
}

%group RFLinkViewHooks
%hook RFLinkView
- (void)layoutSubviews {
  %orig;
  UIView *view = (UIView *)self;
  if (gHidePanel && view.window) RFHidePanelNear(view);
}

- (void)didMoveToWindow {
  %orig;
  // The panel can arrive just after the link view, and is kept for whatever the player shows next.
  UIView *view = (UIView *)self;
  if (!view.window) {
    if (view == gPanelOwner) RFShowHiddenPanel();
  } else if (gHidePanel) dispatch_async(dispatch_get_main_queue(), ^{ [view setNeedsLayout]; });
}
%end

// Reddit shows the panel again once the page has loaded.
%hook RFLinkPanelView
- (void)setHidden:(BOOL)hidden {
  %orig(hidden || (gHidePanel && self == (id)gHiddenPanel));
}
%end
%end

%ctor {
  Class linkView = NSClassFromString(@"Video_FBP_Impl.FBPArticleLinkConsumptionView");
  gPanelClass = NSClassFromString(@"PDP_FBPCommentSheetAdapter_Impl.FBPCommentSheetAdapterView");
  if (linkView && gPanelClass) %init(RFLinkViewHooks, RFLinkView = linkView, RFLinkPanelView = gPanelClass);
}
