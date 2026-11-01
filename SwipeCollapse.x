#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Preferences.h"
#import "SwipeCollapse.h"

@interface RFFlexStackView : UIView
- (void)didSingleTap;
@end

static BOOL gSwipeCollapseEnabled;
static NSHashTable<UIView *> *gSwipeCollapseHeaders;
static const void *kRFSwipeCollapseRecognizerKey = &kRFSwipeCollapseRecognizerKey;
static const void *kRFSwipeCollapseSuppressedPagersKey = &kRFSwipeCollapseSuppressedPagersKey;
static const void *kRFSwipeCollapseOriginalTransformKey = &kRFSwipeCollapseOriginalTransformKey;
static const void *kRFSwipeCollapseHandledKey = &kRFSwipeCollapseHandledKey;

static BOOL RFClassNameContains(UIView *view, NSString *needle) {
  return [NSStringFromClass(view.class) containsString:needle];
}

// Both current comment lists and the newer comment-tree presentation put each
// header under one of these containers. This structural gate keeps unrelated
// FlexStackViews out of the gesture path.
static BOOL RFIsInsideCommentView(UIView *view) {
  for (UIView *candidate = view; candidate; candidate = candidate.superview) {
    if (RFClassNameContains(candidate, @"PDP_CommentSheet_Impl.CommentSliceView") ||
        RFClassNameContains(candidate, @"CommentTreeItemPresentation_Internal.CommentTreeItemSliceView"))
      return YES;
  }
  return NO;
}

static UIView *RFCommentContainer(UIView *header) {
  for (UIView *candidate = header.superview; candidate; candidate = candidate.superview) {
    if (RFClassNameContains(candidate, @"PDP_CommentSheet_Impl.CommentSliceView") ||
        RFClassNameContains(candidate, @"CommentTreeItemPresentation_Internal.CommentTreeItemSliceView"))
      return candidate;
  }
  return nil;
}

// Reddit's own comment header has both of these recognizers and the collapse
// target action. Checking for that group is locale-independent and identifies
// the header before any accessibility text is needed.
static BOOL RFHasNativeCommentHeaderRecognizers(UIView *view) {
  if (![view respondsToSelector:@selector(didSingleTap)]) return NO;
  BOOL tap = NO, longPress = NO;
  for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
    if ([recognizer isKindOfClass:UITapGestureRecognizer.class]) tap = YES;
    if ([recognizer isKindOfClass:UILongPressGestureRecognizer.class]) longPress = YES;
  }
  return tap && longPress;
}

static BOOL RFIsExpandedCommentHeader(UIView *header) {
  if (!RFIsInsideCommentView(header) || !RFHasNativeCommentHeaderRecognizers(header)) return NO;
  if (RFIsExpandedCommentHeaderLabel(header.accessibilityLabel)) return YES;

  // Accessibility wording is localized. An expanded row has its body and
  // action bar below the 48pt header (188pt in total for a one-line comment),
  // while a collapsed row's CommentSliceView is exactly the header's height.
  UIView *container = RFCommentContainer(header);
  if (!container) return NO;
  CGRect headerBounds = [header convertRect:header.bounds toView:container];
  return CGRectGetHeight(container.bounds) > CGRectGetHeight(headerBounds) + 16.0;
}

static BOOL RFIsInteractiveCommentHeaderSubview(UIView *view, UIView *header) {
  for (UIView *candidate = view; candidate && candidate != header; candidate = candidate.superview) {
    if ([candidate isKindOfClass:UIControl.class] || [candidate isKindOfClass:UITextView.class] ||
        [candidate isKindOfClass:UITextField.class] || [candidate isKindOfClass:UIScrollView.class] ||
        RFClassNameContains(candidate, @"WebView"))
      return YES;
  }
  return NO;
}

static BOOL RFIsPagerPan(UIGestureRecognizer *recognizer) {
  NSString *name = NSStringFromClass(recognizer.class);
  return [name containsString:@"UIScrollViewPanGestureRecognizer"] ||
         [name containsString:@"UIScrollViewPagingSwipeGestureRecognizer"];
}

