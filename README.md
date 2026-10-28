# RedditFilter

Filters unwanted content from the Reddit app: promoted posts, recommendations, NSFW posts, awards and scores. Originally by [level3tjg](https://github.com/level3tjg/RedditFilter), based on [NicholasBly's fork](https://github.com/NicholasBly/RedditFilter).

## Fixes for Reddit 2026.43.0

- **Comment ads** are hidden again.
- **NSFW filter** now hides NSFW posts in the new feed cards and in community highlights.
- **Recommended filter** also removes the "Related answers" section on post pages.
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

Requires [Theos](https://theos.dev).

- Jailbreak packages: `make package` (add `THEOS_PACKAGE_SCHEME=rootless` for rootless).
- Sideload IPA: install [theos-jailed](https://github.com/level3tjg/theos-jailed), then run `make package SIDELOADED=1 IPA=/path/to/decrypted.ipa`. The IPA must be decrypted. On Apple Silicon Macs without Rosetta, build [insert_dylib](https://github.com/Tyilo/insert_dylib) yourself and add `INSERT_DYLIB=/path/to/insert_dylib`.
