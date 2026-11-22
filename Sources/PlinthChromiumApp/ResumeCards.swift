import AppKit
import SwiftUI
import PlinthModel
import PlinthPanels

// The "where you left off" card: when a site comes back from the shelf, a small card at the bottom
// left of the page names the page and, with page summaries on, sums up what it was about in a
// sentence or two, written on this Mac. As in the Mac app (WindowFeatures.swift).
//
// Pages are Chromium windows above Plinth's own, and the overlay above them ignores the mouse unless
// a panel is open, so the card has a small window of its own: a child of the Plinth window, above the
// pages and below the overlay, the size of the card, so its × button gets clicks and the rest of the
// page still does.

/// The card's content, kept on the window's `WindowChrome`.
struct ResumeCard: Equatable {
    var page: PageID
    var key: SiteKey
    var siteName: String
    var pageName: String
    var summary: String?
    var isLoading: Bool
}

/// Whether a restore shows a card, and what kind. Pure, so it can be tested.
enum ResumeCardDecision: Equatable {
    case none
    /// Summaries are off: the card only marks where you left off, briefly.
    case placeOnly
    /// The card shows a placeholder while the page is read and summed up.
    case summarise

    /// A card shows only for the page now selected, and only if it is one of the pages that just
    /// came back. With summaries on it needs the model to be available; with them off, the AI
    /// switch still has to be on (as on the Mac). Never in a private window.
    static func decide(selected: PageID?, restored: [PageID], isPrivate: Bool, summariesEnabled: Bool,
                       aiEnabled: Bool, aiAvailable: Bool) -> ResumeCardDecision {
        guard let selected, restored.contains(selected), !isPrivate else { return .none }
        if summariesEnabled { return aiAvailable ? .summarise : .none }
        return aiEnabled ? .placeOnly : .none
    }

    /// How long a card stays: a place-only card, and a card once its summary is in.
    static let placeOnlyDuration: Duration = .seconds(8)
    static let summaryDuration: Duration = .seconds(14)
    /// A restored page loads again from scratch; it is read once loaded, or after `readAnywayAfter`
    /// tries of a second each, giving up after `attempts`.
    static let attempts = 8
    static let readAnywayAfter = 4
}

/// The card's own window. It never becomes key, so the page keeps the keyboard.
final class ResumeCardWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The room around the card inside its window, for its shadow.
private enum CardInsets {
    static let horizontal: CGFloat = 22
    static let top: CGFloat = 14
    static let bottom: CGFloat = 30
    /// From the page's bottom-left corner to the card's.
    static let fromPage: CGFloat = 12
}

private struct ResumeCardHost: View {
    let app: ChromiumApp
    let controller: BrowserWindowController
    let chrome: WindowChrome
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let card = chrome.resumeCard {
            ResumeCardView(siteKey: card.key, siteName: card.siteName, pageName: card.pageName,
                           summary: card.summary, isLoading: card.isLoading, accent: app.accent(scheme),
                           icon: { app.pool.favicons.image(for: $0) },
                           onDismiss: { controller.dismissResumeCard() })
                .padding(.horizontal, CardInsets.horizontal)
                .padding(.top, CardInsets.top)
                .padding(.bottom, CardInsets.bottom)
                .fixedSize()
        }
    }
}

