// RFBackup.m
//
// See RFBackup.h. Parsing is separate from applying so the settings screen can show what a file
// holds, and refuse a bad one, before anything is replaced.

#import "RFBackup.h"
#import "PreferenceKeys.h"
#import "RFStats.h"
#import <math.h>

#ifndef RF_VERSION
#define RF_VERSION "dev"
#endif

static NSString *const kRFBackupFormat = @"RedditFilterSettings";
static const NSInteger kRFBackupVersion = 1;
static const NSUInteger kRFBackupMaxBytes = 5 * 1024 * 1024;

// Every BOOL setting. Keep in step with PreferenceKeys.h (RFBackupTests checks this).
static NSString *const kRFBackupSettingKeys[] = {
    kRedditFilterPromoted,
    kRedditFilterRecommended,
    kRedditFilterNSFW,
    kRedditFilterAwards,
    kRedditFilterScores,
    kRedditFilterAutoCollapseAutoMod,
    kRedditFilterSwipeToCollapse,
    kRedditFilterSwipeCollapseHaptics,
    kRedditFilterTapToCollapse,
    kRedditFilterSwipeLeftToCollapse,
    kRedditFilterSwipeRightToCollapse,
    kRedditFilterVideosForYou,
    kRedditFilterExtraCards,
    kRedditFilterKeywordComments,
    kRedditFilterKeywordCommentReplies,
    kRedditFilterRedgifsDirect,
    kRedditFilterRedgifsHD,
    kRedditFilterRedgifsHDWiFiOnly,
    kRedditFilterColoredComments,
    kRedditFilterColoredCommentsApollo,
    kRedditFilterHideLinkPanel,
    kRedditFilterKeepFeedPosition,
    kRedditFilterRestoreScreens,
    kRedditFilterRestoreAfterSwipe,
    kRedditFilterSafariLinks,
    kRedditFilterCheckUpdates,
    kRedditFilterDiagnostics,
};
static const NSInteger kRFBackupSettingKeyCount = sizeof(kRFBackupSettingKeys) / sizeof(kRFBackupSettingKeys[0]);

@interface RFBackupSummary ()
@property(nonatomic, copy) NSDictionary<NSString *, NSNumber *> *settings;
@property(nonatomic, copy) NSArray<NSString *> *keywords;
@property(nonatomic, copy) NSDictionary *stats;
@property(nonatomic) BOOL hasKeywords;
@property(nonatomic) BOOL hasStats;
@property(nonatomic, readwrite) NSDate *exportedAt;
@property(nonatomic, readwrite) NSUInteger settingCount;
@property(nonatomic, readwrite) NSUInteger keywordCount;
@property(nonatomic, readwrite) unsigned long long totalHidden;
@end

@implementation RFBackupSummary
@end

