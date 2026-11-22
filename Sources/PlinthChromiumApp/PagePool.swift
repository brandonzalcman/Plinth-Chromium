import AppKit
import Observation
import SwiftUI
import PlinthCEF
import PlinthModel
import PlinthSidebar

/// One Chromium browser per open page, keyed by the store's `PageID`. The CEF counterpart of the
/// Mac app's `WebViewPool`: it reports what pages do and carries out what the store decides.
@MainActor
final class PagePool: NSObject, PCEFBrowserDelegate, PageNavigating {
    struct Callbacks {
        var didUpdate: (PageID, URL?, String?) -> Void = { _, _, _ in }
        /// A link asked for a new page. `background` for ⌘-click.
        var openRequest: (URL, _ opener: PageID, _ background: Bool) -> Void = { _, _, _ in }
        /// A main-frame navigation; return false to cancel it.
        var shouldNavigate: (PageID, URL, _ linkClick: Bool) -> Bool = { _, _, _ in true }
        var loadingChanged: (PageID) -> Void = { _ in }
        var fullscreenChanged: (PageID, Bool) -> Void = { _, _ in }
        var didClose: (PageID) -> Void = { _ in }
        /// The page's window exists, or it was clicked into.
        var hostReady: (PageID) -> Void = { _ in }
        var activated: (PageID) -> Void = { _ in }
        var keyEquivalent: (NSEvent) -> Bool = { _ in false }
    }

    var callbacks = Callbacks()
    /// The Chromium profile a page belongs to (the shared one, or its private window's).
    var profileForPage: (PageID) -> PCEFProfile = { _ in .shared }
    let favicons = Favicons()
    let siteKey: (URL) -> SiteKey

    private var browsers: [PageID: PCEFBrowser] = [:]
    private var ids: [ObjectIdentifier: PageID] = [:]
    /// Pages being closed on purpose, so the store isn't told twice.
    private var closing = Set<ObjectIdentifier>()
    /// Load progress per page, 0...1, while loading.
    private(set) var progress: [PageID: Double] = [:]

    init(siteKey: @escaping (URL) -> SiteKey) { self.siteKey = siteKey }

    func existing(_ id: PageID) -> PCEFBrowser? { browsers[id] }

    @discardableResult
    func browser(for page: Page) -> PCEFBrowser {
        if let b = browsers[page.id] { return b }
        let b = PCEFBrowser(url: page.url.absoluteString, profile: profileForPage(page.id), delegate: self)
        browsers[page.id] = b
        ids[ObjectIdentifier(b)] = page.id
        // CEF makes the page's window during init, before the page was registered here.
        if b.hostWindow != nil { callbacks.hostReady(page.id) }
        return b
    }

    func load(_ url: URL, in id: PageID) { browsers[id]?.loadURL(url.absoluteString) }

    /// Closes a page's browser (the page itself is gone, or put on the shelf).
    func close(_ id: PageID) {
        guard let b = browsers.removeValue(forKey: id) else { return }
        closing.insert(ObjectIdentifier(b))
        progress[id] = nil
        b.close()
    }

    func close(_ ids: [PageID]) { ids.forEach(close) }

    /// Closes every browser without telling the store (quitting keeps the pages for next time).
    func closeAll() { close(Array(browsers.keys)) }

    var allBrowsers: [PCEFBrowser] { Array(browsers.values) }

    // MARK: Navigation

    func goBack(_ page: PageID) { browsers[page]?.goBack() }
    func goForward(_ page: PageID) { browsers[page]?.goForward() }
    func reload(_ page: PageID) { browsers[page]?.reload() }
    func stopLoading(_ page: PageID) { browsers[page]?.stopLoading() }
    func canGoBack(_ page: PageID) -> Bool { browsers[page]?.canGoBack ?? false }
    func canGoForward(_ page: PageID) -> Bool { browsers[page]?.canGoForward ?? false }
    func isLoading(_ page: PageID) -> Bool { browsers[page]?.isLoading ?? false }

    /// Chromium zoom levels: each step is 20% (level 1 ≈ 120%).
    func zoom(_ page: PageID, by step: Double) {
        guard let b = browsers[page] else { return }
        b.zoomLevel = step == 0 ? 0 : min(max(b.zoomLevel + step, -5), 9)
    }

    // MARK: PCEFBrowserDelegate

    private func id(of browser: PCEFBrowser) -> PageID? { ids[ObjectIdentifier(browser)] }

    func browser(_ browser: PCEFBrowser, didChangeAddress address: String) {
        guard let id = id(of: browser) else { return }
        callbacks.didUpdate(id, URL(string: address), browser.title.isEmpty ? nil : browser.title)
    }

    func browser(_ browser: PCEFBrowser, didChangeTitle title: String) {
        guard let id = id(of: browser) else { return }
        callbacks.didUpdate(id, URL(string: browser.address), title)
    }

    func browser(_ browser: PCEFBrowser, didChangeFaviconURL url: String?) {
        guard let id = id(of: browser), let page = URL(string: browser.address),
              let icon = url.flatMap(URL.init(string:)) else { return }
        // A private page's icon is not fetched outside its private profile.
        guard !browser.profile.isPrivate else { return }
        favicons.fetch(icon, for: siteKey(page))
        _ = id
    }

