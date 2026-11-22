import AppKit
import Observation
import SwiftUI
import PlinthCEF
import PlinthModel
import PlinthPanels
import PlinthStore

/// Per-window UI state the SwiftUI chrome reads.
@MainActor
@Observable
final class WindowChrome {
    enum Panel: Equatable {
        case none
        case command(text: String, newPage: Bool)
        case shelf
        case downloads
        case find
    }

    var panel: Panel = .none
    var findNotFound = false
    /// The bar's last layout was compact (lets the engine add hysteresis).
    @ObservationIgnored var barWasCompact = false
    /// A page went full screen: the chrome steps aside and the page fills the window.
    var chromeHidden = false
    /// Pages whose Chromium window is showing under the hole, with where it sits (view coordinates).
    var attached: [PageID: CGRect] = [:]
    /// Shown while the selected page's window is still being made.
    var pendingFrames: [CGRect] = []
    var extensionsMenuOpen = false
    /// The collapsed sidebar is showing in full over the page while the pointer is on it.
    var flyoutOpen = false
    /// A short message, such as pages being put away on the shelf.
    var notice: String?
}

/// A clear window above the pages that holds what floats over them: the panels and the sidebar's
/// hover flyout. It ignores the mouse whenever neither is showing, so the page gets every click.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// One Plinth window. It draws the chrome (dock or sidebar) and leaves room for the page; the selected
/// page's own Chromium window sits in that room as a child window above it, so it gets clicks and keys
/// directly. Panels and the sidebar flyout float above the page in a clear overlay window.
@MainActor
final class BrowserWindowController: NSObject, NSWindowDelegate, WindowPanels {
    unowned let app: ChromiumApp
    let windowID: WindowID
    let window: NSWindow
    let overlay: OverlayWindow
    let chrome = WindowChrome()
    private var flyoutClose: DispatchWorkItem?
    private var noticeTask: DispatchWorkItem?
    let isPrivate: Bool
    /// Pages currently placed under the hole, left to right.
    private(set) var shown: [PageID] = []
    private var frameSave: DispatchWorkItem?

    init(app: ChromiumApp, windowID: WindowID) {
        self.app = app
        self.windowID = windowID
        isPrivate = app.store.isPrivate(window: windowID)
        let saved = app.store.window(windowID)?.frame
        let frame = saved.flatMap { $0.count == 4 ? NSRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
            ?? NSRect(x: 0, y: 0, width: 1280, height: 820)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        overlay = OverlayWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 560, height: 380)
        // Transparent where the page shows through; clicks there pass to the page's window below.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.delegate = self
        if saved == nil { window.center() } else { window.setFrame(frame, display: false) }
        let root = NSHostingView(rootView: WindowRoot(app: app, controller: self, chrome: chrome))
        root.frame = NSRect(origin: .zero, size: frame.size)
        root.autoresizingMask = [.width, .height]
        // By default the hosting view turns its SwiftUI content's size into the window's min and max
        // size, which locks the window. The window sizes the content, not the other way round.
        root.sizingOptions = []
        window.contentView = root

        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.isReleasedWhenClosed = false
        let overlayRoot = NSHostingView(rootView: OverlayRoot(app: app, controller: self, chrome: chrome))
        overlayRoot.sizingOptions = []
        overlay.contentView = overlayRoot
        window.addChildWindow(overlay, ordered: .above)
        overlay.setFrame(overlayFrame, display: false)
        observeStore()
        refreshContent()
    }

    var geometry: ContentGeometry {
        ContentGeometry(layout: app.prefs.value.tabLayout, sidebarCollapsed: app.prefs.value.sidebarCollapsed,
                        chromeHidden: chrome.chromeHidden,
                        accessoryHeight: app.prefs.value.tabLayout == .dock && hasAccessories ? ContentGeometry.accessoryRowHeight : 0)
    }

    /// The geometry as SwiftUI should draw it: reads the observed state so views follow changes.
    func geometryForDrawing(_ chrome: WindowChrome) -> ContentGeometry {
        _ = chrome.chromeHidden
        _ = app.prefs.value
        return geometry
    }

    /// The dock shows group chips, or a suggestion to make a group, in a row above the bar.
    var hasAccessories: Bool {
        !app.store.groups(in: windowID).isEmpty || app.store.groupSuggestion(for: windowID) != nil
    }

    private var contentSize: CGSize { window.contentView?.bounds.size ?? window.frame.size }

    // MARK: Content

