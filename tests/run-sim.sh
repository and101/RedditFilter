#!/bin/sh
# Runs tests/NetworkTests.m in the iOS Simulator: the real network hook from Tweak.xm against stubbed
# Reddit responses. Needs Xcode, Theos (for its Logos preprocessor) and a booted simulator, or pass a
# simulator's ID. Built with the debug menu on, so its record of unfiltered requests is tested too.
# Also runs tests/ColoredCommentsTests.mm on the color rules in ColoredComments.x.
set -eu
cd "$(dirname "$0")/.."
: "${THEOS:=$HOME/theos}"
: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
device=${1:-booted}
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/redditfilter-sim-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

flags="-target arm64-apple-ios16.0-simulator -fobjc-arc -I. -Iinclude -DREDDITFILTER_DEBUG=1"
"$THEOS/bin/logos.pl" -c generator=internal Tweak.xm >"$test_dir/Tweak.mm"
xcrun --sdk iphonesimulator clang++ $flags -Wno-module-import-in-extern-c -c "$test_dir/Tweak.mm" -o "$test_dir/Tweak.o"
xcrun --sdk iphonesimulator clang $flags -framework UIKit -lc++ \
  JSONFilter.m Redgifs.m tests/NetworkTests.m -x objective-c DebugMenu.x -x none "$test_dir/Tweak.o" \
  -o "$test_dir/NetworkTests"
xcrun simctl spawn "$device" "$test_dir/NetworkTests"

"$THEOS/bin/logos.pl" -c generator=internal ColoredComments.x >"$test_dir/ColoredComments.mm"
xcrun --sdk iphonesimulator clang++ $flags -framework UIKit -framework CoreGraphics -DCOLORED_COMMENTS_SOURCE="\"$test_dir/ColoredComments.mm\"" \
  tests/ColoredCommentsTests.mm -o "$test_dir/ColoredCommentsTests"
xcrun simctl spawn "$device" "$test_dir/ColoredCommentsTests"
