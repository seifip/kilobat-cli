import Foundation
import UserNotifications

/// Budget thresholds, app quotas and unusual uploads, checked every half minute while the app runs. Each
/// alert goes out once per cycle (an upload once per app a day), remembered in alerts.json across relaunches.
@MainActor public final class BudgetWatch {
    public private(set) var ledger: AlertLedger
    private let url: URL
    private var task: Task<Void, Never>?

    public init(directory: URL? = nil) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")
        url = directory.appendingPathComponent("alerts.json")
        ledger = StoredJSON.read(url) ?? AlertLedger()
    }

    /// `budgets` says whether budget and quota alerts are on (they are Pro); upload alerts follow their own setting.
    public func start(_ store: TrafficStore, budgets: @escaping @MainActor () -> Bool) {
        guard task == nil else { return }
        task = Task { [weak self, weak store] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, let store else { return }
                for (title, body) in self.check(store, budgets: budgets()) { Self.post(title, body) }
            }
        }
    }

    /// The alerts due now, marked as sent.
    public func check(_ store: TrafficStore, budgets: Bool = true, now: Date = Date()) -> [(title: String, body: String)] {
        var alerts: [(String, String)] = []
        let before = ledger
        if budgets, store.networkKey != "unknown" {
            let cycle = store.budgetCycle, interval = cycle.interval(containing: now)
            let key = "budget|\(store.networkKey)|" + (interval.map { String(Int($0.start.timeIntervalSince1970)) } ?? "session")
            let used = store.budgetUsed(on: store.networkKey, now: now)
            let fraction = Double(used) / Double(max(1, store.limit))
            if let threshold = ledger.crossed(cycle.thresholds, fraction: fraction, key: key, now: now).max() {
                let limit = "\(store.preferences.limitGB.formatted()) GB"
                let resets = interval.map { " " + String(localized: "It resets \($0.end.formatted(.dateTime.day().month())).") } ?? ""
                let name = store.networkName, phrase = cycle.period.phrase
                alerts.append(threshold >= 100
                    ? (String(localized: "Data budget used up"), (cycle.period == .session ? String(localized: "\(name) has used its \(limit) budget.") : String(localized: "\(name) has used its \(limit) budget for \(phrase).")) + resets)
                    : (String(localized: "\(threshold)% of your data budget"), String(localized: "\(TrafficFormat.bytes(used)) of \(limit) used on \(name) \(phrase).") + resets))
            }
        }
        if budgets {
            for quota in store.preferences.quotas ?? [] where quota.applies(to: store.networkKey) {
                let start = store.quotaCycle(quota).quotaInterval(containing: now).start
                let used = store.quotaUsed(quota, now: now)
                if !ledger.crossed([100], fraction: Double(used) / Double(max(1, quota.bytes)), key: "quota|\(quota.id)|\(Int(start.timeIntervalSince1970))", now: now).isEmpty {
                    let bytes = TrafficFormat.bytes(used)
                    alerts.append((String(localized: "\(quota.name) reached its quota"), quota.uploadOnly ? String(localized: "It used \(bytes) of uploads. New connections stop while the network filter is on.") : String(localized: "It used \(bytes). New connections stop while the network filter is on.")))
                }
            }
        }
        if store.preferences.uploadAlerts == true, let day = Calendar.current.dateInterval(of: .day, for: now)?.start {
            for anomaly in store.uploadAnomalies(now: now) where ledger.once("upload|\(anomaly.app)|\(Int(day.timeIntervalSince1970))", now: now) {
                alerts.append((String(localized: "Unusual upload"), anomaly.message))
            }
        }
        ledger.prune(now: now)
        if ledger != before { try? JSONEncoder().encode(ledger).write(to: url, options: .atomic) }
        return alerts
    }

    /// Notifications need an app bundle; macOS asks for permission once, the first time there is something to say.
    private static func post(_ title: String, _ body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }
}
