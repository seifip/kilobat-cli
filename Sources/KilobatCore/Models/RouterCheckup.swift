import Foundation

// Router check-up: whether a router has been getting slower over days, and whether restarting it helps.
//
// Kilobat already pings the router and times a lookup with every background check (once a minute, every two in
// Low Power Mode). Each check that ran while the Mac was quiet goes into an hour; hours make days; 14 days make
// the router's baseline. A router counts as slowing only when each of the last three days with data is clearly
// worse than that baseline, so one bad evening, a busy afternoon or a weekend away never raises it.
//
// Thresholds, tested on synthetic series in RouterCheckupTests:
// - An hour counts with 6 or more quiet checks; a day with 2 or more such hours and 30 or more checks.
// - The baseline needs 4 or more such days in the 14 days before the recent window, so 7 days of data in all.
// - Slower: each of the last 3 days' median reply at least 2× the baseline's and at least 5 ms more.
//   The +5 ms floor keeps a wired router going from 0.6 to 1.4 ms quiet.
// - Losing replies: each day at least 3 points more loss than the baseline and at least twice it, from 100+ pings.
// - Dropping: each day at least 3 drops and at least 3× the baseline's daily average.
// - Name lookups only support a finding (never raise one): through the router's DNS relay they also time the
//   provider's resolvers, so a slow provider would look like a slow router.
// - Not raised when the Mac's own Wi-Fi explains it: the signal 6 dB or more weaker than in the baseline, another band,
//   or an access point the baseline didn't use (a mesh satellite adds its own hop).

/// One quiet check of the router, as the health check measured it.
public struct RouterCheck: Sendable, Equatable {
    public var date: Date
    /// The average reply from the router; nil when none came back.
    public var rtt: Double?
    public var sent: Int
    public var lost: Int
    public var dns: Double?
    /// The lookup went through the router's own DNS relay.
    public var dnsViaRouter: Bool
    public var rssi: Int?
    public var band: String?
    public var accessPoint: String?
    /// Other traffic was heavy enough to slow replies, or a Wi-Fi sign-in page was in the way (it holds lookups and
    /// sends traffic through the venue's gateway): the check is left out of the baseline. It still shows the router answered.
    public var busy: Bool
    public init(date: Date, rtt: Double?, sent: Int = 4, lost: Int = 0, dns: Double? = nil, dnsViaRouter: Bool = false,
                rssi: Int? = nil, band: String? = nil, accessPoint: String? = nil, busy: Bool = false) {
        self.date = date; self.rtt = rtt; self.sent = sent; self.lost = lost; self.dns = dns; self.dnsViaRouter = dnsViaRouter
        self.rssi = rssi; self.band = band; self.accessPoint = accessPoint; self.busy = busy
    }
    /// The router part of a health check, or nil when there was no router to ask.
    public init?(_ snapshot: DiagnosticSnapshot, busy: Bool) {
        guard let gateway = snapshot.gateway, let router = snapshot.router, let loss = router.lossPercent else { return nil }
        // DiagnosticProbe pings the router four times.
        let sent = max(4, router.samples.count)
        let wifi = snapshot.wiredInterface == nil
        self.init(date: snapshot.date, rtt: router.average, sent: sent, lost: min(sent, Int((Double(sent) * loss / 100).rounded())),
                  dns: snapshot.dnsMilliseconds, dnsViaRouter: snapshot.dnsServers.contains(gateway),
                  rssi: wifi ? snapshot.radio.rssi : nil, band: wifi ? snapshot.radio.band : nil, accessPoint: wifi ? snapshot.radio.bssid : nil,
                  busy: busy || snapshot.captivePortal == true)
    }
    /// No reply at all: part of a drop rather than a slow reply.
    public var silent: Bool { rtt == nil }
}

