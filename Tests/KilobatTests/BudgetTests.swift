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
        #expect(BudgetCycle().limitInterval(containing: Self.date(2026, 3, 8), calendar: Self.calendar).start == Self.date(2026, 3, 8, 0))
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

    @Test @MainActor func onlyAnEnabledBlockingBudgetCanStopNewConnections() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrafficStore(directory: directory, startMonitoring: false)
        store.networkKey = "phone"
        store.preferences.networkLimits = ["phone": 5, "other": 2]
        store.usage = [UsageEntry(date: Date(), received: 6_000_000_000, sent: 0, apps: [:], networkKey: "phone")]

        #expect(store.budgetMode == .off)
        // A limit left over from before isn't a budget while the network's is off: the widget once called it used up.
        #expect(store.limit > 0 && !store.hasBudget)
        #expect(store.preferences.budgetMode(for: "other") == .block)
        store.setBudgetMode(.alert)
        #expect(store.hasBudget)
        #expect(store.budgetCycle.thresholds == [80, 100])
        store.preferences.budgetCycle = BudgetCycle(period: .daily)
        #expect(store.limitFraction == 1)
        #expect(!store.budgetBlocksNewConnections)
        store.setBudgetMode(.block)
        #expect(store.budgetBlocksNewConnections)
        store.setBudgetMode(.off)
        #expect(!store.budgetBlocksNewConnections)
        #expect(BudgetWatch(directory: directory).check(store).isEmpty)
        #expect(TrafficStore(directory: directory, startMonitoring: false).preferences.budgetMode(for: "phone") == .off)
    }

    @Test func oldPreferencesStillDecode() throws {
        let json = #"{"profile":"Work","rules":{"Work":{"com.example.App":true}},"limitGB":2,"autoHotspot":true,"defaultAllow":false,"networkLimits":{"phone":2}}"#
        let preferences = try JSONDecoder().decode(SavedPreferences.self, from: Data(json.utf8))
        #expect(preferences.limitGB == 2 && preferences.budgetCycle == nil && preferences.quotas == nil && preferences.uploadAlerts == nil)
        var next = preferences
        next.budgetCycle = BudgetCycle(period: .weekly, anchor: 2, alerts: [50, 100])
        next.quotas = [AppLimit(name: "Dropbox", apps: ["com.getdropbox.dropbox"], bytes: 1_000_000_000, uploadOnly: true, network: "phone")]
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
        store.setBudgetMode(.alert)
        store.preferences.limitGB = 1
        store.preferences.budgetCycle = BudgetCycle(period: .daily)
        store.preferences.quotas = [AppLimit(name: "Dropbox", apps: ["com.getdropbox.dropbox"], bytes: 200_000_000)]
        let alerts = BudgetWatch(directory: directory).check(store, now: now)
        #expect(alerts.map(\.title) == ["80% of your data budget", "Dropbox reached its limit"])
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
        #expect(FilterPolicy.Reason.quota("com.example.App").summary == "App limit reached")
    }

    @Test @MainActor func quotasReachFromHistoryOnTheirNetwork() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrafficStore(directory: directory, startMonitoring: false)
        store.usage = [UsageEntry(date: max(Date().addingTimeInterval(-60), Calendar.current.startOfDay(for: Date())), received: 0, sent: 0, apps: ["Example": 2_000_000_000], networkKey: "phone", appsSent: ["Example": 100_000_000])]
        store.networkKey = "phone"
        store.preferences.quotas = [AppLimit(name: "Example", apps: ["com.example.App", "com.example.Helper"], bytes: 1_000_000_000, network: "phone")]
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

/// Budgets, app limits and prepaid packs as one limit model.
struct LimitModelTests {
    static func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-limits-\(UUID().uuidString)") }

