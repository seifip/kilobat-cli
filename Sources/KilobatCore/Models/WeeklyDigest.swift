import Foundation

// MARK: Schedule

/// When the weekly digest goes out: a weekday and an hour, local time, kept where the app and the CLI both read them.
/// The digest reports the seven days before the day it goes out, so a Monday digest covers Monday to Sunday.
public struct DigestSchedule: Codable, Sendable, Equatable {
    public static let enabledKey = "digest.enabled"
    public static let weekdayKey = "digest.weekday"
    public static let hourKey = "digest.hour"
    /// The last delivery time handled, sent or skipped, so one is never sent twice.
    public static let lastKey = "digest.last"
    /// A digest the Mac slept through still goes out within this long of its time; after that it's no longer news.
    public static let catchUp: TimeInterval = 3 * 86_400
    /// Two digests never go out closer together than this, even after the day is changed.
    public static let spacing: TimeInterval = 4 * 86_400
    /// A late digest waits for the daytime: from 7 am to 10 pm.
    public static let daytime = 7..<22

    public var enabled = true
    /// `Calendar` weekday: 1 is Sunday, 2 Monday.
    public var weekday = 2
    public var hour = 9
    public init(enabled: Bool = true, weekday: Int = 2, hour: Int = 9) { self.enabled = enabled; self.weekday = weekday; self.hour = hour }

    public static func load(_ defaults: UserDefaults = .standard) -> DigestSchedule {
        let weekday = defaults.object(forKey: weekdayKey) as? Int ?? 2, hour = defaults.object(forKey: hourKey) as? Int ?? 9
        return DigestSchedule(enabled: defaults.object(forKey: enabledKey) as? Bool ?? true,
                              weekday: (1...7).contains(weekday) ? weekday : 2, hour: (0...23).contains(hour) ? hour : 9)
    }
    public func save(_ defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.enabledKey); defaults.set(weekday, forKey: Self.weekdayKey); defaults.set(hour, forKey: Self.hourKey)
    }

    /// The latest delivery time at or before `now`.
    public func slot(atOrBefore now: Date, calendar: Calendar = .current) -> Date {
        let parts = DateComponents(hour: hour, minute: 0, second: 0, weekday: weekday)
        return calendar.nextDate(after: now.addingTimeInterval(1), matching: parts, matchingPolicy: .nextTime, direction: .backward)
            ?? now.addingTimeInterval(-7 * 86_400)
    }

    /// The seven days a digest sent at `slot` reports: from a week before the slot's day to the start of that day.
    public static func week(for slot: Date, weeksAgo: Int = 0, calendar: Calendar = .current) -> DateInterval {
        let end = calendar.date(byAdding: .day, value: -7 * weeksAgo, to: calendar.startOfDay(for: slot)) ?? slot
        let start = calendar.date(byAdding: .day, value: -7, to: end) ?? end.addingTimeInterval(-7 * 86_400)
        return DateInterval(start: start, end: end)
    }

    public enum Skip: String, Codable, Sendable {
        /// Kilobat's history starts inside the week: too little to say anything.
        case firstWeek
        /// The Mac slept through the time and woke more than `catchUp` later.
        case stale
        /// Another digest went out less than `spacing` ago, such as after the day was changed.
        case tooSoon
    }
    public enum Decision: Equatable, Sendable {
        case wait
        case send(slot: Date, week: DateInterval)
        /// Mark the slot handled without sending.
        case skip(slot: Date, Skip)
    }

    /// What to do now. `last` is the slot handled last; `historyStart` when Kilobat's history begins.
    public func decide(now: Date, last: Date?, historyStart: Date?, calendar: Calendar = .current) -> Decision {
        guard enabled else { return .wait }
        let slot = slot(atOrBefore: now, calendar: calendar)
        if let last, last >= slot { return .wait }
        if now.timeIntervalSince(slot) > Self.catchUp { return .skip(slot: slot, .stale) }
        if let last, slot.timeIntervalSince(last) < Self.spacing { return .skip(slot: slot, .tooSoon) }
        let week = Self.week(for: slot, calendar: calendar)
        guard let historyStart, WeeklyDigest.covers(historyStart, week.start) else { return .skip(slot: slot, .firstWeek) }
        // On time, or a catch-up after sleep that waits for the daytime.
        if now.timeIntervalSince(slot) > 3600, !Self.daytime.contains(calendar.component(.hour, from: now)) { return .wait }
        return .send(slot: slot, week: week)
    }
}

// MARK: Protection ledger

/// What Protection blocked each day, kept longer than the filter's own seven-day log so a week can be told in full on
/// Monday and compared with the week before. Counts only, no hosts. `weekly-digest.json` in Application Support.
public struct DigestLedger: Codable, Sendable, Equatable {
    public struct Counts: Codable, Sendable, Equatable {
        public var threats = 0
        public var trackers = 0
        public var agentGuard = 0
        /// Threat and agent-guard blocks made by an AI agent's processes.
        public var agents = 0
        public init(threats: Int = 0, trackers: Int = 0, agentGuard: Int = 0, agents: Int = 0) {
            self.threats = threats; self.trackers = trackers; self.agentGuard = agentGuard; self.agents = agents
        }
        static func max(_ a: Counts, _ b: Counts) -> Counts {
            Counts(threats: Swift.max(a.threats, b.threats), trackers: Swift.max(a.trackers, b.trackers),
                   agentGuard: Swift.max(a.agentGuard, b.agentGuard), agents: Swift.max(a.agents, b.agents))
        }
        static func + (a: Counts, b: Counts) -> Counts {
            Counts(threats: a.threats + b.threats, trackers: a.trackers + b.trackers, agentGuard: a.agentGuard + b.agentGuard, agents: a.agents + b.agents)
        }
    }
    public static let keepDays = 63
    /// By local day, "2026-10-26".
    public var days: [String: Counts] = [:]
    public init(days: [String: Counts] = [:]) { self.days = days }

