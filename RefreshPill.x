// Reddit sometimes floats a "new posts" button at the top of Home; tapping it reloads the feed and goes
// back to the top. Its holder (Home_Impl.RefreshPillWrapperView) is always in Home's view tree, zero
// high until the button shows, so keeping that hidden hides the button and stops it being tapped.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "RefreshPill.h"

@interface RFRefreshPillHolder : UIView
@end

static BOOL gHidePill;                    // main thread
static BOOL gApplying;                    // RedditFilter itself is setting hidden; main thread
static NSHashTable<UIView *> *gHolders;   // the holders seen, weakly; main thread

// What Reddit itself last asked of each holder (hidden or not), so turning hiding off puts that back.
static const void *kRFWantsHiddenKey = &kRFWantsHiddenKey;
static BOOL RFRedditWantsHidden(UIView *holder) { return [objc_getAssociatedObject(holder, kRFWantsHiddenKey) boolValue]; }

static void RFApplyToHolders(void) {
  gApplying = YES;
  for (UIView *holder in gHolders.allObjects) holder.hidden = RFRedditWantsHidden(holder); // the hook adds gHidePill
  gApplying = NO;
}

void RFSetHideRefreshPill(BOOL hide) {
  dispatch_block_t apply = ^{
    if (gHidePill == hide) return;
    gHidePill = hide;
    RFApplyToHolders();
  };
  if (NSThread.isMainThread) apply();
  else dispatch_async(dispatch_get_main_queue(), apply);
}

%group RFRefreshPillHooks
%hook RFRefreshPillHolder
- (void)didMoveToWindow {
  %orig;
  UIView *holder = (UIView *)self;
  if (!holder.window) return;
  if (!gHolders) gHolders = [NSHashTable weakObjectsHashTable];
  [gHolders addObject:holder];
  // Not hidden by Reddit unless it said so (setHidden: notes it).
  if (!objc_getAssociatedObject(holder, kRFWantsHiddenKey))
    objc_setAssociatedObject(holder, kRFWantsHiddenKey, @(holder.hidden && !gHidePill), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if (gHidePill && !holder.hidden) {
    gApplying = YES;
    holder.hidden = YES;
    gApplying = NO;
  }
}

// Kept hidden while hiding is on, even if Reddit shows it again itself.
- (void)setHidden:(BOOL)hidden {
  UIView *holder = (UIView *)self;
  // Only Reddit's own calls are noted (RFApplyToHolders and didMoveToWindow pass what's already noted or YES).
  if (!gApplying) objc_setAssociatedObject(holder, kRFWantsHiddenKey, @(hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  %orig(hidden || gHidePill);
}
%end
%end

%ctor {
  Class holder = NSClassFromString(@"Home_Impl.RefreshPillWrapperView");
  if ([holder isSubclassOfClass:UIView.class]) %init(RFRefreshPillHooks, RFRefreshPillHolder = holder);
}