/// One hour of a router's checks: medians of the quiet ones, and counts of the rest.
public struct RouterHour: Codable, Sendable, Equatable {
    public var start: Date
    /// Quiet checks with a reply.
    public var checks: Int
    public var rtt: Double?
    public var rtt90: Double?
    public var sent: Int
    public var lost: Int
    public var dns: Double?
    public var dnsViaRouter: Bool
    public var rssi: Int?
    public var band: String?
    public var accessPoint: String?
    /// Times the router went out of reach and came back, counted in the hour it went.
    public var drops: Int
    /// Checks left out because of heavy traffic.
    public var busy: Int
    public init(start: Date, checks: Int, rtt: Double?, rtt90: Double? = nil, sent: Int = 0, lost: Int = 0, dns: Double? = nil, dnsViaRouter: Bool = false,
                rssi: Int? = nil, band: String? = nil, accessPoint: String? = nil, drops: Int = 0, busy: Int = 0) {
        self.start = start; self.checks = checks; self.rtt = rtt; self.rtt90 = rtt90 ?? rtt; self.sent = sent; self.lost = lost; self.dns = dns
        self.dnsViaRouter = dnsViaRouter; self.rssi = rssi; self.band = band; self.accessPoint = accessPoint; self.drops = drops; self.busy = busy
    }
    public var qualifies: Bool { checks >= RouterCheckup.hourChecks && rtt != nil }
}

/// The hour being filled, kept raw until it closes.
public struct RouterHourDraft: Codable, Sendable, Equatable {
    public var start: Date
    public var rtts: [Double] = []
    public var dns: [Double] = []
    public var dnsViaRouter = 0
    public var rssis: [Int] = []
    public var bands: [String: Int] = [:]
    public var accessPoints: [String: Int] = [:]
    public var sent = 0
    public var lost = 0
    public var drops = 0
    public var busy = 0
    public init(start: Date) { self.start = start }

    mutating func add(_ check: RouterCheck) {
        if check.busy { busy += 1; return }
        sent += check.sent; lost += check.lost
        guard let rtt = check.rtt else { return }
        rtts.append(rtt)
        if let value = check.dns { dns.append(value); if check.dnsViaRouter { dnsViaRouter += 1 } }
        if let rssi = check.rssi { rssis.append(rssi) }
        if let band = check.band { bands[band, default: 0] += 1 }
        if let point = check.accessPoint { accessPoints[point, default: 0] += 1 }
    }

    var hour: RouterHour {
        RouterHour(start: start, checks: rtts.count, rtt: RouterCheckup.percentile(rtts, 0.5), rtt90: RouterCheckup.percentile(rtts, 0.9), sent: sent, lost: lost,
                   dns: RouterCheckup.percentile(dns, 0.5), dnsViaRouter: !dns.isEmpty && dnsViaRouter * 2 >= dns.count,
                   rssi: RouterCheckup.percentile(rssis.map(Double.init), 0.5).map { Int($0.rounded()) },
                   band: bands.max { $0.value < $1.value }?.key, accessPoint: accessPoints.max { $0.value < $1.value }?.key, drops: drops, busy: busy)
    }
}

/// A day of a router's quiet hours.
public struct RouterDay: Codable, Sendable, Equatable {
    public let day: Date
    public let hours: Int
    public let checks: Int
    /// The median of the day's hourly medians, so a bad evening moves a full day little.
    public let rtt: Double
    public let rtt90: Double
    /// Nil with fewer than 100 pings.
    public let lossPercent: Double?
    public let dns: Double?
    public let dnsViaRouter: Bool
    public let drops: Int
    public let rssi: Int?
    public let band: String?
    public let accessPoint: String?
}

/// What normal looks like for a router: its typical day over the 14 days before the recent ones.
public struct RouterBaseline: Codable, Sendable, Equatable {
    public let days: Int
    public let rtt: Double
    public let rtt90: Double
    public let lossPercent: Double
    public let dns: Double?
    /// Average drops a day.
    public let drops: Double
    public let rssi: Int?
    public let band: String?
    /// Access points used on at least a fifth of the days.
    public let accessPoints: [String]
}

