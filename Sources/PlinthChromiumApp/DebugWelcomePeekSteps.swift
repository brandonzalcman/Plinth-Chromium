import AppKit
import PlinthModel

/// Scripted steps for the welcome guide and peek (see DebugSteps.swift). Keys and clicks are made in this
/// process only (posted to Plinth's own event queue or sent to one of its windows), never through the
/// window server, so nothing outside the app is touched.
@MainActor
extension DebugSteps {
    static func runWelcomeOrPeek(_ command: String, _ arg: String, _ app: ChromiumApp) async -> Bool {
        let controller = app.keyController ?? app.allControllers.first
        switch command {
        case "welcome":
            app.showWelcomeGuide(startingAtCard: Int(arg))
        case "welcomestate":
            let flow = app.welcome?.model.flow
            log("welcome: open=\(app.welcome != nil) phase=\(flow.map { "\($0.phase)" } ?? "-") card=\(flow?.currentCard?.rawValue ?? "-") "
                + "seen=\(app.settings.value.hasCompletedOnboarding) layout=\(app.prefs.value.tabLayout.rawValue) "
                + "key=\(windowName(NSApp.keyWindow, app)) visible=\(app.welcome?.window?.isVisible ?? false)")
        case "welcomenext":
            app.welcome?.model.apply { $0.next() }
        case "welcomeback":
            app.welcome?.model.apply { $0.back() }
        case "welcomego":
            app.welcome?.model.apply { $0.go(to: Int(arg) ?? 0) }
        case "welcomeimport":
            // The last card's Import button.
            app.welcome?.openImport()
            try? await Task.sleep(for: .milliseconds(600))
            log("welcomeimport: guide=\(app.welcome != nil) settings=\(app.settingsWindow?.isVisible ?? false) seen=\(app.settings.value.hasCompletedOnboarding)")
        case "welcomeskip":
            app.welcome?.model.apply { $0.skip() }
        case "welcomekey", "key":
            // A key press posted to the app's own queue, so it goes through monitors and the key window.
            guard let (code, characters) = keyCodes[arg] else { log("\(command): unknown key \(arg)"); return true }
            let target = NSApp.keyWindow
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: target?.windowNumber ?? 0, context: nil, characters: characters,
                                                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            try? await Task.sleep(for: .milliseconds(400))
            log("\(command) \(arg): sent to \(windowName(target, app))")
        case "peek":
            if let url = URL(string: arg) { controller?.showPeek(url) }
        case "peekstate":
            guard let controller else { log("peek: no window"); return true }
            let children = controller.window.childWindows ?? []
            let order = children.map { windowName($0, app) }
            var atPage = "-", atBackdrop = "-"
            if let peek = controller.peek, let page = peek.pageScreenFrame {
                atPage = windowName(windowAt(NSPoint(x: page.midX, y: page.midY)), app)
                atBackdrop = windowName(windowAt(NSPoint(x: peek.window.frame.minX + 20, y: peek.window.frame.minY + 20)), app)
            }
            let browser = controller.peek?.browser
            log("peek: open=\(controller.isPeeking) title=\(controller.peek?.state.title ?? "-") url=\(controller.peek?.state.url?.absoluteString ?? "-") "
                + "loading=\(controller.peek?.state.isLoading ?? false) hostAttached=\(browser?.hostWindow?.parent === controller.window) "
                + "card=\(controller.peek.map { NSStringFromRect($0.state.card) } ?? "-") caps=\(controller.chrome.peekPage.map { NSStringFromRect($0) } ?? "-") "
                + "children=\(order) key=\(windowName(NSApp.keyWindow, app)) topmostAtPage=\(atPage) topmostAtBackdrop=\(atBackdrop) "
                + "promoteEnabled=\(app.validateMenuItem(NSMenuItem(title: "", action: #selector(ChromiumApp.menuPromoteMini(_:)), keyEquivalent: "")))")
        case "peekopen":
            let browser = controller?.peek?.browser
            controller?.promotePeek()
            let page = controller.flatMap { app.store.window($0.windowID)?.selectedPageID }
            log("peekopen: peeking=\(controller?.isPeeking ?? false) selected=\(page.flatMap { app.store.page($0)?.url.absoluteString } ?? "-") "
                + "sameBrowser=\(browser != nil && page.flatMap { app.pool.existing($0) } === browser)")
        case "peekclose":
            log("peekclose: \(controller?.closePeek() ?? false)")
        case "peekfocuspage":
            // As if the previewed page was clicked into.
            controller?.peek?.browser?.hostWindow?.makeKey()
            controller?.peek?.browser?.focus()
            try? await Task.sleep(for: .milliseconds(200))
            log("peekfocuspage: key=\(windowName(NSApp.keyWindow, app))")
        case "peekclickout":
            // A click on the dimmed backdrop, outside the card, through the peek window's own event path.
            guard let window = controller?.peek?.window else { log("peekclickout: no peek"); return true }
            let point = NSPoint(x: 20, y: 20)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
            log("peekclickout: peeking=\(controller?.isPeeking ?? false)")
        case "shiftclick":
            await shiftClick(arg, app)
        default:
            return false
        }
        return true
    }

