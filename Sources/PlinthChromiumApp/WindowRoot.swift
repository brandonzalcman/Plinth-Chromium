import AppKit
import SwiftUI
import PlinthBarUI
import PlinthModel
import PlinthPanels
import PlinthSidebar

/// Colours for the window surface and the sidebar. Calm greys that let the page and accent lead.
struct ShellPalette {
    let surface: Color
    let raised: Color
    let hover: Color
    let primary: Color
    let secondary: Color
    let tertiary: Color
    let hairline: Color
    let pageShadow: Color

    init(_ scheme: ColorScheme, isPrivate: Bool = false) {
        if isPrivate {
            surface = Color(red: 0.10, green: 0.09, blue: 0.17)
            raised = Color.white.opacity(0.07)
            hover = Color.white.opacity(0.06)
            primary = Color.white.opacity(0.92)
            secondary = Color.white.opacity(0.58)
            tertiary = Color.white.opacity(0.36)
            hairline = Color.white.opacity(0.10)
            pageShadow = Color.black.opacity(0.5)
        } else if scheme == .dark {
            surface = Color(red: 0.105, green: 0.105, blue: 0.115)
            raised = Color.white.opacity(0.07)
            hover = Color.white.opacity(0.055)
            primary = Color.white.opacity(0.92)
            secondary = Color.white.opacity(0.56)
            tertiary = Color.white.opacity(0.34)
            hairline = Color.white.opacity(0.09)
            pageShadow = Color.black.opacity(0.45)
        } else {
            surface = Color(red: 0.925, green: 0.925, blue: 0.935)
            raised = Color.white.opacity(0.75)
            hover = Color.black.opacity(0.045)
            primary = Color.black.opacity(0.86)
            secondary = Color.black.opacity(0.52)
            tertiary = Color.black.opacity(0.32)
            hairline = Color.black.opacity(0.08)
            pageShadow = Color.black.opacity(0.16)
        }
    }
}

/// Everything Plinth draws in a window: the surface with the page hole, the dock or the sidebar,
/// and the panels that float over the page.
struct WindowRoot: View {
    let app: ChromiumApp
    let controller: BrowserWindowController
    let chrome: WindowChrome
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let g = ContentGeometry(layout: app.prefs.value.tabLayout, sidebarCollapsed: app.prefs.value.sidebarCollapsed,
                                    chromeHidden: chrome.chromeHidden)
            let palette = ShellPalette(scheme, isPrivate: controller.isPrivate)
            // SwiftUI measures from the top; the controller's frames are AppKit's (from the bottom).
            let flip = { (r: CGRect) in CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height) }
            let holes = chrome.attached.values.map(flip)
            let pending = chrome.pendingFrames.map(flip)
            let radius = g.cornerRadius

            ZStack(alignment: .topLeading) {
                Surface(holes: holes, radius: radius, palette: palette)
                // A page whose window is still being made shows as a blank sheet, not a hole to the desktop.
                ForEach(Array(pending.enumerated()), id: \.offset) { _, r in
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(scheme == .dark ? Color(white: 0.16) : .white)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
                if !chrome.chromeHidden {
                    if holes.isEmpty && pending.isEmpty { EmptyWindow(app: app, controller: controller, frame: flip(g.pageFrame(in: size)), radius: radius, palette: palette) }
                    switch g.layout {
                    case .dock:
                        TopStrip(app: app, controller: controller, palette: palette)
                            .frame(width: size.width, height: ContentGeometry.titlebarHeight)
                        DockHost(app: app, controller: controller, chrome: chrome)
                            .frame(width: size.width - BarMetrics.standard.sideInset * 2, height: BarMetrics.standard.barHeight)
                            .offset(x: BarMetrics.standard.sideInset, y: size.height - BarMetrics.standard.barHeight - BarMetrics.standard.bottomInset)
                    case .sidebar:
                        SidebarHost(app: app, controller: controller, chrome: chrome, collapsed: g.sidebarCollapsed)
                            .frame(width: g.sidebarColumnWidth, height: size.height)
                    }
                    // The sidebar shows loading on its Now card; the dock layout shows it along the page's top.
                    if g.layout == .dock {
                        ProgressLine(app: app, controller: controller, frame: holes.first, accent: app.accent(scheme))
                    }
                }
                PanelLayer(app: app, controller: controller, chrome: chrome, size: size, geometry: g)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .preferredColorScheme(controller.isPrivate ? .dark : nil)
    }
}

/// The window's surface, everywhere except the page holes.
struct Surface: View {
    let holes: [CGRect]
    let radius: CGFloat
    let palette: ShellPalette

