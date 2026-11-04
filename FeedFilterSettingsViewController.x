#import <objc/message.h>
#import <objc/runtime.h>
#import "FeedFilterSettingsViewController.h"
#import "KeywordsViewController.h"
#import "DebugMenu.h"
#import "RFStats.h"
#import "RFStatsViewController.h"
#import "UpdateChecker.h"

#ifndef RF_VERSION
#define RF_VERSION "dev" // the Makefile passes the real version
#endif

#pragma mark - The filter rows

typedef struct {
  __unsafe_unretained NSString *key;
  __unsafe_unretained NSString *title;
  __unsafe_unretained NSString *subtitle; // nil for none
  __unsafe_unretained NSString *icons;    // comma-separated, first icon found wins
  BOOL switchOnMeansShow;                 // YES: switch ON saves NO (shows the content, or prefers SD over HD)
  __unsafe_unretained NSString *requires; // only switchable while this setting is on, nil for always
} RFToggleRow;

static const RFToggleRow kToggleRows[] = {
    {kRedditFilterPromoted, @"Promoted", @"Show ads in your feed and comments", @"rpl3/tag,icon_tag", YES},
    {kRedditFilterRecommended, @"Recommended", @"Show recommendations on post pages", @"rpl3/spam,icon_spam", YES},
    {kRedditFilterNSFW, @"NSFW", @"Show NSFW posts", @"rpl3/nsfw,icon_nsfw_outline,icon_nsfw", YES},
    {kRedditFilterVideosForYou, @"Videos for you", @"Show the video carousel in your feed",
     @"rpl3/video,icon_video,icon_play", YES},
    {kRedditFilterAwards, @"Awards", @"Show awards on posts and comments",
     @"rpl3/award,icon_gift_fill,icon_award,icon-award-outline", YES},
    {kRedditFilterScores, @"Scores", @"Show vote count on posts and comments", @"rpl3/upvote,icon_upvote", YES},
    {kRedditFilterColoredComments, @"Coloured comment threads", @"Give each reply level its own colour",
     @"rpl3/branch,rpl3/comment,icon_comment", NO},
    {kRedditFilterColoredCommentsApollo, @"Apollo style", @"Only colour each comment's own line",
     @"rpl3/branch,rpl3/comment,icon_comment", NO, kRedditFilterColoredComments},
};
static const NSInteger kToggleRowCount = sizeof(kToggleRows) / sizeof(kToggleRows[0]);

// In the Keywords section, under the keyword list. Their switch tags follow kToggleRows'.
static const RFToggleRow kKeywordRows[] = {
    {kRedditFilterKeywordComments, @"Filter comments too", @"Hide comments that mention a keyword",
     @"rpl3/comment,icon_comment", NO},
    {kRedditFilterKeywordCommentReplies, @"Hide replies too", @"Also hide the replies below them",
     @"rpl3/reply,icon_reply", NO, kRedditFilterKeywordComments},
};
static const NSInteger kKeywordRowCount = sizeof(kKeywordRows) / sizeof(kKeywordRows[0]);

// In the RedGIFs section. Their switch tags follow kUpdateRow's.
static const RFToggleRow kRedgifsRows[] = {
    {kRedditFilterRedgifsDirect, @"Direct-play RedGIFs", @"Plays with sound, but may use more data",
     @"rpl3/volumeOn,rpl3/play", NO},
    // Saved as "prefer HD", so the switch is the opposite.
    {kRedditFilterRedgifsHD, @"Prefer SD", @"Uses about a tenth of the data. Off prefers sharper HD",
     @"rpl3/video,icon_video,icon_play", YES, kRedditFilterRedgifsDirect},
    {kRedditFilterRedgifsHDWiFiOnly, @"Prefer SD on mobile data", @"And in Low Data Mode. HD is preferred on Wi-Fi",
     @"rf/wifi", NO, kRedditFilterRedgifsHD},
};
static const NSInteger kRedgifsRowCount = sizeof(kRedgifsRows) / sizeof(kRedgifsRows[0]);

// In the Collapsing section, after the row that opens Swipe to collapse. Their switch tags follow kRedgifsRows'.
static const RFToggleRow kCollapseRows[] = {
    {kRedditFilterAutoCollapseAutoMod, @"AutoMod", @"Auto collapse AutoMod comments", @"rpl3/mod,icon_mod", NO},
};
static const NSInteger kCollapseRowCount = sizeof(kCollapseRows) / sizeof(kCollapseRows[0]);

// The Swipe to collapse page. Their switch tags follow kDiagnosticsRow's.
static const RFToggleRow kSwipeRows[] = {
    {kRedditFilterSwipeToCollapse, @"Swipe to collapse",
     @"Swipe a comment to collapse it, or swipe further to collapse the whole thread",
     @"rpl3/swipeLeft,rpl3/comment,icon_comment", NO},
    {kRedditFilterSwipeRightToCollapse, @"Swipe right too",
     @"Swipe right to collapse as well. Swiping from the screen edge still goes back",
     @"rpl3/swipeRight,rpl3/comment,icon_comment", NO, kRedditFilterSwipeToCollapse},
    {kRedditFilterSwipeRightOnly, @"Swipe right only", @"Swiping left only moves to the next post",
     @"rpl3/swipeRight,rpl3/comment,icon_comment", NO, kRedditFilterSwipeRightToCollapse},
    {kRedditFilterSwipeCollapseHaptics, @"Swipe haptics",
     @"Vibrate when your swipe reaches Collapse or Collapse thread", @"rpl3/swipeLeft,rpl3/comment,icon_comment", NO,
     kRedditFilterSwipeToCollapse},
    {kRedditFilterTapToCollapse, @"Tap to collapse too",
     @"Tap a comment to collapse it, or long press to collapse the whole thread", @"rpl3/comment,icon_comment", NO,
     kRedditFilterSwipeToCollapse},
};
static const NSInteger kSwipeRowCount = sizeof(kSwipeRows) / sizeof(kSwipeRows[0]);

