// Runs in the iOS Simulator from tests/run-sim.sh, which passes ColoredComments.x through Logos and includes it
// here so its color rules can be tested on real views. Its hooks aren't installed: Reddit's classes don't exist.
#include COLORED_COMMENTS_SOURCE

static void Check(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

static UIColor *const kGrey = [UIColor colorWithWhite:0 alpha:0.1];

// A comment row like Reddit's: lines at the given x positions, with Reddit's colors, in a cell in a window.
static NSArray<UIView *> *Row(UIWindow *window, NSArray<NSNumber *> *xs, NSArray<UIColor *> *colors) {
  UICollectionViewCell *cell = [[UICollectionViewCell alloc] initWithFrame:CGRectMake(0, 0, 402, 100)];
  UIView *strip = [[UIView alloc] initWithFrame:cell.bounds];
  [cell.contentView addSubview:strip];
  [window addSubview:cell];
  NSMutableArray *lines = [NSMutableArray array];
  for (NSUInteger i = 0; i < xs.count; i++) {
    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(xs[i].doubleValue, 0, 1, 100)];
    objc_setAssociatedObject(line, kRedditColorKey, colors[i], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [strip addSubview:line];
    [lines addObject:line];
  }
  return lines;
}

static UIColor *Faded(NSInteger depth) { return [RFThreadColors()[depth] colorWithAlphaComponent:0.35]; }

int main(void) {
  @autoreleasepool {
    UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 402, 800)];
    window.hidden = NO;
    UIColor *gold = [UIColor colorWithRed:0.72 green:0.53 blue:0 alpha:1];
    NSArray *colors = RFThreadColors();
    gEnabled = YES;

    NSArray *row = Row(window, @[ @16, @32, @48 ], @[ kGrey, kGrey, kGrey ]);
    Check([RFLineColor(row[2], kGrey) isEqual:colors[2]], @"A depth 3 reply's own line gets the third color");
    Check([RFLineColor(row[0], kGrey) isEqual:Faded(0)] && [RFLineColor(row[1], kGrey) isEqual:Faded(1)],
          @"Lines of the comments above it are faded");
    gApolloStyle = YES;
    Check([RFLineColor(row[0], kGrey) isEqual:kGrey] && [RFLineColor(row[2], kGrey) isEqual:colors[2]],
          @"Apollo style: only its own line is colored");

    // A highlighted reply: its own line is gold. The grey line is a comment above it, so it stays grey.
    row = Row(window, @[ @16, @32 ], @[ kGrey, gold ]);
    Check([RFLineColor(row[0], kGrey) isEqual:kGrey], @"Apollo style: a line above a highlighted reply stays grey");
    Check([RFLineColor(row[1], gold) isEqual:gold], @"A highlighted comment keeps its gold line");
    gApolloStyle = NO;
    Check([RFLineColor(row[0], kGrey) isEqual:Faded(0)], @"Faded, not colored as its own line");

    // A highlighted parent's gold line at its level: the reply below is depth 2.
    row = Row(window, @[ @16, @32 ], @[ gold, kGrey ]);
    Check([RFLineColor(row[1], kGrey) isEqual:colors[1]], @"A gold line at a level still counts as that level");

    // A gold line at the row's edge, outside the levels: the reply is still depth 1.
    row = Row(window, @[ @0, @16 ], @[ gold, kGrey ]);
    Check([RFLineColor(row[1], kGrey) isEqual:colors[0]], @"A line outside the levels doesn't shift the colors");

    // Another indent step, from the gap between lines.
    row = Row(window, @[ @12, @24, @36 ], @[ kGrey, kGrey, kGrey ]);
    Check([RFLineColor(row[2], kGrey) isEqual:colors[2]], @"Work out the indent from the gap between lines");

    gEnabled = NO;
    Check([RFLineColor(row[2], kGrey) isEqual:kGrey], @"Off: Reddit's color");
    puts("All colored comment tests passed.");
  }
  return 0;
}
