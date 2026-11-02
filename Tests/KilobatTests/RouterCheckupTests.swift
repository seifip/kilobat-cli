import Foundation
import Testing
@testable import KilobatCore

/// Router check-up on synthetic series: what raises a slowdown, what never should, and how restarts are judged.
struct RouterCheckupTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// 4 January 2027 (a Monday) at `hour`:00 UTC, `day` days later.
    private func at(_ day: Int, _ hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2027, month: 1, day: 4, hour: hour, minute: minute))!.addingTimeInterval(Double(day) * 86_400)
    }
    /// Days 0..<`days`, eight hours a day from 9 to 17 with 40 quiet checks each; `rtt` nil leaves the hour out.
    private func series(_ days: Int, hours: ClosedRange<Int> = 9...16, rssi: Int = -55, drops: (Int) -> Int = { _ in 0 },
                        lost: (Int) -> Int = { _ in 0 }, rtt: (Int, Int) -> Double?) -> [RouterHour] {
        (0..<days).flatMap { day in
            hours.compactMap { hour -> RouterHour? in
                guard let value = rtt(day, hour) else { return nil }
                return RouterHour(start: at(day, hour), checks: 40, rtt: value, rtt90: value * 1.4, sent: 160, lost: hour == hours.lowerBound ? lost(day) : 0,
                                  dns: 18, dnsViaRouter: true, rssi: rssi, band: "5 GHz", accessPoint: "aa:bb:cc:00:00:01", drops: hour == hours.lowerBound ? drops(day) : 0)
            }
        }
    }
    private func record(_ hours: [RouterHour]) -> RouterRecord {
        var record = RouterRecord(network: "home", mac: "f4:92:bf:10:20:30", name: "Home", lastSeen: hours.last?.start ?? at(0))
        record.hours = hours
        return record
    }
    /// 14 days at 4 ms, then 6, 9.5, 12, 15 and 19 ms.
    private func climb(_ day: Int, _ hour: Int) -> Double? { day < 14 ? 4 : [6, 9.5, 12, 15, 19][min(day - 14, 4)] }
    private func started(_ events: [RouterRecord.Event]) -> Int { events.filter { if case .started = $0 { true } else { false } }.count }

    // MARK: Slowdowns

    @Test func flatSeriesStaysNormal() {
        var router = record(series(21) { day, hour in 4 + Double((day * 7 + hour) % 3) * 0.4 })
        #expect(started(router.update(now: at(20, 20), calendar: calendar)) == 0)
        let assessment = router.assess(now: at(20, 20), calendar: calendar)
        #expect(assessment.state == .normal)
        #expect(abs((assessment.baseline?.rtt ?? 0) - 4.4) < 0.5)
        #expect(RouterReport(router, now: at(20, 20), calendar: calendar).showsFinding == false)
    }

    @Test func learnsForSevenDays() {
        let hours = series(6) { _, _ in 4 }
        #expect(RouterCheckup.assess(hours, now: at(5, 20), calendar: calendar).state == .learning)
        // Three slow days on top of four normal ones is the least that can raise it.
        let enough = series(7) { day, _ in day < 4 ? 4 : 20 }
        #expect(RouterCheckup.assess(enough, now: at(6, 20), calendar: calendar).state == .degraded)
    }

    @Test func slowClimbRaisesOneEpisode() {
        var router = record(series(17, rtt: climb))
        // 6 ms on day 14 is under the line (2 × 4 ms and 4 + 5 ms = 9 ms), so days 14–16 don't yet count.
        #expect(started(router.update(now: at(16, 20), calendar: calendar)) == 0)
        router.hours = series(18, rtt: climb)
        let events = router.update(now: at(17, 20), calendar: calendar)
        #expect(started(events) == 1)
        #expect(router.episode?.symptoms == [.slower])
        #expect(router.episode?.baseline.rtt == 4)
        // The next hour, and the next day, add nothing: one episode, one alert.
        #expect(started(router.update(now: at(17, 21), calendar: calendar)) == 0)
        router.hours = series(19, rtt: climb)
        #expect(started(router.update(now: at(18, 20), calendar: calendar)) == 0)
        let report = RouterReport(router, now: at(18, 20), calendar: calendar)
        #expect(report.state == .degraded && report.showsFinding)
        #expect(report.headline == "Your router has been getting slower")
        #expect(report.detail == "For 4 days, its replies have taken 19 ms instead of 4 ms.")
        #expect(report.advice?.hasPrefix("Restarting it often helps.") == true)
    }

    @Test func oneBadEveningDoesNotAlert() {
        // Mostly at the desk: a bad evening is a few hours of a long day.
        let long = series(21, hours: 9...22) { day, hour in day == 20 && hour >= 18 ? 45 : 4 }
        #expect(RouterCheckup.assess(long, now: at(20, 23), calendar: calendar).state == .normal)
        // Only on in the evenings: the bad evening is the whole day, but it's one day.
        let evenings = series(21, hours: 19...22) { day, _ in day == 20 ? 45 : 4 }
        #expect(RouterCheckup.assess(evenings, now: at(20, 23), calendar: calendar).state == .normal)
        // Two bad days in a row, then a normal one, isn't sustained either.
        let twoDays = series(21) { day, _ in day == 18 || day == 19 ? 30 : 4 }
        #expect(RouterCheckup.assess(twoDays, now: at(20, 20), calendar: calendar).state == .normal)
    }

    @Test func weekendGapsAreSkipped() {
        // 4 January 2027 is a Monday: days 5, 6, 12, 13, 19 and 20 are weekends with no data.
        let weekend: (Int) -> Bool = { [5, 6].contains($0 % 7) }
        let flat = series(22) { day, _ in weekend(day) ? nil : 4 }
        let assessment = RouterCheckup.assess(flat, now: at(21, 20), calendar: calendar)
        #expect(assessment.state == .normal)
        #expect(assessment.recent.map(\.day) == [at(17), at(18), at(21)])
        // Slow from Thursday: Thursday, Friday and Monday are three slow days with data, so it's raised after the weekend.
        let slow = series(22) { day, _ in weekend(day) ? nil : day >= 17 ? 16 : 4 }
        #expect(RouterCheckup.assess(slow, now: at(18, 20), calendar: calendar).state == .normal)
        #expect(RouterCheckup.assess(slow, now: at(21, 20), calendar: calendar).state == .degraded)
        // Away for a week: the old days are too far back to judge, so it waits.
        #expect(RouterCheckup.assess(series(10) { _, _ in 4 }, now: at(17, 20), calendar: calendar).state == .waiting)
    }

    @Test func wiredRouterNeedsFiveMoreMilliseconds() {
        // 0.6 → 1.4 ms more than doubles, but nobody would notice it.
        let wired = series(21) { day, _ in day < 18 ? 0.6 : 1.4 }
        #expect(RouterCheckup.assess(wired, now: at(20, 20), calendar: calendar).state == .normal)
    }

    @Test func weakerSignalIsNotTheRouter() {
        let weak = series(14) { _, _ in 4 } + series(17, rssi: -64) { day, _ in day < 14 ? nil : 12 }
        let assessment = RouterCheckup.assess(weak, now: at(16, 20), calendar: calendar)
        #expect(assessment.state == .signal && assessment.signalChange == "weaker")
        var router = record(weak)
        #expect(started(router.update(now: at(16, 20), calendar: calendar)) == 0)
    }

    @Test func lossAndDropsRaiseTheirOwn() {
        let loss = series(21, lost: { $0 >= 18 ? 80 : 0 }) { _, _ in 4 }
        let lossy = RouterCheckup.assess(loss, now: at(20, 20), calendar: calendar)
        #expect(lossy.state == .degraded && lossy.symptoms == [.loss])
        let drops = series(21, drops: { $0 >= 18 ? 4 : ($0 % 5 == 0 ? 1 : 0) }) { _, _ in 4 }
        let dropping = RouterCheckup.assess(drops, now: at(20, 20), calendar: calendar)
        #expect(dropping.state == .degraded && dropping.symptoms == [.drops])
        // Two drops a day is under the line.
        let few = series(21, drops: { $0 >= 18 ? 2 : 0 }) { _, _ in 4 }
        #expect(RouterCheckup.assess(few, now: at(20, 20), calendar: calendar).state == .normal)
    }

    @Test func episodeEndsWhenDaysAreNormalAgain() {
        var router = record(series(18, rtt: climb))
        router.update(now: at(17, 20), calendar: calendar)
        router.hours = series(19) { day, hour in day == 18 ? 4 : climb(day, hour) }
        let events = router.update(now: at(18, 20), calendar: calendar)
        #expect(events.contains { if case .ended = $0 { true } else { false } })
        // The slow days before can't raise a second episode straight away.
        router.hours = series(20) { day, hour in day >= 18 ? 4 : climb(day, hour) }
        #expect(started(router.update(now: at(19, 20), calendar: calendar)) == 0)
    }

    @Test func longSlowdownBecomesTheNewNormal() {
        // Slower from day 14 and never restarted: after three weeks the finding stops, and a week later the slower
        // replies are what's usual, with no second alert.
        let slow: (Int, Int) -> Double? = { day, _ in day < 14 ? 4 : 16 }
        var router = record(series(17, rtt: slow))
        #expect(started(router.update(now: at(16, 20), calendar: calendar)) == 1)
        for day in 17..<50 {
            router.hours = series(day + 1, rtt: slow)
            let events = router.update(now: at(day, 20), calendar: calendar)
            #expect(started(events) == 0, "day \(day)")
            if day == 38 { #expect(events.contains { if case .ended = $0 { true } else { false } }) }
        }
        #expect(router.episode == nil)
        #expect(router.assess(now: at(49, 20), calendar: calendar).state == .normal)
    }

    @Test func noisyHealthyMonthsNeverAlert() {
        // Two months of a healthy router with Wi-Fi's usual noise: replies 2–12 ms, a bad evening about once a week,
        // some days off, odd hours of heavy household traffic. Judged every evening, it must never raise anything.
        var seed: UInt64 = 0x5eed
        func random() -> Double { seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return Double(seed >> 11) / Double(1 << 53) }
        var badEvening: Set<Int> = [], off: Set<Int> = []
        for day in 0..<60 { if random() < 0.15 { badEvening.insert(day) }; if random() < 0.2 { off.insert(day) } }
        let hours = series(60, hours: 8...22) { day, hour in
            if off.contains(day) { return nil }
            if badEvening.contains(day) && hour >= 19 { return 30 + random() * 40 }
            if random() < 0.05 { return 25 + random() * 30 }
            return 2 + random() * 10
        }
        var router = record([])
        for day in 7..<60 {
            router.hours = hours.filter { $0.start < at(day, 23) }
            #expect(started(router.update(now: at(day, 23), calendar: calendar)) == 0, "day \(day)")
        }
    }

    // MARK: Restarts

    /// A slowdown raised on day 17, a restart at 08:00 on day 18, and the days after at `after` ms.
    private func restarted(_ source: RouterRestart.Source, after: Double) -> RouterRecord {
        var router = record(series(18, rtt: climb))
        router.update(now: at(17, 20), calendar: calendar)
        router.restarted(at: at(18, 8), source: source, outageSeconds: source == .outage ? 140 : nil)
        router.hours = series(20) { day, hour in day >= 18 ? after : climb(day, hour) }
        return router
    }

    @Test func restartThatFixesIt() {
        var router = restarted(.button, after: 4)
        // Under a day later it is still watching.
        router.update(now: at(18, 20), calendar: calendar)
        #expect(router.restarts.last?.outcome == nil)
        #expect(RouterReport(router, now: at(18, 20), calendar: calendar).followUp?.hasPrefix("Restarted ") == true)
        let events = router.update(now: at(19, 9), calendar: calendar)
        #expect(router.restarts.last?.outcome == .fixed)
        #expect(router.restarts.last?.before == 15 && router.restarts.last?.after == 4)
        #expect(router.episode == nil && events.contains { if case .ended = $0 { true } else { false } })
        let report = RouterReport(router, now: at(19, 9), calendar: calendar)
        #expect(report.followUp == "Since the restart: back to 4 ms ✓" && report.followUpGood == true && report.showsFinding)
        // Two days on, the follow-up has had its say.
        #expect(RouterReport(router, now: at(21, 10), calendar: calendar).showsFinding == false)
    }

    @Test func restartThatDoesNotHelp() {
        var router = restarted(.button, after: 18)
        router.update(now: at(19, 9), calendar: calendar)
        #expect(router.restarts.last?.outcome == .notFixed)
        #expect(router.episode != nil)
        let report = RouterReport(router, now: at(19, 9), calendar: calendar)
        #expect(report.followUp == "Since the restart: still 18 ms. Restarting didn’t help this time." && report.followUpGood == false)
        #expect(report.advice?.hasPrefix("Restarting it didn’t help last time.") == true)
    }

    @Test func seenOutageWithNoChangeIsUnclear() {
        // It may have been the Mac's own Wi-Fi, not a restart, so it never says restarting didn't help.
        var router = restarted(.outage, after: 18)
        router.update(now: at(19, 9), calendar: calendar)
        #expect(router.restarts.last?.outcome == .unclear)
        #expect(RouterReport(router, now: at(19, 9), calendar: calendar).advice?.hasPrefix("Restarting it often helps.") == true)
        // A seen outage that fixed it counts like a reported one.
        var fixed = restarted(.outage, after: 4)
        fixed.update(now: at(19, 9), calendar: calendar)
        #expect(fixed.restarts.last?.outcome == .fixed)
    }

    @Test func restartWithTooLittleDataAfterIsUnclear() {
        var router = record(series(18, rtt: climb))
        router.update(now: at(17, 20), calendar: calendar)
        router.restarted(at: at(18, 8), source: .button)
        #expect(router.update(now: at(19, 9), calendar: calendar).isEmpty)
        router.update(now: at(21, 9), calendar: calendar)
        #expect(router.restarts.last?.outcome == .unclear)
    }

    @Test func restartWhileHealthySaysNothingAboutRestarts() {
        var router = record(series(20) { _, _ in 4 })
        router.restarted(at: at(18, 8), source: .outage, outageSeconds: 90)
        router.update(now: at(19, 9), calendar: calendar)
        #expect(router.restarts.last?.outcome == .noProblem && router.restarts.last?.counts == false)
        #expect(RouterReport(router, now: at(19, 9), calendar: calendar).showsFinding == false)
    }

    @Test func buttonAfterSeenOutageIsOneRestart() {
        var router = record(series(18, rtt: climb))
        router.update(now: at(17, 20), calendar: calendar)
        router.restarted(at: at(18, 8), source: .outage, outageSeconds: 120)
        router.restarted(at: at(18, 8, minute: 40), source: .button)
        #expect(router.restarts.count == 1 && router.restarts[0].source == .button && router.restarts[0].episode == router.episode?.id)
    }

    @Test func adviceFromRestartHistory() {
        func restart(_ outcome: RouterRestart.Outcome) -> RouterRestart { var r = RouterRestart(date: at(0), source: .button, episode: UUID()); r.outcome = outcome; return r }
        #expect(RouterReport.advice([]).hasPrefix("Restarting it often helps."))
        #expect(RouterReport.advice([restart(.fixed)]) == "Restarting it fixed this last time.")
        #expect(RouterReport.advice([restart(.fixed), restart(.helped), restart(.fixed)]) == "Restarting it fixed this the last 3 times.")
        #expect(RouterReport.advice([restart(.notFixed), restart(.fixed), restart(.fixed)]) == "Restarting it fixed this 2 of the last 3 times.")
        #expect(RouterReport.advice([restart(.fixed), restart(.notFixed), restart(.notFixed)]).contains("firmware update"))
        // Unclear and healthy-time restarts don't count either way.
        #expect(RouterReport.advice([restart(.fixed), restart(.unclear), restart(.noProblem)]) == "Restarting it fixed this last time.")
    }

    // MARK: Detecting restarts

    @Test func outageTrackerTellsRestartsFromDrops() {
        var tracker = OutageTracker()
        #expect(tracker.observe(router: "r", reachable: true, gone: false, date: at(0, 10), interval: 60) == nil)
        // Two minutes with no Wi-Fi network at all, then the same router.
        #expect(tracker.observe(router: nil, reachable: false, gone: true, date: at(0, 10, minute: 1), interval: 60) == nil)
        #expect(tracker.observe(router: nil, reachable: false, gone: true, date: at(0, 10, minute: 2), interval: 60) == nil)
        #expect(tracker.observe(router: "r", reachable: true, gone: false, date: at(0, 10, minute: 3), interval: 60) == .restart(router: "r", at: at(0, 10, minute: 1), seconds: 180))
        // One check without a network is a drop.
        _ = tracker.observe(router: nil, reachable: false, gone: true, date: at(0, 10, minute: 4), interval: 60)
        #expect(tracker.observe(router: "r", reachable: true, gone: false, date: at(0, 10, minute: 5), interval: 60) == .drop(router: "r", at: at(0, 10, minute: 4)))
        // One check without replies, the route still there, is lost pings.
        _ = tracker.observe(router: "r", reachable: false, gone: false, date: at(0, 10, minute: 6), interval: 60)
        #expect(tracker.observe(router: "r", reachable: true, gone: false, date: at(0, 10, minute: 7), interval: 60) == nil)
    }

    @Test func outageTrackerIgnoresSleepOtherRoutersAndLongOutages() {
        var tracker = OutageTracker()
        _ = tracker.observe(router: "r", reachable: true, gone: false, date: at(0, 10), interval: 60)
        _ = tracker.observe(router: nil, reachable: false, gone: true, date: at(0, 10, minute: 1), interval: 60)
        // The Mac slept: the next check comes 40 minutes later.
        _ = tracker.observe(router: nil, reachable: false, gone: true, date: at(0, 10, minute: 41), interval: 60)
        #expect(tracker.observe(router: "r", reachable: true, gone: false, date: at(0, 10, minute: 42), interval: 60) == nil)
        // Back through another router: not this one's restart.
        _ = tracker.observe(router: nil, reachable: false, gone: true, date: at(0, 10, minute: 43), interval: 60)
        _ = tracker.observe(router: nil, reachable: false, gone: true, date: at(0, 10, minute: 44), interval: 60)
        #expect(tracker.observe(router: "other", reachable: true, gone: false, date: at(0, 10, minute: 45), interval: 60) == nil)
        #expect(tracker.observe(router: "r", reachable: true, gone: false, date: at(0, 10, minute: 46), interval: 60) == nil)
        // Fifteen minutes without it is an outage, not a restart.
        var minute = 47
        while minute < 62 { _ = tracker.observe(router: nil, reachable: false, gone: true, date: at(0, 10, minute: minute), interval: 60); minute += 1 }
        #expect(tracker.observe(router: "r", reachable: true, gone: false, date: at(0, 11, minute: 2), interval: 60) == nil)
    }

    @MainActor @Test func watchRecordsARestartFromHealthChecks() {
        let watch = RouterWatch(directory: nil, calendar: calendar)
        func snapshot(_ date: Date, router: Double?, gateway: String? = "192.168.1.1") -> DiagnosticSnapshot {
            DiagnosticSnapshot(date: date, radio: RadioSample(bssid: "aa:bb:cc:00:00:01", ssid: "Home", interface: "en0", rssi: -55, noise: -92, transmitMbps: 866, channel: 36, band: "5 GHz"),
                               gateway: gateway, router: gateway == nil ? nil : PingResult(host: gateway!, samples: router.map { [$0, $0, $0, $0] } ?? [], lossPercent: router == nil ? 100 : 0),
                               internet: PingResult(host: "1.1.1.1", samples: [20], lossPercent: 0), dnsMilliseconds: 15, dnsServers: ["192.168.1.1"],
                               captivePortal: false, networkService: "Wi-Fi")
        }
        for minute in 0..<10 { watch.ingest(snapshot(at(0, 10, minute: minute), router: 4), mac: "f4:92:bf:10:20:30", busy: false, interval: 60) }
        watch.ingest(snapshot(at(0, 10, minute: 10), router: nil, gateway: nil), mac: nil, busy: false, interval: 60)
        watch.ingest(snapshot(at(0, 10, minute: 11), router: nil, gateway: nil), mac: nil, busy: false, interval: 60)
        watch.ingest(snapshot(at(0, 10, minute: 12), router: nil), mac: nil, busy: false, interval: 60)
        watch.ingest(snapshot(at(0, 10, minute: 13), router: 4), mac: "f4:92:bf:10:20:30", busy: false, interval: 60)
        #expect(watch.records.count == 1)
        #expect(watch.records[0].restarts.map(\.source) == [.outage])
        #expect(watch.records[0].restarts[0].outageSeconds == 240)
        // A busy check is counted aside, never as a reply time.
        watch.ingest(snapshot(at(0, 10, minute: 14), router: 90), mac: "f4:92:bf:10:20:30", busy: true, interval: 60)
        #expect(watch.records[0].draft?.rtts.count == 11 && watch.records[0].draft?.busy == 1)
        #expect(watch.records[0].draft?.lost == 4)
        // A replaced router on the same network keeps its own history.
        watch.ingest(snapshot(at(0, 10, minute: 15), router: 4), mac: "00:11:22:33:44:55", busy: false, interval: 60)
        #expect(watch.records.count == 2)
    }

    @MainActor @Test func signInPageChecksStayOutOfTheBaseline() {
        let watch = RouterWatch(directory: nil, calendar: calendar)
        func snapshot(_ minute: Int, router: Double, portal: Bool) -> DiagnosticSnapshot {
            DiagnosticSnapshot(date: at(0, 10, minute: minute), radio: RadioSample(bssid: "aa:bb:cc:00:00:01", ssid: "Guest", interface: "en0", rssi: -55, noise: -92, transmitMbps: 866, channel: 36, band: "5 GHz"),
                               gateway: "10.0.0.1", router: PingResult(host: "10.0.0.1", samples: [router, router, router, router], lossPercent: 0),
                               internet: PingResult(host: "1.1.1.1", samples: [], lossPercent: 100), dnsMilliseconds: 900, dnsServers: ["10.0.0.1"],
                               captivePortal: portal, networkService: "Wi-Fi")
        }
        // Behind the sign-in page: the router answers, slowly, while the venue's gateway holds everything else.
        for minute in 0..<10 { watch.ingest(snapshot(minute, router: 40, portal: true), mac: "f4:92:bf:10:20:30", busy: false, interval: 60) }
        for minute in 10..<16 { watch.ingest(snapshot(minute, router: 4, portal: false), mac: "f4:92:bf:10:20:30", busy: false, interval: 60) }
        let draft = watch.records[0].draft
        #expect(draft?.busy == 10 && draft?.rtts == Array(repeating: 4, count: 6) && draft?.dns.count == 6)
        #expect(draft?.hour.rtt == 4)
        // Still answering, so the sign-in page is neither a drop nor a restart.
        #expect(watch.records[0].restarts.isEmpty && draft?.drops == 0)
        #expect(RouterCheck(snapshot(0, router: 40, portal: true), busy: false)?.busy == true)
        #expect(RouterCheck(snapshot(0, router: 4, portal: false), busy: false)?.busy == false)
    }

    // MARK: Busy periods and parsing

    @Test func busyChecksAreLeftOut() {
        #expect(!RouterWatch.busy(checkBytes: 20_000, checkSeconds: 2, sinceBytes: 6_000_000, sinceSeconds: 60))
        #expect(RouterWatch.busy(checkBytes: 400_000, checkSeconds: 2, sinceBytes: nil, sinceSeconds: nil))
        #expect(RouterWatch.busy(checkBytes: 0, checkSeconds: 2, sinceBytes: 60_000_000, sinceSeconds: 60))
        var draft = RouterHourDraft(start: at(0, 9))
        for _ in 0..<8 { draft.add(RouterCheck(date: at(0, 9), rtt: 4)) }
        for _ in 0..<20 { draft.add(RouterCheck(date: at(0, 9), rtt: 60, busy: true)) }
        let hour = draft.hour
        #expect(hour.rtt == 4 && hour.checks == 8 && hour.busy == 20 && hour.qualifies)
        // An hour that was all busy doesn't count toward a day.
        var busy = RouterHourDraft(start: at(0, 10))
        for _ in 0..<30 { busy.add(RouterCheck(date: at(0, 10), rtt: 60, busy: true)) }
        #expect(!busy.hour.qualifies)
    }

    @Test func parsesOptionsAndARP() throws {
        #expect(try RouterReport.Options.parse(["router"]) == RouterReport.Options())
        #expect(try RouterReport.Options.parse(["router", "--json", "--all"]) == RouterReport.Options(json: true, all: true))
        #expect(throws: DiagnosticError.self) { try RouterReport.Options.parse(["router", "--days", "3"]) }
        #expect(RouterWatch.parseARP("? (192.168.1.1) at f4:92:bf:1:2:3 on en0 ifscope [ethernet]") == "f4:92:bf:01:02:03")
        #expect(RouterWatch.parseARP("? (192.168.1.1) at (incomplete) on en0 ifscope [ethernet]") == nil)
    }

    @Test func reportRoundTripsAsJSON() throws {
        var router = record(series(19, rtt: climb))
        router.update(now: at(18, 20), calendar: calendar)
        let data = try JSONEncoder().encode(RouterReport(router, now: at(18, 20), calendar: calendar))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["state"] as? String == "degraded")
        #expect((object["symptoms"] as? [String]) == ["slower"])
        #expect((object["recent"] as? [Any])?.count == 3)
        #expect((object["baseline"] as? [String: Any])?["routerMs"] as? Double == 4)
    }
}
