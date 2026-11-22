import SwiftUI
import PlinthLoyalty
import PlinthPanels

// Pictures for the guide's later cards: fading and the shelf, search by meaning, extensions,
// Points & Levels, and the Import card.

// MARK: - Fading and the shelf

/// A page going faint in the list, landing on the shelf, then coming back with a resume card.
struct FadingCardPicture: View {
    var accent: Color
    var reduceMotion: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var faded = true

    var body: some View {
        let p = PanelPalette(scheme)
        HStack(alignment: .center, spacing: 14) {
            stage("Fades", p) { list(p) }
            arrow(p)
            stage("Rests on the shelf", p) { shelf(p) }
            arrow(p)
            stage("Comes back", p) { resume(p) }
        }
        .task {
            guard !reduceMotion else { faded = true; return }
            while !Task.isCancelled {
                faded = false
                try? await Task.sleep(for: .seconds(0.4))
                withAnimation(.easeInOut(duration: 1.6)) { faded = true }
                try? await Task.sleep(for: .seconds(3.2))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A page fades in the list, goes to the shelf, and comes back with a card saying where you left off")
    }

    private func stage<Content: View>(_ title: String, _ p: PanelPalette, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10) {
            content().frame(width: 170, height: 150)
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(p.secondary)
        }
    }

    private func arrow(_ p: PanelPalette) -> some View {
        Image(systemName: "arrow.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.tertiary)
            .padding(.bottom, 24)
    }

    private func card<Content: View>(_ p: PanelPalette, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(width: 170, height: 150, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.surface).shadow(color: p.shadow, radius: 8, y: 4))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.border, lineWidth: 1))
    }

    private func row(_ name: String, _ colour: Color, current: Bool = false, _ p: PanelPalette) -> some View {
        HStack(spacing: 7) {
            SketchIcon(letter: String(name.prefix(1)), colour: colour, size: 14)
            Text(name).font(.system(size: 11, weight: current ? .semibold : .regular))
                .foregroundStyle(current ? p.onAccent : p.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(current ? accent : .clear))
    }

    private func list(_ p: PanelPalette) -> some View {
        card(p) {
            VStack(alignment: .leading, spacing: 4) {
                row("Docs", SketchSite.docs, current: true, p)
                row("Mail", SketchSite.mail, p)
                row("Recipes", SketchSite.maps, p)
                    .opacity(faded ? 0.32 : 1)
                    // Pages about to fade: the bar's dashed outline.
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(p.tertiary.opacity(faded ? 0.8 : 0), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                row("Flights", SketchSite.code, p).opacity(0.55)
            }
        }
    }

    private func shelf(_ p: PanelPalette) -> some View {
        card(p) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "tray.full").font(.system(size: 11)).foregroundStyle(p.tertiary)
                    Text("Shelf").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.secondary)
                    Spacer()
                    Text("\u{21E7}\u{2318}L").font(.system(size: 10, weight: .medium)).foregroundStyle(p.tertiary)
                }
                ForEach(["Recipes", "Weekend trip", "Old news"], id: \.self) { name in
                    HStack(spacing: 6) {
                        SketchIcon(letter: String(name.prefix(1)), colour: name == "Recipes" ? SketchSite.maps : p.tertiary, size: 12)
                        Text(name).font(.system(size: 10.5)).foregroundStyle(p.secondary)
                    }
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Capsule().fill(p.fill))
                    .opacity(name == "Recipes" ? (faded ? 1 : 0.2) : 1)
                }
            }
        }
    }

    private func resume(_ p: PanelPalette) -> some View {
        card(p) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    SketchIcon(letter: "R", colour: SketchSite.maps, size: 14)
                    Text("Where you left off").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.tertiary)
                }
                Text("Sourdough starter").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.primary)
                Text("Feeding the starter twice a day; you were on step 3, the first rise.")
                    .font(.system(size: 10.5)).foregroundStyle(p.secondary).lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Image(systemName: "sparkles").font(.system(size: 9))
                    Text("Summed up on this Mac").font(.system(size: 9.5, weight: .medium))
                }
                .foregroundStyle(p.tertiary)
            }
        }
    }
}

// MARK: - Search by meaning

