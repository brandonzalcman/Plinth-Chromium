import CoreGraphics
import Foundation

/// What the page script (NativeVideoScript.swift) reports, checked.
enum NativeVideoMessage: Equatable {
    /// A new document: forget the page's earlier videos.
    case reset
    case gone(id: Int)
    case video(NativeVideoFrame)

    init?(_ body: [AnyHashable: Any]) {
        switch body["type"] as? String {
        case "reset": self = .reset
        case "gone":
            guard let id = (body["id"] as? NSNumber)?.intValue else { return nil }
            self = .gone(id: id)
        case "video":
            guard let frame = NativeVideoFrame(body) else { return nil }
            self = .video(frame)
        default: return nil
        }
    }
}

/// One video and where it is, in the page's CSS pixels from the viewport's top left.
struct NativeVideoFrame: Equatable {
    var id: Int
    var url: URL
    var page: URL?
    var rect: CGRect
    var viewport: CGSize
    var radius: CGFloat
    var fill: Bool
    var hidden: Bool
    var muted: Bool
    var loop: Bool
    var autoplay: Bool

    init?(_ body: [AnyHashable: Any]) {
        func number(_ key: String) -> Double? { (body[key] as? NSNumber)?.doubleValue }
        func flag(_ key: String) -> Bool { (body[key] as? NSNumber)?.boolValue ?? false }
        guard let id = number("id"), let urlString = body["url"] as? String, let url = URL(string: urlString),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let x = number("x"), let y = number("y"), let w = number("w"), let h = number("h"),
              let vw = number("vw"), let vh = number("vh"),
              [x, y, w, h, vw, vh].allSatisfy(\.isFinite), w >= 0, h >= 0, vw > 0, vh > 0 else { return nil }
        self.id = Int(id)
        self.url = url
        page = (body["page"] as? String).flatMap(URL.init(string:))
        rect = CGRect(x: x, y: y, width: w, height: h)
        viewport = CGSize(width: vw, height: vh)
        radius = CGFloat(max(0, min(number("radius") ?? 0, 64)))
        fill = flag("fill")
        hidden = flag("hidden")
        muted = flag("muted")
        loop = flag("loop")
        autoplay = flag("autoplay")
    }
}

/// Where a native video goes over the page.
struct NativeVideoPlacement: Equatable {
    /// The part of the video inside the viewport, in the page view's points (top-left origin).
    var visible: CGRect
    /// The whole video, relative to `visible`'s origin (it can stick out where the page cuts it off).
    var player: CGRect
    /// How much of the video is on screen, 0...1.
    var shownFraction: CGFloat

    /// nil when none of it is on screen. `pageSize` is the page view's size in points.
    static func place(_ frame: NativeVideoFrame, pageSize: CGSize) -> NativeVideoPlacement? {
        guard frame.viewport.width > 0, pageSize.width > 0, frame.rect.width >= 2, frame.rect.height >= 2 else { return nil }
        let scale = pageSize.width / frame.viewport.width
        let full = CGRect(x: frame.rect.minX * scale, y: frame.rect.minY * scale,
                          width: frame.rect.width * scale, height: frame.rect.height * scale)
        let viewport = CGRect(origin: .zero, size: pageSize)
        let visible = full.intersection(viewport).integral
        guard !visible.isNull, visible.width >= 2, visible.height >= 2 else { return nil }
        let player = full.offsetBy(dx: -visible.minX, dy: -visible.minY)
        let fraction = (visible.width * visible.height) / max(1, full.width * full.height)
        return NativeVideoPlacement(visible: visible, player: player, shownFraction: min(1, fraction))
    }
}
