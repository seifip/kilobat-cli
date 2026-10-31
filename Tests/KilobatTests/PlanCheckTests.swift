import Foundation
import Testing
@testable import KilobatCore

struct PlanCheckTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// 15 January 2027 at `hour`:`minute` UTC, `days` later.
    private func at(_ hour: Int, _ minute: Int = 0, days: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2027, month: 1, day: 15 + days, hour: hour, minute: minute))!
    }
    private func test(_ date: Date, down: Double, up: Double = 40, network: String = "home", scheduled: Bool = true, changed: Bool = false) -> SavedSpeedTest {
        let ping = PingResult(host: "1.1.1.1", samples: [20, 21], lossPercent: 0)
        let result = SpeedTestResult(date: date, downloadMbps: down, uploadMbps: up, baseline: ping, downloadLoaded: ping, uploadLoaded: ping,
                                     downloadSeconds: 2, uploadSeconds: 2, transferredBytes: 40_000_000)
        return SavedSpeedTest(networkKey: network, networkName: "Home", networkChanged: changed ? true : nil, result: result, scheduled: scheduled ? true : nil)
    }
    private func moment(network: String? = "home", plan: Double? = 500, metered: Bool = false, vpn: Bool = false, call: Bool = false, busy: Bool = false,
                        quiet: TimeInterval = 600, onAC: Bool = true, battery: Int? = 90, lowPower: Bool = false) -> PlanCheck.Moment {
        PlanCheck.Moment(enabled: true, network: network, planMbps: plan, connected: true, metered: metered, vpn: vpn, call: call, busy: busy,
                         quietSeconds: quiet, onAC: onAC, batteryPercent: battery, lowPowerMode: lowPower)
    }
    /// The first minute checks may start in the part of the day `date` falls in, plus a minute.
    private func open(_ date: Date, network: String = "home") -> Date {
        PlanCheck.start(of: PlanCheck.window(containing: date, calendar: calendar), network: network).addingTimeInterval(60)
    }

    // MARK: Summary

    @Test func mediansEveningsAndShareUnderHalf() {
        let now = at(12, days: 20)
        // Off-peak: 300, 320, 340, 360 (median 330). Evenings (19–23): 150, 210 (median 180). Under half of 500: 150 and 210.
        let tests = [test(at(9), down: 300), test(at(14, days: 1), down: 320), test(at(10, days: 2), down: 340), test(at(15, days: 3), down: 360),
                     test(at(20, days: 4), down: 150), test(at(21, days: 5), down: 210)]
        let summary = PlanSummary.make(tests: tests, network: "home", planMbps: 500, now: now, calendar: calendar)!
        #expect(summary.checks == 6)
        #expect(summary.scheduledOnly)
        #expect(summary.downloadMedianMbps == 310)
        #expect(summary.percentOfPlan == 62)
        #expect(summary.peakChecks == 2 && summary.peakMedianMbps == 180)
        #expect(summary.offPeakChecks == 4 && summary.offPeakMedianMbps == 330)
        #expect(abs(summary.underHalfPercent - 100.0 / 3) < 0.001)
        #expect(summary.slowestMbps == 150 && summary.fastestMbps == 360)
        #expect(summary.days == 21)
        #expect(summary.headline == "You got 62% of your 500 Mbps")
        #expect(summary.sentence == "Over 21 days, 6 scheduled checks: median 310 Mbps of the 500 Mbps you pay for (62%); evenings 180 Mbps. 33% of them got under half the plan.")
    }

    @Test func countsOnlyThisNetworkInTheWindow() {
        let now = at(12, days: 40)
        let tests = [test(at(9, days: 39), down: 400), test(at(10, days: 38), down: 420), test(at(11, days: 37), down: 440),
                     test(at(9, days: 39), down: 10, network: "café"),
                     test(at(9, days: 36), down: 5, changed: true),
                     test(at(9, days: 1), down: 1)] // more than 30 days before now
        let summary = PlanSummary.make(tests: tests, network: "home", planMbps: 500, now: now, calendar: calendar)!
        #expect(summary.checks == 3)
        #expect(summary.downloadMedianMbps == 420)
        #expect(summary.peakMedianMbps == nil && !summary.peakShown)
        #expect(summary.underHalfPercent == 0)
        #expect(!summary.sentence.contains("evenings"))
        #expect(!summary.sentence.contains("under half"))
    }

    @Test func usesTestsYouRanUntilThereAreEnoughScheduledChecks() {
        let now = at(12, days: 3)
        let few = [test(at(9), down: 200), test(at(10, days: 1), down: 240, scheduled: false), test(at(11, days: 2), down: 260, scheduled: false)]
        let mixed = PlanSummary.make(tests: few, network: "home", planMbps: 300, now: now, calendar: calendar)!
        #expect(!mixed.scheduledOnly && mixed.checks == 3)
        #expect(mixed.sentence.hasPrefix("Over 4 days, 3 speed tests: median 240 Mbps"))
        let enough = few + [test(at(9, days: 1), down: 100), test(at(9, days: 2), down: 120)]
        let scheduled = PlanSummary.make(tests: enough, network: "home", planMbps: 300, now: now, calendar: calendar)!
        #expect(scheduled.scheduledOnly && scheduled.checks == 3)
        #expect(scheduled.downloadMedianMbps == 120)
    }

    @Test func nothingWithoutAPlanOrATest() {
        let tests = [test(at(9), down: 200)]
        #expect(PlanSummary.make(tests: tests, network: "home", planMbps: nil, now: at(12), calendar: calendar) == nil)
        #expect(PlanSummary.make(tests: tests, network: "home", planMbps: 0, now: at(12), calendar: calendar) == nil)
        #expect(PlanSummary.make(tests: tests, network: "unknown", planMbps: 500, now: at(12), calendar: calendar) == nil)
        #expect(PlanSummary.make(tests: [], network: "home", planMbps: 500, now: at(12), calendar: calendar) == nil)
    }

    // MARK: Schedule

    @Test func partsOfTheDayAndTheNightAcrossMidnight() {
        #expect(PlanCheck.daypart(at(5, 59), calendar: calendar) == .night)
        #expect(PlanCheck.daypart(at(6), calendar: calendar) == .morning)
        #expect(PlanCheck.daypart(at(18, 59), calendar: calendar) == .afternoon)
        #expect(PlanCheck.daypart(at(19), calendar: calendar) == .evening)
        #expect(PlanCheck.daypart(at(23), calendar: calendar) == .night)
        let night = PlanCheck.window(containing: at(2), calendar: calendar)
        #expect(night.interval.start == at(23, days: -1) && night.interval.end == at(6))
        let late = PlanCheck.window(containing: at(23, 30), calendar: calendar)
        #expect(late.interval.start == at(23) && late.interval.end == at(6, days: 1))
        let evening = PlanCheck.window(containing: at(20), calendar: calendar)
        #expect(evening.daypart == .evening && evening.interval.duration == 4 * 3600)
    }

    @Test func startsAtAVariedMinuteThatLeavesTimeToRun() {
        var minutes = Set<Int>()
        for day in 0..<14 {
            let window = PlanCheck.window(containing: at(20, days: day), calendar: calendar)
            let start = PlanCheck.start(of: window, network: "home")
            #expect(start >= window.interval.start && start <= window.interval.end.addingTimeInterval(-90 * 60))
            #expect(start == PlanCheck.start(of: window, network: "home"))
            minutes.insert(Int(start.timeIntervalSince(window.interval.start) / 60))
        }
        #expect(minutes.count > 7)
    }

    @Test func runsOnceThePartOfTheDayOpens() {
        let opens = open(at(9))
        #expect(PlanCheck.wait(moment(), history: [], now: opens, calendar: calendar) == nil)
        let window = PlanCheck.window(containing: at(9), calendar: calendar)
        if PlanCheck.start(of: window, network: "home") > window.interval.start {
            #expect(PlanCheck.wait(moment(), history: [], now: window.interval.start, calendar: calendar) == .later)
        }
    }

    @Test func atMostThreeADayOnePerPartThreeHoursApart() {
        let now = open(at(15))
        #expect(PlanCheck.wait(moment(), history: [test(now.addingTimeInterval(-2 * 3600), down: 300)], now: now, calendar: calendar) == .recent)
        let earlier = PlanCheck.window(containing: now, calendar: calendar).interval.start.addingTimeInterval(60)
        if now.timeIntervalSince(earlier) >= PlanCheck.gap {
            #expect(PlanCheck.wait(moment(), history: [test(earlier, down: 300)], now: now, calendar: calendar) == .daypartDone)
        }
        let three = [test(now.addingTimeInterval(-23 * 3600), down: 300), test(now.addingTimeInterval(-18 * 3600), down: 300), test(now.addingTimeInterval(-10 * 3600), down: 300)]
        #expect(PlanCheck.wait(moment(), history: three, now: now, calendar: calendar) == .enough)
        // Tests you ran and checks on other networks don't count.
        let others = [test(now.addingTimeInterval(-3600), down: 300, scheduled: false), test(now.addingTimeInterval(-3600), down: 300, network: "café")]
        #expect(PlanCheck.wait(moment(), history: others, now: now, calendar: calendar) == nil)
    }

    @Test func keepsTheThirdCheckForTheEvening() {
        let afternoon = open(at(15))
        let two = [test(at(1), down: 300), test(at(8), down: 300)]
        #expect(PlanCheck.wait(moment(), history: two, now: afternoon, calendar: calendar) == .evening)
        #expect(PlanCheck.wait(moment(), history: two, now: open(at(20)), calendar: calendar) == nil)
        let withEvening = [test(at(20, days: -1), down: 200), test(at(8), down: 300)]
        #expect(PlanCheck.wait(moment(), history: withEvening, now: afternoon, calendar: calendar) == nil)
    }

    @Test func waitsForAQuietMacOnAFreeNetwork() {
        let now = open(at(10))
        func wait(_ moment: PlanCheck.Moment) -> PlanCheck.Wait? { PlanCheck.wait(moment, history: [], now: now, calendar: calendar) }
        var off = moment(); off.enabled = false
        #expect(wait(off) == .off)
        #expect(wait(moment(network: nil)) == .network)
        #expect(wait(moment(plan: nil)) == .noPlan)
        #expect(wait(moment(metered: true)) == .metered)
        #expect(wait(moment(busy: true)) == .busy)
        #expect(wait(moment(call: true)) == .call)
        #expect(wait(moment(vpn: true)) == .vpn)
        #expect(wait(moment(quiet: 30)) == .traffic)
        #expect(wait(moment(onAC: false, battery: 50)) == .battery)
        #expect(wait(moment(onAC: false, battery: 51)) == nil)
        #expect(wait(moment(onAC: true, battery: 10)) == nil)
        #expect(wait(moment(lowPower: true)) == .battery)
    }

    @Test func sizesTheTestForThePlan() {
        #expect(PlanCheck.budget(planMbps: 20) == 25_000_000)
        #expect(PlanCheck.budget(planMbps: 100) == 31_250_000)
        #expect(PlanCheck.budget(planMbps: 1000) == 80_000_000)
        #expect(PlanCheck.quietRate(planMbps: 100) == 625_000)
        #expect(PlanCheck.quietRate(planMbps: 1000) == 1_000_000)
        #expect(PlanCheck.quietRate(planMbps: 2) == 32_000)
    }

    // MARK: Plans and the report

    @Test func plansPerNetworkWithTheOldSinglePlanBehind() {
        let defaults = UserDefaults(suiteName: "PlanCheckTests-\(UUID().uuidString)")!
        #expect(PlanSpeeds.plan(for: "home", defaults) == nil)
        defaults.set(100.0, forKey: PlanSpeeds.legacyKey)
        #expect(PlanSpeeds.plan(for: "home", defaults) == 100)
        #expect(PlanSpeeds.explicit(for: "home", defaults) == nil)
        PlanSpeeds.set(500, for: "home", defaults)
        #expect(PlanSpeeds.explicit(for: "home", defaults) == 500)
        #expect(PlanSpeeds.plan(for: "café", defaults) == 500)
        PlanSpeeds.set(nil, for: "home", defaults)
        #expect(PlanSpeeds.all(defaults).isEmpty)
        PlanSpeeds.set(300, for: "unknown", defaults)
        #expect(PlanSpeeds.all(defaults).isEmpty)
    }

    @Test func theProviderReportLeadsWithTheMonth() {
        let sample = DiagnosticSnapshot(date: at(12, days: 20), radio: RadioSample(ssid: "Smith Family 5G", interface: "en0", rssi: -55, noise: -95, transmitMbps: 400, channel: 149, band: "5 GHz"),
                                        gateway: "192.168.1.1", router: PingResult(host: "192.168.1.1", samples: [3], lossPercent: 0),
                                        internet: PingResult(host: "1.1.1.1", samples: [20], lossPercent: 0), dnsMilliseconds: 20,
                                        dnsServers: ["192.168.1.1"], captivePortal: false, networkService: "Wi-Fi")
        let key = sample.networkKey
        let tests = [test(at(9), down: 300, network: key), test(at(14, days: 1), down: 320, network: key), test(at(10, days: 2), down: 340, network: key),
                     test(at(20, days: 4), down: 150, network: key), test(at(21, days: 5), down: 210, network: key)]
        let report = SupportReport.make(samples: [sample], events: [], speedTests: tests, hours: 24, planMbps: 100, plans: [key: 500], mac: "Mac", now: at(12, days: 20))
        #expect(report.planMbps == 500)
        #expect(report.planCheck?.checks == 5)
        #expect(report.findings.contains { $0.hasPrefix("Over 21 days, 5 scheduled checks: median 300 Mbps of the 500 Mbps you pay for (60%); evenings 180 Mbps.") })
        for output in [report.text, report.markdown, report.html] {
            #expect(output.contains("Against the plan: 5 scheduled checks over 21 days"))
            #expect(!output.contains("Smith Family"))
        }
    }
}