public struct RouterAssessment: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// Fewer than 7 days of quiet data.
        case learning
        /// Not 3 recent days with data yet, such as after a trip or a restart.
        case waiting
        case normal
        case degraded
        /// Worse, but the Mac's own Wi-Fi explains it: weaker signal, another band or access point.
        case signal
    }
    public enum Symptom: String, Codable, Sendable { case slower, loss, drops, dns }
    public var state: State
    /// Days with enough quiet checks so far.
    public var days: Int
    public var baseline: RouterBaseline?
    /// The last 3 days with data, oldest first.
    public var recent: [RouterDay]
    /// What crossed its threshold; dns only alongside another.
    public var symptoms: [Symptom]
    /// With state signal: weaker (dB), band or accessPoint.
    public var signalChange: String?
    public var degraded: Bool { state == .degraded }
}

/// A router restart, seen or reported, and whether things got better after it.
public struct RouterRestart: Codable, Sendable, Equatable, Identifiable {
    public enum Source: String, Codable, Sendable {
        /// The router went out of reach for 30 seconds to 10 minutes while the Mac stayed awake, and the same router came back.
        case outage
        /// The person tapped I restarted it.
        case button
    }
    public enum Outcome: String, Codable, Sendable {
        case fixed, helped
        case notFixed = "didntHelp"
        /// Too little data afterwards, or a seen outage after which nothing changed (it may not have been a restart).
        case unclear
        /// Nothing was wrong beforehand, so it says nothing about restarts.
        case noProblem
    }
    public var id = UUID()
    public var date: Date
    public var source: Source
    public var outageSeconds: Double?
    /// The episode it happened in, when the router was slowing.
    public var episode: UUID?
    public var before: Double?
    public var after: Double?
    public var outcome: Outcome?
    public var checked: Date?
    public init(date: Date, source: Source, outageSeconds: Double? = nil, episode: UUID? = nil) {
        self.date = date; self.source = source; self.outageSeconds = outageSeconds; self.episode = episode
    }
    /// Counts toward “restarting fixed this the last 3 times”.
    public var counts: Bool { outcome == .fixed || outcome == .helped || outcome == .notFixed }
}

/// A stretch of days the router was slowing: from the alert until a restart fixed it or the days were normal again.
public struct RouterEpisode: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var start: Date
    /// The first of the recent days that raised it.
    public var since: Date
    public var end: Date?
    public var baseline: RouterBaseline
    public var symptoms: [RouterAssessment.Symptom]
    /// The worst recent day's median reply when it was raised.
    public var rtt: Double
    public var notified = false
}

