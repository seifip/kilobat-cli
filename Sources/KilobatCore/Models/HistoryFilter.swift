import Foundation

/// A display-name filter for history. Stored network identities and their usage remain separate.
public struct HistoryNetworkGroup: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let keys: Set<String>

    /// `names` maps each stored network key to its name (`UsageComparison.networkNames`); `extra` adds names only the
    /// health journal knows, which match by name and have no usage keys.
    public static func groups(_ names: [String: String], extra: some Sequence<String> = [String]()) -> [Self] {
        var keys = Dictionary(grouping: names.keys, by: { names[$0]! }).mapValues(Set.init)
        for name in extra where keys[name] == nil { keys[name] = [] }
        return keys.map { Self(name: $0.key, keys: $0.value) }
            .sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
            }
    }
}

/// History's one period choice, shared by every section: rolling windows from the last hour (usage is kept at 30-second
/// detail for a day) to the last year, and the calendar periods a router or provider counts by.
public enum HistoryPeriod: String, CaseIterable, Identifiable, Sendable {
    case hour, day, week, month, year, thisMonth = "this-month", lastMonth = "last-month", cycle, custom
    public var id: String { rawValue }

    /// Nil for a budget cycle without a budget, or custom dates that don't parse, run backwards or span over 400 days.
    public func interval(now: Date = Date(), calendar: Calendar = .current, cycle: DateInterval? = nil, from: String = "", to: String = "") -> DateInterval? {
        func last(_ seconds: TimeInterval) -> DateInterval { DateInterval(start: now.addingTimeInterval(-seconds), end: now) }
        switch self {
        case .hour: return last(3_600)
        case .day: return last(86_400)
        case .week: return last(7 * 86_400)
        case .month: return last(30 * 86_400)
        case .year: return last(365 * 86_400)
        case .thisMonth: return UsageComparison.Preset.thisMonth.interval(now: now, calendar: calendar)
        case .lastMonth: return UsageComparison.Preset.lastMonth.interval(now: now, calendar: calendar)
        case .cycle: return cycle
        case .custom:
            guard let start = UsageComparison.date(from, calendar: calendar), let end = UsageComparison.date(to, end: true, calendar: calendar),
                  end > start, end.timeIntervalSince(start) <= 400 * 86_400 else { return nil }
            return DateInterval(start: start, end: end)
        }
    }
}
