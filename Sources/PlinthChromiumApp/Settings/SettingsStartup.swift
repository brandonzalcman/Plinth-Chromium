import SwiftUI
import PlinthSettings
import PlinthSidebar

struct StartupSettingsView: View {
    let app: ChromiumApp
    private var settings: SettingsStore { app.settings }
    private var prefs: ShellPreferencesStore { app.prefs }

    var body: some View {
        let isHomepage = settings.value.newPage == .homepage
        SettingsPage(title: "Startup & Pages") {
            SettingsCard(heading: "When Plinth opens") {
                SettingsRow(title: "Start with", caption: settings.value.startup == .restoreLastSession
                            ? "Your windows and pages come back as you left them."
                            : "Open pages go to the shelf and you start with an empty window.") {
                    SettingsSegmented(label: "Start with",
                                      options: [(StartupBehavior.restoreLastSession, "Last session"), (.startFresh, "Fresh start")],
                                      selection: settings.binding(\.startup))
                }
            }

            SettingsCard(heading: "Open pages") {
                SettingsRow(title: "Show pages in", caption: layoutCaption) {
                    HStack(spacing: 12) {
                        ForEach(TabLayout.allCases, id: \.self) { layout in
                            LayoutChoice(layout: layout, isOn: prefs.value.tabLayout == layout) {
                                prefs.update { $0.tabLayout = layout }
                            }
                        }
                    }
                }
                SettingsDivider()
                SettingsToggleRow(title: "Collapse sidebar to icons",
                                  caption: prefs.value.tabLayout == .sidebar
                                      ? "Shrinks the sidebar to a narrow rail of page icons."
                                      : "Applies when pages are in the sidebar.",
                                  isOn: Binding(get: { prefs.value.sidebarCollapsed },
                                                set: { on in prefs.update { $0.sidebarCollapsed = on } }))
                    .disabled(prefs.value.tabLayout != .sidebar)
                SettingsDivider()
                SettingsRow(title: "Fade pages to the shelf", caption: fadeCaption) {
                    SettingsMenuPicker(label: "Fade pages to the shelf",
                                       options: FadeBehavior.allCases.map { ($0, $0.displayName) },
                                       selection: settings.binding(\.fadeBehavior))
                }
            }

            SettingsCard(heading: "New pages") {
                SettingsRow(title: "A new page shows", caption: newPageCaption) {
                    SettingsSegmented(label: "A new page shows",
                                      options: [(NewPageContent.commandBar, "Search bar"), (.homepage, "Homepage"), (.blank, "Blank")],
                                      selection: settings.binding(\.newPage))
                }
                SettingsDivider()
                SettingsRow(title: "Homepage", caption: homepageCaption(isHomepage)) {
                    SettingsTextField(label: "Homepage address", placeholder: "example.com", text: settings.binding(\.homepage), width: 250)
                        .disabled(!isHomepage)
                }
                if isHomepage, !settings.value.homepage.trimmingCharacters(in: .whitespaces).isEmpty, settings.value.homepageURL == nil {
                    SettingsNote(text: "That doesn't look like a web address, so new pages will open the search bar instead.", tone: .warning)
                }
            }
        }
    }

    private var layoutCaption: String {
        switch prefs.value.tabLayout {
        case .dock: "Pages sit on the bar along the bottom of each window."
        case .sidebar: "Pages are listed down the left of each window."
        }
    }

    private var fadeCaption: String {
        switch settings.value.fadeBehavior {
        case .shorter: "Pages you haven't touched go to the shelf sooner. Applies immediately."
        case .standard: "The default: pages fade to the shelf as they go unused. Applies immediately."
        case .longer: "Pages stay on the bar about twice as long. Applies immediately."
        case .never: "Nothing fades by itself; pages leave the bar only when you put them away. Applies immediately."
        }
    }

    private var newPageCaption: String {
        switch settings.value.newPage {
        case .commandBar: "The search and address bar opens."
        case .homepage: "Your homepage loads. With no valid homepage, the search bar opens."
        case .blank: "An empty page."
        }
    }

    private func homepageCaption(_ enabled: Bool) -> String {
        enabled ? "Bare addresses like example.com get https." : "Choose Homepage above to set one."
    }
}

/// A small picture of each layout, so the choice is obvious at a glance.
struct LayoutChoice: View {
    let layout: TabLayout
    let isOn: Bool
    let action: () -> Void
    @Environment(\.settingsTheme) private var t
    @State private var hovered = false

    var body: some View {
        // The window frame, the page inside it, and the bar or list drawn in the palette's quieter tones.
        let frame = t.p.fill
        let page = t.p.surface
        let chrome = t.p.tertiary.opacity(0.45)
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(frame)
                    switch layout {
                    case .dock:
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(page)
                            Capsule().fill(chrome).frame(height: 8).padding(.horizontal, 12)
                        }
                        .padding(EdgeInsets(top: 9, leading: 6, bottom: 5, trailing: 6))
                    case .sidebar:
                        HStack(spacing: 4) {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(0..<5, id: \.self) { i in
                                    Capsule().fill(i == 1 ? t.accent.opacity(0.6) : chrome).frame(width: i == 0 ? 18 : 24, height: 4)
                                }
                                Spacer()
                            }
                            .padding(.top, 5)
                            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(page)
                        }
                        .padding(6)
                    }
                }
                .frame(width: 96, height: 60)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isOn ? t.accent : (hovered ? t.p.secondary.opacity(0.5) : t.p.border), lineWidth: isOn ? 2 : 0.5))
                Text(layout.displayName).font(.system(size: 11.5, weight: isOn ? .semibold : .medium))
                    .foregroundStyle(isOn ? t.accentText : t.p.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(layout.displayName)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
