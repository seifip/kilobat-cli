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
        public let downloadLoadedMs: Double?
        public let uploadLoadedMs: Double?
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
    public let firstCheck: Date?
    public let lastCheck: Date?
    public let placeURL: String?
    /// "MacBook Pro · macOS 27.2". No serial number or name.
    public let mac: String
    /// "Wi-Fi 5 GHz, channel 149, signal −54 dBm" or "Ethernet". Never the network's name.
    public let connection: String
    public var findings: [String]
    public let latency: Latency?
    public let outages: [Outage]
    public let speedTests: [Speed]
    public let planMbps: Double?
    /// The last 30 days of tests on this network against its plan, when a plan is set.
    public let planCheck: PlanSummary?
    public var check: Check?
    /// What was left out on purpose, said in the report so the reader knows it isn't missing by accident.
    public var leftOut: [String]
    /// The Starlink dish's own outage log, when the report's network is a dish's.
    public var starlink: StarlinkEvidence? = nil
    /// One service much slower than the rest of the internet on this network: the route to it, for the provider.
    public var serviceRoute: ServiceRoute? = nil

    public struct ServiceRoute: Codable, Sendable {
        public let service: String
        public let slowMbps: Double
        public let elsewhereMbps: Double
        public let transfers: Int
        public let since: Date
        /// The hours it's slow in, when there's a pattern.
        public let pattern: String?
        /// Where a route trace saw the delay rise.
        public let trace: String?
        /// The server traced, a public address.
        public let address: String?
    }

    public static let footer = String(localized: "Measured with Kilobat · kilobat.app", comment: "The last line of the report for an internet provider")

    /// Builds the report for the network the latest check ran on. `plans` are the plans set per network
    /// (`PlanSpeeds`); `planMbps` stands in for a network without one.
    public static func make(samples: [DiagnosticSnapshot], events: [NetworkEvent], speedTests: [SavedSpeedTest],
                            hours: Int, planMbps: Double? = nil, plans: [String: Double] = [:], check: DoctorReport? = nil, starlink: StarlinkEvidence? = nil,
                            serviceSpeed: ServiceSpeedReport? = nil, placeURL: String? = nil, mac: String = SupportReport.macDescription(), now: Date = Date()) -> SupportReport {
        let since = now.addingTimeInterval(-Double(hours) * 3600)
        let latest = samples.last
        let key = latest.flatMap { $0.networkIdentified ? $0.networkKey : nil }, name = latest?.networkName
        // With an unidentified network, summarize the current reading only.
        let window = key == nil ? [latest].compactMap { $0 }.filter { $0.date >= since } : samples.filter { $0.date >= since && $0.networkKey == key }
        let outages = events
            .filter { $0.kind == "Unreachable" && key != nil && $0.networkKey == key && ($0.end ?? now) >= since }
            .map { Outage(start: max($0.start, since), end: min($0.end ?? now, now)) }
            .filter { $0.end > $0.start }
        let speeds = speedTests
            .filter { $0.result.date >= since && $0.result.date <= now && $0.networkKey == key && $0.networkChanged != true }
            .suffix(10)
            .map { Speed(date: $0.result.date, downloadMbps: $0.result.downloadMbps, uploadMbps: $0.result.uploadMbps,
                         idleMs: $0.result.baseline.average, bufferbloat: $0.result.bufferbloat,
                         downloadLoadedMs: $0.result.downloadSeconds >= 2 ? $0.result.downloadLoaded.average : nil,
                         uploadLoadedMs: $0.result.uploadSeconds >= 2 ? $0.result.uploadLoaded.average : nil) }
        let latency = window.isEmpty ? nil : Self.latency(window)
        let plan = (key.flatMap { plans[$0] } ?? planMbps).flatMap { $0 > 0 ? $0 : nil }
        // Fewer than three tests add nothing the speed tests below don't say.
        let planCheck = PlanSummary.make(tests: speedTests, network: key, planMbps: plan, now: now).flatMap { $0.checks >= PlanSummary.enoughScheduled ? $0 : nil }
        let doctor = check.map { report in
            Check(host: report.host, ok: report.ok, verdict: redact(report.verdict),
                  steps: report.steps.map { Step(layer: $0.title, status: $0.status.rawValue, detail: redact($0.detail)) })
        }
        var lines = findings(latency: latency, outages: outages, speeds: Array(speeds), plan: plan, planCheck: planCheck, check: doctor, hours: hours)
        // The dish's log goes right after Kilobat's own outages, or replaces the "nothing recorded yet" line.
        if let line = starlink?.finding {
            if latency == nil, outages.isEmpty, speeds.isEmpty, planCheck == nil, doctor == nil { lines = [line] } else { lines.insert(line, at: outages.isEmpty ? 0 : 1) }
        }
        // A slow route to one service, on this report's network only.
        let route = serviceSpeed.flatMap { report -> ServiceRoute? in
            guard report.network == key, let finding = report.finding, finding.kind == "route", finding.latest >= since else { return nil }
            return ServiceRoute(service: finding.service, slowMbps: finding.slowMbps, elsewhereMbps: finding.elsewhereMbps, transfers: finding.slowTransfers,
                                since: finding.since, pattern: finding.pattern?.sentence, trace: finding.trace.map(ServiceSpeedReport.traceSentence), address: finding.trace?.address)
        }
        if route != nil, let line = serviceSpeed?.providerLine {
            if latency == nil, outages.isEmpty, speeds.isEmpty, planCheck == nil, doctor == nil, starlink?.finding == nil { lines = [line] } else { lines.append(line) }
        }
        let suppliedURL = placeURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeURL = suppliedURL.flatMap { value -> String? in
            guard let parts = URLComponents(string: value), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), parts.host != nil, parts.user == nil, parts.password == nil else { return nil }
            return value
        }
        return SupportReport(created: now, hours: hours, firstCheck: window.map(\.date).min(), lastCheck: window.map(\.date).max(), placeURL: safeURL, mac: mac, connection: latest.map(connection) ?? String(localized: "No checks recorded yet", comment: "The provider report’s connection line before any health check ran"),
                             findings: lines,
                             latency: latency, outages: outages, speedTests: Array(speeds), planMbps: plan, planCheck: planCheck, check: doctor,
                             leftOut: [String(localized: "the network’s name", comment: "Left out of the provider report; items are joined with semicolons"),
                                       String(localized: "every IP address on your network, including the router’s", comment: "Left out of the provider report; items are joined with semicolons"),
                                       String(localized: "device names and hardware addresses", comment: "Left out of the provider report; items are joined with semicolons"),
                                       String(localized: "which apps used the network", comment: "Left out of the provider report; items are joined with semicolons")]
                                     + (starlink == nil ? [] : [String(localized: "the dish’s serial number and location", comment: "Left out of the provider report; items are joined with semicolons")]),
                             starlink: starlink?.outages.isEmpty == false ? starlink : nil, serviceRoute: route)
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
    static func findings(latency: Latency?, outages: [Outage], speeds: [Speed], plan: Double?, planCheck: PlanSummary? = nil, check: Check?, hours: Int) -> [String] {
        var lines: [String] = []
        let period = hours == 24 ? String(localized: "the last 24 hours", comment: "The provider report’s period, mid-sentence")
            : hours % 24 == 0 ? String(localized: "the last \(hours / 24) days", comment: "The provider report’s period, mid-sentence")
            : String(localized: "the last \(hours) hours", comment: "The provider report’s period, mid-sentence")
        if !outages.isEmpty {
            let total = minutes(outages.reduce(0) { $0 + $1.minutes }), longest = outages.max { $0.minutes < $1.minutes }!
            let length = minutes(longest.minutes), start = time(longest.start)
            lines.append(outages.count == 1
                ? String(localized: "The internet was unreachable once in \(period), \(total) in all; the longest lasted \(length) from \(start).", comment: "A period such as “the last 24 hours”, the total and longest outage length, and when it started")
                : String(localized: "The internet was unreachable \(outages.count) times in \(period), \(total) in all; the longest lasted \(length) from \(start).", comment: "A count, a period such as “the last 24 hours”, the total and longest outage length, and when it started"))
        }
        if let latency, let internet = latency.internetMedianMs {
            if let router = latency.routerMedianMs, router < 15, internet > 80 || (latency.internetP95Ms ?? 0) > 200 {
                lines.append(String(localized: "The link to the router stayed fast (median \(ms(router))) while internet latency was high (median \(ms(internet)), 95th percentile \(ms(latency.internetP95Ms))). The delay starts beyond the router.", comment: "Latencies such as “3 ms”"))
            } else if let router = latency.routerMedianMs, router >= 15 {
                lines.append(String(localized: "The router itself answered slowly (median \(ms(router))), which points to Wi-Fi or the router before the internet connection. Internet latency was \(ms(internet)) (median).", comment: "Latencies such as “40 ms”"))
            } else {
                lines.append(String(localized: "Internet latency was \(ms(internet)) (median) over \(latency.checks) checks, \(ms(latency.internetP95Ms)) at the 95th percentile.", comment: "A latency, a count of health checks and another latency"))
            }
            if let loss = latency.lossPercent, loss >= 1 { lines.append(String(localized: "On average \(String(format: "%.1f", locale: Locale.current, loss))% of internet pings got no reply.")) }
            if latency.poorPercent + latency.degradedPercent >= 20 {
                lines.append(String(localized: "\(String(format: "%.0f", locale: Locale.current, latency.poorPercent + latency.degradedPercent))% of checks were slow or poor.", comment: "A percentage of health checks"))
            }
        }
        // A month against the plan says more than a day's tests, so it comes first.
        if let planCheck { lines.append(planCheck.sentence) }
        if !speeds.isEmpty {
            let down = median(speeds.map(\.downloadMbps)) ?? 0, up = median(speeds.map(\.uploadMbps)) ?? 0
            if let plan {
                lines.append(String(localized: "\(speeds.count) speed tests: median \(mbps(down)) down, \(mbps(up)) up, \(String(format: "%.0f", locale: Locale.current, down / plan * 100))% of the \(mbps(plan)) plan.", comment: "A count of speed tests, the median download and upload speeds, and the download as a share of the internet plan’s speed"))
            } else {
                lines.append(String(localized: "\(speeds.count) speed tests: median \(mbps(down)) down, \(mbps(up)) up.", comment: "A count of speed tests and the median download and upload speeds"))
            }
        }
        if let check { lines.append("\(check.host): \(check.verdict)") }
        if lines.isEmpty { lines.append(String(localized: "Kilobat hasn’t recorded checks on this network in \(period) yet. Keep the app running, then make the report again.", comment: "A period such as “the last 24 hours”")) }
        return lines
    }

    // MARK: Redaction

    /// Private and link-local addresses become words; public server addresses stay, since they name the server, not you.
    /// The report without the names of the sites in it, unless the person ticks "Include site names": the host they
    /// checked and the service with a slow route become "the site checked" and "one service", and the service's server
    /// address goes. The measurements stay.
    public func withoutSiteNames() -> SupportReport {
        let site = String(localized: "the site checked", comment: "Replaces the checked site's name in the provider report, mid-sentence")
        let service = String(localized: "one service", comment: "Replaces a service's name, such as GitHub, in the provider report, mid-sentence")
        let server = String(localized: "its server", comment: "Replaces a service's server address in the provider report, mid-sentence")
        var names: [(String, String)] = []
        if let host = check?.host, !host.isEmpty { names.append((host, site)) }
        if let route = serviceRoute {
            if !route.service.isEmpty { names.append((route.service, service)) }
            if let address = route.address, !address.isEmpty { names.append((address, server)) }
        }
        guard !names.isEmpty else { return self }
        // Longest first, so a name inside another (github.com in api.github.com) can't leave half of it behind.
        names.sort { $0.0.count > $1.0.count }
        func scrub(_ text: String) -> String {
            // Redirects and certificate errors can name another host, not just the host the person checked.
            // Paths and query strings can identify the visit too. Remove URLs before renaming hosts, while
            // keeping standalone public IP measurements in DNS/route results.
            let urls = text.replacingOccurrences(of: #"\b(?:https?|wss?)://[^\s<>"']+"#, with: site,
                                                 options: [.regularExpression, .caseInsensitive])
            let domains = urls.replacingOccurrences(of: #"(?<![\p{L}\p{N}_-])(?:[\p{L}\p{N}][\p{L}\p{N}_-]*\.)+\p{L}[\p{L}\p{N}_-]*(?![\p{L}\p{N}_-])(?::[0-9]+)?(?:/[^\s<>"']*)?"#,
                                                     with: site, options: [.regularExpression, .caseInsensitive])
            return names.reduce(domains) { $0.replacingOccurrences(of: $1.0, with: $1.1, options: [.caseInsensitive]) }
        }
        var copy = self
        copy.findings = findings.map(scrub)
        copy.check = check.map { Check(host: site, ok: $0.ok, verdict: scrub($0.verdict), steps: $0.steps.map { Step(layer: $0.layer, status: $0.status, detail: scrub($0.detail)) }) }
        copy.serviceRoute = serviceRoute.map {
            ServiceRoute(service: service, slowMbps: $0.slowMbps, elsewhereMbps: $0.elsewhereMbps, transfers: $0.transfers, since: $0.since,
                         pattern: $0.pattern.map(scrub), trace: $0.trace.map(scrub), address: nil)
        }
        copy.leftOut.append(String(localized: "the names of the sites checked", comment: "Left out of the provider report; items are joined with semicolons"))
        return copy
    }

    public static func redact(_ text: String) -> String {
        var result = text
        let local = String(localized: "a local address", comment: "Replaces a private IP address in the provider report, mid-sentence")
        let patterns: [(String, String)] = [
            (#"\b(?:10|127)(?:\.\d{1,3}){3}\b"#, local),
            (#"\b192\.168(?:\.\d{1,3}){2}\b"#, local),
            (#"\b172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2}\b"#, local),
            (#"\b169\.254(?:\.\d{1,3}){2}\b"#, String(localized: "a link-local address", comment: "Replaces a 169.254 address in the provider report, mid-sentence")),
            (#"\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])(?:\.\d{1,3}){2}\b"#, String(localized: "a carrier or VPN address", comment: "Replaces a 100.64/10 address in the provider report, mid-sentence")),
            (#"\b(?:fe80|fd[0-9a-f]{2}|fc[0-9a-f]{2}):[0-9a-f:%\w]*"#, local),
            (#"\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b"#, String(localized: "a hardware address", comment: "Replaces a MAC address in the provider report, mid-sentence")),
        ]
        for (pattern, word) in patterns {
            result = result.replacingOccurrences(of: pattern, with: word, options: [.regularExpression, .caseInsensitive])
        }
        return result
    }

    static func connection(_ sample: DiagnosticSnapshot) -> String {
        if let wired = sample.wiredInterface { return String(localized: "Wired (\(wired))", comment: "An Ethernet connection and its interface, such as en7") }
        let radio = sample.radio
        guard radio.rssi != nil else { return sample.networkService ?? String(localized: "Unknown connection") }
        return [radio.band.map { String(localized: "Wi-Fi \($0)", comment: "Wi-Fi and its band, such as 5 GHz") } ?? String(localized: "Wi-Fi"),
                radio.channel.map { String(localized: "channel \($0)", comment: "A Wi-Fi channel number, in a list after the band") },
                radio.rssi.map { String(localized: "signal \($0) dBm", comment: "Wi-Fi signal strength, in a list after the channel") },
                radio.transmitMbps.map { String(localized: "link \(String(format: "%.0f", locale: Locale.current, $0)) Mbps", comment: "Wi-Fi link rate, in a list after the signal") }]
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
    static func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", locale: Locale.current, $0) } ?? "—" }
    static func mbps(_ value: Double) -> String { String(format: value < 10 ? "%.1f Mbps" : "%.0f Mbps", locale: Locale.current, value) }
    static func minutes(_ value: Double) -> String {
        value < 1 ? String(localized: "under a minute", comment: "How long an outage lasted")
            : value < 90 ? String(localized: "\(String(format: "%.0f", locale: Locale.current, value)) min", comment: "Minutes, abbreviated") : String(localized: "\(String(format: "%.1f", locale: Locale.current, value / 60)) h", comment: "Hours, abbreviated")
    }
    static func time(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
}
