#!/bin/bash
# Before the IPA is packaged:
#   - writes an Info.plist to merge into the app's, with the app's link types plus redditfilter://
#   - gives the Safari extension the app's version (skipped when no extension is given)
#
#   prepare-ipa.sh <decrypted Reddit IPA> <resources folder> [<RedditFilterSafari.appex>]
set -euo pipefail
IPA=$1 RESOURCES=$2 APPEX=${3:-}
BUDDY=/usr/libexec/PlistBuddy
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

APP_PLIST=$(unzip -Z1 "$IPA" | grep -E '^Payload/[^/]+\.app/Info\.plist$' | head -1)
unzip -p "$IPA" "$APP_PLIST" >"$WORK/App.plist"
[ -s "$WORK/App.plist" ] || { echo "Error: no app Info.plist in $IPA" >&2; exit 1; }

# theos-jailed keeps our value for any key the app also has, so the list has to include the app's
# own link types too.
PLIST=$RESOURCES/Info.plist
rm -f "$PLIST"
"$BUDDY" -c "Add :CFBundleURLTypes array" "$PLIST" >/dev/null
if "$BUDDY" -x -c "Print :CFBundleURLTypes" "$WORK/App.plist" >"$WORK/types.plist" 2>/dev/null; then
  "$BUDDY" -c "Merge $WORK/types.plist :CFBundleURLTypes" "$PLIST"
fi
COUNT=$("$BUDDY" -c "Print :CFBundleURLTypes" "$PLIST" | grep -c '^    Dict {' || true)
"$BUDDY" -c "Add :CFBundleURLTypes:$COUNT dict" \
  -c "Add :CFBundleURLTypes:$COUNT:CFBundleURLName string com.and101.redditfilter" \
  -c "Add :CFBundleURLTypes:$COUNT:CFBundleURLSchemes array" \
  -c "Add :CFBundleURLTypes:$COUNT:CFBundleURLSchemes:0 string redditfilter" "$PLIST"

if [ -n "$APPEX" ]; then
  [ -f "$APPEX/Info.plist" ] || { echo "Error: $APPEX wasn't built" >&2; exit 1; }
  for key in CFBundleShortVersionString CFBundleVersion; do
    "$BUDDY" -c "Set :$key $("$BUDDY" -c "Print :$key" "$WORK/App.plist")" "$APPEX/Info.plist"
  done
  # Same prefix as the app's bundle ID, which signers replace with their own.
  "$BUDDY" -c "Set :CFBundleIdentifier $("$BUDDY" -c "Print :CFBundleIdentifier" "$WORK/App.plist").RedditFilterSafari" \
    "$APPEX/Info.plist"
fi
