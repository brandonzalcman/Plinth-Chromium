import SwiftUI
import AppKit
import PlinthPanels

/// The sections, in sidebar order. The raw value is the stable id used by `select(section:)`.
/// The Mac app's Passwords, Downloads, On-device AI and Import sections are left out:
/// those features aren't in the Chromium build yet.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, startup, appearance, loyalty, privacy, extensions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .startup: "Startup & Pages"
        case .appearance: "Appearance"
        case .loyalty: "Points & Levels"
        case .privacy: "Privacy & Security"
        case .extensions: "Extensions"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .startup: "house"
        case .appearance: "paintbrush"
        case .loyalty: "rosette"
        case .privacy: "hand.raised"
        case .extensions: "puzzlepiece.extension"
        case .about: "info.circle"
        }
    }
}

/// Sidebar plus the selected section.
struct SettingsRoot: View {
    let app: ChromiumApp
    var navigation: SettingsNavigation
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = SettingsTheme(p: PanelPalette(scheme), accent: app.accent(scheme),
                                  amber: scheme == .dark ? Color(red: 0.95, green: 0.70, blue: 0.30) : Color(red: 0.70, green: 0.42, blue: 0.0),
                                  danger: scheme == .dark ? Color(red: 1.0, green: 0.45, blue: 0.45) : Color(red: 0.78, green: 0.18, blue: 0.18),
                                  isDark: scheme == .dark)
        HStack(spacing: 0) {
            SettingsSidebar(navigation: navigation)
                .frame(width: 206)
            Rectangle().fill(theme.p.divider).frame(width: 0.5)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(navigation.selected)
        }
        // The window's vibrancy is a neutral grey in dark mode; tint it towards the panel surface so the cards sit on it.
        .background(scheme == .dark ? theme.p.surface.opacity(0.8) : Color.clear)
        .environment(\.settingsTheme, theme)
        .tint(theme.accent)
        .frame(minWidth: 760, minHeight: 560)
        .ignoresSafeArea()
    }

    @ViewBuilder private var detail: some View {
        switch navigation.selected {
        case .general: GeneralSettingsView(app: app)
        case .startup: StartupSettingsView(app: app)
        case .appearance: AppearanceSettingsView(app: app)
        case .loyalty: LoyaltySettingsView(app: app)
        case .privacy: PrivacySettingsView(app: app)
        case .extensions: ExtensionsSettingsView(app: app)
        case .about: AboutSettingsView()
        }
    }
}

struct SettingsSidebar: View {
    var navigation: SettingsNavigation
    @Environment(\.settingsTheme) private var t
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Settings").font(.system(size: 11, weight: .semibold)).tracking(0.6).textCase(.uppercase)
                .foregroundStyle(t.p.tertiary).padding(.leading, 12).padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            ForEach(SettingsSection.allCases) { section in
                SettingsSidebarItem(section: section, selected: navigation.selected == section) { navigation.selected = section }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 46)
        .padding(.bottom, 12)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
    }

    private func move(_ delta: Int) {
        let all = SettingsSection.allCases
        guard let i = all.firstIndex(of: navigation.selected) else { return }
        navigation.selected = all[min(max(i + delta, 0), all.count - 1)]
    }
}

private struct SettingsSidebarItem: View {
    var section: SettingsSection
    var selected: Bool
    var action: () -> Void
    @Environment(\.settingsTheme) private var t
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.symbol).font(.system(size: 12.5, weight: .medium))
                    .frame(width: 18).foregroundStyle(selected ? t.p.onAccent : t.accentText)
                Text(section.title).font(.system(size: 13, weight: selected ? .semibold : .medium)).lineLimit(1)
                    .foregroundStyle(selected ? t.p.onAccent : t.p.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? t.accent : (hovered ? t.p.hover : .clear)))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

extension ChromiumApp {
    /// Opens `url` as a new page in the last browser window and brings that window forward,
    /// so a link in Settings doesn't open behind it.
    func openFromSettings(_ url: URL) {
        openInNewPage(url)
        keyController?.window.makeKeyAndOrderFront(nil)
    }
}
