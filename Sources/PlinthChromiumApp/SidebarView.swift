import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PlinthBarUI
import PlinthModel
import PlinthPanels
import PlinthSidebar

/// Feeds the sidebar from the store, the same way `DockHost` feeds the bar.
struct SidebarHost: View {
    let app: ChromiumApp
    let controller: BrowserWindowController
    let chrome: WindowChrome
    let collapsed: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let windowID = controller.windowID
        let state = app.store.window(windowID)
        let selected = state?.selectedPageID
        let split = state?.split.flatMap { pair in selected.map(pair.contains) == true ? pair : nil }
        let input = BarInput(pins: app.store.pins(in: windowID), sites: app.store.visibleSites(in: windowID),
                             selected: selected, split: split)
        let _ = app.loadingTick
        let favicons = app.pool.favicons
        let _ = favicons.images.count   // redraw when an icon arrives
        let page = selected.flatMap { app.store.page($0) }
        let nav = BarNavState(hasPage: selected != nil,
                              canGoBack: selected.map(app.pool.canGoBack) ?? false,
                              canGoForward: selected.map(app.pool.canGoForward) ?? false,
                              isLoading: selected.map(app.pool.isLoading) ?? false)
        let palette = ShellPalette(scheme, isPrivate: controller.isPrivate)
        SidebarView(
            model: SidebarModel(input),
            collapsed: collapsed,
            palette: palette,
            accent: app.accent(scheme),
            now: page.map { SidebarView.NowPage(name: $0.name, host: SidebarView.displayAddress($0.url),
                                                key: app.identity.key(for: $0.url)) },
            nav: nav,
            progress: selected.flatMap { app.pool.progress[$0] },
            groups: app.store.groups(in: windowID),
            focusedGroup: state?.focusedGroup,
            shelfCount: controller.isPrivate ? 0 : app.store.shelf.count,
            clock: Date(),
            icon: { favicons.image(for: $0) },
            tint: { favicons.tint(for: $0) },
            onAction: { app.handle($0, in: windowID) },
            onToggleCollapsed: { app.prefs.update { $0.sidebarCollapsed.toggle() } },
            onFocusGroup: { app.store.setFocus($0, in: windowID) },
            onSettings: { app.showSettings() },
            extensions: AnyView(ExtensionsButton(app: app, controller: controller, palette: palette))
        )
    }
}

/// Plinth's vertical sidebar.
///
/// The same ideas as the bar, stood upright and given room: the page you're on sits in a "Now" card at
/// the top, pins stand on a plinth, and every website wears its own colour (taken from its icon), so
/// sites are easy to tell apart at a glance. Pages you haven't touched in a while drift towards faint
/// before Plinth puts them away, and the whole column folds to a rail of coloured icons.
struct SidebarView: View {
    struct NowPage: Equatable {
        var name: String
        var host: String
        var key: SiteKey
    }

    let model: SidebarModel
    let collapsed: Bool
    let palette: ShellPalette
    let accent: Color
    let now: NowPage?
    let nav: BarNavState
    let progress: Double?
    let groups: [SiteGroup]
    let focusedGroup: GroupID?
    let shelfCount: Int
    let clock: Date
    let icon: (SiteKey) -> NSImage?
    let tint: (SiteKey) -> Color
    let onAction: (BarAction) -> Void
    let onToggleCollapsed: () -> Void
    let onFocusGroup: (GroupID?) -> Void
    let onSettings: () -> Void
    let extensions: AnyView

    @State private var openFolder: UUID?
    @State private var hovered: String?
    @State private var dropTarget: SiteID?

    /// Room for the traffic lights at the top left.
    static let trafficLightsWidth: CGFloat = 76

    static func displayAddress(_ url: URL) -> String {
        var host = url.host ?? url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    var body: some View {
        if collapsed { rail } else { full }
    }

    // MARK: Full sidebar

    private var full: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Spacer().frame(width: Self.trafficLightsWidth)
                Spacer()
                iconButton("sidebar.left", help: "Collapse sidebar (⌃⌘S)", action: onToggleCollapsed)
            }
            .padding(.trailing, 8)
            .frame(height: 38)

