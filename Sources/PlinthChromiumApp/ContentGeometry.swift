import CoreGraphics
import PlinthModel
import PlinthSidebar

/// Where the page sits in a window, for each tab layout. Pure, in AppKit view coordinates
/// (origin bottom-left). The window draws its surface everywhere else and leaves this rect clear,
/// and the page's own window is placed under it.
public struct ContentGeometry: Equatable, Sendable {
    public var layout: TabLayout
    public var sidebarCollapsed: Bool
    /// The chrome is hidden (a page went full screen): the page fills the window.
    public var chromeHidden: Bool
    /// Room kept above the dock for its accessory row (group chips, a group suggestion).
    public var accessoryHeight: CGFloat

    public init(layout: TabLayout, sidebarCollapsed: Bool = false, chromeHidden: Bool = false, accessoryHeight: CGFloat = 0) {
        self.layout = layout; self.sidebarCollapsed = sidebarCollapsed; self.chromeHidden = chromeHidden
        self.accessoryHeight = accessoryHeight
    }

    public static let accessoryRowHeight: CGFloat = 44

    /// The gap between the page and the window edge or the chrome.
    public static let margin: CGFloat = 8
    /// Height of the strip that holds the traffic lights in the dock layout.
    public static let titlebarHeight: CGFloat = 34
    public static let sidebarWidth: CGFloat = 264
    public static let railWidth: CGFloat = 60
    public static let cornerRadius: CGFloat = 12
    /// The overlay window (panels, flyout) starts this far below the window's top, clear of the traffic lights.
    public static let overlayTopInset: CGFloat = 30

    /// The room the dock takes along the bottom: the bar and the inset under it.
    public static var dockHeight: CGFloat {
        let m = BarMetrics.standard
        return m.barHeight + m.bottomInset
    }

    /// Width of the sidebar column (0 in the dock layout).
    public var sidebarColumnWidth: CGFloat {
        guard layout == .sidebar, !chromeHidden else { return 0 }
        return sidebarCollapsed ? Self.railWidth : Self.sidebarWidth
    }

    public func pageFrame(in size: CGSize) -> CGRect {
        if chromeHidden { return CGRect(origin: .zero, size: size) }
        let m = Self.margin
        let rect: CGRect
        switch layout {
        case .dock:
            let bottom = Self.dockHeight + m + accessoryHeight
            rect = CGRect(x: m, y: bottom, width: size.width - 2 * m, height: size.height - bottom - Self.titlebarHeight)
        case .sidebar:
            let left = sidebarColumnWidth
            // The rail is narrower than the traffic lights, so the page starts below them.
            let top = sidebarCollapsed ? Self.titlebarHeight : m
            rect = CGRect(x: left, y: m, width: size.width - left - m, height: size.height - m - top)
        }
        return CGRect(x: rect.minX, y: rect.minY, width: max(0, rect.width), height: max(0, rect.height))
    }

    /// The two panes of a split, left then right, `fraction` of the width going to the left one.
    public func splitFrames(in size: CGSize, fraction: Double) -> (CGRect, CGRect) {
        let page = pageFrame(in: size)
        let gap = Self.margin
        let f = min(max(fraction, 0.2), 0.8)
        let leftWidth = ((page.width - gap) * f).rounded()
        let left = CGRect(x: page.minX, y: page.minY, width: leftWidth, height: page.height)
        let right = CGRect(x: left.maxX + gap, y: page.minY, width: page.maxX - left.maxX - gap, height: page.height)
        return (left, right)
    }

    public var cornerRadius: CGFloat { chromeHidden ? 0 : Self.cornerRadius }
}
