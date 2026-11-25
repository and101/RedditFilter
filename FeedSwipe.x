// FeedSwipe.x
//
// Swipe posts (FeedSwipe.h). A pan on each post card in a feed (FeedKit's FeedStackSliceView) slides the
// card like Swipe to collapse does for comments. Letting go presses the post's own vote button, or picks
// Save in its ⋯ menu, which opens out of sight: Reddit then does what a tap would, toast included.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import "Preferences.h"
#import "SwipeCollapse.h"
#import "SwipeGestures.h"
#import "FeedSwipe.h"
#import "SavedPosts.h"

@interface RFFeedStackSliceView : UIView
@end

typedef NS_ENUM(NSInteger, RFPostSwipeAction) {
  RFPostSwipeNone,
  RFPostSwipeUpvote,
  RFPostSwipeDownvote,
  RFPostSwipeSave,
};

static _Atomic BOOL gFeedSwipeEnabled;
static BOOL gFeedSwipeHaptics = YES;
static NSHashTable<UIView *> *gFeedSwipeCards;
static const void *kRFFeedSwipeRecognizerKey = &kRFFeedSwipeRecognizerKey;
static const void *kRFFeedSwipeRevealKey = &kRFFeedSwipeRevealKey;
static const void *kRFFeedSwipeStartXKey = &kRFFeedSwipeStartXKey;
static const void *kRFFeedSwipeDirectionKey = &kRFFeedSwipeDirectionKey;
static const void *kRFFeedSwipeStageKey = &kRFFeedSwipeStageKey;
static const void *kRFFeedSwipeSavedKey = &kRFFeedSwipeSavedKey;
// Matches Swipe to collapse's back edge (SwipeCollapseGeometry.m).
static const CGFloat kRFFeedSwipeBackEdgeWidth = 24.0;

#pragma mark - The post's own buttons

static UIControl *RFControlWithIdentifierPrefix(UIView *root, NSString *prefix) {
  if (root.hidden) return nil;
  if ([root isKindOfClass:UIControl.class] && [root.accessibilityIdentifier hasPrefix:prefix] &&
      CGRectGetWidth(root.bounds) > 0)
    return (UIControl *)root;
  for (UIView *child in root.subviews) {
    UIControl *found = RFControlWithIdentifierPrefix(child, prefix);
    if (found) return found;
  }
  return nil;
}

static void RFCollectVoteButtons(UIView *root, NSMutableArray<UIControl *> *buttons) {
  if (root.hidden) return;
  if ([root isKindOfClass:UIControl.class] && [NSStringFromClass(root.class) containsString:@"RPLVoteButton"] &&
      CGRectGetWidth(root.bounds) > 0)
    [buttons addObject:(UIControl *)root];
  for (UIView *child in root.subviews) RFCollectVoteButtons(child, buttons);
}

// The upvote or downvote button in the card's action bar: by identifier, or else the first and second
// vote button from the left.
static UIControl *RFVoteButton(UIView *card, BOOL up) {
  UIControl *button = RFControlWithIdentifierPrefix(
      card, up ? @"reddit_feed__post_comment_bar__upvote_button" : @"reddit_feed__post_comment_bar__downvote_button");
  if (button) return button;
  NSMutableArray<UIControl *> *buttons = [NSMutableArray array];
  RFCollectVoteButtons(card, buttons);
  if (buttons.count != 2) return nil;
  [buttons sortUsingComparator:^NSComparisonResult(UIControl *a, UIControl *b) {
    CGFloat ax = [a convertPoint:CGPointZero toView:nil].x, bx = [b convertPoint:CGPointZero toView:nil].x;
    return ax < bx ? NSOrderedAscending : ax > bx ? NSOrderedDescending : NSOrderedSame;
  }];
  return buttons[up ? 0 : 1];
}

