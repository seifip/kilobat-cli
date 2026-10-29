import Foundation

/// A router's or provider's total for a period set beside what Kilobat recorded on this Mac for the same period,
/// networks and direction, with the hours it actually recorded and the usual reasons two counters differ.
/// It explains a difference; it never decides which counter is right.
public struct UsageComparison: Codable, Equatable, Sendable {
    public enum Direction: String, Codable, CaseIterable, Identifiable, Sendable {
        case download, upload, both
        public var id: String { rawValue }
        public var title: String { switch self { case .download: "Download"; case .upload: "Upload"; case .both: "Both ways" } }
        public func bytes(received: UInt64, sent: UInt64) -> UInt64 { switch self { case .download: received; case .upload: sent; case .both: received + sent } }
    }

    /// Decimal units count in thousands (1 GB = 1,000,000,000 bytes), binary ones in 1,024s (1 GiB = 1,073,741,824 bytes).
    public enum Unit: String, Codable, CaseIterable, Identifiable, Sendable {
        case b = "B", kb = "KB", mb = "MB", gb = "GB", tb = "TB", kib = "KiB", mib = "MiB", gib = "GiB", tib = "TiB"
        public var id: String { rawValue }
        public var binary: Bool { rawValue.contains("i") }
        public var size: Double {
            switch self {
            case .b: 1; case .kb: 1e3; case .mb: 1e6; case .gb: 1e9; case .tb: 1e12
            case .kib: 1_024; case .mib: 1_048_576; case .gib: 1_073_741_824; case .tib: 1_099_511_627_776
            }
        }
        /// The same prefix in the other system. Providers and routers often write GB for either.
        public var counterpart: Unit? {
            switch self { case .b: nil; case .kb: .kib; case .mb: .mib; case .gb: .gib; case .tb: .tib; case .kib: .kb; case .mib: .mb; case .gib: .gb; case .tib: .tb }
        }
        public static func named(_ text: String) -> Unit? {
            let name = text.trimmingCharacters(in: .whitespaces).lowercased()
            return allCases.first { $0.rawValue.lowercased() == name } ?? (["byte", "bytes"].contains(name) ? .b : nil)
        }
    }