    private static let keyCodes: [String: (UInt16, String)] = [
        "right": (124, String(UnicodeScalar(NSRightArrowFunctionKey)!)), "left": (123, String(UnicodeScalar(NSLeftArrowFunctionKey)!)),
        "return": (36, "\r"), "escape": (53, "\u{1B}"), "space": (49, " "), "tab": (48, "\t"), "d": (2, "d"), "s": (1, "s"),
    ]

    /// A real ⇧-click (an AppKit event sent to the page's own window) on the first element matching `selector`
    /// in the selected page, so Chromium sees a trusted click with ⇧ held, as it would from the mouse.
    private static func shiftClick(_ selector: String, _ app: ChromiumApp) async {
        guard let page = app.keyWindowID.flatMap({ app.store.window($0)?.selectedPageID }),
              let browser = app.pool.existing(page), let host = browser.hostWindow else { log("shiftclick: no page"); return }
        let script = "(function(){var e=document.querySelector(\(jsString(selector))); if(!e) return null; var r=e.getBoundingClientRect(); return [r.left+r.width/2, r.top+r.height/2];})()"
        let raw = await withCheckedContinuation { (done: CheckedContinuation<Any?, Never>) in
            browser.evaluateJavaScript(script) { done.resume(returning: $0) }
        }
        guard let xy = raw as? [NSNumber], xy.count == 2 else { log("shiftclick: \(selector) not found"); return }
        let height = host.contentView?.bounds.height ?? host.frame.height
        let point = NSPoint(x: CGFloat(xy[0].doubleValue), y: height - CGFloat(xy[1].doubleValue))
        host.makeKey()
        browser.focus()
        try? await Task.sleep(for: .milliseconds(200))
        // Posted to the app's own queue, so Chromium handles it as it would a click from the mouse.
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [.shift], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                NSApp.postEvent(event, atStart: false)
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
        try? await Task.sleep(for: .milliseconds(500))
        let controller = app.keyController
        log("shiftclick \(selector) at \(NSStringFromPoint(point)): peeking=\(controller?.isPeeking ?? false) "
            + "peekURL=\(controller?.peek?.state.url?.absoluteString ?? "-") pageURL=\(app.store.page(page)?.url.absoluteString ?? "-") "
            + "pages=\(app.keyWindowID.flatMap { app.store.window($0)?.sites.flatMap(\.pages).count } ?? 0)")
    }

    /// The window on top at a screen point, among all on screen.
    private static func windowAt(_ point: NSPoint) -> NSWindow? {
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        return NSApp.windows.first { $0.windowNumber == number }
    }

    /// A short name for one of Plinth's windows, for the log.
    private static func windowName(_ window: NSWindow?, _ app: ChromiumApp) -> String {
        guard let window else { return "none" }
        if window === app.welcome?.window { return "welcome" }
        for c in app.allControllers {
            if window === c.window { return "main" }
            if window === c.overlay { return "overlay" }
            if window === c.resumeCardWindow { return "card" }
            if window === c.peek?.window { return "peek" }
            if window === c.peek?.browser?.hostWindow { return "peekPage" }
            if window.parent === c.window, window.identifier?.rawValue == "plinth.page" { return "page" }
        }
        if window === app.settingsWindow { return "settings" }
        return String(describing: type(of: window))
    }
}
