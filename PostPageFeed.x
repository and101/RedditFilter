// Below a post's comments, Reddit adds "From your feed": your Home feed again, without end. It isn't a
// response the filter sees (it's built from feed data the app already has), so it's hidden on the post
// page itself: the list's sections after the comments that start with a short header card followed by
// feed cards (the same cards as Home) are hidden before they're drawn, and the page stops scrolling at
// the end of the comments. With the Recommended filter (recommendations on post pages hidden).
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "PostPageFeed.h"

@interface RFPostListView : UICollectionView
@end

static BOOL gHideFeed; // main thread
static Class gPostScreenClass;
static char kRFIsPostList, kRFFeedStart, kRFFeedSections, kRFHiddenByUs, kRFTouched;
static BOOL gClamping;

void RFSetHidePostPageFeed(BOOL hide) {
  dispatch_block_t apply = ^{
    gHideFeed = hide;
  };
  if (NSThread.isMainThread) apply();
  else dispatch_async(dispatch_get_main_queue(), apply);
}

// Whether a list is a post page's (cached per list, once it's in a window).
static BOOL RFIsPostList(UICollectionView *list) {
  NSNumber *known = objc_getAssociatedObject(list, &kRFIsPostList);
  if (known) return known.boolValue;
  BOOL post = NO;
  for (UIResponder *node = list.nextResponder; node; node = node.nextResponder)
    if ([node isKindOfClass:UIViewController.class]) {
      post = gPostScreenClass && [node isKindOfClass:gPostScreenClass];
      break;
    }
  objc_setAssociatedObject(list, &kRFIsPostList, @(post), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return post;
}

// A feed card (the same kind Home's feed is made of; a post page's own post and comments are other kinds).
static BOOL RFIsFeedCard(UICollectionViewCell *cell) {
  static Class feedCard;
  if (feedCard) return [cell isKindOfClass:feedCard];
  if (![NSStringFromClass(cell.class) containsString:@"FeedStackSliceViewModel"]) return NO;
  feedCard = cell.class;
  return YES;
}

// The section the feed starts at: a short header card first, then more cards. NSNotFound until it's seen.
static NSInteger RFFeedStart(UICollectionView *list) {
  NSInteger sections = list.numberOfSections;
  NSNumber *start = objc_getAssociatedObject(list, &kRFFeedStart);
  // The comments can grow (more loaded, replies opened), which moves the feed along: found again.
  if (start && [objc_getAssociatedObject(list, &kRFFeedSections) integerValue] != sections) start = nil;
  if (start && start.integerValue < sections) {
    UICollectionViewCell *first = [list cellForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:start.integerValue]];
    if (!first || RFIsFeedCard(first)) return start.integerValue;
  }
  NSInteger found = NSNotFound;
  for (UICollectionViewCell *cell in list.visibleCells) {
    NSIndexPath *path = [list indexPathForCell:cell];
    if (!path || path.item != 0 || path.section == 0 || !RFIsFeedCard(cell) || cell.frame.size.height >= 60) continue;
    if ([list numberOfItemsInSection:path.section] < 2) continue;
    if (found == NSNotFound || path.section < found) found = path.section;
  }
  objc_setAssociatedObject(list, &kRFFeedStart, found == NSNotFound ? nil : @(found), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(list, &kRFFeedSections, @(sections), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return found;
}

// Switched back on: shows the cells hidden here (the page can scroll on again by itself).
static void RFShowPostFeed(UICollectionView *list) {
  if (!objc_getAssociatedObject(list, &kRFTouched)) return;
  objc_setAssociatedObject(list, &kRFTouched, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  for (UICollectionViewCell *cell in list.visibleCells) {
    if (![objc_getAssociatedObject(cell, &kRFHiddenByUs) boolValue]) continue;
    cell.hidden = NO;
    objc_setAssociatedObject(cell, &kRFHiddenByUs, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
}

static void RFHidePostFeed(UICollectionView *list) {
  NSInteger start = RFFeedStart(list);
  for (UICollectionViewCell *cell in list.visibleCells) {
    NSIndexPath *path = [list indexPathForCell:cell];
    BOOL hide = start != NSNotFound && path && path.section >= start;
    BOOL ours = [objc_getAssociatedObject(cell, &kRFHiddenByUs) boolValue];
    if (hide && !cell.hidden) {
      cell.hidden = YES;
      objc_setAssociatedObject(list, &kRFTouched, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      objc_setAssociatedObject(cell, &kRFHiddenByUs, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (!hide && ours) {
      cell.hidden = NO; // reused for something else
      objc_setAssociatedObject(cell, &kRFHiddenByUs, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
  }
  if (start == NSNotFound) return;
  // The page ends where the feed would start.
  UICollectionViewLayoutAttributes *attributes = [list layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:start]];
  if (!attributes) return;
  CGFloat top = -list.adjustedContentInset.top;
  CGFloat end = MAX(top, CGRectGetMinY(attributes.frame) + list.adjustedContentInset.bottom - list.bounds.size.height);
  if (list.contentOffset.y > end + 0.5) {
    gClamping = YES;
    list.contentOffset = CGPointMake(list.contentOffset.x, end);
    gClamping = NO;
  }
}

%group RFPostFeedHooks
%hook RFPostListView
- (void)layoutSubviews {
  %orig;
  UICollectionView *list = (UICollectionView *)self;
  if (gClamping || !list.window || !RFIsPostList(list)) return;
  if (gHideFeed) RFHidePostFeed(list);
  else RFShowPostFeed(list);
}
%end
%end

%ctor {
  gPostScreenClass = NSClassFromString(@"PDP_Impl.PDPViewController");
  Class list = NSClassFromString(@"_TtC8SliceKit18ListCollectionView");
  if (gPostScreenClass && [list isSubclassOfClass:UICollectionView.class]) %init(RFPostFeedHooks, RFPostListView = list);
}
