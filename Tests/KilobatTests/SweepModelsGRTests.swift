import Foundation
import Testing
@testable import KilobatCore

/// Rule backups, outage credits, the router check-up and the other models from G to R, at their edges.
@MainActor struct SweepModelsGRTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Rule backup

    @Test func anExportWithProcessNamesThatHoldSpacesImports() throws {
        var preferences = SavedPreferences()
        preferences.rules = ["Work": ["process:Google Drive": false]]
        preferences.connectionRules = [ConnectionRule(app: "process:Google Chrome Helper", host: "203.0.113.7", port: "443", allowed: false, profile: "Work")]
        preferences.domainExceptions = ["process:Wispr Flow Helper": ["cdn.example"]]
        preferences.askDestinations = ["process:Google Drive"]
        let backup = try RuleBackup.parse(try RuleBackup(preferences, now: now).data())
        for mode in RuleImportMode.allCases { #expect(RuleImportPlan(backup, into: preferences, mode: mode).isEmpty) }
        let fresh = RuleImportPlan(backup, into: SavedPreferences(), mode: .merge).result
        #expect(fresh.rules["Work"] == ["process:Google Drive": false])
        #expect(fresh.connectionRules?.first?.app == "process:Google Chrome Helper")
        #expect(fresh.domainExceptions?["process:Wispr Flow Helper"] == ["cdn.example"])
        #expect(fresh.askDestinations == ["process:Google Drive"])
        #expect(!RuleBackup.validApp("not an id") && !RuleBackup.validApp("com.a.b|x") && !RuleBackup.validApp("com.a b"))
        #expect(!RuleBackup.validApp("process:a|b") && !RuleBackup.validApp("process:a\nb") && !RuleBackup.validApp(""))
    }

    @Test func anExportNeverHoldsADestinationRuleTheImportRefuses() throws {
        var preferences = SavedPreferences()
        preferences.connectionRules = [ConnectionRule(app: "com.a.b", host: "nas", allowed: true, profile: "Work"),
                                       ConnectionRule(app: "Safari", host: "a.example", allowed: false, profile: "Work")]
        let backup = try RuleBackup.parse(try RuleBackup(preferences, now: now).data())
        #expect(backup.profiles.first { $0.id == "work" }?.destinations?.map(\.host) == ["nas"])
        #expect(RuleImportPlan(backup, into: SavedPreferences(), mode: .merge).result.connectionRules?.map(\.host) == ["nas"])
        #expect(RuleBackup.destinationHost("bad host!") == nil && RuleBackup.destinationHost("a..b") == nil)
    }

    @Test func importsTwentyThousandSitesAtOnce() throws {
        let hosts = (0..<20_000).map { "\"h\($0).example\"" }.joined(separator: ",")
        let json = #"{"format":"\#(RuleBackup.formatName)","version":1,"exported":"2026-11-10T10:00:00Z","profiles":[],"everyApp":{"blocked":[\#(hosts)]}}"#
        let backup = try RuleBackup.parse(Data(json.utf8))
        let merged = RuleImportPlan(backup, into: SavedPreferences(), mode: .merge)
        #expect(merged.result.blockedHosts?.count == 20_000 && merged.added == 20_000)
        var old = SavedPreferences(); old.blockedHosts = ["old.example"]
        let replaced = RuleImportPlan(backup, into: old, mode: .replace)
        #expect(replaced.removed == 1 && replaced.result.blockedHosts?.count == 20_000 && replaced.result.blockedHosts == replaced.result.blockedHosts?.sorted())
    }

    // MARK: Profile schedule

    @Test func theNextChangeIsAtTheWallClockTimeOnAClockChangeDay() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        func local(_ month: Int, _ day: Int, _ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2027, month: month, day: day, hour: hour))! }
        let schedule = ProfileSchedule(profile: "Work", days: ProfileSchedule.everyDay, start: 540, end: 1080)
        let spring = try #require(ProfileScheduler.nextChange([schedule], after: local(3, 14, 6), calendar: calendar))
        #expect(spring.date == local(3, 14, 9) && spring.schedule?.id == schedule.id)
        let autumn = try #require(ProfileScheduler.nextChange([schedule], after: local(11, 7, 6), calendar: calendar))
        #expect(autumn.date == local(11, 7, 9) && autumn.schedule?.id == schedule.id)
        #expect(schedule.windowStart(containing: local(11, 7, 12), calendar: calendar) == local(11, 7, 9))
    }

    // MARK: Home usage

    @Test func anInfiniteLineMaximumFallsBackToTheNearTheTopRule() throws {
        var meter = RouterMeter()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        _ = meter.step("home", down: 4_000_000_000, up: 10, at: t, bits: 32, downMax: .infinity, upMax: 1e30)
        let second = meter.step("home", down: 5_000, up: 20, at: t.addingTimeInterval(10), bits: 32, downMax: .infinity, upMax: 1e30)
        let step = try #require(second)
        #expect(step.down == 294_972_296 && step.up == 10)
    }

    // MARK: Local reach

    @Test func theMenuCountsDevicesNotServices() {
        let check = LocalReachCheck(network: "Home", services: [LocalService(kind: .cast, name: "Living Room TV"), LocalService(kind: .airPlay, name: "Living Room TV"),
                                                                LocalService(kind: .printer, name: "HP LaserJet")], peers: LocalPeers())
        #expect(check.devices.count == 2)
        #expect(check.short.contains("2") && !check.short.contains("3"))
    }

    // MARK: Route timeline

    @Test func aDestinationThatAnswersLateMarksOnlyTheRoundsBefore() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var watch = WatchedRoute(host: "example.com", started: start, interval: 2, duration: nil, options: .standard)
        watch.address = "198.51.100.7"
        for index in 0..<60 {
            let answered = index >= 50
            watch.append([RouteHop(ttl: 1, addresses: ["192.168.1.1"], samples: [2], probes: 1),
                          RouteHop(ttl: 2, addresses: answered ? ["198.51.100.7"] : [], samples: answered ? [20] : [], probes: 1)],
                         at: start.addingTimeInterval(Double(index) * 2))
        }
        let points = try #require(RouteTimeline(watch: watch).rows.last?.points)
        #expect(points.count == 60)
        #expect(points.prefix(50).allSatisfy { $0.destinationLost })
        #expect(points.suffix(10).allSatisfy { !$0.destinationLost })
    }

    // MARK: Router check-up

    private let utc: Calendar = { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!; return calendar }()
    /// 4 January 2027 at `hour`:00 UTC, `day` days later.
    private func at(_ day: Int, _ hour: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2027, month: 1, day: 4, hour: hour))!.addingTimeInterval(Double(day) * 86_400)
    }
    private func hours(_ days: Int, rtt: (Int) -> Double?) -> [RouterHour] {
        (0..<days).flatMap { day in
            (9...16).compactMap { hour -> RouterHour? in
                guard let value = rtt(day) else { return nil }
                return RouterHour(start: at(day, hour), checks: 40, rtt: value, rtt90: value * 1.4, sent: 160, lost: 0,
                                  dns: 18, dnsViaRouter: true, rssi: -55, band: "5 GHz", accessPoint: "aa:bb:cc:00:00:01", drops: 0)
            }
        }
    }
    private func record(_ hours: [RouterHour]) -> RouterRecord {
        var record = RouterRecord(network: "home", mac: "f4:92:bf:10:20:30", name: "Home", lastSeen: hours.last?.start ?? at(0))
        record.hours = hours
        return record
    }

    @Test func aSilencedSlowdownDoesNotRestartTheCooldown() throws {
        let now = at(17, 20)
        var router = record(hours(18) { $0 < 15 ? 4 : 20 })
        let baseline = try #require(RouterCheckup.baseline(RouterCheckup.days(hours(5) { _ in 4 }, calendar: utc)))
        let day: TimeInterval = 86_400
        router.episodes = [RouterEpisode(start: now - 10 * day, since: now - 12 * day, end: now - 9 * day, baseline: baseline, symptoms: [.slower], rtt: 20, notified: true),
                           RouterEpisode(start: now - 5 * day, since: now - 7 * day, end: now - 4 * day, baseline: baseline, symptoms: [.slower], rtt: 20, notified: true, silenced: true)]
        let events = router.update(now: now, calendar: utc)
        let started = events.compactMap { if case .started(let episode) = $0 { episode } else { nil } }
        #expect(started.count == 1)
        #expect(started.first?.notified == false)
    }

    @Test func learningCountsOnlyTheDaysThatCountTowardAVerdict() {
        let hours = hours(38) { $0 < 10 || $0 >= 35 ? 4 : nil }
        let now = at(37, 20)
        let assessment = RouterCheckup.assess(hours, now: now, calendar: utc)
        #expect(assessment.state == .learning && assessment.days == 3)
        #expect(RouterReport(record(hours), now: now, calendar: utc).headline.contains("3 of 7"))
        #expect(RouterCheckup.assess(self.hours(6) { _ in 4 }, now: at(5, 20), calendar: utc).days == 6)
    }

    // MARK: Outage credit

    private let table = OutageCreditTable.bundled
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10) -> Date {
        utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }
    private var october: DateInterval { CreditTally.month(of: date(15, 12), calendar: utc) }
    private var september: DateInterval { CreditTally.month(of: date(15, 12, month: 9), calendar: utc) }
    private func outage(_ start: Date, _ end: Date) -> NetworkEvent {
        NetworkEvent(start: start, end: end, network: "Home", kind: "Unreachable", detail: "", routerChecks: 30, routerAnswered: 30)
    }
    private func tally(_ events: [NetworkEvent], sleeps: [DateInterval] = []) -> CreditTally {
        CreditTally.make(events: events, sleeps: sleeps, network: "Home", from: october.start, to: october.end, now: date(31, 23))
    }
    private func septemberTally(_ events: [NetworkEvent]) -> CreditTally {
        CreditTally.make(events: events, network: "Home", from: september.start, to: september.end, now: date(31, 23))
    }
    private func estimate(_ policy: String, _ tally: CreditTally, price: Double? = nil) -> CreditEstimate {
        CreditEstimate.make(policy: table.policy(id: policy), tally: tally, monthlyPrice: price, calendar: utc)
    }

    @Test func anOutageAcrossTheMonthsEdgeNotifiesOnce() {
        let event = NetworkEvent(start: date(30, 10), end: nil, network: "Home", kind: "Unreachable", detail: "", routerChecks: 50, routerAnswered: 50)
        let first = date(31, 10, 30), second = date(1, 10, 30, month: 11)
        let oct = CreditTally.make(events: [event], network: "Home", from: october.start, to: october.end, now: first)
        let key = CreditAlert.due(estimate("us-xfinity", oct), outages: oct.outages, notified: [], last: nil, now: first)
        #expect(key == CreditAlert.key(date(30, 10)))
        let month = CreditTally.month(of: second, calendar: utc)
        let nov = CreditTally.make(events: [event], network: "Home", from: month.start, to: month.end, now: second)
        #expect(CreditAlert.due(estimate("us-xfinity", nov), outages: nov.outages, notified: [key!], last: first, now: second) == nil)
    }

    @Test func aFullDayCreditWithNoDayThisMonthDoesNotQualifyWithoutAPrice() {
        let events = [outage(date(30, 20, month: 9), date(1, 0, 30))]
        let priced = estimate("us-att", tally(events), price: 62)
        #expect(priced.days == 0 && !priced.qualifies)
        let unpriced = estimate("us-att", tally(events))
        #expect(!unpriced.qualifies && !unpriced.needsPrice)
        let september = estimate("us-att", septemberTally(events))
        #expect(september.qualifies && september.days == 1)
    }

    @Test func italyCreditsADayOnceForSeveralOutages() {
        let result = estimate("it-agcom", tally([outage(date(6, 9), date(6, 9, 5)), outage(date(6, 14), date(6, 14, 5)), outage(date(6, 20), date(6, 20, 5))]))
        #expect(result.days == 1 && result.amount == 6)
        #expect(estimate("it-agcom", tally([outage(date(6, 9), date(7, 12))])).amount == 12)
    }

    @Test func sleepsAroundAnOutageAreLeftAsTheyWere() {
        let result = tally([outage(date(6, 10), date(6, 14))], sleeps: [DateInterval(start: date(5, 1), end: date(5, 7)), DateInterval(start: date(6, 11), end: date(6, 12)),
                                                                     DateInterval(start: date(7, 1), end: date(7, 7))])
        #expect(result.totalSeconds == 3 * 3600 && result.asleepSeconds == 3600 && result.outages.count == 2)
    }

    @Test func creditDaysAreCalendarDaysOverTheAutumnClockChange() throws {
        var london = Calendar(identifier: .gregorian); london.timeZone = TimeZone(identifier: "Europe/London")!
        func local(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date { london.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))! }
        let month = CreditTally.month(of: local(15, 12), calendar: london)
        let tally = CreditTally.make(events: [outage(local(19, 10), local(25, 23, 30))], network: "Home", from: month.start, to: month.end, now: local(31, 12))
        let policy = try #require(table.policy(id: "uk-ofcom"))
        #expect(CreditEstimate.deadline(for: tally.outages[0], threshold: policy.threshold, calendar: london) == local(22, 0))
        let result = CreditEstimate.make(policy: policy, tally: tally, monthlyPrice: nil, calendar: london)
        #expect(result.days == 4 && result.amount == 41.36)
    }

    @Test func theDraftListsTheLongestOutagesAndSumsTheShorterOnes() throws {
        let short = (1...26).map { outage(date($0, 9), date($0, 9, 2)) }
        let big = outage(date(28, 8), date(28, 20))
        let t = tally(short + [big])
        let body = CreditClaim.draft(provider: "Xfinity", policy: table.policy(id: "us-xfinity"), tally: t, estimate: estimate("us-xfinity", t), monthlyPrice: nil).body
        let last = try #require(t.outages.last)
        #expect(body.contains(CreditText.span(last)))
        #expect(body.components(separatedBy: "shorter outages").count == 2)
        #expect(body.contains("2 shorter outages, " + CreditText.duration(4 * 60) + " in all"))
    }
}
