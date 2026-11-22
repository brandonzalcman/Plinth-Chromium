import SwiftUI
import PlinthSettings

struct AppearanceSettingsView: View {
    let app: ChromiumApp
    @Environment(\.settingsTheme) private var t
    private var settings: SettingsStore { app.settings }

    /// The base accents. The Mac app's brand colours unlock with levels, which the Chromium build doesn't have yet.
    static let accents: [AccentChoice] = [.blue, .purple, .pink, .red, .orange, .green, .graphite]

    var body: some View {
        SettingsPage(title: "Appearance") {
            SettingsCard(heading: "Appearance") {
                SettingsRow(title: "Appearance", caption: appearanceCaption) {
                    SettingsMenuPicker(label: "Appearance",
                                       options: AppearanceChoice.allCases.map { ($0, $0.displayName) },
                                       selection: settings.binding(\.appearance))
                }
            }

            SettingsCard(heading: "Accent colour") {
                SettingsRow(title: "Accent", caption: "Used for the current page, buttons and switches. Applies immediately.") {
                    HStack(spacing: 9) {
                        ForEach(Self.accents, id: \.self) { choice in swatch(choice) }
                    }
                }
            }
        }
    }

    private var appearanceCaption: String {
        switch settings.value.appearance {
        case .system: "Follows your Mac's light or dark appearance. Applies immediately."
        case .light: "Plinth's bar, panels and settings stay light. Applies immediately."
        case .dark: "Plinth's bar, panels and settings stay dark. Websites that support dark mode follow. Applies immediately."
        }
    }

    private func swatch(_ choice: AccentChoice) -> some View {
        let c = choice.rgb
        let color = Color(red: c.r / 255, green: c.g / 255, blue: c.b / 255)
        // A saved brand colour from the Mac app isn't offered here, so blue shows as in use.
        let effective = Self.accents.contains(settings.value.accent) ? settings.value.accent : AccentChoice.blue
        let on = effective == choice
        return Button { settings.update { $0.accent = choice } } label: {
            Circle().fill(color).frame(width: 20, height: 20)
                .padding(3)
                .overlay(Circle().strokeBorder(on ? t.p.primary : .clear, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(choice.displayName)
        .accessibilityLabel(choice.displayName)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}
