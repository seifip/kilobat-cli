import Foundation
import Testing
@testable import KilobatCore

struct BudgetCycleTests {
    /// New York changes clocks on 8 March and 1 November 2026, inside the cycles below.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()
    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func monthlyAnchorPastTheMonthEndStartsOnItsLastDay() {
        let cycle = BudgetCycle(period: .monthly, anchor: 31)
        let mid = cycle.interval(containing: Self.date(2026, 2, 15), calendar: Self.calendar)
        #expect(mid?.start == Self.date(2026, 1, 31, 0))
        #expect(mid?.end == Self.date(2026, 2, 28, 0))
        let last = cycle.interval(containing: Self.date(2026, 2, 28, 10), calendar: Self.calendar)
        #expect(last?.start == Self.date(2026, 2, 28, 0))
        #expect(last?.end == Self.date(2026, 3, 31, 0))
        #expect(cycle.interval(containing: Self.date(2028, 3, 1), calendar: Self.calendar)?.start == Self.date(2028, 2, 29, 0))
        // March is crossed by the clock change; the next cycle still starts at midnight.
        let march = BudgetCycle(period: .monthly, anchor: 1).interval(containing: Self.date(2026, 3, 15), calendar: Self.calendar)
        #expect(march?.start == Self.date(2026, 3, 1, 0) && march?.end == Self.date(2026, 4, 1, 0))
        let marchLength = march?.duration ?? 0
        #expect(marchLength == 31 * 86_400 - 3_600)
    }

    @Test func weeklyAndDailyCyclesFollowTheCalendarAcrossDaylightSaving() {
        // Sunday 1 November 2026, the day clocks go back, in a week that starts on Monday.
        let week = BudgetCycle(period: .weekly, anchor: 2).interval(containing: Self.date(2026, 11, 1), calendar: Self.calendar)
        #expect(week?.start == Self.date(2026, 10, 26, 0))
        #expect(week?.end == Self.date(2026, 11, 2, 0))
        let weekLength = week?.duration ?? 0
        #expect(weekLength == 7 * 86_400 + 3_600)
        let monday = BudgetCycle(period: .weekly, anchor: 2).interval(containing: Self.date(2026, 11, 2, 0), calendar: Self.calendar)
        #expect(monday?.start == Self.date(2026, 11, 2, 0))
        let day = BudgetCycle(period: .daily).interval(containing: Self.date(2026, 3, 8), calendar: Self.calendar)
        #expect(day?.start == Self.date(2026, 3, 8, 0) && day?.duration == 23 * 3_600)
        #expect(BudgetCycle().interval(containing: Date(), calendar: Self.calendar) == nil)
        #expect(BudgetCycle().quotaInterval(containing: Self.date(2026, 3, 8), calendar: Self.calendar).start == Self.date(2026, 3, 8, 0))
    }

    @Test func cycleUsageCountsOnlyThatNetworkInsideTheCycle() {
        let cycle = BudgetCycle(period: .monthly, anchor: 5)
        let interval = cycle.interval(containing: Self.date(2026, 10, 20), calendar: Self.calendar)!
        let usage = [
            UsageEntry(date: Self.date(2026, 10, 4), received: 1_000, sent: 0, apps: ["Dropbox": 1_000], networkKey: "phone"),
            UsageEntry(date: Self.date(2026, 10, 5, 0), received: 300, sent: 200, apps: ["Dropbox": 500], networkKey: "phone", appsSent: ["Dropbox": 200]),
            UsageEntry(date: Self.date(2026, 10, 18), received: 50, sent: 50, apps: ["Safari": 100], networkKey: "phone", appsSent: ["Safari": 50]),
            UsageEntry(date: Self.date(2026, 10, 19), received: 9_000, sent: 0, apps: ["Dropbox": 9_000], networkKey: "home"),
        ]
        #expect(BudgetCycle.used(usage, in: interval, network: "phone") == 600)
        #expect(BudgetCycle.used(usage, in: interval, network: "phone", uploadOnly: true) == 250)
        #expect(BudgetCycle.used(usage, in: interval, network: nil, app: "Dropbox") == 9_500)
        #expect(BudgetCycle.used(usage, in: interval, network: "phone", app: "Dropbox", uploadOnly: true) == 200)
    }

