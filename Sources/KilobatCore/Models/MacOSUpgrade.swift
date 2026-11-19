import Foundation

/// A macOS version and when this Mac started running it.
public struct MacOSRelease: Codable, Sendable, Equatable {
    /// "27.2", "26.7.1"
    public let version: String
    public let date: Date
    public init(version: String, date: Date) { self.version = version; self.date = date }
}

public enum MacOSVersion {
    /// "27.2", "27.2.1"
    public static var current: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")
    }

    /// Numeric order, so 27.10 comes after 27.9.
    public static func isNewer(_ version: String, than other: String) -> Bool {
        version.compare(other, options: .numeric) == .orderedDescending
    }

    /// macOS updates from the installer's own log (/Library/Receipts/InstallHistory.plist), oldest first, one entry per
    /// version: betas of one release repeat its version, and the first install is when the Mac moved to it.
    public static func installHistory(_ data: Data) -> [MacOSRelease] {
        guard let entries = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { return [] }
        let releases = entries.compactMap { entry -> MacOSRelease? in
            guard let name = entry["displayName"] as? String, name.hasPrefix("macOS ") || name.hasPrefix("OS X "),
                  let date = entry["date"] as? Date else { return nil }
            let version = (entry["displayVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? name.split(separator: " ").last.map(String.init)
            guard let version, version.first?.isNumber == true else { return nil }
            return MacOSRelease(version: version, date: date)
        }.sorted { $0.date < $1.date }
        return collapse(releases)
    }

    public static func readInstallHistory(path: String = "/Library/Receipts/InstallHistory.plist") -> [MacOSRelease] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return installHistory(data)
    }

    /// The installer's log and Kilobat's own sightings as one timeline, oldest first. A version Kilobat saw that the
    /// log doesn't have (it can be missing or cleared) keeps the date Kilobat first saw it.
    public static func timeline(installed: [MacOSRelease], seen: [MacOSRelease]) -> [MacOSRelease] {
        let known = Set(installed.map(\.version))
        return collapse((installed + seen.filter { !known.contains($0.version) }).sorted { $0.date < $1.date })
    }

    /// Drops repeats of the version before, keeping the first date.
    static func collapse(_ releases: [MacOSRelease]) -> [MacOSRelease] {
        var result: [MacOSRelease] = []
        for release in releases where release.version != result.last?.version { result.append(release) }
        return result
    }

    /// The version this Mac ran at a moment, or nil before the timeline starts.
    public static func version(at date: Date, in timeline: [MacOSRelease]) -> String? {
        timeline.last { $0.date <= date }?.version
    }
}

/// One hour of Health's checks on one network, kept for four months so a macOS upgrade can be compared with the
/// days before it. Medians, so one slow check can't move an hour.
public struct HourlyCheck: Codable, Sendable, Equatable {
    public let hour: Date
    public let networkKey: String
    public let networkName: String
    public let checks: Int
    public let internetMs: Double?
    public let routerMs: Double?
    public let dnsMs: Double?
    public let lossPercent: Double?
    /// The macOS version the checks ran on, when Kilobat knew it.
    public var macOS: String?

    public init(hour: Date, networkKey: String, networkName: String, checks: Int, internetMs: Double?, routerMs: Double?, dnsMs: Double?, lossPercent: Double?, macOS: String? = nil) {
        self.hour = hour; self.networkKey = networkKey; self.networkName = networkName; self.checks = checks
        self.internetMs = internetMs; self.routerMs = routerMs; self.dnsMs = dnsMs; self.lossPercent = lossPercent; self.macOS = macOS
    }

    /// Each hour's samples on each network, oldest first.
    public static func summarize(_ samples: [DiagnosticSnapshot], macOS: (Date) -> String?, calendar: Calendar = .current) -> [HourlyCheck] {
        let groups = Dictionary(grouping: samples.filter { $0.networkIdentified }) { sample in
            HourKey(hour: calendar.dateInterval(of: .hour, for: sample.date)?.start ?? sample.date, network: sample.networkKey)
        }
        return groups.map { key, group in
            HourlyCheck(hour: key.hour, networkKey: key.network, networkName: group.last?.networkName ?? "", checks: group.count,
                        internetMs: SupportReport.median(group.compactMap { $0.internet.average }),
                        routerMs: SupportReport.median(group.compactMap { $0.router?.average }),
                        dnsMs: SupportReport.median(group.compactMap(\.dnsMilliseconds)),
                        lossPercent: SupportReport.mean(group.compactMap { $0.internet.lossPercent }),
                        macOS: macOS(key.hour))
        }.sorted { ($0.hour, $0.networkKey) < ($1.hour, $1.networkKey) }
    }
    private struct HourKey: Hashable { let hour: Date; let network: String }
}

