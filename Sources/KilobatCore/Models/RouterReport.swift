import Foundation

/// A router's check-up in words and numbers: for the Health finding, the notification, `kilobat router` and MCP.
public struct RouterReport: Codable, Sendable {
    public enum State: String, Codable, Sendable { case learning, waiting, normal, degraded, signal }
    public struct Restart: Codable, Sendable {
        public let date: Date
        /// outage: Kilobat saw the router go and come back; button: you said you restarted it.
        public let source: String
        public let outageSeconds: Double?
        /// fixed, helped, didntHelp, unclear, noProblem; nil while the day after it is still being watched.
        public let outcome: String?
        public let beforeMs: Double?
        public let afterMs: Double?
        public let duringSlowdown: Bool
    }
    public struct Day: Codable, Sendable {
        public let day: Date
        public let routerMs: Double
        public let routerP90Ms: Double
        public let lossPercent: Double?
        public let dnsMs: Double?
        public let drops: Int
        public let quietHours: Int
    }
    public struct Baseline: Codable, Sendable {
        public let days: Int
        public let routerMs: Double
        public let routerP90Ms: Double
        public let lossPercent: Double
        public let dnsMs: Double?
        public let dropsPerDay: Double
    }
    public let network: String
    public let name: String
    public let mac: String?
    public let lastSeen: Date
    public let state: State
    /// Days with enough quiet checks; 7 are needed before anything is judged.
    public let days: Int
    public let baseline: Baseline?
    /// The last 3 days with data, the ones judged.
    public let recent: [Day]
    /// Up to 14 days, oldest first.
    public let trend: [Day]
    /// slower, loss, drops and dns (name lookups, only alongside another).
    public let symptoms: [String]
    public let slowingSince: Date?
    public let restarts: [Restart]
    public let headline: String
    public let detail: String?
    /// What to do: restart, with how restarts went before, or what to try when they didn't help.
    public let advice: String?
    /// The day after a restart: whether it helped.
    public let followUp: String?
    /// True when it helped, false when it didn't, nil while waiting or unclear.
    public let followUpGood: Bool?
    /// Whether the Health tab shows it (Pro): a slowdown, or a restart being followed up.
    public let showsFinding: Bool

