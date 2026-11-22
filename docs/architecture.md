# Architecture

## Engine: Swift/AppKit + CEF (Chrome style)

Chosen over Electron (would mean rewriting Plinth's UI and logic in JavaScript) and a full Chromium
fork (100 GB checkouts, hours-long builds, a rebase every four weeks). The deciding need was Chrome
extensions, which CEF supports only in **Chrome style**. If CEF ever blocks something, the next step
is building CEF from source with patches — effectively a fork — without throwing away this app.

| | CEF (this app) | Electron | Chromium fork |
| --- | --- | --- | --- |
| Shared Plinth logic | Reused as is (Swift package) | Rewritten in JS | Rewritten in C++ or bridged |
| Chrome extensions | Chrome's own extension system (Chrome style) | Partial `chrome.*` support | Full |
| Signing / notarization | Sign the framework, 5 helper apps, then the app; hardened runtime needs `allow-jit` and `allow-unsigned-executable-memory` for the renderer | electron-builder does it | Same as Chrome |
| Auto-update | Sparkle, like the Mac app | electron-updater | Your own updater (Omaha/Sparkle) |
| Build | Minutes; CEF is a prebuilt download | Minutes | Hours, ~100 GB |

## How a page is shown

CEF has two hard limits on macOS that shape everything:

1. A browser hosted in our own `NSView` (`CefWindowInfo.parent_view`) is always **Alloy** style, and
   Alloy doesn't run Chrome extensions. Chrome style needs CEF's Views framework (`CefWindow` +
   `CefBrowserView`).
2. A Chrome-style `CefWindow` can hold **one** Chrome-style `CefBrowserView`, ever ("Cannot add
   multiple Chrome style BrowserViews"), so tabs can't be swapped inside one CEF window.

So each Plinth page is a Chrome-style browser in its **own frameless CEF window**
(`PCEFBrowser.hostWindow`), clipped to rounded corners and attached as a child window *above* Plinth's
own `NSWindow`, over the space the chrome leaves for it. Plinth's window draws the surface and the dock
or sidebar; pages sit on top, so they get clicks and keys directly. (A first version put pages *below*
a transparent hole in Plinth's window; macOS doesn't pass clicks through to them, so that was dropped.)

What has to float over the page — the command bar, shelf, downloads tray, find bar and the collapsed
sidebar's hover flyout — lives in a clear `OverlayWindow`, the topmost child, which ignores the mouse
whenever nothing is showing in it. It starts below the title strip so the traffic lights stay usable.
Switching pages attaches a different child window; split view attaches two.

Visibility goes through Views (`CefWindow::Show/Hide`) so Chromium knows when a page is hidden.

## Shared logic

`BrowserStore`, `BarLayoutEngine`, `BottomBarView`, the panels, fading, groups, pins and pin folders,
search and suggestions all come from the public Plinth package. `ActionRouter` is a line-for-line port
of the Mac app's `AppController.handle(_:in:)`; the dock and the sidebar both send `BarAction`s
through it, so the two layouts can't drift apart. `PlinthSidebar` builds its model from the same
`BarInput` the bar's layout engine takes, and its tests check it agrees with the engine on current
pages, pin order and ⌘-number shortcuts.

## The sidebar

Plinth's own design rather than a tab list: pins stand on a raised slab at the top (the plinth), each
website is a quiet card with its pages listed by name under a thin guide line, the current page gets
the accent, pages about to fade go faint behind the bar's dashed outline, and the whole column folds
to a 60-point rail of icons. Group chips filter it like the bar's group focus.

## Extensions

Chromium's toolbar is hidden, so Plinth lists installed extensions from the profile
(`Secure Preferences` + each `manifest.json`) behind a puzzle-piece button and opens an extension's
popup page in a small Chrome-style window attached above the Plinth window. Content scripts and
extension pages run in Chromium as usual. Browsers Chromium opens by itself (session restore,
`chrome.tabs.create`) go through CEF's default client, which closes them and opens their address as a
Plinth page.

## Profile and session

Plinth's state lives in `~/Library/Application Support/Plinth Chromium/state.json` (the shared store's
format); Chromium's profile is in `…/Chromium`. Chromium's own `Sessions` folder is cleared at launch
so it never reopens its windows behind Plinth's. Private windows get an in-memory CEF request context
each, dropped when the window closes.

## Known gaps (first cut)

- **Extension popups don't see an active tab.** A popup runs in its own window, so
  `chrome.tabs.query({active: true, currentWindow: true})` doesn't return the page you're on; popups
  that act on the current page (most ad blockers' per-site toggles) need a fix (likely giving pages
  Chrome tab identities or patching CEF).
- **Extensions without a popup** (action `onClicked` only) can't be triggered yet; there's no Plinth
  route to `chrome.action.onClicked`. Extension context menus and page-action icons aren't shown.
- **Web Store installs not yet checked by hand.** Content scripts and popups were verified with an
  unpacked extension; installing from chromewebstore.google.com (the "Add to Chrome" prompt) still
  needs a manual try.
- **Quit doesn't end Chromium cleanly.** `CefQuitMessageLoop` doesn't return from the run loop with
  the Chrome bootstrap; Plinth flushes cookies, stops AppKit's loop and skips `CefShutdown` (which
  crashes in that state). Chromium may treat the next launch as after a crash.
- **Background pages restored from the last session load only when first shown.**
- Downloads are Plinth's own (saved to the Downloads folder or the one in Settings, shown in the
  dock's downloads button, the sidebar and the shared downloads tray); Chromium's download bubble is off.
- Not ported yet from the Mac app: iCloud sync (needs the signed Xcode target and entitlements),
  bookmarks UI, a history panel (Chromium's `chrome://history` is used), passwords (Chromium's built-in manager runs instead; Plinth's
  Apple Passwords import/export isn't wired in), Points & Levels, Ask,
  the welcome guide, peek, split-view divider dragging, page snapshots on the shelf,
  content blocking (use an extension for now), and drag-and-drop between windows.
- **No Chromium sandbox** (`no_sandbox`), no hardened runtime, no notarization, no Sparkle yet.
- On-device AI (Foundation Models, as on the Mac) drives semantic history and the resume card's summary.
  Page text comes from the shared reader script, evaluated in the page's main frame by Plinth's renderer
  helper (`-[PCEFBrowser evaluateJavaScript:completion:]`, a process message to `PlinthChromiumHelper`),
  with Chromium's plain text as a fallback. Unlike WebKit's isolated content world, it runs in the page's
  own JavaScript world, so a page that rewrites built-ins can affect what is read.
- The resume card floats in a small child window of its own, above the pages and below the overlay, so its
  × button gets clicks while the rest of the page still does.