// In the About section, between the RedditFilter and developer rows. Its switch tag follows kKeywordRows'.
// Tapping the row checks now; the switch is for the daily check.
static const RFToggleRow kUpdateRow = {kRedditFilterCheckUpdates, @"Check for updates",
                                       @"Tap to check now, or switch on to be told when one is out",
                                       @"rpl3/download,rpl3/notifications", NO};
// Set on the settings screen while its update check runs, so a reopened screen starts fresh.
static char kRFCheckingForUpdateKey;
static BOOL RFCheckingForUpdate(id settings) {
  return [objc_getAssociatedObject(settings, &kRFCheckingForUpdateKey) boolValue];
}
static void RFSetCheckingForUpdate(id settings, BOOL checking) {
  objc_setAssociatedObject(settings, &kRFCheckingForUpdateKey, checking ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static const NSInteger kKeywordRowTag = kToggleRowCount;
static const NSInteger kUpdateRowTag = kKeywordRowTag + kKeywordRowCount;
static const NSInteger kRedgifsRowTag = kUpdateRowTag + 1;
static const NSInteger kCollapseRowTag = kRedgifsRowTag + kRedgifsRowCount;
// Its position: row 1 of the About section. The other About rows are kAboutRows.
static const NSInteger kAboutUpdateRow = 1;

// First row of the Debug section, at the very end. The schema paths show below it while it's on.
static const RFToggleRow kDiagnosticsRow = {kRedditFilterDiagnostics, @"Diagnostics",
                                            @"Show whether RedditFilter still finds the posts and ads in "
                                            @"Reddit's responses",
                                            @"rpl3/bug,icon_bug", NO};
static const NSInteger kDiagnosticsRowTag = kCollapseRowTag + kCollapseRowCount;
static const NSInteger kSwipeRowTag = kDiagnosticsRowTag + 1;

static const RFToggleRow *RFToggleRowForKey(NSString *key) {
  for (NSInteger i = 0; i < kToggleRowCount; i++)
    if ([kToggleRows[i].key isEqualToString:key]) return &kToggleRows[i];
  for (NSInteger i = 0; i < kKeywordRowCount; i++)
    if ([kKeywordRows[i].key isEqualToString:key]) return &kKeywordRows[i];
  for (NSInteger i = 0; i < kRedgifsRowCount; i++)
    if ([kRedgifsRows[i].key isEqualToString:key]) return &kRedgifsRows[i];
  for (NSInteger i = 0; i < kCollapseRowCount; i++)
    if ([kCollapseRows[i].key isEqualToString:key]) return &kCollapseRows[i];
  for (NSInteger i = 0; i < kSwipeRowCount; i++)
    if ([kSwipeRows[i].key isEqualToString:key]) return &kSwipeRows[i];
  if ([kDiagnosticsRow.key isEqualToString:key]) return &kDiagnosticsRow;
  return [kUpdateRow.key isEqualToString:key] ? &kUpdateRow : NULL;
}

static const RFToggleRow *RFToggleRowForTag(NSInteger tag) {
  if (tag >= 0 && tag < kToggleRowCount) return &kToggleRows[tag];
  NSInteger keywordRow = tag - kKeywordRowTag;
  if (keywordRow >= 0 && keywordRow < kKeywordRowCount) return &kKeywordRows[keywordRow];
  NSInteger redgifsRow = tag - kRedgifsRowTag;
  if (redgifsRow >= 0 && redgifsRow < kRedgifsRowCount) return &kRedgifsRows[redgifsRow];
  NSInteger collapseRow = tag - kCollapseRowTag;
  if (collapseRow >= 0 && collapseRow < kCollapseRowCount) return &kCollapseRows[collapseRow];
  NSInteger swipeRow = tag - kSwipeRowTag;
  if (swipeRow >= 0 && swipeRow < kSwipeRowCount) return &kSwipeRows[swipeRow];
  if (tag == kUpdateRowTag) return &kUpdateRow;
  if (tag == kDiagnosticsRowTag) return &kDiagnosticsRow;
  return NULL;
}

// Use our own layout: Reddit's legacy toggle cells no longer match its SwiftUI Settings.
// Modern Settings uses RPL tokens; the old body/meta colours belong to Reddit's legacy UI.
// Resolve through each view's RUI so light/dark and Reddit's selected theme stay in sync.
static id RFObjectProperty(id object, NSString *name) {
  SEL selector = NSSelectorFromString(name);
  NSMethodSignature *signature = [object methodSignatureForSelector:selector];
  if (signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@') return nil;
  return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static UIColor *RFPaletteColor(UIView *view, NSString *token) {
  id object = view;
  for (NSString *key in @[@"rui", @"color", @"rpl", @"neutral", token]) {
    object = RFObjectProperty(object, key);
    if (!object) return nil;
  }
  return [object isKindOfClass:UIColor.class] ? object : nil;
}

static void RFApplyTheme(UIView *view, SEL setter, SEL themeGetter) {
  NSString *token = themeGetter == @selector(bodyTextColor) ? @"contentStrong"
                   : themeGetter == @selector(metaTextColor) ? @"contentWeak" : @"background";
  UIColor *fallback = RFPaletteColor(view, token);
  if (!fallback) {
    if ([view respondsToSelector:@selector(associatePropertySetter:withThemePropertyGetter:)])
      [view associatePropertySetter:setter withThemePropertyGetter:themeGetter];
    return;
  }
  __weak UIView *weakView = view;
  UIColor *color = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
    NSString *resolvedToken = setter == @selector(setOnTintColor:) && traits.userInterfaceStyle == UIUserInterfaceStyleDark
                                ? @"contentWeak" : token;
    return [(RFPaletteColor(weakView, resolvedToken) ?: fallback) resolvedColorWithTraitCollection:traits];
  }];
  ((void (*)(id, SEL, id))objc_msgSend)(view, setter, color);
}

@interface RFSettingsCell : UITableViewCell
@property(nonatomic, strong) UILabel *mainLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) UIImageView *rowIcon;
@property(nonatomic, strong) UISwitch *accessorySwitch;
@property(nonatomic, strong) UIImageView *disclosure;
- (void)showDisclosure:(BOOL)show;
@end

@implementation RFSettingsCell {
  // The text ends before the switch, or before the arrow on rows that show one instead.
  NSLayoutConstraint *_labelsBeforeSwitch;
  NSLayoutConstraint *_labelsBeforeDisclosure;
}
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
  self = [super initWithStyle:style reuseIdentifier:identifier];
  if (!self) return nil;
  self.backgroundColor = UIColor.systemBackgroundColor;
  RFApplyTheme(self, @selector(setBackgroundColor:), @selector(bodyColor));
  _mainLabel = [UILabel new];
  _mainLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  _mainLabel.adjustsFontForContentSizeCategory = YES;
  _mainLabel.numberOfLines = 0;
  _mainLabel.textColor = UIColor.labelColor;
  RFApplyTheme(_mainLabel, @selector(setTextColor:), @selector(bodyTextColor));
  _detailLabel = [UILabel new];
  _detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
  _detailLabel.adjustsFontForContentSizeCategory = YES;
  _detailLabel.numberOfLines = 0;
  _detailLabel.textColor = UIColor.secondaryLabelColor;
  RFApplyTheme(_detailLabel, @selector(setTextColor:), @selector(metaTextColor));
  _rowIcon = [UIImageView new];
  _rowIcon.contentMode = UIViewContentModeCenter;
  _rowIcon.tintColor = UIColor.labelColor;
  RFApplyTheme(_rowIcon, @selector(setTintColor:), @selector(bodyTextColor));
  _accessorySwitch = [UISwitch new];
  RFApplyTheme(_accessorySwitch, @selector(setOnTintColor:), @selector(bodyTextColor));
  _disclosure = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"
      withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold]]];
  _disclosure.contentMode = UIViewContentModeCenter;
  _disclosure.tintColor = UIColor.secondaryLabelColor;
  RFApplyTheme(_disclosure, @selector(setTintColor:), @selector(metaTextColor));
  _disclosure.hidden = YES;
  UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[_mainLabel, _detailLabel]];
  labels.axis = UILayoutConstraintAxisVertical;
  labels.spacing = 0;
  for (UIView *view in @[_rowIcon, labels, _accessorySwitch, _disclosure]) {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:view];
  }
  _labelsBeforeSwitch = [labels.trailingAnchor constraintEqualToAnchor:_accessorySwitch.leadingAnchor constant:-12];
  _labelsBeforeDisclosure = [labels.trailingAnchor constraintEqualToAnchor:_disclosure.leadingAnchor constant:-12];
  // Native Settings: 20pt edge inset, 24pt icon, text at 56pt, 63pt two-line rows.
  [NSLayoutConstraint activateConstraints:@[
    [_rowIcon.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],
    [_rowIcon.widthAnchor constraintEqualToConstant:24],
    [_rowIcon.heightAnchor constraintEqualToConstant:24],
    [_rowIcon.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
    [labels.leadingAnchor constraintEqualToAnchor:_rowIcon.trailingAnchor constant:12],
    _labelsBeforeSwitch,
    [labels.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
    [labels.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:10],
    [labels.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-10],
    [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:63],
    [_accessorySwitch.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
    [_accessorySwitch.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
    [_disclosure.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],
    [_disclosure.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
  ]];
  // The switch and the arrow keep their own size, so the text takes up the rest of the row.
  for (UIView *view in @[_accessorySwitch, _disclosure]) {
    [view setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [view setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  }
  self.selectionStyle = UITableViewCellSelectionStyleNone;
  return self;
}
- (void)showDisclosure:(BOOL)show {
  self.accessorySwitch.hidden = show;
  self.disclosure.hidden = !show;
  // Deactivate first so the two never conflict.
  (show ? _labelsBeforeSwitch : _labelsBeforeDisclosure).active = NO;
  (show ? _labelsBeforeDisclosure : _labelsBeforeSwitch).active = YES;
  self.selectionStyle = show ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
}
@end

static UILabel *RFMainLabel(RFSettingsCell *cell) { return cell.mainLabel; }
static UILabel *RFDetailLabel(RFSettingsCell *cell) { return cell.detailLabel; }
static UISwitch *RFSwitch(RFSettingsCell *cell) { return cell.accessorySwitch; }

// Switchable only while the setting it requires is on, and that one is switchable too.
static BOOL RFRowEnabled(const RFToggleRow *row) {
  while (row && row->requires) {
    if (![NSUserDefaults.standardUserDefaults boolForKey:row->requires]) return NO;
    row = RFToggleRowForKey(row->requires);
    if (!row) return NO;
  }
  return YES;
}

static void RFSetToggleCellEnabled(RFSettingsCell *cell, const RFToggleRow *row) {
  BOOL enabled = RFRowEnabled(row);
  cell.contentView.alpha = enabled ? 1.0 : 0.4;
  cell.userInteractionEnabled = enabled;
}

// Reddit has no Wi-Fi icon, so draw one on its 20pt grid, with the same line weight and round ends.
static UIImage *RFWiFiIcon(void) {
  UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(20, 20)];
  return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
    CGPoint centre = CGPointMake(10, 15.8);
    for (NSNumber *radius in @[ @4.25, @8, @11.75 ]) {
      UIBezierPath *arc = [UIBezierPath bezierPathWithArcCenter:centre
                                                         radius:radius.doubleValue
                                                     startAngle:-M_PI * 7 / 9
                                                       endAngle:-M_PI * 2 / 9
                                                      clockwise:YES];
      arc.lineWidth = 1.8;
      arc.lineCapStyle = kCGLineCapRound;
      [arc stroke];
    }
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(centre.x - 1.5, centre.y - 1.5, 3, 3)] fill];
  }];
}

// The first of Reddit's icons that's found, else the SF Symbol, drawn in a 20pt square and tinted
// like Reddit's own settings icons. "rf/wifi" is RedditFilter's own.
static UIImage *RFIcon(NSString *iconNames, NSString *fallbackSymbol) {
  UIImage *icon = nil;
  for (NSString *name in [iconNames componentsSeparatedByString:@","])
    if ((icon = [name isEqualToString:@"rf/wifi"] ? RFWiFiIcon() : iconWithName(name))) break;
  if (!icon && fallbackSymbol) icon = [UIImage systemImageNamed:fallbackSymbol];
  if (!icon || icon.size.width <= 0 || icon.size.height <= 0) return nil;
  CGFloat side = 20.0;
  CGFloat scale = MIN(side / icon.size.width, side / icon.size.height);
  CGSize size = CGSizeMake(icon.size.width * scale, icon.size.height * scale);
  UIImage *template = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
  UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
  UIImage *boxed = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
    [template drawInRect:CGRectMake((side - size.width) / 2, (side - size.height) / 2, size.width, size.height)];
  }];
  // Drawing loses the template flag, so set it again: the cell tints it like its other icons.
  return [boxed imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static void RFSetIcon(RFSettingsCell *cell, NSString *iconNames, NSString *fallbackSymbol) {
  cell.rowIcon.image = RFIcon(iconNames, fallbackSymbol);
}

static UIFont *RFSectionFont(BOOL header) {
  return header ? [UIFontMetrics.defaultMetrics scaledFontForFont:[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]]
                : [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
}

// At least `minimum`, and tall enough for the text at the current text size.
static CGFloat RFSectionHeight(UITableView *tableView, NSString *text, BOOL header, CGFloat minimum) {
  if (!text.length) return minimum;
  CGFloat width = MAX(tableView.bounds.size.width - 40.0, 100.0);
  CGRect bounds = [text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
                                     options:NSStringDrawingUsesLineFragmentOrigin
                                  attributes:@{NSFontAttributeName : RFSectionFont(header)}
                                     context:nil];
  return MAX(minimum, ceil(bounds.size.height) + (header ? 10.0 : 20.0));
}

// Section header/footer: a themed label inset like Reddit's own settings.
static UIView *RFSectionView(UITableView *tableView, NSString *text, CGFloat height, BOOL header) {
  if (!text) return nil;

  CGFloat padding = 20.0;
  CGFloat width = tableView.bounds.size.width;
  UILabel *label = [UILabel new];
  label.font = RFSectionFont(header);
  label.adjustsFontForContentSizeCategory = YES;
  label.frame = CGRectMake(padding, 0, MAX(width - padding * 2, 0), height);
  label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  label.numberOfLines = 0;
  label.text = text;
  label.textColor = UIColor.secondaryLabelColor;
  RFApplyTheme(label, @selector(setTextColor:), @selector(metaTextColor));
  UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, height)];
  [container addSubview:label];
  return container;
}

