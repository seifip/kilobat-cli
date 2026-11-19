import Foundation

/// A stronger access point of the same network, heard while the Mac stayed where it was. "Clearly better" is the far
/// node rule (`StickyDetector.candidate` at `MeshNodes.keepMargin`): the current signal weaker than −65 dBm, the other
/// at least 12 dB stronger on a band this Mac can use, promising 1.5 times the link rate.
public struct IgnoredBetter: Codable, Sendable, Equatable {
    public var first: Date
    public var last: Date
    public let bssid: String
    public var rssi: Int
    public var betterRSSI: Int
    public let band: String
    public var difference: Int { betterRSSI - rssi }
    public var seconds: TimeInterval { last.timeIntervalSince(first) }
}

/// One stay on one access point: when it began and ended, its signal along the way, and how it ended.
public struct APVisit: Codable, Sendable, Equatable, Identifiable {
    public enum End: String, Codable, Sendable {
        /// macOS moved to another access point of the same network.
        case roam
        /// Left the network, or Wi-Fi went off.
        case left
        /// The readings stopped (sleep, Kilobat not running): the stay ended some time after the last reading.
        case gap
    }
    public var id: String { "\(bssid)@\(Int(start.timeIntervalSince1970))" }
    public let network: String
    public var ssid: String?
    public let bssid: String
    public var channel: Int
    public var band: String
    public let start: Date
    /// The last reading on it.
    public var end: Date
    public var firstRSSI: Int
    public var lastRSSI: Int
    public var weakestRSSI: Int
    public var readings: Int
    public var ignored: IgnoredBetter?
    /// Nil while the Mac is still on it.
    public var ended: End?
    /// Where it roamed to.
    public var next: String?
    public var dwell: TimeInterval { end.timeIntervalSince(start) }
}

/// Keeps the visits, fed with each node reading (`NodeWatch`). Pure, so the tests drive it with fixtures.
public struct RoamLog: Codable, Sendable, Equatable {
    public private(set) var visits: [APVisit] = []
    /// Kept this long, and at most this many visits.
    public static let keep: TimeInterval = 14 * 86_400
    public static let most = 2000
    public init(visits: [APVisit] = []) { self.visits = visits }

    public var open: APVisit? { visits.last.flatMap { $0.ended == nil ? $0 : nil } }

    /// One reading on `network`. `names` are the person's node names, by BSSID.
    public mutating func observe(_ reading: NodeReading, network: String, names: [String: String] = [:]) {
        if let last = visits.indices.last, visits[last].ended == nil, reading.date.timeIntervalSince(visits[last].end) > StickyDetector.gap {
            visits[last].ended = .gap
        }
        guard let current = reading.current else { close(.left); return }
        if let last = visits.indices.last, visits[last].ended == nil {
            if visits[last].network != network { close(.left) }
            else if visits[last].bssid != current.bssid {
                visits[last].next = current.bssid
                close(.roam)
            }
        }
        if let last = visits.indices.last, visits[last].ended == nil {
            var visit = visits[last]
            visit.end = reading.date; visit.lastRSSI = current.rssi; visit.weakestRSSI = min(visit.weakestRSSI, current.rssi); visit.readings += 1
            visit.channel = current.channel; visit.band = current.band
            if let ssid = reading.ssid { visit.ssid = ssid }
            visits[last] = visit
        } else {
            visits.append(APVisit(network: network, ssid: reading.ssid, bssid: current.bssid, channel: current.channel, band: current.band, start: reading.date, end: reading.date,
                                  firstRSSI: current.rssi, lastRSSI: current.rssi, weakestRSSI: current.rssi, readings: 1, ignored: nil, ended: nil, next: nil))
        }
        // A scan is the only evidence about the others; none this time says nothing.
        if !reading.scan.isEmpty, let found = StickyDetector.candidate(reading, names: names, margin: MeshNodes.keepMargin), let last = visits.indices.last {
            var ignored = visits[last].ignored ?? IgnoredBetter(first: reading.date, last: reading.date, bssid: found.radio.bssid, rssi: current.rssi, betterRSSI: found.radio.rssi, band: found.radio.band)
            ignored.last = reading.date
            // Keep the widest gap seen.
            if found.radio.rssi - current.rssi >= ignored.difference { ignored.rssi = current.rssi; ignored.betterRSSI = found.radio.rssi }
            visits[last].ignored = ignored
        }
        prune(now: reading.date)
    }
    /// Kilobat stopped looking (sleep, quitting): the open visit ends at its last reading.
    public mutating func interrupt() { close(.gap) }

