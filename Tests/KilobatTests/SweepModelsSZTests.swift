import Foundation
import Testing
@testable import KilobatCore

struct SweepModelsSZTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let home = "3fa91c07b2d4e5a6f1c20b9d"
    private let cafe = "77aa00bb11cc22dd33ee44ff"
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private func file(networks: String) -> Data {
        Data(#"{"format":"kilobat-settings","version":1,"settings":{},"networks":\#(networks)}"#.utf8)
    }
    private func roundTrip(_ preferences: SavedPreferences, into target: SavedPreferences, current: String?) throws -> SettingsImportPlan {
        let data = try SettingsBackup(preferences: preferences, defaults: [:], areas: [.networks], knownNetworks: [home: "Home Wi-Fi"],
                                      currentNetwork: current, now: now).data()
        return SettingsImportPlan(try SettingsBackup.parse(data), preferences: target, defaults: [:], areas: [.networks],
                                  knownNetworks: [home: "Home Wi-Fi"], currentNetwork: current)
    }

    // MARK: Settings import

    @Test func anAlertOnlyTotalBudgetKeepsItsAlertsThroughImport() throws {
        var current = SavedPreferences()
        current.networkLimits = [home: 20]; current.limitGB = 20
        current.setBudgetMode(.alert, for: home)
        current.budgetCycle = current.networkCycles?[home]
        #expect(current.budgetCycle?.period == .session && current.budgetCycle?.thresholds == [80, 100])
        // The same Mac: nothing changes.
        let same = try roundTrip(current, into: current, current: home)
        #expect(same.lines.isEmpty, "\(same.lines.map(\.text))")
        #expect(same.result == current)
        // Another Mac: the alerts come with the budget.
        let fresh = try roundTrip(current, into: SavedPreferences(), current: home)
        #expect(fresh.result.budgetMode(for: home) == .alert)
        #expect(fresh.result.networkCycles?[home]?.thresholds == [80, 100])
        #expect(fresh.result.budgetCycle?.thresholds == [80, 100])
        // The exported placeholder for no cycle still means no cycle.
        var plain = SavedPreferences()
        plain.networkLimits = [cafe: 3]
        #expect(try roundTrip(plain, into: SavedPreferences(), current: home).result.networkCycles == nil)
    }

    @Test func aBudgetTurnedOffIsImportedOff() throws {
        let networks = #"[{"key":"\#(cafe)","budget":{"limitGB":80,"mode":"off","cycle":{"period":"monthly","anchor":1}}}]"#
        let plan = SettingsImportPlan(try SettingsBackup.parse(file(networks: networks)), preferences: SavedPreferences(), defaults: [:], currentNetwork: home)
        #expect(plan.result.networkLimits?[cafe] == 80 && plan.result.networkCycles?[cafe]?.period == .monthly)
        #expect(plan.result.budgetMode(for: cafe) == .off)
        #expect(!plan.stillToDo(SettingsMacState(filterActive: false, hasPro: true, powerHelperApproved: true, calendarAllowed: true)).contains(.filter))
        var off = SavedPreferences()
        off.networkLimits = [cafe: 80]; off.networkBudgetModes = [cafe: .off]
        #expect(try roundTrip(off, into: SavedPreferences(), current: home).result.budgetMode(for: cafe) == .off)
        // Without a mode in the file, a limit still reads as a blocking budget.
        let bare = SettingsImportPlan(try SettingsBackup.parse(file(networks: #"[{"key":"\#(cafe)","budget":{"limitGB":3}}]"#)), preferences: SavedPreferences(), defaults: [:])
        #expect(bare.result.budgetMode(for: cafe) == .block && bare.result.networkBudgetModes == nil)
    }

    @Test func importedPlanSpeedsAskToReopen() throws {
        let plan = SettingsImportPlan(try SettingsBackup.parse(file(networks: #"[{"key":"\#(home)","planMbps":500}]"#)), preferences: SavedPreferences(), defaults: [:], currentNetwork: home)
        #expect(plan.defaultsChanges[PlanSpeeds.key] == .set(.numbers([home: 500])))
        #expect(plan.needsRelaunch)
    }

    // MARK: Weekly digest

    @Test func aHandledSlotInTheFutureDoesNotSilenceTheDigest() {
        let schedule = DigestSchedule(weekday: 2, hour: 9)
        // Monday 23 November 2026, 09:05 UTC.
        let monday = Date(timeIntervalSince1970: 1_795_424_700), slot = monday.addingTimeInterval(-300)
        let history = monday.addingTimeInterval(-60 * 86_400)
        let decision = schedule.decide(now: monday, last: monday.addingTimeInterval(30 * 86_400), historyStart: history, calendar: Self.utc)
        #expect(decision == .send(slot: slot, week: DigestSchedule.week(for: slot, calendar: Self.utc)))
        #expect(schedule.decide(now: monday, last: slot, historyStart: history, calendar: Self.utc) == .wait)
    }

    // MARK: Provider report

    private func sample(_ minutesAgo: Double) -> DiagnosticSnapshot {
        DiagnosticSnapshot(date: now.addingTimeInterval(-minutesAgo * 60),
                           radio: RadioSample(ssid: "Home Wi-Fi", interface: "en0", rssi: -55, noise: -95, transmitMbps: 400, channel: 149, band: "5 GHz"),
                           gateway: "192.168.1.1", router: PingResult(host: "192.168.1.1", samples: [3], lossPercent: 0),
                           internet: PingResult(host: "1.1.1.1", samples: [30], lossPercent: 0), dnsMilliseconds: 20,
                           dnsServers: ["192.168.1.1"], captivePortal: false, networkService: "Wi-Fi")
    }
    private func saved(_ hoursAgo: Double, _ down: Double, network: String, scheduled: Bool = false, reserved: Bool? = nil) -> SavedSpeedTest {
        let ping = PingResult(host: "example.com", samples: [20], lossPercent: 0)
        let result = SpeedTestResult(date: now.addingTimeInterval(-hoursAgo * 3600), downloadMbps: down, uploadMbps: down / 10, baseline: ping, downloadLoaded: ping,
                                     uploadLoaded: ping, downloadSeconds: 8, uploadSeconds: 8, transferredBytes: 1000)
        return SavedSpeedTest(networkKey: network, networkName: "Home", reservedAttempt: reserved, result: result, scheduled: scheduled ? true : nil)
    }

    @Test func theComplaintPackCountsPlanCheckTests() {
        let samples = [sample(60)], key = samples[0].networkKey
        let tests = [saved(10, 80, network: key, scheduled: true, reserved: true), saved(6, 90, network: key, scheduled: true, reserved: true),
                     saved(2, 100, network: key, scheduled: true, reserved: true)]
        let report = SupportReport.make(samples: samples, events: [], speedTests: tests, hours: 24, mac: "Mac", now: now)
        let evidence = ComplaintEvidence.make(report: report, speedTests: tests, network: key, plan: .init(downloadMbps: 500, minimumMbps: 250), app: "test", calendar: Self.utc)
        #expect(evidence.tests.count == 3)
        #expect(evidence.summary.scheduledTests == 3 && evidence.summary.medianDownMbps == 90)
        #expect(!evidence.gaps.contains(.tests))
        #expect(!evidence.gaps.contains { if case .scheduled = $0 { true } else { false } })
    }

    @Test func leavingOutSiteNamesKeepsTimesWithDots() {
        var report = SupportReport.make(samples: [], events: [], speedTests: [], hours: 24, mac: "Mac", now: now)
        report.check = SupportReport.Check(host: "example.com", ok: true, verdict: "example.com answered", steps: [])
        report.findings = ["The longest lasted 12 min from mié 8:06 p.m.", "Slow every evening 7 p.m.–11 p.m. on 3 days", "Fetched cdn.example.org/a.js and t.co"]
        let hidden = report.withoutSiteNames()
        #expect(hidden.findings[0] == report.findings[0])
        #expect(hidden.findings[1] == report.findings[1])
        #expect(!hidden.findings[2].contains("example.org") && !hidden.findings[2].contains("t.co"))
        #expect(hidden.check?.verdict.contains("example.com") == false)
    }

    @Test func theReportAndThePackStateTheSameMedian() {
        let samples = [sample(60)], key = samples[0].networkKey
        let tests = [saved(8, 20, network: key), saved(6, 40, network: key), saved(4, 60, network: key), saved(2, 80, network: key)]
        let report = SupportReport.make(samples: samples, events: [], speedTests: tests, hours: 24, mac: "Mac", now: now).with(service: .init(minimumMbps: 55))
        let evidence = ComplaintEvidence.make(report: report, speedTests: tests, network: key, plan: .init(downloadMbps: 100, minimumMbps: 55), app: "test", calendar: Self.utc)
        #expect(evidence.summary.medianDownMbps == 50)
        #expect(report.findings.contains { $0.contains("median " + SupportReport.mbps(50)) }, "\(report.findings)")
        #expect(report.findings.contains { $0.contains("under the guaranteed minimum") }, "\(report.findings)")
    }

    // MARK: Speed comparison

    @Test func findingByPlaceWithNoTestsDoesNotCrash() {
        let tests = [saved(2, 50, network: home), saved(1, 60, network: home)]
        #expect(SpeedComparison.find("1", in: []) == nil)
        #expect(SpeedComparison.find("0", in: tests) == nil)
        #expect(SpeedComparison.find("-1", in: tests) == nil)
        #expect(SpeedComparison.find("1", in: tests)?.id == tests[1].id)
    }

    // MARK: Siri

    private func probe(_ date: Date, internetLoss: Double, secondary: PingResult?) -> DiagnosticSnapshot {
        var sample = DiagnosticSnapshot(date: date, radio: RadioSample(ssid: "Home", interface: "en0", rssi: -52, noise: -92, transmitMbps: 600, channel: 149, band: "5 GHz"),
                                        gateway: "192.168.1.1", router: PingResult(host: "router", samples: [3, 3], lossPercent: 0),
                                        internet: PingResult(host: "1.1.1.1", samples: [20, 21, 19], lossPercent: internetLoss), dnsMilliseconds: 18, dnsServers: [],
                                        captivePortal: false, networkService: "Wi-Fi")
        sample.secondary = secondary
        return sample
    }
    private func diagnose(_ snapshot: DiagnosticSnapshot, history: [DiagnosticSnapshot] = []) -> (answer: SiriAnswer, cause: NetworkCause) {
        SiriAnswers.diagnosis(NetworkDiagnosisInput(snapshot: snapshot, history: history, outage: nil, busy: [], services: [], lastSpeed: nil, now: now), pro: true, calendar: Self.utc)
    }

    @Test func oneLostReplyWithTwoTargetsIsFineLikeHealth() {
        let sample = probe(now, internetLoss: 25, secondary: PingResult(host: "8.8.8.8", samples: [22, 23], lossPercent: 0))
        #expect(sample.health == .good)
        let (answer, cause) = diagnose(sample)
        #expect(cause == .fine && answer.tone == .good)
        // Two lost replies: Health says poor, and Siri names the provider.
        let lossy = probe(now, internetLoss: 25, secondary: PingResult(host: "8.8.8.8", samples: [22], lossPercent: 50))
        #expect(lossy.health == .poor)
        #expect(diagnose(lossy).cause == .provider)
        // One lost reply that has gone on for an hour is the provider too.
        let history = (0..<60).map { probe(now.addingTimeInterval(Double(-$0) * 60), internetLoss: 25, secondary: PingResult(host: "8.8.8.8", samples: [22, 23], lossPercent: 0)) }
        #expect(diagnose(sample, history: history).cause == .provider)
    }

    // MARK: Usage comparison

    @Test func sleepCoverageDoesNotDependOnTheOrderOfSleeps() {
        func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
        let period = DateInterval(start: at("2026-10-27T00:00:00Z"), end: at("2026-10-29T00:00:00Z"))
        // 40 minutes of hour 3 (asleep), 20 minutes of hour 10 (not), and all of hour 30.
        let sleeps = [DateInterval(start: at("2026-10-27T03:10:00Z"), end: at("2026-10-27T03:50:00Z")),
                      DateInterval(start: at("2026-10-27T10:40:00Z"), end: at("2026-10-27T11:00:00Z")),
                      DateInterval(start: at("2026-10-28T06:00:00Z"), end: at("2026-10-28T07:00:00Z"))]
        let usage = [UsageEntry(date: at("2026-10-26T00:00:00Z"), received: 1, sent: 0, apps: [:], networkKey: "home")]
        func compare(_ sleeps: [DateInterval]) -> UsageComparison {
            UsageComparison.make(usage, period: period, scope: ["home"], total: 1, unit: .gb, direction: .both, sleeps: sleeps, now: at("2026-10-30T00:00:00Z"), calendar: Self.utc)
        }
        let forward = compare(sleeps), backward = compare(sleeps.reversed())
        #expect(forward.gaps == backward.gaps)
        let hour3 = forward.gaps.first { $0.start <= at("2026-10-27T03:00:00Z") && $0.end > at("2026-10-27T03:00:00Z") }
        let hour10 = forward.gaps.first { $0.start <= at("2026-10-27T10:00:00Z") && $0.end > at("2026-10-27T10:00:00Z") }
        let hour30 = forward.gaps.first { $0.start <= at("2026-10-28T06:00:00Z") && $0.end > at("2026-10-28T06:00:00Z") }
        #expect(hour3?.reason == .asleep && hour3?.hours == 1)
        #expect(hour10?.reason == .notRecorded)
        #expect(hour30?.reason == .asleep && hour30?.hours == 1)
        #expect(forward.gaps.map(\.reason) == [.notRecorded, .asleep, .notRecorded, .asleep, .notRecorded])
    }

    // MARK: Smart home

    @Test func unlistedHomeKitCategoriesCountUnderTheTranslatedOther() {
        let records = [BonjourInstance(type: SmartHomeServices.hap, name: "Speaker", txt: ["ci": Data("26".utf8), "id": Data("AA:BB".utf8)]),
                       BonjourInstance(type: SmartHomeServices.hap, name: "Gadget", txt: ["ci": Data("1".utf8), "id": Data("CC:DD".utf8)])]
        let summary = HomeKitSummary.build(records)
        #expect(summary.categories.count == 1)
        #expect(summary.categories == [HomeKitSummary.categoryNames[1]!: 2])
    }
}