/// "It was fine before the update", as measurements: the same network's checks, drops and speed tests in the days
/// before and after a macOS upgrade, side by side. It says what changed, never that the update caused it.
public struct MacOSUpgradeComparison: Codable, Sendable, Equatable {
    public struct Side: Codable, Sendable, Equatable {
        public let version: String
        /// Hours with checks.
        public let hours: Int
        public let internetMs: Double?
        public let routerMs: Double?
        public let dnsMs: Double?
        public let lossPercent: Double?
        /// Times the internet was unreachable on this network.
        public let drops: Int
        public let dropsPerDay: Double?
        public let speedTests: Int
        public let downloadMbps: Double?
        public let uploadMbps: Double?
    }
    public struct Change: Codable, Sendable, Equatable, Identifiable {
        public enum Metric: String, Codable, Sendable { case download, upload, latency, router, dns, loss, drops }
        public var id: String { metric.rawValue }
        public let metric: Metric
        public let before: Double
        public let after: Double
        /// Worse by enough to mention, after the upgrade.
        public let worse: Bool
        public let better: Bool
    }
    public let from: String
    public let to: String
    public let upgraded: Date
    /// Days compared on each side.
    public let days: Int
    public var networkKey: String?
    public var networkName: String?
    public let before: Side
    public let after: Side
    public let changes: [Change]

    public var worse: [Change] { changes.filter(\.worse) }
    /// Enough on both sides to say anything.
    public var comparable: Bool { !changes.isEmpty }