    public static func file(_ directory: URL? = nil) -> URL {
        (directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat"))
            .appendingPathComponent("weekly-digest.json")
    }
    public static func load(directory: URL? = nil) -> DigestLedger { StoredJSON.read(file(directory)) ?? DigestLedger() }
    public func save(directory: URL? = nil) {
        let url = Self.file(directory)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    public static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    /// Each day's counts from the filter's log. The log forgets after seven days and 1,000 entries, so a day keeps the
    /// most it was ever counted at: merging again never double-counts, and a day half gone from the log keeps its count.
    @discardableResult public mutating func record(_ events: [FilterEvent], now: Date = Date(), calendar: Calendar = .current) -> Bool {
        var fresh: [String: Counts] = [:]
        for event in events {
            guard let detail = event.protection else { continue }
            var counts = fresh[Self.key(event.date, calendar: calendar)] ?? Counts()
            switch detail.kind {
            case .tracker: counts.trackers += 1
            case .agentGuard: counts.agentGuard += 1
            default: counts.threats += 1
            }
            if detail.kind != .tracker, detail.agent != nil { counts.agents += 1 }
            fresh[Self.key(event.date, calendar: calendar)] = counts
        }
        let before = days
        for (day, counts) in fresh { days[day] = days[day].map { Counts.max($0, counts) } ?? counts }
        let cutoff = Self.key(now.addingTimeInterval(-Double(Self.keepDays) * 86_400), calendar: calendar)
        days = days.filter { $0.key >= cutoff }
        return days != before
    }
    /// Counts per day of `interval`, oldest first.
    public func counts(in interval: DateInterval, calendar: Calendar = .current) -> [Counts] {
        WeeklyDigest.dayStarts(interval, calendar: calendar).map { days[Self.key($0, calendar: calendar)] ?? Counts() }
    }
}

// MARK: Input

/// Everything the digest reads, gathered by the app or the CLI from what Kilobat keeps on this Mac.
public struct DigestInput {
    public var events: [NetworkEvent] = []
    public var samples: [DiagnosticSnapshot] = []
    public var sleeps: [DateInterval] = []
    public var starlink: [StarlinkOutage] = []
    public var calls: [CallReport] = []
    public var remote: [RemoteSessionReport] = []
    public var usage: [UsageEntry] = []
    /// Names by network key, from `network-sessions.json`.
    public var networkNames: [String: String] = [:]
    /// Networks set to metered by hand, for history from before usage recorded it.
    public var meteredNetworks: Set<String> = []
    /// Networks marked as home in Devices.
    public var homeNetworks: Set<String> = []
    public var routers: [RouterRecord] = []
    public var ledger = DigestLedger()
    /// The filter's log, for which agent was behind a block.
    public var blocked: [FilterEvent] = []
    public var agents: [AgentNetworkSession] = []
    public var pastAgentHosts: Set<String> = []
    public var credit: CreditSettings? = nil
    public var speedTests: [SavedSpeedTest] = []
    /// Plan speeds by network key.
    public var plans: [String: Double] = [:]
    var scopedStarlink: StarlinkJournal?

    public init() {}

    /// What Kilobat saved on this Mac, read from Application Support and the app's settings: the app and the CLI tell
    /// the same week. `defaults` is the app's domain (the CLI passes it by name).
    public static func saved(directory: URL? = nil, defaults: UserDefaults = .standard, now: Date = Date()) -> DigestInput {
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")
        // Read only: a file that doesn't decode is left where it is for the app to deal with.
        func read<T: Decodable>(_ name: String) -> T? { (try? Data(contentsOf: folder.appendingPathComponent(name))).flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
        var input = DigestInput()
        input.events = read("events.json") ?? []
        input.samples = read("health-samples.json") ?? []
        input.speedTests = read("speed-tests.json") ?? []
        input.sleeps = read("sleeps.json") ?? []
        let dish = StarlinkJournal.load(directory: folder)
        input.scopedStarlink = dish
        input.starlink = dish.outages(on: dish.network)
        input.calls = CallStore.load(directory: folder)
        input.remote = RemoteSessionStore.load(directory: folder)
        input.usage = read("usage.json") ?? []
        let sessions: [String: NetworkSession] = read("network-sessions.json") ?? [:]
        input.networkNames = UsageComparison.networkNames(input.usage, sessions: sessions)
        let preferences: SavedPreferences = read("preferences.json") ?? SavedPreferences()
        input.meteredNetworks = Set((preferences.networkCost ?? [:]).filter { $0.value == NetworkCost.metered.rawValue }.keys)
        let devices: DeviceBook = read("devices.json") ?? DeviceBook()
        input.homeNetworks = Set(devices.networks.filter(\.value.home).keys)
        input.routers = RouterWatch.load(directory: folder).routers
        // The filter's own log, as the app keeps it; not moved aside if it can't be read.
        input.blocked = (try? Data(contentsOf: folder.appendingPathComponent("filter-events.json"))).flatMap { try? JSONDecoder().decode([FilterEvent].self, from: $0) } ?? []
        input.ledger = DigestLedger.load(directory: folder)
        input.ledger.record(input.blocked, now: now)
        if let log = AgentLogFile.load(folder.appendingPathComponent("agent-network-log.json")) { input.agents = log.sessions; input.pastAgentHosts = Set(log.pastHosts) }
        input.credit = CreditSettings.load(defaults)
        input.plans = PlanSpeeds.all(defaults)
        return input
    }

    /// The first day anything was recorded.
    public var historyStart: Date? {
        [usage.map(\.date).min(), events.map(\.start).min(), calls.map(\.start).min(), speedTests.map(\.result.date).min()].compactMap { $0 }.min()
    }
}

// MARK: The digest

/// The week in a few lines: the 3–4 most notable things Kilobat saw in seven days, in the order they matter, each with
/// a comparison with the week before when that says something. A calm week says so in one sentence. Zeros are never
/// listed. Without Pro, a fact whose cause is a Pro feature shows its count, and the first such fact carries the one
/// line saying what Pro would have explained.
public struct WeeklyDigest: Codable, Sendable, Equatable {
    public enum Topic: String, Codable, Sendable, CaseIterable {
        case outages, calls, remote, router, starlink, protection, agents, metered, credit, plan, signIns, trackers, routerHealthy
    }
    /// The workspace tab a fact's button opens.
    public enum Tab: String, Codable, Sendable { case history = "History", health = "Wi-Fi", connections = "Connections", speed = "Speed" }

    public struct Fact: Codable, Sendable, Equatable, Identifiable {
        public var id: Topic { topic }
        public let topic: Topic
        public let score: Double
        /// Something went wrong, as opposed to a figure worth knowing; a week with none is calm.
        public let problem: Bool
        /// A clause for the notification and the panel's first line: "2 outages on your provider’s side (41 min)".
        public let line: String
        /// What it means, in a sentence or two.
        public let detail: String?
        /// "half last week’s", only when the week before was recorded and the change says something.
        public var comparison: String?
        /// One value a day, oldest first, for a sparkline; nil where Kilobat has no daily series.
        public let days: [Double]?
        public let tab: Tab
        /// Without Pro: what Pro would have explained here. On one fact at most.
        public var proHint: String?
        /// The fact's main number and the week before's, for scripts.
        public let value: Double
        public var previous: Double?
        /// A cause or detail only Pro shows; free digests have one hidden here.
        let hint: String?
        init(topic: Topic, score: Double, problem: Bool, line: String, detail: String? = nil, days: [Double]? = nil, tab: Tab, value: Double, hint: String? = nil) {
            self.topic = topic; self.score = score; self.problem = problem; self.line = line; self.detail = detail; self.days = days; self.tab = tab
            self.value = value; self.hint = hint
        }
        enum CodingKeys: String, CodingKey { case topic, score, problem, line, detail, comparison, days, tab, proHint, value, previous }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            topic = try c.decode(Topic.self, forKey: .topic); score = try c.decode(Double.self, forKey: .score); problem = try c.decode(Bool.self, forKey: .problem)
            line = try c.decode(String.self, forKey: .line); detail = try c.decodeIfPresent(String.self, forKey: .detail)
            comparison = try c.decodeIfPresent(String.self, forKey: .comparison); days = try c.decodeIfPresent([Double].self, forKey: .days)
            tab = try c.decode(Tab.self, forKey: .tab); proHint = try c.decodeIfPresent(String.self, forKey: .proHint)
            value = try c.decode(Double.self, forKey: .value); previous = try c.decodeIfPresent(Double.self, forKey: .previous); hint = nil
        }
    }

    public static let shown = 4
    /// In the notification.
    public static let notified = 3

    public let start: Date
    public let end: Date
    public let pro: Bool
    /// Kilobat's history starts inside the week, so it is partial: the app doesn't send it.
    public let partial: Bool
    /// The week before was recorded, so comparisons were made.
    public let compared: Bool
    /// No problem worth a line.
    public let calm: Bool
    /// The most notable, most notable first; at most `shown`.
    public let facts: [Fact]
    /// The calm week's sentence: "A calm week: no outages, every call clean, 38 GB at home."
    public let summary: String?
    /// The notification's body.
    public let headline: String
    /// Nothing at all was recorded in the week.
    public var empty: Bool { facts.isEmpty && summary == nil }
    /// The one Pro line, when a Pro feature would have explained something real this week.
    public var proHint: String? { facts.lazy.compactMap(\.proHint).first }

    /// History that starts by this long after the week does still covers it: the app was set up that morning.
    static let slack: TimeInterval = 12 * 3600
    static func covers(_ historyStart: Date, _ weekStart: Date) -> Bool { historyStart <= weekStart.addingTimeInterval(slack) }

    public static func make(_ input: DigestInput, week: DateInterval, pro: Bool, now: Date = Date(), calendar: Calendar = .current) -> WeeklyDigest {
        let before = DateInterval(start: calendar.date(byAdding: .day, value: -7, to: week.start) ?? week.start.addingTimeInterval(-7 * 86_400), end: week.start)
        let history = input.historyStart
        let compared = history.map { covers($0, before.start) } ?? false
        let current = Tally(input, week, now: now, calendar: calendar)
        let previous = compared ? Tally(input, before, now: now, calendar: calendar) : nil
        var facts = Builder(input: input, week: week, current: current, previous: previous, pro: pro, now: now, calendar: calendar).facts()
        facts.sort { $0.score > $1.score }
        // Router healthy only reassures: it says the trouble above it wasn't the router.
        if !facts.contains(where: { $0.problem && [.outages, .calls, .remote].contains($0.topic) }) { facts.removeAll { $0.topic == .routerHealthy } }
        facts = Array(facts.prefix(shown))
        // One Pro line at most: on the first fact a Pro feature would have explained.
        if !pro, let index = facts.firstIndex(where: { $0.hint != nil }) { facts[index].proHint = facts[index].hint }
        let calm = !facts.contains(where: \.problem)
        let summary = calm ? current.calmSentence(input) : nil
        let notified = facts.filter { calm ? $0.topic != .routerHealthy : true }.prefix(notified).map(\.line)
        let headline: String
        if let summary {
            headline = ([summary] + notified.prefix(1).map { String(localized: "Also: \($0).", comment: "Weekly digest notification after the calm week's sentence; the argument is one fact, such as “4.2 GB on Phone, a metered network”") }).joined(separator: " ")
        } else {
            headline = sentence(Array(notified))
        }
        return WeeklyDigest(start: week.start, end: week.end, pro: pro, partial: history.map { !covers($0, week.start) } ?? true, compared: compared,
                            calm: calm, facts: facts, summary: summary, headline: headline)
    }

    /// "A, B and C." with the first letter capitalised for the locale.
    static func sentence(_ parts: [String]) -> String {
        guard !parts.isEmpty else { return "" }
        let joined = parts.formatted(.list(type: .and))
        return joined.prefix(1).uppercased() + joined.dropFirst() + "."
    }

    /// The local midnights of each day in `interval`.
    static func dayStarts(_ interval: DateInterval, calendar: Calendar) -> [Date] {
        var days: [Date] = [], day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }
    static func dayIndex(_ date: Date, _ days: [Date]) -> Int? {
        guard let first = days.first, date >= first else { return nil }
        return days.lastIndex { $0 <= date }
    }

    /// The panel's date range: "26 Oct – 1 Nov".
    public var range: String { (start..<end.addingTimeInterval(-1)).formatted(.interval.month(.abbreviated).day()) }
}

// MARK: Counting a week

extension WeeklyDigest {
    /// One week's numbers, for the facts and for comparing with the week before.
    struct Tally {
        var days: [Date]
        var outageSeconds: [Double]
        var provider: (count: Int, seconds: Double) = (0, 0)
        var local: (count: Int, seconds: Double) = (0, 0)
        var unproven: (count: Int, seconds: Double) = (0, 0)
        var signIns: (count: Int, seconds: Double) = (0, 0)
        var tally: CreditTally
        var calls: [CallReport] = []
        var remote: [RemoteSessionReport] = []
        var protection: [DigestLedger.Counts]
        var bytes: [UInt64]
        var meteredBytes: [UInt64]
        var meteredNetworks: [String: UInt64] = [:]
        var networks: [String: UInt64] = [:]
        var starlinkSetup: [StarlinkOutage] = []
        var agentSessions: [AgentNetworkSession] = []

        var allOutages: (count: Int, seconds: Double) { (provider.count + local.count + unproven.count, provider.seconds + local.seconds + unproven.seconds) }
        var troubledCalls: [CallReport] { calls.filter { !$0.clean } }
        var laggedSessions: [RemoteSessionReport] { remote.filter { !$0.lags.isEmpty || !$0.strain.isEmpty } }
        var threats: Int { protection.reduce(0) { $0 + $1.threats + $1.agentGuard } }
        var trackers: Int { protection.reduce(0) { $0 + $1.trackers } }
        var agentBlocks: Int { protection.reduce(0) { $0 + $1.agents } }
        var totalBytes: UInt64 { bytes.reduce(0, +) }
        var totalMetered: UInt64 { meteredBytes.reduce(0, +) }
        var recorded: Bool { totalBytes > 0 || !calls.isEmpty || !tally.outages.isEmpty || allOutages.count > 0 }

        init(_ input: DigestInput, _ week: DateInterval, now: Date, calendar: Calendar) {
            let starts = WeeklyDigest.dayStarts(week, calendar: calendar)
            days = starts
            let index = { (date: Date) in WeeklyDigest.dayIndex(date, starts) }
            // Outages by side, each judged as the outage credit judges it: the router answering means beyond it.
            tally = CreditTally.make(events: input.events, samples: input.samples, starlink: input.starlink, sleeps: input.sleeps,
                                     network: nil, from: week.start, to: week.end, now: now)
            provider = (tally.outages.count, tally.totalSeconds)
            outageSeconds = Array(repeating: 0, count: days.count)
            for outage in tally.outages { if let day = index(outage.start) { outageSeconds[day] += outage.seconds } }
            for event in input.events where [CreditTally.unreachable, CreditTally.signIn].contains(event.kind) && event.start < week.end && (event.end ?? now) > week.start {
                let one = CreditTally.make(events: [event], samples: input.samples, sleeps: input.sleeps, network: nil, from: week.start, to: week.end, now: now)
                if event.kind == CreditTally.signIn {
                    if one.portalSeconds > 0 { signIns.count += 1; signIns.seconds += one.portalSeconds }
                } else if one.localSeconds > 0 {
                    local.count += 1; local.seconds += one.localSeconds
                    if let day = index(event.start) { outageSeconds[day] += one.localSeconds }
                } else if one.unprovenSeconds > 0 {
                    unproven.count += 1; unproven.seconds += one.unprovenSeconds
                    if let day = index(event.start) { outageSeconds[day] += one.unprovenSeconds }
                }
            }
            calls = input.calls.filter { week.contains($0.start) }
            remote = input.remote.filter { week.contains($0.start) }
            protection = input.ledger.counts(in: week, calendar: calendar)
            bytes = Array(repeating: 0, count: days.count); meteredBytes = bytes
            for entry in input.usage where week.contains(entry.date) {
                guard let day = index(entry.date) else { continue }
                bytes[day] += entry.total
                let key = entry.networkKey ?? "unknown"
                networks[key, default: 0] += entry.total
                if entry.metered == true || input.meteredNetworks.contains(key) {
                    meteredBytes[day] += entry.total; meteredNetworks[key, default: 0] += entry.total
                }
            }
            starlinkSetup = input.starlink.filter { week.contains($0.start) && $0.side == .setup }
            agentSessions = input.agents.filter { $0.start < week.end && ($0.end ?? now) > week.start }
        }

        /// "A calm week: no outages, every call clean, 38 GB at home." Nil when nothing was recorded.
        func calmSentence(_ input: DigestInput) -> String? {
            guard recorded else { return nil }
            var parts: [String] = []
            if allOutages.count == 0 { parts.append(String(localized: "no outages", comment: "Weekly digest, calm week: part of a list")) }
            if calls.count == 1, troubledCalls.isEmpty { parts.append(String(localized: "your call was clean", comment: "Weekly digest, calm week: part of a list")) }
            else if calls.count > 1, troubledCalls.isEmpty { parts.append(String(localized: "every call clean", comment: "Weekly digest, calm week: part of a list")) }
            if totalBytes > 0 {
                let amount = TrafficFormat.bytes(totalBytes)
                if let top = networks.max(by: { $0.value < $1.value }), Double(top.value) >= Double(totalBytes) * 0.6, top.key != "unknown" {
                    if input.homeNetworks.contains(top.key) { parts.append(String(localized: "\(amount) at home", comment: "Weekly digest, calm week: data moved on the home network, such as “38 GB at home”")) }
                    else if let name = input.networkNames[top.key] { parts.append(String(localized: "\(amount) on \(name)", comment: "Weekly digest, calm week: data moved on one network; the arguments are an amount and a network name")) }
                    else { parts.append(String(localized: "\(amount) moved", comment: "Weekly digest, calm week: data moved this week, such as “38 GB moved”")) }
                } else {
                    parts.append(String(localized: "\(amount) moved", comment: "Weekly digest, calm week: data moved this week, such as “38 GB moved”"))
                }
            }
            guard !parts.isEmpty else { return String(localized: "A calm week.", comment: "Weekly digest: nothing went wrong") }
            return String(localized: "A calm week: \(parts.formatted(.list(type: .and))).", comment: "Weekly digest: nothing went wrong; the argument lists things like “no outages, every call clean and 38 GB at home”")
        }
    }
}

// MARK: The facts

extension WeeklyDigest {
    /// Rank bases, in the order the facts matter; a fact's severity adds up to 20, so a severe one can pass the next.
    enum Base {
        static let outages = 100.0, calls = 90.0, remote = 84.0, router = 80.0, starlink = 76.0, localOutages = 74.0
        static let protection = 70.0, agents = 64.0, metered = 60.0, credit = 56.0, plan = 50.0, signIns = 40.0, trackers = 20.0, routerHealthy = 10.0
    }

    struct Builder {
        let input: DigestInput
        let week: DateInterval
        let current: Tally
        let previous: Tally?
        let pro: Bool
        let now: Date
        let calendar: Calendar

        func facts() -> [Fact] {
            [outages(), calls(), remote(), router(), starlink(), protection(), agents(), metered(), credit(), plan(), signIns(), trackers(), routerHealthy()].compactMap { $0 }
        }

        private func compare(_ fact: Fact?, _ value: Double, _ before: Double?, bytes: Bool = false) -> Fact? {
            guard var fact else { return nil }
            fact.previous = before
            if let before { fact.comparison = WeeklyDigest.comparison(value, before, bytes: bytes) }
            return fact
        }
        private func minutes(_ seconds: Double) -> String { CreditText.duration(seconds) }

        // Outages: on the provider's side with Pro, all of them without.
        func outages() -> Fact? {
            // Starlink's own outages aren't in the journal, so the provider's side can be the larger count.
            let all = (count: max(current.allOutages.count, current.provider.count), seconds: max(current.allOutages.seconds, current.provider.seconds))
            guard all.count > 0 else { return nil }
            let days = current.outageSeconds.map { $0 / 60 }
            if !pro {
                let line = all.count == 1 ? String(localized: "1 outage (\(minutes(all.seconds)))", comment: "Weekly digest; the argument is a length such as “41 min”")
                    : String(localized: "\(all.count) outages (\(minutes(all.seconds)))", comment: "Weekly digest; a count and a length such as “41 min”")
                let fact = Fact(topic: .outages, score: Base.outages + severity(count: all.count, seconds: all.seconds), problem: true, line: line,
                                detail: String(localized: "Times the internet didn’t answer while your Mac was awake.", comment: "Weekly digest detail for outages without Pro"),
                                days: days, tab: .history, value: Double(all.count),
                                hint: String(localized: "Kilobat Pro shows whose side each outage was on: your provider’s, or your router’s and Wi-Fi’s.", comment: "Weekly digest Pro line"))
                return compare(fact, Double(all.count), previous.map { Double($0.allOutages.count) })
            }
            var extra: [String] = []
            if current.provider.count > 0, current.local.count > 0 {
                extra.append(current.local.count == 1 ? String(localized: "1 more was at your router or Wi-Fi (\(minutes(current.local.seconds))).", comment: "Weekly digest detail; a length")
                             : String(localized: "\(current.local.count) more were at your router or Wi-Fi (\(minutes(current.local.seconds))).", comment: "Weekly digest detail; a count and a length"))
            }
            if current.unproven.count > 0 {
                extra.append(current.unproven.count == 1 ? String(localized: "1 had too few checks to say whose side it was on.", comment: "Weekly digest detail")
                             : String(localized: "\(current.unproven.count) had too few checks to say whose side they were on.", comment: "Weekly digest detail; a count"))
            }
            if current.provider.count > 0 {
                let line = current.provider.count == 1 ? String(localized: "1 outage on your provider’s side (\(minutes(current.provider.seconds)))", comment: "Weekly digest; a length such as “41 min”")
                    : String(localized: "\(current.provider.count) outages on your provider’s side (\(minutes(current.provider.seconds)))", comment: "Weekly digest; a count and a length such as “41 min”")
                let lead = String(localized: "Your router answered while the internet didn’t, so the trouble was beyond your home.", comment: "Weekly digest detail for provider outages")
                let fact = Fact(topic: .outages, score: Base.outages + severity(count: current.provider.count, seconds: current.provider.seconds), problem: true, line: line,
                                detail: ([lead] + extra).joined(separator: " "), days: days, tab: .history, value: Double(current.provider.count))
                return compare(fact, Double(current.provider.count), previous.map { Double($0.provider.count) })
            }
            if current.local.count > 0 {
                let line = current.local.count == 1 ? String(localized: "1 outage at your router or Wi-Fi (\(minutes(current.local.seconds)))", comment: "Weekly digest; a length")
                    : String(localized: "\(current.local.count) outages at your router or Wi-Fi (\(minutes(current.local.seconds)))", comment: "Weekly digest; a count and a length")
                let lead = String(localized: "The router stopped answering too, so it was on your side: the router, its power or the Wi-Fi.", comment: "Weekly digest detail for outages at the router")
                let fact = Fact(topic: .outages, score: Base.localOutages + severity(count: current.local.count, seconds: current.local.seconds), problem: true, line: line,
                                detail: ([lead] + extra).joined(separator: " "), days: days, tab: .history, value: Double(current.local.count))
                return compare(fact, Double(current.local.count), previous.map { Double($0.local.count) })
            }
            let line = all.count == 1 ? String(localized: "1 outage (\(minutes(all.seconds)))", comment: "Weekly digest; the argument is a length such as “41 min”")
                : String(localized: "\(all.count) outages (\(minutes(all.seconds)))", comment: "Weekly digest; a count and a length such as “41 min”")
            let fact = Fact(topic: .outages, score: Base.localOutages, problem: true, line: line, detail: extra.joined(separator: " "), days: days, tab: .history, value: Double(all.count))
            return compare(fact, Double(all.count), previous.map { Double($0.allOutages.count) })
        }

        private func severity(count: Int, seconds: Double) -> Double { min(20, Double(count) * 2 + seconds / 600) }

        // Calls that froze, and with Pro what froze most of them.
        func calls() -> Fact? {
            let troubled = current.troubledCalls, total = current.calls.count
            guard !troubled.isEmpty else { return nil }
            let count = troubled.count
            let base: String = if total == 1 { String(localized: "Your call froze", comment: "Weekly digest: the week's only call froze") }
                else if count == total { String(localized: "All \(total) calls froze", comment: "Weekly digest; a count") }
                else if count == 1 { String(localized: "1 of \(total) calls froze", comment: "Weekly digest; a count of calls") }
                else { String(localized: "\(count) of \(total) calls froze", comment: "Weekly digest; two counts of calls") }
            var line = base, detail: String? = nil
            let causes = Dictionary(grouping: troubled, by: { WeeklyDigest.cause(of: $0) }).mapValues(\.count)
            if pro, let top = causes.filter({ $0.key != nil }).max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key! > $1.key!) }), let reason = top.key {
                line = top.value == count
                    ? String(localized: "\(base), \(reason)", comment: "Weekly digest: calls that froze, then why, such as “3 of 12 calls froze, because of Dropbox”")
                    : String(localized: "\(base), \(top.value) \(reason)", comment: "Weekly digest: calls that froze, then how many had the main cause, such as “3 of 12 calls froze, 2 because of Dropbox”")
                detail = troubled.last { WeeklyDigest.cause(of: $0) == reason }?.advice
            }
            let days = current.days.map { day in Double(troubled.filter { calendar.isDate($0.start, inSameDayAs: day) }.count) }
            let fact = Fact(topic: .calls, score: Base.calls + min(20, Double(count) * 3), problem: true, line: line,
                            detail: detail ?? String(localized: "Each call’s report is in Health.", comment: "Weekly digest detail for calls"), days: days, tab: .health, value: Double(count),
                            hint: String(localized: "Kilobat Pro shows what froze each call, such as an app uploading or weak Wi-Fi, and what to change.", comment: "Weekly digest Pro line"))
            // A week before without calls says nothing about calls.
            return compare(fact, Double(count), previous.flatMap { $0.calls.isEmpty ? nil : Double($0.troubledCalls.count) })
        }

