import AppKit
import SwiftUI
import PlinthCEF
import PlinthRules
import PlinthSettings
import PlinthSidebar

extension ChromiumApp {
    func showSettings() {
        if let window = settingsWindow { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(app: self))
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }
}

/// Settings for the Chromium build: where pages live (dock or sidebar), looks, search and extensions.
struct SettingsView: View {
    let app: ChromiumApp
    @State private var refresh = 0

    var body: some View {
        let _ = refresh
        let settings = app.settings.value
        Form {
            Section("Pages") {
                Text("Show open pages in").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    ForEach(TabLayout.allCases, id: \.self) { layout in
                        LayoutChoice(layout: layout, isOn: app.prefs.value.tabLayout == layout, accent: app.accent(.light)) {
                            app.prefs.update { $0.tabLayout = layout }
                        }
                    }
                }
                .padding(.vertical, 4)
                Picker("Pages fade", selection: binding(\.fadeBehavior)) {
                    ForEach(FadeBehavior.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            Section("Appearance") {
                Picker("Appearance", selection: binding(\.appearance)) {
                    ForEach(AppearanceChoice.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Accent", selection: binding(\.accent)) {
                    ForEach([AccentChoice.blue, .purple, .pink, .red, .orange, .green, .graphite], id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
            }
            Section("Search") {
                Picker("Search engine", selection: Binding(
                    get: { app.settings.value.searchEngine.kind },
                    set: { kind in app.settings.update { $0.searchEngine.kind = kind }; refresh += 1 })) {
                    ForEach(SearchEngine.Kind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            Section("Extensions") {
                let installed = app.extensions.installed
                if installed.isEmpty {
                    Text("Install extensions from the Chrome Web Store. They appear under the puzzle-piece button.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ForEach(installed) { ext in
                        HStack {
                            Text(ext.name)
                            Spacer()
                            Text(ext.version).foregroundStyle(.secondary).font(.system(size: 11))
                        }
                    }
                }
                HStack {
                    Button("Get Extensions…") { app.menuGetExtensions(nil) }
                    Button("Manage…") { app.menuManageExtensions(nil) }
                }
            }
            Section("About") {
                LabeledContent("Engine", value: "Chromium \(PCEFRuntime.chromiumVersion())")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
        .onAppear { app.extensions.refresh() }
        .onChange(of: settings) { refresh += 1 }
    }

    private func binding<T: Equatable>(_ key: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { app.settings.value[keyPath: key] },
                set: { value in app.settings.update { $0[keyPath: key] = value }; refresh += 1 })
    }
}

/// A small picture of each layout, so the choice is obvious at a glance.
struct LayoutChoice: View {
    let layout: TabLayout
    let isOn: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.9))
                    switch layout {
                    case .dock:
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 4).fill(.white)
                            Capsule().fill(Color(white: 0.78)).frame(height: 10).padding(.horizontal, 10)
                        }
                        .padding(EdgeInsets(top: 10, leading: 6, bottom: 5, trailing: 6))
                    case .sidebar:
                        HStack(spacing: 4) {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(0..<5, id: \.self) { i in
                                    Capsule().fill(i == 1 ? accent.opacity(0.5) : Color(white: 0.78)).frame(width: i == 0 ? 24 : 30, height: 4)
                                }
                                Spacer()
                            }
                            .padding(.top, 6)
                            RoundedRectangle(cornerRadius: 4).fill(.white)
                        }
                        .padding(6)
                    }
                }
                .frame(width: 120, height: 76)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isOn ? accent : .clear, lineWidth: 2))
                Text(layout.displayName).font(.system(size: 12, weight: isOn ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
    }
}
