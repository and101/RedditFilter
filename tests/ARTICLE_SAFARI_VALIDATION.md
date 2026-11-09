# Article Safari validation

Record the Reddit version, RedditFilter commit, device/model, iOS or iPadOS version, blocker and enabled filters when reporting a result. The switch is **Appearance → Open article links in Safari**. The bundled **Open Reddit links here** Safari extension is a separate feature for incoming links.

## Automated coverage

CI runs `tests/run-sim.sh` on one available iPhone simulator and one available iPad simulator. The job logs the selected model and runtime. It uses the runtimes already installed on the macOS runner; it does not download older runtimes or establish coverage for every supported iOS release. The arm64 device build is also compiled once, without running on a physical device.

`ArticleSafariTests.mm` uses UIKit, WebKit and SafariServices objects with controlled presenters and navigation stacks. It checks URL eligibility, safe presentation, exact stack identity, visible article selection, preloads, one-shot behavior, and preserving native navigation when handoff fails. It does not run the Reddit application, fetch a website, or activate a third-party blocker. See the test assertions for the precise cases exercised by the current commit.

The article fixtures also exercise portrait and landscape window sizes for phones and tablets, plus a narrow split-window size. These are geometry checks; they do not rotate the simulator or prove behavior under iPad multitasking.

The build's iOS 16 deployment target is not evidence of a successful iOS 16 runtime test. Older supported releases and hardware need the manual checks below, using a Reddit build that itself supports that OS.

## Manual device matrix

These are validation tasks, not completed-test claims. Mark each result with its exact device and OS; untested combinations remain unverified.

| Device or configuration | Exercise | Expected result |
| --- | --- | --- |
| Current supported iPhone/iOS | From both a feed and an opened post, tap an article; use Done; repeat with the switch off | Safari returns to the correct Reddit screen when enabled; the original route remains available when disabled |
| Older supported iPhone/iOS | Repeat the same routes, including repeated opens and back navigation | No crash or lost screen; unsupported routes fall back to Reddit |
| iPad/iPadOS | Open and dismiss in portrait, landscape, and supported Split View sizes; rotate before and during presentation | Controls remain usable and dismissal restores the intended screen |
| Reduce Motion on, then off | Repeat article open/Done, rapid taps, and back navigation with **Settings → Accessibility → Motion → Reduce Motion** | No stacked sheets, stuck transition, or extra pop |
| Native Safari content blocker enabled, then disabled | Use the same article and provider filters; compare the sheet and full Safari | The sheet opens in both cases; verify blocking separately, without assuming full Safari extension features apply |
| Mixed media and other sheets | Open native video, swipe to an article, open login or another modal, and return | Videos/login keep their routes; later swipes and preloads do not unexpectedly trigger Safari |
| Official Reddit also installed | Open RedditFilter directly, then test incoming Reddit links in a fresh Safari tab with its extension enabled | Article setting works inside the intended app; incoming-link routing is checked independently |
| A new Reddit release or newly observed article route | Exercise feed and post-page routes before accepting the new build | Treat the route as unverified until checked; retain native behavior when the hook no longer matches |

Fixture sizes and controlled completion callbacks can test geometry and transition logic, but do not replace physical rotation, iPad multitasking, or the OS Reduce Motion setting. Content-blocker effectiveness also requires a device check with the actual provider and filters.