public enum RouterCheckup {
    public static let hourChecks = 6
    public static let dayHours = 2
    public static let dayChecks = 30
    public static let baselineDays = 4
    public static let baselineWindow = 14
    public static let recentDays = 3
    /// The recent days must fall within this many calendar days, today included.
    public static let recentSpan = 5
    public static let slowerFactor = 2.0
    public static let slowerFloor = 5.0
    public static let lossPoints = 3.0
    public static let dropsPerDay = 3
    public static let dnsFactor = 2.0
    public static let dnsFloor = 20.0
    public static let weakerSignal = 6
    /// Hours of history kept per router.
    public static let keepDays = 35
    /// A second alert for the same router waits at least this long.
    public static let alertCooldown: TimeInterval = 7 * 86_400
    /// An episode this old, with no restart in its last week, ends: whatever changed has become the router's normal.
    public static let longestEpisode: TimeInterval = 21 * 86_400

    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    /// Days with enough quiet hours, oldest first. Drops count every hour of the day, quiet or not.
    public static func days(_ hours: [RouterHour], calendar: Calendar = .current) -> [RouterDay] {
        let grouped = Dictionary(grouping: hours) { calendar.startOfDay(for: $0.start) }
        return grouped.keys.sorted().compactMap { day in
            let all = grouped[day] ?? [], quiet = all.filter(\.qualifies)
            let checks = quiet.reduce(0) { $0 + $1.checks }
            guard quiet.count >= dayHours, checks >= dayChecks, let rtt = percentile(quiet.compactMap(\.rtt), 0.5) else { return nil }
            let sent = all.reduce(0) { $0 + $1.sent }, lost = all.reduce(0) { $0 + $1.lost }
            let dnsHours = quiet.filter { $0.dns != nil }
            func most(_ values: [String?]) -> String? {
                Dictionary(grouping: values.compactMap { $0 }, by: { $0 }).max { $0.value.count < $1.value.count }?.key
            }
            return RouterDay(day: day, hours: quiet.count, checks: checks, rtt: rtt, rtt90: percentile(quiet.compactMap(\.rtt90), 0.5) ?? rtt,
                             lossPercent: sent >= 100 ? Double(lost) / Double(sent) * 100 : nil,
                             dns: percentile(dnsHours.compactMap(\.dns), 0.5), dnsViaRouter: dnsHours.filter(\.dnsViaRouter).count * 2 > dnsHours.count,
                             drops: all.reduce(0) { $0 + $1.drops }, rssi: percentile(quiet.compactMap { $0.rssi.map(Double.init) }, 0.5).map { Int($0.rounded()) },
                             band: most(quiet.map(\.band)), accessPoint: most(quiet.map(\.accessPoint)))
        }
    }

    public static func baseline(_ days: [RouterDay]) -> RouterBaseline? {
        guard days.count >= baselineDays, let rtt = percentile(days.map(\.rtt), 0.5) else { return nil }
        let losses = days.compactMap(\.lossPercent)
        let points = Dictionary(grouping: days.compactMap(\.accessPoint), by: { $0 }).filter { Double($0.value.count) >= Double(days.count) / 5 }.keys.sorted()
        return RouterBaseline(days: days.count, rtt: rtt, rtt90: percentile(days.map(\.rtt90), 0.5) ?? rtt, lossPercent: percentile(losses, 0.5) ?? 0,
                              dns: percentile(days.compactMap(\.dns), 0.5), drops: Double(days.reduce(0) { $0 + $1.drops }) / Double(days.count),
                              rssi: percentile(days.compactMap { $0.rssi.map(Double.init) }, 0.5).map { Int($0.rounded()) },
                              band: Dictionary(grouping: days.compactMap(\.band), by: { $0 }).max { $0.value.count < $1.value.count }?.key, accessPoints: points)
    }

    /// The reply time a day must reach to count as slower than `baseline`.
    public static func slowerThreshold(_ baseline: RouterBaseline) -> Double { max(baseline.rtt * slowerFactor, baseline.rtt + slowerFloor) }
    static func slower(_ rtt: Double, _ baseline: RouterBaseline) -> Bool { rtt >= slowerThreshold(baseline) }
    static func losing(_ loss: Double?, _ baseline: RouterBaseline) -> Bool {
        guard let loss else { return false }
        return loss >= baseline.lossPercent + lossPoints && loss >= baseline.lossPercent * 2
    }
    static func dropping(_ drops: Int, _ baseline: RouterBaseline) -> Bool { drops >= dropsPerDay && Double(drops) >= baseline.drops * 3 }
    static func slowLookups(_ day: RouterDay, _ baseline: RouterBaseline) -> Bool {
        guard day.dnsViaRouter, let dns = day.dns, let normal = baseline.dns else { return false }
        return dns >= max(normal * dnsFactor, normal + dnsFloor)
    }