// Whether a vote button is already pressed: its identifier ends in _selected rather than _not_selected.
static BOOL RFVoteButtonIsOn(UIControl *button) {
  NSString *identifier = button.accessibilityIdentifier;
  if ([identifier hasSuffix:@"_not_selected"]) return NO;
  if ([identifier hasSuffix:@"_selected"]) return YES;
  return button.selected;
}

// A button showing Reddit's ⋯ icon (rpl3/overflowHorizontal, or rpl3/png/overflowHorizontal-16).
static UIControl *RFControlWithOverflowIcon(UIView *root) {
  if (root.hidden) return nil;
  if ([root isKindOfClass:UIControl.class] && CGRectGetWidth(root.bounds) > 0)
    for (UIView *child in root.subviews)
      if ([child isKindOfClass:UIImageView.class] && [child.accessibilityIdentifier containsString:@"overflowHorizontal"])
        return (UIControl *)root;
  for (UIView *child in root.subviews) {
    UIControl *found = RFControlWithOverflowIcon(child);
    if (found) return found;
  }
  return nil;
}

// Any control with this identifier, even one that's hidden or has no size.
static UIControl *RFHiddenControlWithIdentifier(UIView *root, NSString *identifier) {
  if ([root isKindOfClass:UIControl.class] && [root.accessibilityIdentifier isEqualToString:identifier])
    return (UIControl *)root;
  for (UIView *child in root.subviews) {
    UIControl *found = RFHiddenControlWithIdentifier(child, identifier);
    if (found) return found;
  }
  return nil;
}

// The post's ⋯ button: identified on Home, unnamed (just its icon) in community feeds. Some compact cards
// don't show one (Home with tabs; holding the post opens the menu): the button is there with no size, and
// pressing it opens the same menu.
static UIControl *RFOverflowButton(UIView *card) {
  return RFControlWithIdentifierPrefix(card, @"reddit_feed__post_title__overflow_button")
             ?: RFControlWithOverflowIcon(card)
             ?: RFHiddenControlWithIdentifier(card, @"reddit_post__promoted_post__overflow_button");
}

static UIView *RFViewWithIdentifierSuffix(UIView *root, NSArray<NSString *> *suffixes) {
  for (NSString *suffix in suffixes)
    if ([root.accessibilityIdentifier hasSuffix:suffix]) return root;
  for (UIView *child in root.subviews) {
    UIView *found = RFViewWithIdentifierSuffix(child, suffixes);
    if (found) return found;
  }
  return nil;
}

// Whether the card's post is already saved, as far as that's known (SavedPosts.h). The card doesn't show it.
static BOOL RFCardPostIsSaved(UIView *card) {
  UIView *title = RFViewWithIdentifierSuffix(
      card, @[ @"reddit_feed__post__title_text", @"reddit_feed__post__classic_view_post_title" ]);
  NSString *text = nil;
  if ([title isKindOfClass:UITextView.class]) text = ((UITextView *)title).text;
  else if ([title isKindOfClass:UILabel.class]) text = ((UILabel *)title).text;
  return RFSavedPostsIsSaved(text.length ? text : title.accessibilityLabel, card.accessibilityLabel);
}

#pragma mark - Save, through the ⋯ menu

// Set while the swipe's own ⋯ menu is on its way, so that one presentation opens hidden.
static BOOL gHideNextOverflowMenu;
static NSUInteger gOverflowMenuRequest;
static const void *kRFHiddenMenuKey = &kRFHiddenMenuKey;

static BOOL RFIsHiddenMenu(UIViewController *controller) {
  return controller && objc_getAssociatedObject(controller, kRFHiddenMenuKey) != nil;
}

