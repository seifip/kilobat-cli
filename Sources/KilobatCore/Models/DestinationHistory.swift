import Foundation

// Destination history: how much each chosen app sent to and received from each site, one total per site per day.
// Off until the person turns it on, for one app at a time or for every app that isn't a browser. A browser is kept only
// when it's added by name, since its sites are the person's browsing. Kept on this Mac for 30 days, cleared and
// forgotten with the other histories that name hosts, and never part of a support report or a rules file.

/// Which apps' destinations are kept.
public struct DestinationHistorySettings: Codable, Equatable, Sendable {
    /// Every app and command-line tool except browsers and macOS's own services.
    public var allApps: Bool
    /// Apps kept by name (as usage history names them), with or without `allApps`. The only way a browser is kept.
    public var apps: [String]
    /// Apps left out while `allApps` is on.
    public var excluded: [String]
    public init(allApps: Bool = false, apps: [String] = [], excluded: [String] = []) {
        self.allApps = allApps; self.apps = apps; self.excluded = excluded
    }
    public var isOn: Bool { allApps || !apps.isEmpty }

    /// Whether an app's destinations are kept. A browser or a macOS service only when named.
    public func keeps(_ app: DestinationApp) -> Bool {
        if apps.contains(app.name) { return true }
        return allApps && !app.browser && !app.system && !excluded.contains(app.name)
    }

    /// Turns one app on or off, keeping the lists tidy.
    public mutating func set(_ name: String, on: Bool, browser: Bool, system: Bool) {
        apps.removeAll { $0 == name }; excluded.removeAll { $0 == name }
        if on { if !allApps || browser || system { apps.append(name) } }
        else if allApps && !browser && !system { excluded.append(name) }
        apps.sort(); excluded.sort()
    }
}

/// An app as destination history sees it.
public struct DestinationApp: Equatable, Sendable {
    /// What usage history calls it: the app that owns a helper, not the helper.
    public let name: String
    public let browser: Bool
    /// One of macOS's own services, such as the system's DNS or download daemons.
    public let system: Bool
    public init(name: String, browser: Bool, system: Bool) { self.name = name; self.browser = browser; self.system = system }

    /// Browsers by bundle ID, of the process or the app that owns it (Chrome's helpers, Safari's web content).
    public static func isBrowser(_ ids: [String?]) -> Bool {
        ids.contains { id in id.map { id in SendLater.browsers.contains { id.hasPrefix($0) } } ?? false }
    }
}

/// One app's bytes to one site on one day.
public struct DestinationRecord: Codable, Equatable, Sendable {
    /// The local day, "2026-11-10".
    public var day: String
    public var app: String
    /// The name the app asked for, as the network filter saw it, or the address when no name is known. Empty for
    /// the rest of a day past `DestinationHistory.maxHostsPerDay`.
    public var host: String
    /// An address the named host was reached at, so forgetting the address forgets the row too.
    public var address: String?
    public var received: UInt64
    public var sent: UInt64
    /// The last moment bytes moved, so clearing the last hour removes every row it touched.
    public var last: Date
    public var total: UInt64 { received + sent }
    public init(day: String, app: String, host: String, address: String? = nil, received: UInt64, sent: UInt64, last: Date) {
        self.day = day; self.app = app; self.host = host; self.address = address; self.received = received; self.sent = sent; self.last = last
    }
}

/// destination-history.json.
public struct DestinationHistoryFile: Codable, Equatable, Sendable {
    public var version = 1
    public var records: [DestinationRecord]
    public init(records: [DestinationRecord]) { self.records = records }
}

/// One site in an app's history, over the days asked for.
public struct DestinationTotal: Equatable, Identifiable, Sendable {
    public let host: String
    public let received: UInt64
    public let sent: UInt64
    /// On how many of the days it was contacted.
    public let days: Int
    public let last: Date
    public var id: String { host }
    public var total: UInt64 { received + sent }
}

