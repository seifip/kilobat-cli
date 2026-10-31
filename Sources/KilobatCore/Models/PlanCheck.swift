import Foundation

/// The download speed each network's plan promises, kept per network on this Mac. `speed.planMbps` is the older
/// single plan for every network: it still fills in where a network has none, but never starts scheduled checks.
public enum PlanSpeeds {
    public static let key = "speed.plans"
    public static let legacyKey = "speed.planMbps"

    /// Plans set for a network, by `networkKey`.
    public static func all(_ defaults: UserDefaults = .standard) -> [String: Double] {
        (defaults.dictionary(forKey: key) ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }.filter { $0.value > 0 && $0.value.isFinite }
    }
    /// The plan set for this network itself.
    public static func explicit(for network: String?, _ defaults: UserDefaults = .standard) -> Double? {
        guard let network, network != "unknown" else { return nil }
        return all(defaults)[network]
    }
    /// This network's plan, or the single plan from before plans were per network.
    public static func plan(for network: String?, _ defaults: UserDefaults = .standard) -> Double? {
        if let plan = explicit(for: network, defaults) { return plan }
        let legacy = defaults.double(forKey: legacyKey)
        return legacy > 0 && legacy.isFinite ? legacy : nil
    }
    /// Sets or clears this network's plan. The single plan follows the newest one, for older readers of it.
    public static func set(_ mbps: Double?, for network: String, _ defaults: UserDefaults = .standard) {
        guard network != "unknown" else { return }
        var plans = all(defaults)
        if let mbps, mbps > 0, mbps.isFinite, mbps <= 100_000 { plans[network] = mbps; defaults.set(mbps, forKey: legacyKey) }
        else { plans.removeValue(forKey: network) }
        defaults.set(plans, forKey: key)
    }
}

/// Light speed tests now and then, while the Mac is otherwise quiet, to compare a network with the plan it pays for.
/// At most three a day per network, at most one per part of the day and three hours apart, starting at a different
/// minute each day, and with the last of the three kept for the evening peak. Never on a metered network, through a
/// VPN, during a call, under other traffic or on a low battery.
public enum PlanCheck {
    public static let enabledKey = "speed.planCheck"
    public static let perDay = 3
    public static let gap: TimeInterval = 3 * 3600
    /// How long traffic must stay under `quietRate` first.
    public static let quietFor: TimeInterval = 120
    /// Battery charge needed when the Mac isn't on its power adapter.
    public static let batteryFloor = 50
    /// The evening peak: 7 to 11 pm local time, the busy hours broadband regulators measure.
    public static let peakHours = 19..<23

    public enum Daypart: String, Codable, Sendable, CaseIterable {
        /// 11 pm to 6 am.
        case night
        /// 6 am to noon.
        case morning
        /// Noon to 7 pm.
        case afternoon
        /// 7 to 11 pm, the peak.
        case evening
    }

    /// What decides whether a check may run now.
    public struct Moment: Sendable {
        public var enabled: Bool
        /// The current network's `networkKey`.
        public var network: String?
        /// The plan set for this network itself.
        public var planMbps: Double?
        public var connected: Bool
        public var metered: Bool
        /// The default route leaves through a VPN, which would measure the VPN rather than the plan.
        public var vpn: Bool
        public var call: Bool
        /// Asleep, or a speed test already running.
        public var busy: Bool
        /// How long this Mac's traffic has stayed under `quietRate`.
        public var quietSeconds: TimeInterval
        public var onAC: Bool
        public var batteryPercent: Int?
        public var lowPowerMode: Bool
        public init(enabled: Bool, network: String?, planMbps: Double?, connected: Bool, metered: Bool, vpn: Bool, call: Bool, busy: Bool,
                    quietSeconds: TimeInterval, onAC: Bool, batteryPercent: Int?, lowPowerMode: Bool) {
            self.enabled = enabled; self.network = network; self.planMbps = planMbps; self.connected = connected; self.metered = metered
            self.vpn = vpn; self.call = call; self.busy = busy; self.quietSeconds = quietSeconds
            self.onAC = onAC; self.batteryPercent = batteryPercent; self.lowPowerMode = lowPowerMode
        }
    }

    /// Why a check isn't running now, schedule first, then the Mac's state.
    public enum Wait: String, Codable, Sendable {
        case off, network, noPlan, metered
        /// Three checks in the last 24 hours.
        case enough
        /// The last check was under three hours ago.
        case recent
        /// This part of the day already has its check.
        case daypartDone
        /// Today's start time in this part of the day hasn't come yet.
        case later
        /// Two checks in the last day and none in the evening: the third waits for the peak.
        case evening
        case busy, call, vpn, traffic, battery
    }