// Wait until the first small movement proves this is a left swipe before
// temporarily disabling scrolling and post paging. This leaves rightward and
// vertical gestures entirely to Reddit's existing recognizers.
static void RFSuppressPagerRecognizersForSwipe(UIView *header, UIPanGestureRecognizer *swipe) {
  NSHashTable<UIGestureRecognizer *> *suppressed =
      objc_getAssociatedObject(swipe, kRFSwipeCollapseSuppressedPagersKey);
  if (suppressed) return;
  suppressed = [NSHashTable weakObjectsHashTable];
  objc_setAssociatedObject(swipe, kRFSwipeCollapseSuppressedPagersKey, suppressed,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  for (UIView *ancestor = header.superview; ancestor; ancestor = ancestor.superview) {
    if (![ancestor isKindOfClass:UIScrollView.class]) continue;
    for (UIGestureRecognizer *recognizer in ancestor.gestureRecognizers) {
      if (recognizer == swipe || !RFIsPagerPan(recognizer) || !recognizer.enabled) continue;
      recognizer.enabled = NO;
      [suppressed addObject:recognizer];
    }
  }
}

static void RFRestorePagerRecognizersForSwipe(UIPanGestureRecognizer *swipe) {
  NSHashTable<UIGestureRecognizer *> *suppressed =
      objc_getAssociatedObject(swipe, kRFSwipeCollapseSuppressedPagersKey);
  for (UIGestureRecognizer *recognizer in suppressed.allObjects) recognizer.enabled = YES;
  objc_setAssociatedObject(swipe, kRFSwipeCollapseSuppressedPagersKey, nil,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// handleSwipe: turns the recognizers back on when the swipe ends or is
// cancelled. If UIKit fails the swipe straight after gestureRecognizerShouldBegin:
// (another recognizer won), no action is sent, so this check makes sure
// scrolling and post paging never stay off.
static void RFRestorePagersIfSwipeNeverBegan(UIPanGestureRecognizer *swipe, NSInteger checksLeft) {
  __weak UIPanGestureRecognizer *weakSwipe = swipe;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    UIPanGestureRecognizer *swipe = weakSwipe;
    if (!swipe || !objc_getAssociatedObject(swipe, kRFSwipeCollapseSuppressedPagersKey)) return;
    UIGestureRecognizerState state = swipe.state;
    if (state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged) return;
    if (state == UIGestureRecognizerStatePossible && checksLeft > 0) {
      RFRestorePagersIfSwipeNeverBegan(swipe, checksLeft - 1);
      return;
    }
    RFRestorePagerRecognizersForSwipe(swipe);
  });
}

static void RFRemoveSwipeCollapse(UIView *header) {
  UIPanGestureRecognizer *swipe =
      objc_getAssociatedObject(header, kRFSwipeCollapseRecognizerKey);
  if (!swipe) return;
  // Removing a recognizer mid-swipe sends no final action, so undo its effects here.
  RFRestorePagerRecognizersForSwipe(swipe);
  NSValue *original = objc_getAssociatedObject(swipe, kRFSwipeCollapseOriginalTransformKey);
  if (original) header.layer.sublayerTransform = original.CATransform3DValue;
  objc_setAssociatedObject(swipe, kRFSwipeCollapseOriginalTransformKey, nil,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [header removeGestureRecognizer:swipe];
  objc_setAssociatedObject(header, kRFSwipeCollapseRecognizerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void RFCollapseHeader(UIView *header) {
  if (!header.window || ![header respondsToSelector:@selector(didSingleTap)]) return;
  [(RFFlexStackView *)header didSingleTap];
}

static UIView *RFCommentHeaderInView(UIView *root) {
  if (RFIsExpandedCommentHeader(root)) return root;
  for (UIView *child in root.subviews) {
    UIView *header = RFCommentHeaderInView(child);
    if (header) return header;
  }
  return nil;
}

static UICollectionViewCell *RFCommentCellForHeader(UIView *header) {
  for (UIView *view = header; view; view = view.superview)
    if ([view isKindOfClass:UICollectionViewCell.class]) return (UICollectionViewCell *)view;
  return nil;
}

static UICollectionView *RFCommentCollectionForCell(UICollectionViewCell *cell) {
  for (UIView *view = cell.superview; view; view = view.superview)
    if ([view isKindOfClass:UICollectionView.class]) return (UICollectionView *)view;
  return nil;
}

static NSArray<UICollectionViewCell *> *RFSortedCommentCells(UICollectionView *collection) {
  return [collection.visibleCells sortedArrayUsingComparator:^NSComparisonResult(
      UICollectionViewCell *a, UICollectionViewCell *b) {
    if (a.frame.origin.y < b.frame.origin.y) return NSOrderedAscending;
    if (a.frame.origin.y > b.frame.origin.y) return NSOrderedDescending;
    return NSOrderedSame;
  }];
}

// If the section/item list changes shape, the nearest preceding Level 1
// header is still a safe fallback. It collapses the furthest ancestor which
// can be reached without relying on an invisible cell.
static UIView *RFFurthestVisibleAncestorHeader(UIView *header, UICollectionView *collection) {
  UICollectionViewCell *currentCell = RFCommentCellForHeader(header);
  NSIndexPath *currentPath = currentCell ? [collection indexPathForCell:currentCell] : nil;
  UIView *best = nil;
  for (UICollectionViewCell *cell in RFSortedCommentCells(collection)) {
    NSIndexPath *path = [collection indexPathForCell:cell];
    if (!path || (currentPath && [path compare:currentPath] != NSOrderedAscending)) continue;
    if (currentPath && path.section != currentPath.section) continue;
    UIView *candidate = RFCommentHeaderInView(cell);
    if (!candidate) continue;
    NSInteger level = RFCommentLevelFromLabel(candidate.accessibilityLabel);
    if (level == 1 || (!best && level == 0)) best = candidate;
  }
  return best;
}

static UIView *RFRootHeaderAtPath(UICollectionView *collection, NSIndexPath *rootPath) {
  UICollectionViewCell *rootCell = [collection cellForItemAtIndexPath:rootPath];
  UIView *rootHeader = rootCell ? RFCommentHeaderInView(rootCell) : nil;
  if (!rootHeader) return nil;
  // English labels say which level this is; other languages rely on the
  // section layout (each top-level thread is a section starting at item 0).
  NSInteger level = RFCommentLevelFromLabel(rootHeader.accessibilityLabel);
  return level == 0 || level == 1 ? rootHeader : nil;
}

static void RFCollapseRootAtPath(UIView *originalHeader, UICollectionView *collection,
                                 NSIndexPath *rootPath) {
  UIView *rootHeader = RFRootHeaderAtPath(collection, rootPath);
  if (!rootHeader && rootPath.section < collection.numberOfSections &&
      rootPath.item < [collection numberOfItemsInSection:rootPath.section]) {
    // The root is off-screen: bring it into view and lay out now so its cell exists.
    [collection scrollToItemAtIndexPath:rootPath
                        atScrollPosition:UICollectionViewScrollPositionTop
                                animated:NO];
    [collection layoutIfNeeded];
    rootHeader = RFRootHeaderAtPath(collection, rootPath);
  }
  if (rootHeader) {
    RFCollapseHeader(rootHeader);
    return;
  }
  UIView *furthest = RFFurthestVisibleAncestorHeader(originalHeader, collection);
  RFCollapseHeader(furthest ?: originalHeader);
}

// The current comment sheet is a collection whose section is the root comment
// and whose item 0 is that root's header. Scrolling to item 0 materializes a
// root which started off-screen (scrolling the list up to it); if that cannot happen, collapse the furthest
// visible ancestor instead.
static void RFCollapseRootForHeader(UIView *header) {
  UICollectionViewCell *cell = RFCommentCellForHeader(header);
  UICollectionView *collection = cell ? RFCommentCollectionForCell(cell) : nil;
  NSIndexPath *currentPath = cell && collection ? [collection indexPathForCell:cell] : nil;
  if (!currentPath) {
    RFCollapseHeader(header);
    return;
  }

  NSInteger level = RFCommentLevelFromLabel(header.accessibilityLabel);
  if (level == 1 || (currentPath.item == 0 && level == 0)) {
    RFCollapseHeader(header);
    return;
  }

  if (currentPath.item > 0) {
    NSIndexPath *rootPath = [NSIndexPath indexPathForItem:0 inSection:currentPath.section];
    RFCollapseRootAtPath(header, collection, rootPath);
    return;
  }

  UIView *furthest = RFFurthestVisibleAncestorHeader(header, collection);
  RFCollapseHeader(furthest ?: header);
}

@interface RFSwipeCollapseGestureHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)handleSwipe:(UIPanGestureRecognizer *)swipe;
@end

@implementation RFSwipeCollapseGestureHandler
+ (instancetype)shared {
  static RFSwipeCollapseGestureHandler *handler;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ handler = [self new]; });
  return handler;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldReceiveTouch:(UITouch *)touch {
  if (![gestureRecognizer isKindOfClass:UIPanGestureRecognizer.class]) return NO;
  UIView *header = gestureRecognizer.view;
  return gSwipeCollapseEnabled && RFIsExpandedCommentHeader(header) &&
         !RFIsInteractiveCommentHeaderSubview(touch.view, header);
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
  if (![gestureRecognizer isKindOfClass:UIPanGestureRecognizer.class] || !gSwipeCollapseEnabled)
    return NO;
  UIPanGestureRecognizer *swipe = (UIPanGestureRecognizer *)gestureRecognizer;
  BOOL shouldBegin = RFIsExpandedCommentHeader(swipe.view) &&
                     RFHasLeftSwipeDirection([swipe translationInView:swipe.view],
                                             [swipe velocityInView:swipe.view]);
  if (shouldBegin) {
    RFSuppressPagerRecognizersForSwipe(swipe.view, swipe);
    RFRestorePagersIfSwipeNeverBegan(swipe, 10);
  }
  return shouldBegin;
}

- (void)handleSwipe:(UIPanGestureRecognizer *)swipe {
  UIView *header = swipe.view;
  UIView *coordinateView = header.superview ?: header;

  if (swipe.state == UIGestureRecognizerStateBegan) {
    objc_setAssociatedObject(swipe, kRFSwipeCollapseHandledKey, @NO,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(swipe, kRFSwipeCollapseOriginalTransformKey,
                             [NSValue valueWithCATransform3D:header.layer.sublayerTransform],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }

  if (swipe.state == UIGestureRecognizerStateChanged) {
    CGPoint translation = [swipe translationInView:coordinateView];
    CGFloat limit = RFThreadCollapseDistance(header.bounds.size.width);
    CGFloat dx = MIN(0.0, MAX(-limit, translation.x));
    // Move the header's contents, not the header: Reddit keeps setting the
    // header's frame during layout, and that doesn't mix with a view transform.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    header.layer.sublayerTransform = CATransform3DMakeTranslation(dx, 0, 0);
    [CATransaction commit];
    return;
  }

  if (swipe.state != UIGestureRecognizerStateEnded &&
      swipe.state != UIGestureRecognizerStateCancelled &&
      swipe.state != UIGestureRecognizerStateFailed)
    return;

  RFRestorePagerRecognizersForSwipe(swipe);
  NSValue *original = objc_getAssociatedObject(swipe, kRFSwipeCollapseOriginalTransformKey);
  if (original) header.layer.sublayerTransform = original.CATransform3DValue;
  objc_setAssociatedObject(swipe, kRFSwipeCollapseOriginalTransformKey, nil,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  if (swipe.state != UIGestureRecognizerStateEnded || !gSwipeCollapseEnabled ||
      !RFIsExpandedCommentHeader(header))
    return;
  if ([objc_getAssociatedObject(swipe, kRFSwipeCollapseHandledKey) boolValue]) return;
  objc_setAssociatedObject(swipe, kRFSwipeCollapseHandledKey, @YES,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  CGPoint translation = [swipe translationInView:coordinateView];
  CGPoint velocity = [swipe velocityInView:coordinateView];
  if (RFShouldCollapseThreadForSwipe(translation, header.bounds.size.width)) {
    RFCollapseRootForHeader(header);
  } else if (RFShouldCollapseForSwipe(translation, velocity)) {
    RFCollapseHeader(header);
  }
}
@end

static void RFPrepareSwipeCollapseHeader(UIView *header) {
  if (!gSwipeCollapseEnabled) return;
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{ RFPrepareSwipeCollapseHeader(header); });
    return;
  }

  UIPanGestureRecognizer *swipe =
      objc_getAssociatedObject(header, kRFSwipeCollapseRecognizerKey);
  if (swipe) {
    if (RFIsExpandedCommentHeaderLabel(header.accessibilityLabel)) return;
    if (RFIsExpandedCommentHeader(header)) return;
    RFRemoveSwipeCollapse(header);
    return;
  }

  // Most FlexStackViews fail this two-gesture check without walking ancestors.
  if (!RFHasNativeCommentHeaderRecognizers(header) || !RFIsExpandedCommentHeader(header)) return;

  swipe = [[UIPanGestureRecognizer alloc] initWithTarget:RFSwipeCollapseGestureHandler.shared
                                                 action:@selector(handleSwipe:)];
  swipe.delegate = RFSwipeCollapseGestureHandler.shared;
  swipe.minimumNumberOfTouches = 1;
  swipe.maximumNumberOfTouches = 1;
  swipe.cancelsTouchesInView = YES;
  swipe.name = @"RedditFilterSwipeToCollapse";
  [header addGestureRecognizer:swipe];
  objc_setAssociatedObject(header, kRFSwipeCollapseRecognizerKey, swipe,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  if (!gSwipeCollapseHeaders) gSwipeCollapseHeaders = [NSHashTable weakObjectsHashTable];
  [gSwipeCollapseHeaders addObject:header];
}

void RFSetSwipeCollapse(BOOL enabled) {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{ RFSetSwipeCollapse(enabled); });
    return;
  }
  if (gSwipeCollapseEnabled == enabled) return;
  gSwipeCollapseEnabled = enabled;
  NSArray<UIView *> *headers = gSwipeCollapseHeaders.allObjects;
  for (UIView *header in headers) {
    if (enabled) {
      RFPrepareSwipeCollapseHeader(header);
    } else {
      header.layer.sublayerTransform = CATransform3DIdentity;
      RFRemoveSwipeCollapse(header);
    }
  }
}

%group RFFlexStackViewHooks
%hook RFFlexStackView

- (void)didMoveToWindow {
  %orig;
  RFPrepareSwipeCollapseHeader(self);
}

- (void)layoutSubviews {
  %orig;
  RFPrepareSwipeCollapseHeader(self);
}

%end
%end

%ctor {
  Class flexStack = NSClassFromString(@"SliceKit.FlexStackView");
  if (flexStack) %init(RFFlexStackViewHooks, RFFlexStackView = flexStack);
  RFSetSwipeCollapse([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterSwipeToCollapse]);
}
