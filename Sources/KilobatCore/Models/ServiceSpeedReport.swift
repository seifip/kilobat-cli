import Foundation

/// How fast the services you download from are on one network, against what the line carries, and when one is clearly
/// slow while the rest is fast, what that means. Built from `ServiceSpeedLog`; the app, the CLI and the MCP tool share it.
public struct ServiceSpeedReport: Codable, Sendable {
    public struct Capacity: Codable, Sendable, Equatable {
        public let mbps: Double
        /// speedTest: the latest speed test on this network; transfer: the fastest download Kilobat saw here.
        public let source: String
        public let date: Date
    }
    public struct Row: Codable, Sendable, Identifiable {
        public var id: String { key }
        /// A service id (github), `net:<network>` when only the network is known, or other.
        public let key: String
        public let name: String
        /// service or network.
        public let kind: String
        /// The median of the last 30 days here.
        public let typicalMbps: Double
        /// The latest transfer, and when.
        public let latestMbps: Double
        public let latest: Date
        public let transfers: Int
        /// The typical speed as a share of the line's capacity.
        public let percentOfLine: Double?
        /// Of the last day's transfers, how many were slow.
        public let slowToday: Int
        public let today: Int
        /// fast, slow, mixed or unknown (no capacity to compare with).
        public let state: String
        public let pattern: ServiceSpeedPattern?
        /// Networks the transfers came through, most first.
        public let via: [String]
        /// Test this service exists for it.
        public let testable: Bool
    }
    public struct Finding: Codable, Sendable {
        public let key: String
        public let service: String
        /// route: between the provider and the service; service: its status page reports a problem.
        public let kind: String
        public let headline: String
        public let detail: String
        public let evidence: [String]
        public let advice: String
        public let slowMbps: Double
        public let elsewhereMbps: Double
        public let slowTransfers: Int
        public let since: Date
        public let latest: Date
        public var statusPage: URL? = nil
        public var statusIncident: String? = nil
        public var trace: ServiceRouteTrace? = nil
        public var pattern: ServiceSpeedPattern? = nil
        /// The address to trace, when there isn't a trace from today.
        public var traceAddress: String? = nil
    }
    public let network: String
    public let networkName: String
    public let generated: Date
    public let capacity: Capacity?
    public let rows: [Row]
    public let finding: Finding?
    /// What the numbers are, in one line, for the terminal and agents.
    public let note: String

    public static let note = String(localized: "Measured from this Mac’s own downloads of 5 MB or more, over the seconds they were moving, against the line’s capacity: the latest speed test on this network or the fastest download seen here. Video, music and calls are never counted: they move at the pace they play.", comment: "Service speed: how the numbers are measured")

    /// `statuses` are the latest status page answers by `ServiceCatalog` id.
    public init(log: ServiceSpeedLog, network: String, speedTests: [SavedSpeedTest], statuses: [String: ServiceStatus] = [:], now: Date = Date(), calendar: Calendar = .current) {
        self.network = network; generated = now
        let entry = log.networks[network]
        networkName = entry?.name ?? network
        let capacity = Self.capacity(entry, network: network, speedTests: speedTests, now: now)
        self.capacity = capacity
        let services = entry?.services ?? [:]
        let tests = speedTests.filter { $0.networkKey == network && $0.networkChanged != true }.map { ($0.result.date, $0.result.downloadMbps) }
        var finding: Finding?
        var rows: [Row] = []
        for (key, transfers) in services where key != ServiceSpeedCatalog.otherKey && !transfers.isEmpty {
            let sorted = transfers.sorted { $0.date < $1.date }
            let typical = Self.median(sorted.map(\.mbps)) ?? 0
            let recent = sorted.filter { now.timeIntervalSince($0.date) <= ServiceSpeedRules.lookback && $0.date <= now }
            let pattern = capacity.flatMap { ServiceSpeedPattern.find(sorted, capacity: $0.mbps, calendar: calendar) }
            let slowToday = capacity.map { c in recent.filter { ServiceSpeedRules.slow($0, capacity: c.mbps) }.count } ?? 0
            let state: String
            if let capacity {
                let slow = typical < capacity.mbps * ServiceSpeedRules.slowFraction
                let share = recent.isEmpty ? (slow ? 1 : 0) : Double(slowToday) / Double(recent.count)
                state = share >= ServiceSpeedRules.slowShare ? "slow" : share > 0 || slow ? "mixed" : "fast"
            } else { state = "unknown" }
            var via: [String: Int] = [:]
            for transfer in sorted { if let network = transfer.via { via[network, default: 0] += 1 } }
            rows.append(Row(key: key, name: ServiceSpeedCatalog.name(of: key), kind: key.hasPrefix("net:") ? "network" : "service",
                            typicalMbps: typical, latestMbps: sorted.last!.mbps, latest: sorted.last!.date, transfers: sorted.count,
                            percentOfLine: capacity.map { typical / $0.mbps * 100 }, slowToday: slowToday, today: recent.count, state: state, pattern: pattern,
                            via: via.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { ServiceSpeedCatalog.networks[$0.key] ?? $0.key },
                            testable: ServiceSpeedTarget.target(forKey: key) != nil))
            guard let capacity, let candidate = Self.finding(key: key, transfers: sorted, recent: recent, capacity: capacity.mbps, services: services, tests: tests,
                                                             log: log, network: network, speedTests: speedTests, statuses: statuses, pattern: pattern, now: now, calendar: calendar) else { continue }
            // The service with the most slow transfers leads.
            if finding == nil || candidate.slowTransfers > finding!.slowTransfers { finding = candidate }
        }
        self.finding = finding
        self.rows = rows.sorted { a, b in
            if (a.key == finding?.key) != (b.key == finding?.key) { return a.key == finding?.key }
            if (a.kind == "service") != (b.kind == "service") { return a.kind == "service" }
            return a.latest > b.latest
        }
        note = Self.note
    }

