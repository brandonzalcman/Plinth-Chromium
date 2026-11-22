import SwiftUI
import PlinthPanels
import PlinthSidebar

// Pictures for the guide's first cards: the layout choice, the sidebar, and the rail and split.
// Small drawings of the real thing, in the panels' palette, not screenshots.

/// Colours for the made-up sites in the pictures, the way the sidebar takes a colour from each icon.
enum SketchSite {
    static let mail = Color(welcomeHex: 0x3B6FE0)
    static let docs = Color(welcomeHex: 0x2F9E6B)
    static let news = Color(welcomeHex: 0xD9553F)
    static let music = Color(welcomeHex: 0xD1467A)
    static let maps = Color(welcomeHex: 0xE89B2E)
    static let code = Color(welcomeHex: 0x7356CF)
}

/// A letter tile in a site's colour, standing in for its icon.
struct SketchIcon: View {
    var letter: String
    var colour: Color
    var size: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(colour)
            .frame(width: size, height: size)
            .overlay(Text(letter).font(.system(size: size * 0.55, weight: .bold, design: .rounded)).foregroundStyle(.white))
    }
}

/// The plinth itself: a slab lit from above, as in the sidebar.
struct SketchSlab: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = PanelPalette(scheme)
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(LinearGradient(colors: [p.primary.opacity(0.16), p.primary.opacity(0.05)], startPoint: .top, endPoint: .bottom))
            .frame(height: 6)
            .overlay(alignment: .top) { Rectangle().fill(p.primary.opacity(0.18)).frame(height: 1) }
    }
}

/// A small window in either layout: traffic lights, the page, and the dock or the sidebar.
struct MiniWindowSketch: View {
    var layout: TabLayout
    var accent: Color
    var highlighted: Bool
    var size = CGSize(width: 220, height: 140)
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = PanelPalette(scheme)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.fill)
            HStack(spacing: 4) {
                ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { hex in
                    Circle().fill(Color(welcomeHex: UInt32(hex))).frame(width: 6, height: 6)
                }
            }
            .padding(.leading, 9).padding(.top, 8)
            switch layout {
            case .dock: dock(p)
            case .sidebar: sidebar(p)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(highlighted ? accent : p.border, lineWidth: highlighted ? 2 : 1))
        .shadow(color: p.shadow.opacity(0.6), radius: 8, y: 4)
        .accessibilityHidden(true)
    }

    private func page(_ p: PanelPalette) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(p.surface)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(p.border).frame(width: 64, height: 6)
                    Capsule().fill(p.border.opacity(0.7)).frame(width: 96, height: 4)
                    Capsule().fill(p.border.opacity(0.7)).frame(width: 80, height: 4)
                }
                .padding(10)
            }
    }

    private func dock(_ p: PanelPalette) -> some View {
        VStack(spacing: 6) {
            page(p)
            HStack(spacing: 4) {
                SketchIcon(letter: "", colour: accent.opacity(0.85), size: 10).clipShape(Circle())
                Capsule().fill(p.border).frame(width: 30, height: 10)
                Capsule().fill(accent).frame(width: 30, height: 10)
                Capsule().strokeBorder(p.tertiary.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 28, height: 10)
            }
            .padding(.horizontal, 7).frame(height: 18)
            .background(Capsule().fill(p.surface))
            .overlay(Capsule().strokeBorder(p.border, lineWidth: 1))
        }
        .padding(EdgeInsets(top: 20, leading: 7, bottom: 7, trailing: 7))
    }

    private func sidebar(_ p: PanelPalette) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    SketchIcon(letter: "", colour: SketchSite.mail, size: 11)
                    SketchIcon(letter: "", colour: SketchSite.music, size: 11)
                    SketchIcon(letter: "", colour: SketchSite.maps, size: 11)
                }
                SketchSlab().frame(width: 42)
                    .padding(.bottom, 3)
                row(SketchSite.docs, width: 34, current: false, p)
                row(SketchSite.docs, width: 28, current: true, p)
                row(SketchSite.news, width: 30, current: false, p)
                Spacer(minLength: 0)
            }
            .frame(width: 46)
            .padding(.top, 14)
            page(p)
        }
        .padding(EdgeInsets(top: 8, leading: 7, bottom: 7, trailing: 7))
    }

    private func row(_ colour: Color, width: CGFloat, current: Bool, _ p: PanelPalette) -> some View {
        HStack(spacing: 3) {
            Rectangle().fill(colour).frame(width: 1.5, height: 8)
            Capsule().fill(current ? accent : p.tertiary.opacity(0.45)).frame(width: width, height: 5)
        }
    }
}

// MARK: - Layout

/// The two layouts, side by side; picking one switches every window at once.
struct LayoutCardPicture: View {
    let app: ChromiumApp
    var accent: Color

    var body: some View {
        let current = app.prefs.value.tabLayout
        HStack(spacing: 28) {
            choice(.dock, key: "D", current: current)
            choice(.sidebar, key: "S", current: current)
        }
    }