        func remote() -> Fact? {
            let lagged = current.laggedSessions, total = current.remote.count
            guard !lagged.isEmpty else { return nil }
            let line = lagged.count == 1
                ? (total == 1 ? String(localized: "Your remote session lagged", comment: "Weekly digest: an SSH or remote desktop session lagged")
                              : String(localized: "1 of \(total) remote sessions lagged", comment: "Weekly digest; a count of SSH or remote desktop sessions"))
                : String(localized: "\(lagged.count) of \(total) remote sessions lagged", comment: "Weekly digest; two counts of SSH or remote desktop sessions")
            let fact = Fact(topic: .remote, score: Base.remote + min(16, Double(lagged.count) * 2), problem: true, line: line,
                            detail: pro ? lagged.last.map(\.verdict) : String(localized: "SSH, Mosh and remote desktop reports are in Health.", comment: "Weekly digest detail"),
                            tab: .health, value: Double(lagged.count),
                            hint: String(localized: "Kilobat Pro shows why typing lagged or the screen froze, and when Mosh would help.", comment: "Weekly digest Pro line"))
            return compare(fact, Double(lagged.count), previous.flatMap { $0.remote.isEmpty ? nil : Double($0.laggedSessions.count) })
        }

        // The router slowing over days. Without Pro the slower days show, not that the router is why.
        func router() -> Fact? {
            for record in input.routers.sorted(by: { $0.lastSeen > $1.lastSeen }) where record.lastSeen >= week.start {
                let episode = record.episodes.last { $0.start < week.end && ($0.end ?? .distantFuture) > week.start }
                let assessment = record.assess(now: min(now, week.end), calendar: calendar)
                guard let baseline = episode?.baseline ?? (assessment.degraded ? assessment.baseline : nil) else { continue }
                let daily = RouterCheckup.days(record.allHours, calendar: calendar)
                let rtts = current.days.map { day in daily.first { calendar.isDate($0.day, inSameDayAs: day) }?.rtt }
                let slow = rtts.compactMap { $0 }.filter { $0 >= RouterCheckup.slowerThreshold(baseline) }
                // An episode that ended before any slow day of this week isn't this week's news.
                guard !slow.isEmpty else { continue }
                let worst = episode?.rtt ?? slow.max() ?? baseline.rtt
                let series = rtts.compactMap { $0 }
                let line: String, detail: String
                if pro {
                    line = String(localized: "Your router slowed down (\(Self.ms(worst)) instead of \(Self.ms(baseline.rtt)))", comment: "Weekly digest; two reply times such as “19 ms” and “4 ms”")
                    detail = String(localized: "Its replies have been slower than its usual for days. Restarting it often puts that right; Health has the details.", comment: "Weekly digest detail for router check-up")
                } else {
                    let count = slow.count
                    line = count == 1 ? String(localized: "Your connection was slower than usual on 1 day", comment: "Weekly digest without Pro")
                        : String(localized: "Your connection was slower than usual on \(count) days", comment: "Weekly digest without Pro; a count of days")
                    detail = String(localized: "Replies close to home took longer than they normally do.", comment: "Weekly digest detail without Pro")
                }
                return Fact(topic: .router, score: Base.router + min(20, worst / max(1, baseline.rtt) * 3), problem: true, line: line, detail: detail,
                            days: series.count >= 2 ? series : nil, tab: .health, value: worst,
                            hint: String(localized: "Kilobat Pro shows that it was your router, and whether restarting it helped before.", comment: "Weekly digest Pro line"))
            }
            return nil
        }

