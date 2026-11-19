import CryptoKit
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
    /// A watched route the person chose to include (`with(route:)`).
    public var route: RouteEvidence? = nil
    /// The provider and plan the person set up in the app; the CLI's report has none.
    public var service: Service? = nil
    /// This network the week before and the days since a recent macOS upgrade, without the network's name.
    public var macOSUpgrade: MacOSUpgradeComparison? = nil

    public struct Service: Codable, Sendable, Equatable {
        public var provider: String?
        public var downloadMbps: Double?
        public var uploadMbps: Double?
        public var minimumMbps: Double?
        public init(provider: String? = nil, downloadMbps: Double? = nil, uploadMbps: Double? = nil, minimumMbps: Double? = nil) {
            self.provider = provider; self.downloadMbps = downloadMbps; self.uploadMbps = uploadMbps; self.minimumMbps = minimumMbps
        }
        var isEmpty: Bool { provider == nil && downloadMbps == nil && uploadMbps == nil && minimumMbps == nil }
        /// "BT · plan 500 Mbps down, 50 Mbps up · guaranteed minimum 250 Mbps"
        public var line: String? {
            var parts: [String] = []
            if let provider { parts.append(provider) }
            switch (downloadMbps, uploadMbps) {
            case let (down?, up?): parts.append(String(localized: "plan \(SupportReport.mbps(down)) down, \(SupportReport.mbps(up)) up", comment: "The internet plan in the provider report: download and upload speeds"))
            case let (down?, nil): parts.append(String(localized: "plan \(SupportReport.mbps(down)) down", comment: "The internet plan in the provider report: its download speed"))
            case let (nil, up?): parts.append(String(localized: "plan \(SupportReport.mbps(up)) up", comment: "The internet plan in the provider report: its upload speed"))
            case (nil, nil): break
            }
            if let minimumMbps { parts.append(String(localized: "guaranteed minimum \(SupportReport.mbps(minimumMbps))", comment: "The contract's minimum download speed, in the provider report")) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        /// The report's line: "Provider: BT · plan 500 Mbps down, 50 Mbps up", or "Plan 500 Mbps down" without a provider.
        public var heading: String? {
            guard let line else { return nil }
            return provider != nil ? String(localized: "Provider: \(line)", comment: "The provider report’s line naming the provider and plan") : line.prefix(1).uppercased() + line.dropFirst()
        }
    }

    /// The report with the person's provider and plan named at the top, and a finding when the tests' median download
    /// fell under the guaranteed minimum. Measurements only: it never says the contract was breached.
    public func with(service: Service) -> SupportReport {
        let cleaned = Service(provider: service.provider.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 },
                              downloadMbps: service.downloadMbps.flatMap { $0 > 0 && $0.isFinite ? $0 : nil } ?? planMbps,
                              uploadMbps: service.uploadMbps.flatMap { $0 > 0 && $0.isFinite ? $0 : nil },
                              minimumMbps: service.minimumMbps.flatMap { $0 > 0 && $0.isFinite ? $0 : nil })
        guard !cleaned.isEmpty else { return self }
        var copy = self
        copy.service = cleaned
        let median = planCheck?.downloadMedianMbps ?? Self.median(speedTests.map(\.downloadMbps))
        if let minimum = cleaned.minimumMbps, let median, median < minimum {
            copy.findings.append(String(localized: "The median download, \(Self.mbps(median)), was under the guaranteed minimum of \(Self.mbps(minimum)).", comment: "Provider report: the median measured download and the contract's minimum speed"))
        }
        return copy
    }

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
                            serviceSpeed: ServiceSpeedReport? = nil, placeURL: String? = nil, macOSUpgrade: MacOSUpgradeComparison? = nil,
                            mac: String = SupportReport.macDescription(), now: Date = Date(), calendar: Calendar = .current) -> SupportReport {
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
        let planCheck = PlanSummary.make(tests: speedTests, network: key, planMbps: plan, now: now, calendar: calendar).flatMap { $0.checks >= PlanSummary.enoughScheduled ? $0 : nil }
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
                                since: finding.since, pattern: finding.pattern?.sentence, trace: finding.trace.flatMap(ServiceSpeedReport.traceSentence), address: finding.trace?.address)
        }
        if route != nil, let line = serviceSpeed?.providerLine {
            if latency == nil, outages.isEmpty, speeds.isEmpty, planCheck == nil, doctor == nil, starlink?.finding == nil { lines = [line] } else { lines.append(line) }
        }
        // A recent macOS upgrade, compared on this report's network only; what got worse leads its line.
        let upgrade = macOSUpgrade.flatMap { $0.comparable && key != nil && $0.networkKey == key ? $0.withoutNetwork : nil }
        if let upgrade, !upgrade.worse.isEmpty { lines.append(upgrade.summary) }
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
                             starlink: starlink?.outages.isEmpty == false ? starlink : nil, serviceRoute: route, macOSUpgrade: upgrade)
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
        if let watched = route {
            let word = String(localized: "the host watched", comment: "Replaces a watched route's host in the provider report, mid-sentence")
            names.append((watched.host, word))
            if let address = watched.hops.last(where: { $0.destination })?.router, !address.isEmpty { names.append((address, word)) }
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
        copy.route = route?.withoutNames()
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

// MARK: Complaint evidence

/// Everything a complaint pack argues from, frozen in one value. It is saved as the evidence file whose SHA-256 the
/// PDF prints, so anyone can check that the file is the one the PDF was made from. It carries the report as redacted
/// and every speed test of the period on the report's network, never a network name, an address or the person's details.
public struct ComplaintEvidence: Codable, Sendable {
    public struct Test: Codable, Sendable, Equatable {
        public let date: Date
        public let downloadMbps: Double
        public let uploadMbps: Double
        public let idleMs: Double?
        /// "Ethernet", "Wi-Fi", "VPN" or "Other"; nil for a test saved before Kilobat recorded it.
        public let link: String?
        public let band: String?
        public let server: String?
        /// Started by Kilobat on a schedule, not by the person.
        public let scheduled: Bool
        public var wired: Bool { link == "Ethernet" }
        public init(date: Date, downloadMbps: Double, uploadMbps: Double, idleMs: Double? = nil, link: String? = nil, band: String? = nil, server: String? = nil, scheduled: Bool = false) {
            self.date = date; self.downloadMbps = downloadMbps; self.uploadMbps = uploadMbps; self.idleMs = idleMs
            self.link = link; self.band = band; self.server = server; self.scheduled = scheduled
        }
    }
    /// What the provider sold, as the person entered it.
    public struct Plan: Codable, Sendable, Equatable {
        public var provider: String?
        public var country: String?
        public var downloadMbps: Double?
        public var uploadMbps: Double?
        public var minimumMbps: Double?
        public init(provider: String? = nil, country: String? = nil, downloadMbps: Double? = nil, uploadMbps: Double? = nil, minimumMbps: Double? = nil) {
            self.provider = provider; self.country = country; self.downloadMbps = downloadMbps; self.uploadMbps = uploadMbps; self.minimumMbps = minimumMbps
        }
    }
    /// The numbers page one leads with.
    public struct Summary: Codable, Sendable, Equatable {
        public let tests: Int
        public let wiredTests: Int
        public let wifiTests: Int
        public let scheduledTests: Int
        /// Calendar days with at least one test.
        public let days: Int
        public let medianDownMbps: Double?
        public let medianUpMbps: Double?
        /// 7 to 11 pm, the busy hours regulators measure, and the rest of the day.
        public let eveningTests: Int
        public let eveningMedianMbps: Double?
        public let daytimeTests: Int
        public let daytimeMedianMbps: Double?
        /// The 10th percentile download: what the slowest tenth of tests got.
        public let worstTenthMbps: Double?
        public let percentOfPlan: Double?
        public let belowMinimumPercent: Double?
        public let belowHalfPercent: Double?
        public let outages: Int
        public let outageMinutes: Double
        public let longestOutageMinutes: Double?
    }
    /// The published credit rule and what the outages may be worth under it.
    public struct Credit: Codable, Sendable, Equatable {
        public let rule: String
        public let terms: String?
        public let source: String
        public let checked: String
        public let qualifies: Bool
        public let amount: Double?
        public let currency: String?
        public let atLeast: Bool
        public let verdict: String
        public init(rule: String, terms: String?, source: String, checked: String, qualifies: Bool, amount: Double?, currency: String?, atLeast: Bool, verdict: String) {
            self.rule = rule; self.terms = terms; self.source = source; self.checked = checked; self.qualifies = qualifies
            self.amount = amount; self.currency = currency; self.atLeast = atLeast; self.verdict = verdict
        }
        public init?(_ report: CreditReport) {
            guard let policy = report.policy else { return nil }
            self.init(rule: policy.name, terms: report.terms, source: policy.source, checked: policy.checked, qualifies: report.estimate.qualifies,
                      amount: report.estimate.amount, currency: report.estimate.currency, atLeast: report.estimate.atLeast, verdict: report.verdict)
        }
        /// "about £31.02" or "at least €30.00"
        public var amountText: String? {
            guard qualifies, let amount, let currency else { return nil }
            return atLeast ? String(localized: "at least \(CreditText.money(amount, currency))", comment: "A credit estimate") : String(localized: "about \(CreditText.money(amount, currency))", comment: "A credit estimate")
        }
    }

    public let generated: Date
    public let from: Date
    public let to: Date
    /// The time zone every time in the pack is in, such as Europe/London.
    public let timeZone: String
    /// "Kilobat 1.31.8 (1318)"
    public let app: String
    public let plan: Plan
    public let summary: Summary
    /// Oldest first.
    public let tests: [Test]
    public let report: SupportReport
    public var credit: Credit?

    public init(generated: Date, from: Date, to: Date, timeZone: String, app: String, plan: Plan, summary: Summary, tests: [Test], report: SupportReport, credit: Credit?) {
        self.generated = generated; self.from = from; self.to = to; self.timeZone = timeZone; self.app = app
        self.plan = plan; self.summary = summary; self.tests = tests; self.report = report; self.credit = credit
    }

    /// The period's tests on the report's network, with `network` the key the report was made for.
    public static func make(report: SupportReport, speedTests: [SavedSpeedTest], network: String?, plan: Plan, credit: Credit? = nil, app: String,
                            timeZone: TimeZone = .current, calendar: Calendar = .current) -> ComplaintEvidence {
        let from = report.created.addingTimeInterval(-Double(report.hours) * 3600), to = report.created
        let tests = speedTests
            .filter { $0.networkKey == network && $0.networkChanged != true && $0.reservedAttempt != true && $0.result.date >= from && $0.result.date <= to }
            .sorted { $0.result.date < $1.result.date }
            .map { saved in
                Test(date: saved.result.date, downloadMbps: saved.result.downloadMbps, uploadMbps: saved.result.uploadMbps, idleMs: saved.result.baseline.average,
                     link: saved.result.context?.kind, band: saved.result.context?.band, server: saved.result.server, scheduled: saved.scheduled == true)
            }
        return make(report: report, tests: tests, plan: plan, credit: credit, app: app, timeZone: timeZone, calendar: calendar)
    }

    /// From tests already chosen, oldest first: the sample data and the smoke test build packs this way.
    public static func make(report: SupportReport, tests: [Test], plan: Plan, credit: Credit? = nil, app: String,
                            timeZone: TimeZone = .current, calendar: Calendar = .current) -> ComplaintEvidence {
        var plan = plan
        if plan.downloadMbps == nil { plan.downloadMbps = report.service?.downloadMbps ?? report.planMbps }
        if plan.provider == nil { plan.provider = report.service?.provider }
        if plan.uploadMbps == nil { plan.uploadMbps = report.service?.uploadMbps }
        if plan.minimumMbps == nil { plan.minimumMbps = report.service?.minimumMbps }
        return ComplaintEvidence(generated: report.created, from: report.created.addingTimeInterval(-Double(report.hours) * 3600), to: report.created,
                                 timeZone: timeZone.identifier, app: app, plan: plan,
                                 summary: summary(tests: tests, outages: report.outages, plan: plan, calendar: calendar), tests: tests, report: report, credit: credit)
    }

    /// Two units at most, days once it runs past a day: "4 days, 2 hr", not "98 hrs, 11 min", in the verdict and the pack's tiles.
    public static func duration(_ minutes: Double) -> String {
        let units: Set<Duration.UnitsFormatStyle.Unit> = minutes >= 1_440 ? [.days, .hours] : [.hours, .minutes]
        return Duration.seconds((minutes * 60).rounded()).formatted(.units(allowed: units, width: .abbreviated, maximumUnitCount: 2))
    }

    static func summary(tests: [Test], outages: [SupportReport.Outage], plan: Plan, calendar: Calendar) -> Summary {
        let down = tests.map(\.downloadMbps)
        let evening = tests.filter { PlanCheck.peakHours.contains(calendar.component(.hour, from: $0.date)) }.map(\.downloadMbps)
        let daytime = tests.filter { !PlanCheck.peakHours.contains(calendar.component(.hour, from: $0.date)) }.map(\.downloadMbps)
        let median = PlanSummary.median(down)
        func share(_ below: Double?) -> Double? {
            guard let below, below > 0, !down.isEmpty else { return nil }
            return Double(down.filter { $0 < below }.count) / Double(down.count) * 100
        }
        return Summary(tests: tests.count, wiredTests: tests.filter(\.wired).count, wifiTests: tests.filter { $0.link == "Wi-Fi" }.count,
                       scheduledTests: tests.filter(\.scheduled).count, days: Set(tests.map { calendar.startOfDay(for: $0.date) }).count,
                       medianDownMbps: median, medianUpMbps: PlanSummary.median(tests.map(\.uploadMbps)),
                       eveningTests: evening.count, eveningMedianMbps: PlanSummary.median(evening), daytimeTests: daytime.count, daytimeMedianMbps: PlanSummary.median(daytime),
                       worstTenthMbps: down.isEmpty ? nil : down.sorted()[Int((Double(down.count - 1) * 0.1).rounded(.down))],
                       percentOfPlan: median.flatMap { value in plan.downloadMbps.map { value / $0 * 100 } },
                       belowMinimumPercent: share(plan.minimumMbps), belowHalfPercent: share(plan.downloadMbps.map { $0 / 2 }),
                       outages: outages.count, outageMinutes: outages.reduce(0) { $0 + $1.minutes }, longestOutageMinutes: outages.map(\.minutes).max())
    }

    /// One sentence for page one and the letter: measured facts only, never whose fault it is.
    public var verdict: String {
        var parts: [String] = []
        if let median = summary.medianDownMbps {
            if let share = summary.percentOfPlan, let advertised = plan.downloadMbps {
                parts.append(String(localized: "the median download was \(SupportReport.mbps(median)), \(PlanSummary.percent(share)) of the advertised \(SupportReport.mbps(advertised))",
                                    comment: "Complaint verdict, mid-sentence: the median measured download, its share of the plan, and the plan"))
            } else {
                parts.append(String(localized: "the median download was \(SupportReport.mbps(median))", comment: "Complaint verdict, mid-sentence: the median measured download"))
            }
            if let below = summary.belowMinimumPercent, let minimum = plan.minimumMbps, below > 0 {
                parts.append(String(localized: "\(PlanSummary.percent(below)) of \(summary.tests) tests fell below the guaranteed minimum of \(SupportReport.mbps(minimum))",
                                    comment: "Complaint verdict, mid-sentence: the share of speed tests under the contract's minimum, the count, and the minimum"))
            }
        }
        if summary.outages > 0 {
            parts.append(summary.outages == 1
                ? String(localized: "the internet was unreachable once, for \(ComplaintEvidence.duration(summary.outageMinutes))", comment: "Complaint verdict, mid-sentence: one outage and its length")
                : String(localized: "the internet was unreachable \(summary.outages) times, \(ComplaintEvidence.duration(summary.outageMinutes)) in all", comment: "Complaint verdict, mid-sentence: a count of outages and their total length"))
        }
        guard !parts.isEmpty else { return String(localized: "Kilobat recorded no speed tests or outages on this connection in the period.", comment: "Complaint verdict without measurements") }
        let sentence = parts.joined(separator: "; ") + "."
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    /// The evidence file's bytes: sorted keys and ISO 8601 times, so the same evidence always gives the same file.
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)) ?? Data()
    }
    /// The SHA-256 of `encoded()` in hex, as `shasum -a 256` prints it for the saved file.
    public var fingerprint: String { Self.fingerprint(encoded()) }
    public static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// What would make the case stronger, by the thresholds Kilobat itself uses: three scheduled checks before a month
    /// counts them alone, two evening checks before the evening median is named, and a test over a cable.
    public enum Gap: Equatable, Sendable {
        case plan, minimum, tests
        case scheduled(Int)
        case evenings(Int)
        case wired
    }
    public var gaps: [Gap] {
        var gaps: [Gap] = []
        if plan.downloadMbps == nil { gaps.append(.plan) }
        if plan.minimumMbps == nil { gaps.append(.minimum) }
        guard summary.tests > 0 else { return gaps + [.tests] }
        if summary.scheduledTests < PlanSummary.enoughScheduled { gaps.append(.scheduled(PlanSummary.enoughScheduled - summary.scheduledTests)) }
        if summary.eveningTests < PlanSummary.enoughEvenings { gaps.append(.evenings(PlanSummary.enoughEvenings - summary.eveningTests)) }
        if summary.wiredTests == 0 { gaps.append(.wired) }
        return gaps
    }
}
