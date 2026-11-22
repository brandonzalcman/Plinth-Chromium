import SwiftUI
import AppKit
import PlinthBrowserImport

extension ChromiumApp {
    /// The home folder imports read from. `PLINTH_IMPORT_HOME` points them at a fixture folder, so test
    /// launches never read the person's real browser data.
    var importHome: URL {
        if let path = ProcessInfo.processInfo.environment["PLINTH_IMPORT_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Where a Chromium-family browser's Safe Storage key comes from. Scratch profiles never ask the
    /// Keychain: they use `PLINTH_IMPORT_SAFE_STORAGE` (a made-up key for fixture logins) or refuse.
    var safeStorageKeys: SafeStorageKeyProviding {
        guard isScratchProfile else { return KeychainSafeStorage() }
        if let key = ProcessInfo.processInfo.environment["PLINTH_IMPORT_SAFE_STORAGE"] { return FixedSafeStorage(password: Data(key.utf8)) }
        return NoKeychain()
    }
}

/// Scratch profiles: the Keychain is never asked.
private struct NoKeychain: SafeStorageKeyProviding {
    func safeStoragePassword(service: String, account: String) throws(ImportFailure) -> Data {
        throw ImportFailure(kind: .permissionDenied, message: "Test profiles don't read the Keychain. Import a CSV export instead.")
    }
}

/// Plain-language statement of where imported bookmarks end up.
enum ImportCopy {
    static let bookmarksExplanation = "Bookmarks and history from the other browsers on this Mac. Imported bookmarks are added to Bookmarks, in a folder named for the browser, keeping their folders. Open them with ⌥⌘B. Passwords are imported in Passwords."
}

struct ImportSettingsView: View {
    let app: ChromiumApp
    @State private var installed: [ImportSource] = []

    var body: some View {
        SettingsPage(title: "Import", subtitle: ImportCopy.bookmarksExplanation) {
            ForEach(installed) { source in
                ImportCard(app: app, source: source)
            }
            let missing = ImportSource.allCases.filter { !installed.contains($0) }
            if !missing.isEmpty {
                SettingsCard(heading: "Not on this Mac") {
                    SettingsNote(text: missing.map(\.displayName).joined(separator: ", ")
                                 + (missing.count == 1 ? " wasn't found. Open it once so it creates its data, then come back." : " weren't found. Open a browser once so it creates its data, then come back."))
                }
            }
        }
        .onAppear { installed = ImportService.installedSources(home: app.importHome) }
    }
}

private struct ImportCard: View {
    let app: ChromiumApp
    let source: ImportSource
    @Environment(\.settingsTheme) private var t
    @State private var bookmarks = true
    @State private var history = true
    @State private var running = false
    @State private var report: ImportReport?
    @State private var failure: ImportFailure?
    @State private var profiles: [BrowserProfile] = []

    var body: some View {
        SettingsCard(heading: "From \(source.displayName)") {
            SettingsRow(title: source.displayName, caption: caption) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(t.accentText)
                    .accessibilityLabel("Found on this Mac")
            }
            SettingsDivider()
            SettingsRow(title: "Bookmarks") { Toggle("Import bookmarks", isOn: $bookmarks).labelsHidden().toggleStyle(.checkbox) }
            SettingsDivider()
            SettingsRow(title: "History") { Toggle("Import history", isOn: $history).labelsHidden().toggleStyle(.checkbox) }
            SettingsDivider()
            HStack(spacing: 12) {
                SettingsButton(title: running ? "Importing…" : "Import…", style: .accent) { start() }
                    .disabled(running || (!bookmarks && !history))
                if running { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            if let report { result(report) }
            if let failure { problem(failure) }
        }
        .onAppear { profiles = ImportService.profiles(source, home: app.importHome) }
    }

    private var caption: String {
        switch source.family {
        case .chromium where profiles.count > 1:
            "Found on this Mac, with \(profiles.count) profiles: \(profiles.map(\.name).joined(separator: ", ")). All of them are imported."
        case .firefox where !profiles.isEmpty:
            "Found on this Mac. The profile \(source.displayName) last used is imported."
        default:
            "Found on this Mac."
        }
    }

    @ViewBuilder private func result(_ report: ImportReport) -> some View {
        SettingsDivider()
        SettingsNote(text: summary(report), tone: .good)
        ForEach(report.notes, id: \.self) { SettingsNote(text: $0) }
    }

    private func summary(_ report: ImportReport) -> String {
        var parts: [String] = []
        if report.bookmarksImported > 0 || bookmarks { parts.append("\(report.bookmarksImported) bookmark\(report.bookmarksImported == 1 ? "" : "s")") }
        if report.historyImported > 0 || history { parts.append("\(report.historyImported) history entr\(report.historyImported == 1 ? "y" : "ies")") }
        return "Imported " + parts.joined(separator: " and ") + "."
    }

    @ViewBuilder private func problem(_ failure: ImportFailure) -> some View {
        SettingsDivider()
        SettingsNote(text: failure.message, tone: .error)
        switch failure.kind {
        case .permissionDenied:
            SettingsNote(text: "In System Settings ▸ Privacy & Security ▸ Full Disk Access, turn on Plinth, then try again.", tone: .warning)
            HStack {
                SettingsButton(title: "Open Full Disk Access") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.bottom, 10)
        case .notFound:
            SettingsNote(text: "Open \(source.displayName) once so it creates its data, then try again.")
        case .unreadable:
            SettingsNote(text: "Quit \(source.displayName) and try again.")
        }
    }

    private func start() {
        running = true; report = nil; failure = nil
        let source = source, bookmarks = bookmarks, history = history, home = app.importHome
        Task { @MainActor in
            do {
                report = try await ImportService.run(source, bookmarks: bookmarks, history: history, into: app.store,
                                                     bookmarkStore: app.bookmarks, home: home)
            } catch let error as ImportFailure {
                failure = error
            } catch {
                failure = ImportFailure(kind: .unreadable, message: "The import didn't finish.")
            }
            running = false
        }
    }
}
