import Foundation

// Ported from the Plinth package's PlinthImport module, which is not in the PlinthCore product, and
// widened from Safari, Chrome, Arc and Zen to every browser a Mac is likely to have.

/// A browser Plinth can import from.
public enum ImportSource: String, CaseIterable, Sendable, Identifiable {
    case safari, chrome, edge, brave, arc, vivaldi, opera, chromium, firefox, zen

    public var id: String { rawValue }

    /// How the browser keeps its data. Browsers in one family share a reader.
    public enum Family: Sendable, Equatable {
        /// `Bookmarks.plist` and `History.db` under ~/Library/Safari.
        case safari
        /// A `Bookmarks` JSON file, a `History` database and a `Login Data` database in each profile folder.
        case chromium
        /// `places.sqlite`, `logins.json` and `key4.db` in each profile listed in `profiles.ini`.
        case firefox
    }

    public var displayName: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .edge: "Microsoft Edge"
        case .brave: "Brave"
        case .arc: "Arc"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        case .chromium: "Chromium"
        case .firefox: "Firefox"
        case .zen: "Zen"
        }
    }

    public var family: Family {
        switch self {
        case .safari: .safari
        case .chrome, .edge, .brave, .arc, .vivaldi, .opera, .chromium: .chromium
        case .firefox, .zen: .firefox
        }
    }

    /// The folder that holds the browser's profiles, relative to the home folder.
    var dataPath: String {
        switch self {
        case .safari: "Library/Safari"
        case .chrome: "Library/Application Support/Google/Chrome"
        case .edge: "Library/Application Support/Microsoft Edge"
        case .brave: "Library/Application Support/BraveSoftware/Brave-Browser"
        case .arc: "Library/Application Support/Arc/User Data"
        case .vivaldi: "Library/Application Support/Vivaldi"
        case .opera: "Library/Application Support/com.operasoftware.Opera"
        case .chromium: "Library/Application Support/Chromium"
        case .firefox: "Library/Application Support/Firefox"
        case .zen: "Library/Application Support/zen"
        }
    }

    /// The folder that holds the browser's profiles.
    public func dataFolder(home: URL) -> URL { home.appendingPathComponent(dataPath, isDirectory: true) }

    /// The Keychain item ("<Browser> Safe Storage") whose password protects a Chromium-family browser's
    /// saved logins. nil for Safari and the Firefox family.
    public var safeStorageItem: (service: String, account: String)? {
        switch self {
        case .chrome: ("Chrome Safe Storage", "Chrome")
        case .edge: ("Microsoft Edge Safe Storage", "Microsoft Edge")
        case .brave: ("Brave Safe Storage", "Brave")
        case .arc: ("Arc Safe Storage", "Arc")
        case .vivaldi: ("Vivaldi Safe Storage", "Vivaldi")
        case .opera: ("Opera Safe Storage", "Opera")
        case .chromium: ("Chromium Safe Storage", "Chromium")
        case .safari, .firefox, .zen: nil
        }
    }
}