// Picks a menu row the way a tap does: the menu is a collection view whose delegate acts on selection.
static BOOL RFSelectMenuRow(UIView *row) {
  UICollectionViewCell *cell = nil;
  UICollectionView *collection = nil;
  for (UIView *view = row; view; view = view.superview) {
    if (!cell && [view isKindOfClass:UICollectionViewCell.class]) cell = (UICollectionViewCell *)view;
    else if (cell && [view isKindOfClass:UICollectionView.class]) {
      collection = (UICollectionView *)view;
      break;
    }
  }
  NSIndexPath *path = cell ? [collection indexPathForCell:cell] : nil;
  id<UICollectionViewDelegate> delegate = collection.delegate;
  if (!path || ![delegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) return NO;
  if ([delegate respondsToSelector:@selector(collectionView:shouldSelectItemAtIndexPath:)] &&
      ![delegate collectionView:collection shouldSelectItemAtIndexPath:path])
    return NO;
  [delegate collectionView:collection didSelectItemAtIndexPath:path];
  return YES;
}

// Reddit fills the menu in just after it appears. Save is near the top, but scroll down to it on a long
// menu. If it never shows (logged out, or Reddit changed the menu), close the menu again.
static void RFPickSaveInMenu(UIViewController *menu, NSInteger triesLeft) {
  if (!menu.presentingViewController) return; // already closed
  [menu.view layoutIfNeeded];
  NSArray *rows = @[ @"__save_button", @"__unsave_button" ];
  UIView *row = RFViewWithIdentifierSuffix(menu.view, rows);
  if (!row && triesLeft % 5 == 0) {
    // Not laid out yet: scroll each list down a screen at a time.
    NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:menu.view];
    for (NSUInteger i = 0; i < views.count; i++) {
      UIView *view = views[i];
      if ([view isKindOfClass:UICollectionView.class]) {
        UICollectionView *collection = (UICollectionView *)view;
        CGFloat maxY = MAX(0, collection.contentSize.height - CGRectGetHeight(collection.bounds));
        CGFloat y = MIN(maxY, collection.contentOffset.y + CGRectGetHeight(collection.bounds));
        [collection setContentOffset:CGPointMake(collection.contentOffset.x, y) animated:NO];
        [collection layoutIfNeeded];
      }
      [views addObjectsFromArray:view.subviews];
    }
    row = RFViewWithIdentifierSuffix(menu.view, rows);
  }
  if (row && RFSelectMenuRow(row)) {
    // Picking a row closes the menu; make sure it isn't left open, hidden, if it didn't.
    __weak UIViewController *weakMenu = menu;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      UIViewController *menu = weakMenu;
      if (menu.presentingViewController) [menu dismissViewControllerAnimated:NO completion:nil];
    });
    return;
  }
  if (triesLeft <= 0) {
    [menu dismissViewControllerAnimated:NO completion:nil];
    return;
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    RFPickSaveInMenu(menu, triesLeft - 1);
  });
}

static void RFSavePost(UIView *card) {
  UIControl *overflow = RFOverflowButton(card);
  if (!overflow) return;
  gHideNextOverflowMenu = YES;
  NSUInteger request = ++gOverflowMenuRequest;
  // The menu normally appears within half a second; never hide a presentation that comes later.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (request == gOverflowMenuRequest) gHideNextOverflowMenu = NO;
  });
  [overflow sendActionsForControlEvents:UIControlEventTouchUpInside];
}

%hook UIViewController

- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
  if (!gHideNextOverflowMenu || ![NSStringFromClass(controller.class) containsString:@"Overflow"]) {
    %orig;
    return;
  }
  gHideNextOverflowMenu = NO;
  objc_setAssociatedObject(controller, kRFHiddenMenuKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  // Or the status bar turns white for the menu's dimmed background.
  controller.modalPresentationCapturesStatusBarAppearance = NO;
  // Picked once the menu has finished appearing, as it would be by a tap: Reddit may present something next
  // (the login sheet, when logged out), which is lost if the menu is still on its way in.
  %orig(controller, NO, ^{
    controller.presentationController.containerView.alpha = 0; // if the hook below wasn't there to do it
    if (completion) completion();
    dispatch_async(dispatch_get_main_queue(), ^{ RFPickSaveInMenu(controller, 40); });
  });
}

%end

// The menu's sheet. UIKit makes its container view a little after presentViewController: returns, and it can
// reach the screen before anything queued then runs. This is called as soon as it exists.
%group RFHiddenMenuHooks
%hook RFPanModalPresentationController

