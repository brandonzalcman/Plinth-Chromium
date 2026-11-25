import Foundation
import PlinthModel

/// "Not now" on a group suggestion. The shared store only rules out the exact set and its parts, so
/// with several sites open together the next combination of the same sites came straight back and
/// "Not now" had to be clicked again and again. Here "Not now" quiets every suggestion made only of
/// sites already turned down, for a day. A suggestion that brings in a new site still shows.
public struct SuggestionSnooze: Codable, Equatable, Sendable {
    public static let length: TimeInterval = 24 * 60 * 60

    /// Hosts of the sites turned down while the snooze runs.
    public var hosts: Set<String> = []
    public var until: Date = .distantPast

    public init() {}

    public func hides(_ suggestion: GroupSuggestion, now: Date) -> Bool {
        guard now < until else { return false }
        return suggestion.keys.allSatisfy { hosts.contains($0.host) }
    }

    /// Turns the suggestion down: its sites join the snooze, which runs a day from now.
    public mutating func notNow(_ suggestion: GroupSuggestion, now: Date) {
        if now >= until { hosts = [] }
        hosts.formUnion(suggestion.keys.map(\.host))
        until = now.addingTimeInterval(Self.length)
    }
}