            nowCard.padding(.horizontal, 10)
            if !model.pins.isEmpty { plinth.padding(.horizontal, 10).padding(.top, 14) }
            if !groups.isEmpty { groupChips.padding(.top, 12) }

            HStack {
                Text("Open").font(.system(size: 10.5, weight: .semibold)).tracking(0.6).textCase(.uppercase)
                    .foregroundStyle(palette.tertiary)
                Spacer()
                Button { onAction(.newPage) } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.secondary)
                        .frame(width: 22, height: 22).background(Circle().fill(palette.hover))
                }
                .buttonStyle(.plain)
                .help("New page (⌘T)")
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 2)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.sites.enumerated()), id: \.element.id) { index, site in
                        siteCard(site, index: index)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Now

    /// The page you're on: its name, its site and the ways to move about. Clicking it edits the address.
    private var nowCard: some View {
        let colour = now.map { tint($0.key) } ?? accent
        return VStack(alignment: .leading, spacing: 10) {
            Button { onAction(.openCommandBar) } label: {
                HStack(alignment: .top, spacing: 10) {
                    if let now {
                        SiteIconView(key: now.key, name: now.host, image: icon(now.key), size: 18)
                            .frame(width: 32, height: 32)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(colour.opacity(0.22)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(now.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(palette.primary)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            Text(now.host).font(.system(size: 11.5)).foregroundStyle(palette.secondary).lineLimit(1)
                        }
                    } else {
                        Image(systemName: "sparkle").font(.system(size: 14, weight: .semibold)).foregroundStyle(accent)
                            .frame(width: 32, height: 32)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accent.opacity(0.16)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Go somewhere").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(palette.primary)
                            Text("Search or enter an address").font(.system(size: 11.5)).foregroundStyle(palette.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Search or enter address (⌘L)")

            HStack(spacing: 2) {
                iconButton("chevron.left", help: "Back (⌘[)", enabled: nav.canGoBack) { onAction(.goBack) }
                iconButton("chevron.right", help: "Forward (⌘])", enabled: nav.canGoForward) { onAction(.goForward) }
                iconButton(nav.isLoading ? "xmark" : "arrow.clockwise", help: nav.isLoading ? "Stop" : "Reload (⌘R)",
                           enabled: nav.hasPage) { onAction(nav.isLoading ? .stopLoading : .reload) }
                Spacer()
                Button { onAction(.openCommandBar) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass").font(.system(size: 10.5, weight: .semibold))
                        Text("⌘L").font(.system(size: 10.5, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(palette.secondary)
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(Capsule().fill(palette.hover))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [colour.opacity(0.20), colour.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.raised.opacity(0.6)))
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(colour.opacity(0.22), lineWidth: 1))
        // Loading shows as a line along the card's foot, in the site's colour.
        .overlay(alignment: .bottomLeading) {
            if let progress {
                GeometryReader { g in
                    Capsule().fill(colour).frame(width: max(10, (g.size.width - 24) * progress), height: 2)
                        .offset(x: 12, y: g.size.height - 3)
                        .animation(.easeOut(duration: 0.2), value: progress)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: now)
    }

    // MARK: Pins on the plinth

    private var plinth: some View {
        VStack(spacing: 0) {
            let columns = [GridItem(.adaptive(minimum: 42, maximum: 56), spacing: 8)]
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(model.pins) { slot in
                    switch slot {
                    case .pin(let pin): pinTile(pin)
                    case .folder(let folder): folderTile(folder)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 7)
            // The plinth itself: a slab the pins stand on, lit from above.
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(LinearGradient(colors: [palette.primary.opacity(0.16), palette.primary.opacity(0.05)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(height: 7)
                .overlay(alignment: .top) { Rectangle().fill(palette.primary.opacity(0.18)).frame(height: 1) }
            if let id = openFolder, let folder = model.pins.compactMap({ slot -> SidebarModel.Folder? in
                if case .folder(let f) = slot, f.id == id { return f } else { return nil }
            }).first {
                folderTray(folder).padding(.top, 8)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: openFolder)
    }

    private func pinTile(_ pin: SidebarModel.Pin) -> some View {
        let colour = tint(pin.key)
        let key = "pin\(pin.id.raw)"
        return Button { onAction(.selectPin(pin.id)) } label: {
            SiteIconView(key: pin.key, name: pin.name, image: icon(pin.key), size: 20)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(colour.opacity(pin.isCurrent ? 0.32 : (hovered == key ? 0.22 : 0.14))))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(pin.isCurrent ? colour.opacity(0.85) : .clear, lineWidth: 1.5))
                .shadow(color: .black.opacity(pin.isCurrent ? 0.18 : 0), radius: 3, y: 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pin.name + (pin.shortcut.map { "  ⌘\($0)" } ?? ""))
        .onHover { hovered = $0 ? key : (hovered == key ? nil : hovered) }
        .draggable(PinDragItem(id: pin.id.raw.uuidString))
        .dropDestination(for: PinDragItem.self) { items, _ in
            guard let dragged = items.first.flatMap({ UUID(uuidString: $0.id) }).map({ SiteID($0) }),
                  dragged != pin.id else { return false }
            onAction(.groupPins(dragged, onto: pin.id))
            return true
        }
        .contextMenu { pinMenu(pin) }
    }

    @ViewBuilder
    private func pinMenu(_ pin: SidebarModel.Pin) -> some View {
        Button("Go Back to Home Page") { onAction(.resetPin(pin.id)) }
        Divider()
        let folders = model.pins.compactMap { slot -> SidebarModel.Folder? in
            if case .folder(let f) = slot { return f } else { return nil }
        }
        Menu("Move to Folder") {
            Button("New Folder") { onAction(.movePinToFolder(pin.id, folder: nil)) }
            ForEach(folders.filter { $0.id != pin.folderID }) { f in
                Button(f.name) { onAction(.movePinToFolder(pin.id, folder: f.id)) }
            }
        }
        if pin.folderID != nil { Button("Remove from Folder") { onAction(.removePinFromFolder(pin.id)) } }
        Divider()
        Button("Unpin") { onAction(.unpin(pin.id)) }
    }

    private func folderTile(_ folder: SidebarModel.Folder) -> some View {
        Button { openFolder = openFolder == folder.id ? nil : folder.id } label: {
            // Up to four member icons in a 2×2 grid, like a folder of apps.
            LazyVGrid(columns: [GridItem(.fixed(12), spacing: 3), GridItem(.fixed(12), spacing: 3)], spacing: 3) {
                ForEach(Array(folder.members.prefix(4))) { m in SiteIconView(key: m.key, name: m.name, image: icon(m.key), size: 12) }
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(folder.isCurrent ? accent.opacity(0.22) : palette.hover))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(openFolder == folder.id ? palette.secondary.opacity(0.5) : (folder.isCurrent ? accent.opacity(0.7) : .clear),
                              lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(folder.name)
        .dropDestination(for: PinDragItem.self) { items, _ in
            guard let dragged = items.first.flatMap({ UUID(uuidString: $0.id) }).map({ SiteID($0) }) else { return false }
            onAction(.movePinToFolder(dragged, folder: folder.id))
            return true
        }
        .contextMenu {
            Button("Rename…") { renameFolder(folder) }
            Button("Ungroup") { onAction(.ungroupPinFolder(folder.id)) }
        }
    }

    /// An open folder's pins, in a tray under the plinth.
    private func folderTray(_ folder: SidebarModel.Folder) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(folder.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.secondary)
                .padding(.leading, 6).padding(.bottom, 2)
            ForEach(folder.members) { pin in
                Button { onAction(.selectPin(pin.id)) } label: {
                    HStack(spacing: 9) {
                        SiteIconView(key: pin.key, name: pin.name, image: icon(pin.key), size: 14)
                            .frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint(pin.key).opacity(0.18)))
                        Text(pin.name).font(.system(size: 12.5)).foregroundStyle(palette.primary).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 6).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(pin.isCurrent ? tint(pin.key).opacity(0.2) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { pinMenu(pin) }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.hover))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func renameFolder(_ folder: SidebarModel.Folder) {
        let alert = NSAlert()
        alert.messageText = "Rename Folder"
        let field = NSTextField(string: folder.name)
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { onAction(.renamePinFolder(folder.id, name)) }
        }
    }

    // MARK: Groups

    private var groupChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                chip("All", keys: [], isOn: focusedGroup == nil) { onFocusGroup(nil) }
                ForEach(groups) { group in
                    chip(group.name, keys: group.keys, isOn: focusedGroup == group.id) {
                        onFocusGroup(focusedGroup == group.id ? nil : group.id)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.never)
    }

    private func chip(_ title: String, keys: [SiteKey], isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                // A dot per site, in each site's colour.
                HStack(spacing: -3) {
                    ForEach(Array(keys.prefix(3)), id: \.self) { key in
                        Circle().fill(tint(key)).frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(palette.surface, lineWidth: 1))
                    }
                }
                Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(isOn ? palette.primary : palette.secondary)
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(isOn ? palette.primary.opacity(0.12) : palette.hover))
            .overlay(Capsule().strokeBorder(isOn ? palette.primary.opacity(0.2) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Sites

    @ViewBuilder
    private func siteCard(_ site: SidebarModel.SiteCard, index: Int) -> some View {
        let colour = tint(site.key)
        VStack(alignment: .leading, spacing: 1) {
            if site.isSingle, let page = site.pages.first {
                pageRow(page, site: site, single: true, colour: colour)
            } else {
                siteHeader(site, colour: colour)
                let pages = site.visiblePages
                if !pages.isEmpty {
                    HStack(alignment: .top, spacing: 0) {
                        // The guide that ties a site's pages to it, in the site's colour.
                        Capsule().fill(colour.opacity(0.45)).frame(width: 2).padding(.leading, 20).padding(.vertical, 4)
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(pages) { page in pageRow(page, site: site, single: false, colour: colour) }
                        }
                        .padding(.leading, 9)
                    }
                    .padding(.bottom, 3)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(site.isCurrent && !site.isSingle ? colour.opacity(0.07) : .clear)
        )
        .overlay(alignment: .top) {
            if dropTarget == site.id { Capsule().fill(accent).frame(height: 2).offset(y: -2) }
        }
        .draggable(SiteDragItem(id: site.id.raw.uuidString)) {
            Label(site.name, systemImage: "globe").padding(6).background(.regularMaterial, in: .rect(cornerRadius: 8))
        }
        .dropDestination(for: SiteDragItem.self) { items, _ in
            dropTarget = nil
            guard let dragged = items.first.flatMap({ UUID(uuidString: $0.id) }).map({ SiteID($0) }),
                  dragged != site.id else { return false }
            onAction(.moveSite(dragged, toIndex: index))
            return true
        } isTargeted: { dropTarget = $0 ? site.id : (dropTarget == site.id ? nil : dropTarget) }
        .contextMenu { siteMenu(site) }
    }

    private func siteIcon(_ key: SiteKey, name: String, colour: Color, faded: Bool = false) -> some View {
        SiteIconView(key: key, name: name, image: icon(key), size: 15)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(colour.opacity(faded ? 0.08 : 0.18)))
    }

    private func siteHeader(_ site: SidebarModel.SiteCard, colour: Color) -> some View {
        let key = "site\(site.id.raw)"
        let freshest = site.pages.map(\.lastUsed).max() ?? .distantPast
        return HStack(spacing: 9) {
            siteIcon(site.key, name: site.name, colour: colour)
            Text(site.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.primary)
                .lineLimit(1)
            if site.isKept {
                Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(colour).help("Kept: never fades")
            }
            Spacer(minLength: 4)
            if hovered == key || site.isFolded {
                Button { onAction(.toggleFold(site.id)) } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(site.visiblePages.isEmpty ? -90 : 0))
                        .foregroundStyle(palette.tertiary).frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(site.isFolded ? "Unfold" : "Fold")
            }
            Text("\(site.pages.count)")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(colour)
                .padding(.horizontal, 7).frame(height: 18)
                .background(Capsule().fill(colour.opacity(0.14)))
        }
        .padding(.leading, 7).padding(.trailing, 8)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovered == key ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture { onAction(.selectSite(site.id)) }
        .onHover { hovered = $0 ? key : (hovered == key ? nil : hovered) }
        .opacity(site.fade == .fading ? 0.6 : Freshness.opacity(lastUsed: freshest, now: clock, isCurrent: site.isCurrent, kept: site.isKept))
    }

    private func pageRow(_ page: SidebarModel.PageRow, site: SidebarModel.SiteCard, single: Bool, colour: Color) -> some View {
        let key = "page\(page.id.raw)"
        let isHovered = hovered == key
        let shape = RoundedRectangle(cornerRadius: single ? 11 : 8, style: .continuous)
        return HStack(spacing: 9) {
            if single { siteIcon(site.key, name: site.name, colour: colour, faded: page.fade == .fading) }
            VStack(alignment: .leading, spacing: 1) {
                Text(page.name)
                    .font(.system(size: 13, weight: page.isCurrent ? .semibold : .regular))
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)
                if single, site.name.caseInsensitiveCompare(page.name) != .orderedSame {
                    Text(site.name).font(.system(size: 10.5)).foregroundStyle(palette.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let role = page.splitRole {
                Image(systemName: role == .leading ? "rectangle.lefthalf.filled" : "rectangle.righthalf.filled")
                    .font(.system(size: 10)).foregroundStyle(colour).help("In split view")
            }
            if isHovered {
                Button { onAction(.closePage(page.id)) } label: {
                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(palette.secondary)
                        .frame(width: 18, height: 18).background(Circle().fill(palette.hover))
                }
                .buttonStyle(.plain)
                .help("Close page (⌘W)")
            } else if let n = page.shortcut, !page.isCurrent {
                Text("⌘\(n)").font(.system(size: 10, design: .rounded)).foregroundStyle(palette.tertiary)
            }
        }
        .padding(.leading, single ? 7 : 10).padding(.trailing, 7)
        .frame(height: single ? 40 : 30)
        .background(shape.fill(page.isCurrent ? colour.opacity(0.20) : (isHovered ? palette.hover : .clear)))
        // The current page carries a short bar of its site's colour on its leading edge.
        .overlay(alignment: .leading) {
            if page.isCurrent { Capsule().fill(colour).frame(width: 3, height: single ? 18 : 14).offset(x: -1) }
        }
        // Pages about to fade: the bar's dashed outline.
        .overlay(shape.strokeBorder(page.fade == .fading ? palette.tertiary : .clear, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        .opacity(page.fade == .fading && !page.isCurrent ? 0.55
                 : Freshness.opacity(lastUsed: page.lastUsed, now: clock, isCurrent: page.isCurrent, kept: site.isKept))
        .contentShape(Rectangle())
        .onTapGesture { onAction(.selectPage(page.id)) }
        .onHover { hovered = $0 ? key : (hovered == key ? nil : hovered) }
        .contextMenu { pageMenu(page, site: site) }
    }

    @ViewBuilder
    private func siteMenu(_ site: SidebarModel.SiteCard) -> some View {
        Button(site.isKept ? "Let It Fade" : "Keep") { onAction(.setKept(site.id, !site.isKept)) }
        Button("Pin") { onAction(.pinSite(site.id)) }
        if !site.isSingle { Button(site.isFolded ? "Unfold" : "Fold") { onAction(.toggleFold(site.id)) } }
        Divider()
        Button("Put Away") { onAction(.shelveSite(site.id)) }
        Button("Close \(site.isSingle ? "Page" : "All \(site.pages.count) Pages")") { onAction(.closeSite(site.id)) }
    }

    @ViewBuilder
    private func pageMenu(_ page: SidebarModel.PageRow, site: SidebarModel.SiteCard) -> some View {
        if !page.isCurrent, model.selected != nil { Button("Split View with Current Page") { onAction(.splitWithCurrent(page.id)) } }
        if page.splitRole != nil { Button("End Split View") { onAction(.endSplit) } }
        siteMenu(site)
        Divider()
        Button("Close Page") { onAction(.closePage(page.id)) }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                iconButton("archivebox", help: "Shelf: pages put away (⇧⌘L)") { onAction(.openShelf) }
                if shelfCount > 0 {
                    Text("\(min(shelfCount, 99))").font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white).padding(.horizontal, 3).frame(minWidth: 13, minHeight: 13)
                        .background(Capsule().fill(accent)).offset(x: 2, y: 0)
                }
            }
            extensions
            Spacer()
            iconButton("gearshape", help: "Settings (⌘,)", action: onSettings)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }

    // MARK: Rail (collapsed)

    private var rail: some View {
        VStack(spacing: 8) {
            Spacer().frame(height: 30)   // traffic lights
            iconButton("sidebar.left", help: "Expand sidebar (⌃⌘S)", action: onToggleCollapsed)
            iconButton("magnifyingglass", help: "Search (⌘L)") { onAction(.openCommandBar) }
            ScrollView(.vertical) {
                VStack(spacing: 7) {
                    let pins = model.rail.filter { if case .pin = $0.kind { true } else { false } }
                    let sites = model.rail.filter { if case .site = $0.kind { true } else { false } }
                    ForEach(pins) { railTile($0) }
                    if !pins.isEmpty {
                        // The plinth under the pins.
                        RoundedRectangle(cornerRadius: 2).fill(palette.primary.opacity(0.14)).frame(width: 36, height: 4)
                            .padding(.bottom, 4)
                    }
                    ForEach(sites) { railTile($0) }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            iconButton("plus", help: "New page (⌘T)") { onAction(.newPage) }
            extensions.padding(.bottom, 8)
        }
        .frame(width: ContentGeometry.railWidth)
        .frame(maxHeight: .infinity)
    }

    private func railTile(_ item: SidebarModel.RailItem) -> some View {
        let colour = tint(item.key)
        return Button {
            switch item.kind {
            case .pin(let id): onAction(.selectPin(id))
            case .site(let id): onAction(.selectSite(id))
            }
        } label: {
            SiteIconView(key: item.key, name: item.name, image: icon(item.key), size: 18)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(colour.opacity(item.isCurrent ? 0.32 : 0.14)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(item.isCurrent ? colour.opacity(0.85) : .clear, lineWidth: 1.5))
                .overlay(alignment: .bottomTrailing) {
                    if item.pageCount > 1 {
                        Text("\(item.pageCount)").font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.white).padding(.horizontal, 4).frame(minHeight: 13)
                            .background(Capsule().fill(colour)).offset(x: 3, y: 3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.name)
    }

    // MARK: Pieces

    private func iconButton(_ symbol: String, help: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(enabled ? palette.secondary : palette.tertiary.opacity(0.6))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}

/// Drag payloads for reordering inside the sidebar.
struct SiteDragItem: Codable, Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: .plinthSite) }
}

struct PinDragItem: Codable, Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: .plinthPin) }
}

extension UTType {
    static let plinthSite = UTType(exportedAs: "dev.getplinth.chromium.site")
    static let plinthPin = UTType(exportedAs: "dev.getplinth.chromium.pin")
}
