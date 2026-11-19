import Foundation

/// A route over time, hop by hop: what the per-hop timeline draws, read from a watch or from saved traces. Each row is
/// one TTL; each point one round's reply there (nil: no reply). Pure data, so the drawing only scales and paints.
public struct RouteTimeline: Sendable {
    public struct Point: Sendable, Equatable {
        public let date: Date
        public let ms: Double?
        /// The destination also missed this round, so a gap here may be real loss rather than a router ignoring probes.
        public let destinationLost: Bool
    }
    public struct Row: Sendable, Identifiable, Equatable {
        public var id: Int { ttl }
        public let ttl: Int
        /// Routers that answered here, most often first.
        public let routers: [String]
        public let points: [Point]
        public let bestMs: Double?
        public let medianMs: Double?
        public let worstMs: Double?
        public let lossPercent: Double
        public let isDestination: Bool
        public var replies: Int { points.filter { $0.ms != nil }.count }
    }
    /// One stretch of a row squeezed into one column of pixels: the band runs from `low` to `high`, the line through `mid`.
    public struct Bucket: Sendable, Equatable {
        public let start: Date
        public let end: Date
        public let low: Double?
        public let mid: Double?
        public let high: Double?
        public let lost: Int
        public let probes: Int
        /// Lost probes in rounds where the destination missed too.
        public let lostToEnd: Int
        /// Nothing was measured for a while before this stretch (saved traces hours apart, or between two watches), so
        /// the line shouldn't join it to the one before.
        public var afterGap = false
    }

    public let host: String
    public let start: Date
    public let end: Date
    public let rows: [Row]
    /// When a router new to some hop answered: the route moved.
    public let changes: [Date]
    /// The hop where lasting delay starts: over the whole timeline, or else over its worst stretch (`troubleSpan`).
    public let troubleTTL: Int?
    /// When delay came and went: the stretch where it was worst, judged by route history's rule on that stretch alone.
    public let troubleSpan: ClosedRange<Date>?
    public let verdict: String
    public let rounds: Int
    /// The top of every row's scale: the 95th percentile of all replies with headroom, so one spike doesn't flatten the rest.
    public let ceilingMs: Double

    public init(watch: WatchedRoute) {
        let rounds = watch.rounds.map { (watch.date($0), watch.hops($0), watch.destinationMs($0) == nil && watch.destinationAnswers) }
        self.init(host: watch.host, rounds: rounds, destination: watch.address, history: RouteHistory(watch: watch), changes: Self.changes(in: watch), end: watch.ended ?? watch.lastDate)
    }

    /// Saved traces to `host` as rounds: each trace's average per hop. Three probes a hop make a loss of one in three.
    public init(host: String, routes: [SavedRoute], watches: [WatchedRoute] = []) {
        let saved = routes.filter { $0.host == host }.map { ($0.date, RouteTrace.parse($0.output)) }.filter { !$0.1.isEmpty }
        let watched = watches.filter { $0.host == host }.flatMap { watch in watch.rounds.map { (watch.date($0), watch.hops($0)) } }
        let all = (saved + watched).sorted { $0.0 < $1.0 }
        let destination = watches.first { $0.host == host && $0.address != nil }?.address ?? (ExpertTools.isAddress(host) ? host : nil)
        let rounds = all.map { date, hops in
            (date, hops, destination.map { address in !hops.contains { $0.addresses.contains(address) && !$0.samples.isEmpty } } ?? false)
        }
        var seen: [Int: Set<String>] = [:], changes: [Date] = []
        for (index, round) in all.enumerated() {
            var moved = false
            for hop in round.1 {
                for address in hop.addresses where !(seen[hop.ttl]?.contains(address) ?? false) {
                    if index > 0 && seen[hop.ttl] != nil { moved = true }
                    seen[hop.ttl, default: []].insert(address)
                }
            }
            if moved { changes.append(round.0) }
        }
        self.init(host: host, rounds: rounds, destination: destination, history: RouteHistory(host: host, routes: routes, watches: watches), changes: changes, end: all.last?.0 ?? Date())
    }

