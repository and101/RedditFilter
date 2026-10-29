#import "KeywordsViewController.h"
#import "Preferences.h"

@interface UIView ()
- (void)associatePropertySetter:(SEL)propertySetter withThemePropertyGetter:(SEL)themePropertyGetter;
@end

// Follows Reddit's light/dark theme when it's available, else keeps the system color.
static void RFTheme(id view, SEL setter, SEL themeGetter) {
  if ([view respondsToSelector:@selector(associatePropertySetter:withThemePropertyGetter:)])
    [view associatePropertySetter:setter withThemePropertyGetter:themeGetter];
}

NSArray<NSString *> *RFSavedKeywords(void) {
  NSMutableArray *keywords = [NSMutableArray array];
  for (id keyword in [NSUserDefaults.standardUserDefaults arrayForKey:kRedditFilterKeywords])
    if ([keyword isKindOfClass:NSString.class]) [keywords addObject:keyword];
  return keywords;
}

typedef NS_ENUM(NSInteger, RFKeywordSection) { RFKeywordSectionAdd, RFKeywordSectionList, RFKeywordSectionClear };

@interface RFKeywordsViewController () <UITextFieldDelegate>
@property(nonatomic, strong) NSMutableArray<NSString *> *keywords;
@property(nonatomic, strong) UITextField *field;
@property(nonatomic, strong) UIButton *addButton;
@end

@implementation RFKeywordsViewController

- (instancetype)init {
  if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
    self.title = @"Keywords";
    _keywords = [RFSavedKeywords() mutableCopy];
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
  RFTheme(self.tableView, @selector(setBackgroundColor:), @selector(canvasColor));
  self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;

  UITextField *field = [UITextField new];
  field.placeholder = @"Add a word or phrase";
  field.returnKeyType = UIReturnKeyDone;
  field.autocapitalizationType = UITextAutocapitalizationTypeNone;
  field.autocorrectionType = UITextAutocorrectionTypeNo;
  field.clearButtonMode = UITextFieldViewModeWhileEditing;
  field.font = [UIFont systemFontOfSize:16.0];
  field.delegate = self;
  [field addTarget:self action:@selector(updateAddButton) forControlEvents:UIControlEventEditingChanged];
  RFTheme(field, @selector(setTextColor:), @selector(bodyTextColor));
  self.field = field;

  UIButton *addButton = [UIButton buttonWithType:UIButtonTypeSystem];
  UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24.0];
  [addButton setImage:[UIImage systemImageNamed:@"plus.circle.fill" withConfiguration:config]
             forState:UIControlStateNormal];
  addButton.accessibilityLabel = @"Add keyword";
  [addButton addTarget:self action:@selector(addFromField) forControlEvents:UIControlEventTouchUpInside];
  self.addButton = addButton;
  [self updateAddButton];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (!self.keywords.count) [self.field becomeFirstResponder];
}

#pragma mark - Saving

- (void)save {
  [NSUserDefaults.standardUserDefaults setObject:self.keywords forKey:kRedditFilterKeywords];
  RFReloadPreferences();
}

- (void)updateAddButton {
  NSString *text = [self.field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  self.addButton.enabled = text.length > 0;
}

// Adds what's in the text field. Commas separate several keywords.
- (void)addFromField {
  NSMutableArray<NSString *> *added = [NSMutableArray array];
  for (NSString *part in [self.field.text componentsSeparatedByString:@","]) {
    // Trim, and turn runs of spaces into one.
    NSArray *words = [[part componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    NSString *keyword = [words componentsJoinedByString:@" "];
    if (!keyword.length || [self indexOfKeyword:keyword inArray:self.keywords] != NSNotFound ||
        [self indexOfKeyword:keyword inArray:added] != NSNotFound)
      continue;
    [added addObject:keyword];
  }
  self.field.text = nil;
  [self updateAddButton];
  if (!added.count) return;

  BOOL wasEmpty = self.keywords.count == 0;
  // Newest first, in the order they were typed.
  [self.keywords insertObjects:added atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, added.count)]];
  [self save];

  [self.tableView performBatchUpdates:^{
    NSMutableArray *rows = [NSMutableArray array];
    for (NSUInteger i = 0; i < added.count; i++)
      [rows addObject:[NSIndexPath indexPathForRow:i inSection:RFKeywordSectionList]];
    if (wasEmpty) {
      [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:RFKeywordSectionList]
                    withRowAnimation:UITableViewRowAnimationFade];
      [self.tableView insertSections:[NSIndexSet indexSetWithIndex:RFKeywordSectionClear]
                    withRowAnimation:UITableViewRowAnimationFade];
    } else {
      [self.tableView insertRowsAtIndexPaths:rows withRowAnimation:UITableViewRowAnimationTop];
    }
  } completion:^(BOOL finished) {
    [self refreshListHeader];
  }];
}

- (NSUInteger)indexOfKeyword:(NSString *)keyword inArray:(NSArray<NSString *> *)array {
  return [array indexOfObjectPassingTest:^BOOL(NSString *existing, NSUInteger i, BOOL *stop) {
    return [existing compare:keyword options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch] ==
           NSOrderedSame;
  }];
}

- (void)removeKeywordAtIndex:(NSUInteger)index {
  if (index >= self.keywords.count) return;
  [self.keywords removeObjectAtIndex:index];
  [self save];
  if (self.keywords.count) {
    [self.tableView deleteRowsAtIndexPaths:@[ [NSIndexPath indexPathForRow:index inSection:RFKeywordSectionList] ]
                          withRowAnimation:UITableViewRowAnimationAutomatic];
    [self refreshListHeader];
  } else {
    [self.tableView reloadData];
  }
}

