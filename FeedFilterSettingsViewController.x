#import <objc/message.h>
#import <objc/runtime.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "FeedFilterSettingsViewController.h"
#import "KeywordsViewController.h"
#import "DebugMenu.h"
#import "RFBackup.h"
#import "RFBackupPicker.h"
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

typedef NS_ENUM(NSInteger, RFToggleTag) {
  RFPromoted, RFRecommended, RFNSFW, RFVideos, RFExtraCards,
  RFAwards, RFScores, RFColoured, RFApollo, RFKeywordComments, RFKeywordReplies,
  RFUpdates, RFDirect, RFSD, RFMobileSD, RFAutoMod, RFDiagnostics,
  RFSwipe, RFLeft, RFRight, RFHaptics, RFTap, RFLinkPanel, RFSafariLinks,
};
static const RFToggleRow kToggleRows[] = {
    {kRedditFilterPromoted, @"Promoted", @"Show ads in feeds and comments", @"rpl3/tag,icon_tag", YES},
    {kRedditFilterRecommended, @"Recommended", @"Show recommendations on post pages", @"rpl3/spam,icon_spam", YES},
    {kRedditFilterNSFW, @"NSFW", @"Show NSFW posts", @"rpl3/nsfw,icon_nsfw_outline,icon_nsfw", YES},
    {kRedditFilterVideosForYou, @"Videos for you", @"Show the video carousel in your feed",
     @"rpl3/video,icon_video,icon_play", YES},
    {kRedditFilterExtraCards, @"Extra cards", @"Show suggestions, promos and surveys",
     @"rpl3/community,rpl3/communities,icon_community", YES},
    {kRedditFilterAwards, @"Awards", @"Show awards on posts and comments",
     @"rpl3/award,icon_gift_fill,icon_award,icon-award-outline", YES},
    {kRedditFilterScores, @"Scores", @"Show votes on posts and comments", @"rpl3/upvote,icon_upvote", YES},
    {kRedditFilterColoredComments, @"Coloured comment threads", @"Give each reply level its own colour",
     @"rpl3/branch,rpl3/comment,icon_comment", NO},
    {kRedditFilterColoredCommentsApollo, @"Apollo style", @"Colour only each comment's own line",
     @"rpl3/branch,rpl3/comment,icon_comment", NO, kRedditFilterColoredComments},
    {kRedditFilterKeywordComments, @"Filter comments too", @"Hide comments with a keyword",
     @"rpl3/comment,icon_comment", NO},
    {kRedditFilterKeywordCommentReplies, @"Hide replies too", @"Also hide the replies below them",
     @"rpl3/reply,icon_reply", NO, kRedditFilterKeywordComments},
    {kRedditFilterCheckUpdates, @"Check for updates",
                                       @"Tap to check. Switch on for daily",
                                       @"rpl3/download,rpl3/notifications", NO},
    {kRedditFilterRedgifsDirect, @"Direct-play RedGIFs", @"Plays with sound, but can use more data",
     @"rpl3/volumeOn,rpl3/play", NO},
    // Saved as "prefer HD", so the switch is the opposite.
    {kRedditFilterRedgifsHD, @"Prefer SD", @"Uses about a tenth of the data of HD",
     @"rpl3/video,icon_video,icon_play", YES, kRedditFilterRedgifsDirect},
    {kRedditFilterRedgifsHDWiFiOnly, @"Prefer SD on mobile data", @"Also in Low Data Mode. HD on Wi-Fi",
     @"rf/wifi", NO, kRedditFilterRedgifsHD},
    {kRedditFilterAutoCollapseAutoMod, @"AutoMod", @"Always collapse AutoMod comments", @"rpl3/mod,icon_mod", NO},
    {kRedditFilterDiagnostics, @"Diagnostics",
                                            @"Check the filters still work",
                                            @"rpl3/bug,icon_bug", NO},
    {kRedditFilterSwipeToCollapse, @"Swipe to collapse",
     @"Swipe further to collapse the whole thread",
     @"rpl3/swipeLeft,rpl3/comment,icon_comment", NO},
    {kRedditFilterSwipeLeftToCollapse, @"Swipe left",
     @"When off, swiping left changes post",
     @"rpl3/swipeLeft,rpl3/comment,icon_comment", NO, kRedditFilterSwipeToCollapse},
    {kRedditFilterSwipeRightToCollapse, @"Swipe right",
     @"Swiping from the edge still goes back",
     @"rpl3/swipeRight,rpl3/comment,icon_comment", NO, kRedditFilterSwipeToCollapse},
    {kRedditFilterSwipeCollapseHaptics, @"Swipe haptics",
     @"Vibrate when a swipe reaches Collapse", @"rpl3/swipeLeft,rpl3/comment,icon_comment", NO,
     kRedditFilterSwipeToCollapse},
    {kRedditFilterTapToCollapse, @"Tap to collapse too",
     @"Long press collapses the whole thread", @"rpl3/comment,icon_comment", NO,
     kRedditFilterSwipeToCollapse},
    {kRedditFilterHideLinkPanel, @"Hide panel on opened links", @"Full page. Votes stay on the post",
     @"rpl3/link,icon_link", NO},
    {kRedditFilterSafariLinks, @"Open article links in Safari", @"Opens an in-app Safari sheet",
     @"rpl3/link,icon_link", NO},
};
static const NSInteger kToggleRowCount = sizeof(kToggleRows) / sizeof(kToggleRows[0]);
static const NSInteger kAboutUpdateRow = 1;
// Set on the settings screen while its update check runs, so a reopened screen starts fresh.
static char kRFCheckingForUpdateKey;
static BOOL RFCheckingForUpdate(id settings) {
  return [objc_getAssociatedObject(settings, &kRFCheckingForUpdateKey) boolValue];
}
static void RFSetCheckingForUpdate(id settings, BOOL checking) {
  objc_setAssociatedObject(settings, &kRFCheckingForUpdateKey, checking ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static const RFToggleRow *RFToggleRowForTag(NSInteger tag) {
  return tag >= 0 && tag < kToggleRowCount ? &kToggleRows[tag] : NULL;
}
static const RFToggleRow *RFToggleRowForKey(NSString *key) {
  for (NSInteger i = 0; i < kToggleRowCount; i++)
    if ([kToggleRows[i].key isEqualToString:key]) return &kToggleRows[i];
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

static void RFApplyThemeToken(UIView *view, SEL setter, SEL themeGetter, NSString *token) {
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

static void RFApplyTheme(UIView *view, SEL setter, SEL themeGetter) {
  NSString *token = themeGetter == @selector(bodyTextColor) ? @"contentStrong"
                   : themeGetter == @selector(metaTextColor) ? @"contentWeak" : @"background";
  RFApplyThemeToken(view, setter, themeGetter, token);
}

void RFApplySettingsTheme(UIView *view, SEL setter, SEL themeGetter) {
  RFApplyTheme(view, setter, themeGetter);
}

// Rounded cards on a page with the settings background, raised enough to still be seen.
void RFApplySettingsCardTheme(UIView *view) {
  RFApplyThemeToken(view, @selector(setBackgroundColor:), @selector(bodyColor), @"backgroundContainer");
}

static NSString *const kRootCellID = @"RFRootCellID"; // the root page's shorter link rows

@interface RFSettingsCell : UITableViewCell
@property(nonatomic, strong) UILabel *mainLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) UIImageView *rowIcon;
@property(nonatomic, strong) UISwitch *accessorySwitch;
@property(nonatomic, strong) UIImageView *disclosure;
@property(nonatomic, copy) NSString *iconKey; // the icon this row wants, as cells get reused
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
  // Root links leave room for About; text can still grow at larger sizes.
  BOOL root = [identifier isEqualToString:kRootCellID];
  CGFloat padding = root ? 7.0 : 10.0;
  [NSLayoutConstraint activateConstraints:@[
    [_rowIcon.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],
    [_rowIcon.widthAnchor constraintEqualToConstant:24],
    [_rowIcon.heightAnchor constraintEqualToConstant:24],
    [_rowIcon.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
    [labels.leadingAnchor constraintEqualToAnchor:_rowIcon.trailingAnchor constant:12],
    _labelsBeforeSwitch,
    [labels.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
    [labels.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:padding],
    [labels.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-padding],
    [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:root ? 54 : 63],
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
  RFSwitch(cell).enabled = enabled;
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

// Finding an icon the first time can be slow, so it never happens on the main thread: the row
// fills in its icon when it's ready. Its space is reserved, so nothing moves.
static void RFSetIcon(RFSettingsCell *cell, NSString *iconNames, NSString *fallbackSymbol) {
  static NSCache<NSString *, UIImage *> *cache;
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [NSCache new];
    queue = dispatch_queue_create("RedditFilter.icons", dispatch_queue_attr_make_with_qos_class(
                                                            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
  });
  NSString *key = [NSString stringWithFormat:@"%@|%@", iconNames, fallbackSymbol];
  UIImage *cached = [cache objectForKey:key];
  cell.iconKey = key;
  cell.rowIcon.image = cached;
  if (cached || (!iconNames && !fallbackSymbol)) return;
  __weak RFSettingsCell *weakCell = cell;
  dispatch_async(queue, ^{
    UIImage *icon = [cache objectForKey:key] ?: RFIcon(iconNames, fallbackSymbol);
    if (!icon) return;
    [cache setObject:icon forKey:key];
    dispatch_async(dispatch_get_main_queue(), ^{
      RFSettingsCell *current = weakCell;
      if ([current.iconKey isEqualToString:key]) current.rowIcon.image = icon;
    });
  });
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
  RFSectionBackup,
  RFSectionAbout,
  RFSectionDebug,
  RFSectionAppearance, RFSectionRootFilters, RFSectionDisplay, RFSectionMore,
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

typedef NS_ENUM(NSInteger, RFPage) {
  RFPageRoot, RFPagePosts, RFPageAppearance, RFPageCollapse, RFPageRedgifs,
  RFPageBackup, RFPageDiagnostics, RFPageAbout,
};
static char kRFPageKey, kRFSnapshotKey;
static RFPage RFCurrentPage(id settings) {
  return [objc_getAssociatedObject(settings, &kRFPageKey) integerValue];
}
static NSString *RFPageTitle(RFPage page) {
  return @[@"RedditFilter", @"Posts and ads", @"Appearance", @"Collapsing comments", @"RedGIFs",
           @"Backup", @"Diagnostics", @"About"][page];
}
static NSArray *RFDebugSnapshot(id settings) {
  return objc_getAssociatedObject(settings, &kRFSnapshotKey) ?: @[];
}
static void RFRefreshSnapshot(id settings) {
  objc_setAssociatedObject(settings, &kRFSnapshotKey,
      RFCurrentPage(settings) == RFPageDiagnostics && RFDiagnosticsEnabled() ? [[RFSchemaDebug shared] snapshot] : nil,
      OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static NSArray<NSNumber *> *RFSections(id settings) {
  switch (RFCurrentPage(settings)) {
    case RFPagePosts: return @[@(RFSectionFilters)];
    case RFPageAppearance: return @[@(RFSectionAppearance)];
    case RFPageCollapse: return @[@(RFSectionSwipe), @(RFSectionCollapse)];
    case RFPageRedgifs: return @[@(RFSectionRedgifs)];
    case RFPageBackup: return @[@(RFSectionBackup)];
    case RFPageDiagnostics: return @[@(RFSectionDebug)];
    case RFPageAbout: return @[@(RFSectionAbout)];
    case RFPageRoot: return @[@(RFSectionStats), @(RFSectionRootFilters), @(RFSectionDisplay), @(RFSectionMore)];
  }
  return @[];
}
// Toggle tags are indexes into the single table, independent of section positions.
static NSArray<NSNumber *> *RFTags(RFSection section) {
  switch (section) {
    case RFSectionFilters: return @[@(RFPromoted), @(RFRecommended), @(RFNSFW), @(RFVideos), @(RFExtraCards)];
    case RFSectionAppearance: return @[@(RFAwards), @(RFScores), @(RFColoured), @(RFApollo), @(RFLinkPanel), @(RFSafariLinks)];
    case RFSectionSwipe: return @[@(RFSwipe), @(RFLeft), @(RFRight), @(RFHaptics), @(RFTap)];
    case RFSectionCollapse: return @[@(RFAutoMod)];
    case RFSectionRedgifs: return @[@(RFDirect), @(RFSD), @(RFMobileSD)];
    default: return @[];
  }
}
static RFPage RFDestination(id settings, NSIndexPath *path) {
  if (RFCurrentPage(settings) != RFPageRoot) return RFPageRoot;
  RFSection section = [RFSections(settings)[path.section] integerValue];
  if (section == RFSectionRootFilters && path.row == 0) return RFPagePosts;
  if (section == RFSectionDisplay) return [@[@(RFPageAppearance), @(RFPageCollapse), @(RFPageRedgifs)][path.row] integerValue];
  if (section == RFSectionMore) {
    NSInteger row = path.row - (RFHasSafariExtension() ? 1 : 0);
    if (row >= 0) return [@[@(RFPageBackup), @(RFPageDiagnostics), @(RFPageAbout)][row] integerValue];
  }
  return RFPageRoot;
}

static RFSection RFSectionAt(id settings, NSInteger section) {
  NSArray<NSNumber *> *sections = RFSections(settings);
  return section >= 0 && section < (NSInteger)sections.count ? sections[section].integerValue : RFSectionAbout;
}

static NSString *RFHeaderText(id settings, NSInteger section) {
  switch (RFSectionAt(settings, section)) {
    case RFSectionRootFilters: return @"FILTERS";
    case RFSectionDisplay: return @"DISPLAY";
    case RFSectionMore: return @"MORE";
    default: return nil;
  }
  return nil;
}

static NSString *RFFooterText(id settings, NSInteger section) {
  switch (RFSectionAt(settings, section)) {
    case RFSectionStats: return nil;
    case RFSectionFilters: return @"Turn a switch off to hide that content";
    case RFSectionCollapse: return nil;
    case RFSectionSwipe:
      return @"Turn on both sides to collapse either way. Swiping a collapsed comment or the post itself still "
             @"changes post or goes back. With swipe to collapse off, a tap collapses comments as usual. "
             @"A tap always reopens a collapsed comment.";
    case RFSectionRedgifs:
      return @"Plays RedGIFs' own videos with sound, connecting your device to RedGIFs directly. If RedGIFs "
             @"can't be reached, Reddit's silent version plays. HD plays when a video has no SD version, and "
             @"videos already loaded keep their quality if your network changes.";
    case RFSectionAppearance:
      return @"In-app Safari uses native Safari content blockers enabled in iOS Settings. "
             @"A Safari web extension alone may not provide this blocking. Tap Done to return to Reddit. "
             @"The separate Open Reddit links here extension handles links coming from Safari. With Open "
             @"article links in Safari on, Hide panel on opened links only matters when an article still "
             @"opens in Reddit's own screen.";
    case RFSectionRootFilters:
    case RFSectionDisplay:
    case RFSectionMore:
      return nil;
    case RFSectionBackup:
      return @"A backup includes your settings, keywords and stats, but no account details.";
    case RFSectionDebug:
      if (!RFDiagnosticsEnabled())
        return @"If posts or ads come back, turn this on, use Reddit for a minute, then add what shows here "
               @"to your bug report.";
      return @"✓ found · ✗ not where expected, so RedditFilter tries the usual places. On a ✗ row, Copy gives "
             @"the new location. Copy JSON gives the response, which can include usernames and post text, and "
             @"Share report never includes it. Nothing leaves your device unless you copy or share it, and "
             @"it's cleared when Reddit closes or you turn this off.";
    case RFSectionAbout: return @"Based on original work from level3tjg and NicholasBly";
  }
  return nil;
}

// The switch tag of the row at this position, or -1 for rows without a switch.
static NSInteger RFToggleTagAt(id settings, NSIndexPath *indexPath) {
  RFSection section = RFSectionAt(settings, indexPath.section);
  if (section == RFSectionAbout) return indexPath.row == kAboutUpdateRow ? RFUpdates : -1;
  if (section == RFSectionDebug) return indexPath.row == 0 ? RFDiagnostics : -1;
  NSArray *tags = RFTags(section);
  return indexPath.row < (NSInteger)tags.count ? [tags[indexPath.row] integerValue] : -1;
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
  RFSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:RFCurrentPage((id)tableView.dataSource) == RFPageRoot ? kRootCellID : kLinkCellID];
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
  UITableViewCell *cell = RFLinkCell(tableView, title, subtitle, nil, @"chart.bar"); // Reddit has no such icon
  cell.accessibilityHint = @"Shows what each filter has hidden";
  return cell;
}

// Opens the Swipe to collapse page, and says what that page is set to.
static UITableViewCell *RFSwipeCell(UITableView *tableView) {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  NSString *subtitle = @"Swipe off"; // AutoMod on this page can still be on
  if ([defaults boolForKey:kRedditFilterSwipeToCollapse]) {
    BOOL right = [defaults boolForKey:kRedditFilterSwipeRightToCollapse];
    subtitle = !right ? @"Swipe left"
               : [defaults boolForKey:kRedditFilterSwipeLeftToCollapse] ? @"Swipe left or right"
                                                                        : @"Swipe right";
  }
  return RFLinkCell(tableView, @"Collapsing comments", subtitle, @"rpl3/swipeLeft,rpl3/comment,icon_comment", nil);
}

static UITableViewCell *RFSafariCell(UITableView *tableView) {
  return RFLinkCell(tableView, @"Open Reddit links here", @"Set up the Safari extension",
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
                               @"Safari asks before opening each link. Cancel once to stay on the page, "
                               @"or twice to stay on the web until you close that tab."
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
  [controller presentViewController:alert animated:YES completion:nil];
}

// Swiping needs a side, so turning off the only one on moves it to the other.
static void RFKeepOneSwipeSide(UITableView *tableView, NSString *changedKey, BOOL on) {
  NSString *other = [changedKey isEqualToString:kRedditFilterSwipeLeftToCollapse]    ? kRedditFilterSwipeRightToCollapse
                    : [changedKey isEqualToString:kRedditFilterSwipeRightToCollapse] ? kRedditFilterSwipeLeftToCollapse
                                                                                     : nil;
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  if (!other || on || [defaults boolForKey:other]) return;
  [defaults setBool:YES forKey:other];
  for (UITableViewCell *cell in tableView.visibleCells)
    if ([cell.accessibilityLabel isEqualToString:RFToggleRowForKey(other)->title])
      [RFSwitch((RFSettingsCell *)cell) setOn:YES animated:YES];
}

static void RFConfigureToggleCell(RFSettingsCell *cell, NSInteger tag, id target) {
  const RFToggleRow *row = RFToggleRowForTag(tag);
  cell.accessibilityLabel = row->title;
  RFMainLabel(cell).text = row->title;
  RFDetailLabel(cell).text = row->subtitle;
  RFSetIcon(cell, row->icons, tag == RFDiagnostics ? @"ladybug" : nil);
  RFSetToggleCellEnabled(cell, row);
  BOOL updateRow = tag == RFUpdates;
  if (updateRow && RFCheckingForUpdate(target)) RFDetailLabel(cell).text = @"Checking\u2026";
  cell.selectionStyle = updateRow ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
  cell.accessibilityHint = updateRow ? @"Checks for an update now" : nil;

  UISwitch *toggle = RFSwitch(cell);
  BOOL saved = [NSUserDefaults.standardUserDefaults boolForKey:row->key];
  toggle.on = row->switchOnMeansShow ? !saved : saved;
  toggle.tag = tag;
  toggle.accessibilityLabel = row->title;
  toggle.accessibilityHint = row->subtitle;
  // Only remove our own action (cells get reused), never Reddit's.
  [toggle removeTarget:target action:NULL forControlEvents:UIControlEventAllEvents];
  [toggle addTarget:target action:@selector(rfToggleChanged:) forControlEvents:UIControlEventValueChanged];

}

UITableViewCell *RFKeywordSettingsCell(UITableView *table, NSInteger index, id target) {
  RFSettingsCell *cell = [table dequeueReusableCellWithIdentifier:@"RFKeywordToggle"];
  if (!cell) cell = [[RFSettingsCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"RFKeywordToggle"];
  RFConfigureToggleCell(cell, index == 0 ? RFKeywordComments : RFKeywordReplies, target);
  return cell;
}
void RFKeywordSettingsChanged(UISwitch *sender, UITableView *table) {
  const RFToggleRow *row = RFToggleRowForTag(sender.tag);
  if (!row || (sender.tag != RFKeywordComments && sender.tag != RFKeywordReplies)) return;
  [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:row->key];
  RFReloadPreferences();
  for (UITableViewCell *cell in table.visibleCells)
    if ([cell isKindOfClass:RFSettingsCell.class])
      RFSetToggleCellEnabled((RFSettingsCell *)cell, RFToggleRowForTag(RFSwitch((RFSettingsCell *)cell).tag));
}

// Declarations for the Debug section's helpers so the call sites below are typed.
// (The implementations are added to the class at runtime by Logos below.)
@interface FeedFilterSettingsViewController (RFSchemaDebug)
- (UITableViewCell *)debugCellForRow:(NSInteger)row inTableView:(UITableView *)tableView;
- (void)rfCopyDiscoveredPath:(UIButton *)sender;
- (void)rfCopyFailedJSON:(UIButton *)sender;
- (void)rfResetCounters:(UIButton *)sender;
- (void)rfShareReport:(UIButton *)sender;
@end

// Declarations for the Backup section's helpers so the call sites below are typed.
// (The implementations are added to the class at runtime by Logos below.)
@interface FeedFilterSettingsViewController (RFBackupUI)
- (void)rfExportSettings;
- (void)rfImportSettings;
- (void)rfImportBackupAtURL:(NSURL *)url;
@end

// Keeps the picker's delegate alive for as long as the picker is on screen.
static char kRFBackupPickerKey;

static void RFShowRestartAlert(UIViewController *controller) {
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:@"Restart Reddit"
                                          message:@"Fully close and reopen Reddit to finish blocking Home feed ads."
                                   preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
  [controller presentViewController:alert animated:YES completion:nil];
}

// The picker may still be on screen, or being dismissed, when its delegate callback runs, and
// UIKit drops a presentation made then. Wait until nothing is being presented or animated.
static void RFPresentWhenFree(UIViewController *controller, UIViewController *alert, NSInteger tries) {
  BOOL busy = controller.presentedViewController != nil || controller.transitionCoordinator != nil;
  if (busy && tries > 0) {
    __weak UIViewController *weakController = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      if (weakController) RFPresentWhenFree(weakController, alert, tries - 1);
    });
    return;
  }
  [controller presentViewController:alert animated:YES completion:nil];
}

static void RFShowBackupAlert(UIViewController *controller, NSString *title, NSString *message) {
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                 message:message
                                                          preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
  RFPresentWhenFree(controller, alert, 30);
}

static NSString *RFBackupSummaryMessage(RFBackupSummary *summary) {
  NSString *date = summary.exportedAt ? [NSDateFormatter localizedStringFromDate:summary.exportedAt
                                                                      dateStyle:NSDateFormatterMediumStyle
                                                                      timeStyle:NSDateFormatterShortStyle]
                                      : @"an unknown date";
  NSString *settings = [NSString stringWithFormat:@"%lu setting%@", (unsigned long)summary.settingCount,
                                                  summary.settingCount == 1 ? @"" : @"s"];
  NSString *keywords = [NSString stringWithFormat:@"%lu keyword%@", (unsigned long)summary.keywordCount,
                                                  summary.keywordCount == 1 ? @"" : @"s"];
  NSString *hidden = [NSString stringWithFormat:@"%@ hidden item%@", RFStatsFormattedCount(summary.totalHidden),
                                                summary.totalHidden == 1 ? @"" : @"s"];
  return [NSString stringWithFormat:@"Backup from %@.\n\n%@, %@ and %@.\n\nThis replaces your current settings, "
                                    @"keywords and stats.",
                                    date, settings, keywords, hidden];
}

%subclass FeedFilterSettingsViewController : BaseTableViewController

- (void)viewDidLoad {
  %orig;
  self.title = RFPageTitle(RFCurrentPage(self));
  Class toggleCellClass = RFSettingsCell.class;
  [self.tableView registerClass:toggleCellClass forCellReuseIdentifier:kToggleCellID];
  [self.tableView registerClass:toggleCellClass forCellReuseIdentifier:kLinkCellID];
  [self.tableView registerClass:toggleCellClass forCellReuseIdentifier:kRootCellID];
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
  RFRefreshSnapshot(self);
  [self.tableView reloadData];
}

#pragma mark - Backup

%new
- (void)rfExportSettings {
  NSData *data = RFBackupExport(NSUserDefaults.standardUserDefaults);
  if (!data) {
    RFShowBackupAlert(self, @"Couldn't export settings", @"The backup file couldn't be created.");
    return;
  }

  NSDateFormatter *formatter = [NSDateFormatter new];
  formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  formatter.dateFormat = @"yyyy-MM-dd";
  NSString *name =
      [NSString stringWithFormat:@"RedditFilter-Settings-%@.json", [formatter stringFromDate:[NSDate date]]];
  NSURL *url = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:name];
  NSError *error = nil;
  if (![data writeToURL:url options:NSDataWritingAtomic error:&error]) {
    RFShowBackupAlert(self, @"Couldn't export settings", error.localizedDescription);
    return;
  }

  UIDocumentPickerViewController *picker =
      [[UIDocumentPickerViewController alloc] initForExportingURLs:@[ url ] asCopy:YES];
  RFBackupPicker *delegate = [[RFBackupPicker alloc] initWithCompletion:^(__unused NSURL *picked) {
    // The picker has taken its copy, so the temporary file isn't needed any more.
    [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
  }];
  objc_setAssociatedObject(picker, &kRFBackupPickerKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  picker.delegate = delegate;
  [self presentViewController:picker animated:YES completion:nil];
}

%new
- (void)rfImportSettings {
  UIDocumentPickerViewController *picker =
      [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeJSON ] asCopy:YES];
  __weak typeof(self) weakSelf = self;
  RFBackupPicker *delegate = [[RFBackupPicker alloc] initWithCompletion:^(NSURL *url) {
    if (url) [weakSelf rfImportBackupAtURL:url];
  }];
  objc_setAssociatedObject(picker, &kRFBackupPickerKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  picker.delegate = delegate;
  [self presentViewController:picker animated:YES completion:nil];
}

%new
- (void)rfImportBackupAtURL:(NSURL *)url {
  NSError *error = nil;
  NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&error];
  if (!data) {
    RFShowBackupAlert(self, @"Couldn't import that backup",
                      error.localizedDescription ?: @"The file couldn't be read.");
    return;
  }

  RFBackupSummary *summary = RFBackupParse(data, &error);
  if (!summary) {
    RFShowBackupAlert(self, @"Couldn't import that backup",
                      error.localizedDescription ?: @"This file isn't a RedditFilter backup.");
    return;
  }

  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Import settings?"
                                                                 message:RFBackupSummaryMessage(summary)
                                                          preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
  __weak typeof(self) weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:@"Replace"
                                            style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *action) {
                                            NSError *applyError = nil;
                                            if (!RFBackupApply(summary, NSUserDefaults.standardUserDefaults,
                                                               &applyError)) {
                                              RFShowBackupAlert(weakSelf, @"Couldn't import that backup",
                                                                applyError.localizedDescription ?: @"Nothing was changed.");
                                              return;
                                            }
                                            RFReloadPreferences();
                                            [weakSelf.tableView reloadData];
                                            // Same treatment as turning Promoted on by hand.
                                            BOOL restart =
                                                [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterPromoted] &&
                                                RFCleanCachedExperiments();
                                            UIAlertController *done = [UIAlertController
                                                alertControllerWithTitle:@"Settings imported"
                                                                 message:@"Your settings, keywords and stats have been replaced."
                                                          preferredStyle:UIAlertControllerStyleAlert];
                                            [done addAction:[UIAlertAction
                                                                actionWithTitle:@"OK"
                                                                          style:UIAlertActionStyleDefault
                                                                        handler:^(UIAlertAction *doneAction) {
                                                                          if (restart) RFShowRestartAlert(weakSelf);
                                                                        }]];
                                            RFPresentWhenFree(weakSelf, done, 30);
                                          }]];
  RFPresentWhenFree(self, alert, 30);
}

%new
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return RFSections(self).count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  RFSection kind = RFSectionAt(self, section);
  if (RFTags(kind).count) return RFTags(kind).count;
  switch (kind) {
    case RFSectionStats: return 1;
    case RFSectionRootFilters: return 2;
    case RFSectionDisplay: return 3;
    case RFSectionMore: return 3 + RFHasSafariExtension();
    case RFSectionBackup: return 2;
    case RFSectionDebug: return 1 + (RFDiagnosticsEnabled() ? RFDebugSnapshot(self).count + 2 : 0);
    case RFSectionAbout: return kAboutRowCount + 1;
    default: return 0;
  }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  RFSection section = RFSectionAt(self, indexPath.section);
  NSInteger tag = RFToggleTagAt(self, indexPath);
  if (section == RFSectionAbout && tag < 0) return RFAboutCell(tableView, RFAboutLinkIndex(indexPath.row));
  RFPage destination = RFDestination(self, indexPath);
  if (destination != RFPageRoot) {
    NSString *subtitle = nil, *icon = nil, *symbol = nil;
    switch (destination) {
      case RFPagePosts: {
        NSInteger hidden = 0;
        NSArray<NSNumber *> *tags = RFTags(RFSectionFilters);
        for (NSNumber *tag in tags)
          hidden += [NSUserDefaults.standardUserDefaults boolForKey:kToggleRows[tag.integerValue].key];
        subtitle = [NSString stringWithFormat:@"Hiding %ld of %lu", (long)hidden, (unsigned long)tags.count];
        icon = @"rpl3/filter"; symbol = @"line.3.horizontal.decrease.circle";
        break;
      }
      case RFPageAppearance: subtitle = @"Awards, scores, colours and links"; icon = @"rpl3/award"; symbol = @"paintpalette"; break;
      case RFPageCollapse: return RFSwipeCell(tableView);
      case RFPageRedgifs: subtitle = [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterRedgifsDirect] ? @"Direct play on" : @"Direct play off"; icon = @"rpl3/play"; symbol = @"play.rectangle"; break;
      case RFPageBackup: subtitle = @"Export or import your settings"; icon = @"rpl3/download"; symbol = @"arrow.up.arrow.down"; break;
      case RFPageDiagnostics: subtitle = RFDiagnosticsEnabled() ? @"On" : @"Off"; icon = @"rpl3/bug"; symbol = @"ladybug"; break;
      case RFPageAbout: subtitle = RFVersionText(); icon = @"rpl3/info"; symbol = @"info.circle"; break;
      default: break;
    }
    return RFLinkCell(tableView, RFPageTitle(destination), subtitle, icon, symbol);
  }
  if (section == RFSectionRootFilters) return RFKeywordsCell(tableView);
  if (section == RFSectionMore) return RFSafariCell(tableView);
  if (section == RFSectionStats) return RFStatsCell(tableView);
  if (section == RFSectionBackup) {
    return indexPath.row == 0
               ? RFLinkCell(tableView, @"Export Settings", @"Save your settings, keywords and stats",
                            @"rpl3/upload,rpl3/share", @"square.and.arrow.up")
               : RFLinkCell(tableView, @"Import Settings", @"Restore them from a backup file",
                            @"rpl3/download", @"square.and.arrow.down");
  }
  if (section == RFSectionDebug && tag < 0) return [self debugCellForRow:indexPath.row - 1 inTableView:tableView];
  RFSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:kToggleCellID
                                                                   forIndexPath:indexPath];
  const RFToggleRow *row = RFToggleRowForTag(tag);
  if (!row) return cell;

  RFConfigureToggleCell(cell, tag, self);

  return cell;
}

%new
- (void)rfToggleChanged:(UISwitch *)sender {
  const RFToggleRow *row = RFToggleRowForTag(sender.tag);
  if (!row) return;
  BOOL filterOn = row->switchOnMeansShow ? !sender.on : sender.on;
  [NSUserDefaults.standardUserDefaults setBool:filterOn forKey:row->key];
  RFKeepOneSwipeSide(self.tableView, row->key, filterOn);
  RFReloadPreferences();

  // Some accounts are in a Reddit experiment that loads Home ads where the filter can't see them.
  // It's removed at launch, but the running app has already read it.
  if (filterOn && [row->key isEqualToString:kRedditFilterPromoted] && RFCleanCachedExperiments())
    RFShowRestartAlert(self);

  // Show or hide the schema paths below the Diagnostics switch.
  // (A plain reload: an animated section reload lays the new footer out too wide.)
  if (sender.tag == RFDiagnostics) {
    RFRefreshSnapshot(self);
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
  RFPage destination = RFDestination(self, indexPath);
  if (destination != RFPageRoot) {
    UIViewController *page = [(FeedFilterSettingsViewController *)[self.class alloc] initWithStyle:UITableViewStyleGrouped];
    objc_setAssociatedObject(page, &kRFPageKey, @(destination), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self.navigationController pushViewController:page animated:YES];
    return;
  }
  if (RFSectionAt(self, indexPath.section) == RFSectionRootFilters) {
    [self.navigationController pushViewController:[RFKeywordsViewController new] animated:YES];
    return;
  }
  if (RFSectionAt(self, indexPath.section) == RFSectionMore) {
    RFShowSafariSetup(self);
    return;
  }
  if (RFSectionAt(self, indexPath.section) == RFSectionStats) {
    [self.navigationController pushViewController:[RFStatsViewController new] animated:YES];
    return;
  }
  if (RFSectionAt(self, indexPath.section) == RFSectionBackup) {
    if (indexPath.row == 0) [self rfExportSettings];
    else if (indexPath.row == 1) [self rfImportSettings];
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
    __weak UINavigationController *weakNavigation = self.navigationController;
    Class settingsClass = self.class;
    RFCheckForUpdateNow(self, ^{
      if (weakSelf) RFSetCheckingForUpdate(weakSelf, NO);
      // The RedditFilter row shows an update when there is one.
      UITableView *table = weakTable;
      if (table && section < table.numberOfSections) [table reloadSections:[NSIndexSet indexSetWithIndex:section]
                                                           withRowAnimation:UITableViewRowAnimationNone];
      // They may have gone back to the main page, whose About row shows it too.
      UIViewController *top = weakNavigation.topViewController;
      if (top != weakSelf && [top isKindOfClass:settingsClass]) [((UITableViewController *)top).tableView reloadData];
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
  NSString *text = RFHeaderText(self, section);
  return RFSectionHeight(tableView, text, YES, text ? (RFCurrentPage(self) == RFPageRoot ? 22.0 : 26.0) : 8.0);
}

%new
- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
  return RFSectionView(tableView, RFFooterText(self, section), [self tableView:tableView heightForFooterInSection:section], NO);
}

%new
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
  RFSection kind = RFSectionAt(self, section);
  NSString *text = RFFooterText(self, section);
  CGFloat minimum = !text ? (RFCurrentPage(self) == RFPageRoot ? 4.0 : 8.0) : kind == RFSectionDebug ? 76.0 : 48.0;
  return RFSectionHeight(tableView, text, NO, minimum);
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

  NSArray<NSDictionary *> *snapshot = RFDebugSnapshot(self);
  
  // Trailing "share" row.
  if (row == (NSInteger)snapshot.count) {
    cell.textLabel.textColor = [UIColor systemBlueColor];
    cell.textLabel.text = @"Share report";
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.text = @"Copy or send this list, without usernames or post text";
    UIButton *shareButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [shareButton setTitle:@"Share" forState:UIControlStateNormal];
    shareButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    [shareButton addTarget:self action:@selector(rfShareReport:) forControlEvents:UIControlEventTouchUpInside];
    [shareButton sizeToFit];
    cell.accessoryView = shareButton;
    return cell;
  }

  // Trailing "reset" row.
  if (row > (NSInteger)snapshot.count) {
    cell.textLabel.textColor = [UIColor systemBlueColor];
    cell.textLabel.text = @"Reset counters";
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.text = @"Clear these results and start checking again";
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
  NSString *summary = record[kRFDebugSummary];
  if (summary) {
    cell.textLabel.textColor = [UIColor labelColor];
    cell.textLabel.text = record[kRFDebugOp];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.text = summary;
    return cell;
  }
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
  NSArray<NSString *> *feedCards = record[kRFDebugFeedCards];
  if (feedCards) {
    cell.textLabel.textColor = [UIColor labelColor];
    cell.textLabel.text = record[kRFDebugOp];
    if (feedCards.count == 0) {
      cell.detailTextLabel.text = @"\u2713 only posts and ads so far";
      cell.detailTextLabel.textColor = [UIColor systemGreenColor];
    } else {
      NSMutableArray<NSString *> *known = [NSMutableArray array], *unknown = [NSMutableArray array];
      for (NSString *line in feedCards)
        [[line hasPrefix:@"?"] ? unknown : known addObject:[line substringFromIndex:2]];
      NSMutableArray<NSString *> *groups = [NSMutableArray array];
      if (known.count)
        [groups addObject:[@"Extra cards can hide:\n" stringByAppendingString:[known componentsJoinedByString:@"\n"]]];
      if (unknown.count)
        [groups addObject:[@"Not recognised, worth reporting:\n" stringByAppendingString:[unknown componentsJoinedByString:@"\n"]]];
      cell.detailTextLabel.text = [groups componentsJoinedByString:@"\n\n"];
      cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
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
  NSInteger redditErrors = [record[kRFDebugErrors] integerValue];

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
    if (redditErrors > 0)
      detail = [detail stringByAppendingFormat:@" \u00b7 %ld Reddit error%@", (long)redditErrors,
                                               redditErrors == 1 ? @"" : @"s"];
    detailColor = [UIColor systemGreenColor];
  } else if (misses == 0) {
    detail = [NSString stringWithFormat:@"only Reddit errors so far \u00b7 %ld", (long)redditErrors];
    detailColor = [UIColor secondaryLabelColor];
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
  NSArray<NSDictionary *> *snapshot = RFDebugSnapshot(self);
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
  NSArray<NSDictionary *> *snapshot = RFDebugSnapshot(self);
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
- (void)rfShareReport:(UIButton *)sender {
  NSString *reddit = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
  NSString *report = [NSString stringWithFormat:@"RedditFilter %s, Reddit %@, iOS %@\n\n%@", RF_VERSION, reddit,
                                                UIDevice.currentDevice.systemVersion,
                                                [[RFSchemaDebug shared] reportText]];
  UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[ report ]
                                                                      applicationActivities:nil];
  share.popoverPresentationController.sourceView = sender; // needed on iPad
  share.popoverPresentationController.sourceRect = sender.bounds;
  [self presentViewController:share animated:YES completion:nil];
}

%new
- (void)rfResetCounters:(UIButton *)sender {
  [[RFSchemaDebug shared] reset];
  RFRefreshSnapshot(self);
  [self.tableView reloadData];
}
%end
