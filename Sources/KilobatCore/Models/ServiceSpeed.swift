import Foundation

/// One big download from one service: everything the Mac received from it while it kept moving, possibly over several
/// connections at once (Steam and App Store downloads open many), and how fast that was over the seconds it moved.
public struct ServiceTransfer: Codable, Sendable, Equatable {
    public let date: Date
    /// Seconds in which it moved at least `ServiceFlowTracker.Limits.activeRate`.
    public let seconds: Double
    public let bytes: UInt64
    public let mbps: Double
    /// The Mac's other downloads during those seconds, in Mbps: a busy line can't blame the route.
    public var otherMbps: Double? = nil
    /// The address that carried the most of it, for the route trace. A public server address.
    public var address: String? = nil
    public var host: String? = nil
    public var app: String? = nil
    /// The network its address belongs to (`NetworkOwners`).
    public var via: String? = nil
    /// From Test this service rather than the person's own download.
    public var tested: Bool? = nil
    public init(date: Date, seconds: Double, bytes: UInt64, mbps: Double, otherMbps: Double? = nil, address: String? = nil, host: String? = nil,
                app: String? = nil, via: String? = nil, tested: Bool? = nil) {
        self.date = date; self.seconds = seconds; self.bytes = bytes; self.mbps = mbps; self.otherMbps = otherMbps
        self.address = address; self.host = host; self.app = app; self.via = via; self.tested = tested
    }
}

/// Turns nettop's per-connection rows, one sample a second, into finished transfers per service. Passive: it reads byte
/// counters the traffic monitor already has, and sends nothing. Each connection is named once, when it first moves.
public struct ServiceFlowTracker: Sendable {
    public struct Limits: Sendable {
        /// A transfer counts from 5 MB: smaller ones end before TCP reaches full speed.
        public var minBytes: UInt64 = 5_000_000
        /// A second counts as moving from 32 KB (256 kbit/s); slower seconds are waits between requests.
        public var activeRate: Double = 32_000
        public var minSeconds: Double = 3
        /// Eight quiet seconds end a transfer.
        public var idle: TimeInterval = 8
        /// Downloads only: an upload or a call sends as much as it receives.
        public var downloadRatio: Double = 10
        public init() {}
    }
    struct Flow { var received: UInt64; var sent: UInt64; var attribution: ServiceAttribution?; var excluded = false; let seen: Date; let address: String }
    struct Burst {
        let key: String
        let start: Date
        var lastActive: Date
        var bytes: UInt64 = 0, sent: UInt64 = 0
        var seconds = 0.0, other = 0.0
        var addresses: [String: UInt64] = [:], hosts: [String: UInt64] = [:], apps: [String: UInt64] = [:], via: [String: UInt64] = [:]
    }
    public let limits: Limits
    var flows: [String: Flow] = [:]
    var bursts: [String: Burst] = [:]
    var last: Date?
    public init(limits: Limits = Limits()) { self.limits = limits }

    /// Remote address, port and protocol of `tcp4 192.168.1.20:5000<->140.82.121.4:443`.
    public static func endpoint(_ connection: String) -> (proto: String, address: String, port: String)? {
        guard let arrow = connection.range(of: "<->"), let space = connection.firstIndex(of: " ") else { return nil }
        let proto = String(connection[..<space])
        let remote = TrafficRoute.endpoint(connection[arrow.upperBound...], v6: proto.hasSuffix("6"))
        guard remote.address != "*" else { return nil }
        return (proto, remote.address, remote.port)
    }