        func routerHealthy() -> Fact? {
            guard pro, let record = input.routers.sorted(by: { $0.lastSeen > $1.lastSeen }).first(where: { $0.lastSeen >= week.start }) else { return nil }
            let assessment = record.assess(now: min(now, week.end), calendar: calendar)
            guard assessment.state == .normal, let usual = assessment.baseline?.rtt else { return nil }
            return Fact(topic: .routerHealthy, score: Base.routerHealthy, problem: false, line: String(localized: "router healthy", comment: "Weekly digest: part of a list, after outages or calls"),
                        detail: String(localized: "Your router answered as quickly as usual all week.", comment: "Weekly digest detail"), tab: .health, value: usual)
        }

        // The dish's own outages: obstructions, heat, the cable. Starlink's network counts with the outages above.
        func starlink() -> Fact? {
            let drops = current.starlinkSetup, seconds = drops.reduce(0) { $0 + $1.seconds }
            guard drops.count >= 3 || seconds >= 60 else { return nil }
            let obstructed = drops.filter { $0.cause == .obstructed }
            let line = pro && obstructed.count * 2 >= drops.count
                ? String(localized: "Your Starlink dish was blocked \(obstructed.count) times (\(minutes(obstructed.reduce(0) { $0 + $1.seconds })))", comment: "Weekly digest; a count and a length")
                : String(localized: "Your Starlink dish dropped \(drops.count) times (\(minutes(seconds)))", comment: "Weekly digest; a count and a length")
            let days = current.days.map { day in drops.filter { calendar.isDate($0.start, inSameDayAs: day) }.reduce(0) { $0 + $1.seconds } / 60 }
            let fact = Fact(topic: .starlink, score: Base.starlink + min(16, seconds / 120), problem: true, line: line,
                            detail: pro ? String(localized: "Drops your setup can fix: something in the dish’s view, heat or the cable. Health shows which way it’s blocked.", comment: "Weekly digest detail") : nil,
                            days: days, tab: .health, value: Double(drops.count),
                            hint: String(localized: "Kilobat Pro shows whether drops were your setup or Starlink’s network, and what to move.", comment: "Weekly digest Pro line"))
            return compare(fact, Double(drops.count), previous.map { Double($0.starlinkSetup.count) })
        }