#pragma mark - Sections

typedef NS_ENUM(NSInteger, RFSection) {
  RFSectionStats,
  RFSectionFilters,
  RFSectionCollapse,
  RFSectionSwipe,
  RFSectionRedgifs,
  RFSectionKeywords,
  RFSectionSafari,
  RFSectionAbout,
  RFSectionDebug,
};

// The IPA includes the Safari extension unless it was built without it.
static BOOL RFHasSafariExtension(void) {
  static BOOL hasExtension;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSURL *url = [NSBundle.mainBundle.builtInPlugInsURL URLByAppendingPathComponent:@"RedditFilterSafari.appex"];
    hasExtension = url && [NSFileManager.defaultManager fileExistsAtPath:url.path];
  });
  return hasExtension;
}

// The same screen class shows the Swipe to collapse page, with only that section.
static char kRFSwipePageKey;
static BOOL RFIsSwipePage(id settings) {
  return [objc_getAssociatedObject(settings, &kRFSwipePageKey) boolValue];
}

// Stats, Filters, Collapsing, RedGIFs, Keywords, [Safari (with the extension)], About, Debug
static NSArray<NSNumber *> *RFSections(id settings) {
  if (RFIsSwipePage(settings)) return @[ @(RFSectionSwipe) ];
  static NSArray *sections;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableArray *list = [@[ @(RFSectionStats), @(RFSectionFilters), @(RFSectionCollapse), @(RFSectionRedgifs), @(RFSectionKeywords) ] mutableCopy];
    if (RFHasSafariExtension()) [list addObject:@(RFSectionSafari)];
    [list addObject:@(RFSectionAbout)];
    [list addObject:@(RFSectionDebug)];
    sections = list;
  });
  return sections;
}

