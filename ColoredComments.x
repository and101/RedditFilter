// Colored comment threads: each thread line next to a reply gets a color for its depth, so you can
// follow which comment a reply belongs to. A comment's own line (the last in its row) is in full
// color and the lines of the comments above it are faded, or left grey in Apollo style.
//
// Reddit draws a reply's thread lines as a row of thin views at its left edge, one per level: a
// direct reply has one, a reply to that has two, and so on. The first line in that row is always
// depth 1, the second depth 2, so a line's position gives its color and each level keeps the same
// color all the way down a thread.
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

// The color a line should have: Reddit's own, or the one for its depth.
static UIColor *RFLineColor(UIView *line, UIColor *redditColor) {
  if (!gEnabled || !RFIsPlainLine(redditColor) || !line.superview) return redditColor;
  NSUInteger depth = 0, after = 0;
  BOOL seen = NO;
  for (UIView *sibling in line.superview.subviews) {
    if (sibling == line) {
      seen = YES;
    } else if (sibling.class == line.class && RFIsPlainLine(objc_getAssociatedObject(sibling, kRedditColorKey))) {
      if (seen) after++;
      else depth++;
    }
  }
  if (after > 0 && gApolloStyle) return redditColor; // a line of a comment above this one
  NSArray *colors = RFThreadColors();
  UIColor *color = colors[depth % colors.count];
  return after > 0 ? [color colorWithAlphaComponent:0.35] : color;
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
