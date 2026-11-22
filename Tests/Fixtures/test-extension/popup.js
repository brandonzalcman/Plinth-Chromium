// Proves the popup has the extension APIs: it reads its own id and the active tab.
chrome.tabs.query({ active: true, lastFocusedWindow: true }, (tabs) => {
  const tab = tabs && tabs[0] ? tabs[0].url : "none";
  document.getElementById("out").textContent = "id " + chrome.runtime.id + " · active tab " + tab;
  document.title = "popup ok " + chrome.runtime.id.slice(0, 6) + " tab=" + tab;
});