static RFSection RFSectionAt(id settings, NSInteger section) {
  NSArray<NSNumber *> *sections = RFSections(settings);
  return section >= 0 && section < (NSInteger)sections.count ? sections[section].integerValue : RFSectionAbout;
}

static NSString *RFHeaderText(id settings, NSInteger section) {
  switch (RFSectionAt(settings, section)) {
    case RFSectionStats: return @"STATS";
    case RFSectionFilters: return @"TWEAKS";
    case RFSectionCollapse: return @"COLLAPSING COMMENTS";
    case RFSectionSwipe: return nil;
    case RFSectionRedgifs: return @"REDGIFS";
    case RFSectionKeywords: return @"KEYWORDS";
    case RFSectionSafari: return @"SAFARI";
    case RFSectionDebug: return @"DEBUG";
    case RFSectionAbout: return @"ABOUT";
  }
  return nil;
}

static NSString *RFFooterText(id settings, NSInteger section) {
  switch (RFSectionAt(settings, section)) {
    case RFSectionStats: return nil;
    case RFSectionFilters: return @"Filter posts and adjust how Reddit looks";
    case RFSectionCollapse:
      return @"With swipe to collapse off, tapping a comment collapses it as usual. "
             @"A collapsed comment always opens with a tap.";
    case RFSectionSwipe:
      return @"Swiping a collapsed comment or the post itself still moves between posts or goes back.";
    case RFSectionRedgifs:
      return @"Plays RedGIFs' own videos, which have sound. Your device connects to RedGIFs directly. "
             @"If RedGIFs can't be reached, Reddit's silent version plays. "
             @"If a video has no SD version, HD plays. Videos already loaded keep their quality "
             @"when your network changes.";
    case RFSectionKeywords: return nil;
    case RFSectionSafari:
      return @"Safari asks before each link opens here. Cancel twice to stay on the web in that tab";
    case RFSectionDebug:
      if (!RFDiagnosticsEnabled())
        return @"Turn on if posts or ads come back, then use Reddit for a minute and copy what's shown here "
               @"into your bug report.";
      return @"✓ found · ✗ not found where expected (RedditFilter searches the whole response instead). "
             @"Tap Copy on a ✗ row for the new location, or Copy JSON for the response, which can include "
             @"usernames and post text. Nothing leaves your device unless you copy it, and it's cleared when "
             @"Reddit closes or you turn this off.";
    case RFSectionAbout: return @"Based on original work from level3tjg and NicholasBly";
  }
  return nil;
}