extension BrowserWindowController {
    /// Called after pages come back from the shelf into this window (and only then).
    func showResumeCard(forRestored ids: [PageID]) {
        let settings = app.settings.value
        app.ai.refreshAvailability()
        let selected = app.store.window(windowID)?.selectedPageID
        let decision = ResumeCardDecision.decide(selected: selected, restored: ids, isPrivate: isPrivate,
                                                 summariesEnabled: settings.pageSummariesEnabled,
                                                 aiEnabled: app.ai.isEnabled, aiAvailable: app.ai.availability.isAvailable)
        guard decision != .none, let selected, let page = app.store.page(selected),
              let site = app.store.window(windowID)?.site(containing: selected) else { return }
        resumeTask?.cancel()
        chrome.resumeCard = ResumeCard(page: selected, key: site.key, siteName: site.name, pageName: page.name,
                                       summary: nil, isLoading: decision == .summarise)
        syncResumeCardWindow()
        if decision == .placeOnly {
            resumeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: ResumeCardDecision.placeOnlyDuration)
                if let self, !Task.isCancelled, self.chrome.resumeCard?.page == selected { self.dismissResumeCard() }
            }
            return
        }
        resumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var text: PageText?
            for attempt in 0..<ResumeCardDecision.attempts where text == nil {
                if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
                if Task.isCancelled { return }
                if let browser = self.app.pool.existing(selected), browser.isCreated,
                   !browser.isLoading || attempt >= ResumeCardDecision.readAnywayAfter {
                    text = await self.app.pool.readableText(for: selected)
                }
            }
            guard !Task.isCancelled, self.chrome.resumeCard?.page == selected else { return }
            guard let text, let summary = await self.app.ai.resumeCard(for: selected, text: text) else {
                self.dismissResumeCard()
                return
            }
            guard !Task.isCancelled, self.chrome.resumeCard?.page == selected else { return }
            self.chrome.resumeCard?.summary = summary
            self.chrome.resumeCard?.isLoading = false
            self.syncResumeCardWindow()
            try? await Task.sleep(for: ResumeCardDecision.summaryDuration)
            if !Task.isCancelled, self.chrome.resumeCard?.page == selected { self.dismissResumeCard() }
        }
    }

    func dismissResumeCard() {
        resumeTask?.cancel()
        resumeTask = nil
        chrome.resumeCard = nil
        syncResumeCardWindow()
    }

    /// The card belongs to the page it describes: moving elsewhere puts it away.
    func dropResumeCardIfStale() {
        guard let card = chrome.resumeCard, app.store.window(windowID)?.selectedPageID != card.page else { return }
        dismissResumeCard()
    }

    /// Shows, sizes and places the card's window to match `chrome.resumeCard`, or takes it away.
    func syncResumeCardWindow() {
        guard chrome.resumeCard != nil, !chrome.chromeHidden, window.isVisible else {
            if let card = resumeCardWindow, card.parent != nil || card.isVisible {
                window.removeChildWindow(card)
                card.orderOut(nil)
            }
            return
        }
        let card = resumeCardWindow ?? makeResumeCardWindow()
        guard let host = card.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        // SwiftUI draws a changed card on the next turn of the run loop; measure it then.
        guard size.width > 1, size.height > 1, size != lastResumeCardSize || card.parent !== window else {
            if !resumeCardRetryPending {
                resumeCardRetryPending = true
                DispatchQueue.main.async { [weak self] in
                    self?.resumeCardRetryPending = false
                    self?.placeResumeCardWindow()
                }
            }
            return
        }
        placeResumeCardWindow()
    }

    private func placeResumeCardWindow() {
        guard chrome.resumeCard != nil, !chrome.chromeHidden, window.isVisible,
              let card = resumeCardWindow, let host = card.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size.width > 1, size.height > 1 else { return }
        lastResumeCardSize = size
        let page = window.convertToScreen(geometry.pageFrame(in: window.contentView?.bounds.size ?? window.frame.size))
        let frame = NSRect(x: page.minX + CardInsets.fromPage - CardInsets.horizontal,
                           y: page.minY + CardInsets.fromPage - CardInsets.bottom,
                           width: size.width, height: size.height)
        if card.frame != frame { card.setFrame(frame, display: true) }
        if card.parent !== window { window.addChildWindow(card, ordered: .above) }
        keepOverlayOnTop()
    }

    private func makeResumeCardWindow() -> ResumeCardWindow {
        let card = ResumeCardWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        card.isOpaque = false
        card.backgroundColor = .clear
        card.hasShadow = false
        card.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ResumeCardHost(app: app, controller: self, chrome: chrome))
        host.sizingOptions = [.intrinsicContentSize]
        card.contentView = host
        resumeCardWindow = card
        return card
    }
}
