import SwiftUI
import PlinthSettings

/// Chromium keeps its own privacy controls (cookies, HTTPS-First, site permissions, clearing data),
/// so this section links to them rather than repeating the Mac app's WebKit switches.
struct PrivacySettingsView: View {
    let app: ChromiumApp
    private var settings: SettingsStore { app.settings }

    var body: some View {
        SettingsPage(title: "Privacy & Security") {
            SettingsCard(heading: "Address bar") {
                SettingsToggleRow(title: "Search suggestions", caption: "Shows suggestions from your search engine as you type in the address bar. This sends what you type to that engine.", isOn: settings.binding(\.searchSuggestionsEnabled))
            }

            SettingsCard(heading: "Chromium") {
                SettingsRow(title: "Privacy and security", caption: "Cookies, HTTPS, site permissions and safe browsing are set in Chromium's own settings.") {
                    SettingsButton(title: "Open…") { app.openFromSettings(URL(string: "chrome://settings/privacy")!) }
                }
                SettingsDivider()
                SettingsRow(title: "Clear browsing data", caption: "History, cookies and cached files, for a time range you choose.") {
                    SettingsButton(title: "Clear…") { app.openFromSettings(URL(string: "chrome://settings/clearBrowserData")!) }
                }
            }
        }
    }
}