public enum DestinationHistory {
    public static let retentionDays = 30
    /// Sites per app per day; past it, bytes go to one "other sites" row, so a scan can't grow the file without end.
    static let maxHostsPerDay = 400
    static let maxRecords = 80_000
    public static let fileName = "destination-history.json"

    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Adds bytes to the day's row for the app and site. `index` maps "day|app|host" to a row, and is rebuilt when stale.
    public static func add(app: String, host: String, address: String?, received: UInt64, sent: UInt64, at date: Date,
                           to records: inout [DestinationRecord], index: inout [String: Int], calendar: Calendar = .current) {
        guard received + sent > 0 else { return }
        let day = day(date, calendar: calendar)
        if index.count != records.count { index = Dictionary(records.enumerated().map { (key($0.element), $0.offset) }, uniquingKeysWith: { first, _ in first }) }
        var host = host
        if index[day + "|" + app + "|" + host] == nil {
            // The day's "other sites" row means the app reached its cap today: counting again for every sample would scan every row.
            if records.count >= maxRecords || index[day + "|" + app + "|"] != nil { host = "" }
            else if records.reduce(0, { $0 + ($1.day == day && $1.app == app ? 1 : 0) }) >= maxHostsPerDay { host = "" }
        }
        let key = day + "|" + app + "|" + host
        if let at = index[key] {
            records[at].received += received; records[at].sent += sent; records[at].last = max(records[at].last, date)
            if records[at].address == nil, host != "", let address, address != host { records[at].address = address }
        } else {
            records.append(DestinationRecord(day: day, app: app, host: host, address: host == "" || address == host ? nil : address, received: received, sent: sent, last: date))
            index[key] = records.count - 1
        }
    }
    static func key(_ record: DestinationRecord) -> String { record.day + "|" + record.app + "|" + record.host }

    /// Keeps the last 30 days, today included.
    public static func prune(_ records: inout [DestinationRecord], now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let first = calendar.date(byAdding: .day, value: 1 - retentionDays, to: calendar.startOfDay(for: now)) else { return false }
        let cutoff = day(first, calendar: calendar), before = records.count
        records.removeAll { $0.day < cutoff }
        return records.count != before
    }

    /// An app's sites over the last `days` days, most data first.
    public static func totals(_ records: [DestinationRecord], app: String, days: Int = retentionDays, now: Date = Date(), calendar: Calendar = .current) -> [DestinationTotal] {
        guard let first = calendar.date(byAdding: .day, value: 1 - days, to: calendar.startOfDay(for: now)) else { return [] }
        let cutoff = day(first, calendar: calendar)
        var sums: [String: (received: UInt64, sent: UInt64, days: Set<String>, last: Date)] = [:]
        for record in records where record.app == app && record.day >= cutoff {
            var sum = sums[record.host] ?? (0, 0, [], record.last)
            sum.received += record.received; sum.sent += record.sent; sum.days.insert(record.day); sum.last = max(sum.last, record.last)
            sums[record.host] = sum
        }
        return sums.map { DestinationTotal(host: $0.key, received: $0.value.received, sent: $0.value.sent, days: $0.value.days.count, last: $0.value.last) }
            .sorted { $0.total == $1.total ? $0.host < $1.host : $0.total > $1.total }
    }

    /// Removes one app's rows.
    public static func forget(app: String, in records: inout [DestinationRecord]) -> Int {
        let before = records.count
        records.removeAll { $0.app == app }
        return before - records.count
    }
}

extension HistoryEraser {
    /// Destination history: rows that had bytes in the period (a day's row goes whole, since it can't be split by the
    /// hour), or that name the site or its address.
    public static func apply(_ action: HistoryAction, to records: inout [DestinationRecord], now: Date = Date(), calendar: Calendar = .current) -> Int {
        let before = records.count
        switch action {
        case .clear(let range):
            if let cutoff = range.cutoff(now: now, calendar: calendar) { records.removeAll { $0.last >= cutoff } } else { records = [] }
        case .forget(let match):
            records.removeAll { ($0.host != "" && match.matches($0.host)) || match.matches($0.address) }
        }
        return before - records.count
    }
}

extension DestinationHistoryFile {
    static func load(_ url: URL) -> DestinationHistoryFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DestinationHistoryFile.self, from: data)
    }
    func data() throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
    /// For the command line while the app isn't running.
    public static func erase(_ action: HistoryAction, at url: URL, now: Date = Date()) throws -> Int {
        guard var file = load(url) else { return 0 }
        let removed = HistoryEraser.apply(action, to: &file.records, now: now)
        if removed > 0 { try file.data().write(to: url, options: .atomic) }
        return removed
    }
}
