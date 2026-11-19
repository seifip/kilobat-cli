import Foundation

/// How a trace probes: what it sends, how far it goes and how big each probe is. The defaults are what a plain
/// "Trace route" sends, apart from the 30 hops (traceroute's own default) where Kilobat used 12.
public struct TraceOptions: Codable, Sendable, Equatable, Hashable {
    /// UDP is traceroute's default. ICMP echo gets through where routers or the destination drop UDP. TCP isn't offered:
    /// macOS traceroute reads TCP replies through BPF, and /dev/bpf is root-only, so `-P tcp` fails ("pcap_activate()
    /// failed") without administrator rights.
    public enum Method: String, Codable, Sendable, CaseIterable { case udp, icmp }
    public var method: Method
    /// Highest TTL probed. traceroute stops by itself at the destination; Kilobat also stops after five silent hops in a row.
    public var maxHops: Int
    /// Bytes per probe; nil keeps traceroute's own (40 for UDP, 48 for ICMP).
    public var packetSize: Int?

    public static let hopRange = 1...64
    public static let sizeRange = 60...1500
    public static let standard = TraceOptions()
    /// What Kilobat's own background traces keep: 12 hops, as the service-speed evidence and the outage trace record.
    public static let background = TraceOptions(maxHops: 12)

    public init(method: Method = .udp, maxHops: Int = 30, packetSize: Int? = nil) {
        self.method = method
        self.maxHops = min(max(maxHops, Self.hopRange.lowerBound), Self.hopRange.upperBound)
        self.packetSize = packetSize.map { min(max($0, Self.sizeRange.lowerBound), Self.sizeRange.upperBound) }
    }

    /// `traceroute` arguments, the host and packet size last as it expects them.
    public func arguments(host: String, queries: Int) -> [String] {
        var arguments = ["-n"] + (method == .icmp ? ["-I"] : []) + ["-m", String(maxHops), "-q", String(min(max(queries, 1), 3)), "-w", "1", host]
        if let packetSize { arguments.append(String(packetSize)) }
        return arguments
    }

    /// "ICMP · 30 hops · 1,000 bytes", leaving out what's at its default.
    public var summary: String {
        var parts = [method == .icmp ? "ICMP" : "UDP"]
        parts.append(String(localized: "\(maxHops) hops", comment: "Trace options: the most hops a trace probes"))
        if let packetSize { parts.append(String(localized: "\(packetSize.formatted()) bytes", comment: "Trace options: probe size")) }
        return parts.joined(separator: " · ")
    }

    /// Parses `--protocol`, `--max-hops` and `--size` values; nil names the bad one.
    public static func parse(protocol method: String?, maxHops: String?, size: String?) -> Result<TraceOptions, TraceOptionError> {
        var options = TraceOptions()
        if let method {
            guard let value = Method(rawValue: method.lowercased()) else { return .failure(method.lowercased() == "tcp" ? .tcpNeedsRoot : .protocol) }
            options.method = value
        }
        if let maxHops {
            guard let value = Int(maxHops), hopRange.contains(value) else { return .failure(.maxHops) }
            options.maxHops = value
        }
        if let size {
            guard let value = Int(size), sizeRange.contains(value) else { return .failure(.size) }
            options.packetSize = value
        }
        return .success(options)
    }
}

public enum TraceOptionError: Error, Sendable, Equatable {
    case `protocol`, tcpNeedsRoot, maxHops, size
    public var message: String {
        switch self {
        case .protocol: String(localized: "Use udp or icmp for the protocol.")
        case .tcpNeedsRoot: String(localized: "TCP traces need administrator rights on macOS (traceroute reads TCP replies through /dev/bpf), so Kilobat doesn't offer them. Try icmp.")
        case .maxHops: String(localized: "Use 1 to 64 for the maximum hops.")
        case .size: String(localized: "Use 60 to 1,500 bytes for the probe size.")
        }
    }
}

