import AppKit
import CoreText
import SwiftUI

/// Plinth's brand, as the icon and getplinth.dev show it: an arch filled with a sky (Plinth blue to
/// peach) outlined in ink, standing on an ink plinth, on warm paper. Headings are set in Space Grotesk.
enum Brand {
    static let ink = Color(hex: 0x1C1C1A)
    static let paper = Color(hex: 0xF6F1E7)
    static let sand = Color(hex: 0xD9D0BC)
    static let blue = Color(hex: 0x2F5BEA)
    static let peach = Color(hex: 0xFFC9A3)

    /// The sky in the arch: Plinth blue at the top, warming to peach at the horizon.
    static let sky = LinearGradient(colors: [blue, peach], startPoint: .top, endPoint: .bottom)
    /// The same sky laid sideways, for progress lines.
    static let skyAcross = LinearGradient(colors: [blue, Color(hex: 0x8D86D9), peach], startPoint: .leading, endPoint: .trailing)

    static let displayFamily = "Space Grotesk"

    /// The display face at a size and weight; the rounded system face if Space Grotesk isn't loaded.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        if fontLoaded { return .custom(displayFamily, size: size).weight(weight) }
        return .system(size: size, weight: weight, design: .rounded)
    }

    nonisolated(unsafe) private static var fontLoaded = false

    /// Registers the bundled Space Grotesk for this process. Called once at launch.
    static func registerFonts() {
        guard !fontLoaded,
              let url = Bundle.module.url(forResource: "SpaceGrotesk-Variable", withExtension: "ttf", subdirectory: "Fonts")
        else { return }
        var error: Unmanaged<CFError>?
        fontLoaded = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            || NSFont(name: "SpaceGrotesk-Regular", size: 12) != nil || NSFontManager.shared.availableMembers(ofFontFamily: displayFamily) != nil
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// The Plinth mark: the arch with its sky, standing on the plinth. `tile` draws the paper app-icon tile behind it.
struct PlinthMarkView: View {
    var size: CGFloat
    var tile = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let k = size / 280
        // On a dark surface without the tile, the ink outline would vanish: draw it in paper instead.
        let line = tile || scheme == .light ? Brand.ink : Brand.paper
        ZStack {
            if tile {
                RoundedRectangle(cornerRadius: 62 * k, style: .continuous).fill(Brand.paper)
                RoundedRectangle(cornerRadius: 62 * k, style: .continuous).strokeBorder(Brand.sand, lineWidth: 8 * k)
            }
            Arch().fill(Brand.sky)
            Arch().stroke(line, style: StrokeStyle(lineWidth: 18 * k, lineJoin: .round))
            Path(roundedRect: CGRect(x: 48 * k, y: 194 * k, width: 184 * k, height: 38 * k), cornerRadius: 6 * k).fill(line)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Plinth")
    }

    /// The arch from the icon, in its 280-unit grid.
    private struct Arch: Shape {
        func path(in r: CGRect) -> Path {
            let k = r.width / 280
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * k, y: r.minY + y * k) }
            var p = Path()
            p.move(to: pt(84, 196))
            p.addLine(to: pt(84, 112))
            p.addArc(center: pt(140, 112), radius: 56 * k, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: pt(196, 196))
            p.closeSubpath()
            return p
        }
    }
}
