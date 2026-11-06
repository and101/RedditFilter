# RedditFilter

Filters unwanted content from the Reddit app: promoted posts, recommendations, NSFW posts, awards, scores, and posts or comments that mention your keywords. It can also play RedGIFs videos with sound, collapse comments with a swipe, open Reddit links from Safari in the app, and back up or restore your settings, keywords and stats.

Settings are grouped under **Filters**, **Display** and **More**. **Posts and ads** contains the feed filters. **Appearance** contains awards, scores and comment colours. **Collapsing comments** contains swipe, tap and AutoMod options. **Keywords** includes both comment switches. **Backup**, **Diagnostics** and **About** each have their own page under **More**. To get there quickly, long press the sidebar button at the top left of Reddit.

<table>
  <tr>
    <th colspan="2">Coloured comment threads</th>
    <th colspan="2">Swipe to collapse</th>
  </tr>
  <tr>
    <td align="center" width="25%"><img src="screenshots/threads.png" width="200" alt="Coloured comment threads: each reply level has its own colour, with the lines of parent comments faded"></td>
    <td align="center" width="25%"><img src="screenshots/apollo.png" width="200" alt="Apollo style: only each comment's own line is coloured"></td>
    <td align="center" width="25%"><img src="screenshots/swipe.png" width="200" alt="A reply swiped left, showing Collapse behind it"></td>
    <td align="center" width="25%"><img src="screenshots/swipe-thread.png" width="200" alt="A reply swiped further left, showing Collapse thread behind it"></td>
  </tr>
  <tr>
    <td align="center"><b>Default</b><br><sub>Parent lines faded</sub></td>
    <td align="center"><b>Apollo style</b><br><sub>Only each comment's own line</sub></td>
    <td align="center"><b>Swipe left</b><br><sub>Collapses the comment and its replies</sub></td>
    <td align="center"><b>Swipe further</b><br><sub>Collapses the whole thread</sub></td>
  </tr>
  <tr>
    <th colspan="3">Settings</th>
    <th>Safari</th>
  </tr>
  <tr>
    <td align="center" width="25%"><img src="screenshots/settings.png" width="200" alt="RedditFilter settings: root page"></td>
    <td align="center" width="25%"><img src="screenshots/settings2.png" width="200" alt="RedditFilter settings: Collapsing comments"></td>
    <td align="center" width="25%"><img src="screenshots/settings3.png" width="200" alt="RedditFilter settings: Keywords"></td>
    <td align="center" width="25%"><img src="screenshots/safari.png" width="200" alt="Steps to turn on the RedditFilter Safari extension"></td>
  </tr>
  <tr>
    <td align="center"><b>Tweaks</b><br><sub>Show or hide each kind of content</sub></td>
    <td align="center"><b>Collapsing and RedGIFs</b><br><sub>Swipe or tap, and video quality</sub></td>
    <td align="center"><b>Keywords and About</b><br><sub>Keyword filters, Safari and update check</sub></td>
    <td align="center"><b>Open Reddit links here</b><br><sub>Set up the Safari extension</sub></td>
  </tr>
</table>

<sub>Screenshots use a made-up community, post and users.</sub>

## New in 1.3.6

- **Log in from the app's own login screen**: on sideloaded installs, type your username and password into Reddit's normal login form and it logs you in, with no browser step. Sideloaded apps can't pass Reddit's check that the app is its own build, so RedditFilter tells Reddit this iPhone can't do that check, as some devices can't, and Reddit accepts that. **If Reddit turns this down, you don't need to do anything.** A reddit.com sheet opens by itself, fills in the username and password you just typed, logs in and closes once you're in. If Reddit asks for a 2FA code or a check, finish it in the sheet. A wrong password or too many tries still shows Reddit's usual message, and closing the sheet takes you back to the login screen.
- **Swipe to collapse has its own page**: all the swipe options now live on one page under **Collapsing comments**. **Swipe left** is on by default. Turn on **Swipe right** to collapse with a right swipe too, while swiping from the screen edge still goes back. Turn on both to collapse either way, or turn off **Swipe left** so that swiping left only moves to the next post. Your swipe setting carries over.
- **Extra cards**: turn this off to hide suggested communities, promos, surveys and post carousels from your feeds. Videos for you keeps its own switch.
- **Stats**: a new section at the top of RedditFilter settings shows how much has been hidden, in total, today and by filter. It stays on your device, and you can reset it at any time.
- **Diagnostics**: turn this on at the end of the settings to see whether RedditFilter still finds the posts and ads in Reddit's responses, and whether any new kind of card has appeared in your feeds. Tap **Share report** to copy or send it with a bug report. The report has no usernames or post text. Nothing is shared unless you choose to, and it's cleared when Reddit closes or you turn it off.
- **Fixes**: Keyword checks now read the full text of posts in the Following feed, not just the title and preview. The **Log in with browser** sheet closes reddit.com's cookie banner by itself, opens the **Continue with Google** and **Continue with Apple** windows, and no longer gets stuck if it appears late. RedditFilter only fills in your password on reddit.com, and keeps it in memory only until it's been used.