// The switch tag of the row at this position, or -1 for rows without a switch.
static NSInteger RFToggleTagAt(id settings, NSIndexPath *indexPath) {
  switch (RFSectionAt(settings, indexPath.section)) {
    case RFSectionFilters: return indexPath.row;
    case RFSectionCollapse: return indexPath.row > 0 ? kCollapseRowTag + indexPath.row - 1 : -1;
    case RFSectionSwipe: return kSwipeRowTag + indexPath.row;
    case RFSectionRedgifs: return kRedgifsRowTag + indexPath.row;
    case RFSectionKeywords: return indexPath.row > 0 ? kKeywordRowTag + indexPath.row - 1 : -1;
    case RFSectionAbout: return indexPath.row == kAboutUpdateRow ? kUpdateRowTag : -1;
    case RFSectionDebug: return indexPath.row == 0 ? kDiagnosticsRowTag : -1;
    case RFSectionStats:
    case RFSectionSafari: return -1;
  }
  return -1;
}

#pragma mark - About section

typedef struct {
  __unsafe_unretained NSString *title;
  __unsafe_unretained NSString *subtitle; // nil = show the version
  __unsafe_unretained NSString *link;     // opened when the row is tapped
  __unsafe_unretained NSString *icons;    // Reddit icons, as in RFToggleRow
  __unsafe_unretained NSString *symbol;   // SF Symbol if none of them is found
} RFAboutRow;

static const RFAboutRow kAboutRows[] = {
    {@"RedditFilter", nil, @"https://github.com/and101/RedditFilter/releases", @"rpl3/filter",
     @"line.3.horizontal.decrease.circle"},
    {@"and101", @"Developer", @"https://github.com/and101", @"rpl3/user,rpl3/profile", @"person.crop.circle"},
};
static const NSInteger kAboutRowCount = sizeof(kAboutRows) / sizeof(kAboutRows[0]);

static NSInteger RFAboutLinkIndex(NSInteger row) {
  return row < kAboutUpdateRow ? row : row == kAboutUpdateRow ? -1 : row - 1;
}

static NSString *RFVersionText(void) {
  NSString *text = [@"Version " @RF_VERSION stringByAppendingString:REDDITFILTER_DEBUG ? @" (debug build)" : @""];
  NSString *update = RFAvailableUpdate();
  return update ? [text stringByAppendingFormat:@" \u00b7 Update available: %@", update] : text;
}

static NSString *const kLinkCellID = @"RFLinkCellID";

// A row that opens something when tapped. It's the same cell as the switch rows, with the switch
// swapped for a disclosure arrow, so the icons and text line up with them.
static UITableViewCell *RFLinkCell(UITableView *tableView, NSString *title, NSString *subtitle, NSString *icons,
                                   NSString *symbol) {
  RFSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:kLinkCellID];
  cell.accessibilityLabel = title;
  RFMainLabel(cell).text = title;
  RFDetailLabel(cell).text = subtitle;
  RFSetIcon(cell, icons, symbol);
  [cell showDisclosure:YES];
  return cell;
}

static UITableViewCell *RFAboutCell(UITableView *tableView, NSInteger index) {
  if (index < 0 || index >= kAboutRowCount) return RFLinkCell(tableView, nil, nil, nil, nil);
  const RFAboutRow *row = &kAboutRows[index];
  return RFLinkCell(tableView, row->title, row->subtitle ?: RFVersionText(), row->icons, row->symbol);
}

static UITableViewCell *RFKeywordsCell(UITableView *tableView) {
  NSUInteger count = RFSavedKeywords().count;
  NSString *subtitle = count == 0   ? @"Hide posts that mention a word or phrase"
                       : count == 1 ? @"1 keyword"
                                    : [NSString stringWithFormat:@"%lu keywords", (unsigned long)count];
  return RFLinkCell(tableView, @"Keywords", subtitle, @"rpl3/search", @"text.magnifyingglass");
}

static UITableViewCell *RFStatsCell(UITableView *tableView) {
  NSDictionary *stats = RFStatsSnapshot();
  NSNumber *total = [stats[kRFStatsCounts] valueForKeyPath:@"@sum.self"];
  NSNumber *today = stats[kRFStatsDays][RFStatsDayKey([NSDate date])] ?: @0;
  NSString *title = total.unsignedLongLongValue == 0
                        ? @"Nothing hidden yet"
                        : [NSString stringWithFormat:@"%@ hidden", RFStatsFormattedCount(total.unsignedLongLongValue)];
  NSString *subtitle = [NSString stringWithFormat:@"%@ \u00b7 %@ today", RFStatsSinceText(stats[kRFStatsSince]),
                                                  RFStatsFormattedCount(today.unsignedLongLongValue)];
  UITableViewCell *cell = RFLinkCell(tableView, title, subtitle, @"rpl3/statistics,rpl3/chart", @"chart.bar");
  cell.accessibilityHint = @"Shows what each filter has hidden";
  return cell;
}

// Opens the Swipe to collapse page, and says what that page is set to.
static UITableViewCell *RFSwipeCell(UITableView *tableView) {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  NSString *subtitle = @"Off";
  if ([defaults boolForKey:kRedditFilterSwipeToCollapse]) {
    BOOL right = [defaults boolForKey:kRedditFilterSwipeRightToCollapse];
    subtitle = !right                                          ? @"On, swiping left"
               : [defaults boolForKey:kRedditFilterSwipeRightOnly] ? @"On, swiping right"
                                                                   : @"On, swiping left or right";
  }
  return RFLinkCell(tableView, @"Swipe to collapse", subtitle, @"rpl3/swipeLeft,rpl3/comment,icon_comment", nil);
}

