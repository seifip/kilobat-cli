import Foundation
import IOKit

/// A report to hand an ISP, an IT desk or a friend: what this Mac measured on its current network, without the
/// network's name or any private address. Built from the health checks, outages and speed tests Kilobat recorded,
/// plus an optional check of one host. It says what was measured, never whose fault it is.
public struct SupportReport: Codable, Sendable {
    public struct Latency: Codable, Sendable {
        /// Checks in the window; each is a short ping burst to the router and to two internet targets.
        public let checks: Int
        public let routerMedianMs: Double?
        public let internetMedianMs: Double?
        public let internetP95Ms: Double?
        public let lossPercent: Double?
        public let dnsMedianMs: Double?
        /// Share of checks that were healthy, slow or poor.
        public let goodPercent: Double
        public let degradedPercent: Double
        public let poorPercent: Double
        /// Median internet latency per hour, oldest first, for the chart.
        public let hourly: [Hourly]
    }
    public struct Hourly: Codable, Sendable {
        public let hour: Date
        public let internetMs: Double?
        public let routerMs: Double?
        public let lossPercent: Double?
    }
    public struct Outage: Codable, Sendable {
        public let start: Date
        public let end: Date
        public var minutes: Double { end.timeIntervalSince(start) / 60 }
    }
    public struct Speed: Codable, Sendable {
        public let date: Date
        public let downloadMbps: Double
        public let uploadMbps: Double
        public let idleMs: Double?
        public let bufferbloat: String
    }
    public struct Check: Codable, Sendable {
        public let host: String
        public let ok: Bool
        public let verdict: String
        public let steps: [Step]
    }
    public struct Step: Codable, Sendable {
        public let layer: String
        public let status: String
        public let detail: String
    }

    public let created: Date
    public let hours: Int
    /// "MacBook Pro · macOS 27.2". No serial number or name.
    public let mac: String
    /// "Wi-Fi 5 GHz, channel 149, signal −54 dBm" or "Ethernet". Never the network's name.
    public let connection: String
    public let findings: [String]
    public let latency: Latency?
    public let outages: [Outage]
    public let speedTests: [Speed]
    public let planMbps: Double?
    public let check: Check?
    /// What was left out on purpose, said in the report so the reader knows it isn't missing by accident.
    public let leftOut: [String]

    public static let footer = "Measured with Kilobat · kilobat.app"

    /// Builds the report for the network the latest check ran on.
    public static func make(samples: [DiagnosticSnapshot], events: [NetworkEvent], speedTests: [SavedSpeedTest],
                            hours: Int, planMbps: Double? = nil, check: DoctorReport? = nil,
                            mac: String = SupportReport.macDescription(), now: Date = Date()) -> SupportReport {
        let since = now.addingTimeInterval(-Double(hours) * 3600)
        let latest = samples.last
        let key = latest?.networkKey, name = latest?.networkName
        let window = samples.filter { $0.date >= since && $0.networkKey == key }
        let outages = events
            .filter { $0.kind == "Unreachable" && $0.network == name && ($0.end ?? now) >= since }
            .map { Outage(start: max($0.start, since), end: min($0.end ?? now, now)) }
            .filter { $0.end > $0.start }
        let speeds = speedTests
            .filter { $0.result.date >= since && $0.networkKey == key }
            .suffix(10)
            .map { Speed(date: $0.result.date, downloadMbps: $0.result.downloadMbps, uploadMbps: $0.result.uploadMbps,
                         idleMs: $0.result.baseline.average, bufferbloat: $0.result.bufferbloat) }
        let latency = window.isEmpty ? nil : Self.latency(window)
        let plan = (planMbps ?? 0) > 0 ? planMbps : nil
        let doctor = check.map { report in
            Check(host: report.host, ok: report.ok, verdict: redact(report.verdict),
                  steps: report.steps.map { Step(layer: $0.layer, status: $0.status.rawValue, detail: redact($0.detail)) })
        }
        return SupportReport(created: now, hours: hours, mac: mac, connection: latest.map(connection) ?? "No checks recorded yet",
                             findings: findings(latency: latency, outages: outages, speeds: Array(speeds), plan: plan, check: doctor, hours: hours),
                             latency: latency, outages: outages, speedTests: Array(speeds), planMbps: plan, check: doctor,
                             leftOut: ["the network’s name", "every IP address on your network, including the router’s", "device names and hardware addresses",
                                       "which apps used the network"])
    }

    // MARK: Measurements

    static func latency(_ samples: [DiagnosticSnapshot]) -> Latency {
        let internet = samples.compactMap { $0.internet.average }, router = samples.compactMap { $0.router?.average }
        let loss = samples.compactMap { $0.internet.lossPercent }, dns = samples.compactMap { $0.dnsMilliseconds }
        let count = Double(samples.count)
        func share(_ health: ConnectionHealth) -> Double { Double(samples.filter { $0.health == health }.count) / count * 100 }
        let calendar = Calendar.current
        let hours = Dictionary(grouping: samples) { calendar.dateInterval(of: .hour, for: $0.date)?.start ?? $0.date }
        let hourly = hours.keys.sorted().map { hour in
            let group = hours[hour] ?? []
            return Hourly(hour: hour, internetMs: median(group.compactMap { $0.internet.average }),
                          routerMs: median(group.compactMap { $0.router?.average }),
                          lossPercent: mean(group.compactMap { $0.internet.lossPercent }))
        }
        return Latency(checks: samples.count, routerMedianMs: median(router), internetMedianMs: median(internet),
                       internetP95Ms: percentile(internet, 0.95), lossPercent: mean(loss), dnsMedianMs: median(dns),
                       goodPercent: share(.good), degradedPercent: share(.degraded), poorPercent: share(.poor), hourly: hourly)
    }

