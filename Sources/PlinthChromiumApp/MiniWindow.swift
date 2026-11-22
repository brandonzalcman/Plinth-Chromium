import AppKit
import Observation
import SwiftUI
import PlinthCEF
import PlinthModel

// Links from other apps open in a mini window: the page and nothing else, no bar. It shares cookies
// with the main windows but not their page list. ⇧⌘↩ (File ▸ Move to Main Window, or the pill at the
// top right) moves the page into the frontmost main window, keeping the same Chromium browser, where
// it joins its site like any other page. As in the Mac app (MiniWindowController.swift).

/// One item waiting to be taken over by the next page opened with its address. Pure bookkeeping
/// for the pool's hand-over of a mini window's browser (the Mac app's `pendingAdoption`).
struct AdoptionSlot<Item> {
    private(set) var pending: (url: URL, item: Item)?

    /// Offers `item` for the next page opened with `url`. Returns an earlier offer it displaced.
    @discardableResult
    mutating func offer(_ item: Item, url: URL) -> Item? {
        let displaced = pending?.item
        pending = (url, item)
        return displaced
    }

    /// The offered item, if the page being made has the offered address. It is taken only once.
    mutating func take(matching url: URL) -> Item? {
        guard let offer = pending, offer.url == url else { return nil }
        pending = nil
        return offer.item
    }

    /// Withdraws the offer and returns what was left untaken.
    mutating func clear() -> Item? {
        defer { pending = nil }
        return pending?.item
    }
}

/// Which main window a mini window's page moves into. Pure.
enum MiniPromotion {
    struct Candidate: Equatable {
        var id: WindowID
        var isPrivate: Bool
        /// The window has a controller (it is on screen).
        var isShowing: Bool
    }

    /// The key main window if it is showing and not private, otherwise the first window that isn't
    /// private (shown if need be). nil means a new window has to be made. Never a private window:
    /// the page was made with the shared profile's cookies.
    static func target(keyWindow: WindowID?, windows: [Candidate]) -> WindowID? {
        if let key = keyWindow, let match = windows.first(where: { $0.id == key }), match.isShowing, !match.isPrivate {
            return key
        }
        return windows.first { !$0.isPrivate && $0.isShowing }?.id ?? windows.first { !$0.isPrivate }?.id
    }

    /// The address the page is opened with: where the browser is now, or where it started if it
    /// hasn't reported an address yet.
    static func address(current: String, initial: URL) -> URL {
        guard !current.isEmpty, let url = URL(string: current), url.scheme != nil else { return initial }
        return url
    }
}

/// Where the page sits in a mini window: below the strip that holds the traffic lights and the
/// "Move to Main Window" pill, with the main window's margin on the other sides. Full screen, edge to edge.
enum MiniWindowLayout {
    static let stripHeight: CGFloat = ContentGeometry.titlebarHeight

    static func pageFrame(in size: CGSize, fullScreen: Bool) -> CGRect {
        guard !fullScreen else { return CGRect(origin: .zero, size: size) }
        let m = ContentGeometry.margin
        return CGRect(x: m, y: m, width: max(0, size.width - 2 * m), height: max(0, size.height - m - stripHeight))
    }
}

/// What the mini window's SwiftUI draws from.
@MainActor
@Observable
final class MiniChrome {
    /// The page in view coordinates (origin bottom-left), once its window is showing.
    var pageFrame: CGRect?
    var radius: CGFloat = ContentGeometry.cornerRadius
}

@MainActor
final class MiniWindowController: NSObject, NSWindowDelegate, PCEFBrowserDelegate {
    let window: NSWindow
    let initialURL: URL
    private unowned let app: ChromiumApp
    private(set) var browser: PCEFBrowser?
    /// A clear window above the page that rounds its corners, like the main window's overlay.
    private let caps: NSWindow
    private let chrome = MiniChrome()
    private var promoted = false

    init(app: ChromiumApp, url: URL) {
        self.app = app
        initialURL = url
        var frame = NSRect(x: 0, y: 0, width: 980, height: 720)
        if let screen = NSScreen.main?.visibleFrame {
            frame.origin = NSPoint(x: screen.midX - frame.width / 2 + 40, y: screen.midY - frame.height / 2 - 40)
        }
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        caps = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 420, height: 320)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.title = url.host ?? "Plinth"
        window.delegate = self
        let root = NSHostingView(rootView: MiniRoot(app: app, chrome: chrome, onPromote: { [weak self] in
            guard let self else { return }
            self.app.promote(self)
        }))
        root.sizingOptions = []
        root.frame = NSRect(origin: .zero, size: frame.size)
        root.autoresizingMask = [.width, .height]
        window.contentView = root