    func browserLoadingStateChanged(_ browser: PCEFBrowser) {
        guard let id = id(of: browser) else { return }
        if !browser.isLoading { progress[id] = nil }
        callbacks.loadingChanged(id)
    }

    func browser(_ browser: PCEFBrowser, didChangeProgress value: Double) {
        guard let id = id(of: browser) else { return }
        progress[id] = browser.isLoading && value < 1 ? value : nil
        callbacks.loadingChanged(id)
    }

    func browser(_ browser: PCEFBrowser, openURL url: String, disposition: PCEFOpenDisposition, userGesture: Bool) -> Bool {
        // Scripted popups (sign-in windows) keep their own small window and their opener.
        if disposition == .popup { return false }
        guard let id = id(of: browser), let target = URL(string: url) else { return true }
        callbacks.openRequest(target, id, disposition == .backgroundTab)
        return true
    }

    func browser(_ browser: PCEFBrowser, shouldNavigateTo url: String, linkClick: Bool, isRedirect: Bool) -> Bool {
        guard let id = id(of: browser), let target = URL(string: url), !isRedirect else { return true }
        return callbacks.shouldNavigate(id, target, linkClick)
    }

    func browser(_ browser: PCEFBrowser, fullscreenChanged fullscreen: Bool) {
        guard let id = id(of: browser) else { return }
        callbacks.fullscreenChanged(id, fullscreen)
    }

    func browser(_ browser: PCEFBrowser, handleKeyEquivalent event: NSEvent) -> Bool {
        callbacks.keyEquivalent(event)
    }

    func browserDidClose(_ browser: PCEFBrowser) {
        let key = ObjectIdentifier(browser)
        let id = ids.removeValue(forKey: key)
        if closing.remove(key) != nil { return }
        // Chromium closed it by itself (window.close() from the page): the store drops the page.
        if let id {
            browsers[id] = nil
            callbacks.didClose(id)
        }
    }

    func browserHostWindowReady(_ browser: PCEFBrowser) {
        if let id = id(of: browser) { callbacks.hostReady(id) }
    }

    func browserDidActivate(_ browser: PCEFBrowser) {
        if let id = id(of: browser) { callbacks.activated(id) }
    }
}

/// Site icons, fetched from the URL each page reports and kept per website for the session.
@MainActor
@Observable
final class Favicons {
    private(set) var images: [SiteKey: NSImage] = [:]
    @ObservationIgnored private var requested = Set<String>()
    /// Where icons are kept between launches, so restored pages show theirs before they load.
    @ObservationIgnored var cacheDirectory: URL? {
        didSet { loadCache() }
    }

    private func cacheFile(_ key: SiteKey) -> URL? {
        let safe = key.host.replacingOccurrences(of: "/", with: "_")
        return cacheDirectory?.appendingPathComponent(safe + ".png")
    }

    private func loadCache() {
        guard let dir = cacheDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "png" {
            if let image = NSImage(contentsOf: file) { images[SiteKey(file.deletingPathExtension().lastPathComponent)] = image }
        }
    }

    private func store(_ image: NSImage, for key: SiteKey) {
        guard let file = cacheFile(key), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: file, options: .atomic)
    }
    @ObservationIgnored private var tints: [SiteKey: Color] = [:]

    func image(for key: SiteKey) -> NSImage? { images[key] }

    /// The site's colour: the most saturated colour in its icon, or a stable hue from its host.
    func tint(for key: SiteKey) -> Color {
        if let cached = tints[key] { return cached }
        let colour = images[key].flatMap(Self.dominantColour)
            ?? Color(hue: SiteTint.hue(for: key.host), saturation: 0.55, brightness: 0.85)
        if images[key] != nil { tints[key] = colour }
        return colour
    }

    /// Averages an icon's colourful pixels, ignoring near-white, near-black, grey and transparent ones.
    static func dominantColour(_ image: NSImage) -> Color? {
        let side = 12
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0
        for x in 0..<side { for y in 0..<side {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { continue }
            let maxC = max(c.redComponent, c.greenComponent, c.blueComponent)
            let minC = min(c.redComponent, c.greenComponent, c.blueComponent)
            let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
            guard saturation > 0.25, maxC > 0.2 else { continue }
            let w = saturation * saturation
            r += c.redComponent * w; g += c.greenComponent * w; b += c.blueComponent * w; weight += w
        } }
        guard weight > 0.5 else { return nil }
        return Color(red: r / weight, green: g / weight, blue: b / weight)
    }

    func fetch(_ url: URL, for key: SiteKey) {
        // A cached icon is refreshed once per launch.
        guard requested.insert(key.host + "|" + url.absoluteString).inserted else { return }
        Task { [weak self] in
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let image = NSImage(data: data), image.isValid else { return }
            self?.images[key] = image
            self?.tints[key] = nil
            self?.store(image, for: key)
        }
    }
}
