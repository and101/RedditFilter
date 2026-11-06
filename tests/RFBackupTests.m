// Run on macOS: ./tests/run.sh
#import <Foundation/Foundation.h>
#import "PreferenceKeys.h"
#import "RFBackup.h"
#import "RFStats.h"

static void Check(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

static NSData *JSONData(NSDictionary *dictionary) {
  return [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:NULL];
}

static NSMutableDictionary *JSONObject(NSData *data) {
  return [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL];
}

int main(void) {
  @autoreleasepool {
    RFStatsDisableSaving();
    NSString *suite = [@"RFBackupTests-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    NSArray<NSString *> *keys = RFBackupSettingKeys();
    NSError *error = nil;

    // Round trip: every setting, the keywords and the stats.
    NSMutableDictionary<NSString *, NSNumber *> *saved = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < keys.count; i++) {
      BOOL value = i % 2 == 0;
      saved[keys[i]] = @(value);
      [defaults setBool:value forKey:keys[i]];
    }
    NSArray *keywords = @[ @"Café", @"new york" ];
    [defaults setObject:keywords forKey:kRedditFilterKeywords];

    NSDictionary *seedStats = @{
      @"counts" : @{@"feedAds" : @4, @"nsfw" : @2, @"keywordComments" : @1},
      @"days" : @{@"2026-01-01" : @3, @"2026-01-02" : @4},
      @"since" : @"2026-01-01T12:00:00Z",
    };
    Check(RFStatsImport(seedStats, &error), @"seed stats import");

    NSData *data = RFBackupExport(defaults);
    Check(data.length > 0, @"export produces data");
    RFBackupSummary *summary = RFBackupParse(data, &error);
    Check(summary != nil, @"parse an exported backup");
    Check(summary.settingCount == keys.count, @"summary has every setting");
    Check(summary.keywordCount == 2, @"summary has the keywords");
    Check(summary.totalHidden == 7, @"summary totals the counts");

    for (NSString *key in keys) [defaults setBool:!saved[key].boolValue forKey:key];
    [defaults setObject:@[ @"gone" ] forKey:kRedditFilterKeywords];
    RFStatsReset();

    Check(RFBackupApply(summary, defaults, &error), @"apply the round-trip backup");
    for (NSString *key in keys)
      Check([defaults boolForKey:key] == saved[key].boolValue, ([NSString stringWithFormat:@"restored %@", key]));
    Check([[defaults arrayForKey:kRedditFilterKeywords] isEqual:keywords], @"restored keywords");

    NSDictionary *snapshot = RFStatsSnapshot();
    NSArray<NSNumber *> *counts = snapshot[kRFStatsCounts];
    Check(counts[RFStatFeedAds].unsignedLongLongValue == 4 && counts[RFStatNSFW].unsignedLongLongValue == 2 &&
              counts[RFStatKeywordComments].unsignedLongLongValue == 1 &&
              counts[RFStatRecommended].unsignedLongLongValue == 0,
          @"snapshot reflects the imported counts");
    Check([snapshot[kRFStatsDays] isEqual:seedStats[@"days"]], @"snapshot reflects the imported days");
    Check(fabs([snapshot[kRFStatsSince] timeIntervalSince1970] - 1767268800.0) < 1.0,
          @"snapshot reflects the imported since date");

    // Every #define in PreferenceKeys.h must be carried by a backup.
    NSString *header = [NSString stringWithContentsOfFile:@"PreferenceKeys.h"
                                                 encoding:NSUTF8StringEncoding
                                                    error:&error];
    Check(header.length > 0, @"read PreferenceKeys.h");
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"#define\\s+(kRedditFilter\\w+)\\s+@\"([^\"]+)\""
                                                                           options:0
                                                                             error:&error];
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:header options:0 range:NSMakeRange(0, header.length)];
    Check(matches.count > 0, @"found setting keys in PreferenceKeys.h");
    for (NSTextCheckingResult *match in matches) {
      NSString *name = [header substringWithRange:[match rangeAtIndex:1]];
      NSString *key = [header substringWithRange:[match rangeAtIndex:2]];
      Check(RFBackupHandlesKey(key), ([NSString stringWithFormat:@"backup includes %@", name]));
    }

    // A bad stats section rejects the whole file and changes nothing.
    BOOL wasPromoted = [defaults boolForKey:kRedditFilterPromoted];
    NSDictionary *badStats = @{
      @"format" : @"RedditFilterSettings",
      @"version" : @1,
      @"exportedAt" : @"2026-01-01T00:00:00Z",
      @"redditFilterVersion" : @"1.3.6",
      @"settings" : @{kRedditFilterPromoted : [NSNumber numberWithBool:!wasPromoted]},
      @"keywords" : @[],
      @"stats" : @{@"counts" : @{@"feedAds" : @(-1)}},
    };
    error = nil;
    Check(RFBackupParse(JSONData(badStats), &error) == nil && error != nil, @"reject negative stats");
    Check([defaults boolForKey:kRedditFilterPromoted] == wasPromoted, @"bad file changes nothing");

    // A day key is only a label, so it must parse whatever the device's time zone is.
    NSTimeZone *savedZone = NSTimeZone.defaultTimeZone;
    [NSTimeZone setDefaultTimeZone:[NSTimeZone timeZoneWithName:@"America/Havana"]];
    NSError *dayError = nil;
    Check(RFStatsValidate(@{@"days" : @{@"2026-03-08" : @1}}, &dayError),
          @"accept a day key whose midnight is missing in the device's time zone");
    [NSTimeZone setDefaultTimeZone:savedZone];

    // A count is neither a JSON boolean nor a number too large for uint64_t.
    error = nil;
    Check(!RFStatsValidate(@{@"counts" : @{@"feedAds" : @YES}}, &error), @"reject boolean stat counts");
    error = nil;
    Check(!RFStatsValidate(@{@"counts" : @{@"feedAds" : @(1e30)}}, &error),
          @"reject stat counts too large for uint64_t");

    // A newer file is refused.
    NSMutableDictionary *newer = JSONObject(data);
    newer[@"version"] = @2;
    error = nil;
    Check(RFBackupParse(JSONData(newer), &error) == nil, @"reject a newer version");

    // An older backup with missing keys leaves the others alone.
    NSDictionary *partial = @{
      @"format" : @"RedditFilterSettings",
      @"version" : @1,
      @"exportedAt" : @"2026-01-01T00:00:00Z",
      @"settings" : @{kRedditFilterPromoted : [NSNumber numberWithBool:!wasPromoted]},
    };
    RFBackupSummary *partialSummary = RFBackupParse(JSONData(partial), &error);
    Check(partialSummary != nil, @"parse an older backup");
    BOOL otherBefore = [defaults boolForKey:kRedditFilterNSFW];
    Check(RFBackupApply(partialSummary, defaults, &error), @"apply an older backup");
    Check([defaults boolForKey:kRedditFilterPromoted] == !wasPromoted, @"missing-key backup changes its keys");
    Check([defaults boolForKey:kRedditFilterNSFW] == otherBefore, @"missing keys stay unchanged");
    Check([[defaults arrayForKey:kRedditFilterKeywords] isEqual:keywords], @"missing keywords stay unchanged");

    // Both swipe sides off is fixed to left, as the switches do.
    NSDictionary *noSwipe = @{
      @"format" : @"RedditFilterSettings",
      @"version" : @1,
      @"settings" : @{
        kRedditFilterSwipeLeftToCollapse : @NO,
        kRedditFilterSwipeRightToCollapse : @NO,
      },
    };
    RFBackupSummary *noSwipeSummary = RFBackupParse(JSONData(noSwipe), &error);
    Check(noSwipeSummary != nil, @"parse a backup with no swipe side");
    Check(RFBackupApply(noSwipeSummary, defaults, &error), @"apply a backup with no swipe side");
    Check([defaults boolForKey:kRedditFilterSwipeLeftToCollapse], @"fixes both swipe sides off");
    Check(![defaults boolForKey:kRedditFilterSwipeRightToCollapse], @"leaves the other swipe side off");

    // Unknown settings and stat names are ignored.
    NSDictionary *unknown = @{
      @"format" : @"RedditFilterSettings",
      @"version" : @1,
      @"settings" : @{@"kRedditFilterFuture" : @YES},
      @"stats" : @{@"counts" : @{@"futureStat" : @9}},
    };
    NSError *unknownError = nil;
    RFBackupSummary *unknownSummary = RFBackupParse(JSONData(unknown), &unknownError);
    Check(unknownSummary != nil, @"parse unknown keys");
    Check(RFBackupApply(unknownSummary, defaults, &unknownError), @"apply unknown keys");
    Check([defaults objectForKey:@"kRedditFilterFuture"] == nil, @"unknown setting is not written");
    NSArray<NSNumber *> *afterUnknown = RFStatsSnapshot()[kRFStatsCounts];
    Check(afterUnknown[RFStatFeedAds].unsignedLongLongValue == 0,
          @"unknown stat name does not add a count");

    // A JSON number that isn't a boolean is not a setting value.
    NSDictionary *numberSetting = @{
      @"format" : @"RedditFilterSettings",
      @"version" : @1,
      @"settings" : @{kRedditFilterPromoted : @1},
    };
    error = nil;
    Check(RFBackupParse(JSONData(numberSetting), &error) == nil, @"reject non-boolean settings values");

    // Importing more days than the app keeps drops the oldest ones.
    NSMutableDictionary<NSString *, NSNumber *> *manyDays = [NSMutableDictionary dictionary];
    NSDateFormatter *dayFormatter = [NSDateFormatter new];
    dayFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    dayFormatter.dateFormat = @"yyyy-MM-dd";
    dayFormatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSDate *start = [dayFormatter dateFromString:@"2026-01-01"];
    for (NSInteger i = 0; i < 40; i++)
      manyDays[[dayFormatter stringFromDate:[start dateByAddingTimeInterval:i * 86400]]] = @(i);
    error = nil;
    Check(RFStatsImport(@{@"days" : manyDays}, &error), @"import 40 days");
    NSDictionary *keptDays = RFStatsSnapshot()[kRFStatsDays];
    Check(keptDays.count == 30, @"import keeps the latest 30 days");
    Check(keptDays[@"2026-01-11"] != nil && keptDays[@"2026-01-10"] == nil, @"import drops the oldest days");

    [defaults removePersistentDomainForName:suite];
    NSLog(@"RFBackupTests passed");
  }
  return 0;
}
