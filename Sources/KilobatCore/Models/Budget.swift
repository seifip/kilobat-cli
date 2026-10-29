import Foundation

/// When a network's data budget starts over. Session is the original behaviour: only a manual reset.
public enum BudgetPeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case session, daily, weekly, monthly
    public var id: String { rawValue }
    public var title: String {
        switch self { case .session: "Until reset"; case .daily: "Daily"; case .weekly: "Weekly"; case .monthly: "Monthly" }
    }
    /// "this month", for "1.2 of 5 GB this month".
    public var phrase: String {
        switch self { case .session: "this session"; case .daily: "today"; case .weekly: "this week"; case .monthly: "this month" }
    }
}

/// A budget's reset cycle and the percentages that notify.
public struct BudgetCycle: Codable, Equatable, Sendable {
    public var period: BudgetPeriod = .session
    /// The weekday a weekly budget starts on (1 Sunday … 7 Saturday, as `Calendar` counts), or the day of the
    /// month a monthly one starts on (1–31; short months start on their last day).
    public var anchor: Int? = nil
    /// Percentages that notify once per cycle. Nil means 80 and 100, except for a session budget, which
    /// stays quiet unless alerts were chosen, as it was before cycles.
    public var alerts: [Int]? = nil

    public init(period: BudgetPeriod = .session, anchor: Int? = nil, alerts: [Int]? = nil) {
        self.period = period; self.anchor = anchor; self.alerts = alerts
    }

    public static let defaultAlerts = [80, 100]
    public var thresholds: [Int] { Array(Set((alerts ?? (period == .session ? [] : Self.defaultAlerts)).filter { (1...100).contains($0) })).sorted() }

    /// The cycle that contains `date`; nil for a session budget, which follows no calendar. Days are counted
    /// with the calendar, so a daylight saving change can't move a reset off midnight.
    public func interval(containing date: Date, calendar: Calendar = .current) -> DateInterval? {
        switch period {
        case .session: return nil
        case .daily: return calendar.dateInterval(of: .day, for: date)
        case .weekly:
            let weekday = min(7, max(1, anchor ?? calendar.firstWeekday)), today = calendar.startOfDay(for: date)
            let back = (calendar.component(.weekday, from: today) - weekday + 7) % 7
            guard let start = calendar.date(byAdding: .day, value: -back, to: today), let end = calendar.date(byAdding: .day, value: 7, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        case .monthly:
            let day = min(31, max(1, anchor ?? 1))
            guard let month = calendar.dateInterval(of: .month, for: date)?.start else { return nil }
            func start(_ offset: Int) -> Date? {
                guard let first = calendar.date(byAdding: .month, value: offset, to: month), let length = calendar.range(of: .day, in: .month, for: first)?.count else { return nil }
                return calendar.date(byAdding: .day, value: min(day, length) - 1, to: first)
            }
            guard let this = start(0) else { return nil }
            let offset = date >= this ? 0 : -1
            guard let begin = start(offset), let end = start(offset + 1) else { return nil }
            return DateInterval(start: begin, end: end)
        }
    }

    /// App quotas need a calendar, so with a session budget they start over each day.
    public func quotaInterval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        interval(containing: date, calendar: calendar) ?? calendar.dateInterval(of: .day, for: date) ?? DateInterval(start: date, duration: 86_400)
    }

    /// "Monthly from the 5th", "Weekly from Monday", "Daily", "Until reset".
    public func summary(calendar: Calendar = .current) -> String {
        switch period {
        case .session, .daily: return period.title
        case .weekly: return "Weekly from " + calendar.weekdaySymbols[min(7, max(1, anchor ?? calendar.firstWeekday)) - 1]
        case .monthly: return "Monthly from day \(min(31, max(1, anchor ?? 1)))"
        }
    }

    /// "1.2 of 5 GB this month · resets 1 Nov"; a session budget has no reset date.
    public func progress(used: UInt64, limitGB: Double, now: Date = Date(), calendar: Calendar = .current) -> String {
        let gb = Double(used) / 1_000_000_000
        var text = gb.formatted(.number.precision(.fractionLength(0...(gb < 0.1 ? 2 : 1)))) + " of \(limitGB.formatted()) GB \(period.phrase)"
        if let end = interval(containing: now, calendar: calendar)?.end { text += " · resets " + end.formatted(.dateTime.day().month()) }
        return text
    }

    /// Bytes recorded in `interval`, on one network or every network when nil, for one app (by its history name) when given.
    public static func used(_ usage: [UsageEntry], in interval: DateInterval, network: String?, app: String? = nil, uploadOnly: Bool = false) -> UInt64 {
        usage.reduce(0) { total, entry in
            guard entry.date >= interval.start, entry.date < interval.end, network == nil || entry.networkKey == network else { return total }
            guard let app else { return total + (uploadOnly ? entry.sent : entry.total) }
            let bytes = entry.apps[app] ?? 0
            guard bytes > 0 else { return total }
            return total + (uploadOnly ? min(bytes, entry.estimatedSent[app] ?? 0) : bytes)
        }
    }
}

