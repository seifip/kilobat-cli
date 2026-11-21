import Foundation

/// The link to one local device, from a ping a second: the middle round trip, how much it varies and what's lost.
public struct LinkReading: Equatable, Sendable {
    public enum Grade: String, Sendable, Comparable {
        case good, fair, poor
        public static func < (a: Self, b: Self) -> Bool { [Grade.good, .fair, .poor].firstIndex(of: a)! < [Grade.good, .fair, .poor].firstIndex(of: b)! }
    }
    public var count: Int
    public var median: Double?
    public var p95: Double?
    /// The average change from one reply to the next.
    public var jitter: Double?
    public var lossPercent: Double
    public var grade: Grade?

    /// "Good", "Fair", "Poor": for a device a few metres away, which should answer within a few milliseconds.
    public var gradeTitle: String? {
        switch grade {
        case .good: String(localized: "Good", comment: "Link quality to a local device")
        case .fair: String(localized: "Fair", comment: "Link quality to a local device")
        case .poor: String(localized: "Poor", comment: "Link quality to a local device")
        case nil: nil
        }
    }
}

public enum LinkQuality {
    /// The window the panel reads, in seconds.
    public static let window: Double = 60
    /// The stretch an alert is judged on.
    public static let recent: Double = 15
    /// Fewer pings than this say nothing yet.
    public static let minimum = 8

    /// The reading over the pings from `since` seconds on.
    public static func reading(_ pings: [CallSamples.Ping], since: Double = -.infinity) -> LinkReading {
        let span = pings.filter { $0.at >= since }
        let times = span.compactMap(\.ms)
        let loss = span.isEmpty ? 0 : Double(span.count - times.count) / Double(span.count) * 100
        let sorted = times.sorted()
        func percentile(_ p: Double) -> Double? { sorted.isEmpty ? nil : sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))] }
        let jitter: Double? = times.count < 2 ? nil : zip(times, times.dropFirst()).map { abs($1 - $0) }.reduce(0, +) / Double(times.count - 1)
        var reading = LinkReading(count: span.count, median: percentile(0.5), p95: percentile(0.95), jitter: jitter, lossPercent: loss, grade: nil)
        reading.grade = span.count < minimum ? nil : grade(reading)
        return reading
    }

    /// A device on its own Wi-Fi a room away answers in a few milliseconds. Video and control links stutter past
    /// about 5% loss or 50 ms of jitter; past 20% or 150 ms they freeze or drop.
    public static func grade(_ reading: LinkReading) -> LinkReading.Grade {
        let median = reading.median ?? .infinity, jitter = reading.jitter ?? 0
        if reading.lossPercent >= 20 || median >= 150 || jitter >= 100 { return .poor }
        if reading.lossPercent >= 5 || median >= 40 || jitter >= 30 { return .fair }
        return .good
    }

    /// The last `recent` seconds are poor, when the minute before them wasn't: what an alert says.
    public static func degraded(_ pings: [CallSamples.Ping], now: Double) -> Bool {
        let last = reading(pings, since: now - recent)
        guard last.count >= minimum, last.grade == .poor else { return false }
        let before = reading(pings.filter { $0.at < now - recent }, since: now - recent - window)
        return before.grade != .poor
    }

    /// The pings as one bar a second for the panel's strip, oldest first, `seconds` long.
    public static func line(_ pings: [CallSamples.Ping], now: Double, seconds: Int = 60) -> [Double?] {
        var slots = [Double?](repeating: nil, count: seconds)
        for ping in pings {
            let index = Int((ping.at - (now - Double(seconds))).rounded(.down))
            guard slots.indices.contains(index) else { continue }
            if let ms = ping.ms { slots[index] = max(slots[index] ?? 0, ms) }
        }
        return slots
    }

    /// Why the link may be slow, the Wi-Fi channel's crowding: networks seen on the same or an overlapping channel.
    public static func crowding(channel: Int?, band: String?, networks: [NearbyNetwork]) -> Int? {
        guard let channel, let band, !networks.isEmpty else { return nil }
        let radius = band == "2.4 GHz" ? 4 : 1
        return networks.filter { $0.band == band && abs($0.channel - channel) < radius }.count
    }
    /// From how many networks around it a channel counts as crowded, for the pointer to Radar.
    public static let crowded = 4
}
