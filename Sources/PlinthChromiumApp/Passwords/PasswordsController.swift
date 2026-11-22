import AppKit
import Observation
import PlinthCEF
import PlinthModel
import PlinthPasswords

/// One message from the password script, with the frame it came from. `body` can hold what was typed
/// into a login form: it is decoded into a `PageEvent` and never logged.
struct PasswordScriptMessage {
    var body: [AnyHashable: Any]
    var frameID: String
    var frameURL: String
    var isMainFrame: Bool
}

/// Plinth's own password manager in the Chromium build, as on the Mac: logins in the Mac's Keychain, the
/// shared `PasswordsCoordinator` rules for when to fill and when to offer saving, and native prompts.
/// Chromium's own password manager is turned off (see `ApplyPlinthPreferences` in PlinthCEF.mm).
@MainActor
final class PasswordsController {
    let vault: PasswordVault
    let preferences: PasswordPreferences
    let authenticator: Authenticating
    let model: PasswordsModel
    unowned let app: ChromiumApp
    /// One coordinator per page, so a login waiting for its outcome stays with the page it was typed in.
    private var coordinators: [PageID: (coordinator: PasswordsCoordinator, prompts: PagePasswordPrompts)] = [:]
    /// Scripted test launches: the answer the save prompt gives without showing.
    var debugAnswer: SaveChoice?

    /// The Keychain service Plinth Chromium keeps logins under (the Mac app uses its own).
    static let keychainService = "app.plinth.chromium.passwords"

    /// `testing` (a throwaway PLINTH_STORAGE profile) keeps logins in memory, away from the Keychain.
    init(app: ChromiumApp, storageDirectory: URL, testing: Bool, authenticator: Authenticating = DeviceAuthenticator()) {
        self.app = app
        let vault: PasswordVault = testing ? InMemoryVault() : KeychainVault(service: Self.keychainService)
        self.vault = vault
        preferences = PasswordPreferences(storageDirectory: storageDirectory)
        self.authenticator = authenticator
        model = PasswordsModel(vault: vault)
    }

    // MARK: Pages

    /// A message from the password script in one of a page's frames.
    func handle(_ message: PasswordScriptMessage, from page: PageID, browser: PCEFBrowser) {
        guard let event = PageEvent(body: message.body as NSDictionary as? [String: Any] ?? [:]),
              let url = URL(string: message.frameURL), let origin = WebOrigin(url: url) else { return }
        // A private window offers to fill but never to save.
        if browser.profile.isPrivate {
            switch event {
            case .submit, .identifier: return
            default: break
            }
        }
        let coordinator = coordinator(for: page)
        let frameID = message.frameID
        Task { @MainActor [weak browser] in
            await coordinator.handle(event, origin: origin, webView: nil, isMainFrame: message.isMainFrame) { token, username, password in
                browser?.fillPassword(inFrame: frameID, token: token, username: username, password: password)
            }
        }
    }

    func pageClosed(_ page: PageID) { coordinators[page] = nil }

    private func coordinator(for page: PageID) -> PasswordsCoordinator {
        if let existing = coordinators[page] { return existing.coordinator }
        let prompts = PagePasswordPrompts(page: page, controller: self)
        let coordinator = PasswordsCoordinator(vault: vault, preferences: preferences, prompts: prompts)
        coordinator.savedHook = { [model] in model.reload() }
        coordinators[page] = (coordinator, prompts)
        return coordinator
    }

    /// Scripted test launches: where a login waits for its outcome on a page (never the password).
    func debugPending(_ page: PageID) -> String { coordinators[page]?.coordinator.debugPendingSummary ?? "none" }

    // MARK: Apple Passwords

    /// Logins not yet known to be in Apple Passwords (new, or edited since they were last sent or imported).
    var waitingForApple: [LoginSummary] { preferences.applePasswords.waiting(in: model.logins) }

    /// Opens the Passwords app, where the person exports from or imports into it.
    func openApplePasswords() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Passwords") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Passwords for the chosen logins, after the person proves it is them. Nil when they decline.
    private func unlockedLogins(_ summaries: [LoginSummary], reason: String) async -> [Login]? {
        guard await authenticator.authenticate(reason: reason) else { return nil }
        return summaries.compactMap { summary in
            guard let secret = try? vault.password(for: summary.key) else { return nil }
            return Login(origin: summary.origin, username: summary.username, password: secret, created: summary.created, modified: summary.modified)
        }
    }

    enum AppleSend { case sent(Int), cancelled, failed(String) }

    /// Writes a CSV the Passwords app can import (File > Import Passwords from File) and opens the Passwords app.
    func exportCSVForApple(_ summaries: [LoginSummary], to url: URL) async -> AppleSend {
        guard !summaries.isEmpty else { return .sent(0) }
        guard let logins = await unlockedLogins(summaries, reason: "export your passwords as a file") else { return .cancelled }
        do {
            try Data(ApplePasswordsCSV.export(logins).utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { return .failed("Plinth couldn't write the file.") }
        preferences.markInApplePasswords(summaries)
        openApplePasswords()
        return .sent(logins.count)
    }

    // MARK: Clipboard

    /// Copies a password marked as concealed (clipboard managers skip it) and clears it after a minute if nothing else was copied.
    func copyToClipboard(_ secret: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(secret, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let count = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        }
    }
}

/// What the Settings list shows: logins without their passwords.
@MainActor
@Observable
final class PasswordsModel {
    private(set) var logins: [LoginSummary] = []
    private(set) var error: String?
    @ObservationIgnored private let vault: PasswordVault

    init(vault: PasswordVault) {
        self.vault = vault
        reload()
    }

    func reload() {
        do { logins = try vault.list(); error = nil }
        catch { self.error = "Plinth couldn't read the Keychain right now." }
    }
}

extension ChromiumApp {
    /// Starts the password manager. Called once at launch.
    func setUpPasswords() {
        passwords = PasswordsController(app: self, storageDirectory: storageDirectory, testing: isScratchProfile)
    }
}