## New in 1.3.5

**Rebuilt for Reddit 2026.44.0.** The IPA now contains Reddit 2026.44.0 (earlier releases contained 2026.43.0). Install it over your current RedditFilter as usual; your settings and accounts carry over.

- **Check for updates now**: tap **Check for updates** under About to check GitHub straight away. It tells you whether an update is available, you're up to date, or it couldn't check. The switch still turns the daily check on or off.
- **Fixes**: full-text keyword checks work on Reddit 2026.44 from the first launch. Swiping the **Log in with browser** sheet away now cancels that login; dragging it down and letting it spring back doesn't. Rows with an arrow in RedditFilter settings use the full width for their text. Look-alike sites such as evilredgifs.com are no longer treated as RedGIFs. Pages that wait for the full-text check, RedGIFs or the next page now reach Reddit the same way as any other response, and a few unexpected values from Reddit or iOS no longer risk a crash.

## New in 1.3.4

- **Swipe haptics**: a light vibration when your swipe reaches Collapse or Collapse thread. On by default; turn it off under **Collapsing comments**.
- **Stay on the web in Safari**: cancel the prompt twice in a row and that Safari tab stays on the web until it's closed. Going back or forward no longer asks again.
- **RedGIFs quality switches renamed**: **Prefer SD** (on by default) and **Prefer SD on mobile data**, which also covers Low Data Mode. Your settings carry over. HD still plays when a video has no SD version, and videos already loaded keep their quality when your network changes.
- **Fixes**: with **Swipe to collapse** on and **Tap to collapse too** off, "more replies" rows load again when tapped. A RedGIFs video whose lookup came back without a playable file is looked up again, instead of playing silently until Reddit is restarted. Reddit links the website opens without loading a new page now open in the app too. After turning ads off, RedditFilter asks you to reopen Reddit if your account was in the Reddit experiment that loads Home ads differently.

## New in 1.3.3

- **Swipe to collapse**: swipe a comment left to collapse it and its replies, or swipe further to collapse the whole thread, like the 2024 app. The comment slides with your finger and shows what will happen. Swiping left on a collapsed comment or on the post still moves to the next post, and swiping right still goes back. Off by default; turn it on under **Collapsing comments**.
- **Collapsing comments settings**: a new section for **Swipe to collapse**, **Tap to collapse too** and the **AutoMod** switch. With swipe on, tapping or long pressing anywhere on a comment no longer collapses it, so it can't happen by accident. Links and spoilers still open with a tap. Turn on **Tap to collapse too** to keep both. A collapsed comment always opens with a tap.
- **Open Reddit links in the app**: a Safari extension now opens Reddit links from Safari in RedditFilter. Safari asks before each one. To set it up, tap **Open Reddit links here** in the new **Safari** section of RedditFilter settings.
- **RedGIFs quality**: RedGIFs has its own settings section, with **HD video** (off by default, so videos play in SD and use less data) and **HD on Wi-Fi only**, which plays SD on mobile data and in Low Data Mode.
- **Fixes**: ads no longer appear on the Home feed for users in a Reddit experiment that loads it differently. The IPA no longer includes Reddit's crash report extension, so SideStore and AltStore can install it.

## New in 1.3.2

- **Coloured comment threads**: new option that gives each reply level's thread line its own colour. Each comment's own line is in full colour and the lines of the comments above it are faded. Turn on **Apollo style** to colour only each comment's own line. Off by default. Lines Reddit already colours, like a highlighted comment's, keep their colour.
- **Update check**: once a day, RedditFilter checks GitHub for a new release and shows an alert once for each one. That includes the same RedditFilter version rebuilt for a newer Reddit version. RedditFilter settings also show when an update is available. Turn it off with **Check for updates** under About.
- **Redesigned settings**: RedditFilter settings now look like Reddit's current Settings and follow its theme colours. They open in their own sheet with a close button. **Filters** is now called **Tweaks**. Section headers and footers grow with your text size.
- **Fixes**: icons no longer disappear from settings rows. A highlighted comment's gold line no longer shifts the thread colours.

## New in 1.3.1

