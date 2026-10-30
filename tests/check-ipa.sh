#!/bin/bash
# Checks a Reddit build before RedditFilter is moved onto it.
#   tests/check-ipa.sh <decrypted Reddit .ipa or .app> [--update]
#
# 1. Everything in tests/reddit-contract.txt is still in the app.
# 2. Compares the parts that can let content past the filter with tests/reddit-baseline.txt: Reddit
#    server addresses, URLSession calls, networking experiments and ad types/fields. Anything new
#    or gone is listed for review. --update saves this build as the new baseline once reviewed.
# 3. Runs tests/run.sh, then tests/run-sim.sh with every GraphQL/OAuth address found, so the real
#    network hook is checked against each one (needs a booted simulator; skipped otherwise).
set -eu
cd "$(dirname "$0")/.."
: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
input=${1:?usage: tests/check-ipa.sh <Reddit .ipa or .app> [--update]}
update=${2:-}
work=$(mktemp -d "${TMPDIR:-/tmp}/redditfilter-check.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

if [ -d "$input" ]; then
  app=$input
else
  unzip -q "$input" 'Payload/*' -d "$work/ipa"
  app=$(ls -d "$work"/ipa/Payload/*.app | head -1)
fi
version="$(plutil -extract CFBundleShortVersionString raw "$app/Info.plist") ($(plutil -extract CFBundleVersion raw "$app/Info.plist"))"
echo "Reddit $version"

# Reddit's own binaries, not the dylibs this project injects.
: >"$work/strings"
: >"$work/imports"
find "$app" -maxdepth 3 -type f \( -path "*/Frameworks/*.framework/*" -o -path "$app/$(plutil -extract CFBundleExecutable raw "$app/Info.plist")" \) |
  while read -r binary; do
    file -b "$binary" | grep -q Mach-O || continue
    strings -a "$binary" >>"$work/strings"
    nm -u "$binary" 2>/dev/null >>"$work/imports" || true
  done

failed=0
fail() { echo "FAIL: $*"; failed=1; }

# 1. What RedditFilter relies on
section=
while read -r line; do
  case $line in '' | '#'*) continue ;; '['*) section=$line; continue ;; esac
  if grep -qF -- "$line" "$work/strings"; then
    [ "$section" = "[legacy]" ] && echo "legacy name still present: $line"
  else
    [ "$section" = "[required]" ] && fail "$line is gone (see tests/reddit-contract.txt)"
  fi
done <tests/reddit-contract.txt

# 2. Compare with the baseline
{
  echo "# Reddit $version. Regenerate with: tests/check-ipa.sh <ipa> --update"
  echo "[hosts]"
  grep -oE '\b[a-z0-9-]+(\.[a-z0-9-]+)*\.reddit\.com\b' "$work/strings" | sort -u
  echo "[url-session]"
  grep -xE '(dataTask|uploadTask|downloadTask|streamTask|webSocketTask)With[A-Za-z:]*' "$work/strings" | sort -u
  grep -oE '\$sSo12NSURLSessionC10FoundationE[A-Za-z0-9_]+' "$work/imports" | sort -u |
    xcrun swift-demangle --compact --simplified | grep -E '^NSURLSession\.[a-z][A-Za-z]*\(' | sort -u
  echo "[network-experiments]"
  grep -xE 'ios_[a-z0-9_]*(graphql|gql|uri|host|cloudflare|endpoint|transport|http3|quic|network|url_session|multipath|preconnect)[a-z0-9_]*' "$work/strings" | sort -u
  grep -xE '[a-z0-9_]*(gql|graphql)[a-z0-9_]*' "$work/strings" | grep -v '^ios_' | sort -u
  echo "[ad-schema]"
  grep -E '^(fragment|query|subscription) ' "$work/strings" >"$work/graphql" || true
  grep -oE 'on [A-Z][A-Za-z]*(Ad|Ads|Promoted|Sponsor)[A-Za-z]* ' "$work/graphql" | sed 's/^on //; s/ $//' | sort -u
  grep -oE '\b[a-z][A-Za-z]*(Ads|AdPosts|AdPayload|Promoted[A-Za-z]*)\b' "$work/graphql" | sort -u
} >"$work/baseline"

if [ "$update" = "--update" ]; then
  cp "$work/baseline" tests/reddit-baseline.txt
  echo "Saved as tests/reddit-baseline.txt"
else
  section_of() { sed -n "/^\[$2\]/,/^\[/p" "$1" | grep -v '^\['; }
  base=$(head -1 tests/reddit-baseline.txt | sed 's/^# //; s/\. Regenerate.*//')
  for section in hosts url-session network-experiments ad-schema; do
    changes=$(diff <(section_of tests/reddit-baseline.txt $section) <(section_of "$work/baseline" $section) |
      sed -n 's/^< /  - /p; s/^> /  + /p' || true)
    [ -z "$changes" ] && continue
    case $section in
      hosts) why="a new Reddit address skips the hook unless RFIsAPIHost in Tweak.xm accepts it" ;;
      url-session) why="requests made through a call the hook doesn't cover are never filtered" ;;
      network-experiments) why="an experiment can move some users onto a different address or client" ;;
      ad-schema) why="a new ad type or field may need filtering in JSONFilter.m" ;;
    esac
    echo
    echo "REVIEW $section, changed since $base ($why):"
    echo "$changes"
  done
fi

# 3. The filter's own tests, then the real hook against every API address in this build
echo
tests/run.sh || fail "JSON filter tests (see above)"
hosts=$(sed -n '/^\[hosts\]/,/^\[/p' "$work/baseline" | grep -E '(^|\.|-)(gql|graphql|oauth)' | paste -sd, -)
echo
echo "API addresses: $hosts"
if xcrun simctl list devices booted 2>/dev/null | grep -q Booted; then
  SIMCTL_CHILD_RF_API_HOSTS=$hosts tests/run-sim.sh || fail "network tests (see above)"
else
  echo "No booted simulator: skipped the network tests. Boot one and run again."
fi

echo
if [ $failed = 0 ]; then echo "Check passed. Review anything listed above."; else echo "Check failed."; exit 1; fi
