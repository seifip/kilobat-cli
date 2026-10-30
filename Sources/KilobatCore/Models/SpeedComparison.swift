import Foundation

/// Two saved speed tests side by side, with what was different between them and why that can change a result.
/// It lists recorded differences; it never says which result is right or what caused a change for certain.
public struct SpeedComparison: Codable, Sendable {
    public struct Side: Codable, Sendable {
        public let id: UUID
        public let date: Date
        public let network: String
        public let downloadMbps: Double
        public let uploadMbps: Double
        public let idleLatencyMs: Double?
    }
    public struct Difference: Codable, Sendable, Equatable {
        /// network, time, server, method, connection, vpn, band, signal, linkRate, otherTraffic, latency, dataLimit
        public let factor: String
        public let first: String
        public let second: String
        public let note: String
    }

    public let first: Side
    public let second: Side
    /// Percent change from the first test to the second; nil when the first is zero.
    public let downloadChangePercent: Double?
    public let uploadChangePercent: Double?
    public let differences: [Difference]
    /// Factors that weren't recorded for one of the tests, so they can't be compared.
    public let unknown: [String]
    public let summary: String

    /// `first` is the earlier test, whichever order they're passed in.
    public init(_ a: SavedSpeedTest, _ b: SavedSpeedTest) {
        let (one, two) = a.result.date <= b.result.date ? (a, b) : (b, a)
        let x = one.result, y = two.result, cx = x.context, cy = y.context
        func side(_ test: SavedSpeedTest) -> Side {
            Side(id: test.id, date: test.result.date, network: test.networkName, downloadMbps: test.result.downloadMbps, uploadMbps: test.result.uploadMbps, idleLatencyMs: test.result.baseline.average)
        }
        first = side(one); second = side(two)
        func change(_ from: Double, _ to: Double) -> Double? { from > 0 && from.isFinite && to.isFinite ? (to - from) / from * 100 : nil }
        downloadChangePercent = change(x.downloadMbps, y.downloadMbps); uploadChangePercent = change(x.uploadMbps, y.uploadMbps)

        var found: [Difference] = [], missing: [String] = []
        func add(_ factor: String, _ a: String, _ b: String, _ note: String) { found.append(Difference(factor: factor, first: a, second: b, note: note)) }

        if one.networkKey != two.networkKey || one.networkName != two.networkName {
            add("network", one.networkName, two.networkName, "Different networks: each has its own plan, router and path to the internet.")
        }
        let apart = y.date.timeIntervalSince(x.date), calendar = Calendar.current
        let hourA = calendar.component(.hour, from: x.date), hourB = calendar.component(.hour, from: y.date)
        let evening = { (hour: Int) in (18...23).contains(hour) }
        if evening(hourA) != evening(hourB) {
            add("time", Self.time(x.date), Self.time(y.date), "One test ran in the evening, when home connections and the provider’s network are often busiest.")
        } else if apart >= 6 * 3600 {
            add("time", Self.time(x.date), Self.time(y.date), "Hours apart: congestion upstream comes and goes over the day.")
        }
        if let a = x.server, let b = y.server, a != b, a != "Cloudflare", b != "Cloudflare" {
            add("server", a, b, "A different Cloudflare data center answered, so the path past your provider differed.")
        } else if x.server == nil || y.server == nil { missing.append("server") }
        let streamsA = x.streams ?? 1, streamsB = y.streams ?? 1
        if streamsA != streamsB {
            add("method", Self.streams(streamsA), Self.streams(streamsB), "Several connections at once fill a fast or distant link that one connection can’t, so the parallel test usually reads higher.")
        }
        if let cx, let cy {
            if cx.kind != cy.kind, let a = cx.kind, let b = cy.kind {
                add("connection", a, b, "Different links: Wi-Fi shares the air with nearby networks, Ethernet doesn’t, and a VPN adds its own route and server.")
            }
            if (cx.vpn != nil) != (cy.vpn != nil) || (cx.vpn != nil && cx.vpn != cy.vpn) {
                add("vpn", cx.vpn ?? "Off", cy.vpn ?? "Off", "Through a VPN, traffic goes to the VPN’s server first and is encrypted on the way, which changes both the route and the speed.")
            }
            if let a = cx.band, let b = cy.band, a != b {
                add("band", a, b, "2.4 GHz reaches further but is slower and more crowded; 5 and 6 GHz are faster at short range.")
            }
            if let a = cx.rssi, let b = cy.rssi, abs(a - b) >= 6 {
                add("signal", "\(a) dBm", "\(b) dBm", "A weaker signal lowers the Wi-Fi link rate and causes retries; 6 dB is about a quarter of the signal power.")
            }
            if let a = cx.transmitMbps, let b = cy.transmitMbps, max(a, b) > 0, abs(a - b) / max(a, b) >= 0.3 {
                add("linkRate", String(format: "%.0f Mbps", a), String(format: "%.0f Mbps", b), "The Wi-Fi link rate is the ceiling between the Mac and the router; real throughput is usually well under half of it.")
            }
            if let a = cx.otherBytes, let b = cy.otherBytes {
                let busy = { (bytes: Int, test: Int) in bytes >= 5_000_000 && Double(bytes) >= Double(test) * 0.1 }
                if busy(a, x.transferredBytes) != busy(b, y.transferredBytes) {
                    add("otherTraffic", TrafficFormat.bytes(UInt64(a)), TrafficFormat.bytes(UInt64(b)), "Other traffic on this Mac during a test competes with it. Other devices on the network compete too, and Kilobat can’t see them.")
                }
            } else { missing.append("other traffic") }
            if cx.kind == nil || cy.kind == nil { missing.append("connection") }
        } else { missing += ["connection", "VPN", "Wi-Fi band and signal", "other traffic"] }
        if let a = x.baseline.average, let b = y.baseline.average, abs(a - b) >= 20, max(a, b) >= min(a, b) * 1.5 {
            add("latency", String(format: "%.0f ms", a), String(format: "%.0f ms", b), "Higher idle latency means a longer or busier path, and a single connection speeds up more slowly over it.")
        }
        let capped = { (result: SpeedTestResult) in result.downloadSeconds < 7.5 }
        if capped(x) != capped(y) {
            add("dataLimit", capped(x) ? "Reached" : "Not reached", capped(y) ? "Reached" : "Not reached", "A test that hit its data limit before 8 seconds stopped early, so it may not have reached full speed.")
        }
        differences = found
        unknown = Array(NSOrderedSet(array: missing)) as? [String] ?? missing

        let headline = String(format: "Download %.1f → %.1f Mbps", x.downloadMbps, y.downloadMbps) + (downloadChangePercent.map { String(format: " (%+.0f%%)", $0) } ?? "")
            + String(format: ", upload %.1f → %.1f Mbps", x.uploadMbps, y.uploadMbps) + (uploadChangePercent.map { String(format: " (%+.0f%%)", $0) } ?? "") + "."
        let factors = Dictionary(uniqueKeysWithValues: [("network", "network"), ("time", "time of day"), ("server", "server"), ("method", "number of connections"), ("connection", "connection"),
                                                         ("vpn", "VPN"), ("band", "Wi-Fi band"), ("signal", "Wi-Fi signal"), ("linkRate", "Wi-Fi link rate"), ("otherTraffic", "other traffic on this Mac"),
                                                         ("latency", "idle latency"), ("dataLimit", "data limit")])
        if found.isEmpty {
            summary = headline + " Nothing Kilobat records differed between them" + (unknown.isEmpty ? "" : " (not recorded: \(unknown.joined(separator: ", ")))")
                + ", so the difference is likely the connection itself at the time, or something Kilobat can’t see, such as other devices on the network."
        } else {
            summary = headline + " What differed: " + found.map { factors[$0.factor] ?? $0.factor }.joined(separator: ", ") + "."
        }
    }