- (void)presentationTransitionWillBegin {
  UIPresentationController *presentation = (UIPresentationController *)self;
  if (RFIsHiddenMenu(presentation.presentedViewController)) presentation.containerView.alpha = 0;
  %orig;
}

%end
%end

#pragma mark - What shows behind the card

@interface RFFeedSwipeReveal : UIView
@property(nonatomic, strong) UIImageView *icon;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic) BOOL onLeft; // the card moved right, so the space is on its left
@property(nonatomic) CGFloat gap;  // how far the card has moved
- (void)showAction:(RFPostSwipeAction)action undo:(BOOL)undo;
@end

@implementation RFFeedSwipeReveal {
  RFPostSwipeAction _action;
  BOOL _undo;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.userInteractionEnabled = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
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
  }
  return self;
}

- (void)showAction:(RFPostSwipeAction)action undo:(BOOL)undo {
  if (action == _action && undo == _undo && self.label.text) return;
  _action = action;
  _undo = undo;
  NSString *symbol = undo ? @"bookmark.slash" : @"bookmark", *text = undo ? @"Unsave" : @"Save";
  UIColor *colour = UIColor.systemGreenColor;
  if (action == RFPostSwipeUpvote) {
    symbol = @"arrow.up";
    text = undo ? @"Remove upvote" : @"Upvote";
    colour = UIColor.systemOrangeColor;
  } else if (action == RFPostSwipeDownvote) {
    symbol = @"arrow.down";
    text = undo ? @"Remove downvote" : @"Downvote";
    colour = UIColor.systemIndigoColor;
  }
  self.icon.image = [[UIImage systemImageNamed:symbol]
      imageWithConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17
                                                                             weight:UIImageSymbolWeightSemibold]];
  self.label.text = text;
  self.backgroundColor = colour;
  [self setNeedsLayout];
}

- (void)setOnLeft:(BOOL)onLeft {
  if (_onLeft == onLeft) return;
  _onLeft = onLeft;
  [self setNeedsLayout];
}

- (void)setGap:(CGFloat)gap {
  if (_gap == gap) return;
  _gap = gap;
  [self setNeedsLayout];
}

// Icon and label sit near the top of the card, so they stay on screen for tall posts: just inside the
// screen edge at first, then in the middle of the space as the card moves further.
- (void)layoutSubviews {
  [super layoutSubviews];
  CGFloat width = CGRectGetWidth(self.bounds), height = CGRectGetHeight(self.bounds);
  CGFloat centreY = MIN(height / 2.0, 60.0);
  CGSize labelSize = [self.label sizeThatFits:CGSizeMake(120, 40)];
  CGFloat columnWidth = MAX(28.0, labelSize.width);
  CGFloat fromEdge = MAX(10.0 + columnWidth / 2.0, self.gap / 2.0);
  CGFloat centreX = self.onLeft ? fromEdge : width - fromEdge;
  self.icon.frame = CGRectMake(centreX - 11, centreY - 18, 22, 22);
  self.label.frame = CGRectMake(centreX - columnWidth / 2.0, centreY + 6, columnWidth, labelSize.height);
}

@end

#pragma mark - Card movement

static UICollectionViewCell *RFFeedCellForCard(UIView *card) {
  for (UIView *view = card; view; view = view.superview)
    if ([view isKindOfClass:UICollectionViewCell.class]) return (UICollectionViewCell *)view;
  return nil;
}

// The cell's content view slides, so the whole card moves; moving its sublayers rather than the view
// leaves Reddit's frames and layout alone.
static UIView *RFFeedMovingView(UIView *card) {
  UICollectionViewCell *cell = RFFeedCellForCard(card);
  return cell && [card isDescendantOfView:cell.contentView] ? cell.contentView : card;
}

