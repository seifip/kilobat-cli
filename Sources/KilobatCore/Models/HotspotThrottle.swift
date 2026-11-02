import Foundation

/// What kind of phone connection a network is, when it's one: the address an iPhone or Android hotspot hands out,
/// Bluetooth tethering, or simply a network macOS (or the person) marks metered.
public enum HotspotKind: String, Codable, Sendable {
    case iPhone, android, bluetooth, metered

    /// iPhone Personal Hotspot (Wi-Fi, USB or Bluetooth) always routes through 172.20.10.1; Android's tethering used
    /// 192.168.43.1 (Wi-Fi) and 192.168.42.129 (USB) for years, newer versions pick a random range. Anything else
    /// metered counts too: a hotspot macOS flags, or one the person marked.
    public static func classify(metered: Bool, gateway: String?, service: String?) -> HotspotKind? {
        let bluetooth = service?.localizedCaseInsensitiveContains("bluetooth") == true
        if gateway == "172.20.10.1" { return bluetooth ? .bluetooth : .iPhone }
        if gateway == "192.168.43.1" || gateway == "192.168.42.129" { return bluetooth ? .bluetooth : .android }
        guard metered else { return nil }
        return bluetooth ? .bluetooth : .metered
    }
    public var title: String {
        switch self {
        case .iPhone: String(localized: "iPhone hotspot", comment: "Hotspot throttling: the kind of network")
        case .android: String(localized: "Android hotspot", comment: "Hotspot throttling: the kind of network")
        case .bluetooth: String(localized: "Bluetooth tethering", comment: "Hotspot throttling: the kind of network")
        case .metered: String(localized: "Metered network", comment: "Hotspot throttling: the kind of network")
        }
    }
}

/// One measurement of how fast the hotspot carried data: a speed test, or one of this Mac's own big downloads (with
/// whatever else downloaded at the same time, since a cap holds the whole hotspot).
public struct HotspotMeasurement: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable { case speedTest, download }
    public let date: Date
    public let mbps: Double
    public let source: Source
    /// The service a download came from (`ServiceSpeedCatalog` key), for "from 3 different sources".
    public var service: String? = nil
    public init(date: Date, mbps: Double, source: Source, service: String? = nil) {
        self.date = date; self.mbps = mbps; self.source = source; self.service = service
    }
}

/// A latency reading on the network while idle: a speed test's baseline ping or one of Health's background checks.
public struct HotspotLatency: Codable, Sendable, Equatable {
    public let date: Date
    public let ms: Double
    public var jitterMs: Double? = nil
    public var lossPercent: Double? = nil
    public init(date: Date, ms: Double, jitterMs: Double? = nil, lossPercent: Double? = nil) {
        self.date = date; self.ms = ms; self.jitterMs = jitterMs; self.lossPercent = lossPercent
    }
}

/// One stretch of video from one service (YouTube, Netflix, Twitch, Disney+, Prime Video): how fast its connections
/// ran in the seconds they moved. Players fetch ahead as fast as the line allows, then wait, so on an open line the
/// busy seconds run near the line's speed; a video limit holds every one of them near the same rate.
public struct HotspotVideoSession: Codable, Sendable, Equatable {
    public let date: Date
    public let service: String
    /// Seconds in which it moved at least 32 KB.
    public let seconds: Double
    public let bytes: UInt64
    /// The 90th percentile of its busy seconds, in Mbps: what it reached when it fetched.
    public let peakMbps: Double
    public init(date: Date, service: String, seconds: Double, bytes: UInt64, peakMbps: Double) {
        self.date = date; self.service = service; self.seconds = seconds; self.bytes = bytes; self.peakMbps = peakMbps
    }
}

/// Turns nettop's per-connection rows into video sessions, passively, as `ServiceFlowTracker` does for downloads.
/// Only connections `identify` names as video count.
public struct HotspotVideoMeter: Sendable {
    public struct Limits: Sendable {
        public var activeRate: Double = 32_000
        /// Thirty quiet seconds end a session: players pause longer than downloads do.
        public var idle: TimeInterval = 30
        /// A session counts from a minute of busy seconds and 10 MB.
        public var minSeconds: Double = 60
        public var minBytes: UInt64 = 10_000_000
        public init() {}
    }
    struct Flow { var received: UInt64; var service: String?; var named = false }
    struct Session { let start: Date; var last: Date; var bytes: UInt64 = 0; var rates: [Double] = [] }
    public let limits: Limits
    var flows: [String: Flow] = [:]
    var sessions: [String: Session] = [:]
    var last: Date?
    public init(limits: Limits = Limits()) { self.limits = limits }