/// One watched route: the same host traced every few seconds, one probe a hop, kept compactly. Each round lists, by TTL,
/// the reply time and which router answered (an index into `routers`), nil where the probe got no reply.
public struct WatchedRoute: Codable, Identifiable, Sendable, Equatable {
    public enum End: String, Codable, Sendable {
        /// Ran for the time chosen.
        case finished
        /// Stopped by the person.
        case stopped
        /// The Mac went to sleep.
        case slept
        /// The network or default route changed, so later rounds would describe another path.
        case networkChanged
        /// traceroute failed every round, such as an unknown host.
        case failed
        /// The app or command quit mid-watch; the rounds so far are kept.
        case quit
    }
    public struct Round: Codable, Sendable, Equatable {
        /// Seconds after the watch started.
        public let t: Double
        public let ms: [Double?]
        public let via: [Int?]
    }
    public var id = UUID()
    public let host: String
    /// What the person picked it as, such as "Counter-Strike 2 · Frankfurt"; nil for a typed host.
    public var label: String?
    /// The address traceroute resolved the host to; the destination is the hop where it answers.
    public var address: String?
    public let started: Date
    public var ended: Date?
    public var end: End?
    /// Seconds from the start of one round to the start of the next.
    public let interval: Double
    /// Seconds it was meant to run; nil for "until stopped".
    public let duration: Double?
    public let options: TraceOptions
    public private(set) var routers: [String] = []
    public private(set) var rounds: [Round] = []

    /// A watch at 2 s for four hours is 7,200 rounds; past that the oldest go, so a forgotten watch can't grow forever.
    public static let roundLimit = 7_200

    public init(id: UUID = UUID(), host: String, label: String? = nil, started: Date, interval: Double, duration: Double?, options: TraceOptions) {
        self.id = id; self.host = host; self.label = label; self.started = started; self.interval = interval; self.duration = duration; self.options = options
    }

    public var title: String { label ?? host }
    public var running: Bool { end == nil }
    public var lastDate: Date { rounds.last.map { started.addingTimeInterval($0.t) } ?? started }

    /// Adds one traceroute's hops. Probes are one a hop, so each TTL has one router and one time at most.
    public mutating func append(_ hops: [RouteHop], at date: Date) {
        guard !hops.isEmpty else { return }
        let depth = hops.map(\.ttl).max() ?? 0
        var ms = [Double?](repeating: nil, count: depth), via = [Int?](repeating: nil, count: depth)
        for hop in hops where hop.ttl >= 1 && hop.ttl <= depth {
            ms[hop.ttl - 1] = hop.samples.first.map { ($0 * 10).rounded() / 10 }
            if let address = hop.addresses.first { via[hop.ttl - 1] = router(address) }
        }
        rounds.append(Round(t: (date.timeIntervalSince(started) * 100).rounded() / 100, ms: ms, via: via))
        if rounds.count > Self.roundLimit { rounds.removeFirst(rounds.count - Self.roundLimit) }
    }
    private mutating func router(_ address: String) -> Int {
        if let index = routers.firstIndex(of: address) { return index }
        routers.append(address); return routers.count - 1
    }

    /// A round as traceroute hops again, for route history.
    public func hops(_ round: Round) -> [RouteHop] {
        (0..<max(round.ms.count, round.via.count)).map { index in
            let ms = index < round.ms.count ? round.ms[index] : nil
            let via = index < round.via.count ? round.via[index] : nil
            return RouteHop(ttl: index + 1, addresses: via.flatMap { $0 < routers.count ? [routers[$0]] : nil } ?? [], samples: ms.map { [$0] } ?? [], probes: 1)
        }
    }
    public func date(_ round: Round) -> Date { started.addingTimeInterval(round.t) }

    /// The destination's reply in a round: the hop where `address` answered, else nil (lost or never reached).
    public func destinationMs(_ round: Round) -> Double? {
        guard let address, let index = routers.firstIndex(of: address) else { return nil }
        guard let ttl = round.via.firstIndex(of: index) else { return nil }
        return ttl < round.ms.count ? round.ms[ttl] : nil
    }
    /// Whether the destination has answered in any round.
    public var destinationAnswers: Bool {
        guard let address, let index = routers.firstIndex(of: address) else { return false }
        return rounds.contains { $0.via.contains(index) }
    }

