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

  // What this tab remembers, until it's closed.
  const SENT = "redditfilter-sent"; // the last page sent, so it isn't sent twice in a row
  const ASKED = "redditfilter-asked"; // set while Safari may still be asking about it
  const CANCELS = "redditfilter-cancels"; // prompts cancelled in a row
  const WEB_ONLY = "redditfilter-web"; // set after two: the tab stays on the web
  const read = (name) => {
    try { return sessionStorage.getItem(name); } catch (error) { return null; }
  };
  const write = (name, value) => {
    try {
      if (value === null) sessionStorage.removeItem(name);
      else sessionStorage.setItem(name, value);
    } catch (error) {}
  };

  // Safari doesn't say whether Open or Cancel was tapped, but opening the app hides the page.
  // So a page still on screen when the next one is checked means the prompt was cancelled.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "hidden" || !read(ASKED)) return;
    write(ASKED, null);
    write(CANCELS, null);
  });

  function check(href, replaced) {
    const url = new URL(href);
    // Reddit's own way to keep a link on the web, plus one of ours.
    if (url.searchParams.get("$web_only") === "true" || url.searchParams.has("rf_web")) return;
    if (!opensInApp(url.hostname.toLowerCase(), url.pathname)) return;
    if (read(WEB_ONLY) || read(SENT) === url.href) return;
    // Reddit tidying the address (a share link's tracking, say) while Safari may still be asking
    // about the page isn't a new page, so it isn't a cancel and isn't sent again.
    if (replaced && read(ASKED)) return write(SENT, url.href);

    if (read(ASKED)) {
      write(ASKED, null);
      const cancels = Number(read(CANCELS) || 0) + 1;
      write(CANCELS, String(cancels));
      if (cancels >= 2) return write(WEB_ONLY, "1");
    }
    write(SENT, url.href);
    write(ASKED, "1");

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
  }

  if (window.top !== window) return;
  let current = location.href;
  // Going back or forward to a page doesn't ask again: it's a page already kept on the web, and
  // Safari won't open an app link during it anyway.
  let traversed = false;
  try {
    traversed = performance.getEntriesByType("navigation")[0].type === "back_forward";
  } catch (error) {}
  if (!traversed) check(current);

  // Reddit's website changes pages without loading a new one, so check each new address too.
  // Only the part before "#" counts, so jumping within a page doesn't ask again.
  const page = (href) => href.split("#")[0];
  const changed = (ask, replaced) => {
    if (page(location.href) === page(current)) return;
    current = location.href;
    if (ask) check(current, replaced);
  };
  if (window.navigation && typeof window.navigation.addEventListener === "function") {
    window.navigation.addEventListener("currententrychange", (event) =>
      changed(event.navigationType === "push" || event.navigationType === "replace",
        event.navigationType === "replace"));
  } else {
    // Scripts like this one can't see the page's own history calls, so look for a new address.
    // Back and forward come with popstate first, so they're noted without asking.
    window.addEventListener("popstate", () => changed(false));
    setInterval(() => changed(true), 500);
  }
  // A page restored from Safari's back-forward cache keeps this script running.
  window.addEventListener("pageshow", (event) => { if (event.persisted) current = location.href; });
})();
