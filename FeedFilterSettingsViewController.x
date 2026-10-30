#import <objc/message.h>
#import <objc/runtime.h>
#import "FeedFilterSettingsViewController.h"
#import "KeywordsViewController.h"
#import "DebugMenu.h"
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
  BOOL switchOnMeansShow;                 // YES: switch ON shows the content (the saved setting is the opposite)
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
    {kRedditFilterAutoCollapseAutoMod, @"AutoMod", @"Auto collapse AutoMod comments", @"rpl3/mod,icon_mod", NO},
    {kRedditFilterColoredComments, @"Colored comment threads", @"Give each reply level its own color",
     @"rpl3/branch,rpl3/comment,icon_comment", NO},
    {kRedditFilterColoredCommentsApollo, @"Apollo style", @"Only color each comment's own line",
     @"rpl3/branch,rpl3/comment,icon_comment", NO, kRedditFilterColoredComments},
    {kRedditFilterRedgifsDirect, @"Direct-play RedGIFs", @"Plays with sound, but may use more data",
     @"rpl3/volumeOn,rpl3/play", NO},
};
static const NSInteger kToggleRowCount = sizeof(kToggleRows) / sizeof(kToggleRows[0]);

// In the Keywords section, under the keyword list. Their switch tags follow kToggleRows'.
static const RFToggleRow kKeywordRows[] = {
    {kRedditFilterKeywordComments, @"Filter comments too", @"Hide comments that mention a keyword",
     @"rpl3/comment,icon_comment", NO},
    {kRedditFilterKeywordCommentReplies, @"Hide replies too", @"Also hide the replies below them",
     @"rpl3/reply,icon_reply", NO, kRedditFilterKeywordComments},
};

// In the About section, between the RedditFilter and developer rows. Its switch tag follows kKeywordRows'.
static const RFToggleRow kUpdateRow = {kRedditFilterCheckUpdates, @"Check for updates",
                                       @"Tell me when a new RedditFilter is out", @"rpl3/download,rpl3/notifications",
                                       NO};
static const NSInteger kUpdateRowTag = kToggleRowCount + 2;
// Its position: row 1 of the About section. The other About rows are kAboutRows.
static const NSInteger kAboutUpdateRow = 1;

static const RFToggleRow *RFToggleRowForTag(NSInteger tag) {
  if (tag >= 0 && tag < kToggleRowCount) return &kToggleRows[tag];
  if (tag == kUpdateRowTag) return &kUpdateRow;
  NSInteger keywordRow = tag - kToggleRowCount;
  return keywordRow >= 0 && keywordRow < 2 ? &kKeywordRows[keywordRow] : NULL;
}

// Greys out a row whose `requires` setting is off, like "Hide replies too" while comments aren't filtered.
static void RFSetToggleCellEnabled(ToggleImageTableViewCell *cell, const RFToggleRow *row) {
  BOOL enabled = !row->requires || [NSUserDefaults.standardUserDefaults boolForKey:row->requires];
  cell.contentView.alpha = enabled ? 1.0 : 0.4;
  cell.userInteractionEnabled = enabled;
}

#pragma mark - Cell helpers (fall back to plain UIKit if Reddit renames its classes)

static UILabel *RFMainLabel(ImageLabelTableViewCell *cell) {
  if ([cell respondsToSelector:@selector(mainLabel)]) return cell.mainLabel;
  if ([cell respondsToSelector:@selector(imageLabelView)]) return cell.imageLabelView.mainLabel;
  return cell.textLabel;
}

static UILabel *RFDetailLabel(ImageLabelTableViewCell *cell) {
  if ([cell respondsToSelector:@selector(detailLabel)]) return cell.detailLabel;
  if ([cell respondsToSelector:@selector(imageLabelView)]) return cell.imageLabelView.detailLabel;
  return cell.detailTextLabel;
}

static UISwitch *RFSwitch(ToggleImageTableViewCell *cell) {
  if ([cell respondsToSelector:@selector(accessorySwitch)]) return cell.accessorySwitch;
  if ([cell.accessoryView isKindOfClass:UISwitch.class]) return (UISwitch *)cell.accessoryView;
  UISwitch *toggle = [UISwitch new];
  cell.accessoryView = toggle;
  return toggle;
}