    /// Plain sentences, the most useful to a support agent first. Each says what was measured and where.
    static func findings(latency: Latency?, outages: [Outage], speeds: [Speed], plan: Double?, check: Check?, hours: Int) -> [String] {
        var lines: [String] = []
        let period = hours == 24 ? "the last 24 hours" : hours % 24 == 0 ? "the last \(hours / 24) days" : "the last \(hours) hours"
        if !outages.isEmpty {
            let total = outages.reduce(0) { $0 + $1.minutes }, longest = outages.max { $0.minutes < $1.minutes }!
            lines.append("The internet was unreachable \(outages.count == 1 ? "once" : "\(outages.count) times") in \(period), \(minutes(total)) in all; the longest lasted \(minutes(longest.minutes)) from \(time(longest.start)).")
        }
        if let latency, let internet = latency.internetMedianMs {
            if let router = latency.routerMedianMs, router < 15, internet > 80 || (latency.internetP95Ms ?? 0) > 200 {
                lines.append("The link to the router stayed fast (median \(ms(router))) while internet latency was high (median \(ms(internet)), 95th percentile \(ms(latency.internetP95Ms))). The delay starts beyond the router.")
            } else if let router = latency.routerMedianMs, router >= 15 {
                lines.append("The router itself answered slowly (median \(ms(router))), which points to Wi-Fi or the router before the internet connection. Internet latency was \(ms(internet)) (median).")
            } else {
                lines.append("Internet latency was \(ms(internet)) (median) over \(latency.checks) checks, \(ms(latency.internetP95Ms)) at the 95th percentile.")
            }
            if let loss = latency.lossPercent, loss >= 1 { lines.append(String(format: "On average %.1f%% of internet pings got no reply.", loss)) }
            if latency.poorPercent + latency.degradedPercent >= 20 {
                lines.append(String(format: "%.0f%% of checks were slow or poor.", latency.poorPercent + latency.degradedPercent))
            }
        }
        if !speeds.isEmpty {
            let down = median(speeds.map(\.downloadMbps)) ?? 0, up = median(speeds.map(\.uploadMbps)) ?? 0
            var line = "\(speeds.count) speed test\(speeds.count == 1 ? "" : "s"): median \(mbps(down)) down, \(mbps(up)) up"
            if let plan { line += String(format: ", %.0f%% of the %@ plan", down / plan * 100, mbps(plan)) }
            lines.append(line + ".")
        }
        if let check { lines.append("\(check.host): \(check.verdict)") }
        if lines.isEmpty { lines.append("Kilobat hasn’t recorded checks on this network in \(period) yet. Keep the app running, then make the report again.") }
        return lines
    }

    // MARK: Redaction

    /// Private and link-local addresses become words; public server addresses stay, since they name the server, not you.
    public static func redact(_ text: String) -> String {
        var result = text
        let patterns: [(String, String)] = [
            (#"\b(?:10|127)(?:\.\d{1,3}){3}\b"#, "a local address"),
            (#"\b192\.168(?:\.\d{1,3}){2}\b"#, "a local address"),
            (#"\b172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2}\b"#, "a local address"),
            (#"\b169\.254(?:\.\d{1,3}){2}\b"#, "a link-local address"),
            (#"\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])(?:\.\d{1,3}){2}\b"#, "a carrier or VPN address"),
            (#"\b(?:fe80|fd[0-9a-f]{2}|fc[0-9a-f]{2}):[0-9a-f:%\w]*"#, "a local address"),
            (#"\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b"#, "a hardware address"),
        ]
        for (pattern, word) in patterns {
            result = result.replacingOccurrences(of: pattern, with: word, options: [.regularExpression, .caseInsensitive])
        }
        return result
    }

    static func connection(_ sample: DiagnosticSnapshot) -> String {
        if let wired = sample.wiredInterface { return "Wired (\(wired))" }
        let radio = sample.radio
        guard radio.rssi != nil else { return sample.networkService ?? "Unknown connection" }
        return ["Wi-Fi" + (radio.band.map { " " + $0 } ?? ""), radio.channel.map { "channel \($0)" },
                radio.rssi.map { "signal \($0) dBm" }, radio.transmitMbps.map { String(format: "link %.0f Mbps", $0) }]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// "MacBook Air (13-inch, M4, 2025) · macOS 27.2": the marketing name from the device tree, never a serial number.
    public static func macDescription() -> String {
        var name = "Mac"
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        if entry != 0 {
            if let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data {
                let text = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
                if !text.isEmpty { name = text }
            }
            IOObjectRelease(entry)
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(name) · macOS \(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")
    }

    // MARK: Numbers

    static func median(_ values: [Double]) -> Double? { percentile(values, 0.5) }
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }
    static func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
    static func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "—" }
    static func mbps(_ value: Double) -> String { String(format: value < 10 ? "%.1f Mbps" : "%.0f Mbps", value) }
    static func minutes(_ value: Double) -> String {
        value < 1 ? "under a minute" : value < 90 ? String(format: "%.0f min", value) : String(format: "%.1f h", value / 60)
    }
    static func time(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
}
