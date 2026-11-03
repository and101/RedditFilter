#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/redditfilter-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
xcrun --sdk macosx clang -fobjc-arc -fblocks -framework Foundation -I. \
  -x objective-c DebugMenu.x -x none JSONFilter.m RFVersion.m tests/JSONFilterTests.m -o "$test_dir/JSONFilterTests"
"$test_dir/JSONFilterTests"

xcrun --sdk macosx clang -fobjc-arc -framework Foundation -framework CoreGraphics -I. \
  SwipeCollapseGeometry.m tests/SwipeCollapseTests.m -o "$test_dir/SwipeCollapseTests"
"$test_dir/SwipeCollapseTests"
