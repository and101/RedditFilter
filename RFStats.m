// RFStats.m
//
// See RFStats.h. Counting happens on the network hook's threads, so it only touches memory under a
// lock; saving to NSUserDefaults is batched a few seconds later and done at once when Reddit goes to
// the background.

#import "RFStats.h"
#import <math.h>
#import <os/lock.h>

NSString *const kRFStatsCounts = @"counts";
NSString *const kRFStatsDays = @"days";
NSString *const kRFStatsSince = @"since";
NSString *const RFStatsDidChangeNotification = @"RFStatsDidChangeNotification";

static NSString *const kRFStatsDefaultsKey = @"kRedditFilterStats";
// Stored by name, so reordering RFStat never mixes up saved counts.
static NSString *const kRFStatNames[RFStatCount] = {
    @"feedAds", @"commentAds", @"recommended", @"videosForYou", @"nsfw", @"keywordPosts", @"keywordComments",
    @"extraCards",
};
static const NSUInteger kRFDaysKept = 30;
static const NSUInteger kRFSeenLimit = 5000; // IDs remembered for counting once per launch
static const double kRFSaveDelay = 3.0;

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock gSaveLock = OS_UNFAIR_LOCK_INIT;
static BOOL gLoaded, gSaveScheduled, gSavingDisabled;
static uint64_t gCounts[RFStatCount];
static NSMutableDictionary<NSString *, NSNumber *> *gDays;
static NSDate *gSince;
static NSMutableSet<NSString *> *gSeen;

NSString *RFStatsDayKey(NSDate *date) {
  NSDateComponents *parts = [NSCalendar.currentCalendar components:NSCalendarUnitYear | NSCalendarUnitMonth |
                                                                   NSCalendarUnitDay
                                                          fromDate:date];
  return [NSString stringWithFormat:@"%04ld-%02ld-%02ld", (long)parts.year, (long)parts.month, (long)parts.day];
}

static NSDictionary *RFStatsPlist(void); // caller holds gLock

static void RFStatsSave(void) {
  // Serialise snapshots and writes; always take gSaveLock before gLock.
  os_unfair_lock_lock(&gSaveLock);
  os_unfair_lock_lock(&gLock);
  gSaveScheduled = NO;
  NSDictionary *plist = gSavingDisabled ? nil : RFStatsPlist();
  os_unfair_lock_unlock(&gLock);
  if (plist) [NSUserDefaults.standardUserDefaults setObject:plist forKey:kRFStatsDefaultsKey];
  os_unfair_lock_unlock(&gSaveLock);
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSNotificationCenter.defaultCenter postNotificationName:RFStatsDidChangeNotification object:nil];
  });
}

// Caller holds gLock.
static void RFStatsLoad(void) {
  if (gLoaded) return;
  gLoaded = YES;
  gDays = [NSMutableDictionary dictionary];
  gSeen = [NSMutableSet set];
  NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:kRFStatsDefaultsKey];
  NSDictionary *counts = [saved[kRFStatsCounts] isKindOfClass:NSDictionary.class] ? saved[kRFStatsCounts] : nil;
  for (NSInteger i = 0; i < RFStatCount; i++) {
    id value = counts[kRFStatNames[i]];
    gCounts[i] = [value isKindOfClass:NSNumber.class] ? [value unsignedLongLongValue] : 0;
  }
  NSDictionary *days = [saved[kRFStatsDays] isKindOfClass:NSDictionary.class] ? saved[kRFStatsDays] : nil;
  for (id day in days)
    if ([day isKindOfClass:NSString.class] && [days[day] isKindOfClass:NSNumber.class]) gDays[day] = days[day];
  gSince = [saved[kRFStatsSince] isKindOfClass:NSDate.class] ? saved[kRFStatsSince] : [NSDate date];

  // Save straight away when Reddit goes to the background, where iOS may close it. Named rather than
  // imported so this file stays Foundation only.
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSNotificationCenter.defaultCenter addObserverForName:@"UIApplicationDidEnterBackgroundNotification"
                                                    object:nil
                                                     queue:nil
                                                usingBlock:^(NSNotification *note) {
                                                  os_unfair_lock_lock(&gLock);
                                                  BOOL pending = gSaveScheduled;
                                                  os_unfair_lock_unlock(&gLock);
                                                  if (pending) RFStatsSave();
                                                }];
  });
}