        caps.isOpaque = false
        caps.backgroundColor = .clear
        caps.hasShadow = false
        caps.ignoresMouseEvents = true
        caps.isReleasedWhenClosed = false
        let capsRoot = NSHostingView(rootView: MiniCaps(chrome: chrome))
        capsRoot.sizingOptions = []
        caps.contentView = capsRoot
        window.addChildWindow(caps, ordered: .above)

        browser = PCEFBrowser(url: url.absoluteString, profile: .shared, delegate: self)
        layoutPage()
    }

    private var isFullScreen: Bool { window.styleMask.contains(.fullScreen) }

    /// Puts the page's window over the space below the strip, with the corner caps above it.
    private func layoutPage() {
        let size = window.contentView?.bounds.size ?? window.frame.size
        let frame = MiniWindowLayout.pageFrame(in: size, fullScreen: isFullScreen)
        chrome.radius = isFullScreen ? 0 : ContentGeometry.cornerRadius
        caps.setFrame(window.frame, display: true)
        guard let browser, browser.hostWindow != nil else { chrome.pageFrame = nil; return }
        browser.attach(to: window, frame: window.convertToScreen(frame), cornerRadius: chrome.radius)
        if chrome.pageFrame != frame { chrome.pageFrame = frame }
        if window.childWindows?.last !== caps {
            window.removeChildWindow(caps)
            window.addChildWindow(caps, ordered: .above)
            caps.setFrame(window.frame, display: false)
        }
        if window.isKeyWindow { focusPage() }
    }

    private func focusPage() {
        browser?.hostWindow?.makeKey()
        browser?.focus()
    }

    /// Hands the browser over (for the move into a main window); the window then closes without
    /// closing it.
    func detachBrowser() -> PCEFBrowser? {
        guard let b = browser else { return nil }
        promoted = true
        b.attach(to: nil, frame: .zero, cornerRadius: 0)
        browser = nil
        return b
    }

    /// Closes the page for good (quitting).
    func closeBrowser() {
        browser?.close()
        browser = nil
    }

    // MARK: Window delegate

    func windowDidResize(_ notification: Notification) { layoutPage() }
    func windowDidEnterFullScreen(_ notification: Notification) { layoutPage() }
    func windowDidExitFullScreen(_ notification: Notification) { layoutPage() }
    func windowDidBecomeKey(_ notification: Notification) { focusPage() }

    func windowWillClose(_ notification: Notification) {
        if !promoted {
            browser?.attach(to: nil, frame: .zero, cornerRadius: 0)
            browser?.close()
            browser = nil
        }
        window.removeChildWindow(caps)
        caps.orderOut(nil)
        app.miniWindowDidClose(self)
    }

    // MARK: PCEFBrowserDelegate

    func browser(_ browser: PCEFBrowser, didChangeAddress address: String) {}
    func browser(_ browser: PCEFBrowser, didChangeTitle title: String) {
        window.title = title.isEmpty ? (URL(string: browser.address)?.host ?? initialURL.host ?? "Plinth") : title
    }
    func browser(_ browser: PCEFBrowser, didChangeFaviconURL url: String?) {}
    func browserLoadingStateChanged(_ browser: PCEFBrowser) {}
    func browser(_ browser: PCEFBrowser, didChangeProgress progress: Double) {}

    func browser(_ browser: PCEFBrowser, openURL url: String, disposition: PCEFOpenDisposition, userGesture: Bool) -> Bool {
        // Scripted popups (sign-in windows) keep their own small window and their opener.
        if disposition == .popup { return false }
        // A link that wants a new page opens in a main window, where pages live.
        if let target = URL(string: url) { app.openFromMiniWindow(target) }
        return true
    }

    func browser(_ browser: PCEFBrowser, fullscreenChanged fullscreen: Bool) {
        if fullscreen != isFullScreen { window.toggleFullScreen(nil) }
    }

    func browser(_ browser: PCEFBrowser, shouldNavigateTo url: String, linkClick: Bool, isRedirect: Bool) -> Bool { true }

    func browser(_ browser: PCEFBrowser, handleKeyEquivalent event: NSEvent) -> Bool {
        NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    func browserDidClose(_ browser: PCEFBrowser) {
        // The page closed itself (window.close()): the mini window goes with it.
        guard !promoted, self.browser === browser else { return }
        self.browser = nil
        window.close()
    }

    func browserHostWindowReady(_ browser: PCEFBrowser) {
        DispatchQueue.main.async { [weak self] in self?.layoutPage() }
    }

    func browserDidActivate(_ browser: PCEFBrowser) {}
}

// MARK: - Views

