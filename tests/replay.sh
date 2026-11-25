#!/bin/sh
# Replays captured Reddit responses through the filter on the Mac, and reports ads that still show and
# changes that could break a feed. See tests/Replay.m.
#   tests/replay.sh <folder> [ads expected]
# The folder holds raw GraphQL responses, one per file, named <operation>-<anything>.json. Captures are
# personal (what an account was shown), so keep them out of git, e.g. in .local/captures.
# tests/fixtures has small anonymous ones, made with tests/trim-captures.py, which tests/run.sh replays.
set -eu
folder=$(cd "${1:?usage: tests/replay.sh <folder of captured responses>}" && pwd)
cd "$(dirname "$0")/.."
: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/redditfilter-replay.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
xcrun --sdk macosx clang -fobjc-arc -fblocks -framework Foundation -I. \
  -x objective-c DebugMenu.x -x none JSONFilter.m RFStats.m RFVersion.m tests/Replay.m -o "$test_dir/Replay"
"$test_dir/Replay" "$folder" ${2:+"$2"}