    public init(_ record: RouterRecord, now: Date = Date(), calendar: Calendar = .current) {
        let assessment = record.assess(now: now, calendar: calendar)
        let episode = record.episode
        let base = episode?.baseline ?? assessment.baseline
        network = record.network; name = record.name; mac = record.mac; lastSeen = record.lastSeen
        days = assessment.days
        func day(_ value: RouterDay) -> Day {
            Day(day: value.day, routerMs: Self.tenth(value.rtt), routerP90Ms: Self.tenth(value.rtt90), lossPercent: value.lossPercent.map(Self.tenth),
                dnsMs: value.dns.map(Self.tenth), drops: value.drops, quietHours: value.hours)
        }
        baseline = base.map { Baseline(days: $0.days, routerMs: Self.tenth($0.rtt), routerP90Ms: Self.tenth($0.rtt90), lossPercent: Self.tenth($0.lossPercent),
                                       dnsMs: $0.dns.map(Self.tenth), dropsPerDay: Self.tenth($0.drops)) }
        recent = assessment.recent.map(day)
        let all = RouterCheckup.days(record.allHours, calendar: calendar)
        trend = all.suffix(14).map(day)
        let open = episode != nil
        let state: State = open ? .degraded : State(rawValue: assessment.state.rawValue) ?? .learning
        self.state = state
        let symptoms = episode?.symptoms ?? (assessment.state == .signal || assessment.state == .degraded ? assessment.symptoms : [])
        self.symptoms = symptoms.map(\.rawValue)
        slowingSince = episode?.since
        restarts = record.restarts.reversed().prefix(10).map {
            Restart(date: $0.date, source: $0.source.rawValue, outageSeconds: $0.outageSeconds, outcome: $0.outcome?.rawValue, beforeMs: $0.before, afterMs: $0.after, duringSlowdown: $0.episode != nil)
        }
        let slowDays = episode.map { e in all.filter { $0.day >= e.since }.count } ?? 0
        let latest = all.last { day in episode.map { day.day >= $0.since } ?? true }
        switch state {
        case .learning:
            headline = String(localized: "Learning what’s normal for this router: \(min(assessment.days, 7)) of 7 days", comment: "Router check-up: days of data collected so far")
            detail = nil
        case .waiting:
            headline = String(localized: "No slowdown. Waiting for three recent days with data.", comment: "Router check-up: not enough recent days to judge")
            detail = nil
        case .normal:
            headline = String(localized: "Your router is as fast as usual", comment: "Router check-up verdict")
            detail = assessment.recent.last.flatMap { day in base.map { String(localized: "Replies take \(Self.ms(day.rtt)), usually \(Self.ms($0.rtt)).", comment: "Router reply times, such as “4 ms”") } }
        case .signal:
            headline = String(localized: "Slower replies, but this Mac’s Wi-Fi explains them", comment: "Router check-up verdict: the Mac's own Wi-Fi link, not the router, got worse")
            detail = switch assessment.signalChange {
            case "weaker": String(localized: "The signal here is weaker than usual. Move closer to the router, or check Radar, before blaming the router.", comment: "Router check-up")
            case "band": String(localized: "This Mac is on a different Wi-Fi band than usual, which can be slower.", comment: "Router check-up")
            default: String(localized: "This Mac is connected to a different access point than usual, such as a mesh satellite.", comment: "Router check-up")
            }
        case .degraded:
            let symptom = symptoms.first ?? .slower
            headline = switch symptom {
            case .loss: String(localized: "Your router has been losing replies", comment: "Router check-up finding title")
            case .drops: String(localized: "Your Wi-Fi keeps dropping", comment: "Router check-up finding title")
            default: String(localized: "Your router has been getting slower", comment: "Router check-up finding title")
            }
            var text: String
            let count = max(RouterCheckup.recentDays, slowDays)
            switch symptom {
            case .loss:
                text = String(localized: "For \(count) days, \(Self.percent(latest?.lossPercent ?? 0)) of its replies went missing, against \(Self.percent(base?.lossPercent ?? 0)) usually.", comment: "Router check-up: a number of days, then two percentages")
            case .drops:
                text = String(localized: "For \(count) days, the connection to it dropped \(latest?.drops ?? 0) times a day, against \(Self.count(base?.drops ?? 0)) usually.", comment: "Router check-up: a number of days, then drops per day now and usually")
            default:
                text = String(localized: "For \(count) days, its replies have taken \(Self.ms(latest?.rtt ?? episode?.rtt ?? 0)) instead of \(Self.ms(base?.rtt ?? 0)).", comment: "Router check-up: a number of days, then reply times such as “19 ms” and “4 ms”")
            }
            if symptoms.contains(.dns), let now = latest?.dns, let usual = base?.dns {
                text += " " + String(localized: "Name lookups through it slowed too, \(Self.ms(usual)) → \(Self.ms(now)).", comment: "Router check-up: DNS lookup times before and now")
            }
            detail = text
        }
        advice = state == .degraded ? Self.advice(record.restarts) : nil
        let follow = Self.followUp(record, now: now)
        followUp = follow?.text; followUpGood = follow?.good
        showsFinding = state == .degraded || follow != nil
    }

