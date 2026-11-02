#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Preferences.h"
#import "SwipeCollapse.h"

@interface RFFlexStackView : UIView
- (void)didSingleTap;
@end

static BOOL gSwipeCollapseEnabled;
static NSHashTable<UIView *> *gSwipeCollapseCards;
static const void *kRFSwipeCollapseRecognizerKey = &kRFSwipeCollapseRecognizerKey;
static const void *kRFSwipeCollapseSuppressedPagersKey = &kRFSwipeCollapseSuppressedPagersKey;
static const void *kRFSwipeCollapseRevealKey = &kRFSwipeCollapseRevealKey;
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

// The first view under a card that has Reddit's own header recognizers: the
// comment's header, whose didSingleTap collapses or expands the comment.
static UIView *RFNativeHeaderInCard(UIView *root) {
  if (RFHasNativeCommentHeaderRecognizers(root)) return root;
  for (UIView *child in root.subviews) {
    UIView *header = RFNativeHeaderInCard(child);
    if (header) return header;
  }
  return nil;
}

static UIView *RFExpandedHeaderInCard(UIView *card) {
  UIView *header = RFNativeHeaderInCard(card);
  return header && RFIsExpandedCommentHeader(header) ? header : nil;
}

// Touches that start on something with its own sideways gesture stay with it:
// a horizontally scrolling view (gallery, wide code block or table), a slider,
// a web view or a video player. Taps on links and buttons still work because
// the swipe only begins after the finger moves sideways.
static BOOL RFTouchBelongsToOwnHorizontalGesture(UIView *view, UIView *card) {
  for (UIView *candidate = view; candidate && candidate != card; candidate = candidate.superview) {
    if ([candidate isKindOfClass:UIScrollView.class]) {
      UIScrollView *scroll = (UIScrollView *)candidate;
      if (scroll.scrollEnabled && scroll.contentSize.width > CGRectGetWidth(scroll.bounds) + 1.0) return YES;
    }
    if ([candidate isKindOfClass:UISlider.class] || [candidate isKindOfClass:UISwitch.class] ||
        [candidate isKindOfClass:UITextField.class] ||
        ([candidate isKindOfClass:UITextView.class] && ((UITextView *)candidate).editable) ||
        RFClassNameContains(candidate, @"WebView") || RFClassNameContains(candidate, @"Player"))
      return YES;
  }
  return NO;
}

#pragma mark - Card movement

static UICollectionViewCell *RFCellForView(UIView *view) {
  for (UIView *candidate = view; candidate; candidate = candidate.superview)
    if ([candidate isKindOfClass:UICollectionViewCell.class]) return (UICollectionViewCell *)candidate;
  return nil;
}

// The view whose contents slide: the cell's content view, so the whole card
// (body, action bar and thread lines) moves together. Moving its sublayers
// rather than the view itself leaves Reddit's frames and layout alone.
static UIView *RFMovingViewForCard(UIView *card) {
  UICollectionViewCell *cell = RFCellForView(card);
  if (cell && [card isDescendantOfView:cell.contentView]) return cell.contentView;
  return card;
}

@interface RFSwipeCollapseReveal : UIView
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic) BOOL thread;
@end

@implementation RFSwipeCollapseReveal
- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.userInteractionEnabled = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backgroundColor = UIColor.systemBlueColor;
    _icon = [[UIImageView alloc] init];
    _icon.tintColor = UIColor.whiteColor;
    _icon.contentMode = UIViewContentModeScaleAspectFit;
    _label = [[UILabel alloc] init];
    _label.textColor = UIColor.whiteColor;
    _label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    _label.adjustsFontForContentSizeCategory = YES;
    _label.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_icon];
    [self addSubview:_label];
    self.thread = NO;
    [self applyThread];
  }
  return self;
}

- (void)applyThread {
  NSString *symbol = self.thread ? @"chevron.up.2" : @"chevron.up";
  UIImage *image = [UIImage systemImageNamed:symbol] ?: [UIImage systemImageNamed:@"chevron.up"];
  self.icon.image = [image imageWithConfiguration:
      [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold]];
  self.label.text = self.thread ? @"Collapse thread" : @"Collapse";
  self.backgroundColor = self.thread ? UIColor.systemIndigoColor : UIColor.systemBlueColor;
  [self setNeedsLayout];
}

- (void)setThread:(BOOL)thread {
  if (_thread == thread && self.label.text) return;
  _thread = thread;
  [self applyThread];
}

// Icon and label sit just inside the right edge, level with the comment's
// header, so they stay on screen for long comments.
- (void)layoutSubviews {
  [super layoutSubviews];
  CGFloat width = CGRectGetWidth(self.bounds), height = CGRectGetHeight(self.bounds);
  CGFloat centreY = MIN(height / 2.0, 40.0);
  CGSize labelSize = [self.label sizeThatFits:CGSizeMake(110, 40)];
  CGFloat columnWidth = MAX(28.0, labelSize.width);
  CGFloat centreX = width - 16.0 - columnWidth / 2.0;
  self.icon.frame = CGRectMake(centreX - 11, centreY - 18, 22, 22);
  self.label.frame = CGRectMake(centreX - columnWidth / 2.0, centreY + 6, columnWidth, labelSize.height);
}
@end

