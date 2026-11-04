// RFStats.m
//
// See RFStats.h. Counting happens on the network hook's threads, so it only touches memory under a
// lock; saving to NSUserDefaults is batched a few seconds later and done at once when Reddit goes to
// the background.

#import "RFStats.h"
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
  os_unfair_lock_lock(&gLock);
  gSaveScheduled = NO;
  NSDictionary *plist = gSavingDisabled ? nil : RFStatsPlist();
  os_unfair_lock_unlock(&gLock);
  if (plist) [NSUserDefaults.standardUserDefaults setObject:plist forKey:kRFStatsDefaultsKey];
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