static NSError *RFBackupError(NSString *message) {
  return [NSError errorWithDomain:@"RedditFilterBackup"
                             code:1
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

// JSON booleans are CFBoolean; the number 1 and the string "true" are not.
static BOOL RFBackupIsBoolean(id value) {
  return value && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL RFBackupIsInteger(id value) {
  if (![value isKindOfClass:NSNumber.class] || RFBackupIsBoolean(value)) return NO;
  double number = [value doubleValue];
  return isfinite(number) && number == floor(number);
}

static NSDate *RFBackupDateFromString(id string) {
  if (![string isKindOfClass:NSString.class]) return nil;
  NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
  return [formatter dateFromString:string];
}

// Same trimming as KeywordsViewController: runs of spaces become one, and empty parts go.
static NSString *RFBackupCleanKeyword(NSString *keyword) {
  NSArray *words = [[keyword componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
      filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
  return [words componentsJoinedByString:@" "];
}

static BOOL RFBackupSameKeyword(NSString *a, NSString *b) {
  return [a compare:b options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch] == NSOrderedSame;
}

// Settings that are a number from a short list rather than on or off.
static NSArray<NSNumber *> *RFBackupAllowedNumbers(NSString *key) {
  if ([key isEqualToString:kRedditFilterRestoreHours]) return @[ @0, @12, @24 ];
  return nil;
}

NSArray<NSString *> *RFBackupSettingKeys(void) {
  static NSArray *keys;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    keys = [NSArray arrayWithObjects:kRFBackupSettingKeys count:kRFBackupSettingKeyCount];
  });
  return keys;
}

BOOL RFBackupHandlesKey(NSString *key) {
  if ([key isEqualToString:kRedditFilterKeywords] || RFBackupAllowedNumbers(key)) return YES;
  return [RFBackupSettingKeys() containsObject:key];
}

NSData *RFBackupExport(NSUserDefaults *defaults) {
  NSMutableDictionary *settings = [NSMutableDictionary dictionaryWithCapacity:kRFBackupSettingKeyCount];
  for (NSString *key in RFBackupSettingKeys()) settings[key] = @([defaults boolForKey:key]);
  settings[kRedditFilterRestoreHours] = @([defaults integerForKey:kRedditFilterRestoreHours]);

  NSMutableArray *keywords = [NSMutableArray array];
  for (id keyword in [defaults arrayForKey:kRedditFilterKeywords])
    if ([keyword isKindOfClass:NSString.class]) [keywords addObject:keyword];

  NSDictionary *backup = @{
    @"format" : kRFBackupFormat,
    @"version" : @(kRFBackupVersion),
    @"exportedAt" : [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]],
    @"redditFilterVersion" : @RF_VERSION,
    @"settings" : settings,
    @"keywords" : keywords,
    @"stats" : RFStatsExport() ?: @{},
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:backup
                                                 options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                   error:NULL];
  return data;
}

RFBackupSummary *RFBackupParse(NSData *data, NSError **error) {
  if (data.length > kRFBackupMaxBytes) {
    if (error) *error = RFBackupError(@"This backup is too large to import.");
    return nil;
  }
  if (!data.length) {
    if (error) *error = RFBackupError(@"This file is empty.");
    return nil;
  }

  id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
  if (![json isKindOfClass:NSDictionary.class]) {
    if (error) *error = RFBackupError(@"This file isn't a RedditFilter backup.");
    return nil;
  }

  if (![json[@"format"] isKindOfClass:NSString.class] || ![json[@"format"] isEqualToString:kRFBackupFormat]) {
    if (error) *error = RFBackupError(@"This file isn't a RedditFilter backup.");
    return nil;
  }

  id version = json[@"version"];
  if (!RFBackupIsInteger(version) || [version integerValue] < 1) {
    if (error) *error = RFBackupError(@"This backup is damaged.");
    return nil;
  }
  if ([version integerValue] > kRFBackupVersion) {
    if (error) *error = RFBackupError(@"This backup was made by a newer version of RedditFilter.");
    return nil;
  }

  id exportedAtValue = json[@"exportedAt"];
  NSDate *exportedAt = nil;
  if (exportedAtValue) {
    exportedAt = RFBackupDateFromString(exportedAtValue);
    if (!exportedAt) {
      if (error) *error = RFBackupError(@"This backup's date is damaged.");
      return nil;
    }
  }

  if (json[@"redditFilterVersion"] && ![json[@"redditFilterVersion"] isKindOfClass:NSString.class]) {
    if (error) *error = RFBackupError(@"This backup is damaged.");
    return nil;
  }

  id settings = json[@"settings"] ?: @{};
  if (![settings isKindOfClass:NSDictionary.class]) {
    if (error) *error = RFBackupError(@"The settings in this backup are damaged.");
    return nil;
  }
  NSMutableDictionary *knownSettings = [NSMutableDictionary dictionary];
  for (id key in settings) {
    if (![key isKindOfClass:NSString.class]) {
      if (error) *error = RFBackupError(@"The settings in this backup are damaged.");
      return nil;
    }
    // Unknown keys are ignored, so a newer backup still loads here.
    if (!RFBackupHandlesKey(key) || [key isEqualToString:kRedditFilterKeywords]) continue;
    id value = settings[key];
    NSArray<NSNumber *> *allowed = RFBackupAllowedNumbers(key);
    if (allowed) {
      if (!RFBackupIsInteger(value) || ![allowed containsObject:@([value integerValue])]) {
        if (error) *error = RFBackupError(@"The settings in this backup are damaged.");
        return nil;
      }
      knownSettings[key] = @([value integerValue]);
      continue;
    }
    if (!RFBackupIsBoolean(value)) {
      if (error) *error = RFBackupError(@"The settings in this backup are damaged.");
      return nil;
    }
    knownSettings[key] = @([value boolValue]);
  }

  BOOL hasKeywords = json[@"keywords"] != nil;
  NSMutableArray<NSString *> *keywords = [NSMutableArray array];
  if (hasKeywords) {
    id saved = json[@"keywords"];
    if (![saved isKindOfClass:NSArray.class]) {
      if (error) *error = RFBackupError(@"The keywords in this backup are damaged.");
      return nil;
    }
    for (id keyword in saved) {
      if (![keyword isKindOfClass:NSString.class]) {
        if (error) *error = RFBackupError(@"The keywords in this backup are damaged.");
        return nil;
      }
      NSString *clean = RFBackupCleanKeyword(keyword);
      if (!clean.length) continue;
      BOOL duplicate = NO;
      for (NSString *existing in keywords)
        if (RFBackupSameKeyword(existing, clean)) {
          duplicate = YES;
          break;
        }
      if (!duplicate) [keywords addObject:clean];
    }
  }

  BOOL hasStats = json[@"stats"] != nil;
  NSDictionary *stats = json[@"stats"];
  if (hasStats) {
    NSError *statsError = nil;
    if (![stats isKindOfClass:NSDictionary.class] || !RFStatsValidate(stats, &statsError)) {
      if (error) *error = statsError ?: RFBackupError(@"The stats in this backup are damaged.");
      return nil;
    }
  }

  RFBackupSummary *summary = [RFBackupSummary new];
  summary.exportedAt = exportedAt;
  summary.settings = knownSettings;
  summary.settingCount = knownSettings.count;
  summary.keywords = keywords;
  summary.hasKeywords = hasKeywords;
  summary.keywordCount = keywords.count;
  summary.stats = stats;
  summary.hasStats = hasStats;
  unsigned long long total = 0;
  for (NSNumber *count in [stats[kRFStatsCounts] allValues]) total += count.unsignedLongLongValue;
  summary.totalHidden = total;
  return summary;
}

BOOL RFBackupApply(RFBackupSummary *summary, NSUserDefaults *defaults, NSError **error) {
  if (!summary) {
    if (error) *error = RFBackupError(@"There's nothing to import.");
    return NO;
  }
  // Validate everything before the first write, so a bad file can't leave half a restore.
  if (summary.hasStats && !RFStatsValidate(summary.stats, error)) return NO;

  for (NSString *key in summary.settings) {
    if (RFBackupAllowedNumbers(key)) [defaults setInteger:summary.settings[key].integerValue forKey:key];
    else [defaults setBool:summary.settings[key].boolValue forKey:key];
  }
  if (summary.hasKeywords) [defaults setObject:summary.keywords forKey:kRedditFilterKeywords];

  // Swiping needs a side, just as when the switches are changed by hand.
  if (![defaults boolForKey:kRedditFilterSwipeLeftToCollapse] &&
      ![defaults boolForKey:kRedditFilterSwipeRightToCollapse])
    [defaults setBool:YES forKey:kRedditFilterSwipeLeftToCollapse];

  if (summary.hasStats) return RFStatsImport(summary.stats, error);
  return YES;
}
