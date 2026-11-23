# Plinth Chromium

Plinth on Chromium: the same calm, native macOS browser — pages named and grouped by website, pins
and pin folders, groups, fading and the shelf — with Chromium's engine and Chrome extensions.

It's a Swift/AppKit app that embeds Chromium through [CEF](https://github.com/chromiumembedded/cef)
(Chrome style) behind a thin Objective-C++ bridge. Everything Plinth does with pages comes from the
public [Plinth](https://github.com/brandonzalcman/Plinth) package (`PlinthCore` and `PlinthMacUI`),
so tab, pin, folder and group behaviour is the Mac app's, not a copy of it.

Pages live in the bottom dock (the Mac app's bar) or in a vertical sidebar, picked in
**Settings → Pages** or **View → Pages in Sidebar / Pages in Bottom Dock**.

## Build and run

Needs macOS 26 and Xcode 26 or later. On this Mac `xcode-select` points at the Command Line Tools, so
`swift` needs `DEVELOPER_DIR`:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
Scripts/fetch-cef.sh      # once: downloads CEF 158 (macOS arm64, ~140 MB) into Vendor/cef
Scripts/bundle.sh         # builds build/Plinth Chromium.app (ad-hoc signed; no iCloud)
# Scripts/bundle.sh release --sign "<identity>" --profile <file.provisionprofile>   # with iCloud: docs/icloud-sync.md
open "build/Plinth Chromium.app"
swift test                # shared-logic tests (no Chromium needed)
```

Test launches: `PLINTH_STORAGE=<dir>` uses a throwaway profile (and skips the Keychain prompt),
`PLINTH_OPEN=<urls>` opens pages, `PLINTH_LAYOUT=dock|sidebar` picks the layout,
`PLINTH_LOAD_EXTENSION=<folder>` loads an unpacked extension, `PLINTH_IMPORT_HOME=<folder>` points import at
fixture browser data (with `PLINTH_IMPORT_SAFE_STORAGE=<made-up key>` for fixture logins; a scratch profile never
asks the Keychain and keeps passwords in memory), `PLINTH_SYNC=memory` syncs a scratch profile with an in-memory server, and `PLINTH_STEPS="wait 3; state; …"`
runs scripted steps (see `Sources/PlinthChromiumApp/DebugSteps.swift`). `PLINTH_CEF_LOG=1` logs the
CEF lifecycle. `Scripts/dev/shoot.swift <pid> <out.png>` captures only that app's windows.

## Layout

| Target | What it is |
| --- | --- |
| `CEFWrapper` | CEF's C++ wrapper library, compiled from `Vendor/cef/libcef_dll` |
| `PlinthCEF` | The Objective-C++ bridge: runtime, profiles, Chrome-style browsers in their own windows |
| `PlinthChromiumHelper` | The helper executable for Chromium's GPU, renderer, utility and plugin processes |
| `PlinthSidebar` | Pure logic for the sidebar (model, rail, intents → `BarAction`) |
| `PlinthExtensions` | Reads installed extensions and their popups from the Chromium profile |
| `PlinthBrowserImport` | Bookmark, history and password import from the other browsers on the Mac, and password CSVs |
| `PlinthChromiumApp` | The app shell: store ↔ pages, windows, dock and sidebar, panels, menu, settings |
| `PlinthChromium` | The executable |

See [docs/architecture.md](docs/architecture.md) for how pages are shown, why, and what's still missing.

## Releasing

`Scripts/release.sh <version>` builds a Developer ID signed, notarized DMG and a signed Sparkle feed in
`build/release/`. Publish both in the public repo brandonzalcman/plinth-chromium-releases as release `v<version>`,
with the notes from `release-notes/<version>.md`. It needs a Developer ID certificate, the notary profile
`plinth-notary` (`xcrun notarytool store-credentials plinth-notary`) and Sparkle's key in your login keychain.