    private func choice(_ layout: TabLayout, key: String, current: TabLayout) -> some View {
        WelcomeLayoutChoice(layout: layout, key: key, isOn: current == layout, accent: accent) {
            app.prefs.update { $0.tabLayout = layout }
        }
    }
}

private struct WelcomeLayoutChoice: View {
    var layout: TabLayout
    var key: String
    var isOn: Bool
    var accent: Color
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        let p = PanelPalette(scheme)
        Button(action: action) {
            VStack(spacing: 10) {
                MiniWindowSketch(layout: layout, accent: accent, highlighted: isOn)
                    .overlay(alignment: .topTrailing) {
                        if isOn {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(.white, accent)
                                .padding(7).transition(.scale.combined(with: .opacity))
                        }
                    }
                    .scaleEffect(hovered && !isOn ? 1.02 : 1)
                HStack(spacing: 7) {
                    Text(layout == .dock ? "Bottom dock" : "Sidebar")
                        .font(.system(size: 13, weight: isOn ? .semibold : .medium))
                        .foregroundStyle(isOn ? p.primary : p.secondary)
                    WelcomeKeyCap(text: key).scaleEffect(0.82)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(focused ? accent.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onHover { hovered = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isOn)
        .accessibilityLabel(layout == .dock ? "Pages in the bottom dock" : "Pages in the sidebar")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

// MARK: - Sidebar

/// The top of the sidebar: pins on the plinth (one an icon folder), a list folder, then sites in their
/// own colours. Notes beside it name each part.
struct SidebarCardPicture: View {
    var accent: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = PanelPalette(scheme)
        HStack(spacing: 30) {
            column(p)
            VStack(alignment: .leading, spacing: 16) {
                note("square.grid.2x2", "Pins on the plinth", "Always there, in every window.", p)
                note("folder", "Folders as icons or a list", "Drop a pin on a pin to make one.", p)
                note("paintpalette", "A colour for every site", "Taken from the site\u{2019}s own icon.", p)
            }
            .frame(width: 250, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The sidebar: pins on a plinth at the top, a folder of pins shown as a list, and sites each in their own colour")
    }

    private func column(_ p: PanelPalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                pin("M", SketchSite.mail, p)
                pin("C", SketchSite.code, p)
                pin("P", SketchSite.music, p)
                folderTile(p)
            }
            .padding(.horizontal, 4).padding(.bottom, 6)
            SketchSlab()
            // A folder shown as a list.
            HStack(spacing: 5) {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(p.tertiary)
                Text("Work").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(p.secondary)
            }
            .padding(.top, 10).padding(.leading, 4)
            listPin("Calendar", SketchSite.maps, p)
            Text("OPEN").font(.system(size: 9, weight: .semibold)).kerning(0.6).foregroundStyle(p.tertiary)
                .padding(.top, 8).padding(.leading, 4).padding(.bottom, 4)
            site("Docs", SketchSite.docs, pages: ["Quarterly plan", "Notes"], current: 0, p)
        }
        .padding(10)
        .frame(width: 210)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.surface).shadow(color: p.shadow, radius: 10, y: 5))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.border, lineWidth: 1))
    }

    private func pin(_ letter: String, _ colour: Color, _ p: PanelPalette) -> some View {
        SketchIcon(letter: letter, colour: colour, size: 18)
            .frame(width: 36, height: 30)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(colour.opacity(0.14)))
    }

    private func folderTile(_ p: PanelPalette) -> some View {
        let colours = [SketchSite.news, SketchSite.docs, SketchSite.maps, SketchSite.mail]
        return VStack(spacing: 2) {
            HStack(spacing: 2) { mini(colours[0]); mini(colours[1]) }
            HStack(spacing: 2) { mini(colours[2]); mini(colours[3]) }
        }
        .frame(width: 36, height: 30)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.fill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(p.border, lineWidth: 1))
    }

    private func mini(_ colour: Color) -> some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(colour).frame(width: 9, height: 9)
    }

    private func listPin(_ name: String, _ colour: Color, _ p: PanelPalette) -> some View {
        HStack(spacing: 7) {
            SketchIcon(letter: String(name.prefix(1)), colour: colour, size: 13)
            Text(name).font(.system(size: 11)).foregroundStyle(p.primary)
        }
        .padding(.leading, 16).padding(.top, 5)
    }

    private func site(_ name: String, _ colour: Color, pages: [String], current: Int?, _ p: PanelPalette) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                SketchIcon(letter: String(name.prefix(1)), colour: colour, size: 14)
                Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(p.primary)
            }
            HStack(alignment: .top, spacing: 8) {
                // The guide that ties a site's pages to it, in the site's colour.
                RoundedRectangle(cornerRadius: 1).fill(colour.opacity(0.7)).frame(width: 2)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { i, page in
                        Text(page).font(.system(size: 10.5, weight: i == current ? .semibold : .regular))
                            .foregroundStyle(i == current ? p.onAccent : p.secondary)
                            .padding(.horizontal, 7).frame(height: 18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(i == current ? accent : .clear))
                    }
                }
            }
            .padding(.leading, 6)
        }
        .padding(.bottom, 6)
    }

    private func note(_ symbol: String, _ title: String, _ detail: String, _ p: PanelPalette) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.primary)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(p.secondary)
            }
        }
    }

    private var tint: Color { scheme == .dark ? accent.mix(with: .white, by: 0.38) : accent }
}

