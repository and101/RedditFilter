// RFScrollDiagnostics.m
//
// A gesture recognizer that never recognizes: it watches each touch on the settings sheet, notes which
// of the app's gestures took it and whether the list moved, then hands that to the Diagnostics report.

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <objc/runtime.h>
#import "DebugMenu.h"
#import "RFScrollDiagnostics.h"

static double RFElapsed(void) {
  static double start;
  if (!start) start = CACurrentMediaTime();
  return CACurrentMediaTime() - start;
}

static NSString *RFSizeText(CGSize size) { return [NSString stringWithFormat:@"%.0fx%.0f", size.width, size.height]; }

static NSString *RFRectText(CGRect rect) {
  return [NSString stringWithFormat:@"%.0f,%.0f %.0fx%.0f", rect.origin.x, rect.origin.y, rect.size.width,
                                    rect.size.height];
}

static NSString *RFGestureStateText(UIGestureRecognizerState state) {
  switch (state) {
    case UIGestureRecognizerStatePossible: return @"possible";
    case UIGestureRecognizerStateBegan: return @"began";
    case UIGestureRecognizerStateChanged: return @"changed";
    case UIGestureRecognizerStateEnded: return @"ended";
    case UIGestureRecognizerStateCancelled: return @"cancelled";
    case UIGestureRecognizerStateFailed: return @"failed";
  }
  return @"?";
}

static NSString *RFGestureText(UIGestureRecognizer *gesture) {
  return [NSString stringWithFormat:@"%@ on %@%@", NSStringFromClass(gesture.class),
                                    gesture.view ? NSStringFromClass(gesture.view.class) : @"nothing",
                                    gesture.enabled ? @"" : @" (off)"];
}

// The page's list: its table, or else the first scroll view in it.
static UIScrollView *RFPageScrollView(UIViewController *controller) {
  if ([controller respondsToSelector:@selector(tableView)]) {
    id table = [(id)controller tableView];
    if ([table isKindOfClass:UIScrollView.class]) return table;
  }
  if (!controller.isViewLoaded) return nil;
  NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:controller.view];
  while (queue.count) {
    UIView *view = queue.firstObject;
    [queue removeObjectAtIndex:0];
    if ([view isKindOfClass:UIScrollView.class]) return (UIScrollView *)view;
    [queue addObjectsFromArray:view.subviews];
  }
  return nil;
}

static NSString *RFPageState(UIViewController *controller) {
  UIScrollView *list = RFPageScrollView(controller);
  UIWindow *window = controller.viewIfLoaded.window;
  UIScreen *screen = window.windowScene.screen;
  UIViewController *container = controller.navigationController ?: controller;
  NSMutableArray<NSString *> *lines = [NSMutableArray array];

  [lines addObject:[NSString stringWithFormat:@"page %@ · screen %@ @%.0fx · window %@ · %lu scene%@ · size classes w%ld h%ld",
                                              controller.title ?: NSStringFromClass(controller.class),
                                              RFSizeText(screen.bounds.size), screen.scale,
                                              RFSizeText(window.bounds.size),
                                              (unsigned long)UIApplication.sharedApplication.connectedScenes.count,
                                              UIApplication.sharedApplication.connectedScenes.count == 1 ? @"" : @"s",
                                              (long)controller.traitCollection.horizontalSizeClass,
                                              (long)controller.traitCollection.verticalSizeClass]];
  // Only ask a presented controller for its presentation, as asking can create one.
  if (container.presentingViewController) {
    NSString *sheetText = @"";
    UISheetPresentationController *sheet = container.sheetPresentationController;
    if (sheet)
      sheetText = [NSString stringWithFormat:@" · detent %@ of %lu · edge expands %d · grabber %d",
                                             sheet.selectedDetentIdentifier ?: @"default",
                                             (unsigned long)sheet.detents.count,
                                             sheet.prefersScrollingExpandsWhenScrolledToEdge, sheet.prefersGrabberVisible];
    [lines addObject:[NSString stringWithFormat:@"presented style %ld · %@%@ · sheet %@",
                                                (long)container.modalPresentationStyle,
                                                NSStringFromClass(container.presentationController.class), sheetText,
                                                window ? RFRectText([container.view convertRect:container.view.bounds
                                                                                         toView:nil])
                                                       : @"?"]];
  } else {
    [lines addObject:@"not presented"];
  }
  if (!list) {
    [lines addObject:@"no list found"];
    return [lines componentsJoinedByString:@"\n"];
  }
  UIEdgeInsets inset = list.contentInset, adjusted = list.adjustedContentInset, safe = list.safeAreaInsets;
  [lines addObject:[NSString stringWithFormat:@"list %@ in %@ · frame %@ · content %@ · offset %.0f",
                                              NSStringFromClass(list.class),
                                              list.superview ? NSStringFromClass(list.superview.class) : @"nothing",
                                              window ? RFRectText([list.superview convertRect:list.frame toView:nil]) : @"?",
                                              RFSizeText(list.contentSize), list.contentOffset.y]];
  CGFloat range = list.contentSize.height + adjusted.top + adjusted.bottom - list.bounds.size.height;
  [lines addObject:[NSString stringWithFormat:@"inset t%.0f b%.0f · adjusted t%.0f b%.0f · safe t%.0f b%.0f · "
                                              @"adjusts %ld · scroll range %.0f",
                                              inset.top, inset.bottom, adjusted.top, adjusted.bottom, safe.top,
                                              safe.bottom, (long)list.contentInsetAdjustmentBehavior, MAX(range, 0)]];
  [lines addObject:[NSString stringWithFormat:@"scroll %d · touches %d · pan %d %@ · bounces %d/%d · list is page view %d · "
                                              @"hidden %d alpha %.2f",
                                              list.scrollEnabled, list.userInteractionEnabled,
                                              list.panGestureRecognizer.enabled,
                                              RFGestureStateText(list.panGestureRecognizer.state), list.bounces,
                                              list.alwaysBounceVertical, list == controller.viewIfLoaded,
                                              list.hidden, list.alpha]];
  return [lines componentsJoinedByString:@"\n"];
}