    static func time(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
    static func streams(_ count: Int) -> String { count == 1 ? "1 connection" : "\(count) connections" }

    /// The two tests to compare when none are named: the newest and the one before it.
    public static func latestPair(_ tests: [SavedSpeedTest]) -> (SavedSpeedTest, SavedSpeedTest)? {
        let sorted = tests.sorted { $0.result.date > $1.result.date }
        return sorted.count >= 2 ? (sorted[1], sorted[0]) : nil
    }

    /// A test by its id, an id prefix, or its place counting back from the newest (1 is the newest).
    public static func find(_ key: String, in tests: [SavedSpeedTest]) -> SavedSpeedTest? {
        let sorted = tests.sorted { $0.result.date > $1.result.date }
        if let index = Int(key), (1...sorted.count).contains(index) { return sorted[index - 1] }
        let lower = key.lowercased()
        let matches = sorted.filter { $0.id.uuidString.lowercased().hasPrefix(lower) }
        return lower.count >= 4 && matches.count == 1 ? matches[0] : nil
    }

    /// Plain text for the terminal.
    public var text: String {
        var lines = [summary]
        for difference in differences { lines.append("  \(difference.factor): \(difference.first) → \(difference.second). \(difference.note)") }
        if !unknown.isEmpty { lines.append("  Not recorded for both tests: \(unknown.joined(separator: ", ")).") }
        return lines.joined(separator: "\n")
    }
}