// The first of Reddit's icons that's found, else the SF Symbol, drawn in a 20pt square and tinted
// like Reddit's own settings icons.
static UIImage *RFIcon(NSString *iconNames, NSString *fallbackSymbol) {
  UIImage *icon = nil;
  for (NSString *name in [iconNames componentsSeparatedByString:@","])
    if ((icon = iconWithName(name))) break;
  if (!icon && fallbackSymbol) icon = [UIImage systemImageNamed:fallbackSymbol];
  if (!icon) return nil;
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

static void RFSetIcon(ImageLabelTableViewCell *cell, NSString *iconNames, NSString *fallbackSymbol) {
  UIImage *icon = RFIcon(iconNames, fallbackSymbol);
  if (!icon) return;
  if ([cell respondsToSelector:@selector(setDisplayImage:)]) {
    // The icon's size is a separate setting that Reddit sets on its own rows. Unset, a reused row keeps
    // whatever size it had, sometimes none, and the icon and its space disappear.
    NSMethodSignature *signature = [cell methodSignatureForSelector:@selector(setImageSize:)];
    if (signature.numberOfArguments == 3 && !strcmp([signature getArgumentTypeAtIndex:2], @encode(CGSize)))
      ((void (*)(id, SEL, CGSize))objc_msgSend)(cell, @selector(setImageSize:), icon.size);
    cell.displayImage = icon;
  } else if ([cell respondsToSelector:@selector(imageLabelView)]) cell.imageLabelView.imageView.image = icon;
  else cell.imageView.image = icon;
}

static void RFApplyTheme(UIView *view, SEL setter, SEL themeGetter) {
  if ([view respondsToSelector:@selector(associatePropertySetter:withThemePropertyGetter:)])
    [view associatePropertySetter:setter withThemePropertyGetter:themeGetter];
}

// Section header/footer: a themed label inset like Reddit's own settings.
static UIView *RFSectionView(UITableView *tableView, NSString *text, CGFloat height) {
  if (!text) return nil;

  // Reddit's spacing class is a Swift class, so it needs CoreClass to be found.
  Class guidanceClass = CoreClass(@"LayoutGuidance");
  LayoutGuidance *guidance =
      [guidanceClass respondsToSelector:@selector(currentGuidance)] ? [guidanceClass currentGuidance] : nil;
  CGFloat padding = guidance.gridPadding > 0 ? guidance.gridPadding : 16.0;
  CGFloat width = tableView.bounds.size.width;

  Class labelClass = %c(BaseLabel);
  UILabel *label = [labelClass respondsToSelector:@selector(labelWithSubheaderFont)]
                       ? [labelClass labelWithSubheaderFont]
                       : [UILabel new];
  label.frame = CGRectMake(padding, 0, MAX(width - padding * 2, 0), height);
  label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  label.numberOfLines = 0;
  label.text = text;
  RFApplyTheme(label, @selector(setTextColor:), @selector(metaTextColor));

  Class containerClass = %c(BaseTableReusableView);
  UIView *container = [[(containerClass ?: UIView.class) alloc] initWithFrame:CGRectMake(0, 0, width, height)];
  UIView *content = [container respondsToSelector:@selector(contentView)]
                        ? ((BaseTableReusableView *)container).contentView
                        : container;
  [content addSubview:label];
  RFApplyTheme(container, @selector(setBackgroundColor:), @selector(canvasColor));
  return container;
}

#pragma mark - Sections

typedef NS_ENUM(NSInteger, RFSection) { RFSectionFilters, RFSectionKeywords, RFSectionDebug, RFSectionAbout };

// Filters, Keywords, [Schema Paths (debug builds only)], About
static const NSInteger kSectionCount = REDDITFILTER_DEBUG ? 4 : 3;

static RFSection RFSectionAt(NSInteger section) {
  if (section == 0) return RFSectionFilters;
  if (section == 1) return RFSectionKeywords;
  if (REDDITFILTER_DEBUG && section == 2) return RFSectionDebug;
  return RFSectionAbout;
}

// The switch tag of the row at this position, or -1 for rows without a switch.
static NSInteger RFToggleTagAt(NSIndexPath *indexPath) {
  switch (RFSectionAt(indexPath.section)) {
    case RFSectionFilters: return indexPath.row;
    case RFSectionKeywords: return indexPath.row > 0 ? kToggleRowCount + indexPath.row - 1 : -1;
    case RFSectionAbout: return indexPath.row == kAboutUpdateRow ? kUpdateRowTag : -1;
    case RFSectionDebug: return -1;
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
  ToggleImageTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kLinkCellID];
  RFMainLabel(cell).text = title;
  RFDetailLabel(cell).text = subtitle;
  RFSetIcon(cell, icons, symbol);
  UISwitch *toggle = RFSwitch(cell);
  toggle.hidden = YES;
  if (cell.accessoryView == toggle) cell.accessoryView = nil;
  cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  cell.selectionStyle = UITableViewCellSelectionStyleDefault;
  objc_setAssociatedObject(cell, @selector(rfOwnedCell), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [cell setNeedsUpdateConstraints];
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

#if REDDITFILTER_DEBUG
// Declarations for the debug-only helpers so the call sites below are typed.
// (The implementations are added to the class at runtime by Logos below.)
@interface FeedFilterSettingsViewController (RFSchemaDebug)
- (UITableViewCell *)debugCellForRow:(NSInteger)row inTableView:(UITableView *)tableView;
- (void)rfCopyDiscoveredPath:(UIButton *)sender;
- (void)rfCopyFailedJSON:(UIButton *)sender;
- (void)rfResetCounters:(UIButton *)sender;
@end
#endif

%subclass FeedFilterSettingsViewController : BaseTableViewController

- (void)viewDidLoad {
  %orig;
  self.title = @"RedditFilter";
  Class toggleCellClass = CoreClass(@"ToggleImageTableViewCell") ?: UITableViewCell.class;
  [self.tableView registerClass:toggleCellClass forCellReuseIdentifier:kToggleCellID];
  [self.tableView registerClass:toggleCellClass forCellReuseIdentifier:kLinkCellID];
#if REDDITFILTER_DEBUG
  // Debug rows carry multi-line detail text, so let them self-size.
  self.tableView.estimatedRowHeight = 60.0;
  self.tableView.rowHeight = UITableViewAutomaticDimension;
#endif
}

- (void)viewWillAppear:(BOOL)animated {
  %orig;
  // Refresh the keyword count after coming back from the Keywords screen
  // (and, in debug builds, the stats that accrue while the app runs).
  [self.tableView reloadData];
}

%new
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return kSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  switch (RFSectionAt(section)) {
    case RFSectionFilters:
      return kToggleRowCount;
    case RFSectionKeywords:
      return 3; // Keywords, Filter comments too, Hide replies too
    case RFSectionDebug:
#if REDDITFILTER_DEBUG
      // One row per tracked schema path, plus a trailing "reset" row.
      return [[RFSchemaDebug shared] snapshot].count + 1;
#endif
      return 0;
    case RFSectionAbout:
      return kAboutRowCount + 1; // plus "Check for updates"
  }
  return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  RFSection section = RFSectionAt(indexPath.section);
  NSInteger tag = RFToggleTagAt(indexPath);
  if (section == RFSectionAbout && tag < 0) return RFAboutCell(tableView, RFAboutLinkIndex(indexPath.row));
  if (section == RFSectionKeywords && indexPath.row == 0) return RFKeywordsCell(tableView);
#if REDDITFILTER_DEBUG
  if (section == RFSectionDebug) return [self debugCellForRow:indexPath.row inTableView:tableView];
#endif
  ToggleImageTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kToggleCellID
                                                                   forIndexPath:indexPath];
  const RFToggleRow *row = RFToggleRowForTag(tag);
  if (!row) return cell;

  RFMainLabel(cell).text = row->title;
  RFDetailLabel(cell).text = row->subtitle;
  RFSetIcon(cell, row->icons, nil);
  RFSetToggleCellEnabled(cell, row);

  UISwitch *toggle = RFSwitch(cell);
  BOOL saved = [NSUserDefaults.standardUserDefaults boolForKey:row->key];
  toggle.on = row->switchOnMeansShow ? !saved : saved;
  toggle.tag = tag;
  // Only remove our own action (cells get reused), never Reddit's.
  [toggle removeTarget:self action:NULL forControlEvents:UIControlEventAllEvents];
  [toggle addTarget:self action:@selector(rfToggleChanged:) forControlEvents:UIControlEventValueChanged];

  // Tag the cell so the layout fix in Tweak.xm applies to our rows only.
  objc_setAssociatedObject(cell, @selector(rfOwnedCell), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [cell setNeedsUpdateConstraints];
  return cell;
}

%new
- (void)rfToggleChanged:(UISwitch *)sender {
  const RFToggleRow *row = RFToggleRowForTag(sender.tag);
  if (!row) return;
  BOOL filterOn = row->switchOnMeansShow ? !sender.on : sender.on;
  [NSUserDefaults.standardUserDefaults setBool:filterOn forKey:row->key];
  RFReloadPreferences();

  // Rows that depend on this one, like "Hide replies too", become switchable or not.
  for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
    const RFToggleRow *other = RFToggleRowForTag(RFToggleTagAt(indexPath));
    if (other && [other->requires isEqualToString:row->key])
      RFSetToggleCellEnabled((ToggleImageTableViewCell *)[self.tableView cellForRowAtIndexPath:indexPath], other);
  }
}

%new
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (RFSectionAt(indexPath.section) == RFSectionKeywords && indexPath.row == 0) {
    [self.navigationController pushViewController:[RFKeywordsViewController new] animated:YES];
    return;
  }
  NSInteger link = RFAboutLinkIndex(indexPath.row);
  if (RFSectionAt(indexPath.section) != RFSectionAbout || link < 0 || link >= kAboutRowCount) return;
  // The RedditFilter row opens the new version's page when there's an update.
  NSURL *url = link == 0 ? RFUpdateURL() : [NSURL URLWithString:kAboutRows[link].link];
  if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

%new
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
  NSString *text = nil;
  switch (RFSectionAt(section)) {
    case RFSectionFilters: text = @"TWEAKS"; break;
    case RFSectionKeywords: text = @"KEYWORDS"; break;
    case RFSectionDebug: text = @"SCHEMA PATHS · DEBUG"; break;
    case RFSectionAbout: text = @"ABOUT"; break;
  }
  return RFSectionView(tableView, text, 40.0);
}