/// The shelf searched for an idea, not a word, with results that match it.
struct MeaningCardPicture: View {
    var accent: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = PanelPalette(scheme)
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(tint)
                    Text("that article about sourdough").font(.system(size: 13.5)).foregroundStyle(p.primary)
                    Rectangle().fill(accent).frame(width: 1.5, height: 16)
                    Spacer()
                    HStack(spacing: 4) { WelcomeKeyCap(text: "\u{21E7}"); WelcomeKeyCap(text: "\u{2318}"); WelcomeKeyCap(text: "L") }
                }
                .padding(.horizontal, 14).frame(height: 46).background(p.inputFill)
                Rectangle().fill(p.divider).frame(height: 1)
                row("The Science of a Good Starter", "Baking journal", "2 weeks ago", SketchSite.maps, p)
                row("Why Your Loaf Isn\u{2019}t Rising", "Kitchen notes", "Last month", SketchSite.news, p)
            }
            .frame(width: 460)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(p.surface).shadow(color: p.shadow, radius: 12, y: 6))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 10))
                Text("On-device AI \u{00B7} nothing leaves your Mac").font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(p.secondary)
            .padding(.horizontal, 12).frame(height: 26)
            .background(Capsule().fill(p.surface))
            .overlay(Capsule().strokeBorder(p.border, lineWidth: 1))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The shelf, searched by meaning for an article about sourdough, on this Mac")
    }

    private var tint: Color { scheme == .dark ? accent.mix(with: .white, by: 0.38) : accent }

    private func row(_ title: String, _ host: String, _ when: String, _ colour: Color, _ p: PanelPalette) -> some View {
        HStack(spacing: 10) {
            SketchIcon(letter: String(title.prefix(1)), colour: colour, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(p.primary).lineLimit(1)
                Text(host).font(.system(size: 11)).foregroundStyle(p.tertiary)
            }
            Spacer()
            Text("by meaning").font(.system(size: 10, weight: .medium)).foregroundStyle(tint)
                .padding(.horizontal, 7).frame(height: 18)
                .background(Capsule().fill(accent.opacity(0.12)))
            Text(when).font(.system(size: 11)).foregroundStyle(p.tertiary).frame(width: 74, alignment: .trailing)
        }
        .padding(.horizontal, 14).frame(height: 48)
    }
}

// MARK: - Extensions

/// The puzzle-piece button with its list of extensions open, and a sign-in window floating above.
struct ExtensionsCardPicture: View {
    var accent: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = PanelPalette(scheme)
        ZStack(alignment: .topLeading) {
            // The top right of a Plinth window.
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.surface)
                .frame(width: 420, height: 210)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.border, lineWidth: 1))
                .shadow(color: p.shadow, radius: 10, y: 5)
            HStack {
                Spacer()
                Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 13)).foregroundStyle(p.onAccent)
                    .frame(width: 28, height: 26)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent))
            }
            .frame(width: 420).padding(.top, 10).offset(x: -12)
            menu(p).offset(x: 196, y: 44)
            signIn(p).offset(x: -18, y: 64)
        }
        .frame(width: 440, height: 220)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Extensions listed under the puzzle-piece button, with a sign-in window floating over Plinth")
    }

    private func menu(_ p: PanelPalette) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            item("Reader", SketchSite.docs, p)
            item("Translate", SketchSite.mail, p)
            item("Ad Blocker", SketchSite.news, p)
            Rectangle().fill(p.divider).frame(height: 1).padding(.vertical, 4)
            HStack(spacing: 7) {
                Image(systemName: "bag").font(.system(size: 11)).foregroundStyle(p.secondary)
                Text("Chrome Web Store\u{2026}").font(.system(size: 11.5)).foregroundStyle(p.primary)
            }
            .padding(.horizontal, 8).frame(height: 24)
        }
        .padding(6)
        .frame(width: 200)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.surface).shadow(color: p.shadow, radius: 12, y: 6))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.border, lineWidth: 1))
    }

    private func item(_ name: String, _ colour: Color, _ p: PanelPalette) -> some View {
        HStack(spacing: 8) {
            SketchIcon(letter: String(name.prefix(1)), colour: colour, size: 16)
            Text(name).font(.system(size: 11.5)).foregroundStyle(p.primary)
            Spacer()
        }
        .padding(.horizontal, 8).frame(height: 26)
    }

    private func signIn(_ p: PanelPalette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { hex in
                    Circle().fill(Color(welcomeHex: UInt32(hex))).frame(width: 6, height: 6)
                }
            }
            Text("Sign in").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.primary)
            field(p)
            field(p)
            Capsule().fill(accent).frame(height: 20)
                .overlay(Text("Continue").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(p.onAccent))
        }
        .padding(12)
        .frame(width: 150)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.inputFill).shadow(color: .black.opacity(0.22), radius: 14, y: 8))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.border, lineWidth: 1))
    }

    private func field(_ p: PanelPalette) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(p.surface).frame(height: 20)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(p.border, lineWidth: 1))
    }
}

