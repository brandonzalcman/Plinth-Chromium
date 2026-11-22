import AppKit
import Observation
import SwiftUI
import PlinthCEF
import PlinthModel
import PlinthPanels

// The peek card over a Plinth window. Pages are Chromium windows above Plinth's own, so, like the
// resume card, the peek has windows of its own, children of the Plinth window stacked above the
// pages and below the overlay:
//
//   pages · the peek window (a dimmed backdrop and the shared `PeekCardView`) · the previewed page's
//   own Chromium window, placed over the card's body · the overlay (which rounds that page's corners)
//
// A click on the backdrop closes the card; so do Escape and its × button. "Open as Page" (Return, or
// ⇧⌘↩) hands the same Chromium browser to the pool as a page in this window, the way a mini window's
// page moves into a main window, so it keeps its history, scroll and form state.

/// What the card's header shows, as the previewed page reports it.
@MainActor
@Observable
final class PeekState {
    var title = ""
    var url: URL?
    var isLoading = true
    var progress = 0.0
    /// The card, in the peek window's coordinates (origin bottom-left; the same as the Plinth window's).
    var card: CGRect = .zero
}

/// Takes the first click even while another window (the previewed page) has the keyboard, so one
/// click on the backdrop closes the card and one on a button presses it.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The backdrop and card's window. It can become key, so Return and Escape reach the card.
final class PeekWindow: NSWindow {
    var onEscape: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape() }
}

@MainActor
final class PeekController: NSObject, PCEFBrowserDelegate {
    let initialURL: URL
    let window: PeekWindow
    let state = PeekState()
    private unowned let host: BrowserWindowController
    private(set) var browser: PCEFBrowser?
    /// Stands in for the page inside `PeekCardView`; the page's own window sits over it.
    private let placeholder = NSView()
    private var keyMonitor: Any?
    private var handedOver = false

    init(host: BrowserWindowController, url: URL, profile: PCEFProfile) {
        self.host = host
        initialURL = url
        window = PeekWindow(contentRect: host.overlayFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        state.url = url
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.onEscape = { [weak self] in self?.host.closePeek() }
        let root = FirstClickHostingView(rootView: PeekRoot(peek: self, app: host.app, isPrivate: host.isPrivate))
        root.sizingOptions = []
        window.contentView = root
        browser = PCEFBrowser(url: url.absoluteString, profile: profile, delegate: self)
        // Escape closes the card while the previewed page has the keyboard too, as on the Mac.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let page = self.browser?.hostWindow, event.window === page || NSApp.keyWindow === page else { return event }
            self.host.closePeek()
            return nil
        }
    }

    /// The previewed page's frame on screen, or nil before it can be placed.
    var pageScreenFrame: NSRect? {
        guard let parent = window.parent else { return nil }
        return parent.convertToScreen(PeekLayout.pageFrame(inCard: state.card))
    }

    /// Covers the Plinth window below its title strip and places the card over `page` (the page area,
    /// in the Plinth window's content coordinates), then the previewed page over the card.
    func layout(in parent: NSWindow, frame: NSRect, page: CGRect) {
        if window.frame != frame { window.setFrame(frame, display: true) }
        let card = PeekLayout.cardFrame(page: page)
        if state.card != card { state.card = card }
        if window.parent !== parent { parent.addChildWindow(window, ordered: .above) }
        if let browser, browser.hostWindow != nil, let screen = pageScreenFrame {
            browser.attach(to: parent, frame: screen, cornerRadius: PeekLayout.pageRadius)
        }
    }

    /// Takes the card and its page off screen. `keepBrowser` hands the page's browser back for "Open as
    /// Page"; otherwise it is closed.
    func tearDown(keepBrowser: Bool) -> PCEFBrowser? {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
        guard let b = browser else { return nil }
        browser = nil
        handedOver = true
        b.attach(to: nil, frame: .zero, cornerRadius: 0)
        if keepBrowser { return b }
        b.close()
        return nil
    }

    // MARK: PCEFBrowserDelegate

    func browser(_ browser: PCEFBrowser, didChangeAddress address: String) {
        if let url = URL(string: address) { state.url = url }
    }

    func browser(_ browser: PCEFBrowser, didChangeTitle title: String) { state.title = title }
    func browser(_ browser: PCEFBrowser, didChangeFaviconURL url: String?) {}

    func browserLoadingStateChanged(_ browser: PCEFBrowser) {
        state.isLoading = browser.isLoading
        if !browser.isLoading { state.progress = 1 }
    }

    func browser(_ browser: PCEFBrowser, didChangeProgress progress: Double) { state.progress = progress }

    func browser(_ browser: PCEFBrowser, openURL url: String, disposition: PCEFOpenDisposition, userGesture: Bool) -> Bool {
        let target = URL(string: url)
        switch LinkOpening.decide(LinkDisposition(disposition), userGesture: userGesture, url: target) {
        case .popup:
            return false
        case .peek:
            // ⇧-click inside the preview previews that link instead.
            browser.loadURL(url)
        case .page(let background):
            if let target { host.openFromPeek(target, background: background) }
        }
        return true
    }

    func browser(_ browser: PCEFBrowser, fullscreenChanged fullscreen: Bool) {}
    func browser(_ browser: PCEFBrowser, shouldNavigateTo url: String, linkClick: Bool, isRedirect: Bool) -> Bool { true }

    func browser(_ browser: PCEFBrowser, handleKeyEquivalent event: NSEvent) -> Bool {
        NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    func browserDidClose(_ browser: PCEFBrowser) {
        // The page closed itself (window.close()): the card goes with it.
        guard !handedOver, self.browser === browser else { return }
        self.browser = nil
        host.closePeek()
    }

    func browserHostWindowReady(_ browser: PCEFBrowser) {
        DispatchQueue.main.async { [weak self] in self?.host.syncPeek() }
    }

    func browserDidActivate(_ browser: PCEFBrowser) {}
}

// MARK: - Views

/// The dimmed backdrop and the card. The card's body is left to the previewed page's window.
private struct PeekRoot: View {
    let peek: PeekController
    let app: ChromiumApp
    let isPrivate: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        GeometryReader { geo in
            let card = peek.state.card
            ZStack(alignment: .topLeading) {
                // Not fully clear: the window server sends clicks on clear pixels to the window below.
                Color.black.opacity(0.18)
                    .contentShape(Rectangle())
                    .onTapGesture { peek.closeFromCard() }
                    .accessibilityLabel("Close preview")
                    .accessibilityAddTraits(.isButton)
                PeekCardView(title: peek.state.title, url: peek.state.url, isLoading: peek.state.isLoading,
                             progress: peek.state.progress, content: peek.placeholderView,
                             accent: app.accent(isPrivate ? .dark : scheme),
                             onOpen: { peek.openFromCard() }, onClose: { peek.closeFromCard() })
                    .frame(width: card.width, height: card.height)
                    .scaleEffect(shown || reduceMotion ? 1 : 0.97)
                    .offset(x: card.minX, y: geo.size.height - card.maxY)
            }
            .opacity(shown ? 1 : 0)
        }
        .ignoresSafeArea()
        .preferredColorScheme(isPrivate ? .dark : nil)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.88)) { shown = true }
        }
    }
}

extension PeekController {
    fileprivate var placeholderView: NSView { placeholder }
    fileprivate func closeFromCard() { host.closePeek() }
    fileprivate func openFromCard() { host.promotePeek() }
}