    /// How the router is doing. `frozen` is the baseline of an episode still open, so a long slowdown never becomes
    /// the new normal; `after` drops days up to it, so days before a restart or an earlier episode can't raise a new one;
    /// `excluded` keeps earlier episodes' days out of the baseline.
    public static func assess(_ hours: [RouterHour], now: Date, frozen: RouterBaseline? = nil, after: Date? = nil,
                              excluded: [ClosedRange<Date>] = [], calendar: Calendar = .current) -> RouterAssessment {
        let all = days(hours, calendar: calendar).filter { $0.day <= now }
        let today = calendar.startOfDay(for: now)
        let floor = after.map { calendar.startOfDay(for: $0) }
        let eligible = all.filter { day in floor.map { day.day > $0 } ?? true }
        let recent = Array(eligible.suffix(recentDays))
        let earliest = calendar.date(byAdding: .day, value: -(recentSpan - 1), to: today) ?? today
        var result = RouterAssessment(state: .learning, days: all.count, baseline: nil, recent: recent, symptoms: [], signalChange: nil)
        let windowEnd = recent.first?.day ?? today
        let windowStart = calendar.date(byAdding: .day, value: -baselineWindow, to: windowEnd) ?? windowEnd
        let base = frozen ?? baseline(all.filter { day in day.day >= windowStart && day.day < windowEnd && !excluded.contains { $0.contains(day.day) } })
        result.baseline = base
        guard let base else { return result }
        guard recent.count == recentDays, let first = recent.first, first.day >= earliest else { result.state = .waiting; return result }
        if recent.allSatisfy({ slower($0.rtt, base) }) { result.symptoms.append(.slower) }
        if recent.allSatisfy({ losing($0.lossPercent, base) }) { result.symptoms.append(.loss) }
        if recent.allSatisfy({ dropping($0.drops, base) }) { result.symptoms.append(.drops) }
        guard !result.symptoms.isEmpty else { result.state = .normal; return result }
        if recent.allSatisfy({ slowLookups($0, base) }) { result.symptoms.append(.dns) }
        // The Mac's own link, not the router: a weaker signal, another band or another access point.
        let rssi = percentile(recent.compactMap { $0.rssi.map(Double.init) }, 0.5)
        if let rssi, let normal = base.rssi, Int(rssi.rounded()) <= normal - weakerSignal { result.signalChange = "weaker" }
        else if let band = base.band, recent.contains(where: { $0.band != nil && $0.band != band }) { result.signalChange = "band" }
        else if !base.accessPoints.isEmpty, recent.contains(where: { $0.accessPoint.map { !base.accessPoints.contains($0) } ?? false }) { result.signalChange = "accessPoint" }
        result.state = result.signalChange == nil ? .degraded : .signal
        return result
    }

