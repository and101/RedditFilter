// RFStatsViewController.m
//
// An inset grouped table like the Settings app: a total with a bar split by filter (like iPhone
// Storage), each filter with its count, then Reset. Follows Reddit's theme like the other settings screens.

#import "RFStatsViewController.h"
#import "Preferences.h"
#import "RFStats.h"

typedef struct {
  __unsafe_unretained NSString *name;
  __unsafe_unretained NSString *symbol;
} RFStatInfo;

static const RFStatInfo kRFStatInfo[RFStatCount] = {
    [RFStatFeedAds] = {@"Promoted Posts", @"megaphone.fill"},
    [RFStatCommentAds] = {@"Ads in Comments", @"text.bubble.fill"},
    [RFStatRecommended] = {@"Recommendations", @"sparkles"},
    [RFStatVideosForYou] = {@"Videos for You", @"play.rectangle.fill"},
    [RFStatNSFW] = {@"NSFW Posts", @"eye.slash.fill"},
    [RFStatKeywordPosts] = {@"Posts with Keywords", @"text.magnifyingglass"},
    [RFStatKeywordComments] = {@"Comments with Keywords", @"bubble.left.and.bubble.right.fill"},
    [RFStatExtraCards] = {@"Extra Feed Cards", @"rectangle.stack.fill"},
};

static UIColor *RFStatColor(RFStat stat) {
  switch (stat) {
    case RFStatFeedAds: return UIColor.systemOrangeColor;
    case RFStatCommentAds: return UIColor.systemPinkColor;
    case RFStatRecommended: return UIColor.systemPurpleColor;
    case RFStatVideosForYou: return UIColor.systemBlueColor;
    case RFStatNSFW: return UIColor.systemRedColor;
    case RFStatKeywordPosts: return UIColor.systemTealColor;
    case RFStatKeywordComments: return UIColor.systemGreenColor;
    case RFStatExtraCards: return UIColor.systemIndigoColor;
    case RFStatCount: break;
  }
  return UIColor.systemGrayColor;
}

NSString *RFStatsFormattedCount(unsigned long long count) {
  static NSNumberFormatter *formatter;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    formatter = [NSNumberFormatter new];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
  });
  return [formatter stringFromNumber:@(count)];
}

NSString *RFStatsSinceText(NSDate *since) {
  if (!since || [NSCalendar.currentCalendar isDateInToday:since]) return @"since today";
  static NSDateFormatter *formatter;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    formatter = [NSDateFormatter new];
    formatter.dateStyle = NSDateFormatterLongStyle;
    formatter.timeStyle = NSDateFormatterNoStyle;
  });
  return [@"since " stringByAppendingString:[formatter stringFromDate:since]];
}

// A white symbol on a rounded colour square, like the Settings app's icons. Main thread only.
static UIImage *RFTileIcon(RFStat stat) {
  static NSMutableDictionary<NSNumber *, UIImage *> *cache;
  if (!cache) cache = [NSMutableDictionary dictionary];
  if (cache[@(stat)]) return cache[@(stat)];
  CGFloat side = 29;
  UIImage *symbol = [[UIImage systemImageNamed:kRFStatInfo[stat].symbol
                             withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15
                                                                                                weight:UIImageSymbolWeightSemibold]]
      imageWithTintColor:UIColor.whiteColor
           renderingMode:UIImageRenderingModeAlwaysOriginal];
  UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
  UIImage *tile = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
    [RFStatColor(stat) setFill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side) cornerRadius:6.5] fill];
    CGSize size = symbol.size;
    CGFloat scale = MIN(1, MIN(19 / size.width, 19 / size.height));
    size = CGSizeMake(size.width * scale, size.height * scale);
    [symbol drawInRect:CGRectMake((side - size.width) / 2, (side - size.height) / 2, size.width, size.height)];
  }];
  cache[@(stat)] = tile;
  return tile;
}

#pragma mark - The bar split by filter

// One bar, split into a coloured part per filter, each as wide as its share, like iPhone Storage.
@interface RFSplitBar : UIView
@property(nonatomic, copy) NSArray<NSNumber *> *counts;
@end

