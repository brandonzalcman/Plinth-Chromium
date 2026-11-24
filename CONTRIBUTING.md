# Contributing to Plinth Chromium

Thanks for helping. Plinth Chromium is a small, opinionated browser, so changes that keep it calm and simple are the easiest to accept.

## Before you start

- **Bugs:** open an issue with steps to reproduce, your macOS version, and what you expected.
- **Features:** open an issue to discuss before you write code.
- **Behaviour shared with Plinth.** Naming, pins, folders, groups, fading, the shelf, sync and the AI features live in the [Plinth](https://github.com/brandonzalcman/Plinth) package, so changes to them belong there.
- **Security problems:** please don't open a public issue; follow [SECURITY.md](SECURITY.md).

## Set up

You need macOS 26, Xcode 26 (Swift 6.2) and about 1 GB free for CEF and the build.

```bash
git clone https://github.com/brandonzalcman/Plinth-Chromium.git
```

```bash
cd Plinth-Chromium && Scripts/fetch-cef.sh && swift build && swift test
```

If `swift` can't find the SDK, prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

Build the app with `Scripts/bundle.sh`. Run it on a throwaway profile, so your own browsing data is never touched:

```bash
PLINTH_STORAGE=/tmp/plinth-chromium-dev "build/Plinth Chromium.app/Contents/MacOS/Plinth Chromium"
```

Chromium allows only one running copy per profile, so give each test run its own `PLINTH_STORAGE` folder. The README lists the other development switches.

## How the code is organised

- **`PlinthCEF`** is the only code that talks to CEF. Keep CEF types out of Swift: add a small Objective-C method to `PlinthCEF.h` instead.
- **Pure logic** has unit tests and no UI: `PlinthSidebar`, `PlinthExtensions`, `PlinthBrowserImport`, and the logic types in `PlinthChromiumApp` (geometry, routing, peek rules and the like).
- **The app shell** (`Sources/PlinthChromiumApp`) wires the shared store's events to Chromium pages, windows and panels.

[docs/architecture.md](docs/architecture.md) explains why each page has its own window, how the overlay works, and the known gaps.

## Conventions

- **Language mode.** The app targets use Swift 5 language mode, as set in `Package.swift`.
- **Tests.** Write them for new logic, using Swift Testing (`import Testing`, `@Test`, `#expect`). Tests must not touch the network, your real profile or the Keychain.
- **Brand.** UI follows Plinth's palette and type: ink, paper, sand, Plinth blue and peach, the sky gradient, and Space Grotesk for names and headings (`Brand.swift`). Check light and dark.
- **Comments.** Keep them short and about *why*.
- **AI features** must respect the on-device AI switch and degrade quietly when the model is unavailable.
- **Never commit** signing identities, Team IDs, provisioning profiles, API keys or anything from your own profile. `Vendor/`, `build/` and `.build/` stay out of git.

## Sending a pull request

1. Fork the repo and create a branch from `main`.
2. Make your change, with tests where it makes sense.
3. Run `swift build` and `swift test`. Both must pass.
4. For anything visible, try it in the bundled app and attach a screenshot to the PR.
5. Open the pull request and describe what changed and why.

By contributing, you agree that your contributions are licensed under the [GPL v3](LICENSE), the project's licence.

## Code of conduct

Be kind and constructive. Harassment or personal attacks aren't welcome in issues, pull requests or discussions; maintainers may remove such content and block people who post it.