    /// One line per hop per round: `time,ttl,router,ms,lost`. Empty `ms` and `lost` 1 for no reply.
    public var csv: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = ["time,host,ttl,router,ms,lost"]
        for round in rounds {
            let time = formatter.string(from: date(round))
            for index in 0..<round.ms.count {
                let via = index < round.via.count ? round.via[index] : nil
                let address = via.flatMap { $0 < routers.count ? routers[$0] : nil } ?? ""
                let ms = round.ms[index].map { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? ""
                lines.append("\(time),\(host),\(index + 1),\(address),\(ms),\(round.ms[index] == nil ? 1 : 0)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// "Stopped: the Mac went to sleep", for the end of a watch.
    public var endLine: String? {
        switch end {
        case nil: nil
        case .finished: String(localized: "Finished", comment: "A route watch ran for its chosen time")
        case .stopped: String(localized: "Stopped", comment: "A route watch was stopped by the person")
        case .slept: String(localized: "Stopped: the Mac went to sleep", comment: "A route watch ended")
        case .networkChanged: String(localized: "Stopped: the network changed", comment: "A route watch ended")
        case .failed: String(localized: "Stopped: traceroute didn't answer", comment: "A route watch ended")
        case .quit: String(localized: "Stopped: Kilobat quit", comment: "A route watch ended")
        }
    }
}

/// When to notify during a watch: the destination's loss or latency over a trailing window. Off unless the person turns
/// it on for that watch.
public struct RouteAlertRule: Codable, Sendable, Equatable, Hashable {
    public var lossPercent: Double = 5
    public var latencyMs: Double = 150
    /// How long the trouble has to last, judged over this trailing window.
    public var sustainSeconds: Double = 30
    public init(lossPercent: Double = 5, latencyMs: Double = 150, sustainSeconds: Double = 30) {
        self.lossPercent = lossPercent; self.latencyMs = latencyMs; self.sustainSeconds = sustainSeconds
    }
    public static let standard = RouteAlertRule()

    public enum Trouble: Equatable, Sendable {
        case loss(percent: Double)
        case latency(ms: Double)
    }

    /// The trouble in the last `sustainSeconds` of `watch`, judged at the destination. Needs three rounds in the window
    /// and the window filled, and two lost probes for loss: with one probe a hop, a single lost probe is 17% of a 30 s
    /// window at 5 s and says little. Latency is the window's median, so it has to be high for half the window or more.
    public func trouble(in watch: WatchedRoute) -> Trouble? {
        guard watch.destinationAnswers, let last = watch.rounds.last, last.t >= sustainSeconds else { return nil }
        let window = watch.rounds.reversed().prefix { last.t - $0.t < sustainSeconds }
        guard window.count >= 3 else { return nil }
        let replies = window.compactMap { watch.destinationMs($0) }.sorted()
        let lost = window.count - replies.count
        let loss = Double(lost) / Double(window.count) * 100
        if lost >= 2, loss >= lossPercent { return .loss(percent: loss) }
        if !replies.isEmpty {
            let median = replies.count.isMultiple(of: 2) ? (replies[replies.count / 2 - 1] + replies[replies.count / 2]) / 2 : replies[replies.count / 2]
            if median >= latencyMs { return .latency(ms: median) }
        }
        return nil
    }

    /// The notification's text for `trouble` on `watch`.
    public static func message(_ trouble: Trouble, watch: WatchedRoute, history: RouteHistory) -> (title: String, body: String) {
        let seconds = Int(RouteAlertRule.standard.sustainSeconds)
        let detail: String
        switch trouble {
        case .loss(let percent):
            detail = String(localized: "\(Int(percent.rounded()))% of probes to \(watch.title) got no reply over the last \(seconds) seconds.", comment: "Route watch alert")
        case .latency(let ms):
            detail = String(localized: "\(watch.title) has answered in \(Int(ms.rounded())) ms or more for the last \(seconds) seconds.", comment: "Route watch alert")
        }
        let where_ = history.troubleTTL.map { String(localized: " Delay starts at hop \($0).", comment: "Route watch alert: appended to the detail") } ?? ""
        return (String(localized: "Trouble on the route to \(watch.title)", comment: "Route watch alert title"), detail + where_)
    }
}

/// Decides when a watch's alert goes out: once when trouble starts, then not again for that watch until the trouble
/// has cleared for a whole window. The app's connection-alerts rate limit (one every 15 minutes) applies on top.
public struct RouteAlertLatch: Sendable, Equatable {
    public private(set) var alerted = false
    private var clearSince: Double?
    public init() {}
    /// Whether to notify now, given this round's trouble and its time in the watch.
    public mutating func update(_ trouble: RouteAlertRule.Trouble?, at t: Double, rule: RouteAlertRule) -> Bool {
        if trouble != nil {
            clearSince = nil
            if alerted { return false }
            alerted = true; return true
        }
        if alerted {
            let since = clearSince ?? t
            clearSince = since
            if t - since >= rule.sustainSeconds { alerted = false; clearSince = nil }
        }
        return false
    }
}