    public enum GapReason: String, Codable, Sendable {
        /// Before the oldest sample Kilobat keeps.
        case beforeHistory
        /// The Mac was recorded on a network outside the comparison.
        case otherNetwork
        /// The Mac was asleep for most of the hour.
        case asleep
        /// Nothing recorded: off, offline, Kilobat not running, or nothing used the network; asleep before 1.3.
        case notRecorded
        /// Later than now.
        case notYet
        public var title: String {
            switch self { case .beforeHistory: "Before history"; case .otherNetwork: "Other network"; case .asleep: "Asleep"; case .notRecorded: "Nothing recorded"; case .notYet: "Not yet" }
        }
    }
    public struct Gap: Codable, Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let hours: Double
        public let reason: GapReason
        public let detail: String
    }
    public struct Network: Codable, Equatable, Sendable {
        public let key: String
        public let name: String
        /// Bytes in the comparison's direction during the period.
        public let bytes: UInt64
        public let counted: Bool
    }
    public struct App: Codable, Equatable, Sendable { public let name: String; public let bytes: UInt64 }
    public struct Reason: Codable, Equatable, Sendable { public let id: String; public let text: String }

    /// Ready-made periods; a provider's billing cycle is usually a custom one.
    public enum Preset: String, CaseIterable, Identifiable, Sendable {
        case last24Hours = "last-24-hours", today, yesterday, last7Days = "last-7-days", thisMonth = "this-month", lastMonth = "last-month"
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .last24Hours: "Last 24 hours"; case .today: "Today"; case .yesterday: "Yesterday"
            case .last7Days: "Last 7 days"; case .thisMonth: "This month"; case .lastMonth: "Last month"
            }
        }
        public func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
            let today = calendar.startOfDay(for: now)
            func days(_ count: Int, from date: Date) -> Date { calendar.date(byAdding: .day, value: count, to: date) ?? date }
            let month = calendar.dateInterval(of: .month, for: now) ?? DateInterval(start: today, end: now)
            switch self {
            case .last24Hours: return DateInterval(start: now.addingTimeInterval(-86_400), end: now)
            case .today: return DateInterval(start: today, end: days(1, from: today))
            case .yesterday: return DateInterval(start: days(-1, from: today), end: today)
            case .last7Days: return DateInterval(start: days(-6, from: today), end: days(1, from: today))
            case .thisMonth: return month
            case .lastMonth: return calendar.dateInterval(of: .month, for: month.start.addingTimeInterval(-1)) ?? month
            }
        }
    }

    public let start: Date
    public let end: Date
    public let timeZone: String
    public let direction: Direction
    public let unit: Unit
    /// The router's or provider's figure as entered, and in bytes.
    public let externalAmount: Double
    public let externalBytes: UInt64
    /// The same figure read in the other unit system, for when "GB" meant GiB or the other way round.
    public let alternateUnit: Unit?
    public let alternateBytes: UInt64?
    public let allNetworks: Bool
    /// Every network with traffic in the period, and each one chosen, with whether it's counted.
    public let networks: [Network]
    /// Internet bytes on the counted networks; `kilobatBytes` is the chosen direction of them.
    public let downloadBytes: UInt64
    public let uploadBytes: UInt64
    public let kilobatBytes: UInt64
    public let kilobatAmount: Double
    /// Local network and AirDrop bytes, both ways, which Kilobat keeps out of its total.
    public let localBytes: UInt64
    /// Bytes no app accounts for, packet headers included, both ways; already part of Kilobat's total.
    public let unattributedBytes: UInt64
    /// This Mac's bytes on networks left out of the comparison.
    public let otherNetworkBytes: UInt64
    /// The router's or provider's total minus Kilobat's.
    public let differenceBytes: Int64
    public let differenceAmount: Double
    /// The difference as a share of the router's or provider's total; nil when that total is zero.
    public let differencePercent: Double?
    /// Hours from the start to now or the end, whichever is first, and the hours with Kilobat samples on a counted network.
    public let periodHours: Double
    public let recordedHours: Double
    /// Recorded hours as a share of the period so far, 0–1.
    public let coverage: Double
    public let gaps: [Gap]
    public let topApps: [App]
    public private(set) var summary = ""
    public private(set) var reasons: [Reason] = []

    /// "all networks", or the counted networks' names, each once.
    public var scopeName: String { allNetworks ? "all networks" : Self.list(networks.filter(\.counted).map(\.name)) }
    /// Names each once, the first four and how many more.
    static func list(_ names: [String]) -> String {
        var seen = Set<String>(), unique = names.filter { seen.insert($0).inserted }
        if unique.count > 4 { unique = Array(unique.prefix(4)) + ["\(unique.count - 4) more"] }
        return unique.count > 1 ? unique.dropLast().joined(separator: ", ") + " and " + unique[unique.count - 1] : unique.first ?? "no network"
    }
    /// Bytes in the comparison's unit, "31.2 GB".
    public func amount(_ bytes: UInt64) -> String { Text().amount(Double(bytes) / unit.size, unit) }
    public var agrees: Bool { Double(differenceBytes.magnitude) <= 0.05 * Double(max(externalBytes, kilobatBytes)) }

    /// Compares `total` (in `unit`, counting `direction`) with the usage history recorded in `period` on the networks in
    /// `scope` (nil for all of them). `names` maps network keys to names. `monitoringScope` is the traffic scope setting.
    /// `sleeps` are the times the Mac slept, which turn an empty hour into an asleep one.
    public static func make(_ usage: [UsageEntry], period: DateInterval, scope: Set<String>?, names: [String: String] = [:],
                            total: Double, unit: Unit, direction: Direction, monitoringScope: String? = nil, sleeps: [DateInterval] = [],
                            now: Date = Date(), calendar: Calendar = .current) -> UsageComparison {
        let start = period.start, end = period.end, until = min(end, max(start, now))
        func counted(_ entry: UsageEntry) -> Bool { scope.map { entry.networkKey.map($0.contains) ?? false } ?? true }
        func name(_ key: String?) -> String { key.flatMap { names[$0] } ?? (key == nil ? "Network not recorded" : "Unnamed network") }

        var received: UInt64 = 0, sent: UInt64 = 0, local: UInt64 = 0, unattributed: UInt64 = 0, appsOnly = 0
        var perNetwork: [String: UInt64] = [:], apps: [String: UInt64] = [:]
        for entry in usage where entry.date >= start && entry.date < end {
            perNetwork[entry.networkKey ?? "", default: 0] += direction.bytes(received: entry.received, sent: entry.sent)
            guard counted(entry) else { continue }
            received += entry.received; sent += entry.sent
            local += entry.localBytes ?? 0; unattributed += entry.unattributed ?? 0
            if entry.unattributed == nil { appsOnly += 1 }
            let up = entry.estimatedSent
            for (app, bytes) in entry.apps where bytes > 0 {
                let appSent = min(bytes, up[app] ?? 0)
                apps[app, default: 0] += direction.bytes(received: bytes - appSent, sent: appSent)
            }
        }
        let keys: Set<String> = Set(perNetwork.keys).union(scope ?? [])
        let networks: [Network] = keys.map { key in
            Network(key: key, name: name(key.isEmpty ? nil : key), bytes: perNetwork[key] ?? 0, counted: scope?.contains(key) ?? true)
        }.sorted { (a: Network, b: Network) -> Bool in
            if a.counted != b.counted { return a.counted }
            return a.bytes != b.bytes ? a.bytes > b.bytes : a.name < b.name
        }
        let kilobat = direction.bytes(received: received, sent: sent)
        let otherBytes = networks.filter { !$0.counted }.reduce(0) { $0 + $1.bytes }

        // Coverage by the hour. History older than a day is kept in hourly totals, and older than 30 days in daily
        // ones dated at midnight; those cover their whole day.
        let daily = now.addingTimeInterval(-30 * 86_400)
        var hours = Set<Date>(), days = Set<Date>(), otherHours: [Date: Set<String>] = [:], otherDays: [Date: Set<String>] = [:]
        for entry in usage where entry.date >= start.addingTimeInterval(-2 * 86_400) && entry.date < end.addingTimeInterval(2 * 86_400) {
            let day = calendar.startOfDay(for: entry.date), wholeDay = entry.date < daily && entry.date == day
            let key = wholeDay ? day : calendar.dateInterval(of: .hour, for: entry.date)?.start ?? entry.date
            if counted(entry) { if wholeDay { days.insert(key) } else { hours.insert(key) } }
            else if wholeDay { otherDays[key, default: []].insert(name(entry.networkKey)) }
            else { otherHours[key, default: []].insert(name(entry.networkKey)) }
        }
        let historyStart = usage.map(\.date).min()
        var recorded = 0.0, gaps: [(start: Date, end: Date, reason: GapReason, networks: Set<String>)] = []
        var cursor = calendar.dateInterval(of: .hour, for: start)?.start ?? start
        while cursor < until {
            let next = calendar.dateInterval(of: .hour, for: cursor)?.end ?? cursor.addingTimeInterval(3_600)
            let slot = DateInterval(start: max(cursor, start), end: min(next, until)), day = calendar.startOfDay(for: cursor)
            defer { cursor = next }
            if hours.contains(cursor) || days.contains(day) { recorded += slot.duration; continue }
            let others = (otherHours[cursor] ?? []).union(otherDays[day] ?? [])
            let asleep = sleeps.reduce(0.0) { $0 + ($1.intersection(with: slot)?.duration ?? 0) } * 2 >= slot.duration
            let reason: GapReason = !others.isEmpty ? .otherNetwork : (historyStart.map { slot.end <= $0 } ?? true) ? .beforeHistory : asleep ? .asleep : .notRecorded
            if let last = gaps.last, last.reason == reason, last.end == slot.start { gaps[gaps.count - 1] = (last.start, slot.end, reason, last.networks.union(others)) }
            else { gaps.append((slot.start, slot.end, reason, others)) }
        }
        if end > until { gaps.append((until, end, .notYet, [])) }
        let text = Text(calendar: calendar)
        let gapList = gaps.map { gap -> Gap in
            let detail: String
            switch gap.reason {
            case .beforeHistory: detail = "Before Kilobat's history starts: it wasn't recording yet, or the history setting has since removed it"
            case .otherNetwork: detail = "On another network: " + list(gap.networks.sorted())
            case .asleep: detail = "The Mac was asleep"
            case .notRecorded: detail = sleeps.isEmpty ? "Nothing recorded: the Mac was asleep, off or offline, Kilobat wasn't running, or nothing used the network"
                : "Nothing recorded and not asleep: the Mac was off or offline, Kilobat wasn't running, or nothing used the network"
            case .notYet: detail = "Hasn't happened yet"
            }
            return Gap(start: gap.start, end: gap.end, hours: gap.end.timeIntervalSince(gap.start) / 3_600, reason: gap.reason, detail: detail)
        }

        func bytes(_ unit: Unit) -> UInt64 { UInt64(min(9e18, max(0, (total * unit.size).rounded()))) }
        let externalBytes = bytes(unit), alternate = unit.counterpart.map(bytes)
        let difference = Int64(clamping: externalBytes) - Int64(clamping: kilobat)
        let comparison = UsageComparison(
            start: start, end: end, timeZone: calendar.timeZone.identifier, direction: direction, unit: unit,
            externalAmount: total, externalBytes: externalBytes, alternateUnit: unit.counterpart, alternateBytes: alternate,
            allNetworks: scope == nil, networks: networks, downloadBytes: received, uploadBytes: sent, kilobatBytes: kilobat,
            kilobatAmount: Double(kilobat) / unit.size, localBytes: local, unattributedBytes: unattributed, otherNetworkBytes: otherBytes,
            differenceBytes: difference, differenceAmount: Double(difference) / unit.size,
            differencePercent: externalBytes > 0 ? Double(difference) / Double(externalBytes) * 100 : nil,
            periodHours: until.timeIntervalSince(start) / 3_600, recordedHours: recorded / 3_600, coverage: until > start ? min(1, recorded / until.timeIntervalSince(start)) : 0, gaps: gapList,
            topApps: apps.filter { $0.value > 0 }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(5).map { App(name: $0.key, bytes: $0.value) })
        return comparison.explained(text: text, appsOnly: appsOnly, monitoringScope: monitoringScope, sleepsKnown: !sleeps.isEmpty, now: now, calendar: calendar)
    }

    /// The headline and the likely reasons, most likely first for the direction of the difference.
    private func explained(text: Text, appsOnly: Int, monitoringScope: String?, sleepsKnown: Bool, now: Date, calendar: Calendar) -> UsageComparison {
        func amount(_ bytes: UInt64) -> String { text.amount(Double(bytes) / unit.size, unit) }
        let kilobatLower = differenceBytes > 0
        let directionName = direction == .both ? "download and upload" : direction.rawValue
        var reasons: [Reason] = []
        func add(_ id: String, _ text: String) { reasons.append(Reason(id: id, text: text)) }

        let gapHours = periodHours - recordedHours
        func coverageReason() {
            guard gapHours >= 0.5 else { return }
            var parts: [String] = []
            for (reason, label) in [(GapReason.asleep, "asleep"), (.notRecorded, sleepsKnown ? "with nothing recorded (off, offline or Kilobat not running)" : "with nothing recorded (asleep, off, offline or Kilobat not running)"),
                                    (.otherNetwork, "on other networks"), (.beforeHistory, "before Kilobat's history starts")] {
                let hours = gaps.filter { $0.reason == reason }.reduce(0) { $0 + $1.hours }
                if hours >= 0.5 { parts.append("\(text.hours(hours)) hour\(text.hours(hours) == "1" ? "" : "s") \(label)") }
            }
            add("coverage", "Kilobat recorded \(text.hours(recordedHours)) of the period's \(text.hours(periodHours)) hours. Missing: \(parts.joined(separator: ", ")). Anything this Mac used then isn't in Kilobat's total.")
        }
        func directionReason() {
            // Only the reading that moves the figure toward Kilobat's.
            guard kilobatLower == (direction != .both) else { return }
            if direction == .both { add("direction", "If the figure counts only downloads, Kilobat's download total is \(amount(downloadBytes)); uploads only, \(amount(uploadBytes)).") }
            else { add("direction", "Many providers and routers count download and upload together. Both ways, Kilobat recorded \(amount(downloadBytes + uploadBytes)).") }
        }
        let other = alternateBytes.map { Int64(clamping: $0) - Int64(clamping: kilobatBytes) }
        // Reading the figure in the other unit system takes away at least half the difference.
        let unitsExplain = other.map { $0.magnitude * 2 <= differenceBytes.magnitude } ?? false
        func unitReason() {
            guard let alternateUnit, let alternateBytes, let other else { return }
            let sizes = "1 \(unit.rawValue) is \(text.count(unit.size)) bytes and 1 \(alternateUnit.rawValue) is \(text.count(alternateUnit.size))"
            if other.magnitude < differenceBytes.magnitude {
                add("units", "Providers and routers often write GB for either unit. If the figure means \(text.amount(externalAmount, alternateUnit)), that's \(text.amount(Double(alternateBytes) / unit.size, unit)), \(amount(other.magnitude)) \(other >= 0 ? "above" : "below") Kilobat's total; \(sizes).")
            } else { add("units", "In \(alternateUnit.rawValue), Kilobat's total is \(text.amount(Double(kilobatBytes) / alternateUnit.size, alternateUnit)); \(sizes).") }
        }
        func networksReason() {
            if !allNetworks, otherNetworkBytes > 0 {
                let others = networks.filter { !$0.counted && $0.bytes > 0 }.map(\.name)
                add("otherNetworks", "This Mac also used \(amount(otherNetworkBytes)) on \(Self.list(others)) in this period, not counted here. Add a network if the same plan or router covers it.")
            }
            let named = Dictionary(grouping: networks, by: \.name).filter { $0.value.contains(where: \.counted) && $0.value.contains { !$0.counted } }
            for (name, list) in named.sorted(by: { $0.key < $1.key }) {
                add("sameName", "\(list.count) recorded networks are named \(name), told apart by their router or interface, and not all are counted. Check that the comparison counts the ones the figure covers.")
            }
            if allNetworks, networks.filter({ $0.bytes > 0 }).count > 1 {
                add("allNetworks", "Kilobat's total covers \(networks.filter { $0.bytes > 0 }.count) networks. Pick the one the provider or router covers.")
            }
        }
        func countingReasons() {
            if localBytes > 0 { add("local", "\(amount(localBytes)) went to devices on the same network and AirDrop. It never reached the Internet, so Kilobat leaves it out; a provider doesn't see it either, but a router's per-device counter may count it.") }
            if let monitoringScope, monitoringScope != "external" { add("monitoringScope", "Kilobat is set to count \(monitoringScope == "wifi" ? "Wi-Fi" : "wired connections") only, so this Mac's traffic over the other isn't in its total.") }
            if appsOnly > 0 { add("appsOnly", "Part of this period was recorded before Kilobat 1.3 or without interface counters, when totals came from apps alone and left out packet headers.") }
            let headers = unattributedBytes > 0 ? "Kilobat's total includes \(amount(unattributedBytes)) of unattributed traffic, mostly packet headers and acknowledgments. " : ""
            add("overhead", headers + "Each counter measures at its own point and adds its own overhead, such as VPN, PPPoE or cellular framing, so a few percent apart is normal.")
        }
        func timingReason() {
            add("timing", "Providers often count days in UTC or their own time zone and can post usage hours late. This comparison runs \(text.date(start)) to \(text.date(end)), \(timeZone).")
            if let change = calendar.timeZone.nextDaylightSavingTimeTransition(after: start), change < end {
                add("clockChange", "The clocks changed on \(text.date(change)), so this period is \(text.hours(end.timeIntervalSince(start) / 3_600)) hours long. Check that the provider's period follows the same clock.")
            }
            if end > now { add("notYet", "The period isn't over: Kilobat counts up to now, while the figure may cover the whole period or lag behind.") }
            let hourly = now.addingTimeInterval(-86_400), cut = { (date: Date) in date < hourly && calendar.dateInterval(of: .hour, for: date)?.start != date }
            if cut(start) || cut(end) { add("boundary", "History older than a day is kept in hourly totals (daily after 30 days), so an hour that straddles the start or end counts by when it began.") }
        }

        let summary: String
        let both = "Kilobat recorded \(amount(kilobatBytes)) of \(directionName) on \(scopeName)"
        if agrees {
            summary = "\(both); the figure you entered is \(text.amount(externalAmount, unit)). They're within 5%."
            add("close", "Counters at different points add different overhead, so within 5% is about as close as two of them get.")
            coverageReason(); directionReason(); unitReason(); timingReason(); networksReason(); countingReasons()
        } else if kilobatLower {
            summary = "\(both), \(amount(differenceBytes.magnitude)) less than the \(text.amount(externalAmount, unit)) you entered" + (differencePercent.map { " (\(text.percent($0)))." } ?? ".")
            coverageReason()
            if unitsExplain { unitReason() }
            add("otherDevices", "A router or provider total covers every device on the network, such as phones, TVs, consoles and other computers. Kilobat measures only this Mac.")
            directionReason(); networksReason()
            if !unitsExplain { unitReason() }
            countingReasons(); timingReason()
        } else {
            summary = "\(both), \(amount(differenceBytes.magnitude)) more than the \(text.amount(externalAmount, unit)) you entered" + (differencePercent.map { " (\(text.percent(-$0)))." } ?? ".")
            if unitsExplain { unitReason() }
            directionReason(); timingReason()
            add("planRules", "Some plans leave traffic out of their count, such as off-peak hours, zero-rated apps or the provider's own services.")
            networksReason()
            if !unitsExplain { unitReason() }
            countingReasons(); coverageReason()
        }
        var copy = self
        copy.summary = summary; copy.reasons = reasons
        return copy
    }

    /// JSON for a provider or router support team: dates carry the comparison's own time zone offset.
    public func json(pretty: Bool = true) throws -> Data {
        let encoder = JSONEncoder(), zone = TimeZone(identifier: timeZone) ?? .current
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter(); formatter.timeZone = zone
            var container = encoder.singleValueContainer(); try container.encode(formatter.string(from: date))
        }
        return try encoder.encode(self)
    }

    /// One table a spreadsheet can read: the period, scope, both totals, coverage, every gap, network, top app and reason.
    public func csv() -> String {
        let formatter = ISO8601DateFormatter(); formatter.timeZone = TimeZone(identifier: timeZone) ?? .current
        func field(_ value: String) -> String { value.contains(where: { ",\"\n".contains($0) }) ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value }
        func number(_ value: Double) -> String { String(format: "%.4f", value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) }
        var rows: [[String]] = [["kind", "name", "value", "unit", "start", "end", "hours", "detail"]]
        rows.append(["period", "comparison", "", "", formatter.string(from: start), formatter.string(from: end), number(periodHours), timeZone])
        rows.append(["scope", "networks", allNetworks ? "all" : networks.filter(\.counted).map(\.name).joined(separator: "; "), "", "", "", "", direction.rawValue])
        rows.append(["external", "total", number(externalAmount), unit.rawValue, "", "", "", "Router or provider figure as entered"])
        rows.append(["external", "total", String(externalBytes), "B", "", "", "", ""])
        if let alternateUnit, let alternateBytes { rows.append(["external", "if \(alternateUnit.rawValue)", String(alternateBytes), "B", "", "", "", "The same figure read as \(alternateUnit.rawValue)"]) }
        rows.append(["kilobat", "total", number(kilobatAmount), unit.rawValue, "", "", "", "Internet bytes, \(direction.rawValue)"])
        rows.append(["kilobat", "total", String(kilobatBytes), "B", "", "", "", ""])
        rows.append(["kilobat", "download", String(downloadBytes), "B", "", "", "", ""])
        rows.append(["kilobat", "upload", String(uploadBytes), "B", "", "", "", ""])
        rows.append(["kilobat", "unattributed", String(unattributedBytes), "B", "", "", "", "Packet headers and bytes no app accounts for; included in the total"])
        rows.append(["kilobat", "local", String(localBytes), "B", "", "", "", "Local network and AirDrop; not included"])
        rows.append(["kilobat", "other networks", String(otherNetworkBytes), "B", "", "", "", "This Mac on networks outside the comparison; not included"])
        rows.append(["difference", "external minus kilobat", String(differenceBytes), "B", "", "", "", differencePercent.map { number($0) + "% of the external total" } ?? ""])
        rows.append(["coverage", "recorded", number(recordedHours), "hours", "", "", number(periodHours), number(coverage * 100) + "% of the period so far"])
        for gap in gaps { rows.append(["gap", gap.reason.rawValue, "", "", formatter.string(from: gap.start), formatter.string(from: gap.end), number(gap.hours), gap.detail]) }
        for network in networks { rows.append(["network", network.name, String(network.bytes), "B", "", "", "", (network.counted ? "counted" : "not counted") + " · " + network.key]) }
        for app in topApps { rows.append(["app", app.name, String(app.bytes), "B", "", "", "", ""]) }
        for reason in reasons { rows.append(["reason", reason.id, "", "", "", "", "", reason.text]) }
        return rows.map { $0.map(field).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// A name for every network in the history: its saved name, or the start of its key once it's no longer saved.
    public static func networkNames(_ usage: [UsageEntry], sessions: [String: NetworkSession]) -> [String: String] {
        var names: [String: String] = [:]
        for key in Set(usage.compactMap(\.networkKey)) { names[key] = "Network " + key.prefix(6) }
        for (key, session) in sessions { names[key] = session.name }
        if names["unknown"] != nil { names["unknown"] = "Network not identified" }
        return names
    }

    /// "40GB", "40 GiB", "1.5 TB" or a bare number; a single comma is read as a decimal comma.
    public static func total(_ text: String) -> (amount: Double, unit: Unit?)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix { $0.isNumber || $0 == "." || $0 == "," }
        var number = String(digits).replacingOccurrences(of: "_", with: "")
        number = number.contains(".") ? number.replacingOccurrences(of: ",", with: "") : number.filter { $0 == "," }.count == 1 ? number.replacingOccurrences(of: ",", with: ".") : number
        guard let amount = Double(number), amount.isFinite, amount >= 0, amount * 1_099_511_627_776 < 9e18 else { return nil }
        let rest = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        if rest.isEmpty { return (amount, nil) }
        guard let unit = Unit.named(rest) else { return nil }
        return (amount, unit)
    }

    /// "2026-10-01" is that day's midnight, or for the end of a period the next midnight, so "1 to 31 October" reads as
    /// written. "2026-10-01 18:30" is local time; ISO 8601 with Z or an offset is exact.
    public static func date(_ text: String, end: Bool = false, calendar: Calendar = .current) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.isLenient = false
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: text) else { return nil }
        return end ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) : calendar.startOfDay(for: day)
    }

    /// Formatting in plain English, independent of the Mac's locale so exports read the same everywhere.
    public struct Text: Sendable {
        public let calendar: Calendar
        public init(calendar: Calendar = .current) { self.calendar = calendar }
        public func amount(_ value: Double, _ unit: Unit) -> String {
            value.formatted(.number.precision(.fractionLength(0...(abs(value) < 10 ? 2 : 1))).locale(Locale(identifier: "en_US"))) + " " + unit.rawValue
        }
        public func count(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0)).locale(Locale(identifier: "en_US"))) }
        public func hours(_ value: Double) -> String {
            value.formatted(.number.precision(.fractionLength(0...(value < 10 ? 1 : 0))).locale(Locale(identifier: "en_US")))
        }
        public func percent(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0)).locale(Locale(identifier: "en_US"))) + "%" }
        public func date(_ value: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "d MMM yyyy HH:mm"
            return formatter.string(from: value)
        }
    }
}
