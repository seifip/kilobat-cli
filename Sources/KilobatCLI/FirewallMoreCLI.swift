import Foundation
import KilobatCore

/// The firewall's advanced parts: blocklist subscriptions, apps that ask about new destinations, the new apps
/// alert mode lists, and the connection log with rule-hit counts. The MCP tools call the same functions.
@MainActor enum FirewallMoreCLI {
    static func run(_ args: [String]) async throws {
        switch args[0] {
        case "blocklists": try await blocklists(args)
        case "new-apps": try newApps(args)
        case "ask-destinations": try askDestinations(args)
        case "connections": try await connections(args)
        default: throw CLIError("Unknown firewall command.")
        }
    }

    // MARK: Connection log and rule hits

    static let connectionsUsage = "Use connections [--log] [--json], or connections --hits [--json]."

    /// The session's log, from the running app's memory; the filter keeps nothing once Kilobat quits.
    static func connectionLog() async throws -> ConnectionLogRelay {
        guard AppRelay.appRunning else { throw CLIError("The connection log lives in the Kilobat app's memory while it runs. Open Kilobat with its network filter on.") }
        guard let data = await AppRelay.ask("connection-log") else { throw CLIError("The Kilobat app didn't answer.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ConnectionLogRelay.self, from: data)
    }

    /// Every rule with how often it decided a connection today and in all, from the app's saved counts.
    static func ruleHits(_ store: TrafficStore, now: Date = Date()) -> [[String: Any]] {
        let counts = RuleHitStore.load(), formatter = ISO8601DateFormatter(), day = DestinationHistory.day(now)
        return store.preferences.listedRules(now: now).compactMap { rule -> [String: Any]? in
            guard let key = RuleHitStore.key(rule) else { return nil }
            let count = counts[key]
            return ["key": key, "allowed": rule.allowed, "app": rule.app ?? NSNull(), "destination": rule.host ?? NSNull(), "profile": rule.profile ?? NSNull(),
                    "today": count.map { $0.day == day ? $0.today : 0 } ?? 0, "total": count?.total ?? 0,
                    "last": count.map { formatter.string(from: $0.last) } ?? NSNull()]
        }
    }

    static func connections(_ args: [String]) async throws {
        let json = args.contains("--json")
        guard args.dropFirst().allSatisfy({ ["--log", "--hits", "--json"].contains($0) }) else { throw CLIError(connectionsUsage) }
        if args.contains("--hits") {
            let rows = ruleHits(TrafficStore(startMonitoring: false))
            if json { print(String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)); return }
            if rows.isEmpty { print("No rules yet."); return }
            for row in rows.sorted(by: { ($0["today"] as? Int ?? 0) > ($1["today"] as? Int ?? 0) }) {
                let target = [row["app"] as? String, row["destination"] as? String].compactMap { $0 }.joined(separator: " → ")
                print("\(row["allowed"] as? Bool == true ? "allow" : "block")  \(target)  \(row["today"] as? Int ?? 0) today · \(row["total"] as? Int ?? 0) in all")
            }
            return
        }
        let log = try await connectionLog()
        if json { print(String(decoding: try ProtectCLI.encode(log), as: UTF8.self)); return }
        if !log.filterActive { print("The network filter is off, so there's no log.") }
        if !log.recording { print("Recording is off (Connections › Log › Record in the app).") }
        if log.entries.isEmpty { print("No connections in the last hour yet."); return }
        for entry in log.entries {
            print("\(entry.last.formatted(date: .omitted, time: .shortened))  \(entry.verdict.padding(toLength: 5, withPad: " ", startingAt: 0))  \(entry.app) → \(entry.destination)\(entry.port.map { ":" + $0 } ?? "")  ×\(entry.count)  \(entry.reason)")
        }
        print("The last hour, in memory only\(log.browsers ? "" : ", browsers left out").")
    }

    // MARK: Asking about new destinations

    static let askUsage = "Use ask-destinations [--json], or ask-destinations on|off <bundle-id|process:name>."

    static func askDestinationsJSON(_ store: TrafficStore) -> [String: Any] {
        ["apps": (store.preferences.askDestinations ?? []).sorted(),
         "note": "These apps ask before reaching a destination their destination rules don't cover; answer in the Kilobat app, or with kilobat approve|deny <approval-id> --scope host|domain|anywhere. With Kilobat closed they connect as before."]
    }

    /// Turning it on holds connections, which is Pro in the app; the CLI stays free, like the rest of its rule commands.
    static func askDestinations(_ args: [String]) throws {
        let json = args.contains("--json")
        let words = Array(args.dropFirst().filter { $0 != "--json" })
        let store = TrafficStore(startMonitoring: false)
        if let action = words.first {
            guard ["on", "off"].contains(action), words.count == 2, RuleBackup.validApp(words[1]) else { throw CLIError(askUsage) }
            AskDestinations.set(words[1], on: action == "on", in: &store.preferences)
            if !json { print(action == "on" ? "✓ \(words[1]) asks before reaching a new destination while the Kilobat app and its filter run." : "✓ \(words[1]) no longer asks about destinations.") ; return }
        }
        let result = askDestinationsJSON(store)
        if json { print(String(decoding: try FirewallCLI.object(result), as: UTF8.self)); return }
        let apps = result["apps"] as? [String] ?? []
        print(apps.isEmpty ? "No app asks about new destinations. Turn it on with kilobat ask-destinations on <app>." : apps.joined(separator: "\n"))
    }

    // MARK: Alert mode's list

    static let newAppsUsage = "Use new-apps [--json], new-apps reviewed <app-id>, or new-apps clear."

    /// The apps alert mode let through, from the app's saved list, minus those that have a rule now.
    static func newAppsList(_ store: TrafficStore) -> [String: Any] {
        let review = NewAppReview()
        let formatter = ISO8601DateFormatter()
        let rows = review.pending(store.preferences).map {
            ["app": $0.app, "process": $0.process, "first": formatter.string(from: $0.first), "last": formatter.string(from: $0.last),
             "connections": $0.connections, "destinations": $0.destinations] as [String: Any]
        }
        return ["mode": NewAppPolicy.mode(store.preferences).rawValue, "apps": rows,
                "note": "Alert mode lets apps without a rule connect and lists them here; give each a rule with kilobat allow|block <app-id>, or mark it reviewed."]
    }

    static func newApps(_ args: [String]) throws {
        let json = args.contains("--json")
        let words = args.dropFirst().filter { $0 != "--json" }
        let store = TrafficStore(startMonitoring: false)
        switch words.first {
        case nil: break
        case "reviewed":
            guard words.count == 2 else { throw CLIError(newAppsUsage) }
            NewAppReview().dismiss(words[words.startIndex + 1])
            if !json { print("✓ \(words[words.startIndex + 1]) is off the list.") ; return }
        case "clear":
            NewAppReview().clear()
            if !json { print("✓ List cleared."); return }
        default: throw CLIError(newAppsUsage)
        }
        let list = newAppsList(store)
        if json { print(String(decoding: try FirewallCLI.object(list), as: UTF8.self)); return }
        let apps = list["apps"] as? [[String: Any]] ?? []
        if NewAppPolicy.mode(store.preferences) != .alert { print("New apps are set to \(NewAppPolicy.mode(store.preferences).rawValue); kilobat settings new-apps alert lists them here.") }
        if apps.isEmpty { print("Nothing to review."); return }
        for app in apps {
            print("\(app["app"] as? String ?? "")  \(app["connections"] as? Int ?? 0) connections since \(app["first"] as? String ?? "")")
            for destination in app["destinations"] as? [String] ?? [] { print("  → \(destination)") }
        }
    }

    // MARK: Blocklist subscriptions

    static let blocklistsUsage = "Use blocklists [--json], blocklists add <https-url> [--name <name>], blocklists remove|on|off <id>, or blocklists update."

    static func blocklists(_ args: [String]) async throws {
        let json = args.contains("--json")
        var words: [String] = [], name: String?, index = 1
        while index < args.count {
            switch args[index] {
            case "--json": index += 1
            case "--name":
                guard index + 1 < args.count else { throw CLIError(blocklistsUsage) }
                name = args[index + 1]; index += 2
            default: words.append(args[index]); index += 1
            }
        }
        let store = TrafficStore(startMonitoring: false)
        switch words.first {
        case nil: break
        case "add":
            guard words.count == 2 else { throw CLIError(blocklistsUsage) }
            do { try BlocklistSubscription.add(name: name, url: words[1], to: &store.preferences) }
            catch let failure as BlocklistSubscription.Failure { throw CLIError(failure.errorDescription ?? blocklistsUsage) }
            if !json { print("✓ Subscribed. Kilobat downloads it now if the app is open, then once a day; run kilobat blocklists update to fetch it here.") }
        case "remove":
            guard words.count == 2, BlocklistSubscription.remove(words[1], from: &store.preferences) else { throw CLIError("No subscription has the id \(words.dropFirst().first ?? ""). See kilobat blocklists.") }
            ProtectionUpdater().forget(words[1])
            if !json { print("✓ Subscription removed.") }
        case "on", "off":
            guard words.count == 2, BlocklistSubscription.set(words[1], on: words[0] == "on", in: &store.preferences) else { throw CLIError("No subscription has the id \(words.dropFirst().first ?? ""). See kilobat blocklists.") }
            if !json { print("✓ \(words[1]) \(words[0]).") }
        case "update":
            let app = await ProtectCLI.appState()
            let lists = ProtectionPreferences.lists(store.preferences, pro: app.pro ?? true)
            guard !ProtectionPreferences.subscriptions(store.preferences).isEmpty else { throw CLIError("No blocklist subscriptions are on. Add one with kilobat blocklists add <https-url>.") }
            let updater = ProtectionUpdater()
            _ = await updater.update(ProtectionPreferences.subscriptions(store.preferences), force: true)
            updater.build(lists, known: ProtectCLI.knownHosts())
            if !json { print("Updated. The app hands the new lists to its filter within a few minutes.") }
        default: throw CLIError(blocklistsUsage)
        }
        let status = await blocklistStatus(store)
        if json { print(String(decoding: try ProtectCLI.encode(status), as: UTF8.self)); return }
        guard words.isEmpty || words.first == "update" else { return }
        if status.lists.isEmpty { print("No blocklist subscriptions. Add one with kilobat blocklists add <https-url> [--name <name>]."); return }
        for row in status.lists { print("\(row.id)  \(row.name)  \(row.on ? "on" : "off")\n  \(row.url)\n  \(BlocklistStatus.detail(row))") }
        if status.filterActive == false { print("The network filter is off, so nothing is blocked.") }
    }

    static func blocklistStatus(_ store: TrafficStore) async -> BlocklistStatus {
        let app = await ProtectCLI.appState()
        return BlocklistStatus.make(store.preferences, state: ProtectionUpdater().loadState(), filterActive: app.filterActive)
    }
}