        // Threats and the agent guard; agents first, since that is what someone running agents wants to know.
        func protection() -> Fact? {
            let threats = current.threats, agents = current.agentBlocks
            guard threats > 0 else { return nil }
            let line: String
            if agents > 0 {
                let names = Set(input.blocked.filter { week.contains($0.date) }.compactMap(\.protection).filter { $0.kind != .tracker }.compactMap(\.agent)).sorted()
                if names.count == 1, agents == threats {
                    line = agents == 1 ? String(localized: "Kilobat stopped \(names[0]) reaching a risky host", comment: "Weekly digest; an AI agent such as Claude Code")
                        : String(localized: "Kilobat stopped \(names[0]) reaching risky hosts \(agents) times", comment: "Weekly digest; an AI agent such as Claude Code and a count")
                } else {
                    line = String(localized: "Kilobat blocked \(threats) risky connections, \(agents) from AI agents", comment: "Weekly digest; two counts")
                }
            } else {
                line = threats == 1 ? String(localized: "Kilobat blocked 1 known threat", comment: "Weekly digest: malware, phishing or scam")
                    : String(localized: "Kilobat blocked \(threats) known threats", comment: "Weekly digest: malware, phishing or scam; a count")
            }
            let days = current.protection.map { Double($0.threats + $0.agentGuard) }
            let fact = Fact(topic: .protection, score: Base.protection + min(20, Double(agents) * 8 + Double(threats)), problem: true, line: line,
                            detail: String(localized: "Malware, phishing and scam hosts, and the agent guard. Blocked attempts are in Connections.", comment: "Weekly digest detail"),
                            days: days, tab: .connections, value: Double(threats))
            return compare(fact, Double(threats), previous.map { Double($0.threats) })
        }