- (void)confirmClearAll {
  NSString *message = [NSString stringWithFormat:@"All %lu keywords will be removed and those posts will show again.",
                                                 (unsigned long)self.keywords.count];
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear all keywords?"
                                                                 message:message
                                                          preferredStyle:UIAlertControllerStyleActionSheet];
  [alert addAction:[UIAlertAction actionWithTitle:@"Clear All"
                                            style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *action) {
                                            [self.keywords removeAllObjects];
                                            [self save];
                                            [self.tableView reloadData];
                                          }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
  UITableViewCell *clearCell =
      [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:RFKeywordSectionClear]];
  alert.popoverPresentationController.sourceView = clearCell ?: self.view;
  alert.popoverPresentationController.sourceRect = clearCell ? clearCell.bounds : self.view.bounds;
  [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
  if (textField.text.length) [self addFromField];
  else [textField resignFirstResponder];
  return NO;
}

#pragma mark - Table

- (NSString *)listHeaderText {
  return self.keywords.count ? [NSString stringWithFormat:@"Hidden keywords (%lu)", (unsigned long)self.keywords.count]
                             : @"Hidden keywords";
}

- (void)refreshListHeader {
  UITableViewHeaderFooterView *header = [self.tableView headerViewForSection:RFKeywordSectionList];
  header.textLabel.text = self.listHeaderText;
  [header setNeedsLayout];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return self.keywords.count ? 3 : 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  if (section == RFKeywordSectionList) return MAX(self.keywords.count, 1); // 1: the empty message
  return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  return section == RFKeywordSectionList ? self.listHeaderText : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  if (section != RFKeywordSectionAdd) return nil;
  return @"Posts with a keyword in their title or text are hidden from your feeds. Whole words only, and "
         @"capitals don't matter: \"cat\" hides \"Cat pics\" but not \"category\". Separate several with commas.";
}

- (UITableViewCell *)styledCell:(UITableViewCell *)cell {
  cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
  RFTheme(cell, @selector(setBackgroundColor:), @selector(bodyColor));
  return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (indexPath.section == RFKeywordSectionAdd) {
    UITableViewCell *cell = [self styledCell:[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                                    reuseIdentifier:nil]];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ self.field, self.addButton ]];
    row.spacing = 8.0;
    row.alignment = UIStackViewAlignmentCenter;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [self.addButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [cell.contentView addSubview:row];
    UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
      [row.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
      [row.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
      [row.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:6.0],
      [row.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-6.0],
      [row.heightAnchor constraintGreaterThanOrEqualToConstant:36.0],
    ]];
    return cell;
  }

  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"RFKeywordCell"];
  if (!cell) {
    cell = [self styledCell:[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                   reuseIdentifier:@"RFKeywordCell"]];
  }
  cell.textLabel.font = [UIFont systemFontOfSize:16.0];
  cell.textLabel.textAlignment = NSTextAlignmentNatural;
  cell.imageView.image = nil;
  cell.selectionStyle = UITableViewCellSelectionStyleNone;

  if (indexPath.section == RFKeywordSectionClear) {
    cell.textLabel.text = @"Clear All Keywords";
    cell.textLabel.textAlignment = NSTextAlignmentCenter;
    cell.textLabel.textColor = UIColor.systemRedColor;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
  } else if (!self.keywords.count) {
    cell.textLabel.text = @"No keywords yet";
    cell.textLabel.textColor = UIColor.secondaryLabelColor;
    RFTheme(cell.textLabel, @selector(setTextColor:), @selector(metaTextColor));
  } else {
    cell.textLabel.text = self.keywords[indexPath.row];
    cell.textLabel.textColor = UIColor.labelColor;
    RFTheme(cell.textLabel, @selector(setTextColor:), @selector(bodyTextColor));
    cell.imageView.image = [UIImage systemImageNamed:@"eye.slash"];
    cell.imageView.tintColor = UIColor.secondaryLabelColor;
    RFTheme(cell.imageView, @selector(setTintColor:), @selector(metaTextColor));
  }
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (indexPath.section == RFKeywordSectionClear) [self confirmClearAll];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (indexPath.section != RFKeywordSectionList || !self.keywords.count) return nil;
  UIContextualAction *remove =
      [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                              title:@"Remove"
                                            handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
                                              [self removeKeywordAtIndex:indexPath.row];
                                              done(YES);
                                            }];
  remove.image = [UIImage systemImageNamed:@"trash"];
  return [UISwipeActionsConfiguration configurationWithActions:@[ remove ]];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                        point:(CGPoint)point {
  if (indexPath.section != RFKeywordSectionList || !self.keywords.count) return nil;
  NSString *keyword = self.keywords[indexPath.row];
  return [UIContextMenuConfiguration
      configurationWithIdentifier:nil
                  previewProvider:nil
                   actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
                     UIAction *remove = [UIAction actionWithTitle:@"Remove"
                                                            image:[UIImage systemImageNamed:@"trash"]
                                                       identifier:nil
                                                          handler:^(UIAction *action) {
                                                            NSUInteger index = [self.keywords indexOfObject:keyword];
                                                            if (index != NSNotFound) [self removeKeywordAtIndex:index];
                                                          }];
                     remove.attributes = UIMenuElementAttributesDestructive;
                     return [UIMenu menuWithTitle:@"" children:@[ remove ]];
                   }];
}

@end