    /// Nil when a check should start now. `history` is every saved test; only scheduled ones on this network count.
    public static func wait(_ moment: Moment, history: [SavedSpeedTest], now: Date = Date(), calendar: Calendar = .current) -> Wait? {
        guard moment.enabled else { return .off }
        guard moment.connected, let network = moment.network, network != "unknown" else { return .network }
        guard let plan = moment.planMbps, plan > 0 else { return .noPlan }
        if moment.metered { return .metered }
        let done = history.filter { $0.scheduled == true && $0.networkKey == network && $0.result.date <= now }.map(\.result.date)
        let lastDay = done.filter { now.timeIntervalSince($0) < 86_400 }
        if lastDay.count >= perDay { return .enough }
        if let last = done.max(), now.timeIntervalSince(last) < gap { return .recent }
        let part = window(containing: now, calendar: calendar)
        if done.contains(where: { part.interval.contains($0) }) { return .daypartDone }
        if now < start(of: part, network: network) { return .later }
        if part.daypart != .evening, lastDay.count >= perDay - 1, !lastDay.contains(where: { daypart($0, calendar: calendar) == .evening }) { return .evening }
        if moment.busy { return .busy }
        if moment.call { return .call }
        if moment.vpn { return .vpn }
        if moment.quietSeconds < quietFor { return .traffic }
        if moment.lowPowerMode || (!moment.onAC && (moment.batteryPercent ?? 100) <= batteryFloor) { return .battery }
        return nil
    }

    /// Traffic this Mac may carry, in bytes per second, and still count as quiet: 5% of the plan, at most 1 MB/s.
    public static func quietRate(planMbps: Double) -> Double { min(1_000_000, max(32_000, planMbps * 1_000_000 / 8 * 0.05)) }

    /// The data limit for one check: about two seconds of download at the plan's speed, so a fast plan isn't cut short
    /// before the connection ramps up, between 25 MB and the 80 MB of a test you start.
    public static func budget(planMbps: Double) -> Int {
        Int(min(80, max(25, planMbps / 3.2)) * 1_000_000)
    }

    public static func daypart(_ date: Date, calendar: Calendar = .current) -> Daypart {
        switch calendar.component(.hour, from: date) {
        case 6..<12: .morning
        case 12..<19: .afternoon
        case 19..<23: .evening
        default: .night
        }
    }

    /// The stretch of the day `date` falls in, such as today 7 to 11 pm, or 11 pm yesterday to 6 am.
    public static func window(containing date: Date, calendar: Calendar = .current) -> (daypart: Daypart, interval: DateInterval) {
        let part = daypart(date, calendar: calendar)
        let midnight = calendar.startOfDay(for: date)
        func at(_ hour: Int, dayOffset: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: midnight) ?? midnight
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
        let (start, end): (Date, Date) = switch part {
        case .morning: (at(6), at(12))
        case .afternoon: (at(12), at(19))
        case .evening: (at(19), at(23))
        case .night: calendar.component(.hour, from: date) >= 23 ? (at(23), at(6, dayOffset: 1)) : (at(23, dayOffset: -1), at(6))
        }
        return (part, DateInterval(start: start, end: max(start, end)))
    }

    /// When checks may start in this part of the day: a different minute each day and network, leaving at least
    /// 90 minutes to find a quiet moment, so the checks don't always land on the hour.
    public static func start(of part: (daypart: Daypart, interval: DateInterval), network: String) -> Date {
        let spread = max(1, Int(part.interval.duration / 60) - 90)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(network)|\(Int(part.interval.start.timeIntervalSince1970))".utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return part.interval.start.addingTimeInterval(Double(Int(hash % UInt64(spread))) * 60)
    }
}

/// A month of speed tests on one network against the plan it pays for: the medians, the evening peak beside the
/// rest of the day, and how often a test got under half the plan. Holds no network name, so the provider report
/// can carry it.
public struct PlanSummary: Codable, Sendable, Equatable {
    public let days: Int
    public let planMbps: Double
    public let checks: Int
    /// True when only scheduled checks were counted; false when there were too few and tests you ran count too.
    public let scheduledOnly: Bool
    public let downloadMedianMbps: Double
    public let uploadMedianMbps: Double
    /// The median download as a percentage of the plan.
    public let percentOfPlan: Double
    public let peakChecks: Int
    public let peakMedianMbps: Double?
    public let offPeakChecks: Int
    public let offPeakMedianMbps: Double?
    /// Percentage of tests that got under half the plan.
    public let underHalfPercent: Double
    public let slowestMbps: Double
    public let fastestMbps: Double
    public let first: Date
    public let last: Date

