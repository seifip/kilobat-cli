import AppKit
import KilobatCore

/// `limit` and `quota`: the network budget with its reset cycle and alerts, and per-app quotas.
@MainActor enum QuotaCLI {
    static func run(_ args: [String]) async throws {
        let store = TrafficStore(startMonitoring: false)
        let app = await WiFiCLI.connection()
        if args[0] == "limit" { try limit(args, store: store, app: app) } else { try quota(args, store: store, app: app) }
    }

    static func limit(_ args: [String], store: TrafficStore, app: [String: Any]?) throws {
        var gb: Double?, cycle: String?, resetDay: Int?, alerts: String?, index = 1
        func value() throws -> String {
            guard index + 1 < args.count else { throw CLIError("\(args[index]) needs a value. Run kilobat limit --help.") }
            defer { index += 2 }
            return args[index + 1]
        }
        while index < args.count {
            switch args[index] {
            case "--cycle": cycle = try value()
            case "--reset-day":
                guard let day = Int(try value()) else { throw CLIError("--reset-day takes a number: 1–31 for monthly, 1 (Monday) to 7 (Sunday) for weekly.") }
                resetDay = day
            case "--alert", "--alerts": alerts = try value()
            case let text where gb == nil && !text.hasPrefix("-"):
                guard let amount = Double(text) else { throw CLIError("Use limit <GB>, between 0.1 and 10000.") }
                gb = amount; index += 1
            default: throw CLIError("Unexpected '\(args[index])'. Run kilobat limit --help.")
            }
        }
        let network = currentNetwork(store, app: app)
        if args.count == 1 {
            let budget = budgetJSON(store, app: app)
            let used = (budget["usedBytes"] as? UInt64) ?? 0
            print("Budget: \(store.preferences.limitGB.formatted()) GB · \(store.budgetCycle.summary())")
            if network != nil { print("  " + store.budgetCycle.progress(used: used, limitGB: store.preferences.limitGB)) }
            print("  Alerts: " + (store.budgetCycle.thresholds.isEmpty ? "none" : store.budgetCycle.thresholds.map { "\($0)%" }.joined(separator: ", ")))
            print(Terminal.dim("  Usage is sampled, so the cap is approximate. Blocking needs the app's network filter."))
            return
        }
        try applyBudget(store, gb: gb, cycle: cycle, resetDay: resetDay, alerts: alerts, network: network)
        let thresholds = store.budgetCycle.thresholds
        print("✓ Budget: \(store.preferences.limitGB.formatted()) GB · \(store.budgetCycle.summary()) · alerts \(thresholds.isEmpty ? "off" : "at " + thresholds.map { "\($0)%" }.joined(separator: ", "))")
        print("  With the app's network filter on, new connections stop at the limit. Usage is sampled, so it's approximate.")
    }

    /// Shared by `limit` and the set_budget MCP tool. `network` also records the budget for that network,
    /// so the app keeps it after a relaunch.
    @discardableResult static func applyBudget(_ store: TrafficStore, gb: Double?, cycle: String?, resetDay: Int?, alerts: String?, network: String?) throws -> [String: Any] {
        var preferences = store.preferences, next = store.budgetCycle
        if let gb {
            guard gb.isFinite, (0.1...10_000).contains(gb) else { throw CLIError("The budget must be between 0.1 and 10000 GB.") }
            preferences.limitGB = gb
        }
        if let cycle {
            guard let period = BudgetPeriod(rawValue: cycle.lowercased()) else { throw CLIError("--cycle takes session, daily, weekly or monthly.") }
            if period != next.period { next.period = period; next.anchor = nil }
        }
        if let resetDay {
            switch next.period {
            case .weekly:
                guard (1...7).contains(resetDay) else { throw CLIError("A weekly budget starts on day 1 (Monday) to 7 (Sunday).") }
                next.anchor = resetDay % 7 + 1
            case .monthly:
                guard (1...31).contains(resetDay) else { throw CLIError("A monthly budget starts on day 1 to 31; short months start on their last day.") }
                next.anchor = resetDay
            case .session, .daily: throw CLIError("--reset-day applies to weekly and monthly budgets.")
            }
        }
        if let alerts {
            if ["none", "off"].contains(alerts.lowercased()) { next.alerts = [] } else {
                let values = alerts.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")) }
                guard !values.isEmpty, values.allSatisfy({ $0.map { (1...100).contains($0) } == true }) else { throw CLIError("--alert takes percentages such as 50,80,100, or none.") }
                next.alerts = Array(Set(values.compactMap { $0 })).sorted()
            }
        }
        preferences.budgetCycle = next == BudgetCycle() ? nil : next
        if let network {
            preferences.networkLimits = (preferences.networkLimits ?? [:]).merging([network: preferences.limitGB]) { $1 }
            if let cycle = preferences.budgetCycle { preferences.networkCycles = (preferences.networkCycles ?? [:]).merging([network: cycle]) { $1 } }
            else { preferences.networkCycles?[network] = nil }
        }
        store.preferences = preferences
        return ["limitGB": preferences.limitGB, "cycle": next.period.rawValue, "resetDay": resetDayJSON(next), "alerts": next.thresholds, "saved": true]
    }