    /// Capacity on a network: the latest speed test in 30 days, or the fastest transfer seen, whichever is higher.
    static func capacity(_ entry: ServiceSpeedLog.Network?, network: String, speedTests: [SavedSpeedTest], now: Date) -> Capacity? {
        let cutoff = now.addingTimeInterval(-Double(ServiceSpeedRules.capacityDays) * 86_400)
        let test = speedTests.filter { $0.networkKey == network && $0.networkChanged != true && $0.result.date >= cutoff && $0.result.downloadMbps > 0 }
            .max { $0.result.date < $1.result.date }
        let best = entry?.services.values.joined().filter { $0.date >= cutoff }.max { $0.mbps < $1.mbps }
        switch (test, best) {
        case let (test?, best?) where best.mbps > test.result.downloadMbps: return Capacity(mbps: best.mbps, source: "transfer", date: best.date)
        case let (test?, _): return Capacity(mbps: test.result.downloadMbps, source: "speedTest", date: test.result.date)
        case let (nil, best?): return Capacity(mbps: best.mbps, source: "transfer", date: best.date)
        default: return nil
        }
    }

    // MARK: The finding

    static func finding(key: String, transfers: [ServiceTransfer], recent: [ServiceTransfer], capacity: Double, services: [String: [ServiceTransfer]],
                        tests: [(Date, Double)], log: ServiceSpeedLog, network: String, speedTests: [SavedSpeedTest], statuses: [String: ServiceStatus],
                        pattern: ServiceSpeedPattern?, now: Date, calendar: Calendar) -> Finding? {
        let slow = recent.filter { ServiceSpeedRules.slow($0, capacity: capacity) }
        guard slow.count >= ServiceSpeedRules.minimumSlow, Double(slow.count) >= Double(recent.count) * ServiceSpeedRules.slowShare else { return nil }
        // Each slow transfer needs proof the line was fine then: something else three times as fast within the hour.
        let others = services.filter { $0.key != key }.values.joined().map { ($0.date, $0.mbps) } + tests
        var elsewhere: [Double] = []
        let corroborated = slow.filter { transfer in
            let fast = others.filter { abs($0.0.timeIntervalSince(transfer.date)) <= ServiceSpeedRules.window && $0.1 >= transfer.mbps * ServiceSpeedRules.fastMultiple
                && $0.1 >= capacity * ServiceSpeedRules.slowFraction }.map(\.1)
            elsewhere += fast
            return !fast.isEmpty
        }
        guard corroborated.count >= ServiceSpeedRules.minimumSlow else { return nil }
        // Slow on every network it was seen on: the service or its server, not this provider's route.
        if slowEverywhere(key: key, except: network, log: log, speedTests: speedTests, now: now) { return nil }
        let name = ServiceSpeedCatalog.name(of: key)
        let slowMbps = median(corroborated.map(\.mbps)) ?? 0, fastMbps = median(elsewhere) ?? 0
        let first = corroborated.map(\.date).min()!, latest = corroborated.map(\.date).max()!
        let when = Self.when(corroborated.map(\.date), now: now, calendar: calendar)
        let status = ServiceSpeedCatalog.service(key)?.status.flatMap { statuses[$0] }.flatMap { $0.problem ? $0 : nil }
        let slowText = mbps(slowMbps), fastText = mbps(fastMbps)
        let count = corroborated.count
        var evidence: [String] = []
        let kind: String, headline: String, detail: String, advice: String
        if let status {
            kind = "service"
            headline = String(localized: "\(name) is having problems", comment: "Service speed finding: the service's status page reports a problem")
            detail = String(localized: "\(count) downloads from \(name) ran at about \(slowText) while the rest of the internet got \(fastText). \(name)’s status page reports a problem, so it’s likely them, not your provider or your Wi-Fi.", comment: "Service speed finding: a count, a service, two speeds")
            evidence.append(String(localized: "Status page: \(status.state.title)\(status.incident.map { ", " + $0 } ?? "").", comment: "Service speed finding: what the service's status page says"))
            advice = String(localized: "Wait for \(name) to fix it; the status page says when it’s resolved.", comment: "Service speed advice when the status page reports a problem")
        } else {
            kind = "route"
            headline = when.isEmpty
                ? String(localized: "Your provider’s route to \(name) is slow", comment: "Service speed finding title")
                : String(localized: "Your provider’s route to \(name) is slow \(when)", comment: "Service speed finding title, with tonight or today")
            detail = String(localized: "\(count) downloads from \(name) ran at about \(slowText) while other sites got \(fastText) within the same hour. The slowdown is between your provider and \(name), not your Wi-Fi or this Mac.", comment: "Service speed finding: a count, a service, two speeds")
            advice = String(localized: "Try a VPN, or another DNS such as 1.1.1.1 so \(name) picks another server; both take another path there. Tell your provider: the provider report includes this. Or try again later.", comment: "Service speed advice for a slow route")
        }
        // Peering congestion is the route's story; with the status page reporting a problem it would contradict it.
        if kind == "route", let pattern { evidence.append(pattern.sentence) }
        let trace = log.networks[network]?.traces?[key].flatMap { now.timeIntervalSince($0.date) < ServiceSpeedRules.lookback ? $0 : nil }
        if kind == "route", let trace { evidence.append(traceSentence(trace)) }
        let address = corroborated.last?.address
        return Finding(key: key, service: name, kind: kind, headline: headline, detail: detail, evidence: evidence, advice: advice,
                       slowMbps: slowMbps, elsewhereMbps: fastMbps, slowTransfers: count, since: first, latest: latest,
                       statusPage: status?.page, statusIncident: status?.incident, trace: trace, pattern: pattern,
                       traceAddress: kind == "route" && trace == nil ? address : nil)
    }