        // The agent network log's flags worth a second look: a share or tunnel, a large upload.
        func agents() -> Fact? {
            guard pro, !current.agentSessions.isEmpty else { return nil }
            let ids = Set(current.agentSessions.map(\.id))
            let entries = AgentNetworkLog.report(input.agents, pastHosts: input.pastAgentHosts).filter { ids.contains($0.id) }
            let hosts = entries.flatMap(\.hosts).filter { $0.flags.contains(.shareOrTunnel) || $0.flags.contains(.largeUpload) }
            guard !hosts.isEmpty else { return nil }
            let agents = Set(entries.filter { $0.hosts.contains(where: { $0.flags.contains(.shareOrTunnel) || $0.flags.contains(.largeUpload) }) }.map(\.agent)).sorted()
            let line = hosts.count == 1
                ? String(localized: "\(agents.formatted(.list(type: .and))) sent data somewhere new worth a look", comment: "Weekly digest; AI agents such as Claude Code")
                : String(localized: "\(agents.formatted(.list(type: .and))) sent data to \(hosts.count) hosts worth a look", comment: "Weekly digest; AI agents and a count")
            return Fact(topic: .agents, score: Base.agents + min(16, Double(hosts.count) * 4), problem: true, line: line,
                        detail: String(localized: "A paste site, file share or tunnel, or a large upload. None of these means something is wrong; the agent network log in History has each one.", comment: "Weekly digest detail"),
                        tab: .history, value: Double(hosts.count))
        }