static UITableViewCell *RFSafariCell(UITableView *tableView) {
  return RFLinkCell(tableView, @"Open Reddit links here", @"Set up the RedditFilter Safari extension",
                    @"rpl3/link,icon_link", @"safari");
}

// How to turn on the extension. The app can't turn it on or check whether it's on.
static void RFShowSafariSetup(UIViewController *controller) {
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"Open Reddit links here"
                       message:@"Reddit links you open in Safari can open in this app instead.\n\n"
                               @"1. Open Settings, then Apps, then Safari, then Extensions.\n"
                               @"2. Tap RedditFilter and turn on Allow Extension.\n"
                               @"3. Under Permissions, set the Reddit websites to Allow.\n\n"
                               @"Safari asks before each link opens. Tap Cancel to stay on the web page, "
                               @"or cancel twice to stay on the web in that tab until it's closed."
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
  [controller presentViewController:alert animated:YES completion:nil];
}

// Declarations for the Debug section's helpers so the call sites below are typed.
// (The implementations are added to the class at runtime by Logos below.)
@interface FeedFilterSettingsViewController (RFSchemaDebug)
- (UITableViewCell *)debugCellForRow:(NSInteger)row inTableView:(UITableView *)tableView;
- (void)rfCopyDiscoveredPath:(UIButton *)sender;
- (void)rfCopyFailedJSON:(UIButton *)sender;
- (void)rfResetCounters:(UIButton *)sender;
@end

%subclass FeedFilterSettingsViewController : BaseTableViewController

- (void)viewDidLoad {
  %orig;
  self.title = RFIsSwipePage(self) ? @"Swipe to collapse" : @"RedditFilter";
  Class toggleCellClass = RFSettingsCell.class;
  [self.tableView registerClass:toggleCellClass forCellReuseIdentifier:kToggleCellID];
  [self.tableView registerClass:toggleCellClass forCellReuseIdentifier:kLinkCellID];
  self.tableView.estimatedRowHeight = 63.0;
  self.tableView.rowHeight = UITableViewAutomaticDimension;
  self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
  self.tableView.sectionHeaderTopPadding = 0;
  // Header and footer heights follow the text size, so recalculate them when it changes.
  if (@available(iOS 17.0, *))
    [self registerForTraitChanges:@[ UITraitPreferredContentSizeCategory.class ]
                      withHandler:^(UIViewController *controller, UITraitCollection *previous) {
                        [((UITableViewController *)controller).tableView reloadData];
                      }];
  self.tableView.backgroundColor = UIColor.systemBackgroundColor;
  RFApplyTheme(self.tableView, @selector(setBackgroundColor:), @selector(bodyColor));
  // Grouped tables otherwise add a separate empty area above the first header.
  self.tableView.tableHeaderView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 0.01)];
}

- (void)viewDidLayoutSubviews {
  %orig;
  // BaseTableViewController adds legacy top spacing. Match the current Settings header inset.
  UINavigationBar *bar = self.navigationController.navigationBar;
  if (!bar || bar.hidden) return;
  CGFloat top = CGRectGetMaxY([bar convertRect:bar.bounds toView:self.view]) + 20.0;
  UIEdgeInsets inset = self.tableView.contentInset;
  if (fabs(inset.top - top) < 0.5) return;
  BOOL atTop = self.tableView.contentOffset.y <= -self.tableView.adjustedContentInset.top + 0.5;
  inset.top = top;
  self.tableView.contentInset = inset;
  if (atTop) self.tableView.contentOffset = CGPointMake(0, -self.tableView.adjustedContentInset.top);
}

- (void)viewWillAppear:(BOOL)animated {
  %orig;
  // Refresh the keyword count after coming back from the Keywords screen
  // (and the stats and schema paths, which add up while the app runs).
  [self.tableView reloadData];
}

%new
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return RFSections(self).count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  switch (RFSectionAt(self, section)) {
    case RFSectionStats:
      return 1;
    case RFSectionFilters:
      return kToggleRowCount;
    case RFSectionCollapse:
      return 1 + kCollapseRowCount; // Swipe to collapse, then the switches
    case RFSectionSwipe:
      return kSwipeRowCount;
    case RFSectionRedgifs:
      return kRedgifsRowCount;
    case RFSectionKeywords:
      return 1 + kKeywordRowCount; // Keywords, then its switches
    case RFSectionSafari:
      return 1;
    case RFSectionDebug:
      // The switch, then while it's on one row per tracked schema path and a "reset" row.
      return 1 + (RFDiagnosticsEnabled() ? [[RFSchemaDebug shared] snapshot].count + 1 : 0);
    case RFSectionAbout:
      return kAboutRowCount + 1; // plus "Check for updates"
  }
  return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  RFSection section = RFSectionAt(self, indexPath.section);
  NSInteger tag = RFToggleTagAt(self, indexPath);
  if (section == RFSectionAbout && tag < 0) return RFAboutCell(tableView, RFAboutLinkIndex(indexPath.row));
  if (section == RFSectionKeywords && indexPath.row == 0) return RFKeywordsCell(tableView);
  if (section == RFSectionCollapse && indexPath.row == 0) return RFSwipeCell(tableView);
  if (section == RFSectionSafari) return RFSafariCell(tableView);
  if (section == RFSectionStats) return RFStatsCell(tableView);
  if (section == RFSectionDebug && tag < 0) return [self debugCellForRow:indexPath.row - 1 inTableView:tableView];
  RFSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:kToggleCellID
                                                                   forIndexPath:indexPath];
  const RFToggleRow *row = RFToggleRowForTag(tag);
  if (!row) return cell;

  cell.accessibilityLabel = row->title;
  RFMainLabel(cell).text = row->title;
  RFDetailLabel(cell).text = row->subtitle;
  RFSetIcon(cell, row->icons, tag == kDiagnosticsRowTag ? @"ladybug" : nil);
  RFSetToggleCellEnabled(cell, row);
  BOOL updateRow = tag == kUpdateRowTag;
  if (updateRow && RFCheckingForUpdate(self)) RFDetailLabel(cell).text = @"Checking\u2026";
  cell.selectionStyle = updateRow ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
  cell.accessibilityHint = updateRow ? @"Checks for an update now" : nil;

  UISwitch *toggle = RFSwitch(cell);
  BOOL saved = [NSUserDefaults.standardUserDefaults boolForKey:row->key];
  toggle.on = row->switchOnMeansShow ? !saved : saved;
  toggle.tag = tag;
  toggle.accessibilityLabel = row->title;
  toggle.accessibilityHint = row->subtitle;
  // Only remove our own action (cells get reused), never Reddit's.
  [toggle removeTarget:self action:NULL forControlEvents:UIControlEventAllEvents];
  [toggle addTarget:self action:@selector(rfToggleChanged:) forControlEvents:UIControlEventValueChanged];

  return cell;
}