    /// True when the service was slow on every other network with three or more transfers of it, and there was one.
    static func slowEverywhere(key: String, except network: String, log: ServiceSpeedLog, speedTests: [SavedSpeedTest], now: Date) -> Bool {
        var judged = 0
        for (other, entry) in log.networks where other != network {
            guard let transfers = entry.services[key], transfers.count >= 3,
                  let capacity = capacity(entry, network: other, speedTests: speedTests, now: now) else { continue }
            let typical = median(transfers.map(\.mbps)) ?? 0
            guard typical < capacity.mbps * ServiceSpeedRules.slowFraction else { return false }
            judged += 1
        }
        return judged > 0
    }

    static func traceSentence(_ trace: ServiceRouteTrace) -> String {
        if let hop = trace.hop, let rise = trace.riseMs {
            return hop <= 1
                ? String(localized: "Route trace: the delay rises at your router (+\(String(format: "%.0f", rise)) ms).", comment: "Service speed evidence from a route trace")
                : String(localized: "Route trace: the delay rises by \(String(format: "%.0f", rise)) ms at hop \(hop), beyond your router, and stays up to \(trace.address).", comment: "Service speed evidence from a route trace: a latency rise, a hop number, the server address")
        }
        return String(localized: "Route trace to \(trace.address): \(trace.verdict)", comment: "Service speed evidence: a route trace's verdict")
    }

