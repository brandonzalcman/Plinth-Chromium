import AppKit
import PlinthCEF
import PlinthModel

/// Pictures of pages for the shelf, as the Mac app shows. Chromium can't picture a page once it's
/// hidden, so the page on screen is pictured shortly after it's shown or finishes loading, and the
/// latest one is what the shelf shows after it's put away. Never taken for private windows.
@MainActor
final class PageSnapshots {
    static let maxWidth: CGFloat = 640
    private let directory: URL?
    private let cache = NSCache<NSUUID, NSImage>()
    private var pending: [PageID: DispatchWorkItem] = [:]

    init(directory: URL?) {
        self.directory = directory
        cache.countLimit = 60
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }

    private func url(for id: PageID) -> URL? { directory?.appendingPathComponent(id.raw.uuidString + ".jpg") }

    func hasSnapshot(for id: PageID) -> Bool {
        cache.object(forKey: id.raw as NSUUID) != nil || url(for: id).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    func snapshot(for id: PageID) -> NSImage? {
        if let image = cache.object(forKey: id.raw as NSUUID) { return image }
        guard let url = url(for: id), let image = NSImage(contentsOf: url), image.isValid else { return nil }
        cache.setObject(image, forKey: id.raw as NSUUID)
        return image
    }

    /// Pictures the page after `delay`, replacing a picture already waiting for it.
    func schedule(_ id: PageID, browser: PCEFBrowser, after delay: TimeInterval = 1.2) {
        pending[id]?.cancel()
        let work = DispatchWorkItem { [weak self, weak browser] in
            guard let self, let browser else { return }
            self.pending[id] = nil
            self.capture(id, browser: browser)
        }
        pending[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func capture(_ id: PageID, browser: PCEFBrowser) {
        guard !browser.profile.isPrivate, browser.isCreated, !browser.isLoading else { return }
        browser.captureSnapshot { [weak self] data in
            guard let self, let data, let image = Self.scaled(data) else { return }
            self.cache.setObject(image, forKey: id.raw as NSUUID)
            guard let url = self.url(for: id), let jpeg = Self.jpeg(image) else { return }
            Task.detached(priority: .utility) { try? jpeg.write(to: url, options: .atomic) }
        }
    }

    func remove(_ id: PageID) {
        pending.removeValue(forKey: id)?.cancel()
        cache.removeObject(forKey: id.raw as NSUUID)
        if let url = url(for: id) { try? FileManager.default.removeItem(at: url) }
    }

    /// The picture at most `maxWidth` points wide, at the screen's scale.
    static func scaled(_ data: Data) -> NSImage? {
        guard let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pointWidth = CGFloat(rep.pixelsWide) / scale
        let width = min(pointWidth, maxWidth)
        let height = (width * CGFloat(rep.pixelsHigh) / CGFloat(rep.pixelsWide)).rounded()
        let pixels = NSSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGraphicsContext.current?.imageInterpolation = .high
        rep.draw(in: NSRect(origin: .zero, size: pixels))
        NSGraphicsContext.restoreGraphicsState()
        out.size = NSSize(width: width, height: height)
        let image = NSImage(size: out.size)
        image.addRepresentation(out)
        return image
    }

    static func jpeg(_ image: NSImage) -> Data? {
        guard let rep = image.representations.first as? NSBitmapImageRep else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
    }
}
