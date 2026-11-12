# RedditFilter

Filters unwanted content from the Reddit app, and adds the comment, video and link options it's missing.

To open RedditFilter, long press the sidebar button at the top left of Reddit, or go to Profile → Settings and tap the button at the top right.

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
    <td align="center"><b>Settings</b><br><sub>Filters, display and more</sub></td>
    <td align="center"><b>Collapsing comments</b><br><sub>Swipe or tap, and AutoMod</sub></td>
    <td align="center"><b>Keywords</b><br><sub>Words to hide, and comment options</sub></td>
    <td align="center"><b>Open Reddit links here</b><br><sub>Set up the Safari extension</sub></td>
  </tr>
</table>

<sub>Screenshots use a made-up community, post and users.</sub>

## Features

### Filters

- **Posts and ads**: hide promoted posts and comment ads, recommendations (including the endless **From your feed** list below a post's comments), NSFW posts, the Videos for you carousel, extra cards such as suggested communities, promos and surveys, and the floating new posts button at the top of Home. These switches show that content when on, so turn one off to hide it. A For You page left short by hidden posts is topped up from the next page.
- **Keywords**: hide posts that mention a word or phrase. Matching is whole-word and ignores capitals, and it checks a post's full text, not just the title and preview. With **Filter comments too**, comments that mention a keyword are hidden with their replies, or replaced by a placeholder if you want to keep the replies.

### Display

- **Appearance**: hide awards and scores on posts and comments, and give each reply level its own colour with **Coloured comment threads**. **Apollo style** colours only each comment's own line.
- **Article links**: choose how links opened from a post show: **Reddit's viewer**, **Reddit's viewer, full page** (without the votes and comments panel), or **Safari**, an in-app Safari sheet that uses your Safari content blockers. See [Safari article links](#safari-article-links). The Safari option is by [dukevin](https://github.com/dukevin).
- **Swipe to collapse**: swipe a comment to collapse it and its replies, or swipe further to collapse the whole thread. Choose left, right or both, with optional haptics. **Tap to collapse too** keeps tap and long press, and **AutoMod** always collapses AutoMod comments.
- **Play RedGIFs directly**: Reddit's copies of RedGIFs videos have no sound, so this plays the originals from RedGIFs instead. **Prefer SD** and **Prefer SD on mobile data** keep data use down. Your device connects to RedGIFs directly, and Reddit's silent version plays if RedGIFs can't be reached.

### Experimental features

These are new, so they're off by default. They work in any app language.

- **Keep feed position**: stay where you were in For You, Following and Popular, even after Reddit closes. Reddit normally jumps back to the top after 10 minutes away. Pull down to refresh.
- **Reopen community and post**: brings back the communities, custom feeds, profiles, searches and posts you had open, on Home, in the You tab or in the Inbox. A post opened at a comment (from the Inbox, say) reopens at that comment. Up to six screens are kept, from the bottom; a screen that can't be reopened ends what's kept, and the screens below it still come back. Posts open at the top, with a **Back to where you were** button that scrolls to the comment you were reading, including replies you had expanded and later pages of comments. Communities use their default sort. If you open Reddit from a notification or a link, that screen is shown first, and going back to Home reopens where you were, unless you went further than that screen.
- **Restore after swiping away** and **Restore for**: by default, your place only comes back if iOS closed Reddit, for 12 hours. You can also have it back after swiping Reddit away, and keep it for 24 hours or with no limit.

### More

- **Open Reddit links here**: a separate Safari extension opens incoming Reddit links from Safari in the app, asking first each time. It does not block ads or enable the article browser.
- **Stats**: see how much has been hidden in total, today and by filter. It stays on your device.
- **Backup**: export your settings, keywords and stats to a file, and import them later. No account details are included.
- **Diagnostics**: check whether RedditFilter still finds posts and ads in Reddit's responses, see how Reddit was last closed, check Safari article links, and share a report with a bug report. Nothing leaves your device unless you share it.
- **Update check**: RedditFilter checks GitHub once a day for a new release. Turn it off under **About**.

## Safari article links

Choose **Appearance → Article links → Safari** to read articles in Apple's in-app Safari sheet; **Done** returns to Reddit. If Safari can't take a link, it opens in Reddit's viewer, full page. Login, videos and other links work as usual.

For ad blocking, install an app with **native Safari content blockers** and turn them on in **Settings → Apps → Safari → Extensions**. RedditFilter supplies no blocking rules, and a Safari web extension or DNS blocker on its own may not work in the sheet.

**Open Reddit links here** is separate: it sends Reddit pages from Safari to RedditFilter.

If an article stays in Reddit's viewer, turn on **Diagnostics**, try the link again, and check **Article links** (no URLs are recorded). Device checks are listed in [the validation matrix](tests/ARTICLE_SAFARI_VALIDATION.md).

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

Based on original work by [level3tjg](https://github.com/level3tjg/RedditFilter) and [NicholasBly](https://github.com/NicholasBly/RedditFilter).

In-app Safari for article links by [dukevin](https://github.com/dukevin) ([#1](https://github.com/and101/RedditFilter/pull/1)).

The sideloaded IPA includes [RedditSideloadFix](https://github.com/level3tjg/RedditSideloadFix) by level3tjg (MIT), with fixes, and [fishhook](https://github.com/facebook/fishhook) (BSD).
