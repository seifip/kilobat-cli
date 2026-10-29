import Foundation

/// The last five minutes of one app's rates, a sample a second.
public struct LiveSeries: Sendable, Equatable {
    public static let length = 300
    public private(set) var down: [Float] = []
    public private(set) var up: [Float] = []
    public init() {}
    mutating func append(down rate: Double, up upRate: Double) {
        down.append(Float(rate)); up.append(Float(upRate))
        if down.count > Self.length { down.removeFirst(down.count - Self.length); up.removeFirst(up.count - Self.length) }
    }
    /// Nothing moved for the whole window, so the app can be forgotten.
    var isIdle: Bool { down.count >= Self.length && !down.contains { $0 > 0 } && !up.contains { $0 > 0 } }
    /// The last `seconds` samples, oldest first, padded with zeros so a fresh app starts at the right edge.
    public func recent(_ seconds: Int) -> (down: [Float], up: [Float]) {
        let pad = max(0, seconds - down.count)
        return (Array(repeating: 0, count: pad) + down.suffix(seconds), Array(repeating: 0, count: pad) + up.suffix(seconds))
    }
    /// Adds another member's series sample by sample, aligned at the newest end.
    public static func sum(_ series: [LiveSeries]) -> LiveSeries {
        var total = LiveSeries()
        let count = series.map(\.down.count).max() ?? 0
        guard count > 0 else { return total }
        var down = [Float](repeating: 0, count: count), up = down
        for item in series {
            let offset = count - item.down.count
            for index in item.down.indices { down[offset + index] += item.down[index]; up[offset + index] += item.up[index] }
        }
        total.down = down; total.up = up
        return total
    }
}

public struct BandwidthBucket: Identifiable, Sendable, Equatable {
    public let start: Date
    public let seconds: Double
    public var received: UInt64
    public var sent: UInt64
    public var id: Date { start }
    public init(start: Date, seconds: Double, received: UInt64 = 0, sent: UInt64 = 0) {
        self.start = start; self.seconds = seconds; self.received = received; self.sent = sent
    }
}

public enum BandwidthRange: String, CaseIterable, Identifiable, Sendable {
    case live = "5 Minutes", hour = "Hour", day = "Day", week = "Week", month = "Month"
    public var id: String { rawValue }
    var component: Calendar.Component {
        switch self { case .live, .hour: .hour; case .day: .day; case .week: .weekOfYear; case .month: .month }
    }
    /// One bar per minute in an hour, per hour in a day, per six hours in a week, per day in a month.
    var bucketSeconds: Double {
        switch self { case .live: 5; case .hour: 60; case .day: 3_600; case .week: 21_600; case .month: 86_400 }
    }
}