/// The mini window's surface: the strip with the pill, a hairline round the page, and a blank sheet
/// while the page's window is still being made.
private struct MiniRoot: View {
    let app: ChromiumApp
    let chrome: MiniChrome
    let onPromote: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let palette = ShellPalette(scheme)
            let page = MiniWindowLayout.pageFrame(in: size, fullScreen: chrome.radius == 0)
            let flipped = CGRect(x: page.minX, y: size.height - page.maxY, width: page.width, height: page.height)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(palette.surface)
                RoundedRectangle(cornerRadius: chrome.radius, style: .continuous)
                    .fill(chrome.pageFrame == nil ? (scheme == .dark ? Color(white: 0.16) : .white) : .clear)
                    .overlay(RoundedRectangle(cornerRadius: chrome.radius, style: .continuous).stroke(palette.hairline, lineWidth: 1))
                    .frame(width: flipped.width, height: flipped.height)
                    .offset(x: flipped.minX, y: flipped.minY)
                    .allowsHitTesting(false)
                HStack {
                    Spacer()
                    PromotePill(accent: app.accent(scheme), action: onPromote)
                        .padding(.trailing, 10)
                }
                .frame(width: size.width, height: MiniWindowLayout.stripHeight)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
    }
}

/// The page's four corners covered with the surface colour, in the clear window above the page.
private struct MiniCaps: View {
    let chrome: MiniChrome
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            if let r = chrome.pageFrame {
                // The caps window covers the whole window, title bar included: same coordinates as the content.
                CornerCaps(frames: [CGRect(x: r.minX, y: geo.size.height - r.maxY, width: r.width, height: r.height)],
                           radius: chrome.radius, colour: ShellPalette(scheme).surface)
            }
        }
        .ignoresSafeArea()
    }
}

/// "Move to Main Window ⌘⇧↩" at the top right of a mini window.
struct PromotePill: View {
    let accent: Color
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 10, weight: .semibold))
                Text("Move to Main Window")
                    .font(.system(size: 12, weight: .medium))
                Text("⌘⇧↩")
                    .font(.system(size: 11))
                    .opacity(0.6)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .foregroundStyle(hovering ? Color.white : (scheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.86)))
            .background(Capsule().fill(hovering ? accent : (scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.07))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Move this page into the main window")
    }
}

// MARK: - App

extension ChromiumApp {
    /// A link from another app opens in a mini window with no bar.
    func openFromOtherApp(_ url: URL) {
        let mini = MiniWindowController(app: self, url: url)
        miniWindows.append(mini)
        mini.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func miniWindowDidClose(_ mini: MiniWindowController) {
        miniWindows.removeAll { $0 === mini }
    }

    /// The mini window in front: its own window or its page's window is key.
    var keyMiniWindow: MiniWindowController? {
        guard let key = NSApp.keyWindow else { return nil }
        return miniWindows.first { $0.window === key || key.parent === $0.window }
    }

    /// The main window a mini window's page (or a link from one) goes into, made and shown if need be.
    private func mainWindowForMini() -> WindowID {
        let candidates = store.windows.map {
            MiniPromotion.Candidate(id: $0.id, isPrivate: $0.isPrivate, isShowing: controller(for: $0.id) != nil)
        }
        let target = MiniPromotion.target(keyWindow: keyWindowID, windows: candidates) ?? store.createWindow()
        if controller(for: target) == nil { showController(for: target) }
        return target
    }

    /// Moves the mini window's page into the frontmost main window, keeping its Chromium browser.
    func promote(_ mini: MiniWindowController) {
        guard let browser = mini.detachBrowser() else { mini.window.close(); return }
        let url = MiniPromotion.address(current: browser.address, initial: mini.initialURL)
        mini.window.close()
        let target = mainWindowForMini()
        pool.offerForAdoption(browser, url: url)
        store.openPage(url: url, in: target, select: true, opener: nil)
        // Not taken (the store picked an existing page): that browser is closed and the page shows as usual.
        pool.endAdoption()
        controller(for: target)?.window.makeKeyAndOrderFront(nil)
        controller(for: target)?.refreshContent()
    }

    /// A link in a mini window that asked for a new page.
    func openFromMiniWindow(_ url: URL) {
        let target = mainWindowForMini()
        store.openPage(url: url, in: target, select: true, opener: nil)
        controller(for: target)?.window.makeKeyAndOrderFront(nil)
    }

    /// ⇧⌘↩: a mini window's page moves into a main window; a peek card's page opens as a page.
    @objc func menuPromoteMini(_ sender: Any?) {
        if let mini = keyMiniWindow { promote(mini) } else { keyController?.promotePeek() }
    }
}