    /// "tonight" when every slow one was this evening, "today" when today, else nothing.
    static func when(_ dates: [Date], now: Date, calendar: Calendar = .current) -> String {
        guard dates.allSatisfy({ calendar.isDate($0, inSameDayAs: now) }) else { return "" }
        let evening = dates.allSatisfy { calendar.component(.hour, from: $0) >= 17 } && calendar.component(.hour, from: now) >= 17
        return evening ? String(localized: "tonight", comment: "Service speed finding title ending: slow tonight") : String(localized: "today", comment: "Service speed finding title ending: slow today")
    }

    // MARK: Numbers

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
    public static func mbps(_ value: Double) -> String { String(format: value < 10 ? "%.1f Mbps" : "%.0f Mbps", value) }

    /// One line for the provider report, when there's a route finding.
    public var providerLine: String? {
        guard let finding, finding.kind == "route" else { return nil }
        let pattern = finding.pattern.map { " " + $0.sentence } ?? ""
        let trace = finding.trace.map { " " + Self.traceSentence($0) } ?? ""
        return String(localized: "Downloads from \(finding.service) ran at about \(Self.mbps(finding.slowMbps)) (\(finding.slowTransfers) times since \(finding.since.formatted(.dateTime.weekday(.abbreviated).hour().minute()))) while other sites reached \(Self.mbps(finding.elsewhereMbps)) within the same hour.", comment: "Provider report: a slow route to one service, its speed, a count and when it began, and the speed elsewhere") + pattern + trace
    }

    /// The terminal's table.
    public var text: String {
        var lines = ["\(networkName) · " + (capacity.map { "line \(Self.mbps($0.mbps)) (\($0.source == "speedTest" ? "speed test" : "fastest download") \($0.date.formatted(date: .abbreviated, time: .shortened)))" } ?? "no speed test or big download here yet")]
        if let finding {
            lines.append("✗ \(finding.headline)")
            lines.append("  \(finding.detail)")
            for line in finding.evidence { lines.append("  · \(line)") }
            lines.append("  \(finding.advice)")
        }
        guard !rows.isEmpty else {
            lines.append("No big downloads measured on this network yet. Kilobat counts downloads of 5 MB or more while the app runs; `--test <service>` measures one now.")
            return lines.joined(separator: "\n")
        }
        lines.append("Service                 Typical      Latest        vs line  Downloads")
        for row in rows {
            let line = row.percentOfLine.map { String(format: "%5.0f%%", $0) } ?? "    —"
            let latest = Self.mbps(row.latestMbps).padding(toLength: 10, withPad: " ", startingAt: 0) + " " + row.latest.formatted(.dateTime.hour().minute())
            let mark = row.state == "slow" ? " ✗" : row.state == "mixed" ? " ~" : ""
            lines.append(row.name.padding(toLength: 22, withPad: " ", startingAt: 0) + "  " + Self.mbps(row.typicalMbps).padding(toLength: 11, withPad: " ", startingAt: 0)
                         + "  " + latest.padding(toLength: 16, withPad: " ", startingAt: 0) + line + "  \(row.transfers)" + mark)
            if let pattern = row.pattern { lines.append("    \(pattern.sentence)") }
        }
        lines.append(note)
        return lines.joined(separator: "\n")
    }

    /// `kilobat service-speed [--all] [--network <name>] [--test <service>] [--budget-mb N] [--json]`.
    public struct Options: Equatable, Sendable {
        public var all = false
        public var json = false
        public var test: String? = nil
        public var budgetMB = ServiceSpeedTarget.maximumBytes / 1_000_000
        public var list = false
        public init() {}
        public static let usage = "Usage: kilobat service-speed [--all] [--json] | --test <service> [--budget-mb 5…25] [--json] | --list"
        public static func parse(_ args: [String]) throws -> Options {
            var options = Options(), index = args.first == "service-speed" ? 1 : 0
            while index < args.count {
                switch args[index] {
                case "--all": options.all = true; index += 1
                case "--json": options.json = true; index += 1
                case "--list": options.list = true; index += 1
                case "--test":
                    guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else { throw DiagnosticError(usage) }
                    options.test = args[index + 1]; index += 2
                case "--budget-mb":
                    guard index + 1 < args.count, let value = Int(args[index + 1]), (5...25).contains(value) else { throw DiagnosticError(usage) }
                    options.budgetMB = value; index += 2
                default: throw DiagnosticError(usage)
                }
            }
            if options.test != nil && (options.all || options.list) { throw DiagnosticError(usage) }
            return options
        }
    }
}