    init(host: String, rounds: [(Date, [RouteHop], Bool)], destination: String?, history: RouteHistory, changes: [Date], end: Date) {
        self.host = host
        start = rounds.first?.0 ?? end
        self.end = max(end, start)
        self.rounds = rounds.count
        self.changes = changes
        if history.troubleTTL == nil, let worst = Self.worstStretch(host: host, rounds: rounds.map { ($0.0, $0.1) }) {
            troubleTTL = worst.history.troubleTTL
            troubleSpan = worst.span
            let from = worst.span.lowerBound.formatted(date: .omitted, time: .shortened), to = worst.span.upperBound.formatted(date: .omitted, time: .shortened)
            verdict = String(localized: "Between \(from) and \(to): \(worst.history.verdict)", comment: "Route timeline: delay that came and went; two times, then a sentence on where it started")
                + " " + String(localized: "Over the whole time: \(history.verdict)", comment: "Route timeline: the verdict over every round, after the worst stretch's")
        } else {
            troubleTTL = history.troubleTTL; troubleSpan = nil; verdict = history.verdict
        }
        let depth = rounds.map { $0.1.map(\.ttl).max() ?? 0 }.max() ?? 0
        var all: [Double] = []
        rows = depth == 0 ? [] : (1...depth).map { ttl in
            var counts: [String: Int] = [:]
            var probes = 0, replies = 0
            let points = rounds.map { date, hops, lost -> Point in
                let hop = hops.first { $0.ttl == ttl }
                for address in hop?.addresses ?? [] { counts[address, default: 0] += 1 }
                probes += hop?.probes ?? 1; replies += hop?.samples.count ?? 0
                let ms = hop.flatMap { $0.samples.isEmpty ? nil : $0.samples.reduce(0, +) / Double($0.samples.count) }
                return Point(date: date, ms: ms, destinationLost: lost)
            }
            let values = points.compactMap(\.ms).sorted()
            all += values
            let routers = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
            return Row(ttl: ttl, routers: routers, points: points, bestMs: values.first, medianMs: Self.percentile(values, 0.5), worstMs: values.last,
                       lossPercent: probes == 0 ? 0 : Double(probes - replies) / Double(probes) * 100,
                       isDestination: destination.map { routers.contains($0) } ?? false)
        }
        ceilingMs = max(20, (Self.percentile(all.sorted(), 0.95) ?? 20) * 1.25)
    }

    /// The stretch (an eighth of the rounds, at least 10, sliding by half) where the last answering hop was slowest and
    /// route history's rule finds a hop where lasting delay starts. Nil for fewer than 20 rounds.
    static func worstStretch(host: String, rounds: [(Date, [RouteHop])]) -> (span: ClosedRange<Date>, history: RouteHistory)? {
        guard rounds.count >= 20 else { return nil }
        let size = max(10, rounds.count / 8)
        let step = max(1, size / 2)
        let starts = Array(stride(from: 0, through: rounds.count - size, by: step))
        let windows = starts.map { start in RouteHistory(host: host, runs: Array(rounds[start..<(start + size)]), pathChanges: 0, watchedRuns: 0) }
        var best: (index: Int, score: Double)?
        for (index, history) in windows.enumerated() {
            guard history.troubleTTL != nil, let score = history.hops.last(where: { $0.averageMs != nil })?.averageMs else { continue }
            if best == nil || score > best!.score { best = (index, score) }
        }
        guard let best, let ttl = windows[best.index].troubleTTL else { return nil }
        // Widen to the neighbouring windows where the same hop is to blame, so the span covers the episode, not its peak.
        var low = best.index, high = best.index
        while low > 0, windows[low - 1].troubleTTL == ttl { low -= 1 }
        while high + 1 < windows.count, windows[high + 1].troubleTTL == ttl { high += 1 }
        let slice = Array(rounds[starts[low]..<(starts[high] + size)])
        guard let first = slice.first?.0, let last = slice.last?.0 else { return nil }
        let history = RouteHistory(host: host, runs: slice, pathChanges: 0, watchedRuns: 0)
        return (first...last, history.troubleTTL == nil ? windows[best.index] : history)
    }