    static func quota(_ args: [String], store: TrafficStore, app: [String: Any]?) throws {
        let flags = Set(args.dropFirst().filter { $0.hasPrefix("--") }), values = args.dropFirst().filter { !$0.hasPrefix("--") }
        guard flags.isSubset(of: ["--list", "--json", "--upload", "--all-networks", "--remove"]) else { throw CLIError("Unexpected '\(flags.subtracting(["--list", "--json", "--upload", "--all-networks", "--remove"]).sorted()[0])'. Run kilobat quota --help.") }
        let network = currentNetwork(store, app: app)
        if flags.contains("--list") || values.isEmpty {
            guard values.isEmpty, flags.isSubset(of: ["--list", "--json"]) else { throw CLIError("Use quota --list [--json].") }
            let quotas = quotasJSON(store, app: app)
            if flags.contains("--json") {
                print(String(decoding: try JSONSerialization.data(withJSONObject: ["network": network as Any? ?? NSNull(), "quotas": quotas] as [String: Any], options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
                return
            }
            if quotas.isEmpty { print("No app quotas. Set one with kilobat quota <bundle-id> <GB>."); return }
            for quota in quotas {
                let used = TrafficFormat.bytes(quota["usedBytes"] as? UInt64 ?? 0), limit = TrafficFormat.bytes(quota["limitBytes"] as? UInt64 ?? 0)
                let scope = quota["network"] is NSNull ? "every network" : (quota["network"] as? String) == network ? "this network" : "another network"
                print("\((quota["reached"] as? Bool) == true ? Terminal.rose("●") : "○") \(KilobatCLI.pad(quota["name"] as? String ?? "", 24))\(used) of \(limit)\((quota["uploadOnly"] as? Bool) == true ? " uploaded" : "") · \(scope)")
            }
            print(Terminal.dim("  Usage is sampled, so quotas are approximate. Blocking needs the app's network filter."))
            return
        }
        guard let id = values.first else { throw CLIError("Use quota <bundle-id> <GB> [--upload] [--all-networks], quota <bundle-id> --remove or quota --list.") }
        if flags.contains("--remove") {
            guard values.count == 1, flags == ["--remove"] else { throw CLIError("Use quota <bundle-id> --remove.") }
            print(removeQuota(id, store: store) ? "✓ Removed the quota for \(id)." : "No quota for \(id).")
            return
        }
        guard values.count == 2, let gb = Double(values[1]) else { throw CLIError("Use quota <bundle-id> <GB> [--upload] [--all-networks].") }
        let quota = try setQuota(id, gb: gb, uploadOnly: flags.contains("--upload"), everyNetwork: flags.contains("--all-networks"), network: network, store: store)
        print("✓ \(quota.name) may use \(TrafficFormat.bytes(quota.bytes))\(quota.uploadOnly ? " of uploads" : "") \(quota.network == nil ? "on every network" : "on this network"), " + resets(store.budgetCycle) + ".")
        print("  With the app's network filter on, its new connections stop once it's used up. Usage is sampled, so it's approximate.")
    }

    static func setQuota(_ id: String, gb: Double, uploadOnly: Bool, everyNetwork: Bool, network: String?, store: TrafficStore) throws -> AppQuota {
        guard id.contains(".") || id.hasPrefix("process:"), !id.contains(" ") else { throw CLIError("Use a bundle ID such as com.example.App, or process:<name>, as kilobat status shows them.") }
        guard gb.isFinite, (0.01...10_000).contains(gb) else { throw CLIError("A quota must be between 0.01 and 10000 GB.") }
        guard everyNetwork || network != nil else { throw CLIError("Open Kilobat so the quota can apply to this network, or pass --all-networks.") }
        let quota = AppQuota(name: displayName(id), apps: [id], bytes: UInt64(gb * 1_000_000_000), uploadOnly: uploadOnly, network: everyNetwork ? nil : network)
        store.preferences.quotas = (store.preferences.quotas ?? []).filter { !($0.apps.contains(id) && $0.network == quota.network) } + [quota]
        return quota
    }

    @discardableResult static func removeQuota(_ id: String, store: TrafficStore) -> Bool {
        let before = store.preferences.quotas ?? []
        let after = before.filter { !$0.apps.contains(id) && $0.name != id }
        guard after.count != before.count else { return false }
        store.preferences.quotas = after.isEmpty ? nil : after
        return true
    }

    /// The app as usage history names it: the app's own name, or the process name.
    static func displayName(_ id: String) -> String {
        if id.hasPrefix("process:") { return String(id.dropFirst(8)) }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { AppTrafficGroup.displayName($0.path) } ?? id
    }

    /// The network the app is on, or failing that the one history was last recorded on.
    static func currentNetwork(_ store: TrafficStore, app: [String: Any]?) -> String? {
        if let key = app?["networkKey"] as? String, key != "unknown" { return key }
        return store.usage.last?.networkKey.flatMap { $0 == "unknown" ? nil : $0 }
    }

    static func cycle(for quota: AppQuota, store: TrafficStore, network: String?) -> BudgetCycle {
        guard let key = quota.network, key != network else { return store.budgetCycle }
        return store.preferences.networkCycles?[key] ?? BudgetCycle()
    }

    static func resets(_ cycle: BudgetCycle) -> String {
        switch cycle.period { case .session, .daily: "resetting each day"; case .weekly: "resetting each week"; case .monthly: "resetting each month" }
    }

    /// Weekly reset days count from Monday (1) to Sunday (7), as `--reset-day` takes them.
    static func resetDayJSON(_ cycle: BudgetCycle) -> Any {
        guard let anchor = cycle.anchor else { return NSNull() }
        return cycle.period == .weekly ? (anchor + 5) % 7 + 1 : anchor
    }

    /// The budget for status and rules JSON: limit, cycle, alerts and use in the current cycle.
    static func budgetJSON(_ store: TrafficStore, app: [String: Any]?) -> [String: Any] {
        let cycle = store.budgetCycle, network = currentNetwork(store, app: app)
        let used = (app?["cycleBytes"] as? NSNumber)?.uint64Value ?? network.map { store.budgetUsed(on: $0, cycle: cycle) } ?? 0
        let resets = cycle.interval(containing: Date())?.end
        return ["limitGB": store.preferences.limitGB, "cycle": cycle.period.rawValue, "resetDay": resetDayJSON(cycle), "alerts": cycle.thresholds,
                "usedBytes": used, "usedFraction": (Double(used) / max(1, store.preferences.limitGB * 1_000_000_000) * 1000).rounded() / 1000,
                "resets": resets.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(), "network": network ?? NSNull()]
    }

    static func quotasJSON(_ store: TrafficStore, app: [String: Any]?) -> [[String: Any]] {
        let network = currentNetwork(store, app: app), reached = Set(app?["quotaReached"] as? [String] ?? [])
        return (store.preferences.quotas ?? []).map { quota in
            let cycle = cycle(for: quota, store: store, network: network)
            let used = quota.used(store.usage, cycle: cycle)
            return ["id": quota.id.uuidString, "name": quota.name, "apps": quota.apps, "limitBytes": quota.bytes, "uploadOnly": quota.uploadOnly,
                    "network": quota.network ?? NSNull(), "networkName": quota.network.flatMap { store.networkSessions[$0]?.name } ?? NSNull(),
                    "usedBytes": used, "reached": used >= quota.bytes || !reached.isDisjoint(with: quota.apps),
                    "resets": ISO8601DateFormatter().string(from: cycle.quotaInterval(containing: Date()).end)]
        }
    }
}