    /// Whether a restart helped: the first day of quiet hours after it, against the baseline and the episode's symptoms.
    /// Nil until there are 3 quiet hours a day after it; unclear when 3 days pass without them.
    public static func outcome(of restart: RouterRestart, hours: [RouterHour], baseline: RouterBaseline?, symptoms: [RouterAssessment.Symptom],
                               now: Date) -> (outcome: RouterRestart.Outcome, before: Double?, after: Double?)? {
        let day: TimeInterval = 86_400
        let before = hours.filter { $0.qualifies && $0.start >= restart.date - day && $0.start + 3600 <= restart.date }
        let windowEnd = restart.date + day
        var after = hours.filter { $0.qualifies && $0.start >= restart.date && $0.start < windowEnd }
        if after.count < 3 {
            guard now >= restart.date + 3 * day else { return nil }
            after = hours.filter { $0.qualifies && $0.start >= restart.date && $0.start < restart.date + 3 * day }
        } else if now < windowEnd { return nil }
        let beforeRTT = percentile(before.compactMap(\.rtt), 0.5)
        guard after.count >= 3, let afterRTT = percentile(after.compactMap(\.rtt), 0.5) else { return (.unclear, beforeRTT, nil) }
        guard let baseline, !symptoms.isEmpty else { return (.noProblem, beforeRTT, afterRTT) }
        let sent = after.reduce(0) { $0 + $1.sent }, lost = after.reduce(0) { $0 + $1.lost }
        let loss = sent >= 100 ? Double(lost) / Double(sent) * 100 : nil
        let drops = hours.filter { $0.start >= restart.date && $0.start < windowEnd }.reduce(0) { $0 + $1.drops }
        var verdicts: [RouterRestart.Outcome] = []
        for symptom in symptoms {
            switch symptom {
            case .slower:
                verdicts.append(afterRTT <= max(baseline.rtt * 1.5, baseline.rtt + 2) ? .fixed : slower(afterRTT, baseline) ? .notFixed : .helped)
            case .loss:
                guard let loss else { continue }
                verdicts.append(loss <= baseline.lossPercent + 1 ? .fixed : losing(loss, baseline) ? .notFixed : .helped)
            case .drops:
                verdicts.append(Double(drops) <= max(1, baseline.drops.rounded(.up)) ? .fixed : dropping(drops, baseline) ? .notFixed : .helped)
            case .dns: continue
            }
        }
        guard !verdicts.isEmpty else { return (.unclear, beforeRTT, afterRTT) }
        var outcome: RouterRestart.Outcome = verdicts.allSatisfy { $0 == .fixed } ? .fixed : verdicts.allSatisfy { $0 == .notFixed } ? .notFixed : .helped
        // An outage Kilobat saw may have been the Mac's own Wi-Fi rather than a restart; only a reported one says restarting didn't help.
        if outcome == .notFixed && restart.source == .outage { outcome = .unclear }
        return (outcome, beforeRTT, afterRTT)
    }
}

