import SwiftUI
import PlinthPanels

// The guide's opening: the Plinth mark builds itself and the sun rises, as in the Mac app, then the
// two ways this build shows pages (the dock and the sidebar) slide up beneath it.

/// The brand mark (docs/brand-guide.md, a 280-unit grid), drawn in code so it can animate and follow
/// dark mode: Sunrise in light, the Dusk colourway in dark. Ported from the Mac app's `PlinthMark`.
struct WelcomeMark: View {
    var dark: Bool
    var size: CGFloat
    /// 0...1 each.
    var tile = 1.0
    var steps = 1.0
    var frame = 1.0
    var sky = 1.0
    var sun = 1.0

    private var tileColour: Color { dark ? Color(welcomeHex: 0x1B1A2E) : Color(welcomeHex: 0xF6F1E7) }
    private var edge: Color { dark ? Color(welcomeHex: 0x3A3958) : Color(welcomeHex: 0xD9D0BC) }
    private var ink: Color { dark ? Color(welcomeHex: 0xF4EEE6) : Color(welcomeHex: 0x1C1C1A) }
    private var gradient: LinearGradient {
        LinearGradient(stops: dark
            ? [.init(color: Color(welcomeHex: 0x3A2A7A), location: 0), .init(color: Color(welcomeHex: 0xB0509A), location: 0.6), .init(color: Color(welcomeHex: 0xFF9E7A), location: 1)]
            : [.init(color: Color(welcomeHex: 0x2F5BEA), location: 0), .init(color: Color(welcomeHex: 0x93AAFF), location: 0.6), .init(color: Color(welcomeHex: 0xFFC9A3), location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        let k = size / 280
        ZStack {
            RoundedRectangle(cornerRadius: 64 * k, style: .continuous).fill(tileColour)
                .overlay(RoundedRectangle(cornerRadius: 64 * k, style: .continuous).strokeBorder(edge, lineWidth: 1))
                .opacity(tile)
            Arch().fill(gradient).opacity(sky)
            Circle().fill(Color(welcomeHex: dark ? 0xFFE0B8 : 0xFFF1DA))
                .frame(width: 52 * k, height: 52 * k)
                .position(x: 140 * k, y: 186 * k + (1 - sun) * 70 * k)
                .mask(Arch())
                .opacity(sun > 0 ? 1 : 0)
            Arch(open: true).trim(from: 0, to: frame).stroke(ink, style: StrokeStyle(lineWidth: 10 * k, lineJoin: .round))
            step(x: 72, y: 190, w: 136).opacity(steps).offset(y: (1 - steps) * 14 * k)
            step(x: 50, y: 214, w: 180).opacity(steps).offset(y: (1 - steps) * 22 * k)
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .accessibilityHidden(true)
    }

    private func step(x: CGFloat, y: CGFloat, w: CGFloat) -> some View {
        let k = size / 280
        return RoundedRectangle(cornerRadius: 4 * k, style: .continuous).fill(ink)
            .frame(width: w * k, height: 20 * k)
            .position(x: (x + w / 2) * k, y: (y + 10) * k)
            .frame(width: size, height: size)
    }

    /// The arch in the 280-unit grid.
    private struct Arch: Shape {
        var open = false
        func path(in r: CGRect) -> Path {
            let k = r.width / 280
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * k, y: r.minY + y * k) }
            var p = Path()
            p.move(to: pt(92, 192))
            p.addLine(to: pt(92, 108))
            p.addArc(center: pt(140, 108), radius: 48 * k, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: pt(188, 192))
            if !open { p.closeSubpath() }
            return p
        }
    }
}

/// About 2.6 s: the plinth builds itself, the sun rises, then a dock and a sidebar slide up beneath it.
/// Click anywhere, or press Esc, Return or Space, to skip. With Reduce Motion it is a short still fade.
struct WelcomeIntro: View {
    var reduceMotion: Bool
    var accent: Color
    var onDone: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var start = Date()
    @State private var stillShown = false
    @FocusState private var focused: Bool
    static let duration = 2.6

    /// Eased progress of `t` between `a` and `b`.
    private func seg(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let x = min(max((t - a) / (b - a), 0), 1)
        return 1 - pow(1 - x, 3)
    }

    var body: some View {
        let p = PanelPalette(scheme)
        ZStack {
            if reduceMotion {
                scene(t: Self.duration, p: p).opacity(stillShown ? 1 : 0)
            } else {
                TimelineView(.animation) { context in
                    scene(t: context.date.timeIntervalSince(start), p: p)
                }
            }
            VStack {
                Spacer()
                Text("Click or press Esc to skip").font(.system(size: 11.5)).foregroundStyle(p.tertiary).padding(.bottom, 18)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onDone)
        .focusable().focusEffectDisabled().focused($focused)
        .onKeyPress(.return) { onDone(); return .handled }
        .onKeyPress(.space) { onDone(); return .handled }
        .onKeyPress(.escape) { onDone(); return .handled }
        .onKeyPress(.rightArrow) { onDone(); return .handled }
        .onAppear { focused = true }
        .task {
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.5)) { stillShown = true }
                try? await Task.sleep(for: .seconds(1.8))
            } else {
                start = Date()
                try? await Task.sleep(for: .seconds(Self.duration + 0.15))
            }
            if !Task.isCancelled { onDone() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Welcome to Plinth")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Skips the animation")
    }

    @ViewBuilder private func scene(t: Double, p: PanelPalette) -> some View {
        let dark = scheme == .dark
        let lift = seg(t, 1.35, 1.95)
        let chrome = seg(t, 1.7, 2.3)
        ZStack {
            // A soft glow behind the mark that warms as the sun comes up.
            Circle().fill(RadialGradient(colors: [(dark ? Color(welcomeHex: 0xB0509A) : Color(welcomeHex: 0xFFC9A3)).opacity(0.32 * seg(t, 0.8, 1.6)), .clear],
                                         center: .center, startRadius: 0, endRadius: 190))
                .frame(width: 380, height: 380).offset(y: -60 - 18 * lift)
            WelcomeMark(dark: dark, size: 160,
                        tile: seg(t, 0, 0.45), steps: seg(t, 0.1, 0.7), frame: seg(t, 0.35, 1.05),
                        sky: seg(t, 0.8, 1.25), sun: seg(t, 0.95, 1.6))
                .scaleEffect(0.94 + 0.06 * seg(t, 0, 1.6))
                .offset(y: -76 - 18 * lift)
            VStack(spacing: 4) {
                Text("Plinth").font(.system(size: 30, weight: .semibold)).kerning(-1.3).foregroundStyle(p.primary)
                Text("on Chromium").font(.system(size: 13, weight: .medium)).foregroundStyle(p.secondary)
            }
            .opacity(seg(t, 1.3, 1.85)).offset(y: 40 - 18 * lift + (1 - seg(t, 1.3, 1.85)) * 8)
            HStack(spacing: 18) {
                MiniWindowSketch(layout: .dock, accent: accent, highlighted: false)
                MiniWindowSketch(layout: .sidebar, accent: accent, highlighted: false)
            }
            .scaleEffect(0.82)
            .opacity(chrome)
            .offset(y: 168 + (1 - chrome) * 30)
        }
    }
}

extension Color {
    init(welcomeHex hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}