static RFFeedSwipeReveal *RFFeedRevealForCard(UIView *card, BOOL create) {
  UICollectionViewCell *cell = RFFeedCellForCard(card);
  if (!cell) return nil;
  RFFeedSwipeReveal *reveal = objc_getAssociatedObject(cell, kRFFeedSwipeRevealKey);
  if (!reveal && create) {
    reveal = [[RFFeedSwipeReveal alloc] initWithFrame:cell.bounds];
    reveal.hidden = YES;
    objc_setAssociatedObject(cell, kRFFeedSwipeRevealKey, reveal, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  if (reveal && reveal.superview != cell) [cell insertSubview:reveal belowSubview:cell.contentView];
  return reveal;
}

static void RFSetFeedCardOffset(UIView *card, CGFloat dx, RFPostSwipeAction action, BOOL undo) {
  UIView *moving = RFFeedMovingView(card);
  RFFeedSwipeReveal *reveal = RFFeedRevealForCard(card, YES);
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [moving.layer removeAnimationForKey:@"RFFeedSwipeReturn"];
  moving.layer.sublayerTransform = CATransform3DMakeTranslation(dx, 0, 0);
  if (reveal) {
    reveal.frame = reveal.superview.bounds;
    reveal.hidden = dx == 0;
    reveal.onLeft = dx > 0;
    reveal.gap = fabs(dx);
    [reveal showAction:action undo:undo];
    reveal.alpha = MIN(1.0, fabs(dx) / 48.0);
  }
  [CATransaction commit];
}

static void RFResetFeedCard(UIView *card, BOOL animated) {
  UIView *moving = RFFeedMovingView(card);
  RFFeedSwipeReveal *reveal = RFFeedRevealForCard(card, NO);
  CATransform3D current = moving.layer.presentationLayer ? moving.layer.presentationLayer.sublayerTransform
                                                         : moving.layer.sublayerTransform;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  moving.layer.sublayerTransform = CATransform3DIdentity;
  [moving.layer removeAnimationForKey:@"RFFeedSwipeReturn"];
  if (animated && !CATransform3DIsIdentity(current)) {
    CABasicAnimation *back = [CABasicAnimation animationWithKeyPath:@"sublayerTransform"];
    back.fromValue = [NSValue valueWithCATransform3D:current];
    back.toValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
    back.duration = 0.22;
    back.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    __weak RFFeedSwipeReveal *weakReveal = reveal;
    [CATransaction setCompletionBlock:^{
      if (CATransform3DIsIdentity(moving.layer.sublayerTransform)) weakReveal.hidden = YES;
    }];
    [moving.layer addAnimation:back forKey:@"RFFeedSwipeReturn"];
  } else {
    reveal.hidden = YES;
  }
  [CATransaction commit];
}

#pragma mark - The gesture

static UIImpactFeedbackGenerator *RFFeedSwipeHaptics(void) {
  static UIImpactFeedbackGenerator *generator;
  if (!generator) generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
  return generator;
}

// The action a left swipe (mirrored for a right one) has reached: 0 none, 1 the short one, 2 the long one.
static NSInteger RFFeedSwipeStage(CGPoint translation, CGFloat width, BOOL right) {
  return RFSwipeCollapseStage(translation, width, !right);
}

static RFPostSwipeAction RFFeedSwipeActionForStage(NSInteger stage, BOOL right) {
  if (right) return RFPostSwipeSave;
  return stage >= 2 ? RFPostSwipeDownvote : RFPostSwipeUpvote;
}

@interface RFFeedSwipeHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)handleSwipe:(UIPanGestureRecognizer *)swipe;
@end

@implementation RFFeedSwipeHandler

+ (instancetype)shared {
  static RFFeedSwipeHandler *handler;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ handler = [self new]; });
  return handler;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
  if (!gFeedSwipeEnabled) return NO;
  UIView *card = recognizer.view;
  CGFloat startX = [touch locationInView:nil].x;
  // Touches at the screen's left edge go back or open the side menu, without waiting for this swipe.
  if (startX < kRFFeedSwipeBackEdgeWidth) return NO;
  objc_setAssociatedObject(recognizer, kRFFeedSwipeStartXKey, @(startX), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return !RFTouchBelongsToOwnHorizontalGesture(touch.view, card);
}

