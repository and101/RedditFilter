// SavedPosts.m

#import "SavedPosts.h"
#import "FeedCache.h"

// Enough for hours of scrolling; the oldest go first.
static const NSUInteger kRFSavedPostsLimit = 3000;

@interface RFSavedPost : NSObject
@property(nonatomic, copy) NSString *title; // squashed; nil until its details are seen
@property(nonatomic, copy) NSString *community;
@property(nonatomic) BOOL saved;
@property(nonatomic) unsigned long long order; // when `saved` was asked for, or changed
@end

@implementation RFSavedPost
@end

static NSObject *gLock;
static NSString *gAccount;
static unsigned long long gOrder;
static NSMutableDictionary<NSString *, RFSavedPost *> *gPosts;                // by ID
static NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *gByTitle; // title -> IDs
static NSMutableArray<NSString *> *gIds;                                      // oldest first

__attribute__((constructor)) static void RFSavedPostsInit(void) {
  gLock = [NSObject new];
}

static NSDictionary *RFDictionary(id value) {
  return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static NSString *RFText(id value) {
  return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

static NSDictionary *RFParsed(NSData *data) {
  return data.length ? RFDictionary([NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]) : nil;
}

// The title on one line with single spaces, as the card may lay it out differently.
static NSString *RFSquashedTitle(NSString *title) {
  NSMutableArray *words = [NSMutableArray array];
  for (NSString *word in [title componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet])
    if (word.length) [words addObject:word];
  return words.count ? [words componentsJoinedByString:@" "] : nil;
}

static void RFForgetLocked(void) {
  gPosts = [NSMutableDictionary dictionary];
  gByTitle = [NSMutableDictionary dictionary];
  gIds = [NSMutableArray array];
}

static void RFSetTitleLocked(RFSavedPost *post, NSString *postId, NSString *title) {
  if (post.title == title || [post.title isEqualToString:title]) return;
  if (post.title) {
    [gByTitle[post.title] removeObject:postId];
    if (!gByTitle[post.title].count) [gByTitle removeObjectForKey:post.title];
  }
  post.title = title;
  if (!title) return;
  if (!gByTitle[title]) gByTitle[title] = [NSMutableSet set];
  [gByTitle[title] addObject:postId];
}

static RFSavedPost *RFPostLocked(NSString *postId) {
  RFSavedPost *post = gPosts[postId];
  if (post) return post;
  post = gPosts[postId] = [RFSavedPost new];
  [gIds addObject:postId];
  if (gIds.count > kRFSavedPostsLimit) {
    NSString *oldest = gIds[0];
    RFSetTitleLocked(gPosts[oldest], oldest, nil);
    [gPosts removeObjectForKey:oldest];
    [gIds removeObjectAtIndex:0];
  }
  return post;
}

static BOOL RFIsForCurrentAccountLocked(NSURLRequest *request) {
  return gPosts && [RFFeedAccount(request) ?: @"" isEqualToString:gAccount];
}

unsigned long long RFSavedPostsNoteRequest(NSURLRequest *request) {
  NSString *account = RFFeedAccount(request) ?: @"";
  @synchronized(gLock) {
    if (!gPosts || ![account isEqualToString:gAccount]) {
      gAccount = account;
      RFForgetLocked();
    }
    return ++gOrder;
  }
}

void RFSavedPostsNoteDetails(NSURLRequest *request, NSData *response, unsigned long long order) {
  id posts = RFDictionary(RFParsed(response)[@"data"])[@"postsInfoByIds"];
  if (![posts isKindOfClass:NSArray.class]) return;
  @synchronized(gLock) {
    if (!RFIsForCurrentAccountLocked(request)) return;
    for (id item in posts) {
      NSDictionary *info = RFDictionary(item);
      NSString *postId = RFText(info[@"id"]), *title = RFText(info[@"title"]);
      if (!postId || !title || ![info[@"isSaved"] isKindOfClass:NSNumber.class]) continue;
      RFSavedPost *post = RFPostLocked(postId);
      RFSetTitleLocked(post, postId, RFSquashedTitle(title));
      post.community = RFText(RFDictionary(info[@"subreddit"])[@"name"]);
      if (order < post.order) continue; // changed since this was asked for
      post.order = order;
      post.saved = [info[@"isSaved"] boolValue];
    }
  }
}

void RFSavedPostsNoteChange(NSURLRequest *request, NSData *response) {
  NSDictionary *payload = RFDictionary(RFDictionary(RFParsed(response)[@"data"])[@"updatePostSaveState"]);
  if (![payload[@"ok"] isKindOfClass:NSNumber.class] || ![payload[@"ok"] boolValue]) return;
  NSDictionary *input = RFDictionary(RFDictionary(RFParsed(request.HTTPBody)[@"variables"])[@"input"]);
  NSString *postId = RFText(input[@"postId"]), *state = RFText(input[@"saveState"]);
  if (!postId || !state) return;
  @synchronized(gLock) {
    if (!RFIsForCurrentAccountLocked(request)) return;
    RFSavedPost *post = RFPostLocked(postId);
    post.saved = [state isEqualToString:@"SAVED"];
    post.order = ++gOrder;
  }
}

// Whether a card's label names this community, whole ("r/pic" isn't in "r/pics, ...").
static BOOL RFLabelNamesCommunity(NSString *label, NSString *community) {
  if (!label.length || !community.length) return NO;
  for (NSString *prefix in @[ @"r/", @"r slash " ]) {
    NSString *pattern = [NSString stringWithFormat:@"\\b%@%@(?![A-Za-z0-9_])", prefix,
                                                   [NSRegularExpression escapedPatternForString:community]];
    if ([label rangeOfString:pattern options:NSRegularExpressionSearch | NSCaseInsensitiveSearch].location != NSNotFound)
      return YES;
  }
  return NO;
}

BOOL RFSavedPostsIsSaved(NSString *title, NSString *cardLabel) {
  NSString *squashed = RFSquashedTitle(title);
  if (!squashed) return NO;
  @synchronized(gLock) {
    NSUInteger saved = 0, unsaved = 0, savedHere = 0, unsavedHere = 0;
    for (NSString *postId in gByTitle[squashed]) {
      RFSavedPost *post = gPosts[postId];
      BOOL here = RFLabelNamesCommunity(cardLabel, post.community);
      if (post.saved) saved++, savedHere += here;
      else unsaved++, unsavedHere += here;
    }
    if (!saved || !unsaved) return saved > 0;
    return savedHere && !unsavedHere;
  }
}

void RFSavedPostsForget(void) {
  @synchronized(gLock) {
    gAccount = nil;
    gPosts = nil;
    gByTitle = nil;
    gIds = nil;
  }
}
