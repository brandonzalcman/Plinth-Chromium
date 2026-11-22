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
        let nav = BarNavState(hasPage: selected != nil,
                              canGoBack: selected.map(app.pool.canGoBack) ?? false,
                              canGoForward: selected.map(app.pool.canGoForward) ?? false,
                              isLoading: selected.map(app.pool.isLoading) ?? false)
        let address = selected.flatMap { app.store.page($0)?.url }
        SidebarView(
            model: SidebarModel(input),
            collapsed: collapsed,
            palette: ShellPalette(scheme, isPrivate: controller.isPrivate),
            accent: app.accent(scheme),
            nav: nav,
            address: address.map(SidebarView.displayAddress),
            groups: app.store.groups(in: windowID),
            focusedGroup: state?.focusedGroup,
            shelfCount: controller.isPrivate ? 0 : app.store.shelf.count,
            icon: { app.pool.favicons.image(for: $0) },
            onAction: { app.handle($0, in: windowID) },
            onToggleCollapsed: { app.prefs.update { $0.sidebarCollapsed.toggle() } },
            onFocusGroup: { app.store.setFocus($0, in: windowID) },
            extensions: AnyView(ExtensionsButton(app: app, controller: controller, palette: ShellPalette(scheme, isPrivate: controller.isPrivate)))
        )
    }
}

/// Plinth's vertical sidebar.
///
/// Same ideas as the bar, laid out vertically: pins stand on a raised slab at the top (the plinth),
/// then each website is a quiet card with its pages listed by name beneath a thin guide line. The
/// current page carries the accent, pages about to fade go faint behind a dashed outline, and the
/// whole thing shrinks to a rail of icons.
struct SidebarView: View {
    let model: SidebarModel
    let collapsed: Bool
    let palette: ShellPalette
    let accent: Color
    let nav: BarNavState
    let address: String?
    let groups: [SiteGroup]
    let focusedGroup: GroupID?
    let shelfCount: Int
    let icon: (SiteKey) -> NSImage?
    let onAction: (BarAction) -> Void
    let onToggleCollapsed: () -> Void
    let onFocusGroup: (GroupID?) -> Void
    let extensions: AnyView

    @State private var openFolder: UUID?
    @State private var hovered: String?
    @State private var dropTarget: SiteID?

