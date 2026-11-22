import SwiftUI
import PlinthPanels

// The guide's card: the opening animation, then one card at a time with a picture, a title and a few
// lines, Back and Next, and step dots. The Mac app's look (PanelPalette, 26-point corners), with this
// build's cards (WelcomeFlow.swift) and pictures (WelcomeIllustrations*.swift).
//
// Keys: → or Return for Next, ← for Back, Esc to skip, Tab between the buttons (Space presses one).
// On the layout card, D picks the dock and S the sidebar.

struct WelcomeView: View {
    var model: WelcomeModel
    let app: ChromiumApp
    var importAction: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = PanelPalette(scheme)
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        ZStack {
            p.surface
            switch model.flow.phase {
            case .intro:
                WelcomeIntro(reduceMotion: reduceMotion, accent: app.accent(scheme), onDone: { model.apply { $0.introDone() } })
                    .transition(.opacity)
            case .guide:
                WelcomeGuide(model: model, app: app, importAction: importAction)
                    .transition(.opacity)
            case .finished:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.35), value: model.flow.phase == .intro)
        .frame(width: WelcomeWindowController.size.width, height: WelcomeWindowController.size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(p.border, lineWidth: 1).allowsHitTesting(false))
        .environment(\.layoutDirection, .leftToRight)
    }
}

private struct WelcomeGuide: View {
    var model: WelcomeModel
    let app: ChromiumApp
    var importAction: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    /// The way the last move went, so the picture slides the right way.
    @State private var forward = true

    private var card: WelcomeCard { model.flow.currentCard ?? .layout }
    private var index: Int { model.flow.cardIndex ?? 0 }

    var body: some View {
        let p = PanelPalette(scheme)
        let accent = app.accent(scheme)
        VStack(spacing: 0) {
            HStack {
                Text("Step \(index + 1) of \(WelcomeFlow.cards.count)")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(p.tertiary)
                    .accessibilityHidden(true)
                Spacer()
                if !model.flow.isLastCard {
                    Button("Skip") { model.apply { $0.skip() } }
                        .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(p.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .accessibilityLabel("Skip the welcome guide")
                        .help("Skip the guide (Esc)")
                }
            }
            .frame(height: 30).padding(.top, 14).padding(.horizontal, 26)

            ZStack {
                illustration(accent: accent)
                    .id(card)
                    .transition(slide)
            }
            .frame(maxWidth: .infinity).frame(height: 262)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(p.fill))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(p.border.opacity(0.7), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 36).padding(.top, 6)

            VStack(spacing: 8) {
                Text(card.title).font(.system(size: 25, weight: .semibold)).kerning(-0.6).foregroundStyle(p.primary)
                    .accessibilityAddTraits(.isHeader)
                Text(card.message).font(.system(size: 14)).foregroundStyle(p.secondary).multilineTextAlignment(.center)
                    .lineSpacing(3).frame(maxWidth: 540).fixedSize(horizontal: false, vertical: true)
            }
            .id(card)
            .transition(.opacity)
            .padding(.top, 22).padding(.horizontal, 40)

            Spacer(minLength: 10)

            HStack {
                Group {
                    if !model.flow.isFirstCard {
                        WelcomeButton(title: "Back", filled: false, accent: accent) { move(forward: false) { $0.back() } }
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 170, alignment: .leading)
                Spacer()
                StepDots(count: WelcomeFlow.cards.count, index: index, accent: accent, reduceMotion: reduceMotion) { target in
                    move(forward: target > index) { $0.go(to: target) }
                }
                Spacer()
                WelcomeButton(title: model.flow.isLastCard ? "Start browsing" : "Next", filled: true, accent: accent) {
                    move(forward: true) { $0.next() }
                }
                .keyboardShortcut(.defaultAction)
                .frame(width: 170, alignment: .trailing)
            }
            .padding(.horizontal, 36).padding(.bottom, 26)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.86), value: card)
        .focusable().focusEffectDisabled().focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.rightArrow) { move(forward: true) { $0.next() }; return .handled }
        .onKeyPress(.leftArrow) { move(forward: false) { $0.back() }; return .handled }
        .onKeyPress(.escape) { model.apply { $0.skip() }; return .handled }
        .onKeyPress(characters: .letters) { press in
            guard card == .layout else { return .ignored }
            switch press.characters.lowercased() {
            case "d": app.prefs.update { $0.tabLayout = .dock }; return .handled
            case "s": app.prefs.update { $0.tabLayout = .sidebar }; return .handled
            default: return .ignored
            }
        }
    }

    /// Slides in from the side it's coming from; a plain fade with Reduce Motion.
    private var slide: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(insertion: .offset(x: forward ? 40 : -40).combined(with: .opacity),
                           removal: .offset(x: forward ? -40 : 40).combined(with: .opacity))
    }

    private func move(forward: Bool, _ change: (inout WelcomeFlow) -> Void) {
        self.forward = forward
        model.apply(change)
    }

    @ViewBuilder private func illustration(accent: Color) -> some View {
        switch card {
        case .layout: LayoutCardPicture(app: app, accent: accent)
        case .sidebar: SidebarCardPicture(accent: accent)
        case .railAndSplit: RailSplitCardPicture(accent: accent, reduceMotion: reduceMotion)
        case .fading: FadingCardPicture(accent: accent, reduceMotion: reduceMotion)
        case .meaning: MeaningCardPicture(accent: accent)
        case .extensions: ExtensionsCardPicture(accent: accent)
        case .points: PointsCardPicture(app: app, accent: accent)
        case .getStarted: GetStartedCardPicture(accent: accent, importAction: importAction)
        }
    }
}

/// One dot per card, the current one a pill in the accent. Each dot jumps to its card.
private struct StepDots: View {
    var count: Int
    var index: Int
    var accent: Color
    var reduceMotion: Bool
    var onSelect: (Int) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = PanelPalette(scheme)
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Capsule().fill(i == index ? accent : p.border)
                    .frame(width: i == index ? 20 : 7, height: 7)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(i) }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: index)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(index + 1) of \(count)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if index + 1 < count { onSelect(index + 1) }
            case .decrement: if index > 0 { onSelect(index - 1) }
            @unknown default: break
            }
        }
    }
}

/// The guide's buttons: an accent capsule, or a quiet outlined one. A keyboard focus ring shows when
/// tabbed to.
struct WelcomeButton: View {
    var title: String
    var filled: Bool
    var accent: Color
    var systemImage: String? = nil
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        let p = PanelPalette(scheme)
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)).accessibilityHidden(true) }
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(filled ? p.onAccent : p.primary)
            .padding(.horizontal, 18).frame(height: 34)
            .background(Capsule().fill(filled ? accent : (hovered ? p.hover : p.surface)).opacity(filled && hovered ? 0.88 : 1))
            .overlay(Capsule().strokeBorder(filled ? .clear : p.border, lineWidth: 1))
            .overlay(Capsule().strokeBorder(accent.opacity(focused ? 0.55 : 0), lineWidth: 3).padding(-3))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onHover { hovered = $0 }
    }
}

/// A key on the keyboard, for shortcuts shown in the pictures.
struct WelcomeKeyCap: View {
    var text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = PanelPalette(scheme)
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.secondary)
            .padding(.horizontal, 8).frame(minWidth: 26, minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(p.surface))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(p.border, lineWidth: 1))
    }
}