    private mutating func close(_ end: APVisit.End) {
        guard let last = visits.indices.last, visits[last].ended == nil else { return }
        visits[last].ended = end
    }
    private mutating func prune(now: Date) {
        visits = Array(visits.filter { now.timeIntervalSince($0.end) < Self.keep }.suffix(Self.most))
    }
}

/// What the visits say, for the Wi-Fi nodes panel, Radar and the export.
public struct RoamSummary: Sendable, Equatable {
    public struct AccessPoint: Sendable, Equatable, Identifiable {
        public let bssid: String
        public var id: String { bssid }
        public let name: String?
        public let band: String
        public let channel: Int
        public let visits: Int
        public let dwell: TimeInterval
        /// The median signal when macOS roamed away from it.
        public let leftAt: Int?
    }
    public let since: Date
    public let visits: [APVisit]
    public let accessPoints: [AccessPoint]
    public let roams: Int
    /// Roams where the signal had fallen to −75 dBm or weaker first: macOS held on long.
    public let late: Int
    /// Stays shorter than a minute that ended in a roam: back-and-forth between two access points.
    public let brief: Int
    public let ignored: [APVisit]

    public static let lateAt = -75
    public static let briefUnder: TimeInterval = 60

    public init(_ log: RoamLog, network: String?, since: Date, names: [String: String] = [:]) {
        self.since = since
        let visits = log.visits.filter { ($0.network == network || network == nil) && $0.end >= since }
        self.visits = visits
        let roamed = visits.filter { $0.ended == .roam }
        roams = roamed.count
        late = roamed.filter { $0.lastRSSI <= Self.lateAt }.count
        brief = roamed.filter { $0.dwell < Self.briefUnder }.count
        ignored = visits.filter { $0.ignored != nil }
        accessPoints = Dictionary(grouping: visits, by: \.bssid).map { bssid, stays in
            let left = stays.filter { $0.ended == .roam }.map(\.lastRSSI).sorted()
            // An open stay counts up to its latest reading.
            let dwell = stays.reduce(0.0) { $0 + $1.dwell }
            return AccessPoint(bssid: bssid, name: names[bssid], band: stays.last?.band ?? "", channel: stays.last?.channel ?? 0, visits: stays.count, dwell: dwell,
                               leftAt: left.isEmpty ? nil : left[left.count / 2])
        }.sorted { $0.dwell != $1.dwell ? $0.dwell > $1.dwell : $0.bssid < $1.bssid }
    }

    public var isEmpty: Bool { visits.isEmpty }

    /// "6 roams today · 2 at a weak signal", for the panel's first line.
    public var headline: String {
        if roams == 0 { return String(localized: "No roams in the last 24 hours", comment: "Roam history: nothing moved") }
        var parts = [roams == 1 ? String(localized: "1 roam in the last 24 hours", comment: "Roam history") : String(localized: "\(roams) roams in the last 24 hours", comment: "Roam history; the argument is a count")]
        if late > 0 { parts.append(String(localized: "\(late) only once the signal was weak", comment: "Roam history: roams at −75 dBm or weaker; the argument is a count")) }
        if brief > 1 { parts.append(String(localized: "\(brief) back and forth", comment: "Roam history: stays under a minute; the argument is a count")) }
        return parts.joined(separator: " · ")
    }

    /// One sentence per stay where a clearly better access point was ignored, the worst first.
    public func ignoredLines(names: [String: String]) -> [String] {
        ignored.sorted { ($0.ignored?.difference ?? 0) > ($1.ignored?.difference ?? 0) }.prefix(3).compactMap { visit in
            guard let better = visit.ignored else { return nil }
            let here = names[visit.bssid] ?? Self.short(visit.bssid), there = names[better.bssid] ?? Self.short(better.bssid)
            return String(localized: "Stayed on \(here) at \(better.rssi) dBm while \(there) was \(better.difference) dB stronger, for \(Self.duration(max(better.seconds, 60))).",
                          comment: "Roam history: a better access point ignored; names, signal, difference and a duration")
        }
    }