    /// One sample. `identify` names a connection (nil: never measured, such as video or a call). Returns transfers that ended.
    public mutating func ingest(_ snapshot: TrafficSnapshot, identify: (ProcessTraffic, _ address: String, _ port: String, _ proto: String) -> ServiceAttribution?) -> [(key: String, transfer: ServiceTransfer)] {
        let now = snapshot.timestamp
        guard let previous = last, now > previous, now.timeIntervalSince(previous) <= 5 else {
            // The first sample, or one after a gap (sleep, a restarted monitor): counters become baselines.
            let ended = finish()
            flows = [:]
            for process in snapshot.processes { for connection in process.connections where connection.route == .internet {
                guard let remote = Self.endpoint(connection.id) else { continue }
                flows["\(process.pid)|\(connection.id)"] = Flow(received: connection.received, sent: connection.sent, attribution: nil, seen: now, address: remote.address)
            } }
            last = now
            return ended
        }
        let elapsed = now.timeIntervalSince(previous)
        last = now
        struct Share { var down: UInt64 = 0; var up: UInt64 = 0; var address: [String: UInt64] = [:]; var host: [String: UInt64] = [:]; var app: [String: UInt64] = [:]; var via: [String: UInt64] = [:] }
        var shares: [String: Share] = [:], total: UInt64 = 0, current: [String: Flow] = [:]
        for process in snapshot.processes {
            for connection in process.connections where connection.route == .internet {
                guard let remote = Self.endpoint(connection.id) else { continue }
                let id = "\(process.pid)|\(connection.id)"
                // A connection's first row is its baseline: it may have opened long before the monitor did.
                guard var flow = flows[id] else {
                    current[id] = Flow(received: connection.received, sent: connection.sent, attribution: nil, seen: now, address: remote.address)
                    continue
                }
                let down = connection.received >= flow.received ? connection.received - flow.received : 0
                let up = connection.sent >= flow.sent ? connection.sent - flow.sent : 0
                flow.received = connection.received; flow.sent = connection.sent
                total += down
                if down + up > 0 {
                    // A name that arrives a moment later (reverse DNS) still counts while the connection is young.
                    if !flow.excluded, flow.attribution == nil || (flow.attribution?.host == nil && now.timeIntervalSince(flow.seen) < 5) {
                        if let named = identify(process, remote.address, remote.port, remote.proto) { flow.attribution = named } else { flow.excluded = true }
                    }
                    if let named = flow.attribution, !flow.excluded {
                        var share = shares[named.key] ?? Share()
                        share.down += down; share.up += up
                        share.address[remote.address, default: 0] += down
                        if let host = named.host { share.host[host, default: 0] += down }
                        if let app = named.app { share.app[app, default: 0] += down }
                        if let via = named.via { share.via[via, default: 0] += down }
                        shares[named.key] = share
                    }
                }
                current[id] = flow
            }
        }
        flows = current
        for (key, share) in shares {
            if Double(share.down) >= limits.activeRate * elapsed {
                var burst = bursts[key] ?? Burst(key: key, start: previous, lastActive: now)
                burst.bytes += share.down; burst.seconds += elapsed; burst.other += Double(total - share.down); burst.lastActive = now
                burst.sent += share.up
                burst.addresses.merge(share.address, uniquingKeysWith: +); burst.hosts.merge(share.host, uniquingKeysWith: +)
                burst.apps.merge(share.app, uniquingKeysWith: +); burst.via.merge(share.via, uniquingKeysWith: +)
                bursts[key] = burst
            } else if bursts[key] != nil {
                bursts[key]?.sent += share.up
            }
        }
        var ended: [(String, ServiceTransfer)] = []
        for (key, burst) in bursts where now.timeIntervalSince(burst.lastActive) > limits.idle {
            bursts[key] = nil
            if let transfer = transfer(burst) { ended.append((key, transfer)) }
        }
        return ended.sorted { $0.1.date < $1.1.date }
    }

    /// Ends every transfer in progress: the network changed, the Mac is going to sleep, or a VPN came on.
    public mutating func finish() -> [(key: String, transfer: ServiceTransfer)] {
        let ended = bursts.values.compactMap { burst in transfer(burst).map { (burst.key, $0) } }.sorted { $0.1.date < $1.1.date }
        bursts = [:]; last = nil
        return ended
    }

    func transfer(_ burst: Burst) -> ServiceTransfer? {
        guard burst.bytes >= limits.minBytes, burst.seconds >= limits.minSeconds, Double(burst.bytes) >= Double(burst.sent) * limits.downloadRatio else { return nil }
        func top(_ counts: [String: UInt64]) -> String? { counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key }
        return ServiceTransfer(date: burst.start, seconds: burst.seconds, bytes: burst.bytes, mbps: Double(burst.bytes) * 8 / burst.seconds / 1_000_000,
                               otherMbps: burst.other * 8 / burst.seconds / 1_000_000, address: top(burst.addresses), host: top(burst.hosts), app: top(burst.apps), via: top(burst.via))
    }
}