@implementation RFSplitBar
- (instancetype)init {
  if ((self = [super initWithFrame:CGRectZero])) {
    self.layer.cornerRadius = 5;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.clipsToBounds = YES;
    self.backgroundColor = UIColor.tertiarySystemFillColor;
  }
  return self;
}
- (CGSize)intrinsicContentSize { return CGSizeMake(UIViewNoIntrinsicMetric, 18); }
- (void)layoutSubviews {
  [super layoutSubviews];
  for (UIView *view in self.subviews) [view removeFromSuperview];
  double total = [[self.counts valueForKeyPath:@"@sum.self"] doubleValue];
  if (total <= 0) return;
  NSInteger parts = 0;
  for (NSNumber *count in self.counts) parts += count.doubleValue > 0;
  CGFloat gap = 1.5, width = self.bounds.size.width - gap * MAX(parts - 1, 0), x = 0;
  for (NSInteger i = 0; i < (NSInteger)self.counts.count; i++) {
    double count = self.counts[i].doubleValue;
    if (count <= 0) continue;
    CGFloat w = MAX(round(width * count / total), 3);
    if (--parts == 0) w = self.bounds.size.width - x; // the last part fills the rest, whatever the rounding
    UIView *part = [[UIView alloc] initWithFrame:CGRectMake(x, 0, MAX(w, 0), self.bounds.size.height)];
    part.backgroundColor = RFStatColor(i);
    [self addSubview:part];
    x += w + gap;
  }
}
@end

#pragma mark - The screen

typedef NS_ENUM(NSInteger, RFStatsSection) { RFStatsSectionTotal, RFStatsSectionFilters, RFStatsSectionReset };

@implementation RFStatsViewController {
  NSDictionary *_stats;
  NSArray<NSNumber *> *_order; // filters, biggest count first
}

- (instancetype)init {
  if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = @"Stats";
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
  RFApplySettingsTheme(self.tableView, @selector(setBackgroundColor:), @selector(bodyColor));
  [NSNotificationCenter.defaultCenter addObserver:self
                                         selector:@selector(reload)
                                             name:RFStatsDidChangeNotification
                                           object:nil];
  [self loadStats];
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)loadStats {
  _stats = RFStatsSnapshot();
  NSArray<NSNumber *> *counts = _stats[kRFStatsCounts];
  NSMutableArray *order = [NSMutableArray array];
  for (NSInteger i = 0; i < RFStatCount; i++) [order addObject:@(i)];
  [order sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
    return [counts[b.integerValue] compare:counts[a.integerValue]];
  }];
  _order = order;
}

- (void)reload {
  [self loadStats];
  [self.tableView reloadData];
}

- (unsigned long long)total {
  return [[_stats[kRFStatsCounts] valueForKeyPath:@"@sum.self"] unsignedLongLongValue];
}

- (UITableViewCell *)styledCell:(UITableViewCell *)cell {
  cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
  RFApplySettingsCardTheme(cell);
  cell.textLabel.textColor = UIColor.labelColor;
  RFApplySettingsTheme(cell.textLabel, @selector(setTextColor:), @selector(bodyTextColor));
  cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
  RFApplySettingsTheme(cell.detailTextLabel, @selector(setTextColor:), @selector(metaTextColor));
  cell.selectionStyle = UITableViewCellSelectionStyleNone;
  return cell;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return section == RFStatsSectionFilters ? RFStatCount : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  return section == RFStatsSectionFilters ? @"By Filter" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  if (section != RFStatsSectionFilters) return nil;
  return @"Counted on this device while a filter is on. A post counts once per launch, so it can count again "
         @"after a restart.";
}

