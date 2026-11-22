import AppKit
import WebKit
import PlinthModel
import PlinthPasswords

/// The native questions the password rules ask for one page: "Save password?" and, when several logins
/// match, which one to fill. The shared `PasswordPrompting` names a web view; Chromium pages have none, so
/// each page gets its own prompts and finds its window from the page.
@MainActor
final class PagePasswordPrompts: PasswordPrompting {
    let page: PageID
    unowned let controller: PasswordsController

    init(page: PageID, controller: PasswordsController) {
        self.page = page
        self.controller = controller
    }

    /// The Plinth window showing this page, and the clear window over its pages (where a sheet or menu
    /// shows above the page rather than under it).
    private var windows: (main: NSWindow, overlay: NSWindow)? {
        let app = controller.app
        guard let id = app.windowShowing(page), let window = app.controller(for: id) else { return nil }
        return (window.window, window.overlay)
    }

    func confirmSave(origin: WebOrigin, username: String, isUpdate: Bool, in webView: WKWebView?) async -> SaveChoice {
        if let answer = controller.debugAnswer {
            DebugSteps.log("save prompt: \(origin) \(username) update=\(isUpdate) -> \(answer)")
            return answer
        }
        guard let windows else { return .notNow }
        let alert = NSAlert()
        alert.messageText = isUpdate ? "Update the password for \(origin.displayHost)?" : "Save the password for \(origin.displayHost)?"
        alert.informativeText = "User name: \(username)\nPlinth keeps it in your Mac's Keychain."
        alert.addButton(withTitle: isUpdate ? "Update" : "Save")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Never for This Site")
        windows.main.makeKeyAndOrderFront(nil)
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: windows.main) { response in
                switch response {
                case .alertFirstButtonReturn: continuation.resume(returning: .save)
                case .alertSecondButtonReturn: continuation.resume(returning: .notNow)
                default: continuation.resume(returning: .never)
                }
            }
        }
    }

    func choose(from logins: [LoginSummary], origin: WebOrigin, in webView: WKWebView?) async -> LoginSummary? {
        if controller.debugAnswer != nil { return logins.first }
        guard let windows, let view = windows.overlay.contentView else { return nil }
        let menu = NSMenu(title: "Passwords")
        menu.addItem(withTitle: "Fill a password for \(origin.displayHost)", action: nil, keyEquivalent: "").isEnabled = false
        let picker = MenuPicker()
        for login in logins {
            let item = NSMenuItem(title: login.username.isEmpty ? "(no user name)" : login.username, action: #selector(MenuPicker.pick(_:)), keyEquivalent: "")
            item.target = picker
            item.representedObject = login.id
            menu.addItem(item)
        }
        // Shown at the pointer, over the page; returns once the person picks or dismisses it.
        let point = view.convert(windows.overlay.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: point, in: view)
        return logins.first { $0.id == picker.chosen }
    }
}

private final class MenuPicker: NSObject {
    var chosen: String?
    @objc func pick(_ sender: NSMenuItem) { chosen = sender.representedObject as? String }
}