%new
- (void)rfToggleChanged:(UISwitch *)sender {
  const RFToggleRow *row = RFToggleRowForTag(sender.tag);
  if (!row) return;
  BOOL filterOn = row->switchOnMeansShow ? !sender.on : sender.on;
  [NSUserDefaults.standardUserDefaults setBool:filterOn forKey:row->key];
  RFReloadPreferences();

  // Some accounts are in a Reddit experiment that loads Home ads where the filter can't see them.
  // It's removed at launch, but the running app has already read it.
  if (filterOn && [row->key isEqualToString:kRedditFilterPromoted] && RFCleanCachedExperiments()) {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Restart Reddit"
                                            message:@"To finish applying Home-feed ad blocking, fully close Reddit "
                                                    @"and reopen it."
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
  }

  // Show or hide the schema paths below the Diagnostics switch.
  // (A plain reload: an animated section reload lays the new footer out too wide.)
  if (sender.tag == kDiagnosticsRowTag) {
    [self.tableView reloadData];
    return;
  }

  // Refresh every dependent row, as a chain (Prefer SD, then on mobile data) can change further down.
  for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
    const RFToggleRow *other = RFToggleRowForTag(RFToggleTagAt(self, indexPath));
    if (other && other->requires)
      RFSetToggleCellEnabled((RFSettingsCell *)[self.tableView cellForRowAtIndexPath:indexPath], other);
  }
}

%new
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (RFSectionAt(self, indexPath.section) == RFSectionKeywords && indexPath.row == 0) {
    [self.navigationController pushViewController:[RFKeywordsViewController new] animated:YES];
    return;
  }
  if (RFSectionAt(self, indexPath.section) == RFSectionCollapse && indexPath.row == 0) {
    UIViewController *page = [(FeedFilterSettingsViewController *)[self.class alloc] initWithStyle:UITableViewStyleGrouped];
    objc_setAssociatedObject(page, &kRFSwipePageKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self.navigationController pushViewController:page animated:YES];
    return;
  }
  if (RFSectionAt(self, indexPath.section) == RFSectionSafari) {
    RFShowSafariSetup(self);
    return;
  }
  if (RFSectionAt(self, indexPath.section) == RFSectionStats) {
    [self.navigationController pushViewController:[RFStatsViewController new] animated:YES];
    return;
  }
  if (RFSectionAt(self, indexPath.section) != RFSectionAbout) return;
  if (indexPath.row == kAboutUpdateRow) {
    if (RFCheckingForUpdate(self)) return;
    RFSetCheckingForUpdate(self, YES);
    NSInteger section = indexPath.section;
    [tableView reloadRowsAtIndexPaths:@[ indexPath ] withRowAnimation:UITableViewRowAnimationNone];
    __weak UITableView *weakTable = tableView;
    __weak id weakSelf = self;
    RFCheckForUpdateNow(self, ^{
      if (weakSelf) RFSetCheckingForUpdate(weakSelf, NO);
      // The RedditFilter row shows an update when there is one.
      UITableView *table = weakTable;
      if (table && section < table.numberOfSections) [table reloadSections:[NSIndexSet indexSetWithIndex:section]
                                                           withRowAnimation:UITableViewRowAnimationNone];
    });
    return;
  }
  NSInteger link = RFAboutLinkIndex(indexPath.row);
  if (link < 0 || link >= kAboutRowCount) return;
  // The RedditFilter row opens the new version's page when there's an update.
  NSURL *url = link == 0 ? RFUpdateURL() : [NSURL URLWithString:kAboutRows[link].link];
  if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

%new
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
  return RFSectionView(tableView, RFHeaderText(self, section), [self tableView:tableView heightForHeaderInSection:section], YES);
}

%new
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
  return RFSectionHeight(tableView, RFHeaderText(self, section), YES, 26.0);
}

%new
- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
  return RFSectionView(tableView, RFFooterText(self, section), [self tableView:tableView heightForFooterInSection:section], NO);
}

%new
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
  RFSection kind = RFSectionAt(self, section);
  CGFloat minimum = kind == RFSectionDebug ? 76.0 : kind == RFSectionStats ? 20.0 : 48.0;
  return RFSectionHeight(tableView, RFFooterText(self, section), NO, minimum);
}

