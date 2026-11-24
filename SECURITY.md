# Security policy

Plinth Chromium is a web browser, so security reports matter. Thank you for taking the time.

## Reporting a vulnerability

Please **do not** open a public issue. Report it privately through GitHub's [private vulnerability reporting](https://github.com/brandonzalcman/Plinth-Chromium/security/advisories/new). Include:

- what the issue is and its impact;
- steps or a page that reproduces it;
- the Plinth Chromium version or commit, and your macOS version.

You'll get an acknowledgement as soon as possible. Fixes ship in a new release, and reporters are credited unless they ask not to be.

## Scope

In scope: Plinth Chromium's own code. That includes the CEF bridge, how pages, popups and extension windows are handled, the password and import code, downloads, persistence, and the update feed.

Out of scope:

- Bugs in Chromium or CEF themselves. Report those to the [Chromium project](https://www.chromium.org/Home/chromium-security/reporting-security-bugs/) or the [CEF project](https://github.com/chromiumembedded/cef). We'll update CEF when they're fixed.
- Behaviour shared with Plinth. Report that to [Plinth](https://github.com/brandonzalcman/Plinth/security/advisories/new).
- macOS itself. Report that to Apple at [security.apple.com](https://security.apple.com).

## Known limitations

Chromium's process sandbox is not enabled yet (see [docs/architecture.md](docs/architecture.md)). Reports that rely only on that are known; reports of ways to exploit it are still welcome.