- (UITableViewCell *)totalCell {
  UITableViewCell *cell = [self styledCell:[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                                  reuseIdentifier:nil]];
  NSArray<NSNumber *> *counts = _stats[kRFStatsCounts];
  unsigned long long total = self.total;
  NSNumber *today = _stats[kRFStatsDays][RFStatsDayKey([NSDate date])] ?: @0;

  UILabel *number = [UILabel new];
  number.font = [UIFontMetrics.defaultMetrics scaledFontForFont:[UIFont systemFontOfSize:34 weight:UIFontWeightBold]];
  number.adjustsFontForContentSizeCategory = YES;
  number.adjustsFontSizeToFitWidth = YES;
  number.minimumScaleFactor = 0.5;
  number.text = RFStatsFormattedCount(total);
  number.textColor = UIColor.labelColor;
  RFApplySettingsTheme(number, @selector(setTextColor:), @selector(bodyTextColor));

  UILabel *caption = [UILabel new];
  caption.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
  caption.adjustsFontForContentSizeCategory = YES;
  caption.numberOfLines = 0;
  caption.text = [NSString stringWithFormat:@"Hidden %@ · %@ today", RFStatsSinceText(_stats[kRFStatsSince]),
                                            RFStatsFormattedCount(today.unsignedLongLongValue)];
  caption.textColor = UIColor.secondaryLabelColor;
  RFApplySettingsTheme(caption, @selector(setTextColor:), @selector(metaTextColor));

  RFSplitBar *bar = [RFSplitBar new];
  bar.counts = counts;

  // A coloured dot and name for each filter that hid something, biggest first.
  NSMutableAttributedString *legend = [NSMutableAttributedString new];
  UIFont *legendFont = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
  for (NSNumber *stat in _order) {
    if (counts[stat.integerValue].unsignedLongLongValue == 0) continue;
    if (legend.length) [legend appendAttributedString:[[NSAttributedString alloc] initWithString:@"    "]];
    [legend appendAttributedString:[[NSAttributedString alloc]
                                       initWithString:@"● "
                                           attributes:@{NSForegroundColorAttributeName : RFStatColor(stat.integerValue),
                                                        NSFontAttributeName : legendFont}]];
    // No-break spaces keep each name on one line.
    NSString *name = [kRFStatInfo[stat.integerValue].name stringByReplacingOccurrencesOfString:@" " withString:@" "];
    [legend appendAttributedString:[[NSAttributedString alloc] initWithString:name
                                                                   attributes:@{NSFontAttributeName : legendFont}]];
  }
  UILabel *legendLabel = [UILabel new];
  legendLabel.numberOfLines = 0;
  legendLabel.textColor = UIColor.secondaryLabelColor;
  RFApplySettingsTheme(legendLabel, @selector(setTextColor:), @selector(metaTextColor));
  legendLabel.attributedText = legend;
  legendLabel.hidden = total == 0;

  UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ number, caption, bar, legendLabel ]];
  stack.axis = UILayoutConstraintAxisVertical;
  stack.spacing = 2;
  [stack setCustomSpacing:14 afterView:caption];
  [stack setCustomSpacing:10 afterView:bar];
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [cell.contentView addSubview:stack];
  UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
  [NSLayoutConstraint activateConstraints:@[
    [stack.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
    [stack.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
    [stack.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:14],
    [stack.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-16],
  ]];
  cell.isAccessibilityElement = YES;
  cell.accessibilityLabel = [NSString stringWithFormat:@"%@ hidden, %@", number.text, caption.text];
  return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (indexPath.section == RFStatsSectionTotal) return [self totalCell];

  if (indexPath.section == RFStatsSectionReset) {
    UITableViewCell *cell = [self styledCell:[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                                    reuseIdentifier:nil]];
    cell.textLabel.text = @"Reset Stats";
    cell.textLabel.textAlignment = NSTextAlignmentCenter;
    BOOL any = self.total > 0;
    cell.textLabel.textColor = any ? UIColor.systemRedColor : UIColor.tertiaryLabelColor;
    cell.selectionStyle = any ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    cell.accessibilityTraits = UIAccessibilityTraitButton | (any ? 0 : UIAccessibilityTraitNotEnabled);
    return cell;
  }

  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"RFStatCell"];
  if (!cell)
    cell = [self styledCell:[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                                   reuseIdentifier:@"RFStatCell"]];
  RFStat stat = _order[indexPath.row].integerValue;
  cell.imageView.image = RFTileIcon(stat);
  cell.textLabel.text = kRFStatInfo[stat].name;
  cell.detailTextLabel.text = RFStatsFormattedCount([_stats[kRFStatsCounts][stat] unsignedLongLongValue]);
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (indexPath.section == RFStatsSectionReset && self.total > 0) [self confirmResetFrom:indexPath];
}

- (void)confirmResetFrom:(NSIndexPath *)indexPath {
  UIAlertController *sheet =
      [UIAlertController alertControllerWithTitle:nil
                                          message:@"All counts go back to zero and start again from today."
                                   preferredStyle:UIAlertControllerStyleActionSheet];
  [sheet addAction:[UIAlertAction actionWithTitle:@"Reset Stats"
                                            style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *action) {
                                            RFStatsReset();
                                            [self reload];
                                          }]];
  [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
  UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
  sheet.popoverPresentationController.sourceView = cell ?: self.view;
  sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
  [self presentViewController:sheet animated:YES completion:nil];
}

@end