// MARK: - Rail and split

/// Left, the collapsed rail with the full sidebar sliding over the page under the pointer; right, a
/// page dragged onto another, then the two side by side.
struct RailSplitCardPicture: View {
    var accent: Color
    var reduceMotion: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var phase = 1.0

    var body: some View {
        let p = PanelPalette(scheme)
        HStack(spacing: 40) {
            VStack(spacing: 10) {
                rail(p)
                caption("Rest on the rail to open it", p)
            }
            VStack(spacing: 10) {
                split(p)
                caption("Drop a page on a page to split", p)
            }
        }
        .task {
            guard !reduceMotion else { phase = 1; return }
            while !Task.isCancelled {
                phase = 0
                try? await Task.sleep(for: .seconds(0.6))
                withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { phase = 1 }
                try? await Task.sleep(for: .seconds(2.8))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The sidebar folded to a rail opens over the page on hover; a page dragged onto another shows the two side by side")
    }

    private func caption(_ text: String, _ p: PanelPalette) -> some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(p.secondary)
    }

    private func frame<Content: View>(_ p: PanelPalette, @ViewBuilder _ content: () -> Content) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.fill)
            content()
        }
        .frame(width: 250, height: 170)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: p.shadow.opacity(0.6), radius: 8, y: 4)
    }

    private func pageSheet(_ p: PanelPalette, lines: Int = 3) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(p.surface)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(p.border).frame(width: 60, height: 7)
                    ForEach(0..<lines, id: \.self) { i in Capsule().fill(p.border.opacity(0.7)).frame(width: CGFloat(90 - i * 14), height: 4) }
                }
                .padding(11)
            }
    }

    private func rail(_ p: PanelPalette) -> some View {
        frame(p) {
            HStack(spacing: 6) {
                VStack(spacing: 7) {
                    ForEach([SketchSite.mail, SketchSite.music, SketchSite.docs, SketchSite.news], id: \.self) { c in
                        SketchIcon(letter: "", colour: c, size: 14)
                    }
                    Spacer()
                }
                .frame(width: 24).padding(.top, 24)
                pageSheet(p)
            }
            .padding(EdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 8))
            // The full sidebar, open over the page.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    SketchIcon(letter: "", colour: SketchSite.mail, size: 12)
                    SketchIcon(letter: "", colour: SketchSite.music, size: 12)
                }
                SketchSlab().frame(width: 60)
                ForEach(Array(["Docs", "Quarterly plan", "News"].enumerated()), id: \.offset) { i, name in
                    Text(name).font(.system(size: 9.5, weight: i == 1 ? .semibold : .regular))
                        .foregroundStyle(i == 1 ? p.onAccent : p.secondary)
                        .padding(.horizontal, 5).frame(height: 15)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(i == 1 ? accent : .clear))
                }
                Spacer()
            }
            .padding(.top, 24).padding(.leading, 10)
            .frame(width: 104, height: 170, alignment: .topLeading)
            .background(UnevenRoundedRectangle(bottomTrailingRadius: 10, topTrailingRadius: 10, style: .continuous)
                .fill(p.surface).shadow(color: .black.opacity(0.22), radius: 8, x: 4))
            .offset(x: (1 - phase) * -110)
            Image(systemName: "cursorarrow").font(.system(size: 15)).foregroundStyle(p.primary)
                .shadow(color: .white.opacity(0.6), radius: 1)
                .offset(x: 70, y: 128)
        }
    }

    private func split(_ p: PanelPalette) -> some View {
        frame(p) {
            HStack(spacing: 6) {
                pageSheet(p)
                pageSheet(p, lines: 2)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SketchSite.news.opacity(0.08)))
                    .frame(width: 112 * phase)
                    .opacity(phase)
            }
            .padding(8)
            // The page being dragged in from the sidebar.
            HStack(spacing: 5) {
                SketchIcon(letter: "N", colour: SketchSite.news, size: 12)
                Text("News").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(p.primary)
            }
            .padding(.horizontal, 8).frame(height: 22)
            .background(Capsule().fill(p.surface).shadow(color: p.shadow, radius: 5, y: 3))
            .overlay(Capsule().strokeBorder(p.border, lineWidth: 1))
            .offset(x: 30 + 120 * phase, y: 110 - 60 * phase)
            .opacity(1 - phase * 0.85)
        }
    }
}
