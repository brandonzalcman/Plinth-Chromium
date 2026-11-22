import Foundation
import PlinthModel
import PlinthReader

/// How a page's text is read in Chromium. The shared reader script is the body of a function taking
/// `limit` and `focusLength` (WebKit calls it with `callAsyncJavaScript`); here it is wrapped in a
/// call so the renderer helper can evaluate it as one expression. It uses no `await`, so it runs
/// synchronously; if it ever does, evaluating it fails and the plain-text fallback is used.
enum PageTextScript {
    static func expression(limit: Int) -> String {
        "(function (limit, focusLength) {\n\(ReaderScript.source)\n})(\(max(0, limit)), \(ReaderScript.focusExcerptLength))"
    }

    /// Chromium's plain text of a page as a `PageText`: each line's whitespace collapsed, blank lines
    /// dropped, at most `limit` characters. nil when there is no text.
    static func plainText(_ text: String?, pageURL: URL, title: String, limit: Int, now: Date = Date()) -> PageText? {
        guard let text else { return nil }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        let joined = lines.joined(separator: "\n")
        guard !joined.isEmpty else { return nil }
        return PageText(url: pageURL, title: title, text: String(joined.prefix(max(0, limit))), extractedAt: now)
    }
}