    var body: some View {
        // Top-leading, so each hairline's offset is the hole's own position (not added to a centred one).
        ZStack(alignment: .topLeading) {
            Rectangle().fill(palette.surface)
                .mask {
                    Canvas { ctx, size in
                        var path = Path(CGRect(origin: .zero, size: size))
                        for hole in holes {
                            path.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
                        }
                        ctx.fill(path, with: .color(.black), style: FillStyle(eoFill: true))
                    }
                }
            // A hairline and a soft shadow around each page, so it reads as a sheet lying on the surface.
            ForEach(Array(holes.enumerated()), id: \.offset) { _, hole in
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 1)
                    .frame(width: hole.width + 1, height: hole.height + 1)
                    .offset(x: hole.minX - 0.5, y: hole.minY - 0.5)
                    .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Shown when a window has no page: a calm sheet with a way to start.
struct EmptyWindow: View {
    let app: ChromiumApp
    let controller: BrowserWindowController
    let frame: CGRect
    let radius: CGFloat
    let palette: ShellPalette

    var body: some View {
        VStack(spacing: 12) {
            Text("Plinth").font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(palette.secondary)
            Button("Search or enter an address") { controller.openCommandBar(newPage: true) }
                .buttonStyle(.borderless)
                .foregroundStyle(palette.secondary)
            Text("⌘T").font(.system(size: 11, design: .rounded)).foregroundStyle(palette.tertiary)
        }
        .frame(width: frame.width, height: frame.height)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(palette.raised))
        .offset(x: frame.minX, y: frame.minY)
    }
}

/// The strip behind the traffic lights in the dock layout, with the extensions button on the right.
struct TopStrip: View {
    let app: ChromiumApp
    let controller: BrowserWindowController
    let palette: ShellPalette

    var body: some View {
        HStack {
            Spacer()
            ExtensionsButton(app: app, controller: controller, palette: palette)
                .padding(.trailing, 10)
        }
        .frame(maxHeight: .infinity)
    }
}

/// A thin accent line along the top of the page while it loads.
struct ProgressLine: View {
    let app: ChromiumApp
    let controller: BrowserWindowController
    let frame: CGRect?
    let accent: Color

    var body: some View {
        let id = controller.shown.first
        let _ = app.loadingTick   // redraw as progress changes
        if let frame, let id, let progress = app.pool.progress[id] {
            Capsule().fill(accent)
                .frame(width: max(8, (frame.width - 24) * progress), height: 2)
                .offset(x: frame.minX + 12, y: frame.minY - 4)
                .animation(.easeOut(duration: 0.2), value: progress)
                .allowsHitTesting(false)
        }
    }
}

/// Plinth's bottom bar, fed from the store, exactly as in the Mac app.
struct DockHost: View {
    let app: ChromiumApp
    let controller: BrowserWindowController
    let chrome: WindowChrome
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let windowID = controller.windowID
        let state = app.store.window(windowID)
        let selected = state?.selectedPageID
        let split = state?.split.flatMap { pair in selected.map(pair.contains) == true ? pair : nil }
        let input = BarInput(pins: app.store.pins(in: windowID), sites: app.store.visibleSites(in: windowID),
                             selected: selected, split: split, wasCompact: chrome.barWasCompact)
        let engine = app.layoutEngine
        let _ = app.loadingTick
        let nav = BarNavState(hasPage: selected != nil,
                              canGoBack: selected.map(app.pool.canGoBack) ?? false,
                              canGoForward: selected.map(app.pool.canGoForward) ?? false,
                              isLoading: selected.map(app.pool.isLoading) ?? false)
        BottomBarView(
            layoutForWidth: { width in
                let layout = engine.layout(input, barWidth: width, metrics: .standard, measure: BarTextMeasurer.width)
                chrome.barWasCompact = layout.compact
                return layout
            },
            accent: app.accent(scheme),
            icon: { app.pool.favicons.image(for: $0) },
            nav: nav,
            onAction: { app.handle($0, in: windowID) }
        )
        .colorMultiply(controller.isPrivate ? Color(red: 0.78, green: 0.76, blue: 1.0) : .white)
    }
}

/// The command bar, shelf or find strip, floating over the page.
struct PanelLayer: View {
    let app: ChromiumApp
    let controller: BrowserWindowController
    let chrome: WindowChrome
    let size: CGSize
    let geometry: ContentGeometry
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let accent = app.accent(scheme)
        let page = geometry.pageFrame(in: size)
        // Panels sit over the page: centred on it, lifted off its bottom edge.
        let centreX = page.midX
        let lift: CGFloat = geometry.layout == .dock ? ContentGeometry.dockHeight + 12 : 24
        switch chrome.panel {
        case .none:
            EmptyView()
        case .command(let text, let newPage):
            ZStack(alignment: .bottom) {
                Dimmer { controller.dismissPanel() }
                CommandBarView(
                    initialText: text, opensNewPage: newPage, accent: accent,
                    results: { query in
                        if query.isEmpty {
                            _ = app.store.suggestions(for: "")
                            return controller.isPrivate ? [] : app.store.suggestedPages()
                        }
                        return app.store.suggestions(for: query, limit: 7)
                    },
                    icon: { app.pool.favicons.image(for: $0) },
                    onSubmit: { controller.submit($0) },
                    onDismiss: { controller.dismissPanel() }
                )
                .offset(x: centreX - size.width / 2)
                .padding(.bottom, lift)
            }
        case .shelf:
            ZStack(alignment: .bottom) {
                Dimmer { controller.dismissPanel() }
                ShelfView(
                    entries: app.store.shelf, accent: accent,
                    icon: { app.pool.favicons.image(for: $0) },
                    snapshot: { _ in nil },
                    onRestore: { entry, page in
                        app.store.restore(entry: entry, page: page, into: controller.windowID)
                        controller.dismissPanel()
                    },
                    onRemove: { entry, page in app.store.removeFromShelf(entry: entry, page: page) },
                    onDismiss: { controller.dismissPanel() },
                    onClearAll: { app.store.clearShelf() }
                )
                .offset(x: centreX - size.width / 2)
                .padding(.bottom, lift)
            }
        case .find:
            ZStack(alignment: .bottom) {
                FindBarView(accent: accent, notFound: Binding(get: { chrome.findNotFound }, set: { chrome.findNotFound = $0 }),
                            onFind: { controller.find($0, backwards: $1) },
                            onDismiss: { controller.dismissPanel() })
                    .offset(x: centreX - size.width / 2)
                    .padding(.bottom, lift)
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

/// A light wash over the page while a panel is open. Clicking it closes the panel. It is not fully
/// clear on purpose: the window server sends clicks on fully transparent pixels to the page below.
struct Dimmer: View {
    let onTap: () -> Void
    var body: some View {
        Color.black.opacity(0.12)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
    }
}
