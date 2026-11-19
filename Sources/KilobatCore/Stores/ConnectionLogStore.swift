import Foundation
import Observation

/// The connection log as the app shows it: what the filter allowed and blocked in the last hour, folded by app,
/// destination and verdict. It lives in the filter's memory and here, never on disk; browsers are left out unless
/// asked for, and the filter forgets it a minute after Kilobat stops asking (RESEARCH-DECISIONS, "A DNS lookup log").
@MainActor @Observable public final class ConnectionLogStore {
    public private(set) var entries: [ConnectionLogEntry] = []
    /// When the filter started keeping this session's log; nil before the first answer.
    public private(set) var since: Date?
    public private(set) var updated: Date?
    public init() {}

    public func take(_ snapshot: ConnectionLogSnapshot, now: Date = Date()) {
        let next = snapshot.entries.filter { now.timeIntervalSince($0.last) < ConnectionLogSnapshot.window }.sorted { $0.last > $1.last }
        if next != entries { entries = next }
        since = snapshot.since; updated = now
    }
    /// Paused, or the filter went off: nothing is kept.
    public func clear() { entries = []; since = nil }

    #if DEBUG
    /// Made-up rows for screenshots.
    public func preview(_ rows: [ConnectionLogEntry]) { entries = rows; since = Date().addingTimeInterval(-1_800); updated = Date() }
    #endif
}

/// The connection log as the app hands it to `kilobat connections --log` and `get_connection_log`.
public struct ConnectionLogRelay: Codable, Equatable, Sendable {
    public let entries: [ConnectionLogEntry]
    public let since: Date?
    public let recording: Bool
    public let browsers: Bool
    public let filterActive: Bool
    public init(entries: [ConnectionLogEntry], since: Date?, recording: Bool, browsers: Bool, filterActive: Bool) {
        self.entries = entries; self.since = since; self.recording = recording; self.browsers = browsers; self.filterActive = filterActive
    }
}

/// How often each rule decided a connection: today's count, the total and the last time, per rule. Counts only, by
/// the rule's own key (a destination rule's id, an app rule's profile and app, a blocked host), kept 60 days.
@MainActor @Observable public final class RuleHitStore {
    public struct Count: Codable, Equatable, Sendable {
        /// The day `today` counts, as yyyy-MM-dd in the Mac's calendar.
        public var day: String
        public var today: Int
        public var total: Int
        public var last: Date
    }
    public private(set) var counts: [String: Count] = [:]
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var lastSave = Date.distantPast

    public nonisolated static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat/rule-hits.json")
    }

    public init(file: URL? = nil) {
        self.file = file ?? Self.fileURL
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: self.file), let saved = try? decoder.decode([String: Count].self, from: data) { counts = saved }
    }

    /// Adds what the filter counted since it was last asked. Saved at most once a minute.
    public func add(_ hits: [String: Int], now: Date = Date(), calendar: Calendar = .current) {
        guard !hits.isEmpty else { return }
        let day = DestinationHistory.day(now, calendar: calendar)
        for (key, added) in hits where added > 0 {
            var count = counts[key] ?? Count(day: day, today: 0, total: 0, last: now)
            if count.day != day { count.day = day; count.today = 0 }
            count.today += added; count.total += added; count.last = now
            counts[key] = count
        }
        dirty = true
        if now.timeIntervalSince(lastSave) >= 60 { save(now: now) }
    }

    /// Today's count for a rule; zero on a new day.
    public func today(_ key: String, now: Date = Date(), calendar: Calendar = .current) -> Int {
        guard let count = counts[key], count.day == DestinationHistory.day(now, calendar: calendar) else { return 0 }
        return count.today
    }

    public func save(now: Date = Date()) {
        guard dirty else { return }
        counts = counts.filter { now.timeIntervalSince($0.value.last) < 60 * 86_400 }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(counts) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic])
        dirty = false; lastSave = now
    }

    /// The same counts as the command line reads them, while the app may be running.
    public nonisolated static func load(file: URL = RuleHitStore.fileURL) -> [String: Count] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: file)).flatMap { try? decoder.decode([String: Count].self, from: $0) } ?? [:]
    }

    /// A listed rule's key in the counts; nil for the kinds the filter doesn't count (exceptions, allowed sites).
    public nonisolated static func key(_ rule: ListedRule) -> String? {
        switch rule.origin {
        case .app(let profile, let key): RuleHitKey.app(profile: profile, key: key)
        case .timedApp(let key): RuleHitKey.timedPrefix + key
        case .destination(let id): RuleHitKey.destination(id)
        case .blockedHost(let host): RuleHitKey.blocked(host)
        case .exception, .allowedSite: nil
        }
    }

    #if DEBUG
    public func preview(_ counts: [String: Count]) { self.counts = counts }
    #endif
}
