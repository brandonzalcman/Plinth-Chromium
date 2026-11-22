import AppKit
import PlinthModel

// Peek in a Plinth window: showing, placing, closing and promoting the card (see PeekController.swift).

extension BrowserWindowController {
    var isPeeking: Bool { peek != nil }

    /// Shows `url` in a peek card over the selected page. A card already showing is replaced.
    func showPeek(_ url: URL) {
        closePeek()
        dismissPanel()
        if chrome.flyoutOpen { closeFlyout(after: 0) }
        guard let selected = app.store.window(windowID)?.selectedPageID else { return }
        // The previewed page shares the selected page's profile: a private window's stays private.
        let controller = PeekController(host: self, url: url, profile: app.pool.profileForPage(selected))
        peek = controller
        syncPeek()
        controller.window.makeKey()
    }

    /// Places the card and its page for the window's current size and layout.
    func syncPeek() {
        guard let peek else { return }
        let size = window.contentView?.bounds.size ?? window.frame.size
        peek.layout(in: window, frame: overlayFrame, page: geometry.pageFrame(in: size))
        let page = peek.browser?.hostWindow != nil ? PeekLayout.pageFrame(inCard: peek.state.card) : nil
        if chrome.peekPage != page { chrome.peekPage = page }
        keepOverlayOnTop()
    }

    /// Closes the card and its page. Returns whether one was showing.
    @discardableResult
    func closePeek() -> Bool {
        guard let peek else { return false }
        self.peek = nil
        _ = peek.tearDown(keepBrowser: false)
        chrome.peekPage = nil
        focusPage()
        return true
    }

    /// "Open as Page": the previewed page becomes a page in this window, keeping its Chromium browser.
    func promotePeek() {
        guard let peek else { return }
        self.peek = nil
        chrome.peekPage = nil
        let initial = peek.initialURL
        guard let browser = peek.tearDown(keepBrowser: true) else { return }
        let url = MiniPromotion.address(current: browser.address, initial: initial)
        let opener = app.store.window(windowID)?.selectedPageID
        app.pool.offerForAdoption(browser, url: url)
        app.store.openPage(url: url, in: windowID, select: true, opener: opener)
        // Not taken (the store chose a page it already had): that browser is closed and the page shows as usual.
        app.pool.endAdoption()
        refreshContent()
        window.makeKeyAndOrderFront(nil)
        focusPage()
    }

    /// A link in the preview that asked for a new page opens in this window, as one from the page would.
    func openFromPeek(_ url: URL, background: Bool) {
        let opener = app.store.window(windowID)?.selectedPageID
        if !background { closePeek() }
        app.store.openPage(url: url, in: windowID, select: !background, opener: opener)
    }
}
