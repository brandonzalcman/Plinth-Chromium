import Foundation
import PlinthCEF
import PlinthSettings

/// The Chromium profile preferences that carry Plinth's settings (HTTPS-only, cookies, fonts, zoom).
enum ChromiumPreferences {
    enum Value: Equatable {
        case bool(Bool)
        case int(Int)
        case double(Double)
        case doubles([String: Double])

        var object: Any {
            switch self {
            case .bool(let b): NSNumber(value: b)
            case .int(let i): NSNumber(value: i)
            case .double(let d): NSNumber(value: d)
            case .doubles(let d): d.mapValues { NSNumber(value: $0) } as NSDictionary
            }
        }
    }

    /// Chromium's zoom level for a zoom factor (1 = 100%): each level is a factor of 1.2.
    static func zoomLevel(forFactor factor: Double) -> Double {
        guard factor > 0, factor.isFinite else { return 0 }
        let level = log(factor) / log(1.2)
        return abs(level) < 1e-9 ? 0 : level
    }

    /// Chromium's cookie_controls_mode: 1 blocks third-party cookies, 0 allows them.
    static func cookieControlsMode(blockThirdParty: Bool) -> Int { blockThirdParty ? 1 : 0 }

    /// Every preference to set, in order. A name a given Chromium doesn't have is refused and
    /// logged, and the rest still apply.
    static func values(for s: AppSettings) -> [(name: String, value: Value)] {
        [
            ("https_only_mode_enabled", .bool(s.httpsOnly)),
            ("profile.cookie_controls_mode", .int(cookieControlsMode(blockThirdParty: s.blockThirdPartyCookies))),
            ("webkit.webprefs.default_font_size", .int(s.defaultFontSize)),
            ("webkit.webprefs.minimum_font_size", .int(s.minimumFontSize)),
            // Keyed by storage partition; Chromium names the profile's default partition "x".
            ("partition.default_zoom_level", .doubles(["x": zoomLevel(forFactor: s.defaultZoom)])),
        ]
    }

    /// True when going from `old` to `new` changes a preference set here.
    static func differ(_ old: AppSettings, _ new: AppSettings) -> Bool {
        values(for: old).map(\.value) != values(for: new).map(\.value)
    }

    @MainActor static func apply(_ s: AppSettings, to profile: PCEFProfile) {
        for (name, value) in values(for: s) { profile.setPreference(name, value: value.object) }
    }
}
