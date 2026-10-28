#!/bin/bash
# Builds the sideload IPA on macOS, the same way the released IPAs are built.
#
#   ./build-ipa.sh /path/to/decrypted-Reddit.ipa
#
# Output: packages/RedditFilter_<Reddit version>-<RedditFilter version>.ipa (unsigned).
#
# Needs Xcode and Homebrew. Installs anything else that's missing, at the versions below.
set -euo pipefail

THEOS_COMMIT=6e7b8c40e0f5f9f5b2377800dc1e42cd2560d24a
THEOS_JAILED_COMMIT=2a861c0fbdf1306050c3a8bc02dc01e12ae9b3a3
INSERT_DYLIB_COMMIT=eb7278162af8fcc372e7f2946a2dee6a386b17d8
BREW_PACKAGES=(ldid-procursus dpkg xmlstarlet libplist)

cd "$(dirname "$0")"
ROOT=$PWD
TOOLS=$ROOT/.build
export THEOS=${THEOS:-$HOME/theos}

fail() { echo "Error: $1" >&2; exit 1; }
step() { echo "==> $1"; }

[ $# -eq 1 ] || fail "usage: ./build-ipa.sh /path/to/decrypted-Reddit.ipa"
IPA=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
[ -f "$IPA" ] || fail "IPA not found: $1"
[ "$(uname)" = Darwin ] || fail "this script runs on macOS"
# Use Xcode even when xcode-select points to the Command Line Tools.
if [ -z "${DEVELOPER_DIR:-}" ]; then
  DEVELOPER_DIR=$(xcode-select -p)
  [[ "$DEVELOPER_DIR" == *CommandLineTools* && -d /Applications/Xcode.app ]] &&
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export DEVELOPER_DIR
xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 ||
  fail "Xcode's iOS SDK isn't available. Install Xcode, or set DEVELOPER_DIR to its Developer folder."

step "Checking Homebrew packages"
command -v brew >/dev/null || fail "Homebrew is required: https://brew.sh"
for package in "${BREW_PACKAGES[@]}"; do
  brew list --versions "$package" >/dev/null || brew install "$package"
done

step "Checking Theos"
if [ ! -d "$THEOS/.git" ]; then
  git clone https://github.com/theos/theos.git "$THEOS"
  git -C "$THEOS" checkout -q "$THEOS_COMMIT"
  git -C "$THEOS" submodule update -q --init --recursive
elif [ "$(git -C "$THEOS" rev-parse HEAD)" != "$THEOS_COMMIT" ]; then
  echo "Warning: Theos at $THEOS isn't at the tested commit ${THEOS_COMMIT:0:7}; builds may differ." >&2
fi

step "Checking theos-jailed"
JAILED_SRC=$TOOLS/theos-jailed
if [ ! -d "$JAILED_SRC/.git" ]; then
  git clone -q --recursive https://github.com/level3tjg/theos-jailed.git "$JAILED_SRC"
fi
if [ "$(git -C "$JAILED_SRC" rev-parse HEAD)" != "$THEOS_JAILED_COMMIT" ] || [ ! -d "$THEOS/mod/jailed" ]; then
  git -C "$JAILED_SRC" checkout -q "$THEOS_JAILED_COMMIT"
  git -C "$JAILED_SRC" submodule update -q --init --recursive
  "$JAILED_SRC/install"
fi

# theos-jailed ships an Intel-only insert_dylib, so build one for this Mac.
step "Checking insert_dylib"
INSERT_DYLIB=$TOOLS/insert_dylib
if [ ! -x "$INSERT_DYLIB" ]; then
  rm -rf "$TOOLS/insert_dylib-src"
  git clone -q https://github.com/Tyilo/insert_dylib.git "$TOOLS/insert_dylib-src"
  git -C "$TOOLS/insert_dylib-src" checkout -q "$INSERT_DYLIB_COMMIT"
  clang -O2 -o "$INSERT_DYLIB" "$TOOLS/insert_dylib-src/insert_dylib/main.c"
fi

step "Checking submodules"
git submodule update -q --init --recursive

CHECK=$(mktemp -d)
trap 'rm -rf "$CHECK"' EXIT
unzip -Z1 "$IPA" >"$CHECK/files"
APP_DIR=$(grep -oE '^Payload/[^/]+\.app/' "$CHECK/files" | sort -u | head -1)
unzip -p "$IPA" "${APP_DIR}Info.plist" >"$CHECK/Info.plist"
APP_VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$CHECK/Info.plist")
unzip -p "$IPA" "$APP_DIR$(plutil -extract CFBundleExecutable raw -o - "$CHECK/Info.plist")" >"$CHECK/binary"
otool -l "$CHECK/binary" | grep -q 'cryptid 1' && fail "the IPA is encrypted; use a decrypted IPA"

step "Building RedditFilter for Reddit $APP_VERSION"
make clean >/dev/null
make package FINALPACKAGE=1 SIDELOADED=1 IPA="$IPA" APP_VERSION="$APP_VERSION" INSERT_DYLIB="$INSERT_DYLIB"

OUTPUT=packages/RedditFilter_$APP_VERSION-$(grep -E '^PACKAGE_VERSION = ' Makefile | cut -d' ' -f3).ipa
[ -f "$OUTPUT" ] || fail "the build didn't produce $OUTPUT"
unzip -Z1 "$OUTPUT" >"$CHECK/output-files"
for library in RedditFilter RedditSideloadFix; do
  grep -qE "^Payload/[^/]+\.app/Frameworks/$library\.dylib$" "$CHECK/output-files" ||
    fail "$library.dylib is missing from $OUTPUT"
done
step "Built $OUTPUT"