// Caller holds gLock.
static NSDictionary *RFStatsPlist(void) {
  NSMutableDictionary *counts = [NSMutableDictionary dictionary];
  for (NSInteger i = 0; i < RFStatCount; i++) counts[kRFStatNames[i]] = @(gCounts[i]);
  return @{kRFStatsCounts : counts, kRFStatsDays : [gDays copy], kRFStatsSince : gSince};
}

// Caller holds gLock.
static void RFStatsScheduleSave(void) {
  if (gSaveScheduled) return;
  gSaveScheduled = YES;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRFSaveDelay * NSEC_PER_SEC)),
                 dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ RFStatsSave(); });
}

// Caller holds gLock. Keeps the last kRFDaysKept days.
static void RFStatsPruneDays(NSString *today) {
  if (gDays.count <= kRFDaysKept) return;
  NSArray *sorted = [gDays.allKeys sortedArrayUsingSelector:@selector(compare:)];
  for (NSUInteger i = 0; i + kRFDaysKept < sorted.count; i++)
    if (![sorted[i] isEqualToString:today]) [gDays removeObjectForKey:sorted[i]];
}

void RFStatsRecord(RFStat stat, NSString *identifier) {
  if (stat < 0 || stat >= RFStatCount) return;
  NSString *today = RFStatsDayKey([NSDate date]);
  os_unfair_lock_lock(&gLock);
  RFStatsLoad();
  BOOL counted = YES;
  if (identifier.length) {
    NSString *key = [NSString stringWithFormat:@"%ld:%@", (long)stat, identifier];
    if ([gSeen containsObject:key]) {
      counted = NO;
    } else {
      if (gSeen.count >= kRFSeenLimit) [gSeen removeAllObjects];
      [gSeen addObject:key];
    }
  }
  if (counted) {
    gCounts[stat]++;
    gDays[today] = @(gDays[today].unsignedLongLongValue + 1);
    RFStatsPruneDays(today);
    RFStatsScheduleSave();
  }
  os_unfair_lock_unlock(&gLock);
}

NSDictionary *RFStatsSnapshot(void) {
  os_unfair_lock_lock(&gLock);
  RFStatsLoad();
  NSMutableArray *counts = [NSMutableArray arrayWithCapacity:RFStatCount];
  for (NSInteger i = 0; i < RFStatCount; i++) [counts addObject:@(gCounts[i])];
  NSDictionary *snapshot = @{kRFStatsCounts : counts, kRFStatsDays : [gDays copy], kRFStatsSince : gSince};
  os_unfair_lock_unlock(&gLock);
  return snapshot;
}

#pragma mark - Settings backup

static NSError *RFStatsBackupError(NSString *message) {
  return [NSError errorWithDomain:@"RedditFilterStats"
                             code:1
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

// A count must be a whole number, not a boolean, not a negative one, not a NaN or infinity, and
// small enough to fit in uint64_t.
static BOOL RFStatsIsCount(id value) {
  if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID())
    return NO;
  double number = [value doubleValue];
  return isfinite(number) && number >= 0 && number == floor(number) && number < 18446744073709551616.0;
}

static BOOL RFStatsIsDayKey(id key) {
  if (![key isKindOfClass:NSString.class] || [key length] != 10) return NO;
  static NSDateFormatter *formatter;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd";
    formatter.lenient = NO;
    // A day key is only a label, so parse it in UTC: a day whose midnight doesn't exist in the
    // device's time zone would otherwise be refused.
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  });
  NSDate *date = [formatter dateFromString:key];
  return date && [[formatter stringFromDate:date] isEqualToString:key];
}

static NSDate *RFStatsDateFromISOString(id string) {
  if (![string isKindOfClass:NSString.class]) return nil;
  static NSISO8601DateFormatter *plain, *fractional;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    plain = [NSISO8601DateFormatter new];
    fractional = [NSISO8601DateFormatter new];
    fractional.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
  });
  return [plain dateFromString:string] ?: [fractional dateFromString:string];
}

