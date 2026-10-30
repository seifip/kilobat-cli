import Foundation
import Testing
@testable import KilobatCore

struct WidgetTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func sample(ping: [Double] = [20, 22, 24], router: Double? = 2, ssid: String = "Home Network", age: TimeInterval = 30, portal: Bool = false, rssi: Int = -50) -> DiagnosticSnapshot {
        DiagnosticSnapshot(date: now.addingTimeInterval(-age), radio: RadioSample(ssid: ssid, interface: "en0", rssi: rssi, noise: -90, transmitMbps: 100, channel: 1, band: "5 GHz"),
                           gateway: "192.168.1.1", router: router.map { PingResult(host: "192.168.1.1", samples: [$0], lossPercent: 0) },
                           internet: PingResult(host: "1.1.1.1", samples: ping, lossPercent: ping.isEmpty ? 100 : 0), dnsMilliseconds: 5, dnsServers: ["192.168.1.1"],
                           captivePortal: portal, networkService: "Wi-Fi")
    }
    static func snapshot(diagnostic: DiagnosticSnapshot? = sample(), connected: Bool = true, pro: Bool = true) -> WidgetSnapshot {
        let baseline = PingResult(host: "1.1.1.1", samples: [20], lossPercent: 0)
        let speed = SpeedTestResult(date: now.addingTimeInterval(-3600), downloadMbps: 412, uploadMbps: 38, baseline: baseline, downloadLoaded: baseline, uploadLoaded: baseline,
                                    downloadSeconds: 8, uploadSeconds: 8, transferredBytes: 60_000_000)
        return WidgetSnapshot(now: now, connected: connected, kind: String(localized: "Wi-Fi"), metered: false, diagnostic: diagnostic, samples: [sample(age: 120), sample(age: 60)],
                              today: (1_000_000_000, 100_000_000, [UInt64](repeating: 0, count: 24)), budget: .init(usedBytes: 2_000_000_000, limitBytes: 5_000_000_000, period: "monthly"),
                              speed: speed, pro: pro)
    }

    @Test func statusReadsLikeTheMenuBarBat() {
        #expect(WidgetSnapshot.Status(connected: false, snapshot: Self.sample(), now: Self.now) == .offline)
        #expect(WidgetSnapshot.Status(connected: true, snapshot: nil, now: Self.now) == .checking)
        #expect(WidgetSnapshot.Status(connected: true, snapshot: Self.sample(age: 200), now: Self.now) == .checking)
        #expect(WidgetSnapshot.Status(connected: true, snapshot: Self.sample(portal: true), now: Self.now) == .login)
        #expect(WidgetSnapshot.Status(connected: true, snapshot: Self.sample(), now: Self.now) == .healthy)
        #expect(WidgetSnapshot.Status(connected: true, snapshot: Self.sample(ping: [150, 160]), now: Self.now) == .unstable)
        #expect(WidgetSnapshot.Status(connected: true, snapshot: Self.sample(rssi: -80), now: Self.now) == .poor)
    }

    @Test func snapshotCarriesFiguresButNoNamesOrAddresses() throws {
        let snapshot = Self.snapshot()
        #expect(snapshot.status == .healthy && snapshot.link == .wifi && snapshot.internetMs == 22 && snapshot.routerMs == 2)
        #expect(snapshot.latency == [22, 22] && snapshot.todayBytes == 1_100_000_000 && snapshot.speed?.downMbps == 412)
        #expect(snapshot.budget?.fraction == 0.4)
        let json = String(decoding: try snapshot.encoded(), as: UTF8.self)
        for secret in ["Home Network", "192.168", "1.1.1.1", "en0"] { #expect(!json.contains(secret)) }
        #expect(WidgetSnapshot.decode(try snapshot.encoded()) == snapshot)
    }

    @Test func budgetNeedsPro() {
        let free = Self.snapshot(pro: false)
        #expect(free.budget == nil && !free.pro && free.todayBytes == 1_100_000_000)
    }

    @Test func offlineDropsStaleLatency() {
        let offline = Self.snapshot(connected: false)
        #expect(offline.status == .offline && offline.link == nil && offline.internetMs == nil)
        let old = Self.snapshot(diagnostic: Self.sample(age: 600))
        #expect(old.status == .checking && old.internetMs == nil)
    }

    @Test func staleAfterAQuarterHour() {
        let snapshot = Self.snapshot()
        #expect(!snapshot.stale(at: Self.now.addingTimeInterval(14 * 60)))
        #expect(snapshot.stale(at: Self.now.addingTimeInterval(16 * 60)))
    }

    @Test func hoursCountTodayOnly() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Prague")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 14, minute: 30))!
        let entry: (Int, Int, UInt64) -> UsageEntry = { day, hour, bytes in
            UsageEntry(date: calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: 10))!, received: bytes, sent: 1, apps: [:])
        }
        let hours = WidgetSnapshot.hours([entry(29, 23, 500), entry(30, 9, 100), entry(30, 9, 50), entry(30, 14, 7)], pending: 3, now: now, calendar: calendar)
        #expect(hours.count == 24 && hours[9] == 152 && hours[14] == 11 && hours.reduce(0, +) == 163)
    }

    @Test func reloadsOnlyWhenTheWidgetsWouldChange() {
        var plan = WidgetReloadPlan()
        var snapshot = Self.snapshot()
        #expect(plan.due(snapshot, now: Self.now) == WidgetSnapshot.Kind.all)
        // A small change in ping is not worth a redraw, even after five minutes.
        snapshot.internetMs = 25
        #expect(plan.due(snapshot, now: Self.now.addingTimeInterval(20)).isEmpty)
        #expect(plan.due(snapshot, now: Self.now.addingTimeInterval(360)).isEmpty)
        // A large one is, once five minutes have passed.
        snapshot.internetMs = 90
        #expect(plan.due(snapshot, now: Self.now.addingTimeInterval(370)) == [WidgetSnapshot.Kind.status])
        // A new status redraws a minute after the last redraw, not before.
        snapshot.status = .poor
        #expect(plan.due(snapshot, now: Self.now.addingTimeInterval(400)).isEmpty)
        #expect(plan.due(snapshot, now: Self.now.addingTimeInterval(440)) == [WidgetSnapshot.Kind.status])
        // A new speed test redraws the status and speed widgets.
        snapshot.speed?.date = Self.now.addingTimeInterval(500)
        #expect(plan.due(snapshot, now: Self.now.addingTimeInterval(520)) == [WidgetSnapshot.Kind.status, WidgetSnapshot.Kind.speed])
        // Crossing a 5% budget step redraws the data widget.
        snapshot.budget?.usedBytes = 2_260_000_000
        #expect(plan.due(snapshot, now: Self.now.addingTimeInterval(600)) == [WidgetSnapshot.Kind.data])
        // Before the widgets would call quiet figures stale, the status and data widgets are redrawn anyway.
        #expect(plan.due(snapshot, now: Self.now.addingTimeInterval(600 + WidgetReloadPlan.keepAlive)) == [WidgetSnapshot.Kind.status, WidgetSnapshot.Kind.data])
        // Quitting redraws everything.
        snapshot.running = false
        #expect(plan.due(snapshot, now: Self.now.addingTimeInterval(700 + WidgetReloadPlan.keepAlive)) == WidgetSnapshot.Kind.all)
    }
}