    @Test func savedQuotasAndPacksBecomeBlockingAppLimitsAndAlertingPackBudgets() throws {
        let json = #"""
        {"profile":"Travel","rules":{},"limitGB":5,"autoHotspot":true,"defaultAllow":false,"networkCycles":{"phone":{"period":"weekly","anchor":2}},
         "quotas":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Dropbox","apps":["com.getdropbox.dropbox"],"bytes":1000000000,"uploadOnly":true,"network":"phone"}],
         "dataPacks":[{"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Trip","bytes":10000000000,"start":800000000,"end":802592000,"networks":{"keys":{"phone":"Phone"}}}]}
        """#
        let preferences = try JSONDecoder().decode(SavedPreferences.self, from: Data(json.utf8))
        let limit = try #require(preferences.quotas?.first)
        #expect(limit.mode == nil && limit.effectiveMode == .block && limit.blocks && limit.cycle == nil)
        // A quota followed its network's budget period and only said when it was used up; a total budget counted it by the day.
        let cycle = limit.resolvedCycle(budget: try #require(preferences.networkCycles?["phone"]))
        #expect(cycle.period == .weekly && cycle.anchor == 2 && cycle.thresholds == [100])
        #expect(limit.resolvedCycle(budget: BudgetCycle()).period == .daily)
        let pack = try #require(preferences.dataPacks?.first)
        #expect(pack.mode == nil && pack.budgetMode == .alert)
        var next = preferences
        next.quotas?[0].mode = .alert; next.quotas?[0].cycle = BudgetCycle(period: .monthly, anchor: 5)
        next.dataPacks?[0].mode = .block
        #expect(try JSONDecoder().decode(SavedPreferences.self, from: JSONEncoder().encode(next)) == next)
    }

    @Test @MainActor func alertOnlyAppLimitsNotifyWithoutBlocking() {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrafficStore(directory: directory, startMonitoring: false)
        let now = Date(), recent = max(now.addingTimeInterval(-60), Calendar.current.startOfDay(for: now))
        store.usage = [UsageEntry(date: recent, received: 0, sent: 0, apps: ["Steam": 900_000_000], networkKey: "home")]
        store.networkKey = "home"; store.networkName = "Home"
        store.preferences.quotas = [AppLimit(name: "Steam", apps: ["com.valvesoftware.steam"], bytes: 1_000_000_000, mode: .alert, cycle: BudgetCycle(period: .daily))]
        #expect(store.quotaReached.isEmpty)
        #expect(BudgetWatch(directory: directory).check(store, now: now).map(\.title) == ["80% of Steam’s limit"])
        store.preferences.quotas?[0].bytes = 500_000_000
        #expect(store.quotaReached.isEmpty)
        #expect(BudgetWatch(directory: directory).check(store, now: now).map(\.title) == ["Steam reached its limit"])
        store.preferences.quotas?[0].mode = nil
        #expect(store.quotaReached == ["com.valvesoftware.steam"])
        store.preferences.quotas?[0].mode = .off
        #expect(store.quotaReached.isEmpty && BudgetWatch(directory: directory).check(store, now: now).isEmpty)
    }

    @Test @MainActor func aRunningPackIsTheNetworksBudgetUntilItEnds() throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrafficStore(directory: directory, startMonitoring: false)
        let now = Date(), recent = max(now.addingTimeInterval(-60), Calendar.current.startOfDay(for: now))
        store.usage = [UsageEntry(date: recent, received: 1_500_000_000, sent: 0, apps: [:], networkKey: "phone")]
        store.networkKey = "phone"; store.networkName = "Phone"
        store.setBudgetMode(.block)
        store.preferences.limitGB = 1
        store.preferences.budgetCycle = BudgetCycle(period: .daily)
        #expect(store.budgetBlocksNewConnections)
        let pack = try DataPack.make(name: "Trip", gb: 10, days: 30, start: now.addingTimeInterval(-7_200), networks: DataPackNetworks(keys: ["phone": "Phone"]))
        store.addPack(pack)
        let running = try #require(store.currentPack)
        #expect(store.budgetMode == .alert && store.limit == 10_000_000_000 && !store.budgetBlocksNewConnections)
        #expect(store.budgetUsedBytes == store.packStatus(running).used && store.budgetUsed(on: "phone") >= 1_500_000_000)
        // The network's own budget stays quiet while the pack runs; the pack's alerts come from checkPacks.
        #expect(BudgetWatch(directory: directory).check(store, now: now).isEmpty)
        var blocking = running
        blocking.mode = .block
        store.updatePack(blocking)
        try store.correctPack(pack.id, leftBytes: 0)
        #expect(store.budgetMode == .block && store.limitFraction == 1 && store.budgetBlocksNewConnections && store.budgetLeft == 0)
        store.endPack(pack.id)
        #expect(store.currentPack == nil && store.limit == 1_000_000_000 && store.budgetBlocksNewConnections)
    }

    @Test func aBlockingPackSaysItStopsConnectionsWhenUsedUp() throws {
        let start = Date().addingTimeInterval(-86_400)
        var pack = try DataPack.make(name: "Trip", gb: 1, days: 30, start: start, networks: DataPackNetworks(keys: ["phone": "Phone"]))
        pack.mode = .block
        let usage = [UsageEntry(date: start.addingTimeInterval(7_200), received: 1_000_000_000, sent: 0, apps: [:], networkKey: "phone")]
        let status = DataPacks.status(pack, packs: [pack], usage: usage, names: { _ in "Phone" })
        var ledger = AlertLedger()
        let alert = try #require(DataPackAlert.due([status], ledger: &ledger).first)
        #expect(alert.kind == .threshold(95) && alert.body.hasSuffix("New connections stop while the network filter is on."))
        pack.mode = .off
        var quiet = AlertLedger()
        #expect(DataPackAlert.due([DataPacks.status(pack, packs: [pack], usage: usage, names: { _ in "Phone" })], ledger: &quiet).isEmpty)
    }

    @Test func budgetsAndAppLimitsShareTheResetWording() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        #expect(BudgetCycle().resets() == "counts until you reset it")
        #expect(BudgetCycle(period: .daily).resets() == "starts over each day")
        #expect(BudgetCycle(period: .weekly, anchor: 2).resets(calendar: calendar) == "starts over each Monday")
        #expect(BudgetCycle(period: .monthly, anchor: 5).resets() == "starts over on day 5 of each month")
        #expect(BudgetPeriod.session.title == "In total" && BudgetPeriod.calendar == [.daily, .weekly, .monthly])
        #expect(BudgetCycle.limitChoices.contains(5) && BudgetCycle.alertChoices.contains(95))
    }

    @Test @MainActor func holdingBigUploadsCoversEveryLivePackAndTheNextOne() throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrafficStore(directory: directory, startMonitoring: false)
        #expect(!store.holdsUploadsOnPacks)
        store.holdsUploadsOnPacks = true
        #expect(store.preferences.dataPacks == nil)
        store.addPack(try DataPack.make(gb: 5, days: 10, start: Date().addingTimeInterval(-3_600), networks: DataPackNetworks(keys: ["phone": "Phone"])))
        store.holdsUploadsOnPacks = true
        #expect(store.holdsUploadsOnPacks && store.dataPacks.allSatisfy { $0.holdUploads == true })
        store.addPack(try DataPack.make(gb: 3, days: 5, start: Date().addingTimeInterval(86_400), networks: DataPackNetworks(keys: ["router": "Router"])))
        #expect(store.dataPacks.count == 2 && store.dataPacks.allSatisfy { $0.holdUploads == true })
        store.holdsUploadsOnPacks = false
        #expect(store.dataPacks.allSatisfy { $0.holdUploads == nil })
    }
}
