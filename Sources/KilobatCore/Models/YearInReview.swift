import Foundation

/// The year in Kilobat, for the share card: what the usage history, the speed tests, the places the user named
/// and the call reports add up to. Network names never come in; a place is named only by what the user typed.
public struct YearInReview: Sendable, Equatable {
    public struct App: Sendable, Equatable {
        /// The bundle ID or `process:name` key from usage history; the card looks up the display name.
        public let id: String
        public let bytes: UInt64
        /// Of the year's total, 0 to 1.
        public let share: Double
    }
    public struct Busiest: Sendable, Equatable {
        public let start: Date
        public let bytes: UInt64
        /// A month when history spans more than one, otherwise a single day.
        public let month: Bool
    }
    public struct Place: Sendable, Equatable {
        /// The name the user typed on This place; nil for the fastest network, which the card never names.
        public let name: String?
        public let downloadMbps: Double
        public let uploadMbps: Double
    }

    public let year: Int
    /// The first day with history this year. The card says "since" that month when it isn't the year's first week.
    public let since: Date?
    public let wholeYear: Bool
    /// Internet bytes: local network and AirDrop traffic are already kept out of usage history.
    public let total: UInt64
    /// Bytes in each month of the year, January first; months before history starts are zero.
    public let months: [UInt64]
    public let hungriest: App?
    public let networks: Int
    public let busiest: Busiest?
    public let place: Place?
    /// The longest run of calls in a row without a freeze or an overloaded Mac.
    public let cleanStreak: Int
    public let calls: Int

    /// Nothing recorded yet, so there is no card to share.
    public var isEmpty: Bool { total == 0 }

    /// The year the card covers: the current one, or in January the one that just ended, so it can still be shared.
    public static func year(at now: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.year, .month], from: now)
        return (parts.year ?? 2026) - (parts.month == 1 ? 1 : 0)
    }
    /// December, when the menu and the share sheet put the card first.
    public static func season(_ now: Date, calendar: Calendar = .current) -> Bool { calendar.component(.month, from: now) == 12 }

    public init(usage: [UsageEntry], speedTests: [SavedSpeedTest], places: [String: String], calls: [CallReport],
                now: Date = Date(), calendar: Calendar = .current) {
        let year = Self.year(at: now, calendar: calendar)
        self.year = year
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? now
        let end = min(now, calendar.date(byAdding: .year, value: 1, to: start) ?? now)
        func within(_ date: Date) -> Bool { date >= start && date < end }

        let entries = usage.filter { within($0.date) }
        let tests = speedTests.filter { within($0.result.date) && $0.networkChanged != true }
        let calls = calls.filter { within($0.start) }.sorted { $0.start < $1.start }

        since = (entries.map(\.date) + tests.map(\.result.date) + calls.map(\.start)).min().map { calendar.startOfDay(for: $0) }
        wholeYear = since.map { $0 < (calendar.date(byAdding: .day, value: 7, to: start) ?? start) } ?? false

        var perApp = [String: UInt64](), perMonth = [Date: UInt64](), perDay = [Date: UInt64]()
        var total: UInt64 = 0
        for entry in entries {
            total += entry.total
            for (app, bytes) in entry.apps { perApp[app, default: 0] += bytes }
            if let month = calendar.dateInterval(of: .month, for: entry.date)?.start { perMonth[month, default: 0] += entry.total }
            perDay[calendar.startOfDay(for: entry.date), default: 0] += entry.total
        }
        self.total = total
        months = (1...12).map { month in
            calendar.date(from: DateComponents(year: year, month: month, day: 1)).flatMap { perMonth[$0] } ?? 0
        }
        // Ties go to the earlier key, so the card doesn't change between two renders of the same history.
        func top<Key: Comparable>(_ values: [Key: UInt64]) -> (key: Key, value: UInt64)? {
            values.filter { $0.value > 0 }.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }
        }
        hungriest = top(perApp).map { App(id: $0.key, bytes: $0.value, share: total > 0 ? min(1, Double($0.value) / Double(total)) : 0) }
        if perMonth.count > 1, let month = top(perMonth) { busiest = Busiest(start: month.key, bytes: month.value, month: true) }
        else { busiest = top(perDay).map { Busiest(start: $0.key, bytes: $0.value, month: false) } }

        let keys = entries.compactMap(\.networkKey) + tests.map(\.networkKey) + calls.compactMap(\.networkKey)
        networks = Set(keys.filter { $0 != "unknown" && !$0.isEmpty }).count

        let named = places.compactMapValues { name -> String? in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let best = tests.filter({ named[$0.networkKey] != nil }).max(by: { $0.result.downloadMbps < $1.result.downloadMbps }) {
            place = Place(name: named[best.networkKey], downloadMbps: best.result.downloadMbps, uploadMbps: best.result.uploadMbps)
        } else {
            place = tests.max { $0.result.downloadMbps < $1.result.downloadMbps }.map { Place(name: nil, downloadMbps: $0.result.downloadMbps, uploadMbps: $0.result.uploadMbps) }
        }

        cleanStreak = Self.longestCleanRun(calls)
        self.calls = calls.count
    }

    /// Consecutive clean calls, oldest first; a call with a freeze or an overloaded Mac ends the run.
    public static func longestCleanRun(_ calls: [CallReport]) -> Int {
        var best = 0, run = 0
        for call in calls.sorted(by: { $0.start < $1.start }) {
            run = call.clean ? run + 1 : 0
            best = max(best, run)
        }
        return best
    }
}
