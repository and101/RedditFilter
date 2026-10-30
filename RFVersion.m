#import "RFVersion.h"

NSString *RFTweakVersionFromTag(NSString *tag) {
  if ([tag hasPrefix:@"v"]) tag = [tag substringFromIndex:1];
  NSRange dash = [tag rangeOfString:@"-"];
  if (dash.location == NSNotFound) return nil; // e.g. "v2026.43.0": no RedditFilter version
  NSString *version = [tag substringFromIndex:NSMaxRange(dash)];
  return [version rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet].location == 0 ? version : nil;
}

NSString *RFRedditVersionFromTag(NSString *tag) {
  if ([tag hasPrefix:@"v"]) tag = [tag substringFromIndex:1];
  NSRange dash = [tag rangeOfString:@"-"];
  if (dash.location == NSNotFound) return nil;
  NSString *version = [tag substringToIndex:dash.location];
  return [version rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet].location == 0 ? version : nil;
}

// "1.3.2-beta2" -> @[1, 3, 2] and "beta2". Nil if it doesn't start with a number.
static NSArray<NSNumber *> *RFVersionParts(NSString *version, NSString **suffix) {
  NSRange dash = [version rangeOfString:@"-"];
  NSString *numbers = dash.location == NSNotFound ? version : [version substringToIndex:dash.location];
  *suffix = dash.location == NSNotFound ? nil : [version substringFromIndex:NSMaxRange(dash)];
  NSMutableArray *parts = [NSMutableArray array];
  for (NSString *part in [numbers componentsSeparatedByString:@"."]) {
    NSScanner *scanner = [NSScanner scannerWithString:part];
    NSInteger value;
    if (![scanner scanInteger:&value] || !scanner.isAtEnd) return nil;
    [parts addObject:@(value)];
  }
  return parts;
}

BOOL RFVersionIsNewer(NSString *candidate, NSString *current) {
  NSString *candidateSuffix, *currentSuffix;
  NSArray *a = candidate ? RFVersionParts(candidate, &candidateSuffix) : nil;
  NSArray *b = current ? RFVersionParts(current, &currentSuffix) : nil;
  if (!a || !b) return NO;
  for (NSUInteger i = 0; i < MAX(a.count, b.count); i++) {
    NSInteger x = i < a.count ? [a[i] integerValue] : 0, y = i < b.count ? [b[i] integerValue] : 0;
    if (x != y) return x > y;
  }
  // Same numbers: a release is later than its betas, and beta2 later than beta1.
  if (!candidateSuffix || !currentSuffix) return !candidateSuffix && currentSuffix;
  return [candidateSuffix compare:currentSuffix options:NSNumericSearch] == NSOrderedDescending;
}

BOOL RFReleaseIsNewer(NSString *tag, NSString *tweak, NSString *reddit) {
  NSString *releaseTweak = RFTweakVersionFromTag(tag);
  if (!releaseTweak || !RFVersionIsNewer(tweak, @"0")) return NO;
  if (RFVersionIsNewer(releaseTweak, tweak)) return YES;
  if (RFVersionIsNewer(tweak, releaseTweak)) return NO;
  // Same RedditFilter: an update only if it's built for a later Reddit.
  return RFVersionIsNewer(RFRedditVersionFromTag(tag), reddit);
}