    /// One sample; `identify` returns the video service for a connection, or nil. Returns sessions that ended.
    public mutating func ingest(_ snapshot: TrafficSnapshot, identify: (ProcessTraffic, _ address: String) -> String?) -> [HotspotVideoSession] {
        let now = snapshot.timestamp
        guard let previous = last, now > previous, now.timeIntervalSince(previous) <= 5 else {
            let ended = finish()
            flows = [:]
            for process in snapshot.processes { for connection in process.connections where connection.route == .internet {
                flows["\(process.pid)|\(connection.id)"] = Flow(received: connection.received)
            } }
            last = now
            return ended
        }
        let elapsed = now.timeIntervalSince(previous)
        last = now
        var current: [String: Flow] = [:], down: [String: UInt64] = [:]
        for process in snapshot.processes {
            for connection in process.connections where connection.route == .internet {
                let id = "\(process.pid)|\(connection.id)"
                guard var flow = flows[id] else { current[id] = Flow(received: connection.received); continue }
                let delta = connection.received >= flow.received ? connection.received - flow.received : 0
                flow.received = connection.received
                if delta > 0, !flow.named, let remote = ServiceFlowTracker.endpoint(connection.id) {
                    flow.service = identify(process, remote.address); flow.named = true
                }
                if let service = flow.service { down[service, default: 0] += delta }
                current[id] = flow
            }
        }
        flows = current
        for (service, bytes) in down where Double(bytes) >= limits.activeRate * elapsed {
            var session = sessions[service] ?? Session(start: previous, last: now)
            session.bytes += bytes; session.last = now
            session.rates.append(Double(bytes) * 8 / elapsed / 1_000_000)
            sessions[service] = session
        }
        var ended: [HotspotVideoSession] = []
        for (service, session) in sessions where now.timeIntervalSince(session.last) > limits.idle {
            sessions[service] = nil
            if let made = Self.session(service, session, limits: limits) { ended.append(made) }
        }
        return ended.sorted { $0.date < $1.date }
    }

    /// Ends every session: the network changed or the monitor stopped.
    public mutating func finish() -> [HotspotVideoSession] {
        let ended = sessions.compactMap { Self.session($0.key, $0.value, limits: limits) }.sorted { $0.date < $1.date }
        sessions = [:]; last = nil
        return ended
    }

    static func session(_ service: String, _ session: Session, limits: Limits) -> HotspotVideoSession? {
        guard Double(session.rates.count) >= limits.minSeconds, session.bytes >= limits.minBytes else { return nil }
        return HotspotVideoSession(date: session.start, service: service, seconds: Double(session.rates.count), bytes: session.bytes,
                                   peakMbps: HotspotThrottleRules.percentile(session.rates, 0.9) ?? 0)
    }
}

/// Hotspot throttling's memory, in hotspot.json: per network, whether it was a phone hotspot, the video sessions on it
/// for 14 days, and its carrier (picked by the person, or matched from the public address when they asked). Local only.
public struct HotspotLog: Codable, Sendable {
    public struct Lookup: Codable, Sendable, Equatable {
        public let carrier: String?
        public let asn: Int?
        public let organization: String?
        public let country: String?
        public let date: Date
        public init(carrier: String?, asn: Int?, organization: String?, country: String?, date: Date) {
            self.carrier = carrier; self.asn = asn; self.organization = organization; self.country = country; self.date = date
        }
    }
    public struct Network: Codable, Sendable {
        public var name: String
        public var kind: HotspotKind? = nil
        public var lastSeen: Date? = nil
        public var video: [HotspotVideoSession] = []
        /// The person's pick; it wins over the lookup.
        public var carrier: String? = nil
        public var lookup: Lookup? = nil
        public init(name: String) { self.name = name }
    }
    public var networks: [String: Network] = [:]
    public var current: String?
    public init() {}

    public static let perNetwork = 200