    /// How earlier restarts went, newest first, for the advice line.
    static func advice(_ restarts: [RouterRestart]) -> String {
        let counted = Array(restarts.filter(\.counts).reversed().prefix(3))
        guard let newest = counted.first else {
            return String(localized: "Restarting it often helps. Unplug it for 30 seconds; the day after, Kilobat says whether it helped.", comment: "Router check-up advice with no restart history")
        }
        let fixed = counted.filter { $0.outcome == .fixed || $0.outcome == .helped }.count
        let streak = counted.prefix { $0.outcome == .fixed || $0.outcome == .helped }.count
        if newest.outcome == .notFixed && counted.count >= 2 && counted[1].outcome == .notFixed {
            return String(localized: "Restarting it didn’t help the last two times. Check for a firmware update, give it an open spot away from walls, and if it’s more than about five years old, consider a new one.", comment: "Router check-up advice when restarts stopped helping")
        }
        if newest.outcome == .notFixed {
            return String(localized: "Restarting it didn’t help last time. Try once more; if it still doesn’t, check for a firmware update or give it a more open spot.", comment: "Router check-up advice")
        }
        if streak == counted.count {
            return streak == 1 ? String(localized: "Restarting it fixed this last time.", comment: "Router check-up advice")
                               : String(localized: "Restarting it fixed this the last \(streak) times.", comment: "Router check-up advice: a count of restarts, 2 or 3")
        }
        return String(localized: "Restarting it fixed this \(fixed) of the last \(counted.count) times.", comment: "Router check-up advice: two counts of restarts")
    }

    /// The line under the finding after a restart: waiting, then for two days whether it helped.
    static func followUp(_ record: RouterRecord, now: Date) -> (text: String, good: Bool?)? {
        guard let restart = record.restarts.last, restart.source == .button || restart.episode != nil else { return nil }
        guard let outcome = restart.outcome else {
            guard now.timeIntervalSince(restart.date) < 3 * 86_400 else { return nil }
            return (String(localized: "Restarted \(restart.date.formatted(date: .omitted, time: .shortened)). Kilobat checks over the next day whether it helped.", comment: "Router check-up: the time of the restart"), nil)
        }
        guard now.timeIntervalSince(restart.checked ?? restart.date) < 2 * 86_400 else { return nil }
        let usual = restart.episode.flatMap { id in record.episodes.first { $0.id == id }?.baseline.rtt }
        let after = restart.after.map(ms) ?? "—", before = restart.before.map(ms) ?? "—"
        switch outcome {
        case .fixed: return (String(localized: "Since the restart: back to \(after) ✓", comment: "Router check-up follow-up: reply time after a restart that helped"), true)
        case .helped:
            return (String(localized: "Since the restart: \(after), better than \(before) but not yet the usual \(usual.map(ms) ?? "—").", comment: "Router check-up follow-up: three reply times"), true)
        case .notFixed: return (String(localized: "Since the restart: still \(after). Restarting didn’t help this time.", comment: "Router check-up follow-up: reply time after a restart that didn't help"), false)
        case .unclear: return restart.source == .button ? (String(localized: "Too little data since the restart to tell whether it helped.", comment: "Router check-up follow-up"), nil) : nil
        case .noProblem:
            return restart.source == .button ? (String(localized: "Since the restart: \(after), and \(before) before it.", comment: "Router check-up follow-up when nothing was wrong: reply times after and before"), nil) : nil
        }
    }

    public var verdict: String { [headline, detail, advice, followUp].compactMap { $0 }.joined(separator: " ") }

    /// JSON numbers to a tenth: medians of pings aren't more precise than that.
    static func tenth(_ value: Double) -> Double { (value * 10).rounded() / 10 }
    public static func ms(_ value: Double) -> String { value < 2 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value) }
    static func percent(_ value: Double) -> String { value < 1 && value > 0 ? String(format: "%.1f%%", value) : String(format: "%.0f%%", value) }
    static func count(_ value: Double) -> String { value < 1 && value > 0 ? String(format: "%.1f", value) : String(format: "%.0f", value) }

    /// `kilobat router [--all] [--json]`.
    public struct Options: Equatable, Sendable {
        public var json = false
        /// Every router seen in the last 60 days, not only the one this Mac used last.
        public var all = false
        public static let usage = "Use router [--all] [--json]."
        public static func parse(_ args: [String]) throws -> Options {
            var options = Options()
            for arg in args.dropFirst() {
                switch arg {
                case "--json": options.json = true
                case "--all": options.all = true
                default: throw DiagnosticError(usage)
                }
            }
            return options
        }
    }
}