- **Ads and filters came back for some users**: Reddit is moving some users to a new server address, and RedditFilter didn't filter anything coming from it. Ads, keywords and every other filter now work on both.
- **Feeds don't wait long for extra checks**: if the full-text keyword check or the extra page loaded for a short For You feed is slow, the page now appears after at most 5 seconds instead of waiting for it. With RedGIFs direct-play on, RedGIFs videos and the full-text check now load at the same time.
- **Keywords ignore link addresses**: a keyword only matches the visible text of a link, not the address it points to.
- **Full-text check after a Reddit update**: after you update Reddit, RedditFilter no longer reuses the request it saved from the previous version.
- **RedGIFs**: videos loading at the same time now share one RedGIFs sign-in instead of each asking for their own.
- **Sideloaded installs**: fixed a crash at launch when the app couldn't read its keychain settings, and a memory leak in keychain access.

## New in 1.3.0

- **Keywords check the whole post**: posts are hidden when a keyword appears anywhere in their text, not just in the title or the preview shown in the feed. Feed cards that show the whole post are now checked too. With keywords set, checking full text adds one batch request per feed page before it appears. If that request fails, title and preview filtering still apply.
- **Filter comments too**: new option under Keywords to hide comments that mention a keyword. Their replies are hidden as well, unless you turn off **Hide replies too**: then the comment is replaced by a "Hidden by keyword filter" placeholder and its replies stay.
- **Direct-play RedGIFs**: new option to play RedGIFs videos with sound. Reddit's copies of RedGIFs videos have no audio, so RedditFilter plays the original from RedGIFs instead, in posts and in the feed. It may use more data, and your device connects to RedGIFs directly. If RedGIFs can't be reached, Reddit's silent version plays as before.
- **Clearer settings**: every switch now says what it does. The **Promoted**, **Recommended** and **NSFW** switches show that content when on; turn **Promoted** off to hide ads. Icons are aligned and follow your light or dark theme.

## Fixes for Reddit 2026.43.0

- **Comment ads** are hidden again.
- **NSFW filter** now hides NSFW posts in the new feed cards and in community highlights.
- **Recommended filter** no longer empties the For You feed, which is now mostly recommendations (your subscriptions are in Following). It still removes the "Related answers" section on post pages.
- **Videos for you**: new option to hide the "Videos for you" carousel in your feed.
- **For You** no longer stops after a few posts when hidden posts leave the first page too short to scroll.
- **Keywords**: new option to hide posts that mention a word or phrase. In RedditFilter settings, tap **Keywords** to add them (separate several with commas). Swipe a keyword to remove it, or use **Clear All Keywords**. Matching is whole-word and ignores capitals.
- **RedditFilter settings** are back: Profile → Settings, button at the top right.
- **Logging in** now works on sideloaded installs (see below).

## Logging in

Log in as usual: **I already have an account** (or **Log in**) → **Use email or username**, then type your username and password. To add another account, open the account switcher → **Add account** → **Log in**.

When the app is sideloaded, Reddit can't check that the app is its own build, so RedditFilter tells it this iPhone can't do that check (as some devices can't), which Reddit accepts. If Reddit still turns the login down, a reddit.com sheet opens, fills in your username and password and logs in for you, closing by itself once you're in. If Reddit asks for a 2FA code or a check there, finish it in the sheet.

Your password only goes to Reddit, the same as logging in on the website.

**Continue with Google** works from the app's own login screen.

### Other options

For accounts without a Reddit password, such as ones made with Apple, or if the steps above stop working after a Reddit update, tap **Other options** at the top right of the login screen:

- **Log in with browser**: log in on the reddit.com page that opens, including with **Continue with Apple** or **Continue with Google** and any 2FA code. The app finishes logging in by itself.
- **Open login link**: first tap **Email me a login link instead**, then copy the link from Reddit's email and paste it here.

## Install

Download the IPA from [Releases](../../releases), sign it with your usual signer and install it.

## Build

On a Mac with Xcode and [Homebrew](https://brew.sh):

```sh
git clone https://github.com/and101/RedditFilter.git
cd RedditFilter
./build-ipa.sh /path/to/decrypted-Reddit.ipa
```

The IPA is saved in `packages/`, unsigned. The script installs anything missing (Theos, theos-jailed, insert_dylib and a few Homebrew packages) at the versions used for the released IPAs, so builds match. The Reddit IPA must be decrypted.

For jailbroken devices, `make package` builds a deb (add `THEOS_PACKAGE_SCHEME=rootless` for rootless).

## Credits

Based on original work from [level3tjg](https://github.com/level3tjg/RedditFilter) and [NicholasBly](https://github.com/NicholasBly/RedditFilter).

The sideloaded IPA includes [RedditSideloadFix](https://github.com/level3tjg/RedditSideloadFix) by level3tjg (MIT), with fixes, and [fishhook](https://github.com/facebook/fishhook) (BSD).