static void RFAddEvent(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void RFAddEvent(NSString *format, ...) {
  va_list args;
  va_start(args, format);
  NSString *text = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  [[RFSchemaDebug shared] addSettingsScrollEvent:[NSString stringWithFormat:@"%.1fs %@", RFElapsed(), text]];
}

@interface RFScrollTouchObserver : UIGestureRecognizer <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UINavigationController *navigation;
@property(nonatomic, weak) UIViewController *page; // when there's no navigation controller
@end

@implementation RFScrollTouchObserver {
  BOOL _tracking;
  CGPoint _start;
  CGFloat _startOffset, _top, _bottom; // where the list was, and can go
  BOOL _severalFingers;
  __weak UIScrollView *_list;
  NSArray<UIGestureRecognizer *> *_others;
  NSMutableOrderedSet<NSString *> *_active;
  NSString *_touchedView;
}

- (instancetype)init {
  self = [super initWithTarget:nil action:nil];
  if (!self) return nil;
  self.cancelsTouchesInView = NO;
  self.delaysTouchesBegan = NO;
  self.delaysTouchesEnded = NO;
  self.delegate = self;
  return self;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
  return YES;
}
- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)other { return NO; }
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)other { return NO; }

- (UIViewController *)currentPage {
  return self.navigation ? self.navigation.topViewController : self.page;
}

- (void)noteActive {
  for (UIGestureRecognizer *gesture in _others)
    if (gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged)
      [_active addObject:RFGestureText(gesture)];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  if (_tracking) _severalFingers = YES; // the first finger is enough
  if (_tracking || !RFDiagnosticsEnabled()) return;
  _severalFingers = event.allTouches.count > 1;
  UITouch *touch = touches.anyObject;
  _tracking = YES;
  _start = [touch locationInView:nil];
  _list = RFPageScrollView(self.currentPage);
  _startOffset = _list.contentOffset.y;
  UIEdgeInsets inset = _list.adjustedContentInset;
  _top = -inset.top;
  _bottom = MAX(_top, _list.contentSize.height + inset.bottom - _list.bounds.size.height);
  NSMutableArray *others = [NSMutableArray array];
  for (UIGestureRecognizer *gesture in touch.gestureRecognizers)
    if (gesture != self) [others addObject:gesture];
  _others = others;
  _active = [NSMutableOrderedSet orderedSet];
  NSMutableArray<NSString *> *chain = [NSMutableArray array];
  for (UIView *view = touch.view; view && chain.count < 4; view = view.superview)
    [chain addObject:NSStringFromClass(view.class)];
  _touchedView = [chain componentsJoinedByString:@" < "];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  if (_tracking) [self noteActive];
}