    @Test @MainActor func aMonthlyBudgetCountsHistoryNotTheSessionCounter() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrafficStore(directory: directory, startMonitoring: false)
        let today = Calendar.current.startOfDay(for: Date())
        store.usage = [
            UsageEntry(date: today.addingTimeInterval(1), received: 600_000_000, sent: 0, apps: [:], networkKey: "phone"),
            UsageEntry(date: today.addingTimeInterval(-1), received: 900_000_000, sent: 0, apps: [:], networkKey: "phone"),
            UsageEntry(date: today.addingTimeInterval(2), received: 700_000_000, sent: 0, apps: [:], networkKey: "home"),
        ]
        store.networkKey = "phone"
        store.preferences.limitGB = 1
        #expect(store.budgetUsedBytes == 0)  // A session budget still reads the session counter.
        store.preferences.budgetCycle = BudgetCycle(period: .daily)
        #expect(store.budgetUsedBytes == 600_000_000)
        #expect(store.limitFraction == 0.6)
        #expect(store.preferences.networkCycles?["phone"]?.period == .daily)
        #expect(store.preferences.networkLimits?["phone"] == 1)
    }

    @Test @MainActor func aRelaunchKeepsTheBudgetOfTheNetworkItWasLastOn() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        func sample(_ name: String) -> DiagnosticSnapshot {
            DiagnosticSnapshot(date: Date(), radio: RadioSample(ssid: name, interface: "en0", rssi: -50, noise: -90, transmitMbps: 100, channel: 1, band: "2.4 GHz"), gateway: "192.168.1.1", router: nil, internet: PingResult(host: "test", samples: [10], lossPercent: 0), dnsMilliseconds: 1, dnsServers: [], captivePortal: false, networkService: "Wi-Fi")
        }
        let phone = sample("Phone"), cafe = sample("Cafe")
        let store = TrafficStore(directory: directory, startMonitoring: false)
        store.usage = [UsageEntry(date: Date(), received: 1, sent: 0, apps: [:], networkKey: phone.networkKey)]
        store.preferences.limitGB = 20
        store.preferences.budgetCycle = BudgetCycle(period: .monthly, anchor: 3)
        store.switchNetwork(phone)
        #expect(store.preferences.limitGB == 20 && store.budgetCycle.anchor == 3)
        store.switchNetwork(cafe)
        #expect(store.preferences.limitGB == 5 && store.preferences.budgetCycle == nil)
        store.switchNetwork(phone)
        #expect(store.preferences.limitGB == 20 && store.budgetCycle.period == .monthly)
    }

    @Test func oldPreferencesStillDecode() throws {
        let json = #"{"profile":"Work","rules":{"Work":{"com.example.App":true}},"limitGB":2,"autoHotspot":true,"defaultAllow":false,"networkLimits":{"phone":2}}"#
        let preferences = try JSONDecoder().decode(SavedPreferences.self, from: Data(json.utf8))
        #expect(preferences.limitGB == 2 && preferences.budgetCycle == nil && preferences.quotas == nil && preferences.uploadAlerts == nil)
        var next = preferences
        next.budgetCycle = BudgetCycle(period: .weekly, anchor: 2, alerts: [50, 100])
        next.quotas = [AppQuota(name: "Dropbox", apps: ["com.getdropbox.dropbox"], bytes: 1_000_000_000, uploadOnly: true, network: "phone")]
        #expect(try JSONDecoder().decode(SavedPreferences.self, from: JSONEncoder().encode(next)) == next)
        #expect(BudgetCycle().thresholds.isEmpty && BudgetCycle(period: .monthly).thresholds == [80, 100])
    }
}

struct BudgetAlertTests {
    @Test func thresholdsNotifyOncePerCycleAndRearmBelowThem() throws {
        var ledger = AlertLedger()
        #expect(ledger.crossed([50, 80, 100], fraction: 0.85, key: "budget|phone|1") == [50, 80])
        #expect(ledger.crossed([50, 80, 100], fraction: 0.9, key: "budget|phone|1").isEmpty)
        #expect(ledger.crossed([50, 80, 100], fraction: 1.2, key: "budget|phone|1") == [100])
        var relaunched = try JSONDecoder().decode(AlertLedger.self, from: JSONEncoder().encode(ledger))
        #expect(relaunched.crossed([50, 80, 100], fraction: 1, key: "budget|phone|1").isEmpty)
        #expect(relaunched.crossed([50, 80, 100], fraction: 0.6, key: "budget|phone|2") == [50])
        #expect(relaunched.crossed([50, 80, 100], fraction: 0.2, key: "budget|phone|1").isEmpty)
        #expect(relaunched.crossed([50, 80, 100], fraction: 0.85, key: "budget|phone|1") == [50, 80])
        #expect(relaunched.once("upload|Dropbox|1") && !relaunched.once("upload|Dropbox|1"))
        relaunched.prune(now: Date().addingTimeInterval(40 * 86_400))
        #expect(relaunched.seen.isEmpty)
    }

    @Test @MainActor func budgetAndQuotaAlertsSurviveARelaunch() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrafficStore(directory: directory, startMonitoring: false)
        // A minute ago, but never before midnight, which would put it in yesterday's daily cycle.
        let now = Date(), recent = max(now.addingTimeInterval(-60), Calendar.current.startOfDay(for: now))
        store.usage = [UsageEntry(date: recent, received: 900_000_000, sent: 0, apps: ["Dropbox": 300_000_000], networkKey: "phone")]
        store.networkKey = "phone"; store.networkName = "Phone"
        store.preferences.limitGB = 1
        store.preferences.budgetCycle = BudgetCycle(period: .daily)
        store.preferences.quotas = [AppQuota(name: "Dropbox", apps: ["com.getdropbox.dropbox"], bytes: 200_000_000)]
        let alerts = BudgetWatch(directory: directory).check(store, now: now)
        #expect(alerts.map(\.title) == ["80% of your data budget", "Dropbox reached its quota"])
        #expect(BudgetWatch(directory: directory).check(store, now: now).isEmpty)
        #expect(BudgetWatch(directory: directory).check(store, budgets: false, now: now).isEmpty)
    }
}

