// Proves the popup has the extension APIs: it reads its own id and the active tab.
chrome.tabs.query({ active: true, lastFocusedWindow: true }, (tabs) => {
  const tab = tabs && tabs[0] ? tabs[0].url : "none";
  document.getElementById("out").textContent = "id " + chrome.runtime.id + " · active tab " + tab;
  document.title = "popup ok " + chrome.runtime.id.slice(0, 6) + " tab=" + tab;
});

// What an extension's "Log in" button typically does: open a sign-in window, or a sign-in tab.
// Plinth's debug steps call these (PLINTH_STEPS "popupjs plinthLoginWindow()").
window.plinthLoginWindow = () =>
  chrome.windows.create({ url: "https://example.com/?login=window", type: "popup", width: 480, height: 600 });
window.plinthLoginTab = () => chrome.tabs.create({ url: "https://example.com/?login=tab" });
