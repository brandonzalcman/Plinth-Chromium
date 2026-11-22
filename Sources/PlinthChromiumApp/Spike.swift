import AppKit
import SwiftUI
import PlinthCEF

@MainActor
public final class Spike: NSObject, @preconcurrency PCEFBrowserDelegate, NSWindowDelegate {
    var window: NSWindow!
    var browsers: [PCEFBrowser] = []
    var shown = 0
    var hole = NSRect.zero

    public func start() {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1100, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.delegate = self
        let root = NSHostingView(rootView: SpikeChrome(swap: { [weak self] in self?.swap() }))
        window.contentView = root
        window.makeKeyAndOrderFront(nil); NSApp.activate(); print("[spike] wid \(window.windowNumber)"); fflush(stdout)
        browsers = ["https://example.com", "https://en.wikipedia.org/wiki/Plinth"].map {
            PCEFBrowser(url: $0, profile: .shared, delegate: self)
        }
        for i in 1...4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(i) * 3) { [weak self] in self?.swap() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 18) { NSApp.terminate(nil) }
    }

    var holeRect: NSRect {
        let b = window.contentView!.bounds
        return NSRect(x: 230, y: 10, width: b.width - 240, height: b.height - 46)
    }

    func place(_ browser: PCEFBrowser) {
        browser.attach(below: window, frame: window.convertToScreen(holeRect))
    }

    func swap() {
        guard browsers.allSatisfy({ $0.hostWindow != nil }) else { print("[spike] hosts not ready"); return }
        let old = browsers[shown]
        shown = (shown + 1) % browsers.count
        place(browsers[shown])
        old.attach(below: nil, frame: .zero)
        print("[spike] showing \(shown) titles=\(browsers.map(\.title)) children=\(window.childWindows?.count ?? 0) key=\(String(describing: NSApp.keyWindow))")
    }

    public func windowDidResize(_ notification: Notification) {
        browsers[safe: shown]?.attach(below: window, frame: window.convertToScreen(holeRect))
    }

    public func browserHostWindowReady(_ browser: PCEFBrowser) {
        print("[spike] host ready \(String(describing: browser.hostWindow))")
        if browser === browsers.first { place(browser) }
    }
    public func browserDidActivate(_ browser: PCEFBrowser) { print("[spike] page activated; main=\(String(describing: NSApp.mainWindow))") }
    public func browser(_ browser: PCEFBrowser, didChangeAddress address: String) { print("[spike] address \(address)") }
    public func browser(_ browser: PCEFBrowser, didChangeTitle title: String) { print("[spike] title \(title)") }
    public func browser(_ browser: PCEFBrowser, didChangeFaviconURL url: String?) {}
    public func browserLoadingStateChanged(_ browser: PCEFBrowser) {}
    public func browser(_ browser: PCEFBrowser, didChangeProgress progress: Double) {}
    public func browser(_ browser: PCEFBrowser, openURL url: String, disposition: PCEFOpenDisposition, userGesture: Bool) -> Bool { true }
    public func browser(_ browser: PCEFBrowser, fullscreenChanged fullscreen: Bool) {}
    public func browser(_ browser: PCEFBrowser, handleKeyEquivalent event: NSEvent) -> Bool { false }
    public func browserDidClose(_ browser: PCEFBrowser) { print("[spike] browser closed") }
}

struct SpikeChrome: View {
    let swap: () -> Void
    var body: some View {
        ZStack(alignment: .topLeading) {
            // The window's surface with a rounded hole where the page shows through.
            Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                .mask {
                    GeometryReader { g in
                        Path { p in
                            p.addRect(CGRect(origin: .zero, size: g.size))
                            p.addRoundedRect(in: CGRect(x: 230, y: 36, width: g.size.width - 240, height: g.size.height - 46),
                                             cornerSize: CGSize(width: 12, height: 12), style: .continuous)
                        }.fill(style: FillStyle(eoFill: true))
                    }
                }
            VStack(alignment: .leading) {
                Text("Plinth sidebar").font(.headline)
                Button("Swap", action: swap)
            }.padding(.top, 50).padding(.leading, 20)
        }.ignoresSafeArea()
    }
}

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }

extension Spike {
    public static func main() {
        let app = PCEFApplication.shared as! PCEFApplication
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("plinth-cef-spike").path
        guard PCEFRuntime.start(withCachePath: cache, mockKeychain: true) else { fatalError("CEF failed to start") }
        print("[spike] chromium \(PCEFRuntime.chromiumVersion())")
        let spike = Spike()
        spike.start()
        app.terminateHandler = {
            spike.browsers.forEach { $0.close() }
            PCEFRuntime.quitAfterBrowsersClose()
        }
        PCEFRuntime.runMessageLoop()
        PCEFRuntime.shutdown()
    }
}
