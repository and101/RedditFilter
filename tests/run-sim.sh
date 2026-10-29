#!/bin/sh
# Runs tests/NetworkTests.m in the iOS Simulator: the real network hook from Tweak.xm against stubbed
# Reddit responses. Needs Xcode, Theos (for its Logos preprocessor) and a booted simulator, or pass a
# simulator's ID.
set -eu
cd "$(dirname "$0")/.."
: "${THEOS:=$HOME/theos}"
: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
device=${1:-booted}
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/redditfilter-sim-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

flags="-target arm64-apple-ios16.0-simulator -fobjc-arc -I. -Iinclude"
"$THEOS/bin/logos.pl" -c generator=internal Tweak.xm >"$test_dir/Tweak.mm"
xcrun --sdk iphonesimulator clang++ $flags -Wno-module-import-in-extern-c -c "$test_dir/Tweak.mm" -o "$test_dir/Tweak.o"
xcrun --sdk iphonesimulator clang $flags -framework UIKit -lc++ \
  JSONFilter.m Redgifs.m tests/NetworkTests.m "$test_dir/Tweak.o" -o "$test_dir/NetworkTests"
xcrun simctl spawn "$device" "$test_dir/NetworkTests"