/// A route trace to a slow service's server, with where the delay rises.
public struct ServiceRouteTrace: Codable, Sendable, Equatable {
    public let date: Date
    public let address: String
    public let verdict: String
    /// The hop where the delay rises and stays up, and by how much.
    public var hop: Int? = nil
    public var riseMs: Double? = nil
    public init(date: Date, address: String, verdict: String, hop: Int? = nil, riseMs: Double? = nil) {
        self.date = date; self.address = address; self.verdict = verdict; self.hop = hop; self.riseMs = riseMs
    }
    /// From `traceroute -n` output (three probes a hop), through route history's reading of it.
    public init(date: Date, address: String, output: String) {
        let history = RouteHistory(host: address, routes: [SavedRoute(date: date, host: address, output: output)])
        let rise = Self.rise(history.hops)
        self.init(date: date, address: address, verdict: history.verdict, hop: rise?.0, riseMs: rise?.1)
    }
    /// The same rule as `RouteHistory.verdict`: the first hop 30 ms or more above the one before that stays up to the end.
    static func rise(_ hops: [RouteHistory.Hop]) -> (Int, Double)? {
        let answering = hops.filter { $0.averageMs != nil }
        guard let end = answering.last?.averageMs else { return nil }
        var previous: Double?
        for hop in answering {
            guard let ms = hop.averageMs else { continue }
            if let before = previous, ms - before >= 30, end >= ms - 10 { return (hop.ttl, ms - before) }
            previous = ms
        }
        return nil
    }
}

/// Service speed's memory, in service-speed.json: each network's transfers by service for 30 days, and the latest route
/// trace to each slow service. Local only.
public struct ServiceSpeedLog: Codable, Sendable {
    public struct Network: Codable, Sendable {
        public var name: String
        public var services: [String: [ServiceTransfer]] = [:]
        public var traces: [String: ServiceRouteTrace]? = nil
        public init(name: String) { self.name = name }
    }
    public var networks: [String: Network] = [:]
    /// The network the Mac was on last.
    public var current: String?
    public init() {}

    public static let days = 30
    public static let perService = 300

    public mutating func add(_ transfer: ServiceTransfer, key: String, network: String, name: String, now: Date = Date()) {
        var entry = networks[network] ?? Network(name: name)
        entry.name = name
        let cutoff = now.addingTimeInterval(-Double(Self.days) * 86_400)
        entry.services[key] = Array(((entry.services[key] ?? []) + [transfer]).filter { $0.date >= cutoff }.sorted { $0.date < $1.date }.suffix(Self.perService))
        networks[network] = entry
    }
    public mutating func setTrace(_ trace: ServiceRouteTrace, key: String, network: String) {
        guard networks[network] != nil else { return }
        var traces = networks[network]?.traces ?? [:]
        traces[key] = trace
        networks[network]?.traces = traces
    }
    /// Drops transfers older than 30 days and networks left with none.
    public mutating func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(Self.days) * 86_400)
        var kept: [String: Network] = [:]
        for (key, entry) in networks {
            var entry = entry
            entry.services = entry.services.mapValues { $0.filter { $0.date >= cutoff } }.filter { !$0.value.isEmpty }
            entry.traces = entry.traces?.filter { $0.value.date >= cutoff }
            if !entry.services.isEmpty { kept[key] = entry }
        }
        networks = kept
    }
}

/// The rules for calling a service slow, in one place.
public enum ServiceSpeedRules {
    /// Slow: under a third of what the line carries.
    public static let slowFraction = 1.0 / 3
    /// Fast elsewhere: another service, or a speed test, at least three times as fast within an hour.
    public static let fastMultiple = 3.0
    public static let window: TimeInterval = 3_600
    /// A finding needs three slow transfers in the last day, each with something fast within the hour.
    public static let minimumSlow = 3
    public static let lookback: TimeInterval = 86_400
    /// …and most of the service's transfers that day slow.
    public static let slowShare = 2.0 / 3
    /// A transfer is crowded out, not slow, when other downloads took at least as much and together they used 60% of the line.
    public static let busyShare = 0.6
    /// Capacity: the latest speed test on this network in the last 30 days, or the fastest transfer, whichever is higher.
    public static let capacityDays = 30

