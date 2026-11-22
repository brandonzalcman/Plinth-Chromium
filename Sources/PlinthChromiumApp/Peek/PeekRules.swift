import CoreGraphics
import Foundation
import PlinthCEF
import PlinthPanels

// Peek: ⇧-click a link to see it in a card over the page without leaving it, as in the Mac app. The
// Mac decides in WebKit's navigation policy (⇧ alone, left button, http, https or file). Chromium has
// already turned the click into a window-open disposition by the time Plinth hears of it, and ⇧-click
// is the one that arrives as "new window" with a user gesture (⌘-click is a background tab, ⌘⇧-click a
// foreground tab, a scripted window.open with features a popup). Pure, so it can be tested.

/// How a page asked for a link to open, without the bridge's Objective-C type.
enum LinkDisposition: Equatable, Sendable {
    case currentTab, foregroundTab, backgroundTab, newWindow, popup

    init(_ disposition: PCEFOpenDisposition) {
        switch disposition {
        case .foregroundTab: self = .foregroundTab
        case .backgroundTab: self = .backgroundTab
        case .newWindow: self = .newWindow
        case .popup: self = .popup
        default: self = .currentTab
        }
    }
}

/// What Plinth does with a link that asked for somewhere new to open.
enum LinkOpening: Equatable, Sendable {
    /// A scripted popup (a sign-in window) keeps its own small window and its opener.
    case popup
    /// ⇧-click: preview it in a peek card.
    case peek
    /// A new page in the window; `background` for ⌘-click and middle-click.
    case page(background: Bool)

    /// The schemes a peek card shows, as on the Mac (`WebViewPool.reportedSchemes`).
    static let peekSchemes: Set<String> = ["http", "https", "file"]

    static func decide(_ disposition: LinkDisposition, userGesture: Bool, url: URL?) -> LinkOpening {
        switch disposition {
        case .popup:
            return .popup
        case .newWindow where userGesture && peekSchemes.contains(url?.scheme?.lowercased() ?? ""):
            return .peek
        case .backgroundTab:
            return .page(background: true)
        default:
            return .page(background: false)
        }
    }
}

/// Where the peek card and its page sit, in the Plinth window's content coordinates (origin
/// bottom-left). Pure.
enum PeekLayout {
    /// The gap between the card's edge and the page inside it, and the page's own corner radius.
    static let pageInset: CGFloat = 8
    static let pageRadius: CGFloat = 10

    /// The card: about 70% of the page area (`PeekCardView.cardSize`), centred on it.
    static func cardFrame(page: CGRect) -> CGRect {
        let size = PeekCardView.cardSize(in: page.size)
        return CGRect(x: (page.midX - size.width / 2).rounded(), y: (page.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    /// The previewed page: the card below its header and divider, inset on every side.
    static func pageFrame(inCard card: CGRect) -> CGRect {
        let top = PeekCardView.headerHeight + 1
        // Clamped as plain numbers: a CGRect reports a negative width as positive.
        return CGRect(x: card.minX + pageInset, y: card.minY + pageInset,
                      width: max(0, card.width - 2 * pageInset), height: max(0, card.height - top - 2 * pageInset))
    }
}