/// A data limit for one app per cycle. Usage is sampled, so the app may run a little over before it stops.
public struct AppQuota: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// The app as usage history names it; helpers count under the app that owns them.
    public var name: String
    /// Rule keys (bundle IDs or process:<name>) the filter stops once the quota is used up.
    public var apps: [String]
    public var bytes: UInt64
    public var uploadOnly: Bool
    /// The network key the quota counts on; nil counts every network.
    public var network: String?

    public init(name: String, apps: [String], bytes: UInt64, uploadOnly: Bool = false, network: String? = nil) {
        self.id = UUID(); self.name = name; self.apps = apps; self.bytes = bytes; self.uploadOnly = uploadOnly; self.network = network
    }

    /// Whether the quota counts traffic on `network`.
    public func applies(to network: String) -> Bool { self.network == nil || self.network == network }

    /// Bytes the app used in the cycle containing `now`.
    public func used(_ usage: [UsageEntry], cycle: BudgetCycle, now: Date = Date(), calendar: Calendar = .current) -> UInt64 {
        BudgetCycle.used(usage, in: cycle.quotaInterval(containing: now, calendar: calendar), network: network, app: name, uploadOnly: uploadOnly)
    }
}

/// Alerts already sent, so each fires once per cycle, also across relaunches. Values are when a key was last
/// seen, so old cycles can be dropped.
public struct AlertLedger: Codable, Equatable, Sendable {
    public var seen: [String: Date] = [:]
    public init() {}

    /// The thresholds `fraction` reached that haven't notified under `key` yet, now marked. Falling back under
    /// one (a reset, or a bigger budget) re-arms it.
    public mutating func crossed(_ thresholds: [Int], fraction: Double, key: String, now: Date = Date()) -> [Int] {
        var fresh: [Int] = []
        for threshold in thresholds {
            let id = key + "|" + String(threshold)
            if fraction * 100 >= Double(threshold) {
                if seen[id] == nil { fresh.append(threshold) }
                seen[id] = now
            } else { seen[id] = nil }
        }
        return fresh
    }

    /// True the first time `key` is seen.
    public mutating func once(_ key: String, now: Date = Date()) -> Bool {
        guard seen[key] == nil else { return false }
        seen[key] = now
        return true
    }

    public mutating func prune(now: Date = Date()) { seen = seen.filter { now.timeIntervalSince($0.value) < 35 * 86_400 } }
}

/// An app that uploaded far more in the last hour than it usually does in an hour.
public struct UploadAnomaly: Equatable, Sendable {
    public let app: String
    public let bytes: UInt64
    public let ratio: Double

    public static let minimumBytes: UInt64 = 50_000_000
    public static let factor = 5.0

    /// "Dropbox uploaded 2.1 GB in the last hour, 9× its usual."
    public var message: String { "\(app) uploaded \(TrafficFormat.bytes(bytes)) in the last hour, \(Int(ratio.rounded()))× its usual." }

    /// Apps that uploaded at least 50 MB in the hour before `now`, and at least five times their usual: the
    /// average over the hours of the week before in which they uploaded anything. Apps with fewer than three such
    /// hours have no usual yet. `pending` adds bytes not yet saved to history.
    public static func detect(_ usage: [UsageEntry], pending: [String: UInt64] = [:], now: Date = Date(), calendar: Calendar = .current) -> [UploadAnomaly] {
        let hourAgo = now.addingTimeInterval(-3_600), weekAgo = hourAgo.addingTimeInterval(-7 * 86_400)
        var recent = pending, hours: [String: [Date: UInt64]] = [:]
        for entry in usage where entry.date >= weekAgo && entry.date <= now {
            let sent = entry.estimatedSent
            if entry.date > hourAgo {
                for (app, bytes) in sent where bytes > 0 { recent[app, default: 0] += bytes }
            } else if let hour = calendar.dateInterval(of: .hour, for: entry.date)?.start {
                for (app, bytes) in sent where bytes > 0 { hours[app, default: [:]][hour, default: 0] += bytes }
            }
        }
        return recent.compactMap { app, bytes -> UploadAnomaly? in
            guard bytes >= minimumBytes, let past = hours[app], past.count >= 3 else { return nil }
            let usual = Double(past.values.reduce(0, +)) / Double(past.count)
            guard usual > 0, Double(bytes) >= usual * factor else { return nil }
            return UploadAnomaly(app: app, bytes: bytes, ratio: Double(bytes) / usual)
        }.sorted { $0.bytes > $1.bytes }
    }
}