    /// Room for the traffic lights at the top left.
    static var trafficLightsWidth: CGFloat { 76 }

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
            header
            addressPill.padding(.horizontal, 12).padding(.top, 6)
            if !model.pins.isEmpty { plinth.padding(.horizontal, 12).padding(.top, 14) }
            if !groups.isEmpty { groupChips.padding(.top, 12) }
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.sites.enumerated()), id: \.element.id) { index, site in
                        siteCard(site, index: index)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.never)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 2) {
            Spacer().frame(width: Self.trafficLightsWidth)
            iconButton("sidebar.left", help: "Collapse sidebar", action: onToggleCollapsed)
            Spacer()
            iconButton("chevron.left", help: "Back", enabled: nav.canGoBack) { onAction(.goBack) }
            iconButton("chevron.right", help: "Forward", enabled: nav.canGoForward) { onAction(.goForward) }
            iconButton(nav.isLoading ? "xmark" : "arrow.clockwise", help: nav.isLoading ? "Stop" : "Reload", enabled: nav.hasPage) {
                onAction(nav.isLoading ? .stopLoading : .reload)
            }
        }
        .padding(.trailing, 8)
        .frame(height: 38)
    }

    /// The current address, quiet; clicking opens the command bar on it.
    private var addressPill: some View {
        Button { onAction(.openCommandBar) } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.tertiary)
                Text(address ?? "Search or enter address")
                    .font(.system(size: 12.5))
                    .foregroundStyle(address == nil ? palette.tertiary : palette.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("⌘L").font(.system(size: 10.5, design: .rounded)).foregroundStyle(palette.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.raised))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Search or enter address (⌘L)")
    }

    // MARK: Pins on the plinth

    private var plinth: some View {
        VStack(spacing: 0) {
            let columns = [GridItem(.adaptive(minimum: 40, maximum: 52), spacing: 6)]
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(model.pins) { slot in
                    switch slot {
                    case .pin(let pin): pinTile(pin)
                    case .folder(let folder): folderTile(folder)
                    }
                }
            }
            .padding(8)
            if let id = openFolder, let folder = model.pins.compactMap({ slot -> SidebarModel.Folder? in
                if case .folder(let f) = slot, f.id == id { return f } else { return nil }
            }).first {
                folderTray(folder).padding(.horizontal, 8).padding(.bottom, 8)
            }
        }
        // The slab the pins stand on: lighter on top, with a crisp lower edge.
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.raised)
                .overlay(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(palette.hairline, lineWidth: 1)
                }
                .shadow(color: palette.pageShadow.opacity(0.35), radius: 0.5, y: 1)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: openFolder)
    }

    private func pinTile(_ pin: SidebarModel.Pin) -> some View {
        Button { onAction(.selectPin(pin.id)) } label: {
            SiteIconView(key: pin.key, name: pin.name, image: icon(pin.key), size: 18)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(pin.isCurrent ? accent.opacity(0.18) : (hovered == "pin\(pin.id.raw)" ? palette.hover : .clear)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(pin.isCurrent ? accent.opacity(0.6) : .clear, lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pin.name + (pin.shortcut.map { "  ⌘\($0)" } ?? ""))
        .onHover { hovered = $0 ? "pin\(pin.id.raw)" : (hovered == "pin\(pin.id.raw)" ? nil : hovered) }
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
            let members = Array(folder.members.prefix(4))
            LazyVGrid(columns: [GridItem(.fixed(11), spacing: 2), GridItem(.fixed(11), spacing: 2)], spacing: 2) {
                ForEach(members) { m in SiteIconView(key: m.key, name: m.name, image: icon(m.key), size: 11) }
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(folder.isCurrent ? accent.opacity(0.18) : palette.hover))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(openFolder == folder.id ? palette.secondary.opacity(0.5) : (folder.isCurrent ? accent.opacity(0.6) : .clear), lineWidth: 1.5))
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

    /// An open folder's pins, in a tray under the plinth's tiles.
    private func folderTray(_ folder: SidebarModel.Folder) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(folder.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.secondary).padding(.leading, 4)
            ForEach(folder.members) { pin in
                Button { onAction(.selectPin(pin.id)) } label: {
                    HStack(spacing: 8) {
                        SiteIconView(key: pin.key, name: pin.name, image: icon(pin.key), size: 14)
                        Text(pin.name).font(.system(size: 12.5)).foregroundStyle(palette.primary).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 6).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(pin.isCurrent ? accent.opacity(0.18) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { pinMenu(pin) }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.hover))
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
                chip("All", isOn: focusedGroup == nil) { onFocusGroup(nil) }
                ForEach(groups) { group in
                    chip(group.name, isOn: focusedGroup == group.id) {
                        onFocusGroup(focusedGroup == group.id ? nil : group.id)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.never)
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                .foregroundStyle(isOn ? accent : palette.secondary)
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(isOn ? accent.opacity(0.14) : palette.hover))
        }
        .buttonStyle(.plain)
    }

    // MARK: Sites

    @ViewBuilder
    private func siteCard(_ site: SidebarModel.SiteCard, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if site.isSingle, let page = site.pages.first {
                pageRow(page, site: site, single: true)
            } else {
                siteHeader(site)
                let pages = site.visiblePages
                if !pages.isEmpty {
                    HStack(alignment: .top, spacing: 0) {
                        // The guide line that ties a site's pages to it.
                        Rectangle().fill(palette.hairline).frame(width: 1).padding(.leading, 17).padding(.vertical, 3)
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(pages) { page in pageRow(page, site: site, single: false) }
                        }
                        .padding(.leading, 8)
                    }
                }
            }
        }
        .padding(.vertical, site.isSingle ? 0 : 3)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(site.isCurrent && !site.isSingle ? palette.hover : .clear)
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

    private func siteHeader(_ site: SidebarModel.SiteCard) -> some View {
        let key = "site\(site.id.raw)"
        return HStack(spacing: 8) {
            SiteIconView(key: site.key, name: site.name, image: icon(site.key), size: 16)
            Text(site.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(site.isCurrent ? palette.primary : palette.secondary)
                .lineLimit(1)
            if site.isKept {
                Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(palette.tertiary).help("Kept: never fades")
            }
            Spacer(minLength: 4)
            Text("\(site.pages.count)")
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(palette.tertiary)
                .padding(.horizontal, 6).frame(height: 16)
                .background(Capsule().fill(palette.hover))
            Button { onAction(.toggleFold(site.id)) } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(site.visiblePages.isEmpty ? -90 : 0))
                    .foregroundStyle(palette.tertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovered == key || site.isFolded ? 1 : 0)
            .help(site.isFolded ? "Unfold" : "Fold")
        }
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: 30)
        .contentShape(Rectangle())
        .onTapGesture { onAction(.selectSite(site.id)) }
        .onHover { hovered = $0 ? key : (hovered == key ? nil : hovered) }
        .opacity(site.fade == .fading ? 0.55 : 1)
    }

    private func pageRow(_ page: SidebarModel.PageRow, site: SidebarModel.SiteCard, single: Bool) -> some View {
        let key = "page\(page.id.raw)"
        let isHovered = hovered == key
        return HStack(spacing: 8) {
            if single {
                SiteIconView(key: site.key, name: site.name, image: icon(site.key), size: 16)
            } else if page.isCurrent {
                Circle().fill(accent).frame(width: 5, height: 5)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(page.name)
                    .font(.system(size: 13, weight: page.isCurrent ? .semibold : .regular))
                    .foregroundStyle(page.isCurrent ? palette.primary : palette.primary.opacity(0.82))
                    .lineLimit(1)
                if single, site.name.caseInsensitiveCompare(page.name) != .orderedSame {
                    Text(site.name).font(.system(size: 10.5)).foregroundStyle(palette.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let role = page.splitRole {
                Image(systemName: role == .leading ? "rectangle.lefthalf.filled" : "rectangle.righthalf.filled")
                    .font(.system(size: 10)).foregroundStyle(accent).help("In split view")
            }
            if isHovered {
                Button { onAction(.closePage(page.id)) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(palette.secondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(palette.hover))
                }
                .buttonStyle(.plain)
                .help("Close page")
            } else if let n = page.shortcut, page.isCurrent == false {
                Text("⌘\(n)").font(.system(size: 10, design: .rounded)).foregroundStyle(palette.tertiary.opacity(0.8))
            }
        }
        .padding(.leading, single ? 10 : 8).padding(.trailing, 6)
        .frame(height: single ? 36 : 28)
        .background(
            RoundedRectangle(cornerRadius: single ? 10 : 8, style: .continuous)
                .fill(page.isCurrent ? accent.opacity(0.16) : (isHovered ? palette.hover : .clear))
        )
        // Pages about to fade: faint, with the bar's dashed outline.
        .overlay(
            RoundedRectangle(cornerRadius: single ? 10 : 8, style: .continuous)
                .strokeBorder(page.fade == .fading ? palette.tertiary : .clear, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        )
        .opacity(page.fade == .fading && !page.isCurrent ? 0.55 : 1)
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
            Button { onAction(.newPage) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                    Text("New Page").font(.system(size: 12.5))
                }
                .foregroundStyle(palette.secondary)
                .padding(.horizontal, 10).frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New page (⌘T)")
            Spacer()
            ZStack(alignment: .topTrailing) {
                iconButton("archivebox", help: "Shelf: pages put away") { onAction(.openShelf) }
                if shelfCount > 0 {
                    Text("\(min(shelfCount, 99))").font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white).padding(.horizontal, 3).frame(minWidth: 13, minHeight: 13)
                        .background(Capsule().fill(accent)).offset(x: 2, y: 0)
                }
            }
            extensions
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .overlay(alignment: .top) { Rectangle().fill(palette.hairline).frame(height: 1).padding(.horizontal, 12) }
    }

    // MARK: Rail (collapsed)

    private var rail: some View {
        VStack(spacing: 6) {
            Spacer().frame(height: 34)   // traffic lights
            iconButton("sidebar.left", help: "Expand sidebar", action: onToggleCollapsed)
            iconButton("magnifyingglass", help: "Search (⌘L)") { onAction(.openCommandBar) }
            Rectangle().fill(palette.hairline).frame(width: 24, height: 1).padding(.vertical, 2)
            ScrollView(.vertical) {
                VStack(spacing: 6) {
                    ForEach(model.rail) { item in
                        Button {
                            switch item.kind {
                            case .pin(let id): onAction(.selectPin(id))
                            case .site(let id): onAction(.selectSite(id))
                            }
                        } label: {
                            SiteIconView(key: item.key, name: item.name, image: icon(item.key), size: 18)
                                .frame(width: 38, height: 38)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(item.isCurrent ? accent.opacity(0.18) : palette.hover.opacity(0.0001)))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(item.isCurrent ? accent.opacity(0.6) : .clear, lineWidth: 1.5))
                                .overlay(alignment: .bottomTrailing) {
                                    if item.pageCount > 1 {
                                        Text("\(item.pageCount)").font(.system(size: 8.5, weight: .bold, design: .rounded))
                                            .foregroundStyle(palette.secondary).padding(.horizontal, 3)
                                            .background(Capsule().fill(palette.surface)).offset(x: 2, y: 2)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(item.name)
                        // A pin sits on the plinth: a short line under it.
                        .overlay(alignment: .bottom) {
                            if case .pin = item.kind { Capsule().fill(palette.tertiary.opacity(0.5)).frame(width: 18, height: 2).offset(y: 3) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)
            iconButton("plus", help: "New page (⌘T)") { onAction(.newPage) }
            extensions
                .padding(.bottom, 8)
        }
        .frame(width: ContentGeometry.railWidth)
        .frame(maxHeight: .infinity)
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
