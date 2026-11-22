import SwiftUI
import PlinthSettings

struct AppearanceSettingsView: View {
    let app: ChromiumApp
    @Environment(\.settingsTheme) private var t
    private var settings: SettingsStore { app.settings }

    /// The brand colours unlock by level, from Points & Levels; the base accents are always there.
    static let brandAccents: [AccentChoice] = [.dusk, .meadow, .ember, .midnight, .mono]
    static let standardAccents: [AccentChoice] = AccentChoice.allCases.filter { !brandAccents.contains($0) }

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
                        ForEach(Self.standardAccents, id: \.self) { choice in swatch(choice) }
                    }
                }
                SettingsDivider()
                SettingsRow(title: "Brand colours", caption: "Unlock one for each level you reach, from Points & Levels.") {
                    HStack(spacing: 9) {
                        ForEach(Self.brandAccents, id: \.self) { choice in swatch(choice) }
                    }
                }
            }

            SettingsCard(heading: "App icon") {
                AppIconPicker(app: app)
                SettingsDivider()
                SettingsNote(text: "Changes Plinth's icon in the Dock while it runs. The icon in Finder and the Applications folder stays Sunrise, and the Dock goes back to it when Plinth quits. The other colours unlock as you level up.")
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
        let level = app.loyaltyLevel ?? 1
        let locked = choice.unlockLevel > level
        // A saved accent the level no longer unlocks is not shown as selected: blue is in use.
        let on = settings.value.accent.effective(atLevel: level) == choice
        return Button { if !locked { settings.update { $0.accent = choice } } } label: {
            Circle().fill(color).frame(width: 20, height: 20)
                .overlay { if locked { Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.white) } }
                .opacity(locked ? 0.55 : 1)
                .padding(3)
                .overlay(Circle().strokeBorder(on ? t.p.primary : .clear, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .help(locked ? "\(choice.displayName): unlocks at level \(choice.unlockLevel)" : choice.displayName)
        .accessibilityLabel(locked ? "\(choice.displayName), locked until level \(choice.unlockLevel)" : choice.displayName)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}