// ---------------------------------------------------------------------------
// Schema-path debug section.
//
// Shown below the Diagnostics switch while it's on. `row` counts from the first
// schema path (the switch is row 0 of the section).
// ---------------------------------------------------------------------------
%new
- (UITableViewCell *)debugCellForRow:(NSInteger)row inTableView:(UITableView *)tableView {
  static NSString *const kRFDebugCellID = @"RFSchemaDebugCell";
  
  // Deliberately a plain UIKit cell, not a Reddit class: the whole point of
  // this screen is to keep working when Reddit's own classes/schema change.
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kRFDebugCellID];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                  reuseIdentifier:kRFDebugCellID];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:11.0
                                                            weight:UIFontWeightRegular];
    cell.textLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
  }
  cell.accessoryView = nil;
  cell.selectionStyle = UITableViewCellSelectionStyleNone;

  NSArray<NSDictionary *> *snapshot = [[RFSchemaDebug shared] snapshot];
  
  // Trailing "reset" row.
  if (row >= (NSInteger)snapshot.count) {
    cell.textLabel.textColor = [UIColor systemBlueColor];
    cell.textLabel.text = @"Reset counters";
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.text = @"Clear all stats and re-arm path discovery";
    UIButton *resetButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [resetButton setTitle:@"Reset" forState:UIControlStateNormal];
    resetButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    [resetButton addTarget:self
                    action:@selector(rfResetCounters:)
          forControlEvents:UIControlEventTouchUpInside];
    [resetButton sizeToFit];
    cell.accessoryView = resetButton;
    return cell;
  }

  NSDictionary *record = snapshot[row];
  NSArray<NSString *> *unfiltered = record[kRFDebugUnfiltered];
  if (unfiltered) {
    cell.textLabel.textColor = [UIColor labelColor];
    cell.textLabel.text = record[kRFDebugOp];
    if (unfiltered.count == 0) {
      cell.detailTextLabel.text = @"\u2713 none seen";
      cell.detailTextLabel.textColor = [UIColor systemGreenColor];
    } else {
      NSInteger total = [record[kRFDebugMisses] integerValue];
      cell.detailTextLabel.text = [NSString
          stringWithFormat:@"\u2717 %ld GraphQL request%@ not filtered (add the address to RFIsAPIHost)\n%@", (long)total,
                           total == 1 ? @"" : @"s", [unfiltered componentsJoinedByString:@"\n"]];
      cell.detailTextLabel.textColor = [UIColor systemRedColor];
    }
    return cell;
  }
  NSString *op = record[kRFDebugOp];
  NSString *expected = record[kRFDebugExpected];
  NSString *discovered = record[kRFDebugDiscovered];
  NSInteger hits = [record[kRFDebugHits] integerValue];
  NSInteger misses = [record[kRFDebugMisses] integerValue];
  BOOL seen = [record[kRFDebugSeen] boolValue];
  BOOL lastResolved = [record[kRFDebugLastResolved] boolValue];

  cell.textLabel.textColor = [UIColor labelColor];
  cell.textLabel.text = op;

  NSString *detail;
  UIColor *detailColor;
  if (!seen) {
    detail = [NSString stringWithFormat:@"untested\nexpected: %@", expected];
    detailColor = [UIColor secondaryLabelColor];
  } else if (lastResolved) {
    detail = [NSString stringWithFormat:@"\u2713 OK \u00b7 %ld hit%@",
                                        (long)hits, hits == 1 ? @"" : @"s"];
    if (misses > 0)
      detail = [detail stringByAppendingFormat:@"  (recovered after %ld miss%@)",
                                               (long)misses, misses == 1 ? @"" : @"es"];
    detailColor = [UIColor systemGreenColor];
  } else {
    detail = [NSString stringWithFormat:@"\u2717 MISS \u00b7 %ld miss%@ \u00b7 fallback active",
                                        (long)misses, misses == 1 ? @"" : @"es"];
    if (discovered.length) {
      detail = [detail stringByAppendingFormat:@"\n\u2192 %@", discovered];
      UIButton *copyButton = [UIButton buttonWithType:UIButtonTypeSystem];
      [copyButton setTitle:@"Copy" forState:UIControlStateNormal];
      copyButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
      copyButton.tag = row;
      [copyButton addTarget:self
                     action:@selector(rfCopyDiscoveredPath:)
           forControlEvents:UIControlEventTouchUpInside];
      [copyButton sizeToFit];
      cell.accessoryView = copyButton;
    } else {
      detail = [detail stringByAppendingFormat:@"\ncould not auto-locate a new path\nexpected: %@",
                                               expected];
                                               
      // Show the "Copy JSON" button if we captured a payload
      NSString *failedJSON = record[kRFDebugFailedJSON];
      if (failedJSON.length > 0) {
          detail = [detail stringByAppendingString:@"\n\u2192 raw payload captured"];
          UIButton *copyJsonButton = [UIButton buttonWithType:UIButtonTypeSystem];
          [copyJsonButton setTitle:@"Copy JSON" forState:UIControlStateNormal];
          copyJsonButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
          copyJsonButton.tag = row;
          [copyJsonButton addTarget:self
                             action:@selector(rfCopyFailedJSON:)
                   forControlEvents:UIControlEventTouchUpInside];
          [copyJsonButton sizeToFit];
          cell.accessoryView = copyJsonButton;
      }
    }
    detailColor = [UIColor systemRedColor];
  }
  cell.detailTextLabel.text = detail;
  cell.detailTextLabel.textColor = detailColor;
  return cell;
}
%new
- (void)rfCopyDiscoveredPath:(UIButton *)sender {
  NSArray<NSDictionary *> *snapshot = [[RFSchemaDebug shared] snapshot];
  if (sender.tag < 0 || sender.tag >= (NSInteger)snapshot.count) return;
  NSString *discovered = snapshot[sender.tag][kRFDebugDiscovered];
  if (!discovered.length) return;
  UIPasteboard.generalPasteboard.string = discovered;
  [sender setTitle:@"Copied" forState:UIControlStateNormal];
  [sender sizeToFit];
  __weak UIButton *weakSender = sender;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   [weakSender setTitle:@"Copy" forState:UIControlStateNormal];
                   [weakSender sizeToFit];
                 });
}
%new
- (void)rfCopyFailedJSON:(UIButton *)sender {
  NSArray<NSDictionary *> *snapshot = [[RFSchemaDebug shared] snapshot];
  if (sender.tag < 0 || sender.tag >= (NSInteger)snapshot.count) return;
  
  NSString *failedJSON = snapshot[sender.tag][kRFDebugFailedJSON];
  if (!failedJSON.length) return;
  
  UIPasteboard.generalPasteboard.string = failedJSON;
  [sender setTitle:@"Copied" forState:UIControlStateNormal];
  [sender sizeToFit];
  
  __weak UIButton *weakSender = sender;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   [weakSender setTitle:@"Copy JSON" forState:UIControlStateNormal];
                   [weakSender sizeToFit];
                 });
}
%new
- (void)rfResetCounters:(UIButton *)sender {
  [[RFSchemaDebug shared] reset];
  [self.tableView reloadData];
}
%end
