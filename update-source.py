#!/usr/bin/env python3
"""Updates docs/source.json, the source that AltStore, SideStore, Feather and Signet read.

    ./update-source.py <released RedditFilter IPA> <release notes .md> [--date YYYY-MM-DD]

Run it on the exact IPA attached to the release: AltStore and SideStore refuse to install an app whose version,
permissions, size or SHA-256 don't match its source. Publish the release first, then push docs/source.json, so the
download link works by the time anyone sees it. Needs ldid (build-ipa.sh installs it).
"""
import argparse
import datetime
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import zipfile

REPO = "and101/RedditFilter"
PAGES = "https://and101.github.io/RedditFilter"
TINT = "#FF6A3D"
OUTPUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "docs", "source.json")

SUBTITLE = "Reddit without the ads"
DESCRIPTION = """The Reddit app with RedditFilter built in. Unofficial, and not affiliated with Reddit.

• Hide promoted posts, comment ads, recommendations, NSFW posts and more
• Filter by keyword, website or flair
• Coloured comment threads and swipe to collapse
• Clean share links and a tracker blocker
• RedGIFs videos with sound

Long press the sidebar button at the top left of Reddit to open RedditFilter."""
SCREENSHOTS = ["threads.png", "swipe.png", "settings.png", "settings3.png"]
# AltStore and SideStore don't check these.
IGNORED_ENTITLEMENTS = {"application-identifier", "com.apple.developer.team-identifier"}


def entitlements(ipa, executable):
    """The entitlements an executable in the IPA is signed with; empty if it's unsigned."""
    with tempfile.NamedTemporaryFile() as binary:
        binary.write(ipa.read(executable))
        binary.flush()
        result = subprocess.run(["ldid", "-e", binary.name], capture_output=True)
    if result.returncode == 0:
        return plistlib.loads(result.stdout) if result.stdout.strip() else {}
    # ldid fails on an unsigned binary (RedditFilterSafari). Anything else is a real error.
    if b"signed binary" in result.stderr:
        return {}
    sys.exit(f"ldid couldn't read {executable}: {result.stderr.decode(errors='replace').strip()}")


def plain_notes(text):
    """Release notes as plain text, which is all sideloading apps show, without the install steps."""
    text = re.split(r"^## Install\b", text, maxsplit=1, flags=re.M)[0]
    text = re.sub(r"^Everything from .*$", "", text, flags=re.M)
    text = text.replace(" See Install below.", "")
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"\*\*(.+?)\*\*", r"\1", text)
    text = text.replace("`", "")
    text = re.sub(r"^#+ +", "", text, flags=re.M)
    text = re.sub(r"^( *)- ", r"\1• ", text, flags=re.M)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("ipa")
    parser.add_argument("notes")
    parser.add_argument("--date", default=datetime.date.today().isoformat(), help="release date (default: today)")
    args = parser.parse_args()
    datetime.date.fromisoformat(args.date)

    name = re.fullmatch(r"RedditFilter_([\d.]+)-([\d.]+)\.ipa", os.path.basename(args.ipa))
    if not name:
        sys.exit("The IPA must keep its release name, RedditFilter_<Reddit version>-<RedditFilter version>.ipa")
    reddit, tweak = name.groups()

    found, privacy = set(), {}
    with zipfile.ZipFile(args.ipa) as ipa:
        plists = [n for n in ipa.namelist()
                  if re.fullmatch(r"Payload/[^/]+\.app/(PlugIns/[^/]+\.appex/)?Info\.plist", n)]
        app = None
        for path in plists:
            info = plistlib.loads(ipa.read(path))
            if "/PlugIns/" not in path:
                app = info
            privacy.update({k: v for k, v in info.items() if re.fullmatch(r"NS\w+UsageDescription", k)})
            found |= set(entitlements(ipa, os.path.dirname(path) + "/" + info["CFBundleExecutable"]))
    if not app:
        sys.exit("No app in the IPA")
    if app["CFBundleShortVersionString"] != reddit:
        sys.exit(f"The IPA is named {reddit} but contains Reddit {app['CFBundleShortVersionString']}")

    digest = hashlib.sha256()
    with open(args.ipa, "rb") as file:
        for chunk in iter(lambda: file.read(1 << 20), b""):
            digest.update(chunk)

    version = {
        "version": reddit,
        "buildVersion": app["CFBundleVersion"],
        "marketingVersion": f"{tweak} (Reddit {reddit})",
        "date": args.date,
        "localizedDescription": plain_notes(open(args.notes, encoding="utf-8").read()),
        "downloadURL": f"https://github.com/{REPO}/releases/download/v{reddit}-{tweak}/{os.path.basename(args.ipa)}",
        "size": os.path.getsize(args.ipa),
        "sha256": digest.hexdigest(),
        "minOSVersion": app["MinimumOSVersion"],
    }

    try:
        with open(OUTPUT, encoding="utf-8") as file:
            last = json.load(file)["apps"][0]["versions"][0]
    except FileNotFoundError:
        last = None
    if last and last["downloadURL"] != version["downloadURL"] and \
            (last["version"], last["buildVersion"]) == (version["version"], version["buildVersion"]):
        print(f"Warning: the last release was also Reddit {reddit} ({version['buildVersion']}). Sideloading apps compare "
              "only those, so people who already have it won't be offered this as an update.", file=sys.stderr)

    source = {
        "name": "RedditFilter",
        "identifier": "com.and101.redditfilter.source",
        "subtitle": SUBTITLE,
        "description": "RedditFilter releases: the Reddit app with ads and other unwanted content filtered out.",
        "iconURL": f"{PAGES}/icon.png",
        "website": f"https://github.com/{REPO}",
        "tintColor": TINT,
        "apps": [{
            "name": "RedditFilter",
            "bundleIdentifier": app["CFBundleIdentifier"],
            "developerName": "and101",
            "subtitle": SUBTITLE,
            "localizedDescription": DESCRIPTION,
            "iconURL": f"{PAGES}/icon.png",
            "tintColor": TINT,
            "category": "social",
            "screenshots": [{"imageURL": f"https://raw.githubusercontent.com/{REPO}/main/screenshots/{file}",
                             "width": 600, "height": 1304} for file in SCREENSHOTS],
            "versions": [version],
            "appPermissions": {
                "entitlements": sorted(found - IGNORED_ENTITLEMENTS),
                "privacy": dict(sorted(privacy.items())),
            },
        }],
        "news": [],
    }
    with open(OUTPUT, "w", encoding="utf-8") as file:
        json.dump(source, file, indent=2, ensure_ascii=False)
        file.write("\n")
    print(f"docs/source.json: RedditFilter {version['marketingVersion']}, build {version['buildVersion']}, "
          f"{version['size']} bytes, SHA-256 {version['sha256']}")


if __name__ == "__main__":
    main()
