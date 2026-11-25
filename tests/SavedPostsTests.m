// Run with ./tests/run.sh
//
// Which posts are saved, for Swipe posts' "Unsave" (SavedPosts.m).
#import <Foundation/Foundation.h>
#import "SavedPosts.h"

static void Check(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

static NSData *JSON(id object) { return [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL]; }

static NSURLRequest *Request(NSString *account, NSDictionary *variables) {
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://gql-fed.reddit.com/"]];
  NSString *claims = [NSString stringWithFormat:@"{\"sub\":\"user\",\"lid\":\"%@\"}", account];
  NSString *encoded = [[claims dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
  [request setValue:[NSString stringWithFormat:@"Bearer e30.%@.s", [encoded stringByReplacingOccurrencesOfString:@"=" withString:@""]]
      forHTTPHeaderField:@"Authorization"];
  request.HTTPBody = JSON(@{@"variables" : variables ?: @{}});
  return request;
}

static NSDictionary *Post(NSString *postId, NSString *title, id community, BOOL saved) {
  return @{@"id" : postId, @"title" : title, @"isSaved" : @(saved),
           @"subreddit" : community ? @{@"name" : community} : (id)NSNull.null};
}

static NSData *Details(NSArray *posts) { return JSON(@{@"data" : @{@"postsInfoByIds" : posts}}); }

static void Load(NSString *account, NSArray *posts) {
  NSURLRequest *request = Request(account, nil);
  unsigned long long order = RFSavedPostsNoteRequest(request);
  RFSavedPostsNoteDetails(request, Details(posts), order);
}

static void Change(NSString *account, NSString *postId, NSString *state, BOOL ok) {
  NSURLRequest *request = Request(account, @{@"input" : @{@"postId" : postId, @"saveState" : state}});
  RFSavedPostsNoteRequest(request);
  RFSavedPostsNoteChange(request, JSON(@{@"data" : @{@"updatePostSaveState" : @{@"ok" : @(ok), @"errors" : NSNull.null}}}));
}

int main(void) {
  @autoreleasepool {
    Check(!RFSavedPostsIsSaved(@"A title", @"r/a, A title"), @"Nothing known yet");

    Load(@"t2_a", @[ Post(@"t3_1", @"A title", @"a", NO), Post(@"t3_2", @"  Spaced   out ", @"a", YES),
                     Post(@"t3_3", @"By a user", nil, YES), NSNull.null, @{@"id" : @"t3_x"} ]);
    Check(!RFSavedPostsIsSaved(@"A title", @"r/a, A title"), @"Not saved");
    Check(RFSavedPostsIsSaved(@"Spaced out", @"r/a, Spaced out"), @"Saved, whatever its spacing");
    Check(RFSavedPostsIsSaved(@"By a user", @"u/someone, By a user"), @"Saved profile post");
    Check(!RFSavedPostsIsSaved(@"Titre traduit", @"r/a, Titre traduit"), @"Unknown title");
    Check(!RFSavedPostsIsSaved(nil, nil) && !RFSavedPostsIsSaved(@" ", nil), @"No title");

    Change(@"t2_a", @"t3_1", @"SAVED", YES);
    Check(RFSavedPostsIsSaved(@"A title", @"r/a, A title"), @"Saved since");
    Change(@"t2_a", @"t3_1", @"NONE", NO);
    Check(RFSavedPostsIsSaved(@"A title", @"r/a, A title"), @"An unsave that failed");
    Change(@"t2_a", @"t3_1", @"NONE", YES);
    Check(!RFSavedPostsIsSaved(@"A title", @"r/a, A title"), @"Unsaved since");

    // Details asked for before a save, answered after it.
    NSURLRequest *early = Request(@"t2_a", nil);
    unsigned long long order = RFSavedPostsNoteRequest(early);
    Change(@"t2_a", @"t3_1", @"SAVED", YES);
    Change(@"t2_a", @"t3_4", @"SAVED", YES); // not seen in a feed yet
    RFSavedPostsNoteDetails(early, Details(@[ Post(@"t3_1", @"A title", @"a", NO), Post(@"t3_4", @"New", @"a", NO) ]), order);
    Check(RFSavedPostsIsSaved(@"A title", @"r/a, A title"), @"An older answer doesn't undo a save");
    Check(RFSavedPostsIsSaved(@"New", @"r/a, New"), @"Saved before its details came");
    Load(@"t2_a", @[ Post(@"t3_1", @"A title", @"a", NO) ]);
    Check(!RFSavedPostsIsSaved(@"A title", @"r/a, A title"), @"A newer answer counts (unsaved elsewhere)");

    // Two posts with one title.
    Load(@"t2_a", @[ Post(@"t3_5", @"Same", @"pic", YES), Post(@"t3_6", @"Same", @"pics", NO) ]);
    Check(RFSavedPostsIsSaved(@"Same", @"r/pic, Same, 3 upvotes"), @"The saved one");
    Check(!RFSavedPostsIsSaved(@"Same", @"r/pics, Same, 3 upvotes"), @"The other one");
    Check(RFSavedPostsIsSaved(@"Same", @"r slash Pic, 4d, Same"), @"Spoken community name");
    Check(!RFSavedPostsIsSaved(@"Same", @"someone, 4d, Same"), @"Can't be told apart");
    Load(@"t2_a", @[ Post(@"t3_6", @"Same", @"pics", YES) ]);
    Check(RFSavedPostsIsSaved(@"Same", @"someone, 4d, Same"), @"Both saved");

    // An edited title isn't found under the old one.
    Load(@"t2_a", @[ Post(@"t3_2", @"Renamed", @"a", YES) ]);
    Check(!RFSavedPostsIsSaved(@"Spaced out", nil) && RFSavedPostsIsSaved(@"Renamed", nil), @"Renamed");

    // Another account starts again, and an answer for the old one is dropped.
    NSURLRequest *old = Request(@"t2_a", nil);
    order = RFSavedPostsNoteRequest(old);
    Load(@"t2_b", @[ Post(@"t3_7", @"B's", @"b", YES) ]);
    RFSavedPostsNoteDetails(old, Details(@[ Post(@"t3_8", @"A's", @"a", YES) ]), order);
    Check(!RFSavedPostsIsSaved(@"Renamed", nil) && !RFSavedPostsIsSaved(@"A's", nil), @"Other account's posts forgotten");
    Check(RFSavedPostsIsSaved(@"B's", nil), @"This account's kept");

    // Broken answers.
    for (id broken in @[ @[], @{@"data" : NSNull.null}, @{@"data" : @{@"postsInfoByIds" : @"x", @"updatePostSaveState" : @1}} ]) {
      RFSavedPostsNoteDetails(Request(@"t2_b", nil), JSON(broken), 1000);
      RFSavedPostsNoteChange(Request(@"t2_b", nil), JSON(broken));
    }
    RFSavedPostsNoteDetails(Request(@"t2_b", nil), nil, 1000);
    Check(RFSavedPostsIsSaved(@"B's", nil), @"Broken answers change nothing");

    // The oldest go first.
    for (NSUInteger i = 0; i < 3000; i++)
      Load(@"t2_b", @[ Post([NSString stringWithFormat:@"t3_n%lu", (unsigned long)i], [NSString stringWithFormat:@"N%lu", (unsigned long)i], @"b", YES) ]);
    Check(!RFSavedPostsIsSaved(@"B's", nil), @"Oldest dropped");
    Check(RFSavedPostsIsSaved(@"N0", nil) && RFSavedPostsIsSaved(@"N2999", nil), @"The rest kept");

    RFSavedPostsForget();
    Check(!RFSavedPostsIsSaved(@"N0", nil), @"Forgotten");
    NSLog(@"SavedPosts tests passed");
  }
  return 0;
}