- (void)finish:(NSSet<UITouch *> *)touches cancelled:(BOOL)cancelled {
  if (!_tracking) return;
  [self noteActive];
  UIViewController *page = self.currentPage;
  CGPoint end = [touches.anyObject locationInView:nil];
  CGFloat dy = end.y - _start.y, dx = end.x - _start.x;
  CGFloat scrolled = _list ? _list.contentOffset.y - _startOffset : 0;
  BOOL drag = fabs(dy) > 40 && fabs(dy) > fabs(dx);
  // Pulling down at the top drags the sheet, and a second finger can stop the first one's drag.
  BOOL counts = drag && !cancelled && !_severalFingers && RFDragHasRoom(dy, _startOffset, _top, _bottom);
  NSMutableArray<NSString *> *receivers = [NSMutableArray array];
  for (UIGestureRecognizer *gesture in _others)
    [receivers addObject:[NSString stringWithFormat:@"%@ %@", NSStringFromClass(gesture.class),
                                                    RFGestureStateText(gesture.state)]];
  NSString *title = page.title ?: @"?", *view = _touchedView, *state = RFPageState(page);
  NSString *took = _active.count ? [_active.array componentsJoinedByString:@", "] : @"nothing";
  NSString *got = [receivers componentsJoinedByString:@", "];
  if (!drag && !cancelled) {
    RFAddEvent(@"%@ tap on %@", title, view);
    [[RFSchemaDebug shared] setSettingsScrollState:state drag:NO stuck:NO];
  } else {
    // A flick can start moving the list just after the finger lifts.
    __weak UIScrollView *weakList = _list;
    CGFloat startOffset = _startOffset, top = _top, bottom = _bottom;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      UIScrollView *list = weakList;
      CGFloat later = list ? list.contentOffset.y - startOffset : scrolled;
      CGFloat moved = dy > 0 ? MIN(scrolled, later) : MAX(scrolled, later); // the furthest it got, the right way
      BOOL stuck = counts && !RFDragScrolled(dy, startOffset, top, bottom, moved);
      RFAddEvent(@"%@ %@%@ dy %.0f · list moved %.0f%@ · on %@\n  took it: %@\n  got the touch: %@", title,
                 cancelled ? @"cancelled " : @"", stuck ? @"DRAG DIDN'T SCROLL" : @"drag", dy, moved,
                 counts ? @"" : @" · not counted", view, took, got);
      [[RFSchemaDebug shared] setSettingsScrollState:state drag:counts stuck:stuck];
    });
  }
  self.state = UIGestureRecognizerStateFailed;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  [self finish:touches cancelled:NO];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  [self finish:touches cancelled:YES];
}

- (void)reset {
  [super reset];
  _tracking = NO;
  _others = nil;
  _active = nil;
}

@end

static const void *kRFInsetChangesKey = &kRFInsetChangesKey;

void RFScrollDiagnosticsAttach(UIViewController *controller) {
  if (!RFDiagnosticsEnabled() || !controller.isViewLoaded) return;
  objc_setAssociatedObject(controller, kRFInsetChangesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  // The whole sheet, so touches that never reach the list are seen too.
  UINavigationController *navigation = controller.navigationController;
  UIView *host = navigation ? navigation.view : controller.view;
  BOOL attached = NO;
  for (UIGestureRecognizer *gesture in host.gestureRecognizers)
    if ([gesture isKindOfClass:RFScrollTouchObserver.class]) attached = YES;
  if (!attached) {
    RFScrollTouchObserver *observer = [RFScrollTouchObserver new];
    observer.navigation = navigation;
    observer.page = navigation ? nil : controller;
    [host addGestureRecognizer:observer];
  }
  RFAddEvent(@"%@ appeared", controller.title ?: @"?");
  [[RFSchemaDebug shared] setSettingsScrollState:RFPageState(controller) drag:NO stuck:NO];
}

void RFScrollDiagnosticsInsetChanged(UIViewController *controller, CGFloat from, CGFloat to, BOOL resetOffset) {
  if (!RFDiagnosticsEnabled()) return;
  NSInteger count = [objc_getAssociatedObject(controller, kRFInsetChangesKey) integerValue] + 1;
  objc_setAssociatedObject(controller, kRFInsetChangesKey, @(count), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  // A few are normal while the page lays out; many more means it keeps fighting the scroll.
  if (count <= 3 || count == 10 || count == 100 || count == 1000)
    RFAddEvent(@"%@ top inset %.0f -> %.0f%@ (change %ld since it appeared)", controller.title ?: @"?", from, to,
               resetOffset ? @", back to top" : @"", (long)count);
}

void RFScrollDiagnosticsNote(UIViewController *controller, NSString *event) {
  if (!RFDiagnosticsEnabled()) return;
  RFAddEvent(@"%@ %@", controller.title ?: @"?", event);
}