struct QuotaPolicyTests {
    func reason(_ change: (inout SavedPreferences) -> Void = { _ in }, budget: Bool = false, quota: [String] = ["com.example.App"]) -> FilterPolicy.Reason {
        var preferences = SavedPreferences()
        preferences.profile = .travel
        change(&preferences)
        return FilterPolicy(FilterController.policy(preferences, budgetReached: budget, quotaReached: quota))
            .decide(.init(app: "com.example.App", process: "App", host: "example.com")).reason
    }

    @Test func aQuotaBlocksAfterTheBudgetButExplicitAllowsWin() {
        #expect(reason() == .quota("com.example.App"))
        #expect(reason(budget: true) == .budget)
        #expect(reason(quota: ["com.other.App"]) == .newAppDefault(false))
        // A saved allow rule is what a quota limits, so the quota comes first.
        #expect(reason { $0.rules["Travel"] = ["com.example.App": true] } == .quota("com.example.App"))
        let temporary = TemporaryRule(allowed: true, expires: Date().addingTimeInterval(600))
        guard case .temporaryRule(let temporaryRule) = reason({ $0.temporaryRules = ["Travel|com.example.App": temporary] }) else { Issue.record("A temporary allow should win"); return }
        #expect(temporaryRule.allowed)
        let rule = ConnectionRule(app: "com.example.App", host: "example.com", allowed: true, profile: "Travel")
        #expect(reason { $0.connectionRules = [rule] } == .connectionRule(rule))
        #expect(reason { $0.profile = .unrestricted } == .unrestricted)
        #expect(FilterController.policy(SavedPreferences(profile: .unrestricted), budgetReached: false, quotaReached: ["com.example.App"])["quotaReached"] as? [String] == [])
        #expect(FilterPolicy.Reason.quota("com.example.App").summary == "App quota reached")
    }

    @Test @MainActor func quotasReachFromHistoryOnTheirNetwork() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrafficStore(directory: directory, startMonitoring: false)
        store.usage = [UsageEntry(date: max(Date().addingTimeInterval(-60), Calendar.current.startOfDay(for: Date())), received: 0, sent: 0, apps: ["Example": 2_000_000_000], networkKey: "phone", appsSent: ["Example": 100_000_000])]
        store.networkKey = "phone"
        store.preferences.quotas = [AppQuota(name: "Example", apps: ["com.example.App", "com.example.Helper"], bytes: 1_000_000_000, network: "phone")]
        #expect(store.quotaReached == ["com.example.App", "com.example.Helper"])
        store.preferences.quotas?[0].uploadOnly = true
        #expect(store.quotaReached.isEmpty)
        store.preferences.quotas?[0].uploadOnly = false
        store.networkKey = "home"
        #expect(store.quotaReached.isEmpty)
    }
}

struct UploadAnomalyTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// `usual` bytes uploaded in each of `hours` earlier hours, then `recent` in the last hour.
    static func usage(usual: UInt64, hours: Int, recent: UInt64) -> [UsageEntry] {
        let past = (1...max(1, hours)).map { hour in
            UsageEntry(date: now.addingTimeInterval(-Double(hour + 2) * 3_600), received: 0, sent: usual, apps: ["Dropbox": usual], networkKey: "home", appsSent: ["Dropbox": usual])
        }
        return Array(past.prefix(hours)) + [UsageEntry(date: now.addingTimeInterval(-600), received: 0, sent: recent, apps: ["Dropbox": recent], networkKey: "home", appsSent: ["Dropbox": recent])]
    }

    @Test func uploadsFiveTimesTheUsualAndOver50MBAlert() {
        let found = UploadAnomaly.detect(Self.usage(usual: 10_000_000, hours: 4, recent: 100_000_000), now: Self.now)
        #expect(found == [UploadAnomaly(app: "Dropbox", bytes: 100_000_000, ratio: 10)])
        #expect(found.first?.message == "Dropbox uploaded 100 MB in the last hour, 10× its usual.")
        #expect(UploadAnomaly.detect(Self.usage(usual: 1_000_000, hours: 4, recent: 40_000_000), now: Self.now).isEmpty)
        #expect(UploadAnomaly.detect(Self.usage(usual: 20_000_000, hours: 4, recent: 60_000_000), now: Self.now).isEmpty)
        #expect(UploadAnomaly.detect(Self.usage(usual: 1_000_000, hours: 2, recent: 900_000_000), now: Self.now).isEmpty)
        #expect(UploadAnomaly.detect(Self.usage(usual: 10_000_000, hours: 4, recent: 30_000_000), pending: ["Dropbox": 30_000_000], now: Self.now).first?.bytes == 60_000_000)
    }
}