    /// The latest macOS change in the last `within` days, compared over `days` days on each side, on `network` when
    /// it has checks on both sides, else on the network with the most. Nil when there's no recent upgrade.
    public static func make(timeline: [MacOSRelease], hourly: [HourlyCheck], events: [NetworkEvent], speedTests: [SavedSpeedTest],
                            network preferred: String? = nil, now: Date = Date(), days: Int = 7, within: Int = 30) -> MacOSUpgradeComparison? {
        guard timeline.count >= 2, let index = timeline.indices.last(where: { $0 > 0 && timeline[$0].date <= now }),
              now.timeIntervalSince(timeline[index].date) <= Double(within) * 86_400 else { return nil }
        let from = timeline[index - 1].version, to = timeline[index].version, pivot = timeline[index].date
        let start = max(pivot.addingTimeInterval(-Double(days) * 86_400), timeline[index - 1].date)
        let end = min(pivot.addingTimeInterval(Double(days) * 86_400), now)
        func inBefore(_ date: Date) -> Bool { date >= start && date < pivot }
        func inAfter(_ date: Date) -> Bool { date >= pivot && date <= end }
        // A tag that disagrees with the side means the dates can't be trusted for it.
        let beforeHours = hourly.filter { inBefore($0.hour) && ($0.macOS == nil || $0.macOS == from) }
        let afterHours = hourly.filter { inAfter($0.hour) && ($0.macOS == nil || $0.macOS == to) }
        let usable = speedTests.filter { $0.networkChanged != true }
        let beforeTests = usable.filter { inBefore($0.result.date) && ($0.macOS == nil || $0.macOS == from) }
        let afterTests = usable.filter { inAfter($0.result.date) && ($0.macOS == nil || $0.macOS == to) }

        // The network: one with something on both sides, the one asked for first.
        func weight(_ key: String) -> (Int, Int) {
            let hours = min(beforeHours.filter { $0.networkKey == key }.count, afterHours.filter { $0.networkKey == key }.count)
            let tests = min(beforeTests.filter { $0.networkKey == key }.count, afterTests.filter { $0.networkKey == key }.count)
            return (hours, tests)
        }
        func usableKey(_ key: String) -> Bool { let w = weight(key); return w.0 >= minimumHours || w.1 >= 1 }
        let keys = Set(beforeHours.map(\.networkKey) + afterHours.map(\.networkKey) + beforeTests.map(\.networkKey) + afterTests.map(\.networkKey)).filter { $0 != "unknown" }
        let key = preferred.flatMap { usableKey($0) ? $0 : nil }
            ?? keys.filter(usableKey).max { let a = weight($0), b = weight($1); return (a.0 + a.1 * 24, $0) < (b.0 + b.1 * 24, $1) }
        let name = key.flatMap { key in (afterHours + beforeHours).last { $0.networkKey == key }?.networkName ?? (afterTests + beforeTests).last { $0.networkKey == key }?.networkName }

        // Tests on the kind of link most of the after tests ran on, so Wi-Fi isn't set against Ethernet.
        let kinds = afterTests.filter { $0.networkKey == key }.compactMap { $0.result.context?.kind }
        let kind = Dictionary(grouping: kinds) { $0 }.max { $0.value.count < $1.value.count }?.key
        func tests(_ list: [SavedSpeedTest]) -> [SavedSpeedTest] {
            list.filter { $0.networkKey == key && (kind == nil || $0.result.context?.kind == nil || $0.result.context?.kind == kind) }
        }
        let drops = events.filter { $0.kind == "Unreachable" && key != nil && $0.networkKey == key }
        func side(_ version: String, _ hours: [HourlyCheck], _ tests: [SavedSpeedTest], _ inside: (Date) -> Bool) -> Side {
            let hours = hours.filter { $0.networkKey == key }
            let count = drops.filter { inside($0.start) }.count
            let covered = Double(hours.count) / 24
            return Side(version: version, hours: hours.count,
                        internetMs: SupportReport.median(hours.compactMap(\.internetMs)), routerMs: SupportReport.median(hours.compactMap(\.routerMs)),
                        dnsMs: SupportReport.median(hours.compactMap(\.dnsMs)), lossPercent: SupportReport.mean(hours.compactMap(\.lossPercent)),
                        drops: count, dropsPerDay: hours.count >= minimumHours ? Double(count) / max(1, covered) : nil,
                        speedTests: tests.count, downloadMbps: SupportReport.median(tests.map(\.result.downloadMbps)), uploadMbps: SupportReport.median(tests.map(\.result.uploadMbps)))
        }
        let before = side(from, beforeHours, tests(beforeTests), inBefore), after = side(to, afterHours, tests(afterTests), inAfter)
        return MacOSUpgradeComparison(from: from, to: to, upgraded: pivot, days: days, networkKey: key, networkName: name,
                                      before: before, after: after, changes: changes(before, after))
    }

    /// Hours of checks a side needs before its latency, DNS, loss and drops count.
    public static let minimumHours = 6

    /// What moved by enough to mention. Lower is better for all but speed.
    static func changes(_ before: Side, _ after: Side) -> [Change] {
        var result: [Change] = []
        func add(_ metric: Change.Metric, _ a: Double?, _ b: Double?, worse: (Double, Double) -> Bool, better: (Double, Double) -> Bool) {
            guard let a, let b else { return }
            result.append(Change(metric: metric, before: a, after: b, worse: worse(a, b), better: better(a, b)))
        }
        if before.speedTests > 0 && after.speedTests > 0 {
            add(.download, before.downloadMbps, after.downloadMbps, worse: { b, a in a < b * 0.75 }, better: { b, a in a > b * 1.25 })
            add(.upload, before.uploadMbps, after.uploadMbps, worse: { b, a in a < b * 0.75 }, better: { b, a in a > b * 1.25 })
        }
        if before.hours >= minimumHours && after.hours >= minimumHours {
            add(.latency, before.internetMs, after.internetMs, worse: { b, a in a > b * 1.3 && a - b >= 10 }, better: { b, a in a < b / 1.3 && b - a >= 10 })
            add(.router, before.routerMs, after.routerMs, worse: { b, a in a > b * 1.5 && a - b >= 5 }, better: { b, a in a < b / 1.5 && b - a >= 5 })
            add(.dns, before.dnsMs, after.dnsMs, worse: { b, a in a > b * 1.5 && a - b >= 20 }, better: { b, a in a < b / 1.5 && b - a >= 20 })
            add(.loss, before.lossPercent, after.lossPercent, worse: { b, a in a - b >= 2 }, better: { b, a in b - a >= 2 })
            add(.drops, before.dropsPerDay, after.dropsPerDay, worse: { b, a in a - b >= 0.5 && after.drops >= 2 }, better: { b, a in b - a >= 0.5 && before.drops >= 2 })
        }
        return result
    }

