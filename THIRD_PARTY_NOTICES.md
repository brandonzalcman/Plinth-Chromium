# Third-party notices

Plinth Chromium is licensed under the GNU GPL v3 (see [LICENSE](LICENSE)). It builds on the following software, each under its own licence.

| Component | How it's used | Licence |
| --- | --- | --- |
| [Plinth](https://github.com/brandonzalcman/Plinth) (`PlinthCore`, `PlinthMacUI`) | Swift package dependency | GNU GPL v3 |
| [Chromium Embedded Framework](https://github.com/chromiumembedded/cef) | Downloaded by `Scripts/fetch-cef.sh` into `Vendor/cef` (not in this repository); its wrapper library is compiled into the app and its framework is bundled | BSD 3-Clause (`Vendor/cef/LICENSE.txt`) |
| [Chromium](https://www.chromium.org) | Inside the CEF framework | BSD 3-Clause and the licences of Chromium's own third-party code, listed in full at `chrome://credits` in the app and in `Vendor/cef/CREDITS.html` |
| [Sparkle](https://sparkle-project.org) | Swift package dependency, for updates | MIT |
| [Space Grotesk](https://github.com/floriankarsten/space-grotesk) | Bundled font (`Sources/PlinthChromiumApp/Resources/Fonts`) | SIL Open Font License 1.1 (`Sources/PlinthChromiumApp/Resources/Fonts/OFL.txt`) |

Plinth Chromium isn't affiliated with or endorsed by Google, the Chromium project or the CEF project. "Chrome" and "Chromium" are trademarks of Google LLC.