    public mutating func seen(_ key: String, name: String, kind: HotspotKind, now: Date = Date()) {
        var entry = networks[key] ?? Network(name: name)
        entry.name = name; entry.kind = kind; entry.lastSeen = now
        networks[key] = entry
        current = key
    }
    public mutating func add(_ session: HotspotVideoSession, network key: String, name: String, now: Date = Date()) {
        var entry = networks[key] ?? Network(name: name)
        let cutoff = now.addingTimeInterval(-HotspotThrottleRules.lookback)
        entry.video = Array((entry.video + [session]).filter { $0.date >= cutoff }.sorted { $0.date < $1.date }.suffix(Self.perNetwork))
        networks[key] = entry
    }
    public mutating func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-HotspotThrottleRules.lookback)
        for key in networks.keys { networks[key]?.video.removeAll { $0.date < cutoff } }
        // A network unseen for 90 days, with no carrier picked, goes.
        networks = networks.filter { $0.value.carrier != nil || ($0.value.lastSeen ?? .distantPast) >= now.addingTimeInterval(-90 * 86_400) }
    }
}

/// The rules for calling it a cap, in one place. Deliberately strict: a carrier cap is a flat line, the same speed every
/// time; a weak signal or a busy cell wanders, and it's those Kilobat must not blame on the carrier.
public enum HotspotThrottleRules {
    /// Hotspot and tethering speed limits carriers publish, in Mbps: 128 kbps (AT&T, T-Mobile's 2G speeds), 512 and
    /// 600 kbps (Rogers, T-Mobile, Verizon), 1 (Verizon), 1.5 (Telstra, and DVD-quality video), 3, 4 and 6 (Verizon),
    /// 5, 10 and 15 (Visible). See hotspot-limits on the site for the sources.
    public static let caps: [Double] = [0.128, 0.512, 0.6, 1, 1.5, 3, 4, 5, 6, 10, 15]
    /// What a download measures under a cap of C: protocol overhead keeps it a little under C, a burst allowance at
    /// the start of a download can lift it a little over.
    public static let below = 0.80, above = 1.12
    /// Measurements from the last two weeks.
    public static let lookback: TimeInterval = 14 * 86_400
    /// At least four, from at least two sources (speed tests, or different services), on two occasions two hours apart.
    public static let minimumMeasurements = 4
    public static let minimumSources = 2
    public static let minimumSpan: TimeInterval = 2 * 3_600
    /// A new occasion starts after an hour without a measurement.
    public static let occasionGap: TimeInterval = 3_600
    /// Most measurements sit at the ceiling and none clearly above it.
    public static let atCeilingShare = 0.7
    /// Tightly: the measurements at the ceiling vary by at most 8% (coefficient of variation).
    public static let maximumVariation = 0.08
    /// The line's idle latency stays normal: median ping at most 150 ms, jitter at most 40 ms, loss under 3%.
    public static let maximumLatency = 150.0, maximumJitter = 40.0, maximumLoss = 3.0
    /// Latency readings count within 30 minutes of a measurement at the ceiling; at least two are needed.
    public static let latencyWindow: TimeInterval = 1_800
    public static let minimumLatency = 2
    /// Spread this wide (coefficient of variation) is the signal or a busy cell, never a cap.
    public static let wandering = 0.25
    /// A speed test and a download within a minute are the same event: the speed test's traffic.
    public static let sameEvent: TimeInterval = 60

    // Video: three sessions on two occasions, their busy seconds near 1.5 Mbps (within 12%), while two or more other
    // downloads or speed tests in the same two weeks ran at least 2.5 times as fast.
    public static let videoCap = 1.5
    public static let minimumVideo = 3
    public static let videoVariation = 0.12
    public static let videoFaster = 2.5
    public static let minimumFaster = 2

    public static func median(_ values: [Double]) -> Double? { percentile(values, 0.5) }
    public static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let position = fraction * Double(sorted.count - 1), low = Int(position.rounded(.down)), high = Int(position.rounded(.up))
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }
    /// Standard deviation over the mean.
    public static func variation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0 else { return 0 }
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count - 1)
        return variance.squareRoot() / mean
    }
    /// Times split where there's an hour or more between them.
    public static func occasions(_ dates: [Date]) -> Int {
        let sorted = dates.sorted()
        guard var previous = sorted.first else { return 0 }
        var count = 1
        for date in sorted.dropFirst() { if date.timeIntervalSince(previous) >= occasionGap { count += 1 }; previous = date }
        return count
    }
    /// The cap whose band holds the measurement.
    public static func cap(near mbps: Double) -> Double? { caps.first { mbps >= $0 * below && mbps <= $0 * above } }
}

