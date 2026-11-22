import AppKit
import SwiftUI
import PlinthCEF

extension ChromiumApp {
    /// Plinth ▸ About Plinth: the mark, the name, the version, and the engine underneath.
    @objc func menuAbout(_ sender: Any?) {
        if let window = aboutWindow { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 380),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AboutView())
        host.sizingOptions = []
        window.contentView = host
        window.center()
        aboutWindow = window
        window.makeKeyAndOrderFront(nil)
    }
}

struct AboutView: View {
    @Environment(\.colorScheme) private var scheme

    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "0.1"
        let b = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        let palette = ShellPalette(scheme)
        VStack(spacing: 0) {
            PlinthMarkView(size: 112, tile: true)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                .padding(.top, 44)
            Text("Plinth").font(Brand.display(30)).foregroundStyle(palette.primary).padding(.top, 18)
            Text("A calmer way to browse, on Chromium.").font(.system(size: 13)).foregroundStyle(palette.secondary)
                .padding(.top, 4)
            Text(version).font(.system(size: 12, design: .rounded)).foregroundStyle(palette.tertiary).padding(.top, 14)
            Text("Chromium \(PCEFRuntime.chromiumVersion())").font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(palette.tertiary).padding(.top, 2)
            Spacer()
            Link("getplinth.dev", destination: URL(string: "https://getplinth.dev")!)
                .font(Brand.display(12.5, weight: .medium))
                .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // Paper with the sky rising from the foot, like the mark's arch.
            LinearGradient(colors: [palette.surface, palette.surface, Brand.peach.opacity(scheme == .dark ? 0.10 : 0.22)],
                           startPoint: .top, endPoint: .bottom)
        )
        .ignoresSafeArea()
    }
}