public struct BandwidthPeriod: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let buckets: [BandwidthBucket]
    public var received: UInt64 { buckets.reduce(0) { $0 + $1.received } }
    public var sent: UInt64 { buckets.reduce(0) { $0 + $1.sent } }
    /// The busiest bucket as a rate, and when it started.
    public var peak: (rate: Double, at: Date)? {
        guard let top = buckets.max(by: { $0.received + $0.sent < $1.received + $1.sent }), top.received + top.sent > 0 else { return nil }
        return (Double(top.received + top.sent) / top.seconds, top.start)
    }

    /// One app's saved history, or every app's when `app` is nil, for the calendar period `offset` steps back.
    public static func history(_ usage: [UsageEntry], app: String?, range: BandwidthRange, offset: Int = 0,
                               now: Date = Date(), calendar: Calendar = .current) -> BandwidthPeriod {
        let anchor = calendar.date(byAdding: range.component, value: -offset, to: now) ?? now
        let interval = calendar.dateInterval(of: range.component, for: anchor) ?? DateInterval(start: anchor, duration: 3_600)
        let step = range.bucketSeconds
        var buckets: [BandwidthBucket] = []
        var cursor = interval.start
        while cursor < interval.end {
            // Daily bars follow the calendar so a DST change can't shift them off midnight.
            let next = range == .month ? calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(step) : cursor.addingTimeInterval(step)
            buckets.append(BandwidthBucket(start: cursor, seconds: next.timeIntervalSince(cursor)))
            cursor = next
        }
        for entry in usage where entry.date >= interval.start && entry.date < interval.end {
            let (received, sent): (UInt64, UInt64)
            if let app {
                let total = entry.apps[app] ?? 0
                guard total > 0 else { continue }
                let up = min(total, entry.estimatedSent[app] ?? 0)
                (received, sent) = (total - up, up)
            } else { (received, sent) = (entry.received, entry.sent) }
            guard let index = buckets.lastIndex(where: { $0.start <= entry.date }) else { continue }
            buckets[index].received += received; buckets[index].sent += sent
        }
        return BandwidthPeriod(start: interval.start, end: interval.end, buckets: buckets)
    }

    /// Moments in the period when the Mac moved to another network, with the network it joined.
    public func networkChanges(_ usage: [UsageEntry]) -> [(date: Date, key: String)] {
        var changes: [(Date, String)] = [], previous = usage.last(where: { $0.date < start })?.networkKey
        for entry in usage where entry.date >= start && entry.date < end {
            guard let key = entry.networkKey else { continue }
            if let previous, previous != key { changes.append((entry.date, key)) }
            previous = key
        }
        return changes.map { (date: $0.0, key: $0.1) }
    }

    /// The live window as five-second buckets, newest last.
    public static func live(_ series: LiveSeries, now: Date = Date()) -> BandwidthPeriod {
        let samples = series.recent(LiveSeries.length), step = Int(BandwidthRange.live.bucketSeconds)
        let start = now.addingTimeInterval(-Double(LiveSeries.length))
        let buckets = stride(from: 0, to: LiveSeries.length, by: step).map { index in
            BandwidthBucket(start: start.addingTimeInterval(Double(index)), seconds: Double(step),
                            received: UInt64(samples.down[index..<index + step].reduce(0, +)), sent: UInt64(samples.up[index..<index + step].reduce(0, +)))
        }
        return BandwidthPeriod(start: start, end: now, buckets: buckets)
    }
}

/// What a period means for one app, beyond its own chart: where the bytes went over, how it compares
/// with its usual, and its share of the whole Mac.
public struct BandwidthInsight: Sendable, Equatable {
    public struct Network: Sendable, Equatable { public let key: String; public let bytes: UInt64 }
    /// Bytes per network, largest first.
    public let networks: [Network]
    /// This period against the average of the previous four with any traffic; nil without enough history.
    public let comparedWithUsual: Double?
    /// The app's share of all traffic in the period, 0–1.
    public let share: Double?

    public static func make(_ usage: [UsageEntry], app: String, range: BandwidthRange, offset: Int = 0,
                            now: Date = Date(), calendar: Calendar = .current) -> BandwidthInsight {
        let period = BandwidthPeriod.history(usage, app: app, range: range, offset: offset, now: now, calendar: calendar)
        let total = period.received + period.sent
        var networks: [String: UInt64] = [:]
        for entry in usage where entry.date >= period.start && entry.date < period.end {
            if let bytes = entry.apps[app], bytes > 0 { networks[entry.networkKey ?? "unknown", default: 0] += bytes }
        }
        let earlier = (1...4).map { step -> UInt64 in
            let past = BandwidthPeriod.history(usage, app: app, range: range, offset: offset + step, now: now, calendar: calendar)
            return past.received + past.sent
        }.filter { $0 > 0 }
        let usual = earlier.isEmpty ? nil : Double(earlier.reduce(0, +)) / Double(earlier.count)
        let everything = BandwidthPeriod.history(usage, app: nil, range: range, offset: offset, now: now, calendar: calendar)
        let all = everything.received + everything.sent
        return BandwidthInsight(networks: networks.sorted { $0.value > $1.value }.map { Network(key: $0.key, bytes: $0.value) },
                                comparedWithUsual: usual.flatMap { $0 > 0 && total > 0 ? Double(total) / $0 : nil },
                                share: all > 0 && total > 0 ? min(1, Double(total) / Double(all)) : nil)
    }
}

extension UsageEntry {
    /// Bytes sent per app. History from before the split shares each app's bytes out by the period's overall ratio.
    public var estimatedSent: [String: UInt64] {
        if let appsSent { return appsSent }
        guard total > 0 else { return [:] }
        let share = Double(sent) / Double(total)
        return apps.mapValues { UInt64((Double($0) * share).rounded()) }
    }
}