    public static func busy(_ transfer: ServiceTransfer, capacity: Double) -> Bool {
        let other = transfer.otherMbps ?? 0
        return other >= transfer.mbps && transfer.mbps + other >= capacity * busyShare
    }
    public static func slow(_ transfer: ServiceTransfer, capacity: Double) -> Bool { transfer.mbps < capacity * slowFraction && !busy(transfer, capacity: capacity) }
}

/// When a service is slow: the hours of the day it's slow in most days, and fine outside them. Peering between providers
/// fills up at the same time every evening, so a fixed window is its signature.
public struct ServiceSpeedPattern: Codable, Sendable, Equatable {
    /// Local hours, start inclusive, end exclusive; the window may wrap midnight.
    public let startHour: Int
    public let endHour: Int
    public let slowInside: Int
    public let inside: Int
    public let slowOutside: Int
    public let outside: Int
    /// Different days with a slow transfer inside the window.
    public let days: Int

    /// Windows of 2 to 6 hours with 4+ transfers on 3+ days, 70%+ slow inside and 30% or less outside (4+ transfers).
    public static func find(_ transfers: [ServiceTransfer], capacity: Double, calendar: Calendar = .current) -> ServiceSpeedPattern? {
        let measured = transfers.filter { !ServiceSpeedRules.busy($0, capacity: capacity) }
        guard measured.count >= 8 else { return nil }
        var best: (ServiceSpeedPattern, Double)?
        for length in 2...6 {
            for start in 0..<24 {
                let hours = Set((0..<length).map { (start + $0) % 24 })
                let (inside, outside) = measured.reduce(into: ([ServiceTransfer](), [ServiceTransfer]())) { split, transfer in
                    if hours.contains(calendar.component(.hour, from: transfer.date)) { split.0.append(transfer) } else { split.1.append(transfer) }
                }
                let slowInside = inside.filter { $0.mbps < capacity * ServiceSpeedRules.slowFraction }
                let slowOutside = outside.filter { $0.mbps < capacity * ServiceSpeedRules.slowFraction }
                let days = Set(slowInside.map { calendar.startOfDay(for: $0.date) }).count
                guard inside.count >= 4, outside.count >= 4, days >= 3 else { continue }
                let shareIn = Double(slowInside.count) / Double(inside.count), shareOut = Double(slowOutside.count) / Double(outside.count)
                guard shareIn >= 0.7, shareOut <= 0.3 else { continue }
                let pattern = ServiceSpeedPattern(startHour: start, endHour: (start + length) % 24, slowInside: slowInside.count, inside: inside.count,
                                                  slowOutside: slowOutside.count, outside: outside.count, days: days)
                // The clearest split wins; between equals, the shorter window.
                if best == nil || shareIn - shareOut > best!.1 + 1e-9 { best = (pattern, shareIn - shareOut) }
            }
        }
        return best?.0
    }

    /// Mostly inside 5 pm to 1 am.
    public var evening: Bool {
        let length = (endHour - startHour + 24) % 24 == 0 ? 24 : (endHour - startHour + 24) % 24
        let middle = (startHour + length / 2) % 24
        return middle >= 17 || middle < 1
    }
    /// "7 PM–11 PM" in the reader's clock.
    public func hours(calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        func hour(_ h: Int) -> String { (calendar.date(byAdding: .hour, value: h, to: day) ?? day).formatted(.dateTime.hour()) }
        return "\(hour(startHour))–\(hour(endHour))"
    }
    public var sentence: String {
        evening
            ? String(localized: "Slow every evening \(hours()) on \(days) days, fine at other times: the classic sign of a congested link between your provider and theirs at the busiest hours.", comment: "Service speed: a time-of-day pattern; hours such as 7 PM–11 PM and a count of days")
            : String(localized: "Slow at \(hours()) on \(days) days, fine at other times: a link on the way that fills up at the same hours each day.", comment: "Service speed: a time-of-day pattern; hours such as 9 AM–12 PM and a count of days")
    }
}