static RFSwipeCollapseReveal *RFRevealForCard(UIView *card, BOOL create) {
  UICollectionViewCell *cell = RFCellForView(card);
  if (!cell) return nil;
  RFSwipeCollapseReveal *reveal = objc_getAssociatedObject(cell, kRFSwipeCollapseRevealKey);
  if (!reveal && create) {
    reveal = [[RFSwipeCollapseReveal alloc] initWithFrame:cell.bounds];
    reveal.hidden = YES;
    objc_setAssociatedObject(cell, kRFSwipeCollapseRevealKey, reveal, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  if (reveal && reveal.superview != cell) [cell insertSubview:reveal belowSubview:cell.contentView];
  return reveal;
}

static void RFSetCardOffset(UIView *card, CGFloat dx, BOOL thread) {
  UIView *moving = RFMovingViewForCard(card);
  RFSwipeCollapseReveal *reveal = RFRevealForCard(card, YES);
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [moving.layer removeAnimationForKey:@"RFSwipeCollapseReturn"];
  moving.layer.sublayerTransform = CATransform3DMakeTranslation(dx, 0, 0);
  if (reveal) {
    reveal.frame = reveal.superview.bounds;
    reveal.hidden = dx >= 0;
    reveal.thread = thread;
    reveal.alpha = MIN(1.0, -dx / 48.0);
  }
  [CATransaction commit];
}

// Slides the card back into place. animated:NO is for clean-up (removal,
// cell reuse, setting turned off) where nothing should be left moved.
static void RFResetCard(UIView *card, BOOL animated) {
  UIView *moving = RFMovingViewForCard(card);
  RFSwipeCollapseReveal *reveal = RFRevealForCard(card, NO);
  CATransform3D current = moving.layer.presentationLayer ? moving.layer.presentationLayer.sublayerTransform
                                                         : moving.layer.sublayerTransform;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  moving.layer.sublayerTransform = CATransform3DIdentity;
  [moving.layer removeAnimationForKey:@"RFSwipeCollapseReturn"];
  if (animated && !CATransform3DIsIdentity(current)) {
    CABasicAnimation *back = [CABasicAnimation animationWithKeyPath:@"sublayerTransform"];
    back.fromValue = [NSValue valueWithCATransform3D:current];
    back.toValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
    back.duration = 0.22;
    back.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    __weak RFSwipeCollapseReveal *weakReveal = reveal;
    [CATransaction setCompletionBlock:^{
      if (CATransform3DIsIdentity(moving.layer.sublayerTransform)) weakReveal.hidden = YES;
    }];
    [moving.layer addAnimation:back forKey:@"RFSwipeCollapseReturn"];
  } else {
    reveal.hidden = YES;
  }
  [CATransaction commit];
}

#pragma mark - Pager

static BOOL RFIsPagerPan(UIGestureRecognizer *recognizer) {
  NSString *name = NSStringFromClass(recognizer.class);
  return [name containsString:@"UIScrollViewPanGestureRecognizer"] ||
         [name containsString:@"UIScrollViewPagingSwipeGestureRecognizer"];
}

// Wait until the first small movement proves this is a left swipe before
// temporarily disabling scrolling and post paging. This leaves rightward and
// vertical gestures entirely to Reddit's existing recognizers.
static void RFSuppressPagerRecognizersForSwipe(UIView *card, UIPanGestureRecognizer *swipe) {
  NSHashTable<UIGestureRecognizer *> *suppressed =
      objc_getAssociatedObject(swipe, kRFSwipeCollapseSuppressedPagersKey);
  if (suppressed) return;
  suppressed = [NSHashTable weakObjectsHashTable];
  objc_setAssociatedObject(swipe, kRFSwipeCollapseSuppressedPagersKey, suppressed,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  for (UIView *ancestor = card.superview; ancestor; ancestor = ancestor.superview) {
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

static void RFRemoveSwipeCollapse(UIView *card) {
  UIPanGestureRecognizer *swipe = objc_getAssociatedObject(card, kRFSwipeCollapseRecognizerKey);
  if (!swipe) return;
  // Removing a recognizer mid-swipe sends no final action, so undo its effects here.
  RFRestorePagerRecognizersForSwipe(swipe);
  RFResetCard(card, NO);
  [card removeGestureRecognizer:swipe];
  objc_setAssociatedObject(card, kRFSwipeCollapseRecognizerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Collapsing

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
  if (![gestureRecognizer isKindOfClass:UIPanGestureRecognizer.class] || !gSwipeCollapseEnabled) return NO;
  UIView *card = gestureRecognizer.view;
  return !RFTouchBelongsToOwnHorizontalGesture(touch.view, card) && RFExpandedHeaderInCard(card) != nil;
}

// Only leftward swipes on an expanded comment are claimed. Rightward and
// vertical ones, and every swipe on a collapsed comment (which has no
// recognizer), stay with Reddit: scrolling and moving between posts.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
  if (![gestureRecognizer isKindOfClass:UIPanGestureRecognizer.class] || !gSwipeCollapseEnabled)
    return NO;
  UIPanGestureRecognizer *swipe = (UIPanGestureRecognizer *)gestureRecognizer;
  UIView *card = swipe.view;
  BOOL shouldBegin = RFHasLeftSwipeDirection([swipe translationInView:card], [swipe velocityInView:card]) &&
                     RFExpandedHeaderInCard(card) != nil;
  if (shouldBegin) {
    RFSuppressPagerRecognizersForSwipe(card, swipe);
    RFRestorePagersIfSwipeNeverBegan(swipe, 10);
  }
  return shouldBegin;
}

- (void)handleSwipe:(UIPanGestureRecognizer *)swipe {
  UIView *card = swipe.view;
  CGFloat width = CGRectGetWidth(card.bounds);

  if (swipe.state == UIGestureRecognizerStateBegan) {
    objc_setAssociatedObject(swipe, kRFSwipeCollapseHandledKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }

  if (swipe.state == UIGestureRecognizerStateBegan || swipe.state == UIGestureRecognizerStateChanged) {
    CGPoint translation = [swipe translationInView:card];
    // The card follows the finger, with resistance past the whole-thread distance.
    CGFloat limit = RFThreadCollapseDistance(width);
    CGFloat dx = MIN(0.0, translation.x);
    if (dx < -limit) dx = -limit + (dx + limit) * 0.3;
    RFSetCardOffset(card, dx, RFShouldCollapseThreadForSwipe(translation, width));
    return;
  }

  if (swipe.state != UIGestureRecognizerStateEnded &&
      swipe.state != UIGestureRecognizerStateCancelled &&
      swipe.state != UIGestureRecognizerStateFailed)
    return;

  RFRestorePagerRecognizersForSwipe(swipe);
  RFResetCard(card, YES);

  if (swipe.state != UIGestureRecognizerStateEnded || !gSwipeCollapseEnabled) return;
  UIView *header = RFExpandedHeaderInCard(card);
  if (!header) return;
  if ([objc_getAssociatedObject(swipe, kRFSwipeCollapseHandledKey) boolValue]) return;
  objc_setAssociatedObject(swipe, kRFSwipeCollapseHandledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  CGPoint translation = [swipe translationInView:card];
  CGPoint velocity = [swipe velocityInView:card];
  if (RFShouldCollapseThreadForSwipe(translation, width)) {
    RFCollapseRootForHeader(header);
  } else if (RFShouldCollapseForSwipe(translation, velocity)) {
    RFCollapseHeader(header);
  }
}
@end

// Called whenever a comment header lays out: gives its card a recognizer
// while the comment is expanded and removes it once collapsed.
static void RFPrepareSwipeCollapseHeader(UIView *header) {
  if (!gSwipeCollapseEnabled) return;
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{ RFPrepareSwipeCollapseHeader(header); });
    return;
  }
  // Most FlexStackViews fail this two-gesture check without walking ancestors.
  if (!RFHasNativeCommentHeaderRecognizers(header)) return;
  UIView *card = RFCommentContainer(header);
  if (!card) return;

  UIPanGestureRecognizer *swipe = objc_getAssociatedObject(card, kRFSwipeCollapseRecognizerKey);
  BOOL expanded = RFIsExpandedCommentHeader(header);
  if (swipe) {
    if (!expanded && swipe.state == UIGestureRecognizerStatePossible) RFRemoveSwipeCollapse(card);
    return;
  }
  if (!expanded) return;

  swipe = [[UIPanGestureRecognizer alloc] initWithTarget:RFSwipeCollapseGestureHandler.shared
                                                 action:@selector(handleSwipe:)];
  swipe.delegate = RFSwipeCollapseGestureHandler.shared;
  swipe.minimumNumberOfTouches = 1;
  swipe.maximumNumberOfTouches = 1;
  swipe.cancelsTouchesInView = YES;
  swipe.name = @"RedditFilterSwipeToCollapse";
  [card addGestureRecognizer:swipe];
  objc_setAssociatedObject(card, kRFSwipeCollapseRecognizerKey, swipe, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  if (!gSwipeCollapseCards) gSwipeCollapseCards = [NSHashTable weakObjectsHashTable];
  [gSwipeCollapseCards addObject:card];
}

void RFSetSwipeCollapse(BOOL enabled) {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{ RFSetSwipeCollapse(enabled); });
    return;
  }
  if (gSwipeCollapseEnabled == enabled) return;
  gSwipeCollapseEnabled = enabled;
  if (enabled) return; // Headers pick it up as they lay out.
  for (UIView *card in gSwipeCollapseCards.allObjects) RFRemoveSwipeCollapse(card);
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
