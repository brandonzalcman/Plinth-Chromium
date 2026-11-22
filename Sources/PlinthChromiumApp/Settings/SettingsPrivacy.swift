import SwiftUI
import AppKit
import PlinthSettings

/// Chromium keeps its own privacy controls (cookies, HTTPS-First, site permissions, clearing data),
/// so this section links to them rather than repeating the Mac app's WebKit switches. Plinth's own
/// history (⌘Y, and what iCloud sync shares) is cleared here, as on the Mac.
struct PrivacySettingsView: View {
    let app: ChromiumApp
    @Environment(\.settingsTheme) private var t
    @State private var range = ClearRange.lastHour
    @State private var result: String?
    private var settings: SettingsStore { app.settings }

    var body: some View {
        SettingsPage(title: "Privacy & Security") {
            SettingsCard(heading: "Address bar") {
                SettingsToggleRow(title: "Search suggestions", caption: "Shows suggestions from your search engine as you type in the address bar. This sends what you type to that engine.", isOn: settings.binding(\.searchSuggestionsEnabled))
            }

            SettingsCard(heading: "History") {
                SettingsRow(title: "Time range", caption: "Pages Plinth remembers for History (⌘Y) and search. With iCloud sync on, they are cleared on your other devices too.") {
                    SettingsMenuPicker(label: "Time range", options: ClearRange.allCases.map { ($0, $0.displayName) }, selection: $range)
                }
                SettingsDivider()
                HStack(spacing: 12) {
                    SettingsButton(title: "Clear History…", style: .destructive) { confirmClear() }
                    if let result {
                        Text(result).font(.system(size: 11.5)).foregroundStyle(t.p.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }

            SettingsCard(heading: "Chromium") {
                SettingsRow(title: "Privacy and security", caption: "Cookies, HTTPS, site permissions and safe browsing are set in Chromium's own settings.") {
                    SettingsButton(title: "Open…") { app.openFromSettings(URL(string: "chrome://settings/privacy")!) }
                }
                SettingsDivider()
                SettingsRow(title: "Clear browsing data", caption: "Chromium's own history, cookies and cached files, for a time range you choose.") {
                    SettingsButton(title: "Clear…") { app.openFromSettings(URL(string: "chrome://settings/clearBrowserData")!) }
                }
            }
        }
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear history?"
        alert.informativeText = "This removes the pages you visited \(range == .allTime ? "of all time" : range.displayName.lowercased()) from Plinth's history\(app.sync != nil ? ", here and on your other devices" : ""). This can't be undone."
        let clear = alert.addButton(withTitle: "Clear History")
        clear.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard let window = app.settingsWindow ?? NSApp.keyWindow else { return }
        let range = range
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let removed = app.clearHistory(since: range.since())
            result = "Cleared \(removed) history \(removed == 1 ? "entry" : "entries")" + (range == .allTime ? "." : " (\(range.displayName.lowercased())).")
        }
    }
}