    /// Scheduled checks count alone once there are this many; until then, every test on the network does.
    public static let enoughScheduled = 3
    public static let window = 30

    /// Nil without a plan or a test on this network in the last `days`.
    public static func make(tests: [SavedSpeedTest], network: String?, planMbps: Double?, days: Int = PlanSummary.window,
                            now: Date = Date(), calendar: Calendar = .current) -> PlanSummary? {
        guard let network, network != "unknown", let plan = planMbps, plan > 0, plan.isFinite else { return nil }
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        let here = tests.filter { $0.networkKey == network && $0.networkChanged != true && $0.result.date >= since && $0.result.date <= now }
        let scheduled = here.filter { $0.scheduled == true }
        let counted = scheduled.count >= enoughScheduled ? scheduled : here
        guard !counted.isEmpty else { return nil }
        let down = counted.map(\.result.downloadMbps), up = counted.map(\.result.uploadMbps)
        let peak = counted.filter { PlanCheck.peakHours.contains(calendar.component(.hour, from: $0.result.date)) }.map(\.result.downloadMbps)
        let offPeak = counted.filter { !PlanCheck.peakHours.contains(calendar.component(.hour, from: $0.result.date)) }.map(\.result.downloadMbps)
        let median = Self.median(down) ?? 0
        let dates = counted.map(\.result.date)
        let first = dates.min() ?? now, last = dates.max() ?? now
        return PlanSummary(days: min(days, max(1, Int((now.timeIntervalSince(first) / 86_400).rounded(.up)))), planMbps: plan, checks: counted.count,
                           scheduledOnly: counted.count == scheduled.count && !scheduled.isEmpty,
                           downloadMedianMbps: median, uploadMedianMbps: Self.median(up) ?? 0, percentOfPlan: median / plan * 100,
                           peakChecks: peak.count, peakMedianMbps: Self.median(peak), offPeakChecks: offPeak.count, offPeakMedianMbps: Self.median(offPeak),
                           underHalfPercent: Double(down.filter { $0 < plan / 2 }.count) / Double(down.count) * 100,
                           slowestMbps: down.min() ?? 0, fastestMbps: down.max() ?? 0, first: first, last: last)
    }

    /// The middle value; the mean of the two middle values for an even count.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// Evenings are worth naming once two checks ran then.
    public var peakShown: Bool { peakChecks >= 2 && peakMedianMbps != nil }

    /// "You got 61% of your 500 Mbps"
    public var headline: String {
        String(localized: "You got \(Self.percent(percentOfPlan)) of your \(Self.mbps(planMbps))", comment: "Plan check: the median download as a share of the plan’s speed, e.g. “You got 61% of your 500 Mbps”")
    }

    /// One sentence for the provider report: "Over 30 days, 41 checks: median 305 Mbps of the 500 Mbps you pay for (61%); evenings 180 Mbps."
    public var sentence: String {
        let median = Self.mbps(downloadMedianMbps), plan = Self.mbps(planMbps), share = Self.percent(percentOfPlan)
        var line: String
        if peakShown, let peak = peakMedianMbps.map(Self.mbps) {
            line = scheduledOnly
                ? String(localized: "Over \(days) days, \(checks) scheduled checks: median \(median) of the \(plan) you pay for (\(share)); evenings \(peak).", comment: "Plan check, in the provider report: days, a count of automatic speed tests, the median download, the plan’s speed, the share, and the median between 7 and 11 pm")
                : String(localized: "Over \(days) days, \(checks) speed tests: median \(median) of the \(plan) you pay for (\(share)); evenings \(peak).", comment: "Plan check, in the provider report: days, a count of speed tests, the median download, the plan’s speed, the share, and the median between 7 and 11 pm")
        } else {
            line = scheduledOnly
                ? String(localized: "Over \(days) days, \(checks) scheduled checks: median \(median) of the \(plan) you pay for (\(share)).", comment: "Plan check, in the provider report: days, a count of automatic speed tests, the median download, the plan’s speed and the share")
                : String(localized: "Over \(days) days, \(checks) speed tests: median \(median) of the \(plan) you pay for (\(share)).", comment: "Plan check, in the provider report: days, a count of speed tests, the median download, the plan’s speed and the share")
        }
        if underHalfPercent >= 10 {
            line += " " + String(localized: "\(Self.percent(underHalfPercent)) of them got under half the plan.", comment: "Plan check: the share of speed tests below half the plan’s speed")
        }
        return line
    }

    public static func mbps(_ value: Double) -> String { String(format: value < 10 ? "%.1f Mbps" : "%.0f Mbps", value) }
    public static func percent(_ value: Double) -> String { String(format: "%.0f%%", value) }
}