    private func observeStore() {
        withObservationTracking {
            _ = app.store.window(windowID)
            _ = app.store.pins
            _ = app.store.groups
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshContent()
                self.observeStore()
            }
        }
    }

    /// The pages to show, left to right: the selected page, and its split partner when the split is on.
    private func pagesToShow() -> (ids: [PageID], fraction: Double) {
        guard let state = app.store.window(windowID), let selected = state.selectedPageID else { return ([], 0.5) }
        guard let split = state.split, split.contains(selected) else { return ([selected], 0.5) }
        let order = BarOrder.pageOrder(pins: app.store.pins(in: windowID), sites: state.sites)
        let leadingFirst = (order.firstIndex(of: split.leading) ?? 0) <= (order.firstIndex(of: split.trailing) ?? 0)
        return (leadingFirst ? [split.leading, split.trailing] : [split.trailing, split.leading],
                leadingFirst ? split.fraction : 1 - split.fraction)
    }

    func refreshContent() {
        let (ids, fraction) = pagesToShow()
        let size = contentSize
        let g = geometry
        let frames: [CGRect] = ids.count == 2
            ? { let (a, b) = g.splitFrames(in: size, fraction: fraction); return [a, b] }()
            : ids.isEmpty ? [] : [g.pageFrame(in: size)]

        // Take away pages that are no longer on screen.
        for id in shown where !ids.contains(id) {
            app.pool.existing(id)?.attach(to: nil, frame: .zero, cornerRadius: 0)
            chrome.attached[id] = nil
        }
        let changed = shown != ids
        shown = ids

        var pending: [CGRect] = []
        for (id, frame) in zip(ids, frames) {
            guard let page = app.store.page(id) else { continue }
            let browser = app.pool.browser(for: page)
            if browser.hostWindow != nil {
                browser.attach(to: window, frame: window.convertToScreen(frame), cornerRadius: g.cornerRadius)
                if chrome.attached[id] != frame { chrome.attached[id] = frame }
            } else {
                pending.append(frame)   // drawn as a blank page until Chromium's window exists
            }
        }
        if chrome.pendingFrames != pending { chrome.pendingFrames = pending }
        keepOverlayOnTop()
        for id in chrome.attached.keys where !ids.contains(id) { chrome.attached[id] = nil }

        let name = app.store.window(windowID)?.selectedPageID.flatMap { app.store.page($0)?.name } ?? "Plinth"
        window.title = (isPrivate ? "Private — " : "") + name
        if changed {
            if chrome.panel == .find { chrome.panel = .none }
            if chrome.panel == .none, window.isKeyWindow || app.pool.existing(ids.first ?? PageID())?.hostWindow?.isKeyWindow == true {
                focusPage()
            }
        }
    }

    /// A page's Chromium window just appeared: put it in place if it should be showing.
    func hostReady(_ id: PageID) {
        if shown.contains(id) { refreshContent() }
    }

    func focusPage() {
        guard chrome.panel == .none, let id = shown.first, let browser = app.pool.existing(id) else { return }
        browser.hostWindow?.makeKey()
        browser.focus()
    }

    func setChromeHidden(_ hidden: Bool) {
        guard chrome.chromeHidden != hidden else { return }
        chrome.chromeHidden = hidden
        refreshContent()
    }

    // MARK: Overlay

    /// The overlay takes the mouse only while something is showing in it.
    private func syncOverlay() {
        let interactive = chrome.panel != .none || chrome.flyoutOpen
        overlay.ignoresMouseEvents = !interactive
        if overlay.frame != overlayFrame { overlay.setFrame(overlayFrame, display: true) }
        keepOverlayOnTop()
    }

    /// The window less its title strip, so the traffic lights stay visible and usable under a panel.
    var overlayFrame: NSRect {
        var f = window.frame
        if !window.styleMask.contains(.fullScreen) { f.size.height -= ContentGeometry.overlayTopInset }
        return f
    }

    /// Pages are children of the window too; the overlay stays above all of them.
    /// Child windows stack in the order they were added, so the overlay is re-added last when it isn't.
    private func keepOverlayOnTop() {
        guard let children = window.childWindows, children.last !== overlay else { return }
        window.removeChildWindow(overlay)
        window.addChildWindow(overlay, ordered: .above)
        overlay.setFrame(overlayFrame, display: false)
    }

    /// Shows the full sidebar over the page while the pointer is on the rail.
    func openFlyout() {
        flyoutClose?.cancel()
        guard !chrome.flyoutOpen, chrome.panel == .none else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { chrome.flyoutOpen = true }
        syncOverlay()
    }

    /// Closes the flyout shortly after the pointer leaves it (a quick return keeps it open).
    func closeFlyout(after delay: TimeInterval = 0.25) {
        flyoutClose?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.chrome.flyoutOpen else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { self.chrome.flyoutOpen = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.syncOverlay() }
        }
        flyoutClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Shows a short notice over the page for a few seconds.
    func showNotice(_ text: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { chrome.notice = text }
        noticeTask?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.25)) { self?.chrome.notice = nil }
        }
        noticeTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: work)
    }

    // MARK: Panels

    var hasNoPanel: Bool { chrome.panel == .none }

    private func showPanel(_ panel: WindowChrome.Panel) {
        if chrome.flyoutOpen { chrome.flyoutOpen = false }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) { chrome.panel = panel }
        syncOverlay()
        if panel != .none { overlay.makeKey() }
    }

    func openCommandBar(newPage: Bool) {
        let current = newPage ? "" : (app.store.window(windowID)?.selectedPageID.flatMap { app.store.page($0)?.url.absoluteString } ?? "")
        showPanel(.command(text: current, newPage: newPage))
    }

    func toggleShelf() {
        if chrome.panel == .shelf { dismissPanel() } else { showPanel(.shelf) }
    }

    func toggleDownloads() {
        if chrome.panel == .downloads { dismissPanel() } else { showPanel(.downloads) }
    }

    func openFind() {
        chrome.findNotFound = false
        showPanel(.find)
    }

    @discardableResult
    func dismissPanel() -> Bool {
        guard chrome.panel != .none else { return false }
        if chrome.panel == .find, let id = shown.first { app.pool.existing(id)?.stopFinding() }
        withAnimation(.easeOut(duration: 0.18)) { chrome.panel = .none }
        syncOverlay()
        focusPage()
        return true
    }

    func submit(_ submission: CommandSubmission) {
        let store = app.store!
        let selected = store.window(windowID)?.selectedPageID
        dismissPanel()
        switch submission {
        case .text(let text, let newPage):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let url: URL
            switch app.resolver.resolve(trimmed) {
            case .url(let resolved):
                url = resolved
                store.recordSuggestionPick(url: resolved)
            case .search(let query): url = app.resolver.searchURL(for: query)
            }
            open(url, newPage: newPage || selected == nil, replacing: selected)
        case .result(let result):
            store.recordSuggestionPick(result)
            switch result.target {
            case .openPage(let page, let otherWindow):
                store.select(page, in: otherWindow)
                app.controller(for: otherWindow)?.window.makeKeyAndOrderFront(nil)
            case .pin(let pin):
                if isPrivate, let url = store.url(of: result.target) {
                    open(url, newPage: true, replacing: selected)
                } else {
                    store.selectPin(pin, in: windowID)
                }
            case .shelf(let entry, let page):
                if isPrivate {
                    if let url = store.url(of: result.target) { open(url, newPage: true, replacing: selected) }
                } else {
                    store.restore(entry: entry, page: page, into: windowID)
                }
            case .history(let url):
                open(url, newPage: true, replacing: selected)
            }
        }
        refreshContent()
    }

    private func open(_ url: URL, newPage: Bool, replacing selected: PageID?) {
        // An address typed from a pin that leaves the pin's site opens as an ordinary page, like a link would.
        let leavesPin = selected.flatMap { id in app.store.pins.first { $0.page.id == id } }
            .map { app.identity.key(for: url) != $0.key } ?? false
        if !newPage, !leavesPin, let selected {
            app.store.navigate(selected, to: url)
        } else {
            app.store.openPage(url: url, in: windowID, select: true, opener: nil)
        }
    }

    func find(_ text: String, backwards: Bool) {
        guard let id = shown.first, let browser = app.pool.existing(id) else { return }
        guard !text.isEmpty else { chrome.findNotFound = false; browser.stopFinding(); return }
        browser.find(text, forward: !backwards)
    }

    // MARK: Window delegate

    func saveFrame() {
        frameSave?.cancel()
        frameSave = nil
        let f = window.frame
        app.store.setFrame([f.origin.x, f.origin.y, f.size.width, f.size.height], for: windowID)
    }

    private func scheduleFrameSave() {
        frameSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveFrame() }
        frameSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func windowDidResize(_ notification: Notification) {
        overlay.setFrame(overlayFrame, display: true)
        refreshContent()
        scheduleFrameSave()
    }

    func windowDidMove(_ notification: Notification) { scheduleFrameSave() }

    func windowDidBecomeKey(_ notification: Notification) { app.mainWindowBecameKey(windowID) }

    func windowWillClose(_ notification: Notification) {
        saveFrame()
        for id in shown { app.pool.existing(id)?.attach(to: nil, frame: .zero, cornerRadius: 0) }
        window.removeChildWindow(overlay)
        overlay.orderOut(nil)
        shown = []
        app.windowDidClose(windowID)
    }

    func windowDidEnterFullScreen(_ notification: Notification) { refreshContent() }
    func windowDidExitFullScreen(_ notification: Notification) { refreshContent() }
}
