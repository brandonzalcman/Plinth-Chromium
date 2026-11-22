import AppKit
import Observation
import SwiftUI

// The welcome guide's window: a borderless card centred over the browser, like the Mac app's
// (Welcome.swift there). It opens on the first launch of a new profile and from Plinth ▸ Show
// Welcome Guide; finishing or skipping it is remembered in `hasCompletedOnboarding`.

extension ChromiumApp {
    /// First launch of a new profile shows the guide; a profile that already had windows predates it
    /// and is marked as seen without showing anything (see `WelcomeLaunch`).
    func launchWelcomeIfNeeded(profileHadWindows: Bool) {
        let env = ProcessInfo.processInfo.environment
        switch WelcomeLaunch.decide(hasCompleted: settings.value.hasCompletedOnboarding, profileHadWindows: profileHadWindows,
                                    override: env["PLINTH_WELCOME"], scripted: env["PLINTH_STEPS"] != nil) {
        case .show:
            // After this turn of the run loop, so the browser window is up and the guide centres on it.
            DispatchQueue.main.async { [weak self] in self?.showWelcomeGuide() }
        case .markSeen:
            settings.update { $0.hasCompletedOnboarding = true }
        case .nothing:
            break
        }
    }

    /// Also behind Plinth ▸ Show Welcome Guide. PLINTH_WELCOME_CARD=<n> starts at that card (from 0).
    func showWelcomeGuide(startingAtCard card: Int? = nil) {
        welcome?.closeNow()
        let start = card ?? ProcessInfo.processInfo.environment["PLINTH_WELCOME_CARD"].flatMap { Int($0) }
        let controller = WelcomeWindowController(app: self, flow: WelcomeFlow(startingAtCard: start))
        welcome = controller
        controller.show()
    }

    @objc func menuShowWelcome(_ sender: Any?) { showWelcomeGuide(startingAtCard: 0) }

    /// The guide's Import button: Settings ▸ Import.
    func openImportSettings() {
        showSettings()
        SettingsWindowController.shared?.select(section: "import")
    }
}

@MainActor
@Observable
final class WelcomeModel {
    var flow: WelcomeFlow
    @ObservationIgnored var onFinished: () -> Void = {}

    init(flow: WelcomeFlow) { self.flow = flow }

    func apply(_ change: (inout WelcomeFlow) -> Void) {
        change(&flow)
        if flow.isFinished { onFinished() }
    }
}

/// Borderless, so the card floats over the browser like Plinth's other panels. Escape skips.
final class WelcomeWindow: NSWindow {
    var onEscape: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape() }
}

@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    static let size = NSSize(width: 760, height: 528)
    private unowned let app: ChromiumApp
    let model: WelcomeModel
    private var finishing = false
    /// False when the guide hands over to Settings, which keeps the keyboard.
    private var returnFocus = true

    init(app: ChromiumApp, flow: WelcomeFlow) {
        self.app = app
        model = WelcomeModel(flow: flow)
        let window = WelcomeWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless],
                                   backing: .buffered, defer: false)
        super.init(window: window)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("plinth.welcome")
        window.delegate = self
        window.onEscape = { [weak self] in self?.model.apply { $0.skip() } }
        model.onFinished = { [weak self] in self?.finish() }
        let host = NSHostingView(rootView: WelcomeView(model: model, app: app,
                                                       importAction: { [weak self] in self?.openImport() }))
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.sizingOptions = []
        window.contentView = host
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        guard let window else { return }
        if let controller = app.keyController ?? app.allControllers.first {
            let f = controller.window.frame
            window.setFrameOrigin(NSPoint(x: (f.midX - Self.size.width / 2).rounded(), y: (f.midY - Self.size.height / 2).rounded()))
            // A child of the browser window, above its pages and its overlay (keepOverlayOnTop keeps it
            // last), so it stays in front of the pages' own Chromium windows.
            controller.window.addChildWindow(window, ordered: .above)
            controller.keepOverlayOnTop()
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Closes at once, without the fade (another guide is replacing it).
    func closeNow() {
        finishing = true
        window?.parent?.removeChildWindow(window!)
        window?.orderOut(nil)
        if app.welcome === self { app.welcome = nil }
    }

    private func finish() {
        guard !finishing else { return }
        finishing = true
        if !app.settings.value.hasCompletedOnboarding { app.settings.update { $0.hasCompletedOnboarding = true } }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { $0.duration = reduceMotion ? 0.1 : 0.25; window?.animator().alphaValue = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.1 : 0.25)) { [weak self] in
            guard let self, let window else { return }
            window.parent?.removeChildWindow(window)
            window.orderOut(nil)
            guard app.welcome === self else { return }
            app.welcome = nil
            app.announceLevelUpIfPossible()
            guard returnFocus else { return }
            // Hand the keyboard back to the browser: its open panel (a new window's search bar), or its page.
            guard let controller = app.keyController ?? app.allControllers.first else { return }
            controller.window.makeKeyAndOrderFront(nil)
            if controller.hasNoPanel { controller.focusPage() } else { controller.overlay.makeKey() }
        }
    }

    /// The Import button: Settings ▸ Import, closing the guide.
    func openImport() {
        returnFocus = false
        model.apply { $0.skip() }
        app.openImportSettings()
    }
}