%new
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
  return 40.0;
}

%new
- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
  NSString *text = nil;
  switch (RFSectionAt(section)) {
    case RFSectionFilters:
      text = @"Filter posts and adjust how Reddit looks";
      break;
    case RFSectionKeywords:
      break;
    case RFSectionDebug:
      text = @"✓ resolved · ✗ broke (structural fallback is now filtering). "
             @"Tap Copy on a ✗ row to grab the auto-discovered replacement path.";
      break;
    case RFSectionAbout:
      text = @"Based on original work from level3tjg and NicholasBly";
      break;
  }
  return RFSectionView(tableView, text, [self tableView:tableView heightForFooterInSection:section]);
}

%new
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
  return RFSectionAt(section) == RFSectionDebug ? 76.0 : 40.0;
}

// ---------------------------------------------------------------------------
// Schema-path debug section.
//
// All of the method *declarations* below are compiled unconditionally so that
// Logos always registers them on the subclass; only their bodies are gated on
// REDDITFILTER_DEBUG. In a release build the bodies collapse to no-ops, the
// section is never shown (numberOfSections returns 1), and these methods are
// never invoked.
// ---------------------------------------------------------------------------
%new
- (UITableViewCell *)debugCellForRow:(NSInteger)row inTableView:(UITableView *)tableView {
#if REDDITFILTER_DEBUG
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
#else
  return nil;
#endif
}
%new
- (void)rfCopyDiscoveredPath:(UIButton *)sender {
#if REDDITFILTER_DEBUG
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
#endif
}
%new
- (void)rfCopyFailedJSON:(UIButton *)sender {
#if REDDITFILTER_DEBUG
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
#endif
}
%new
- (void)rfResetCounters:(UIButton *)sender {
#if REDDITFILTER_DEBUG
  [[RFSchemaDebug shared] reset];
  [self.tableView reloadData];
#endif
}
%end
