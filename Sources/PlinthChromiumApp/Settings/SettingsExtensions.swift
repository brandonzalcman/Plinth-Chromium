import SwiftUI
import AppKit
import PlinthExtensions

/// The extensions installed in this profile, with links to get more and to manage them in Chromium.
struct ExtensionsSettingsView: View {
    let app: ChromiumApp
    @Environment(\.settingsTheme) private var t

    var body: some View {
        let installed = app.extensions.installed
        SettingsPage(title: "Extensions", subtitle: "Plinth runs extensions from the Chrome Web Store.") {
            SettingsCard(heading: installed.isEmpty ? "Installed" : "Installed (\(installed.count))") {
                if installed.isEmpty {
                    SettingsNote(text: "No extensions yet. Once installed, they appear under the puzzle-piece button.")
                } else {
                    ForEach(Array(installed.enumerated()), id: \.element.id) { index, ext in
                        if index > 0 { SettingsDivider() }
                        row(ext)
                    }
                }
            }

            HStack(spacing: 8) {
                SettingsButton(title: "Get Extensions…", systemImage: "plus", style: .accent) { app.menuGetExtensions(nil) }
                SettingsButton(title: "Manage…") { app.menuManageExtensions(nil) }
                Spacer(minLength: 0)
            }
            .padding(.leading, 4)
        }
        .onAppear { app.extensions.refresh() }
    }

    private func row(_ ext: InstalledExtension) -> some View {
        HStack(spacing: 12) {
            Group {
                if let file = ext.iconFile, let image = NSImage(contentsOf: file) {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 15)).foregroundStyle(t.p.secondary)
                }
            }
            .frame(width: 24, height: 24)
            .opacity(ext.isEnabled ? 1 : 0.5)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(ext.name).font(.system(size: 13, weight: .medium)).foregroundStyle(t.p.primary).lineLimit(1)
                Text(ext.isEnabled ? "Version \(ext.version)" : "Version \(ext.version) · Turned off")
                    .font(.system(size: 11.5)).foregroundStyle(t.p.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
