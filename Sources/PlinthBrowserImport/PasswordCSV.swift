import Foundation
import PlinthPasswords

/// Reads a password export from any browser on the Mac, or from Apple Passwords, 1Password or Bitwarden.
/// Each writes its own columns; the header row says which one made the file.
public enum PasswordCSV {
    /// Who wrote the file, judged by its header.
    public enum Format: String, Sendable, Equatable {
        /// Chrome, Edge, Brave, Arc, Vivaldi, Opera and Chromium: name, url, username, password[, note].
        case chromium
        /// Safari and the Passwords app: Title, URL, Username, Password, Notes, OTPAuth.
        case applePasswords
        /// Firefox and Zen: url, username, password, httpRealm, formActionOrigin, guid, timeCreated, …
        case firefox
        /// 1Password: Title, Url (or website), Username, Password, …
        case onePassword
        /// Bitwarden: folder, favorite, type, name, notes, …, login_uri, login_username, login_password.
        case bitwarden
        /// Any other file with a URL, a user name and a password column.
        case generic

        public var displayName: String {
            switch self {
            case .chromium: "a Chrome-family browser"
            case .applePasswords: "Safari or the Passwords app"
            case .firefox: "Firefox or Zen"
            case .onePassword: "1Password"
            case .bitwarden: "Bitwarden"
            case .generic: "a password manager"
            }
        }
    }

    /// Which column holds what.
    public struct Columns: Equatable, Sendable {
        public var url: Int
        public var username: Int?
        public var password: Int
        /// Milliseconds since 1970 (Firefox).
        public var created: Int?
        /// Bitwarden's item type: only "login" rows are logins.
        public var type: Int?
    }

    public struct Result: Equatable, Sendable {
        public var logins: [Login] = []
        /// Rows without a usable site, user name or password.
        public var skipped = 0
        public var format: Format = .generic
    }

    public enum Failure: Error, Equatable, Sendable {
        /// No header row with a URL and a password column.
        case unrecognised
    }

    private static let urlNames = ["url", "login_uri", "website", "web site", "origin", "hostname", "site", "uri", "address"]
    private static let userNames = ["username", "login_username", "user name", "user", "login", "email", "e-mail", "account"]
    private static let passwordNames = ["password", "login_password", "pass"]

    /// The format and columns for a header row, or nil if it has no URL or password column.
    public static func detect(header: [String]) -> (format: Format, columns: Columns)? {
        let names = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let set = Set(names)
        func column(_ options: [String]) -> Int? {
            for option in options { if let i = names.firstIndex(of: option) { return i } }
            return nil
        }
        func index(_ name: String) -> Int? { names.firstIndex(of: name) }

        if let url = index("login_uri"), let password = index("login_password") {
            return (.bitwarden, Columns(url: url, username: index("login_username"), password: password, type: index("type")))
        }
        if let url = index("url"), let password = index("password"),
           set.contains("httprealm") || set.contains("formactionorigin") || (set.contains("guid") && set.contains("timecreated")) {
            return (.firefox, Columns(url: url, username: index("username"), password: password, created: index("timecreated")))
        }
        if let password = index("password"), let url = index("url") ?? index("website"), index("title") != nil,
           index("website") != nil || set.contains("favorite") || set.contains("archived") || set.contains("tags") {
            return (.onePassword, Columns(url: url, username: index("username"), password: password))
        }
        if let url = index("url"), let password = index("password"), index("title") != nil, set.contains("otpauth") || set.contains("notes") {
            return (.applePasswords, Columns(url: url, username: index("username"), password: password))
        }
        if let url = index("url"), let password = index("password"), index("name") != nil, index("username") != nil {
            return (.chromium, Columns(url: url, username: index("username"), password: password))
        }
        guard let url = column(urlNames), let password = column(passwordNames) else { return nil }
        return (.generic, Columns(url: url, username: column(userNames), password: password))
    }

    public static func parse(_ text: String, now: Date = Date()) throws -> Result {
        let rows = records(text)
        guard let header = rows.first, let (format, columns) = detect(header: header) else { throw Failure.unrecognised }
        var result = Result(format: format)
        for row in rows.dropFirst() where !(row.count == 1 && row[0].isEmpty) {
            func cell(_ i: Int?) -> String { i.flatMap { $0 < row.count ? row[$0] : nil } ?? "" }
            if let type = columns.type, !cell(type).isEmpty, cell(type).lowercased() != "login" { result.skipped += 1; continue }
            let username = cell(columns.username), password = cell(columns.password)
            guard let origin = WebOrigin(string: cell(columns.url)), !password.isEmpty, !username.isEmpty else {
                result.skipped += 1
                continue
            }
            var created = now
            if let ms = Double(cell(columns.created)), ms > 0 { created = Date(timeIntervalSince1970: ms / 1000) }
            result.logins.append(Login(origin: origin, username: username, password: password, created: created))
        }
        return result
    }

    /// RFC 4180: quoted fields, doubled quotes, newlines inside quotes, CRLF or LF, a leading byte-order mark.
    static func records(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(text.unicodeScalars)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.unicodeScalars.append("\""); i += 1 } else { quoted = false }
                } else { field.unicodeScalars.append(c) }
            } else {
                switch c {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n":
                    row.append(field); rows.append(row); row = []; field = ""
                case "\r":
                    if i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                    row.append(field); rows.append(row); row = []; field = ""
                default: field.unicodeScalars.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
