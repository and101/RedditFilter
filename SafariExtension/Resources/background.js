// Opens the app link from the extension rather than the page. If Safari doesn't allow that, the
// content script opens it from the page instead.
browser.runtime.onMessage.addListener((message, sender) => {
  if (!message || typeof message.open !== "string" || !message.open.startsWith("redditfilter://"))
    return Promise.resolve({ ok: false });
  if (!sender.tab || sender.tab.id === undefined) return Promise.resolve({ ok: false });
  return browser.tabs.update(sender.tab.id, { url: message.open }).then(
    () => ({ ok: true }),
    () => ({ ok: false }),
  );
});
