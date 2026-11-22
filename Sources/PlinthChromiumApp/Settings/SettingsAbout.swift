import SwiftUI
import PlinthCEF
import PlinthSettings

/// The app's version and the Chromium engine it runs on.
struct AboutSettingsView: View {
    var body: some View {
        SettingsPage(title: "About") {
            SettingsCard {
                SettingsRow(title: "Plinth", caption: AppVersion.current.displayString) { EmptyView() }
                SettingsDivider()
                SettingsRow(title: "Engine", caption: "Chromium \(PCEFRuntime.chromiumVersion())") { EmptyView() }
            }
        }
    }
}