    /// Rounds where a router answered at a hop for the first time after the first round: a new path, not a flip between
    /// two load-balanced routers already seen.
    public static func changes(in watch: WatchedRoute) -> [Date] {
        var seen: [Int: Set<Int>] = [:], changes: [Date] = []
        for (index, round) in watch.rounds.enumerated() {
            var moved = false
            for (ttl, via) in round.via.enumerated() {
                guard let via else { continue }
                if !(seen[ttl]?.contains(via) ?? false) {
                    if index > 0 && seen[ttl] != nil { moved = true }
                    seen[ttl, default: []].insert(via)
                }
            }
            if moved { changes.append(watch.date(round)) }
        }
        return changes
    }

    /// The row squeezed into `count` equal stretches of time, for drawing at any width without one shape per round.
    public func buckets(_ row: Row, count: Int) -> [Bucket] {
        let count = max(1, count), span = max(1, end.timeIntervalSince(start))
        var groups = [[Point]](repeating: [], count: count)
        for point in row.points {
            let index = min(count - 1, max(0, Int(point.date.timeIntervalSince(start) / span * Double(count))))
            groups[index].append(point)
        }
        // A gap is five times the usual spacing between rounds, and at least a minute.
        let spacing = zip(row.points, row.points.dropFirst()).map { $1.date.timeIntervalSince($0.date) }.sorted()
        let gap = max(60, 5 * (Self.percentile(spacing, 0.5) ?? 60))
        var previous: Date?
        return groups.enumerated().map { index, points in
            let values = points.compactMap(\.ms).sorted()
            let lost = points.filter { $0.ms == nil }
            var bucket = Bucket(start: start.addingTimeInterval(span * Double(index) / Double(count)), end: start.addingTimeInterval(span * Double(index + 1) / Double(count)),
                                low: values.first, mid: Self.percentile(values, 0.5), high: values.last,
                                lost: lost.count, probes: points.count, lostToEnd: lost.filter(\.destinationLost).count)
            if let first = points.first?.date {
                if let previous, first.timeIntervalSince(previous) > gap { bucket.afterGap = true }
                previous = points.last?.date
            }
            return bucket
        }
    }

    /// The round nearest `date`, for reading values under the pointer.
    public func nearest(_ date: Date) -> Int? {
        guard let first = rows.first, !first.points.isEmpty else { return nil }
        var low = 0, high = first.points.count - 1
        while low < high {
            let middle = (low + high) / 2
            if first.points[middle].date < date { low = middle + 1 } else { high = middle }
        }
        if low > 0, abs(first.points[low - 1].date.timeIntervalSince(date)) < abs(first.points[low].date.timeIntervalSince(date)) { return low - 1 }
        return low
    }

    /// What VoiceOver reads for a row: "Hop 3, 203.0.113.5: median 81 ms, best 79, worst 86, no loss. Delay starts here."
    public func summary(_ row: Row) -> String {
        let router = row.routers.first ?? String(localized: "no reply", comment: "A route hop that didn't answer")
        guard let median = row.medianMs else {
            return String(localized: "Hop \(row.ttl), \(router): no replies.", comment: "VoiceOver: one row of the route timeline")
        }
        var line = String(localized: "Hop \(row.ttl), \(router): median \(Self.ms(median)), best \(Self.ms(row.bestMs ?? median)), worst \(Self.ms(row.worstMs ?? median)), \(Self.loss(row.lossPercent)).",
                          comment: "VoiceOver: one row of the route timeline; latencies such as 12 ms and a loss such as “no loss”")
        if row.ttl == troubleTTL { line += " " + String(localized: "Delay starts here.", comment: "VoiceOver: the route timeline row where delay starts") }
        if row.isDestination { line += " " + String(localized: "The destination.", comment: "VoiceOver: the route timeline row of the destination") }
        return line
    }

    public static func ms(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0))) + " ms" }
    public static func loss(_ percent: Double) -> String {
        percent < 0.5 ? String(localized: "no loss", comment: "A route hop answered every probe")
            : String(localized: "\(percent.formatted(.number.precision(.fractionLength(0))))% loss", comment: "A route hop's share of probes without reply")
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let position = Double(sorted.count - 1) * p
        let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }
}
