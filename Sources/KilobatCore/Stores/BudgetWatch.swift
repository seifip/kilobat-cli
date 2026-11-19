import Foundation
import UserNotifications

/// Budget thresholds, app limits and unusual uploads, checked every half minute while the app runs. Each
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

    /// Posts a data pack's alert; the app adds the button that holds big uploads. Without it, a plain notification.
    public var packAlert: (@MainActor (DataPackAlert) -> Void)?

    /// `budgets` says whether budget, app limit and data pack alerts are on (they are Pro); upload alerts follow their own setting.
    public func start(_ store: TrafficStore, budgets: @escaping @MainActor () -> Bool) {
        guard task == nil else { return }
        task = Task { [weak self, weak store] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, let store else { return }
                let pro = budgets()
                for (title, body) in self.check(store, budgets: pro) { Self.post(title, body) }
                guard pro else { continue }
                for alert in self.checkPacks(store) {
                    if let packAlert = self.packAlert { packAlert(alert) } else { Self.post(alert.title, alert.body) }
                }
            }
        }
    }

    /// Running data packs' alerts due now, marked as sent: thresholds once each, running out early at most daily.
    public func checkPacks(_ store: TrafficStore, now: Date = Date()) -> [DataPackAlert] {
        let statuses = store.dataPacks.filter { $0.active(at: now) }.map { store.packStatus($0, now: now) }
        guard !statuses.isEmpty else { return [] }
        let before = ledger
        let alerts = DataPackAlert.due(statuses, ledger: &ledger, now: now)
        if ledger != before { try? JSONEncoder().encode(ledger).write(to: url, options: .atomic) }
        return alerts
    }

    /// The alerts due now, marked as sent.
    public func check(_ store: TrafficStore, budgets: Bool = true, now: Date = Date()) -> [(title: String, body: String)] {
        var alerts: [(String, String)] = []
        let before = ledger
        // A running pack is this network's budget instead; its alerts come from `checkPacks`.
        if budgets, store.networkKey != "unknown", store.currentPack == nil, store.preferences.budgetMode(for: store.networkKey) != .off {
            let cycle = store.budgetCycle, interval = cycle.interval(containing: now)
            let key = "budget|\(store.networkKey)|" + (interval.map { String(Int($0.start.timeIntervalSince1970)) } ?? store.budgetSession.map { "session-" + $0.uuidString } ?? "session")
            let used = store.budgetUsed(on: store.networkKey, now: now)
            let fraction = Double(used) / max(1, store.preferences.limitGB * 1_000_000_000)
            if let threshold = ledger.crossed(cycle.thresholds, fraction: fraction, key: key, now: now).max() {
                let limit = "\(store.preferences.limitGB.formatted()) GB"
                let resets = interval.map { " " + String(localized: "It resets \($0.end.formatted(.dateTime.day().month())).") } ?? ""
                let name = store.networkName, phrase = cycle.period.phrase
                alerts.append(threshold >= 100
                    ? (String(localized: "Data budget used up"), (cycle.period == .session ? String(localized: "\(name) has used its \(limit) budget.") : String(localized: "\(name) has used its \(limit) budget for \(phrase).")) + resets)
                    : (String(localized: "\(threshold)% of your data budget"),
                       (cycle.period == .session ? String(localized: "\(TrafficFormat.bytes(used)) of \(limit) used on \(name).") : String(localized: "\(TrafficFormat.bytes(used)) of \(limit) used on \(name) \(phrase).")) + resets))
            }
        }
        if budgets {
            for limit in store.preferences.quotas ?? [] where limit.effectiveMode != .off && limit.applies(to: store.networkKey) {
                let cycle = store.limitCycle(limit), start = cycle.limitInterval(containing: now).start
                let used = store.limitUsed(limit, now: now)
                // Keyed as quotas were, so a limit used up before an update doesn't notify again.
                guard let threshold = ledger.crossed(cycle.thresholds, fraction: Double(used) / Double(max(1, limit.bytes)), key: "quota|\(limit.id)|\(Int(start.timeIntervalSince1970))", now: now).max() else { continue }
                let bytes = TrafficFormat.bytes(used), size = TrafficFormat.bytes(limit.bytes)
                if threshold >= 100 {
                    let stops = limit.blocks ? " " + String(localized: "New connections stop while the network filter is on.") : ""
                    alerts.append((String(localized: "\(limit.name) reached its limit"),
                                   (limit.uploadOnly ? String(localized: "It uploaded \(bytes) of its \(size) limit.") : String(localized: "It used \(bytes) of its \(size) limit.")) + stops))
                } else {
                    alerts.append((String(localized: "\(threshold)% of \(limit.name)’s limit"),
                                   limit.uploadOnly ? String(localized: "It uploaded \(bytes) of \(size) \(cycle.period.phrase).") : String(localized: "It used \(bytes) of \(size) \(cycle.period.phrase).")))
                }
            }
        }
        if store.preferences.uploadAlerts != false, let day = Calendar.current.dateInterval(of: .day, for: now)?.start {
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