/// A router's history: its hours, restarts and episodes, keyed by the network and the router's hardware address.
public struct RouterRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String { mac.map { network + "|" + $0 } ?? network }
    public var network: String
    public var mac: String?
    public var name: String
    public var lastSeen: Date
    public var hours: [RouterHour] = []
    public var draft: RouterHourDraft?
    public var restarts: [RouterRestart] = []
    public var episodes: [RouterEpisode] = []
    public init(network: String, mac: String?, name: String, lastSeen: Date) { self.network = network; self.mac = mac; self.name = name; self.lastSeen = lastSeen }

    public var episode: RouterEpisode? { episodes.last.flatMap { $0.end == nil ? $0 : nil } }

    /// Adds a check; closes the hour before it when the hour changed.
    public mutating func add(_ check: RouterCheck, calendar: Calendar = .current) {
        let hour = calendar.dateInterval(of: .hour, for: check.date)?.start ?? check.date
        if let open = draft, open.start != hour { close() }
        if draft == nil { draft = RouterHourDraft(start: hour) }
        draft?.add(check)
        lastSeen = max(lastSeen, check.date)
    }
    /// The router went out of reach and came back.
    public mutating func addDrop(at date: Date, calendar: Calendar = .current) {
        let hour = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        if draft?.start == hour { draft?.drops += 1 }
        else if let index = hours.lastIndex(where: { $0.start == hour }) { hours[index].drops += 1 }
        else if draft.map({ $0.start < hour }) ?? true { close(); draft = RouterHourDraft(start: hour); draft?.drops = 1 }
        else { hours.append(RouterHour(start: hour, checks: 0, rtt: nil, drops: 1)); hours.sort { $0.start < $1.start } }
    }
    public mutating func close() {
        guard let draft else { return }
        self.draft = nil
        hours.append(draft.hour)
        if let cutoff = hours.last?.start.addingTimeInterval(-Double(RouterCheckup.keepDays) * 86_400) { hours.removeAll { $0.start < cutoff } }
    }
    /// Closed hours plus the one being filled.
    public var allHours: [RouterHour] { hours + (draft.map { [$0.hour] } ?? []) }

    /// Days of earlier episodes, from the first slow day to the end.
    var excluded: [ClosedRange<Date>] { episodes.map { $0.since...($0.end ?? .distantFuture) } }
    /// Days before this can't raise an episode: the newest restart or episode end.
    var fresh: Date? { [restarts.last?.date, episodes.last?.end].compactMap { $0 }.max() }

    public func assess(now: Date, calendar: Calendar = .current) -> RouterAssessment {
        if let episode {
            return RouterCheckup.assess(allHours, now: now, frozen: episode.baseline, after: restarts.last.flatMap { $0.date > episode.start ? $0.date : nil }, calendar: calendar)
        }
        return RouterCheckup.assess(allHours, now: now, after: fresh, excluded: excluded, calendar: calendar)
    }

    public enum Event: Equatable, Sendable { case started(RouterEpisode), ended(RouterEpisode), checked(RouterRestart) }

    /// Opens or closes the episode, and judges restarts whose day has passed. The caller notifies on `started`.
    @discardableResult public mutating func update(now: Date, calendar: Calendar = .current) -> [Event] {
        var events: [Event] = []
        for index in restarts.indices where restarts[index].outcome == nil {
            let restart = restarts[index]
            let episode = restart.episode.flatMap { id in episodes.first { $0.id == id } }
            let baseline = episode?.baseline ?? RouterCheckup.assess(hours.filter { $0.start < restart.date }, now: restart.date, calendar: calendar).baseline
            guard let result = RouterCheckup.outcome(of: restart, hours: allHours, baseline: baseline, symptoms: episode?.symptoms ?? [], now: now) else { continue }
            restarts[index].outcome = result.outcome; restarts[index].before = result.before; restarts[index].after = result.after; restarts[index].checked = now
            events.append(.checked(restarts[index]))
            if let id = restart.episode, [.fixed, .helped].contains(result.outcome), let open = episodes.lastIndex(where: { $0.id == id && $0.end == nil }) {
                episodes[open].end = now; events.append(.ended(episodes[open]))
            }
        }
        let assessment = assess(now: now, calendar: calendar)
        if let open = episodes.indices.last, episodes[open].end == nil {
            // Back to normal on the newest day with data, after the episode began.
            let recovered = assessment.recent.last.map { latest in
                latest.day > calendar.startOfDay(for: episodes[open].start) && !RouterCheckup.slower(latest.rtt, episodes[open].baseline)
                    && !RouterCheckup.losing(latest.lossPercent, episodes[open].baseline) && !RouterCheckup.dropping(latest.drops, episodes[open].baseline)
            } ?? false
            // Three weeks on with no restart since its last week, it's the router's new normal rather than a slowdown to keep pointing at.
            let settled = now.timeIntervalSince(episodes[open].start) > RouterCheckup.longestEpisode
                && !restarts.contains { $0.date > now - 7 * 86_400 }
            if recovered || settled { episodes[open].end = now; events.append(.ended(episodes[open])) }
        } else if assessment.degraded, let baseline = assessment.baseline, let since = assessment.recent.first?.day {
            var episode = RouterEpisode(start: now, since: since, baseline: baseline, symptoms: assessment.symptoms, rtt: assessment.recent.map(\.rtt).max() ?? baseline.rtt)
            let lastAlert = episodes.filter(\.notified).map(\.start).max()
            episode.notified = lastAlert.map { now.timeIntervalSince($0) < RouterCheckup.alertCooldown } ?? false
            episodes.append(episode); episodes = Array(episodes.suffix(20))
            events.append(.started(episode))
        }
        return events
    }

    /// The person restarted it, or Kilobat saw it come back after an outage. One within two hours of another is the same restart.
    public mutating func restarted(at date: Date, source: RouterRestart.Source, outageSeconds: Double? = nil) {
        if let index = restarts.lastIndex(where: { abs($0.date.timeIntervalSince(date)) < 7200 && $0.outcome == nil }) {
            if source == .button { restarts[index].source = .button }
            return
        }
        restarts.append(RouterRestart(date: date, source: source, outageSeconds: outageSeconds, episode: episode?.id))
        restarts = Array(restarts.suffix(30))
    }
}
