// Colored comment threads: each thread line next to a reply gets a color for its depth, so you can
// follow which comment a reply belongs to. A comment's own line (the last in its row) is in full
// color and the lines of the comments above it are faded, or left grey in Apollo style.
//
// Reddit draws a reply's thread lines as a row of thin views at its left edge, one per level: a
// direct reply has one, a reply to that has two, and so on. The first line in that row is always
// depth 1, the second depth 2, so a line's position gives its color and each level keeps the same
// color all the way down a thread. A highlighted comment's gold line keeps its color and isn't counted.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ColoredComments.h"

@interface PDPVerticalDivider : UIView
@end
@interface TreeVerticalDivider : UIView
@end

static BOOL gEnabled, gApolloStyle;
static NSHashTable<UIView *> *gLines; // lines seen so far, to recolor when the setting changes (main thread)
static const void *kRedditColorKey = &kRedditColorKey;

// Depths 1, 2, 3... use these in turn, starting over after the last.
static NSArray<UIColor *> *RFThreadColors(void) {
  static NSArray *colors;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    colors = @[
      UIColor.systemRedColor, UIColor.systemOrangeColor, UIColor.systemYellowColor, UIColor.systemGreenColor,
      UIColor.systemTealColor, UIColor.systemBlueColor, UIColor.systemPurpleColor
    ];
  });
  return colors;
}

// Ordinary thread lines are a faint grey. Lines in any other color mean something (a highlighted
// comment's is gold), so those keep Reddit's color.
static BOOL RFIsPlainLine(UIColor *color) {
  CGFloat r, g, b, a;
  if (![color getRed:&r green:&g blue:&b alpha:&a]) return NO;
  return MAX(r, MAX(g, b)) - MIN(r, MIN(g, b)) < 0.05;
}

// The comment row a line sits in.
static UIView *RFCommentRow(UIView *line) {
  for (UIView *view = line.superview; view; view = view.superview)
    if ([view isKindOfClass:UICollectionViewCell.class] || [view isKindOfClass:UITableViewCell.class]) return view;
  return nil;
}

// A line's depth, 0 for a direct reply. Taken from where it sits in its row: each level is indented by the
// same step, the gap between neighbouring lines (16 points in 2026.43). Lines outside the levels, like the
// gold line a highlighted comment gets at the row's edge, don't shift the others. Before the row is laid
// out, counts the plain lines before it instead.
static NSInteger RFLineDepth(UIView *line, NSArray<UIView *> *lines) {
  NSInteger plainBefore = 0;
  for (UIView *other in lines) {
    if (other == line) break;
    if (RFIsPlainLine(objc_getAssociatedObject(other, kRedditColorKey))) plainBefore++;
  }
  UIView *row = RFCommentRow(line);
  if (!row || !line.window) return plainBefore;
  CGFloat x = [line convertPoint:CGPointZero toView:row].x, step = 16;
  for (NSUInteger i = 1; i < lines.count; i++) {
    CGFloat gap = [lines[i] convertPoint:CGPointZero toView:row].x - [lines[i - 1] convertPoint:CGPointZero toView:row].x;
    if (gap > 4) {
      step = gap;
      break;
    }
  }
  NSInteger level = lround(x / step);
  return level >= 1 ? level - 1 : plainBefore;
}

// The color a line should have: Reddit's own, or the one for its depth.
static UIColor *RFLineColor(UIView *line, UIColor *redditColor) {
  if (!gEnabled || !RFIsPlainLine(redditColor) || !line.superview) return redditColor;
  NSMutableArray<UIView *> *lines = [NSMutableArray array];
  for (UIView *sibling in line.superview.subviews)
    if (sibling.class == line.class) [lines addObject:sibling];
  // The comment's own line is the last; every other line, whatever its color, is a comment above it.
  BOOL own = lines.lastObject == line;
  if (!own && gApolloStyle) return redditColor;
  NSArray *colors = RFThreadColors();
  UIColor *color = colors[RFLineDepth(line, lines) % colors.count];
  return own ? color : [color colorWithAlphaComponent:0.35];
}

// Reapplies Reddit's last color through the setter below, which swaps in the depth color.
static void RFRefreshLine(UIView *line) {
  UIColor *redditColor = objc_getAssociatedObject(line, kRedditColorKey);
  if (redditColor && ![line.backgroundColor isEqual:RFLineColor(line, redditColor)]) line.backgroundColor = redditColor;
}

static void RFTrackLine(UIView *line) {
  if (!gLines) gLines = [NSHashTable weakObjectsHashTable];
  [gLines addObject:line];
  RFRefreshLine(line);
}

void RFSetColoredComments(BOOL enabled, BOOL apolloStyle) {
  if (enabled == gEnabled && apolloStyle == gApolloStyle) return;
  gEnabled = enabled;
  gApolloStyle = apolloStyle;
  dispatch_async(dispatch_get_main_queue(), ^{
    for (UIView *line in gLines.allObjects) RFRefreshLine(line);
  });
}

// The same hooks for both kinds of thread line: the comments page's and the newer comment tree's.
%group PDPLines
%hook PDPVerticalDivider
- (void)setBackgroundColor:(UIColor *)color {
  objc_setAssociatedObject(self, kRedditColorKey, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  %orig(RFLineColor(self, color));
}
- (void)didMoveToSuperview {
  %orig;
  if (((UIView *)self).superview) RFTrackLine(self);
}
// Reused rows can gain or lose lines, which moves the others.
- (void)layoutSubviews {
  %orig;
  RFRefreshLine(self);
}
%end
%end

%group TreeLines
%hook TreeVerticalDivider
- (void)setBackgroundColor:(UIColor *)color {
  objc_setAssociatedObject(self, kRedditColorKey, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  %orig(RFLineColor(self, color));
}
- (void)didMoveToSuperview {
  %orig;
  if (((UIView *)self).superview) RFTrackLine(self);
}
- (void)layoutSubviews {
  %orig;
  RFRefreshLine(self);
}
%end
%end

%ctor {
  Class pdpLines = NSClassFromString(@"PDP_CommentSheet_Impl.VerticalDivider");
  Class treeLines = NSClassFromString(@"Components_CommentTreeItem_CommentTreeItemPresentation_Internal.CommentTreeItemVerticalDivider");
  if (pdpLines) %init(PDPLines, PDPVerticalDivider = pdpLines);
  if (treeLines) %init(TreeLines, TreeVerticalDivider = treeLines);
}