    public static func short(_ bssid: String) -> String { String(localized: "Node \(String(bssid.suffix(5)))", comment: "An access point the user hasn't named; the argument is the end of its address") }
    public static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .short
        return formatter.string(from: max(60, seconds)) ?? "\(Int(seconds / 60)) min"
    }

    // MARK: Export

    /// One row per stay, for an IT desk: ISO 8601 times with the Mac's offset, signal in dBm, seconds as numbers.
    public func csv(names: [String: String]) -> String {
        let header = ["ssid", "access_point", "node_name", "band", "channel", "joined", "last_reading", "dwell_seconds", "signal_at_join_dbm", "signal_at_leave_dbm",
                      "weakest_dbm", "readings", "ended", "next_access_point", "better_access_point_heard", "better_signal_dbm", "better_by_db", "better_heard_seconds"]
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        format.timeZone = .current
        let rows = visits.map { visit -> [String] in
            let better = visit.ignored
            return [visit.ssid ?? "", visit.bssid, names[visit.bssid] ?? "", visit.band, String(visit.channel), format.string(from: visit.start), format.string(from: visit.end),
                    String(Int(visit.dwell.rounded())), String(visit.firstRSSI), String(visit.lastRSSI), String(visit.weakestRSSI), String(visit.readings),
                    visit.ended?.rawValue ?? "current", visit.next ?? "", better?.bssid ?? "", better.map { String($0.betterRSSI) } ?? "",
                    better.map { String($0.difference) } ?? "", better.map { String(Int($0.seconds.rounded())) } ?? ""]
        }
        return ([header] + rows).map { $0.map(Self.field).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }
    static func field(_ value: String) -> String {
        value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
    }

    /// A plain-English summary to paste into a ticket, whatever the app's language.
    public func text(names: [String: String], mac: String?, system: String) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        var lines = ["Wi-Fi roaming report from Kilobat", "Mac: \(mac ?? "unknown") · \(system)", "From \(format.string(from: since)) · readings every 12 to 60 seconds, so times are good to about a minute", ""]
        lines.append("Roams: \(roams) · at -75 dBm or weaker: \(late) · stays under a minute: \(brief) · stays where a clearly better access point was heard: \(ignored.count)")
        lines.append("")
        lines.append("Access points (longest stay first):")
        for point in accessPoints {
            lines.append("  \(point.bssid)\(names[point.bssid].map { " (\($0))" } ?? "") · \(point.band) ch \(point.channel) · \(point.visits) stay\(point.visits == 1 ? "" : "s") · \(Int((point.dwell / 60).rounded())) min" + (point.leftAt.map { " · median signal at roam \($0) dBm" } ?? ""))
        }
        lines.append("")
        lines.append("Stays:")
        for visit in visits {
            var line = "  \(format.string(from: visit.start)) \(visit.bssid) \(visit.band) ch \(visit.channel): \(Int(visit.dwell.rounded())) s, \(visit.firstRSSI) → \(visit.lastRSSI) dBm"
            switch visit.ended {
            case .roam?: line += ", roamed to \(visit.next ?? "another access point")"
            case .left?: line += ", left the network"
            case .gap?: line += ", readings stopped (sleep or Kilobat not running)"
            case nil: line += ", still connected"
            }
            if let better = visit.ignored { line += "; \(better.bssid) heard at \(better.betterRSSI) dBm (\(better.difference) dB stronger) for \(Int(better.seconds.rounded())) s" }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// `kilobat wifi roams [--hours 1…336] [--csv|--text]` and `kilobat wakes [--days 1…30]`.
public enum WiFiHistoryCommand: Equatable, Sendable {
    public enum Format: String, Sendable { case summary, csv, text }
    case roams(hours: Int, format: Format)
    case wakes(days: Int)

    public static let roamsUsage = "Use wifi roams [--hours 1…336] [--csv|--text] [--json]."
    public static let wakesUsage = "Use wakes [--days 1…30] [--json]."
    public static func parse(_ args: [String]) throws -> WiFiHistoryCommand {
        guard let first = args.first, first == "roams" || first == "wakes" else { throw DiagnosticError(roamsUsage) }
        let roams = first == "roams"
        var number = roams ? 24 : 7, format = Format.summary
        var rest = Array(args.dropFirst())
        while let option = rest.first {
            rest.removeFirst()
            switch option {
            case "--hours" where roams, "--days" where !roams:
                guard let text = rest.first, let value = Int(text), (1...(roams ? 336 : 30)).contains(value) else { throw DiagnosticError(roams ? roamsUsage : wakesUsage) }
                number = value; rest.removeFirst()
            case "--csv" where roams && format == .summary: format = .csv
            case "--text" where roams && format == .summary: format = .text
            default: throw DiagnosticError(roams ? roamsUsage : wakesUsage)
            }
        }
        return roams ? .roams(hours: number, format: format) : .wakes(days: number)
    }
}