// The pans above the card that aren't scrolling (going back across the whole screen, the side menu)
// start sooner than this swipe decides, so they wait until it fails. It fails as soon as a drag turns
// out to be vertical.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer
    shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
  if (!gFeedSwipeEnabled || ![other isKindOfClass:UIPanGestureRecognizer.class] || !other.view ||
      [NSStringFromClass(other.class) containsString:@"UIScrollView"])
    return NO;
  return recognizer.view != other.view && [recognizer.view isDescendantOfView:other.view];
}

// Left swipes are claimed on posts with vote buttons, right ones on posts with a ⋯ menu, except those
// starting at the screen's left edge (going back, or the side menu). Everything else stays with Reddit.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
  if (!gFeedSwipeEnabled || ![recognizer isKindOfClass:UIPanGestureRecognizer.class]) return NO;
  UIPanGestureRecognizer *swipe = (UIPanGestureRecognizer *)recognizer;
  UIView *card = swipe.view;
  CGFloat startX = [objc_getAssociatedObject(swipe, kRFFeedSwipeStartXKey) doubleValue];
  NSInteger direction = RFSwipeDirectionToClaim([swipe translationInView:card], [swipe velocityInView:card], startX,
                                                RFVoteButton(card, YES) != nil, RFOverflowButton(card) != nil);
  if (direction == 0) return NO;
  objc_setAssociatedObject(swipe, kRFFeedSwipeDirectionKey, @(direction), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  RFSuppressPagerRecognizersForSwipe(card, swipe, direction > 0);
  RFRestorePagersIfSwipeNeverBegan(swipe, 10);
  return YES;
}

