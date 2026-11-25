// RFDiagnosticDetail.m

#import "RFDiagnosticDetail.h"
#import "Preferences.h"
#import "ScreenRestore.h"

UIColor *RFDebugLevelColor(RFDebugLevel level) {
  return level == RFDebugLevelGood  ? UIColor.systemGreenColor
         : level == RFDebugLevelBad ? UIColor.systemRedColor
                                    : UIColor.secondaryLabelColor;
}

NSString *RFDebugSpokenStatus(NSString *status) {
  return [status stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"✓✗ "]];
}

typedef NS_ENUM(NSInteger, RFDetailSection) { RFDetailSectionStatus, RFDetailSectionText, RFDetailSectionCopy };

@implementation RFDiagnosticDetail {
  NSString *_operation; // nil: Last closed
  NSDictionary *_record;
  NSString *_status, *_explanation, *_details, *_copied, *_response;
  RFDebugLevel _level;
}

- (instancetype)initWithOperation:(NSString *)operation {
  if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
    _operation = [operation copy];
    [self load];
    self.title = operation ? RFDebugTitle(_record) : @"Last closed";
  }
  return self;
}

- (void)load {
  if (!_operation) {
    _status = RFLastCloseStatus();
    _explanation = @"How Reddit was closed before this launch.";
    _details = RFLastCloseDescription(NO);
    _copied = RFLastCloseDescription(YES);
    return;
  }
  for (NSDictionary *record in [[RFSchemaDebug shared] snapshot])
    if ([record[kRFDebugOp] isEqualToString:_operation]) _record = record;
  _status = RFDebugStatus(_record, &_level);
  _explanation = RFDebugExplanation(_record);
  _details = _copied = RFDebugDetails(_record);
  _response = [_record[kRFDebugDiscovered] length] ? nil : _record[kRFDebugFailedJSON];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
  RFApplySettingsTheme(self.tableView, @selector(setBackgroundColor:), @selector(bodyColor));
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self load];
  [self.tableView reloadData];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  if (section == RFDetailSectionStatus) return 1;
  if (section == RFDetailSectionText) return _details.length ? 1 : 0;
  return (_details.length ? 1 : 0) + (_response.length ? 1 : 0);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  return section == RFDetailSectionText && _details.length ? @"Details" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  if (section != RFDetailSectionCopy) return nil;
  if (_response.length) return @"\"Copy JSON\" copies Reddit's response, which can include usernames and post text.";
  return !_operation && ![_details isEqualToString:_copied] ? @"\"Copy details\" leaves out what was open." : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
  cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
  RFApplySettingsCardTheme(cell);
  cell.textLabel.numberOfLines = cell.detailTextLabel.numberOfLines = 0;
  cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  cell.textLabel.adjustsFontForContentSizeCategory = YES;
  cell.selectionStyle = UITableViewCellSelectionStyleNone;
  switch (indexPath.section) {
    case RFDetailSectionStatus:
      cell.textLabel.text = _status;
      cell.textLabel.textColor = _level == RFDebugLevelNone ? UIColor.labelColor : RFDebugLevelColor(_level);
      if (_level == RFDebugLevelNone) RFApplySettingsTheme(cell.textLabel, @selector(setTextColor:), @selector(bodyTextColor));
      cell.textLabel.accessibilityLabel = RFDebugSpokenStatus(_status);
      cell.detailTextLabel.text = _explanation;
      cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
      cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
      cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
      RFApplySettingsTheme(cell.detailTextLabel, @selector(setTextColor:), @selector(metaTextColor));
      break;
    case RFDetailSectionText:
      cell.textLabel.text = _details;
      cell.textLabel.font = [UIFontMetrics.defaultMetrics scaledFontForFont:[UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular]];
      cell.textLabel.textColor = UIColor.labelColor;
      RFApplySettingsTheme(cell.textLabel, @selector(setTextColor:), @selector(bodyTextColor));
      break;
    default:
      cell.textLabel.text = indexPath.row == 0 ? @"Copy details" : @"Copy JSON";
      cell.textLabel.textColor = UIColor.systemBlueColor;
      cell.selectionStyle = UITableViewCellSelectionStyleDefault;
      cell.accessibilityTraits = UIAccessibilityTraitButton;
  }
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (indexPath.section != RFDetailSectionCopy) return;
  NSString *text = indexPath.row == 0 ? [NSString stringWithFormat:@"%@: %@\n\n%@", self.title, _status, _copied] : _response;
  if (!text.length) return;
  UIPasteboard.generalPasteboard.string = text;
  UILabel *label = [tableView cellForRowAtIndexPath:indexPath].textLabel;
  NSString *title = label.text;
  label.text = @"Copied";
  UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"Copied");
  __weak UILabel *weakLabel = label;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    if ([weakLabel.text isEqualToString:@"Copied"]) weakLabel.text = title;
  });
}

@end
