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
            let g = controller.geometryForDrawing(chrome)
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
                        if g.accessoryHeight > 0 {
                            DockAccessoryRow(app: app, controller: controller)
                                .frame(width: size.width - BarMetrics.standard.sideInset * 2, height: ContentGeometry.accessoryRowHeight,
                                       alignment: .leading)
                                .offset(x: BarMetrics.standard.sideInset,
                                        y: size.height - BarMetrics.standard.barHeight - BarMetrics.standard.bottomInset
                                            - ContentGeometry.accessoryRowHeight - 2)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
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
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .preferredColorScheme(controller.isPrivate ? .dark : nil)
    }
}

/// The window's surface. The pages' own windows sit on top of it; a hairline frames each page.
struct Surface: View {
    let holes: [CGRect]
    let radius: CGFloat
    let palette: ShellPalette

    var body: some View {
        // Top-leading, so each hairline's offset is the hole's own position (not added to a centred one).
        ZStack(alignment: .topLeading) {
            Rectangle().fill(palette.surface)
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

/// Group chips, or a suggestion to group sites you keep open together, just above the dock.
struct DockAccessoryRow: View {
    let app: ChromiumApp
    let controller: BrowserWindowController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let store = app.store!
        let windowID = controller.windowID
        let focused = store.window(windowID)?.focusedGroup
        let groups = store.groups(in: windowID)
        let accent = app.accent(scheme)
        HStack(spacing: 8) {
            if !groups.isEmpty {
                ForEach(groups) { group in
                    GroupChipView(group: group, isFiltering: focused == group.id, accent: accent,
                                  icon: { app.pool.favicons.image(for: $0) },
                                  onToggle: { focused == group.id ? store.setFocus(nil, in: windowID) : store.showGroup(group.id, in: windowID) },
                                  onRemove: { store.deleteGroup(group.id) })
                }
            } else if let suggestion = store.groupSuggestion(for: windowID) {
                GroupSuggestionView(suggestion: suggestion, accent: accent, icon: { app.pool.favicons.image(for: $0) },
                                    onGroup: { store.showGroup(store.acceptSuggestion(suggestion), in: windowID) },
                                    onNotNow: { store.dismissSuggestion(suggestion) })
            }
            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: groups)
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
            downloads: app.downloads.list.barState,
            nav: nav,
            onAction: { app.handle($0, in: windowID) }
        )
        .colorMultiply(controller.isPrivate ? Color(red: 0.78, green: 0.76, blue: 1.0) : .white)
        // How many pages are on the shelf, on the bar's shelf button.
        .overlay(alignment: .topTrailing) {
            let count = controller.isPrivate ? 0 : app.store.shelf.count
            if count > 0 {
                Text("\(min(count, 99))").font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white).padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                    .background(Capsule().fill(app.accent(scheme)))
                    .offset(x: -Self.shelfBadgeInset(withDownloads: app.downloads.list.barState != nil), y: 8)
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: app.store.shelf.count)
    }

    /// Distance from the bar's right edge to the shelf button's top-right corner (the bar's own
    /// arithmetic: padding, then the search button, then the downloads button if shown).
    static func shelfBadgeInset(withDownloads: Bool) -> CGFloat {
        let m = BarMetrics.standard
        let search = m.searchPadding * 2 + BarTextMeasurer.width("Search", style: .regular) + m.searchGap
            + BarTextMeasurer.width("⌘L", style: .regular)
        return m.barPadding + search + 4 + (withDownloads ? 36 : 0) - 4
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
        // Panels sit over the page, centred on it. With the dock they rise from the bar, where the eye
        // already is; with the sidebar the command bar sits at eye level, a little above the middle.
        let centreX = page.midX
        let lift: CGFloat = geometry.layout == .dock ? ContentGeometry.dockHeight + 12 : max(24, size.height * 0.42)
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
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .transition(.opacity)
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
        case .downloads:
            // Under the downloads button: bottom right in the dock layout, beside the sidebar's foot otherwise.
            ZStack(alignment: geometry.layout == .dock ? .bottomTrailing : .bottomLeading) {
                Dimmer { controller.dismissPanel() }
                let model = app.downloads!
                DownloadsTrayView(items: model.list.items, accent: accent,
                                  onOpen: { model.open($0) }, onReveal: { model.reveal($0) },
                                  onCancel: { model.cancel($0) }, onRemove: { model.remove($0) },
                                  onClear: { model.clear() }, onDismiss: { controller.dismissPanel() })
                    .padding(geometry.layout == .dock ? .trailing : .leading,
                             geometry.layout == .dock ? 120 : geometry.sidebarColumnWidth + 12)
                    .padding(.bottom, geometry.layout == .dock ? lift : 12)
                    .transition(.scale(scale: 0.96, anchor: .bottom).combined(with: .opacity))
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

/// What floats above the pages, in the overlay window: the panels, and the sidebar's hover flyout.
struct OverlayRoot: View {
    let app: ChromiumApp
    let controller: BrowserWindowController
    let chrome: WindowChrome
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let g = controller.geometryForDrawing(chrome)
            ZStack(alignment: .topLeading) {
                // Rounds the pages' corners by covering them with the surface colour.
                if !chrome.chromeHidden {
                    CornerCaps(frames: chrome.attached.values.map { r in
                        CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height)
                    }, radius: g.cornerRadius, colour: ShellPalette(scheme, isPrivate: controller.isPrivate).surface)
                }
                if chrome.flyoutOpen {
                    // A click on the page side closes the flyout.
                    Color.black.opacity(0.06)
                        .contentShape(Rectangle())
                        .onTapGesture { controller.closeFlyout(after: 0) }
                        .transition(.opacity)
                    SidebarHost(app: app, controller: controller, chrome: chrome, collapsed: false, inFlyout: true)
                        .frame(width: ContentGeometry.sidebarWidth, height: size.height)
                        .background(
                            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 14,
                                                   topTrailingRadius: 14, style: .continuous)
                                .fill(ShellPalette(scheme, isPrivate: controller.isPrivate).surface)
                                .shadow(color: .black.opacity(0.28), radius: 18, x: 6)
                        )
                        .onHover { inside in if inside { controller.openFlyout() } else { controller.closeFlyout() } }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                PanelLayer(app: app, controller: controller, chrome: chrome, size: size, geometry: g)
                // "Put away" notice, near the shelf it points to.
                if let notice = chrome.notice {
                    HStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(app.accent(scheme))
                        Text(notice).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    }
                    .padding(.horizontal, 14).frame(height: 34)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: g.layout == .dock ? .bottomTrailing : .bottomLeading)
                    .padding(g.layout == .dock ? .trailing : .leading, g.layout == .dock ? 60 : g.sidebarColumnWidth + 12)
                    .padding(.bottom, g.layout == .dock ? ContentGeometry.dockHeight + 10 : 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .preferredColorScheme(controller.isPrivate ? .dark : nil)
    }
}

/// The four corners outside each page's rounded rectangle, filled with the surface colour.
struct CornerCaps: View {
    let frames: [CGRect]
    let radius: CGFloat
    let colour: Color

    var body: some View {
        Canvas { ctx, _ in
            for f in frames where radius > 0 {
                let rounded = Path(roundedRect: f, cornerRadius: radius, style: .continuous)
                for corner in [CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX - radius, y: f.minY),
                               CGPoint(x: f.minX, y: f.maxY - radius), CGPoint(x: f.maxX - radius, y: f.maxY - radius)] {
                    let square = Path(CGRect(origin: corner, size: CGSize(width: radius, height: radius)))
                    ctx.fill(square.subtracting(rounded), with: .color(colour))
                }
            }
        }
        .allowsHitTesting(false)
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