/// Whether this hotspot's speed looks capped by the carrier, the evidence and what to do. Built from service speed's
/// downloads, the speed tests, Health's pings and the video sessions; the app, the CLI and the MCP tool share it.
public struct HotspotThrottleReport: Codable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Not a phone hotspot or metered network: nothing to judge.
        case notHotspot
        /// Too few measurements, sources or occasions yet.
        case learning
        /// Speeds on this hotspot show no fixed limit.
        case noCap
        /// Every measurement topped out at one of the common hotspot limits.
        case cap
        /// Video was held near 1.5 Mbps while other downloads ran faster.
        case videoCap
    }
    public struct Carrier: Codable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let page: URL
        /// you: picked in Kilobat; lookup: matched from the public address's network.
        public let source: String
        /// MVNOs on the same network, whose addresses look the same.
        public let sharedWith: [String]
    }
    public let network: String
    public let networkName: String
    public let generated: Date
    public let kind: HotspotKind?
    public let state: State
    public let headline: String
    public let detail: String
    /// What to check or try, in order. Never how to hide hotspot use from the carrier.
    public let advice: [String]
    /// One line per measurement or check behind the verdict.
    public let evidence: [String]
    /// The common limit it matched, the median at the ceiling, and how tightly the measurements sat there.
    public let capMbps: Double?
    public let plateauMbps: Double?
    public let variationPercent: Double?
    public let latencyMs: Double?
    public let measurements: [HotspotMeasurement]
    public let atCeiling: Int
    public let occasions: Int
    public let videoSessions: [HotspotVideoSession]
    public let videoMbps: Double?
    public let otherMbps: Double?
    public let carrier: Carrier?
    /// The hub when the carrier isn't known: every carrier's page.
    public let carriersPage: URL
    public let note: String

    public static let note = String(localized: "Measured from this Mac: speed tests and its own downloads of 5 MB or more on this hotspot in the last 14 days, with Health’s pings for latency. A cap is called only when every measurement tops out at the same common limit on different occasions while latency stays normal. It can’t tell a hotspot cap from a plan that caps all data: check on the phone itself.", comment: "Hotspot throttling: how it's measured")

    public var headlineWithDetail: String { detail.isEmpty ? headline : headline + " " + detail }

    /// `transfers` are service speed's downloads on this network, by service key.
    public init(network: String, networkName: String, kind: HotspotKind?, transfers: [String: [ServiceTransfer]], speedTests: [SavedSpeedTest],
                latency: [HotspotLatency], video: [HotspotVideoSession], carrier: Carrier?, now: Date = Date()) {
        self.network = network; self.networkName = networkName; self.kind = kind; generated = now; self.carrier = carrier
        carriersPage = HotspotCarriers.hub; note = Self.note
        let cutoff = now.addingTimeInterval(-HotspotThrottleRules.lookback)
        let tests = speedTests.filter { $0.networkKey == network && $0.networkChanged != true && $0.result.date >= cutoff && $0.result.date <= now && $0.result.downloadMbps > 0 }
        var measured = tests.map { HotspotMeasurement(date: $0.result.date, mbps: $0.result.downloadMbps, source: .speedTest) }
        for (key, list) in transfers {
            for transfer in list where transfer.date >= cutoff && transfer.date <= now && transfer.tested != true {
                // The speed test's own traffic shows up as a download too.
                guard !tests.contains(where: { abs($0.result.date.timeIntervalSince(transfer.date)) <= HotspotThrottleRules.sameEvent }) else { continue }
                measured.append(HotspotMeasurement(date: transfer.date, mbps: transfer.mbps + (transfer.otherMbps ?? 0), source: .download, service: key))
            }
        }
        measured.sort { $0.date < $1.date }
        measurements = measured
        let readings = latency.filter { $0.date >= cutoff && $0.date <= now }
            + tests.compactMap { test in test.result.baseline.average.map { HotspotLatency(date: test.result.date, ms: $0, jitterMs: test.result.baseline.jitter, lossPercent: test.result.baseline.lossPercent) } }
        let sessions = video.filter { $0.date >= cutoff && $0.date <= now }
        videoSessions = sessions

        let verdict = Self.judge(kind: kind, measurements: measured, latency: readings, video: sessions, carrier: carrier)
        state = verdict.state; headline = verdict.headline; detail = verdict.detail; advice = verdict.advice; evidence = verdict.evidence
        capMbps = verdict.cap; plateauMbps = verdict.plateau; variationPercent = verdict.variation.map { $0 * 100 }
        latencyMs = verdict.latency; atCeiling = verdict.atCeiling; occasions = verdict.occasions
        videoMbps = verdict.video; otherMbps = verdict.other
    }

    struct Verdict {
        var state: State
        var headline: String
        var detail = ""
        var advice: [String] = []
        var evidence: [String] = []
        var cap: Double? = nil, plateau: Double? = nil, variation: Double? = nil, latency: Double? = nil
        var atCeiling = 0, occasions = 0
        var video: Double? = nil, other: Double? = nil
    }

    /// A plateau: the common limit whose band holds the most measurements, if it holds enough of them, tightly, with
    /// nothing clearly faster. Nil when there's no such limit.
    struct Plateau { let cap: Double; let at: [HotspotMeasurement]; let median: Double; let variation: Double }
    static func plateau(_ measured: [HotspotMeasurement]) -> Plateau? {
        var best: Plateau?
        for cap in HotspotThrottleRules.caps {
            let at = measured.filter { $0.mbps >= cap * HotspotThrottleRules.below && $0.mbps <= cap * HotspotThrottleRules.above }
            guard !at.isEmpty, let median = HotspotThrottleRules.median(at.map(\.mbps)) else { continue }
            let candidate = Plateau(cap: cap, at: at, median: median, variation: HotspotThrottleRules.variation(at.map(\.mbps)))
            // Bands overlap (5 and 6 Mbps): the one holding more wins, then the one the median sits closest under.
            func fit(_ p: Plateau) -> Double { abs(p.median / p.cap - 0.95) }
            if best == nil || at.count > best!.at.count || (at.count == best!.at.count && fit(candidate) < fit(best!)) { best = candidate }
        }
        return best
    }

    static func judge(kind: HotspotKind?, measurements measured: [HotspotMeasurement], latency: [HotspotLatency], video: [HotspotVideoSession], carrier: Carrier?) -> Verdict {
        guard let kind else {
            return Verdict(state: .notHotspot, headline: String(localized: "Not on a phone hotspot", comment: "Hotspot throttling: the current network isn't a hotspot"),
                           detail: String(localized: "Kilobat looks for a carrier’s hotspot cap only on phone hotspots and networks marked metered.", comment: "Hotspot throttling: when it applies"))
        }
        let whose = carrier.map { String(localized: "\($0.name)’s", comment: "Hotspot throttling: a carrier's name, possessive, e.g. T-Mobile’s") }
        let rules = HotspotThrottleRules.self
        let sources = Set(measured.map { $0.source == .speedTest ? "speedTest" : ($0.service ?? "other") }).count
        let occasions = rules.occasions(measured.map(\.date))
        let span = (measured.last?.date.timeIntervalSince(measured.first!.date)) ?? 0
        let values = measured.map(\.mbps)
        var verdict = Verdict(state: .learning, headline: "")
        verdict.occasions = occasions
        verdict.evidence = measured.suffix(12).map(Self.line)

        // Bluetooth tethering has its own ceiling, about 1 to 2 Mbps, whatever the carrier does.
        if kind == .bluetooth {
            verdict.state = .noCap
            verdict.headline = String(localized: "Bluetooth tethering is slow on its own", comment: "Hotspot throttling: Bluetooth tethering")
            verdict.detail = String(localized: "Bluetooth carries only a megabit or two, so a cap can’t be told apart from the link. Join the hotspot over Wi-Fi or USB to check.", comment: "Hotspot throttling: Bluetooth tethering detail")
            return verdict
        }

        // A flat line at a common limit.
        let plateau = measured.count >= rules.minimumMeasurements ? Self.plateau(measured) : nil
        if let plateau {
            let atDates = plateau.at.map(\.date)
            let atSources = Set(plateau.at.map { $0.source == .speedTest ? "speedTest" : ($0.service ?? "other") }).count
            let atOccasions = rules.occasions(atDates)
            let atSpan = (atDates.max()?.timeIntervalSince(atDates.min()!)) ?? 0
            let faster = measured.filter { $0.mbps > plateau.cap * rules.above }
            let nearby = latency.filter { reading in atDates.contains { abs($0.timeIntervalSince(reading.date)) <= rules.latencyWindow } }
            let ping = rules.median(nearby.map(\.ms)), jitter = rules.median(nearby.compactMap(\.jitterMs)), loss = rules.median(nearby.compactMap(\.lossPercent))
            let latencyNormal = nearby.count >= rules.minimumLatency && (ping ?? .infinity) <= rules.maximumLatency
                && (jitter ?? 0) <= rules.maximumJitter && (loss ?? 0) < rules.maximumLoss
            let enough = plateau.at.count >= rules.minimumMeasurements && atSources >= rules.minimumSources
                && atOccasions >= 2 && atSpan >= rules.minimumSpan
            let flat = faster.isEmpty && Double(plateau.at.count) >= Double(measured.count) * rules.atCeilingShare && plateau.variation <= rules.maximumVariation
            if enough && flat && latencyNormal {
                let near = Self.mbps(plateau.cap), days = Set(atDates.map { Calendar.current.startOfDay(for: $0) }).count
                verdict.state = .cap; verdict.cap = plateau.cap; verdict.plateau = plateau.median; verdict.variation = plateau.variation
                verdict.latency = ping; verdict.atCeiling = plateau.at.count
                verdict.headline = whose.map { String(localized: "Looks like \($0) hotspot cap: every download on this hotspot topped out near \(near).", comment: "Hotspot throttling finding: a carrier's name (possessive) and a speed such as 3 Mbps") }
                    ?? String(localized: "Looks like your carrier’s hotspot cap: every download on this hotspot topped out near \(near).", comment: "Hotspot throttling finding: a speed such as 3 Mbps")
                let spread = String(format: "%.0f%%", locale: Locale.current, max(1, plateau.variation * 100))
                let when = days > 1 ? String(localized: "on \(days) days", comment: "Hotspot throttling: measurements on several days")
                    : String(localized: "at \(atOccasions) different times", comment: "Hotspot throttling: measurements at several times of one day")
                verdict.detail = String(localized: "\(plateau.at.count) measurements \(when) stayed within about \(spread) of \(Self.mbps(plateau.median)), and the ping stayed normal (\(String(format: "%.0f", locale: Locale.current, ping ?? 0)) ms): a fixed limit rather than a weak signal or a busy cell. Likely, not certain: a plan can cap all its data, too.", comment: "Hotspot throttling finding detail: a count, when, a spread such as 4%, a speed, a ping")
                verdict.advice = Self.capAdvice(carrier)
                verdict.evidence = plateau.at.suffix(12).map(Self.line)
                    + [String(localized: "Ping near those times: \(String(format: "%.0f", locale: Locale.current, ping ?? 0)) ms, jitter \(String(format: "%.0f", locale: Locale.current, jitter ?? 0)) ms, loss \(String(format: "%.0f", locale: Locale.current, loss ?? 0))%.", comment: "Hotspot throttling evidence: idle latency near the measurements")]
                return verdict
            }
        }

        // Video held near 1.5 Mbps while other downloads ran faster.
        let videoAt = video.filter { $0.peakMbps >= rules.videoCap * rules.below && $0.peakMbps <= rules.videoCap * rules.above }
        if let videoMbps = rules.median(videoAt.map(\.peakMbps)), videoAt.count >= rules.minimumVideo, Double(videoAt.count) >= Double(video.count) * rules.atCeilingShare,
           rules.occasions(videoAt.map(\.date)) >= 2, rules.variation(videoAt.map(\.peakMbps)) <= rules.videoVariation {
            let faster = measured.filter { $0.mbps >= videoMbps * rules.videoFaster }
            if faster.count >= rules.minimumFaster, let other = rules.median(faster.map(\.mbps)) {
                let services = Array(Set(videoAt.map { ServiceSpeedCatalog.name(of: $0.service) })).sorted()
                verdict.state = .videoCap; verdict.video = videoMbps; verdict.other = other; verdict.cap = rules.videoCap
                verdict.headline = whose.map { String(localized: "Looks like \($0) video limit: video on this hotspot topped out near \(Self.mbps(rules.videoCap)) while other downloads ran at \(Self.mbps(other)).", comment: "Hotspot throttling video finding: a carrier (possessive), a video speed, a speed for other downloads") }
                    ?? String(localized: "Looks like your carrier’s video limit: video on this hotspot topped out near \(Self.mbps(rules.videoCap)) while other downloads ran at \(Self.mbps(other)).", comment: "Hotspot throttling video finding: a video speed, a speed for other downloads")
                verdict.detail = String(localized: "\(videoAt.count) stretches of video from \(services.formatted(.list(type: .and))) never fetched faster than about \(Self.mbps(videoMbps)), the speed of DVD-quality video. Likely, not certain: a slow video server looks the same.", comment: "Hotspot throttling video finding detail: a count, services, a speed")
                verdict.advice = Self.videoAdvice(carrier)
                verdict.evidence = videoAt.suffix(8).map(Self.line) + faster.suffix(4).map(Self.line)
                return verdict
            }
        }

        // Not a cap: too little to tell, or speeds that wander or run past every common limit.
        let fastest = values.max() ?? 0
        if measured.count >= rules.minimumMeasurements, rules.variation(values) >= rules.wandering || fastest > (rules.caps.last ?? 10) * rules.above {
            verdict.state = .noCap
            verdict.headline = String(localized: "No sign of a hotspot cap", comment: "Hotspot throttling: speeds show no fixed limit")
            verdict.detail = fastest > (rules.caps.last ?? 10) * rules.above && rules.variation(values) < rules.wandering
                ? String(localized: "Downloads on this hotspot reached \(Self.mbps(fastest)), faster than any common hotspot limit.", comment: "Hotspot throttling: no cap, a speed")
                : String(localized: "Speeds on this hotspot ranged from \(Self.mbps(values.min() ?? 0)) to \(Self.mbps(fastest)). A cap is the same speed every time; this is the signal or a busy cell.", comment: "Hotspot throttling: no cap, speeds vary between two values")
            return verdict
        }
        verdict.state = .learning
        verdict.headline = String(localized: "Not enough to tell yet", comment: "Hotspot throttling: too few measurements")
        if measured.count < rules.minimumMeasurements || sources < rules.minimumSources || occasions < 2 || span < rules.minimumSpan {
            verdict.detail = String(localized: "Kilobat needs \(rules.minimumMeasurements) speed tests or big downloads from at least two sources, at different times, to tell a carrier’s cap from a weak signal. So far: \(measured.count).", comment: "Hotspot throttling: what's needed, and the count so far")
        } else {
            verdict.detail = String(localized: "Speeds here don’t sit at one common limit, or Kilobat has no normal ping to go with them, so it isn’t calling it a cap.", comment: "Hotspot throttling: measurements don't add up to a cap")
        }
        return verdict
    }

    static func capAdvice(_ carrier: Carrier?) -> [String] {
        [
            carrier.map { String(localized: "Check how much hotspot data is left in the \($0.name) app or account: once a plan’s hotspot allowance is used up, many carriers slow hotspot data to a set speed until the next bill.", comment: "Hotspot throttling advice; a carrier's name") }
                ?? String(localized: "Check how much hotspot data is left in your carrier’s app or account: once a plan’s hotspot allowance is used up, many carriers slow hotspot data to a set speed until the next bill.", comment: "Hotspot throttling advice"),
            String(localized: "Some plans cap hotspot speed all the time, or leave hotspot use out entirely.", comment: "Hotspot throttling advice"),
            String(localized: "Run a speed test in the phone’s own browser with the Mac disconnected. If the phone is much faster, the limit is on hotspot data; if it’s just as slow, it’s the plan or the signal.", comment: "Hotspot throttling advice"),
            String(localized: "If you rely on the hotspot, a plan with more hotspot data, a data SIM in a travel router, or another carrier avoids it.", comment: "Hotspot throttling advice"),
        ]
    }
    static func videoAdvice(_ carrier: Carrier?) -> [String] {
        [
            carrier.map { String(localized: "Many plans stream video at DVD quality, about 480p. Check the \($0.name) app or account for an HD video setting, or whether the plan includes it.", comment: "Hotspot throttling video advice; a carrier's name") }
                ?? String(localized: "Many plans stream video at DVD quality, about 480p. Check your carrier’s app or account for an HD video setting, or whether the plan includes it.", comment: "Hotspot throttling video advice"),
            String(localized: "Play the same video in the phone’s own app to compare: hotspot and phone video can have different limits.", comment: "Hotspot throttling video advice"),
            String(localized: "If you rely on it, a plan with HD video, or another carrier, avoids it.", comment: "Hotspot throttling video advice"),
        ]
    }

    static func line(_ m: HotspotMeasurement) -> String {
        let when = m.date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        switch m.source {
        case .speedTest: return String(localized: "\(when): speed test, \(mbps(m.mbps))", comment: "Hotspot throttling evidence: a time and a speed")
        case .download: return String(localized: "\(when): download from \(ServiceSpeedCatalog.name(of: m.service ?? ServiceSpeedCatalog.otherKey)), \(mbps(m.mbps))", comment: "Hotspot throttling evidence: a time, a service and a speed")
        }
    }
    static func line(_ v: HotspotVideoSession) -> String {
        let when = v.date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return String(localized: "\(when): \(ServiceSpeedCatalog.name(of: v.service)) video, up to \(mbps(v.peakMbps)) over \(Int(v.seconds / 60)) min", comment: "Hotspot throttling evidence: a time, a video service, its top speed and minutes")
    }

    public static func mbps(_ value: Double) -> String {
        value < 1 ? String(format: "%.0f kbps", locale: Locale.current, value * 1000) : value.truncatingRemainder(dividingBy: 1) == 0 && value < 100 ? String(format: "%.0f Mbps", locale: Locale.current, value) : String(format: value < 10 ? "%.1f Mbps" : "%.0f Mbps", locale: Locale.current, value)
    }

    /// Shown in Health: a cap or a video limit on this hotspot.
    public var showsFinding: Bool { state == .cap || state == .videoCap }

    /// The terminal's text.
    public var text: String {
        var lines = ["\(networkName)" + (kind.map { " · \($0.title)" } ?? "")]
        lines.append((showsFinding ? "✗ " : "") + headline)
        if !detail.isEmpty { lines.append("  " + detail) }
        if showsFinding {
            for item in evidence { lines.append("  · " + item) }
            for item in advice { lines.append("  → " + item) }
        } else if state != .notHotspot, !measurements.isEmpty {
            for item in measurements.suffix(6) { lines.append("  · " + Self.line(item)) }
        }
        if state != .notHotspot {
            if let carrier {
                lines.append("Carrier: \(carrier.name) (\(carrier.source == "you" ? "your pick" : "from the public address’s network"))\(carrier.sharedWith.isEmpty ? "" : "; also used by " + carrier.sharedWith.compactMap { HotspotCarriers.carrier($0)?.name }.joined(separator: ", ")). Hotspot rules: \(carrier.page.absoluteString)")
            } else {
                lines.append("Carrier unknown: `kilobat hotspot --carrier <id>` or `--detect`. Every carrier’s hotspot rules: \(carriersPage.absoluteString)")
            }
            lines.append(note)
        }
        return lines.joined(separator: "\n")
    }

    /// `kilobat hotspot [--all] [--carrier <id>] [--detect] [--json]`, `kilobat hotspot carriers [--json]`.
    public struct Options: Equatable, Sendable {
        public var all = false
        public var json = false
        public var detect = false
        public var carriers = false
        public var carrier: String? = nil
        public init() {}
        public static let usage = "Usage: kilobat hotspot [--all] [--carrier <id>] [--detect] [--json] | carriers [--json]"
        public static func parse(_ args: [String]) throws -> Options {
            var options = Options(), index = args.first == "hotspot" ? 1 : 0
            if index < args.count, args[index] == "carriers" { options.carriers = true; index += 1 }
            while index < args.count {
                switch args[index] {
                case "--all": options.all = true; index += 1
                case "--json": options.json = true; index += 1
                case "--detect": options.detect = true; index += 1
                case "--carrier":
                    guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else { throw DiagnosticError(usage) }
                    options.carrier = args[index + 1]; index += 2
                default: throw DiagnosticError(usage)
                }
            }
            if options.carriers && (options.all || options.detect || options.carrier != nil) { throw DiagnosticError(usage) }
            if options.detect && options.carrier != nil { throw DiagnosticError(usage) }
            return options
        }
    }
}

public extension HotspotThrottleReport.Carrier {
    init(_ carrier: HotspotCarrier, source: String) {
        self.init(id: carrier.id, name: carrier.name, page: carrier.page, source: source, sharedWith: carrier.sharedWith)
    }
}

public extension HotspotLog {
    /// The carrier for a network: the person's pick, else what the lookup matched.
    func carrier(for key: String) -> HotspotThrottleReport.Carrier? {
        if let id = networks[key]?.carrier, let carrier = HotspotCarriers.carrier(id) { return .init(carrier, source: "you") }
        if let id = networks[key]?.lookup?.carrier, let carrier = HotspotCarriers.carrier(id) { return .init(carrier, source: "lookup") }
        return nil
    }
}

public extension HotspotLatency {
    /// Health's background check, when it pinged the internet.
    init?(_ sample: DiagnosticSnapshot) {
        guard let ms = sample.internet.average else { return nil }
        self.init(date: sample.date, ms: ms, jitterMs: sample.internet.jitter, lossPercent: sample.internet.lossPercent)
    }
}
