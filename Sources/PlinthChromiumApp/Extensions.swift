import AppKit
import Observation
import SwiftUI
import PlinthCEF
import PlinthExtensions

/// Chrome extensions in Plinth's own UI. Chromium's toolbar is hidden, so Plinth lists what is
/// installed in the profile and opens an extension's popup page in a small window of its own,
/// attached above the Plinth window under the button.
@MainActor
@Observable
final class ExtensionsController: NSObject, PCEFBrowserDelegate {
    private(set) var installed: [InstalledExtension] = []
    @ObservationIgnored let profileDirectory: URL
    @ObservationIgnored unowned let app: ChromiumApp
    @ObservationIgnored private var popup: PCEFBrowser?
    @ObservationIgnored private var popupPlacement: (parent: NSWindow, frame: NSRect)?
    @ObservationIgnored private var monitors: [Any] = []

    static let popupSize = NSSize(width: 380, height: 540)

    init(app: ChromiumApp, profileDirectory: URL) {
        self.app = app
        self.profileDirectory = profileDirectory
        super.init()
        refresh()
    }

    func refresh() {
        let found = InstalledExtensions.scan(profile: profileDirectory).filter(\.isEnabled)
        if found != installed { installed = found }
    }

    /// Opens `ext`'s popup under `anchor` (screen coordinates), above `window`.
    func openPopup(_ ext: InstalledExtension, from window: NSWindow, anchor: NSRect) {
        closePopup()
        guard let url = ext.popupURL else { return }
        let size = Self.popupSize
        var frame = NSRect(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 6, width: size.width, height: size.height)
        // Keep it on the window's screen, and below the anchor if there is room, else above.
        if let screen = window.screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, screen.minX + 8), screen.maxX - size.width - 8)
            if frame.minY < screen.minY { frame.origin.y = anchor.maxY + 6 }
        }
        popupPlacement = (window, frame)
        let browser = PCEFBrowser(url: url.absoluteString, profile: .shared, delegate: self)
        popup = browser
        // CEF makes the window during init, before `popup` was set: place it now.
        if browser.hostWindow != nil { browserHostWindowReady(browser) }
        // Click outside or Esc closes it, like a popover.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let host = self?.popup?.hostWindow, event.window !== host { self?.closePopup() }
            return event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.popup != nil { self?.closePopup(); return nil }
            return event
        } as Any)
    }

    func closePopup() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        popup?.attach(below: nil, frame: .zero)
        popup?.close()
        popup = nil
        popupPlacement = nil
    }

    var popupTitle: String? { popup?.title }

    // MARK: PCEFBrowserDelegate

    func browserHostWindowReady(_ browser: PCEFBrowser) {
        guard browser === popup, let placement = popupPlacement else { return }
        browser.attach(above: placement.parent, frame: placement.frame)
        browser.hostWindow?.makeKey()
        browser.focus()
    }

    func browser(_ browser: PCEFBrowser, openURL url: String, disposition: PCEFOpenDisposition, userGesture: Bool) -> Bool {
        // Links from a popup open as ordinary pages in the window it belongs to.
        if let target = URL(string: url) { app.openInNewPage(target) }
        closePopup()
        return true
    }

    func browserDidClose(_ browser: PCEFBrowser) { if browser === popup { closePopup() } }
    func browser(_ browser: PCEFBrowser, didChangeTitle title: String) { print("[extensions] popup title \(title)") }
    func browser(_ browser: PCEFBrowser, didChangeAddress address: String) {}
    func browser(_ browser: PCEFBrowser, didChangeFaviconURL url: String?) {}
    func browserLoadingStateChanged(_ browser: PCEFBrowser) {}
    func browser(_ browser: PCEFBrowser, didChangeProgress progress: Double) {}
    func browser(_ browser: PCEFBrowser, shouldNavigateTo url: String, linkClick: Bool, isRedirect: Bool) -> Bool { true }
    func browser(_ browser: PCEFBrowser, fullscreenChanged fullscreen: Bool) {}
    func browser(_ browser: PCEFBrowser, handleKeyEquivalent event: NSEvent) -> Bool {
        NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }
    func browserDidActivate(_ browser: PCEFBrowser) {}
}

/// The puzzle-piece button: a menu of installed extensions, their popups, and the Web Store.
struct ExtensionsButton: View {
    let app: ChromiumApp
    let controller: BrowserWindowController
    let palette: ShellPalette
    @State private var showing = false

    var body: some View {
        GeometryReader { geo in
            Button {
                app.extensions.refresh()
                showing.toggle()
            } label: {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(palette.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Extensions")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                ExtensionsMenu(installed: app.extensions.installed,
                               onOpen: { ext in
                                   showing = false
                                   let frame = geo.frame(in: .global)
                                   open(ext, anchorInView: frame)
                               },
                               onGet: { showing = false; app.menuGetExtensions(nil) },
                               onManage: { showing = false; app.menuManageExtensions(nil) })
            }
        }
        .frame(width: 28, height: 28)
    }

    /// SwiftUI's global frame is top-left based inside the window; the popup wants screen coordinates.
    private func open(_ ext: InstalledExtension, anchorInView frame: CGRect) {
        let window = controller.window
        let height = window.contentView?.bounds.height ?? 0
        let inWindow = NSRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
        app.extensions.openPopup(ext, from: window, anchor: window.convertToScreen(inWindow))
    }
}

struct ExtensionsMenu: View {
    let installed: [InstalledExtension]
    let onOpen: (InstalledExtension) -> Void
    let onGet: () -> Void
    let onManage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Extensions").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            if installed.isEmpty {
                Text("No extensions yet. Chrome Web Store extensions work in Plinth.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
            ForEach(installed) { ext in
                Button { onOpen(ext) } label: {
                    HStack(spacing: 10) {
                        Group {
                            if let file = ext.iconFile, let image = NSImage(contentsOf: file) {
                                Image(nsImage: image).resizable().interpolation(.high)
                            } else {
                                Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(ext.name).font(.system(size: 13)).lineLimit(1)
                            if ext.popupURL == nil {
                                Text("No popup").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10).frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(ext.popupURL == nil)
            }
            Divider().padding(.vertical, 4)
            Button("Get Extensions…", action: onGet).buttonStyle(.plain).padding(.horizontal, 10).frame(height: 26)
            Button("Manage Extensions", action: onManage).buttonStyle(.plain).padding(.horizontal, 10).frame(height: 26)
                .padding(.bottom, 6)
        }
        .frame(width: 260)
    }
}