- (void)handleSwipe:(UIPanGestureRecognizer *)swipe {
  UIView *card = swipe.view;
  CGFloat width = CGRectGetWidth(card.bounds);
  // The rules below read a right swipe as its mirror image: a left swipe.
  BOOL right = [objc_getAssociatedObject(swipe, kRFFeedSwipeDirectionKey) integerValue] > 0;
  CGPoint translation = [swipe translationInView:card];
  CGPoint velocity = [swipe velocityInView:card];
  if (right) {
    translation = RFMirroredSwipeVector(translation);
    velocity = RFMirroredSwipeVector(velocity);
  }

  if (swipe.state == UIGestureRecognizerStateBegan) {
    objc_setAssociatedObject(swipe, kRFFeedSwipeStageKey, @0, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(swipe, kRFFeedSwipeSavedKey, @(right && RFCardPostIsSaved(card)), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (gFeedSwipeHaptics) [RFFeedSwipeHaptics() prepare];
  }

  if (swipe.state == UIGestureRecognizerStateBegan || swipe.state == UIGestureRecognizerStateChanged) {
    // The card follows the finger, with resistance past the long swipe's distance.
    CGFloat limit = RFThreadCollapseDistance(width);
    CGFloat dx = MIN(0.0, translation.x);
    if (dx < -limit) dx = -limit + (dx + limit) * 0.3;
    NSInteger stage = RFFeedSwipeStage(translation, width, right);
    RFPostSwipeAction action = RFFeedSwipeActionForStage(stage, right);
    UIControl *vote = action == RFPostSwipeSave ? nil : RFVoteButton(card, action == RFPostSwipeUpvote);
    BOOL undo = action == RFPostSwipeSave ? [objc_getAssociatedObject(swipe, kRFFeedSwipeSavedKey) boolValue]
                                          : vote && RFVoteButtonIsOn(vote);
    RFSetFeedCardOffset(card, right ? -dx : dx, action, undo);
    // A tap of feedback as the swipe reaches each action; moving back lets it fire again.
    NSInteger previous = [objc_getAssociatedObject(swipe, kRFFeedSwipeStageKey) integerValue];
    if (gFeedSwipeHaptics && stage > previous) [RFFeedSwipeHaptics() impactOccurred];
    if (stage != previous)
      objc_setAssociatedObject(swipe, kRFFeedSwipeStageKey, @(stage), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return;
  }

  if (swipe.state != UIGestureRecognizerStateEnded && swipe.state != UIGestureRecognizerStateCancelled &&
      swipe.state != UIGestureRecognizerStateFailed)
    return;

  RFRestorePagerRecognizersForSwipe(swipe);
  RFResetFeedCard(card, YES);
  if (swipe.state != UIGestureRecognizerStateEnded || !gFeedSwipeEnabled) return;

  RFPostSwipeAction action = RFPostSwipeNone;
  if (!right && RFShouldCollapseThreadForSwipe(translation, width)) action = RFPostSwipeDownvote;
  else if (RFShouldCollapseForSwipe(translation, velocity)) action = right ? RFPostSwipeSave : RFPostSwipeUpvote;
  if (action == RFPostSwipeSave) RFSavePost(card);
  else if (action != RFPostSwipeNone)
    [RFVoteButton(card, action == RFPostSwipeUpvote) sendActionsForControlEvents:UIControlEventTouchUpInside];
}

@end

static void RFRemoveFeedSwipe(UIView *card) {
  UIPanGestureRecognizer *swipe = objc_getAssociatedObject(card, kRFFeedSwipeRecognizerKey);
  if (!swipe) return;
  // Removing a recognizer mid-swipe sends no final action, so undo its effects here.
  RFRestorePagerRecognizersForSwipe(swipe);
  RFResetFeedCard(card, NO);
  [card removeGestureRecognizer:swipe];
  objc_setAssociatedObject(card, kRFFeedSwipeRecognizerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void RFPrepareFeedSwipe(UIView *card) {
  if (!gFeedSwipeEnabled || !card.window || objc_getAssociatedObject(card, kRFFeedSwipeRecognizerKey)) return;
  UIPanGestureRecognizer *swipe = [[UIPanGestureRecognizer alloc] initWithTarget:RFFeedSwipeHandler.shared
                                                                          action:@selector(handleSwipe:)];
  swipe.delegate = RFFeedSwipeHandler.shared;
  swipe.maximumNumberOfTouches = 1;
  swipe.name = @"RedditFilterSwipePosts";
  [card addGestureRecognizer:swipe];
  objc_setAssociatedObject(card, kRFFeedSwipeRecognizerKey, swipe, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if (!gFeedSwipeCards) gFeedSwipeCards = [NSHashTable weakObjectsHashTable];
  [gFeedSwipeCards addObject:card];
}

BOOL RFFeedSwipeEnabled(void) {
  return gFeedSwipeEnabled;
}

void RFSetFeedSwipe(BOOL enabled, BOOL haptics) {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{ RFSetFeedSwipe(enabled, haptics); });
    return;
  }
  gFeedSwipeHaptics = haptics;
  if (gFeedSwipeEnabled == enabled) return;
  gFeedSwipeEnabled = enabled;
  if (enabled) return; // cards pick it up as they reach the screen
  RFSavedPostsForget();
  for (UIView *card in gFeedSwipeCards.allObjects) RFRemoveFeedSwipe(card);
}

%group RFFeedStackHooks
%hook RFFeedStackSliceView

- (void)didMoveToWindow {
  %orig;
  RFPrepareFeedSwipe((UIView *)self);
}

%end
%end

%ctor {
  Class card = NSClassFromString(@"FeedKit_Slices.FeedStackSliceView");
  if (card) %init(RFFeedStackHooks, RFFeedStackSliceView = card);
  Class sheet = NSClassFromString(@"PanModal.PanModalPresentationController");
  if (sheet) %init(RFHiddenMenuHooks, RFPanModalPresentationController = sheet);
  %init;
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  RFSetFeedSwipe([defaults boolForKey:kRedditFilterSwipePosts], [defaults boolForKey:kRedditFilterSwipeCollapseHaptics]);
}
