import Foundation

/// One hop of one traceroute: the routers that answered at that distance and their reply times.
public struct RouteHop: Codable, Sendable, Equatable {
    public let ttl: Int
    /// Routers that answered, in order; several when traffic is balanced across paths.
    public var addresses: [String]
    public var samples: [Double]
    /// Probes sent: replies plus `*`.
    public var probes: Int
}

/// Traceroutes to one host over time, hop by hop, like mtr: replies, best, average, worst and last per hop,
/// and whether the routers at a hop changed between runs. A hop that ignores probes isn't losing packets
/// unless the loss carries on to the hops after it.
public struct RouteHistory: Codable, Sendable {
    public struct Hop: Codable, Sendable, Equatable {
        public let ttl: Int
        /// Routers seen at this hop, most often first.
        public let addresses: [String]
        public let replies: Int
        public let probes: Int
        public let bestMs: Double?
        public let averageMs: Double?
        public let worstMs: Double?
        /// The latest run's average at this hop; nil when it didn't answer then.
        public let lastMs: Double?
        /// Different routers answered at this hop in different runs.
        public let changed: Bool
        public var lossPercent: Double { probes == 0 ? 0 : Double(probes - replies) / Double(probes) * 100 }
    }
    public let host: String
    public let runs: Int
    public let first: Date?
    public let last: Date?
    public let hops: [Hop]
    /// Runs whose answering routers differ from the run before.
    public let pathChanges: Int
    /// Where the delay starts, in words.
    public let verdict: String

    public init(host: String, routes: [SavedRoute]) {
        let runs = routes.filter { $0.host == host }.sorted { $0.date < $1.date }
        let parsed = runs.map { RouteTrace.parse($0.output) }.filter { !$0.isEmpty }
        self.host = host; self.runs = parsed.count; first = runs.first?.date; last = runs.last?.date
        let ttls = Set(parsed.flatMap { $0.map(\.ttl) }).sorted()
        hops = ttls.map { ttl in
            let rows = parsed.compactMap { $0.first { $0.ttl == ttl } }
            let samples = rows.flatMap(\.samples)
            var counts: [String: Int] = [:]
            for address in rows.flatMap(\.addresses) { counts[address, default: 0] += 1 }
            let sets = Set(rows.map { Set($0.addresses) }.filter { !$0.isEmpty })
            let latest = parsed.last?.first { $0.ttl == ttl }
            return Hop(ttl: ttl, addresses: counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key),
                       replies: samples.count, probes: rows.reduce(0) { $0 + $1.probes },
                       bestMs: samples.min(), averageMs: samples.isEmpty ? nil : samples.reduce(0, +) / Double(samples.count), worstMs: samples.max(),
                       lastMs: latest.flatMap { $0.samples.isEmpty ? nil : $0.samples.reduce(0, +) / Double($0.samples.count) }, changed: sets.count > 1)
        }
        let paths = parsed.map { $0.map { Set($0.addresses) } }
        pathChanges = zip(paths, paths.dropFirst()).filter { $0 != $1 }.count
        verdict = Self.verdict(hops, runs: parsed.count)
    }

    /// The first hop where the average rises by 30 ms or more and stays up to the last hop that answers.
    static func verdict(_ hops: [Hop], runs: Int) -> String {
        let answering = hops.filter { $0.averageMs != nil }
        guard let end = answering.last, let endMs = end.averageMs else { return runs == 0 ? String(localized: "No saved traces to this host.") : String(localized: "No hop answered. Some networks block traceroute probes.") }
        var previous: Double?
        for hop in answering {
            guard let ms = hop.averageMs else { continue }
            if let before = previous, ms - before >= 30, endMs >= ms - 10 {
                let rise = String(format: "%.0f", ms - before)
                if hop.ttl == 1 { return String(localized: "Delay rises at the first hop, the router: +\(rise) ms over the hop before, and stays up to the last hop that answers.") }
                let address = hop.addresses.first ?? String(localized: "no reply")
                return String(localized: "Delay rises at hop \(hop.ttl) (\(address)): +\(rise) ms over the hop before, and stays up to the last hop that answers.")
            }
            previous = ms
        }
        let lossy = hops.filter { $0.lossPercent >= 20 && $0.ttl < end.ttl }
        if !lossy.isEmpty, end.lossPercent < 20 {
            return String(localized: "No hop adds lasting delay. Hops \(lossy.map { String($0.ttl) }.joined(separator: ", ")) skip some replies, but later hops answer, so that's the routers rate-limiting probes, not loss.")
        }
        if end.lossPercent >= 20 { return String(localized: "The last hop that answers missed \(String(format: "%.0f", end.lossPercent))% of probes. Loss that carries on to the end is real; check it with a few more traces.") }
        return String(localized: "No hop adds lasting delay along this route.")
    }

    /// A table for the terminal.
    public var text: String {
        let traces = first.map { String(localized: "\(runs) traces since \($0.formatted(date: .abbreviated, time: .shortened))") } ?? String(localized: "\(runs) traces")
        var lines = ["\(host) · " + traces + (pathChanges > 0 ? " · " + String(localized: "route changed \(pathChanges) times") : ""),
                     "Hop  Address            Loss   Best    Avg  Worst   Last"]
        func ms(_ value: Double?) -> String { value.map { String(format: "%5.0f", $0) } ?? "    —" }
        for hop in hops {
            let address = (hop.addresses.first ?? "*") + (hop.addresses.count > 1 ? " +\(hop.addresses.count - 1)" : "")
            lines.append(String(format: "%3d  %@ %4.0f%% %@  %@  %@  %@%@", hop.ttl, address.padding(toLength: 18, withPad: " ", startingAt: 0), hop.lossPercent,
                                ms(hop.bestMs), ms(hop.averageMs), ms(hop.worstMs), ms(hop.lastMs), hop.changed ? "  changed" : ""))
        }
        lines.append(verdict)
        return lines.joined(separator: "\n")
    }

    /// Hosts with saved traces, the most recently traced first.
    public static func hosts(_ routes: [SavedRoute]) -> [String] {
        var seen = Set<String>()
        return routes.sorted { $0.date > $1.date }.map(\.host).filter { seen.insert($0).inserted }
    }
}

public enum RouteTrace {
    /// Parses `traceroute -n` output: " 3  10.0.0.1  10.1 ms  * 10.0.0.2  11.0 ms", with continuation lines
    /// (no hop number) for further routers at the same hop.
    public static func parse(_ output: String) -> [RouteHop] {
        var hops: [RouteHop] = []
        for line in output.split(separator: "\n") {
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let head = tokens.first else { continue }
            var rest = ArraySlice(tokens)
            if let ttl = Int(head), line.first?.isWhitespace == true || line.first?.isNumber == true, ttl > 0, ttl <= 64 {
                hops.append(RouteHop(ttl: ttl, addresses: [], samples: [], probes: 0)); rest = rest.dropFirst()
            } else if line.first?.isWhitespace != true || hops.isEmpty || AddressRange.parse(head) == nil && head != "*" { continue }
            var index = rest.startIndex
            while index < rest.endIndex {
                let token = rest[index]
                if token == "*" { hops[hops.count - 1].probes += 1 }
                else if let value = Double(token), index + 1 < rest.endIndex, rest[index + 1] == "ms" {
                    hops[hops.count - 1].samples.append(value); hops[hops.count - 1].probes += 1; index += 1
                } else if AddressRange.parse(token) != nil, !hops[hops.count - 1].addresses.contains(token) {
                    hops[hops.count - 1].addresses.append(token)
                }
                index += 1
            }
        }
        return hops
    }
}