NSDictionary *RFStatsExport(void) {
  NSDictionary *snapshot = RFStatsSnapshot();
  NSArray<NSNumber *> *counts = snapshot[kRFStatsCounts];
  NSMutableDictionary *byName = [NSMutableDictionary dictionaryWithCapacity:RFStatCount];
  for (NSInteger i = 0; i < RFStatCount; i++) byName[kRFStatNames[i]] = counts[i] ?: @0;
  NSString *since = [[NSISO8601DateFormatter new] stringFromDate:snapshot[kRFStatsSince]] ?: @"";
  return @{kRFStatsCounts : byName, kRFStatsDays : snapshot[kRFStatsDays] ?: @{}, kRFStatsSince : since};
}

BOOL RFStatsValidate(NSDictionary *stats, NSError **error) {
  if (![stats isKindOfClass:NSDictionary.class]) {
    if (error) *error = RFStatsBackupError(@"The stats in this backup are damaged.");
    return NO;
  }

  id counts = stats[kRFStatsCounts];
  if (counts) {
    if (![counts isKindOfClass:NSDictionary.class]) {
      if (error) *error = RFStatsBackupError(@"The stats in this backup are damaged.");
      return NO;
    }
    for (id name in counts) {
      if (![name isKindOfClass:NSString.class] || !RFStatsIsCount(counts[name])) {
        if (error) *error = RFStatsBackupError(@"The stats in this backup are damaged.");
        return NO;
      }
    }
  }

  id days = stats[kRFStatsDays];
  if (days) {
    if (![days isKindOfClass:NSDictionary.class]) {
      if (error) *error = RFStatsBackupError(@"The stats in this backup are damaged.");
      return NO;
    }
    for (id day in days) {
      if (!RFStatsIsDayKey(day) || !RFStatsIsCount(days[day])) {
        if (error) *error = RFStatsBackupError(@"The daily stats in this backup are damaged.");
        return NO;
      }
    }
  }

  id since = stats[kRFStatsSince];
  if (since && !RFStatsDateFromISOString(since)) {
    if (error) *error = RFStatsBackupError(@"The stats in this backup have an invalid start date.");
    return NO;
  }
  return YES;
}

BOOL RFStatsImport(NSDictionary *stats, NSError **error) {
  if (!RFStatsValidate(stats, error)) return NO;

  uint64_t counts[RFStatCount] = {0};
  NSDictionary *savedCounts = stats[kRFStatsCounts];
  for (NSInteger i = 0; i < RFStatCount; i++) {
    id value = savedCounts[kRFStatNames[i]];
    if (value) counts[i] = [value unsignedLongLongValue];
  }
  NSDictionary *savedDays = stats[kRFStatsDays];
  NSDate *since = RFStatsDateFromISOString(stats[kRFStatsSince]) ?: [NSDate date];

  os_unfair_lock_lock(&gLock);
  RFStatsLoad();
  memcpy(gCounts, counts, sizeof(counts));
  [gDays removeAllObjects];
  for (NSString *day in savedDays) gDays[day] = @([savedDays[day] unsignedLongLongValue]);
  [gSeen removeAllObjects];
  gSince = since;
  // An old or hand-made backup can hold more days than the app keeps.
  RFStatsPruneDays(RFStatsDayKey([NSDate date]));
  os_unfair_lock_unlock(&gLock);

  RFStatsSave();
  return YES;
}

void RFStatsReset(void) {
  os_unfair_lock_lock(&gLock);
  RFStatsLoad();
  memset(gCounts, 0, sizeof(gCounts));
  [gDays removeAllObjects];
  [gSeen removeAllObjects];
  gSince = [NSDate date];
  os_unfair_lock_unlock(&gLock);
  RFStatsSave();
}

void RFStatsDisableSaving(void) {
  os_unfair_lock_lock(&gLock);
  gSavingDisabled = YES;
  os_unfair_lock_unlock(&gLock);
}
