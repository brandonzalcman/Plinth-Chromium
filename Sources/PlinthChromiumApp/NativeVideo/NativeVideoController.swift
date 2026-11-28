import AppKit
import PlinthCEF
import PlinthModel

/// Keeps each page's native videos (NativeVideoLayer) in step with what the page script reports, and shows
/// them only while their page is on screen.
@MainActor
final class NativeVideoController {
    private var layers: [PageID: [Int: NativeVideoLayer]] = [:]
    private var frames: [PageID: [Int: NativeVideoFrame]] = [:]
    /// The page's browser, if it has one.
    var browser: (PageID) -> PCEFBrowser? = { _ in nil }
    /// The page is showing in a window right now.
    var isPageShown: (PageID) -> Bool = { _ in false }

    func handle(_ message: NativeVideoMessage, page: PageID) {
        switch message {
        case .reset:
            remove(page)
        case .gone(let id):
            layers[page]?.removeValue(forKey: id)?.close()
            frames[page]?.removeValue(forKey: id)
        case .video(let frame):
            if let existing = layers[page]?[frame.id], existing.url != frame.url {
                existing.close()
                layers[page]?[frame.id] = nil
            }
            frames[page, default: [:]][frame.id] = frame
            let layer = layers[page]?[frame.id] ?? make(frame, page: page)
            place(layer, frame, page: page)
        }
    }

    /// Re-places every video, after pages were shown, hidden or moved.
    func refreshAll() {
        for (page, byID) in layers {
            for (id, layer) in byID { if let frame = frames[page]?[id] { place(layer, frame, page: page) } }
        }
    }

    var debugState: String {
        layers.values.flatMap(\.values).map(\.debugState).joined(separator: " | ")
    }

    func remove(_ page: PageID) {
        layers.removeValue(forKey: page)?.values.forEach { $0.close() }
        frames.removeValue(forKey: page)
    }

    private func make(_ frame: NativeVideoFrame, page: PageID) -> NativeVideoLayer {
        let layer = NativeVideoLayer(frame: frame)
        layer.onScroll = { [weak self] point, dx, dy in
            self?.browser(page)?.sendScroll(at: point, deltaX: dx, deltaY: dy)
        }
        layers[page, default: [:]][frame.id] = layer
        return layer
    }

    private func place(_ layer: NativeVideoLayer, _ frame: NativeVideoFrame, page: PageID) {
        guard let host = browser(page)?.hostWindow else { layer.hide(); return }
        layer.update(frame, host: host, pageVisible: isPageShown(page))
    }
}
