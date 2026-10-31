// Sends the Reddit pages the official app opens (its universal links) to the RedditFilter app.
// The rules follow Reddit's apple-app-site-association files for each domain.
(() => {
  const SCHEME = "redditfilter";

  // Languages Reddit is translated into, for language paths ("/de/r/pics", "/pt-br/") and
  // language sites ("de.reddit.com").
  const LANGUAGES =
    "bg|bn|cs|da|de|el|en|es|fi|fil|fr|hi|hr|hu|id|it|ja|ko|ms|nb|nl|pl|pt|ro|ru|sk|sr|sv|th|tr|uk|vi|zh";
  const LANGUAGE = new RegExp("^/(" + LANGUAGES + ")(-[a-z]{2,4})?(/|$)", "i");
  // The official app only takes the en, ja, ol and dd sites; the other language sites are
  // included here as well.
  const LANGUAGE_HOST = new RegExp("^(" + LANGUAGES + ")\\.reddit\\.com$");

  // Hosts with Reddit's main list of app paths.
  const MAIN_HOSTS = new Set([
    "reddit.com", "www.reddit.com", "m.reddit.com", "old.reddit.com", "new.reddit.com",
    "np.reddit.com", "i.reddit.com", "amp.reddit.com", "s.reddit.com", "en.reddit.com",
    "ja.reddit.com", "ol.reddit.com", "dd.reddit.com", "alb.reddit.com", "applink.reddit.com",
  ]);

  // Paths that open in the app, with or without anything after them ("/r/*").
  const PREFIXES = [
    "/r/", "/x/", "/u/", "/user/", "/comments/", "/live/", "/message/", "/c/", "/chat/",
    "/channel/", "/notifications/a/", "/verification/", "/rpan/", "/search/", "/vault/",
    "/submit/", "/magic_link/", "/talk/", "/avatar/", "/redditchat/", "/recap/", "/explore/",
    "/answers/", "/trending/", "/p/", "/page/", "/mail/", "/reviews/",
  ];
  // Paths that open in the app only as they are.
  const EXACT = new Set([
    "/", "/prefs/update", "/coins", "/earn", "/premium", "/layer", "/subreddits/create",
    "/onboarding", "/passwordrecovery", "/trends", "/reddit-pro", "/reviews", "/redditchat",
  ]);
  // Rules Reddit matches without regard to capitals (the language ones below are too).
  const ANY_CASE_PREFIXES = ["/recap/", "/explore/", "/answers/", "/reviews/"];
  const ANY_CASE_EXACT = new Set(["/passwordrecovery", "/reviews"]);

  function opensInApp(host, path) {
    if (host === "chat.reddit.com") return true;
    if (host === "mod.reddit.com") return path === "/" || path.startsWith("/mail/") || path.startsWith("/redir/");
    if (!MAIN_HOSTS.has(host) && !LANGUAGE_HOST.test(host)) return false;

    const trimmed = path.replace(/\/$/, "");
    const lower = path.toLowerCase();
    if (EXACT.has(path) || EXACT.has(trimmed) || PREFIXES.some((prefix) => path.startsWith(prefix))) return true;
    if (ANY_CASE_EXACT.has(trimmed.toLowerCase()) || ANY_CASE_PREFIXES.some((prefix) => lower.startsWith(prefix)))
      return true;

    const language = path.match(LANGUAGE);
    if (!language) return false;
    const rest = "/" + lower.slice(language[0].length);
    return rest === "/" || rest.startsWith("/r/") || rest.startsWith("/x/");
  }

  const url = new URL(location.href);
  if (window.top !== window) return;
  // Reddit's own way to keep a link on the web, plus one of ours.
  if (url.searchParams.get("$web_only") === "true" || url.searchParams.has("rf_web")) return;
  if (!opensInApp(url.hostname.toLowerCase(), url.pathname)) return;

  // Don't send the same page twice in a row, so going back to Safari or cancelling the prompt
  // leaves the web page usable.
  const key = "redditfilter-sent";
  try {
    if (sessionStorage.getItem(key) === url.href) return;
    sessionStorage.setItem(key, url.href);
  } catch (error) {}

  const target = SCHEME + "://" + url.host + url.pathname + url.search + url.hash;
  const openHere = () => location.replace(target);
  try {
    browser.runtime.sendMessage({ open: target }).then(
      (response) => { if (!response || !response.ok) openHere(); },
      openHere,
    );
  } catch (error) {
    openHere();
  }
})();
