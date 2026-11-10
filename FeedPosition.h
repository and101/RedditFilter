#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif
// Stops Reddit reloading Home when the app comes back after a while in the background.
void RFSetKeepFeedPosition(BOOL keep);

// Shared with ScreenRestore.x (main thread only).

// Every SliceKit list Reddit has put in a window this run (feeds, communities, comments).
NSArray<UICollectionView *> *RFFeedLists(void);
// The feed list taking up most of the screen, if any.
UICollectionView *RFListOnScreen(void);
// Whether a feed is still being scrolled back after its replay.
BOOL RFFeedRestoring(void);
// Feeds whose screen the restore covers with others: they're scrolled back when RFFeedUndefer says their
// screen's on top again (in that screen's list).
void RFFeedDefer(NSArray<NSString *> *feeds);
void RFFeedUndefer(NSArray<NSString *> *feeds, UIViewController *screen);
BOOL RFFeedHasDeferred(void);
// A list's visible cells, top first; the top of what's on screen (below the bars) in its coordinates;
// a feed cell's label (its post card's).
NSArray<UICollectionViewCell *> *RFCellsTopFirst(UICollectionView *list);
CGFloat RFVisibleTop(UICollectionView *list);
NSString *RFCellLabel(UICollectionViewCell *cell);

typedef NS_ENUM(NSInteger, RFScrollResult) {
  RFScrollNotHere, // the list isn't showing what's being restored (yet)
  RFScrollPending, // moved it, but the item isn't in place yet
  RFScrollPlaced,  // the item is where it was
  RFScrollDone,    // nothing more to do
};
// One step of scrolling a list so the item at `path` sits `offset` points above the top of the screen.
// isTarget says whether a cell is the expected one (the item's cell can show something else while the
// list is still filling in).
// asDrag: moves it as if dragged (needed for a community's list, which otherwise jumps back to the top).
RFScrollResult RFScrollListToItem(UICollectionView *list, NSIndexPath *path, double offset, BOOL asDrag,
                                  BOOL (^isTarget)(UICollectionViewCell *cell));
#ifdef __cplusplus
}
#endif