    /// The report and the CLI name no network.
    public var withoutNetwork: MacOSUpgradeComparison {
        var copy = self; copy.networkKey = nil; copy.networkName = nil; return copy
    }

    // MARK: Words

    public static func value(_ metric: Change.Metric, _ value: Double) -> String {
        switch metric {
        case .download, .upload: SupportReport.mbps(value)
        case .latency, .router, .dns: SupportReport.ms(value)
        case .loss: String(format: "%.1f%%", locale: Locale.current, value)
        case .drops: String(localized: "\(String(format: "%.1f", locale: Locale.current, value)) a day", comment: "Internet drops per day, such as 0.5 a day")
        }
    }
    public static func label(_ metric: Change.Metric) -> String {
        switch metric {
        case .download: String(localized: "Download", comment: "Before and after a macOS upgrade: median speed-test download")
        case .upload: String(localized: "Upload", comment: "Before and after a macOS upgrade: median speed-test upload")
        case .latency: String(localized: "Internet latency", comment: "Before and after a macOS upgrade: median ping to the internet")
        case .router: String(localized: "Router latency", comment: "Before and after a macOS upgrade: median ping to the router")
        case .dns: String(localized: "DNS lookups", comment: "Before and after a macOS upgrade: median time to look up a name")
        case .loss: String(localized: "Packet loss", comment: "Before and after a macOS upgrade: share of pings with no reply")
        case .drops: String(localized: "Drops", comment: "Before and after a macOS upgrade: times the internet was unreachable, per day")
        }
    }

    /// "download 480 Mbps → 120 Mbps", mid-sentence.
    public static func phrase(_ change: Change) -> String {
        let before = value(change.metric, change.before), after = value(change.metric, change.after)
        return switch change.metric {
        case .download: String(localized: "download \(before) → \(after)", comment: "Mid-sentence, after a macOS upgrade: median download before and after")
        case .upload: String(localized: "upload \(before) → \(after)", comment: "Mid-sentence, after a macOS upgrade: median upload before and after")
        case .latency: String(localized: "internet latency \(before) → \(after)", comment: "Mid-sentence, after a macOS upgrade: median internet ping before and after")
        case .router: String(localized: "router latency \(before) → \(after)", comment: "Mid-sentence, after a macOS upgrade: median router ping before and after")
        case .dns: String(localized: "DNS lookups \(before) → \(after)", comment: "Mid-sentence, after a macOS upgrade: median lookup time before and after")
        case .loss: String(localized: "packet loss \(before) → \(after)", comment: "Mid-sentence, after a macOS upgrade: ping loss before and after")
        case .drops: String(localized: "drops \(before) → \(after)", comment: "Mid-sentence, after a macOS upgrade: internet drops per day before and after")
        }
    }

    /// "macOS 27.0 → 27.2"
    public var title: String { String(localized: "macOS \(from) → \(to)", comment: "A macOS upgrade: the version before and after") }

    /// One sentence for Health, the report and the CLI.
    public var summary: String {
        let date = upgraded.formatted(.dateTime.day().month(.abbreviated))
        guard comparable else {
            return String(localized: "Updated to macOS \(to) on \(date). Not enough checks on one network before and after to compare yet.", comment: "Before and after a macOS upgrade; a version and a date")
        }
        let worse = self.worse
        if worse.isEmpty {
            return String(localized: "Updated to macOS \(to) on \(date). Speed, latency, DNS and drops look about the same as on \(from).", comment: "Before and after a macOS upgrade; versions and a date")
        }
        let list = ListFormatter.localizedString(byJoining: worse.map(Self.phrase))
        return String(localized: "Since macOS \(to) on \(date), on the same network: \(list).", comment: "Before and after a macOS upgrade: what got worse, such as “download 480 Mbps → 120 Mbps”")
    }
}
