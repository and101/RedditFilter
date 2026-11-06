// RFBackup.h
//
// Settings backup for RedditFilter: every setting, the keywords and the stats, as one JSON file.
// Foundation only, so the macOS tests can use the same code as the app.

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Every setting key that is stored as a BOOL. Exposed so the app and the tests agree on the list.
NSArray<NSString *> *RFBackupSettingKeys(void);

// YES for every key a backup carries, including the keywords.
BOOL RFBackupHandlesKey(NSString *key);

// Pretty-printed, sorted-key JSON for `defaults`.
NSData *RFBackupExport(NSUserDefaults *defaults);

#ifdef __cplusplus
}
#endif

// What a backup holds, for the import confirmation.
@interface RFBackupSummary : NSObject
@property(nonatomic, readonly) NSDate *exportedAt;
@property(nonatomic, readonly) NSUInteger settingCount;
@property(nonatomic, readonly) NSUInteger keywordCount;
@property(nonatomic, readonly) unsigned long long totalHidden;
@end

#ifdef __cplusplus
extern "C" {
#endif

// Parses and fully validates a backup without changing anything. Nil, with a user-facing error,
// if the file isn't a RedditFilter backup or is damaged.
RFBackupSummary *RFBackupParse(NSData *data, NSError **error);

// Writes a parsed backup to `defaults` and the stats. Validates again before writing anything, so
// it either applies everything or changes nothing. Keys missing from the file stay as they are.
BOOL RFBackupApply(RFBackupSummary *summary, NSUserDefaults *defaults, NSError **error);

#ifdef __cplusplus
}
#endif