        // Data on metered networks: a hotspot or tethering.
        func metered() -> Fact? {
            let bytes = current.totalMetered
            guard bytes >= 100_000_000 else { return nil }
            let amount = TrafficFormat.bytes(bytes)
            let named = current.meteredNetworks.count == 1 ? current.meteredNetworks.keys.first.flatMap { input.networkNames[$0] } : nil
            let line = named.map { String(localized: "\(amount) on \($0), a metered network", comment: "Weekly digest; an amount such as “4.2 GB” and a network name") }
                ?? String(localized: "\(amount) on metered networks", comment: "Weekly digest; an amount such as “4.2 GB”")
            let fact = Fact(topic: .metered, score: Base.metered + min(16, Double(bytes) / 1e9 * 2), problem: false, line: line,
                            detail: String(localized: "Hotspots and other networks you pay for by the gigabyte. History shows which apps used it.", comment: "Weekly digest detail"),
                            days: current.meteredBytes.map { Double($0) / 1e6 }, tab: .history, value: Double(bytes))
            return compare(fact, Double(bytes), previous.map { Double($0.totalMetered) }, bytes: true)
        }

        // An outage on the provider's side this week that may qualify for a credit this month. Only Pro estimates it.
        func credit() -> Fact? {
            guard pro, let settings = input.credit, settings.provider != nil || settings.country != nil else { return nil }
            let month = CreditTally.month(of: week.end.addingTimeInterval(-1), calendar: calendar)
            let report: CreditReport
            if let dish = input.scopedStarlink {
                report = CreditReport.make(settings: settings, events: input.events, samples: input.samples, dish: dish,
                                           sleeps: input.sleeps, interval: month, now: now)
            } else {
                let tally = CreditTally.make(events: input.events, samples: input.samples, starlink: input.starlink, sleeps: input.sleeps,
                                             network: settings.networkName, from: month.start, to: month.end, now: now)
                report = CreditReport.make(settings: settings, tally: tally)
            }
            guard report.estimate.qualifies, report.estimate.qualifying.contains(where: { week.contains($0) }) else { return nil }
            let amount = report.estimate.amount.flatMap { amount in report.estimate.currency.map { CreditText.money(amount, $0) } }
            let line = amount.map { String(localized: "Your outages may qualify for about \($0) from \(report.providerName)", comment: "Weekly digest; an amount and a provider") }
                ?? String(localized: "Your outages may qualify for a credit from \(report.providerName)", comment: "Weekly digest; a provider")
            return Fact(topic: .credit, score: Base.credit, problem: true, line: line,
                        detail: String(localized: "History has the claim to send. Kilobat never sends it.", comment: "Weekly digest detail"), tab: .history, value: report.estimate.amount ?? 0)
        }