// MARK: - Points & Levels

/// The first levels' badges, the next one a little ahead, and how points come in.
struct PointsCardPicture: View {
    let app: ChromiumApp
    var accent: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = PanelPalette(scheme)
        let levels = Array(LoyaltyLevel.all.prefix(4))
        VStack(spacing: 20) {
            HStack(spacing: 22) {
                ForEach(Array(levels.enumerated()), id: \.element.id) { i, level in
                    VStack(spacing: 8) {
                        LoyaltyBadge(level: level, colourway: colourway(for: level), size: i == 0 ? 64 : 52)
                            .opacity(i == 0 ? 1 : 0.55 + 0.1 * Double(3 - i))
                        Text(level.name).font(.system(size: 11.5, weight: i == 0 ? .semibold : .medium))
                            .foregroundStyle(i == 0 ? p.primary : p.secondary)
                        Text(i == 0 ? "Where you start" : "\(level.threshold) points").font(.system(size: 10.5)).foregroundStyle(p.tertiary)
                    }
                }
            }
            HStack(spacing: 10) {
                chip("+10", "each day you browse", p)
                chip("+25", "your first pin", p)
                chip("+25", "your first split", p)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Level badges, each unlocking an app icon and accent colour, and the ways to earn points")
    }

    private func colourway(for level: LoyaltyLevel) -> LoyaltyColourway {
        LoyaltyColourway.all.first { $0.unlockLevel == level.number } ?? .sunrise
    }

    private func chip(_ points: String, _ label: String, _ p: PanelPalette) -> some View {
        HStack(spacing: 6) {
            Text(points).font(.system(size: 11.5, weight: .bold).monospacedDigit()).foregroundStyle(scheme == .dark ? accent.mix(with: .white, by: 0.38) : accent)
            Text(label).font(.system(size: 11.5)).foregroundStyle(p.secondary)
        }
        .padding(.horizontal, 11).frame(height: 28)
        .background(Capsule().fill(p.surface))
        .overlay(Capsule().strokeBorder(p.border, lineWidth: 1))
    }
}

// MARK: - Get started

/// Import from another browser (Settings ▸ Import), and the shortcuts worth knowing first.
struct GetStartedCardPicture: View {
    var accent: Color
    var importAction: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = PanelPalette(scheme)
        VStack(spacing: 12) {
            actionRow(symbol: "square.and.arrow.down", title: "Import from another browser",
                      detail: "Bookmarks, history and passwords from Safari, Chrome, Edge, Arc, Firefox and more.", p: p) {
                WelcomeButton(title: "Import\u{2026}", filled: false, accent: accent, action: importAction)
                    .accessibilityHint("Opens Settings at Import")
            }
            actionRow(symbol: "keyboard", title: "Three keys to start with", detail: "Search or go anywhere, a new page, and the shelf.", p: p) {
                HStack(spacing: 10) {
                    shortcut(["\u{2318}", "L"])
                    shortcut(["\u{2318}", "T"])
                    shortcut(["\u{21E7}", "\u{2318}", "L"])
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Command L, Command T, Shift Command L")
            }
        }
        .padding(.horizontal, 28)
    }

    private var iconTint: Color { scheme == .dark ? accent.mix(with: .white, by: 0.38) : accent }

    private func shortcut(_ keys: [String]) -> some View {
        HStack(spacing: 3) { ForEach(keys, id: \.self) { WelcomeKeyCap(text: $0) } }
    }

    private func actionRow<Trailing: View>(symbol: String, title: String, detail: String, p: PanelPalette,
                                          @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(iconTint)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(accent.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(p.primary)
                Text(detail).font(.system(size: 12)).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16).frame(height: 74)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.border, lineWidth: 1))
    }
}
