# RedditFilter

Filters unwanted content from the Reddit app: promoted posts, recommendations, NSFW posts, awards and scores. Based on original work from [level3tjg](https://github.com/level3tjg/RedditFilter) and [NicholasBly](https://github.com/NicholasBly/RedditFilter).

## Fixes for Reddit 2026.43.0

- **Comment ads** are hidden again.
- **NSFW filter** now hides NSFW posts in the new feed cards and in community highlights.
- **Recommended filter** no longer empties the For You feed, which is now mostly recommendations (your subscriptions are in Following). It still removes the "Related answers" section on post pages.
- **Videos for you**: new option to hide the "Videos for you" carousel in your feed.
- **RedditFilter settings** are back: Profile → Settings, button at the top right.
- **Logging in** now works on sideloaded installs (see below).

## Logging in

Reddit rejects the app's normal username and password login when the app is sideloaded. Use one of these instead:

1. Open the login screen: **I already have an account** (or **Log in**) → **Use email or username**.
2. Tap **Other options** at the top right, then choose:
   - **Log in with browser**: log in on the reddit.com page that opens, including any 2FA code. The app finishes logging in by itself.
   - **Open login link**: first tap **Email me a login link instead**, then copy the link from Reddit's email and paste it here.

Google sign-in may not work inside the browser, because Google often blocks it in apps. Use your Reddit username and password on the web page instead.

## Install

Download the IPA from [Releases](../../releases), sign it with your usual signer and install it.

## Build

On a Mac with Xcode and [Homebrew](https://brew.sh):

```sh
git clone --recursive https://github.com/and101/RedditFilter.git
cd RedditFilter
./build-ipa.sh /path/to/decrypted-Reddit.ipa
```

The IPA is saved in `packages/`, unsigned. The script installs anything missing (Theos, theos-jailed, insert_dylib and a few Homebrew packages) at the versions used for the released IPAs, so builds match. The Reddit IPA must be decrypted.

For jailbroken devices, `make package` builds a deb (add `THEOS_PACKAGE_SCHEME=rootless` for rootless).