        // Speed tests under the plan on a network with one.
        func plan() -> Fact? {
            let tests = input.speedTests.filter { week.contains($0.result.date) && $0.networkChanged != true }
            let worst = Dictionary(grouping: tests, by: \.networkKey).compactMap { key, tests -> (String, Double, [Double], Double)? in
                guard tests.count >= 2, let plan = input.plans[key], plan > 0, let median = PlanSummary.median(tests.map(\.result.downloadMbps)) else { return nil }
                return (key, plan, tests.sorted { $0.result.date < $1.result.date }.map(\.result.downloadMbps), median)
            }.min { $0.3 / $0.1 < $1.3 / $1.1 }
            guard let (_, plan, series, median) = worst, median < plan * 0.75 else { return nil }
            let share = (median / plan).formatted(.percent.precision(.fractionLength(0)))
            return Fact(topic: .plan, score: Base.plan + min(15, (1 - median / plan) * 20), problem: true,
                        line: String(localized: "Speed tests got \(share) of your \(Self.mbps(plan)) plan", comment: "Weekly digest; a percentage and a speed such as “500 Mbps”"),
                        detail: String(localized: "The median download was \(Self.mbps(median)). Your provider report in Speed shows the month.", comment: "Weekly digest detail; a speed"),
                        days: series, tab: .speed, value: median / plan * 100)
        }

        func signIns() -> Fact? {
            let signIns = current.signIns
            guard signIns.count > 0, signIns.seconds >= 60 else { return nil }
            let line = signIns.count == 1 ? String(localized: "A Wi-Fi sign-in page held you up (\(minutes(signIns.seconds)))", comment: "Weekly digest: a hotel or café sign-in page; a length")
                : String(localized: "Wi-Fi sign-in pages held you up \(signIns.count) times (\(minutes(signIns.seconds)))", comment: "Weekly digest: hotel or café sign-in pages; a count and a length")
            return Fact(topic: .signIns, score: Base.signIns + min(10, signIns.seconds / 600), problem: false, line: line,
                        detail: String(localized: "Hotel and café Wi-Fi that wanted you to sign in again. It never counts as your provider’s outage.", comment: "Weekly digest detail"),
                        tab: .health, value: Double(signIns.count))
        }

        func trackers() -> Fact? {
            let count = current.trackers
            guard count >= 50 else { return nil }
            let fact = Fact(topic: .trackers, score: Base.trackers, problem: false,
                            line: String(localized: "\(count) trackers blocked in apps", comment: "Weekly digest; a count"),
                            detail: String(localized: "From the tracker list in Settings › Protection.", comment: "Weekly digest detail"),
                            days: current.protection.map { Double($0.trackers) }, tab: .connections, value: Double(count))
            return compare(fact, Double(count), previous.map { Double($0.trackers) })
        }

        static func ms(_ value: Double) -> String {
            Measurement(value: value, unit: UnitDuration.milliseconds).formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
        }
        static func mbps(_ value: Double) -> String {
            String(localized: "\(value.formatted(.number.precision(.fractionLength(0)))) Mbps", comment: "A speed in megabits per second")
        }
    }

    /// "half last week’s", "twice last week’s", "down from 6 last week", "up from 1.2 GB last week", "none the week before";
    /// nil when the change is too small to mention.
    public static func comparison(_ value: Double, _ before: Double, bytes: Bool = false) -> String? {
        func amount(_ x: Double) -> String { bytes ? TrafficFormat.bytes(UInt64(max(0, x))) : Int(x.rounded()).formatted() }
        guard value > 0 else { return nil }
        if before <= 0 { return String(localized: "none the week before", comment: "Weekly digest comparison") }
        // Small counts: 1 against 2 says little.
        if !bytes, max(value, before) < 2 { return nil }
        let ratio = value / before
        if bytes ? abs(ratio - 0.5) < 0.05 : value * 2 == before { return String(localized: "half last week’s", comment: "Weekly digest comparison") }
        if bytes ? abs(ratio - 2) < 0.1 : value == before * 2 { return String(localized: "twice last week’s", comment: "Weekly digest comparison") }
        if ratio <= 0.6 { return String(localized: "down from \(amount(before)) last week", comment: "Weekly digest comparison; a count or an amount") }
        if ratio >= 1.6 { return String(localized: "up from \(amount(before)) last week", comment: "Weekly digest comparison; a count or an amount") }
        return nil
    }

    /// Why a call froze, in a short phrase that reads after a count: "because of Dropbox", "on weak Wi-Fi".
    static func cause(of call: CallReport) -> String? {
        guard let cause = call.causes.first?.cause else { return call.strain.isEmpty ? nil : String(localized: "because the Mac was overloaded", comment: "Weekly digest: why calls froze") }
        switch cause.kind {
        case .app: return String(localized: "because of \(cause.app ?? String(localized: "another app"))", comment: "Weekly digest: why calls froze; an app such as Dropbox")
        case .otherDevice: return cause.device.map { String(localized: "because of \($0)", comment: "Weekly digest: why calls froze; a device such as Rita’s iPad") }
            ?? String(localized: "because of another device", comment: "Weekly digest: why calls froze")
        case .wifi: return cause.weakSignal == true ? String(localized: "on weak Wi-Fi", comment: "Weekly digest: why calls froze") : String(localized: "at the Wi-Fi or router", comment: "Weekly digest: why calls froze")
        case .airDrop: return String(localized: "because of AirDrop", comment: "Weekly digest: why calls froze")
        case .beyondRouter: return String(localized: "beyond your router", comment: "Weekly digest: why calls froze")
        case .starlink: return String(localized: "at the Starlink dish", comment: "Weekly digest: why calls froze")
        case .portal: return String(localized: "after a Wi-Fi sign-in ran out", comment: "Weekly digest: why calls froze")
        }
    }
}

// MARK: Command line

/// `kilobat week [--json] [--weeks-ago N]`.
public struct WeekOptions: Equatable, Sendable {
    public static let usage = "Use week [--weeks-ago 0…12] [--json]."
    public var json = false
    /// 0 is the week the latest digest covered.
    public var weeksAgo = 0
    public init(json: Bool = false, weeksAgo: Int = 0) { self.json = json; self.weeksAgo = weeksAgo }

    public static func parse(_ args: [String]) throws -> WeekOptions {
        var options = WeekOptions(), index = 1
        while index < args.count {
            switch args[index] {
            case "--json": options.json = true
            case "--weeks-ago":
                guard index + 1 < args.count, let value = Int(args[index + 1]), (0...12).contains(value) else { throw DiagnosticError("--weeks-ago takes 0 (the last full week) to 12.") }
                options.weeksAgo = value; index += 1
            default: throw DiagnosticError(usage)
            }
            index += 1
        }
        return options
    }

    /// The week to tell: ending at the start of the latest digest day, `weeksAgo` weeks back.
    public func week(schedule: DigestSchedule, now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        DigestSchedule.week(for: schedule.slot(atOrBefore: now, calendar: calendar), weeksAgo: weeksAgo, calendar: calendar)
    }
}
