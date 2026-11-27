import AppKit
import Foundation
import KilobatCore

/// Per-app bandwidth, declared access policies, approvals and blocked destinations; `settings new-apps` sets the mode.
/// The MCP tools call the same functions, so both return the same JSON.
@MainActor enum FirewallCLI {
    static func run(_ args: [String]) async throws {
        let json = args.contains("--json")
        let words = args.filter { $0 != "--json" }
        switch words[0] {
        case "bandwidth":
            var range = BandwidthRange.hour, back = 0, app: String?, index = 1
            while index < words.count {
                switch words[index] {
                case "hour", "day", "week", "month": range = rangeNamed(words[index])!; index += 1
                case "--back":
                    guard index + 1 < words.count, let value = Int(words[index + 1]), (0...400).contains(value) else { throw CLIError("Use --back 0…400.") }
                    back = value; index += 2
                default:
                    guard app == nil, !words[index].hasPrefix("--") else { throw CLIError(bandwidthUsage) }
                    app = words[index]; index += 1
                }
            }
            let result = bandwidth(app: app, range: range, back: back)
            if json { print(String(decoding: try object(result), as: UTF8.self)); return }
            let period = result["period"] as? [String: Any] ?? [:]
            print("\(app ?? "All apps") · \(period["label"] as? String ?? "")")
            print("↑ \(TrafficFormat.bytes(result["sentBytes"] as? UInt64 ?? 0)) sent  ↓ \(TrafficFormat.bytes(result["receivedBytes"] as? UInt64 ?? 0)) received")
            if let peak = result["peakBytesPerSecond"] as? Double { print("Peak \(TrafficFormat.rate(peak)) at \(result["peakAt"] as? String ?? "")") }
            if app != nil, (result["receivedBytes"] as? UInt64 ?? 0) + (result["sentBytes"] as? UInt64 ?? 0) == 0 {
                print("No traffic recorded under this name. Names match `kilobat report --summary`.")
            }
        case "access-policy":
            guard words.count == 2 else { throw CLIError("Use access-policy <bundle-id|app-path> [--json].") }
            let result = try policy(app: words[1])
            if json { print(String(decoding: try object(result), as: UTF8.self)); return }
            guard result["declared"] as? Bool == true else { print("\(words[1]) doesn’t declare its connections."); return }
            if let description = result["description"] as? String { print(description) }
            for connection in result["connections"] as? [[String: Any]] ?? [] {
                print("")
                print("\((connection["hosts"] as? [String] ?? []).joined(separator: ", "))\(connection["essential"] as? Bool == true ? "  · essential" : "")")
                print("  \(connection["purpose"] as? String ?? "")")
                if let consequence = connection["denyConsequences"] as? String { print("  If denied: \(consequence)") }
            }
        case "block-host", "unblock-host":
            guard words.count == 2 || (words.count == 4 && words[2] == "--app") else { throw CLIError("Use \(words[0]) <domain|IP|CIDR> [--app <bundle-id|process:name>].") }
            let result = try blockDestination(words[1], app: words.count == 4 ? words[3] : nil, block: words[0] == "block-host", store: TrafficStore(startMonitoring: false))
            if json { print(String(decoding: try object(result), as: UTF8.self)); return }
            print("✓ \(result["blocked"] as? Bool == true ? "Blocked" : "Unblocked") \(result["target"] as? String ?? "") for \(result["app"] as? String ?? "all apps").")
            print("  Enforcement requires the open app and its active signed filter.")
        case "approvals":
            guard words.count == 1 else { throw CLIError("Use approvals [--json].") }
            let pending = try await approvals()
            if json { print(String(decoding: try encode(pending), as: UTF8.self)); return }
            if pending.isEmpty { print("Nothing is waiting for approval."); return }
            for item in pending {
                print("\(item.app)\(item.site.map { "  new site \($0)" } ?? "")  \(item.requests) request\(item.requests == 1 ? "" : "s") · \(item.signatureValid ? "valid signature" : "signature not valid")\(item.signer.map { " · " + $0 } ?? "")")
                if let id = item.approvalID { print("  approval id \(id.uuidString)") }
                for destination in item.destinations.prefix(5) { print("  → \(destination.label)") }
            }
        case "approve", "deny":
            let usage = "Use \(words[0]) <app-id|approval-id> [--minutes 1…1440 | --duration once|until-quit|hour|forever] [--scope host|domain|anywhere]."
            var minutes: Int?, duration: ApprovalDuration?, scope: ApprovalAnswer.Scope?, index = 2
            guard words.count >= 2 else { throw CLIError(usage) }
            while index < words.count {
                guard index + 1 < words.count else { throw CLIError(usage) }
                switch words[index] {
                case "--minutes": minutes = Int(words[index + 1]).flatMap { (1...1440).contains($0) ? $0 : nil }; guard minutes != nil else { throw CLIError("Use --minutes 1…1440.") }
                case "--duration": duration = ApprovalDuration(word: words[index + 1]); guard duration != nil else { throw CLIError(usage) }
                case "--scope": scope = ApprovalAnswer.Scope(rawValue: words[index + 1]); guard scope != nil else { throw CLIError(usage) }
                default: throw CLIError(usage)
                }
                index += 2
            }
            guard minutes == nil || duration == nil else { throw CLIError(usage) }
            let result = try await decide(words[1], allowed: words[0] == "approve", minutes: minutes, duration: duration, scope: scope)
            if json { print(String(decoding: try object(["app": words[1], "decided": result.decided, "confirming": result.confirming, "duration": duration?.rawValue ?? (minutes == nil ? "forever" : "minutes")]), as: UTF8.self)); return }
            if result.confirming { print("Kilobat is asking you to confirm allowing \(words[1]) in its approval window.") }
            else {
                let span = minutes.map { " for \($0) minutes" } ?? duration.map { [.once: " once", .untilQuit: " until it quits", .hour: " for an hour", .forever: ""][$0] ?? "" } ?? ""
                print(result.decided ? "✓ Blocked \(words[1])\(span)." : "\(words[1]) isn’t waiting for approval.")
            }
        default: throw CLIError("Unknown firewall command.")
        }
    }

    static let bandwidthUsage = "Use bandwidth [app] [hour|day|week|month] [--back N] [--json]."
    static func rangeNamed(_ name: String) -> BandwidthRange? {
        ["hour": .hour, "day": .day, "week": .week, "month": .month][name]
    }

    static func bandwidth(app: String?, range: BandwidthRange, back: Int) -> [String: Any] {
        let period = BandwidthPeriod.history(TrafficStore(startMonitoring: false).usage, app: app, range: range, offset: back)
        let formatter = ISO8601DateFormatter()
        var result: [String: Any] = [
            "app": app ?? NSNull(), "range": range.rawValue.lowercased(),
            "period": ["start": formatter.string(from: period.start), "end": formatter.string(from: period.end),
                       "label": period.start.formatted(date: .abbreviated, time: range == .hour || range == .day ? .shortened : .omitted) + " – " + period.end.formatted(date: .abbreviated, time: range == .hour || range == .day ? .shortened : .omitted)],
            "sentBytes": period.sent, "receivedBytes": period.received,
            "buckets": period.buckets.map { ["start": formatter.string(from: $0.start), "sentBytes": $0.sent, "receivedBytes": $0.received] },
        ]
        if let peak = period.peak { result["peakBytesPerSecond"] = peak.rate; result["peakAt"] = formatter.string(from: peak.at) }
        return result
    }

    /// The developer's declared connections for an app found by bundle ID or path.
    static func policy(app: String) throws -> [String: Any] {
        let path = app.hasPrefix("/") ? app : NSWorkspace.shared.urlForApplication(withBundleIdentifier: app)?.path
        guard let path, FileManager.default.fileExists(atPath: path) else { throw CLIError("No app with bundle ID \(app) is installed.") }
        guard let policy = InternetAccessPolicy.load(bundlePath: path) else { return ["app": app, "path": path, "declared": false] }
        return ["app": app, "path": path, "declared": true, "description": policy.description ?? NSNull(), "developer": policy.developer ?? NSNull(),
                "website": policy.website?.absoluteString ?? NSNull(),
                "connections": policy.connections.map { ["hosts": $0.hosts, "incoming": $0.incoming, "protocol": $0.networkProtocol ?? NSNull(), "port": $0.port ?? NSNull(),
                                                         "purpose": $0.purpose, "denyConsequences": $0.denyConsequences ?? NSNull(), "essential": $0.essential] }]
    }

    static func mode(_ store: TrafficStore) -> [String: Any] {
        let preferences = store.preferences
        return ["profile": preferences.profile.rawValue.lowercased(),
                "newApps": preferences.profile == .unrestricted ? "allow" : NewAppPolicy.mode(preferences).rawValue,
                "allowApple": preferences.allowApple == true, "blockedHosts": preferences.blockedHosts ?? []]
    }

    static func setMode(_ store: TrafficStore, newApps: String?, allowApple: Bool?) throws -> [String: Any] {
        if let newApps {
            guard let mode = NewAppPolicy.Mode(rawValue: newApps) else { throw CLIError("Choose allow, alert, ask or block.") }
            mode.apply(to: &store.preferences)
        }
        if let allowApple { store.preferences.allowApple = allowApple }
        return mode(store).merging(["saved": true]) { $1 }
    }

    /// Blocks a domain, IP or range for every app, or adds a connection rule for one app.
    static func blockDestination(_ target: String, app: String?, block: Bool, store: TrafficStore) throws -> [String: Any] {
        guard let entry = DomainPolicy.entry(target) else { throw CLIError("\(target) isn’t a domain, IP address or CIDR range.") }
        if let app {
            guard store.preferences.profile != .unrestricted else { throw CLIError("Unrestricted has no rules. Switch to Essentials or Work first.") }
            var rules = store.preferences.connectionRules ?? []
            rules.removeAll { $0.app == app && $0.host == entry && $0.port.isEmpty && $0.profile == store.preferences.profile.rawValue }
            if block { rules.append(ConnectionRule(app: app, host: entry, port: "", direction: "outgoing", allowed: false, profile: store.preferences.profile.rawValue)) }
            store.preferences.connectionRules = rules
        } else {
            var hosts = Set(store.preferences.blockedHosts ?? [])
            if block { hosts.insert(entry) } else { hosts.remove(entry) }
            store.preferences.blockedHosts = hosts.isEmpty ? nil : hosts.sorted()
        }
        return ["target": entry, "app": app ?? NSNull(), "blocked": block, "profile": app == nil ? NSNull() : store.preferences.profile.rawValue.lowercased(), "saved": true]
    }

    /// The developer rule key for an installed app: `team:<its Team ID>`. Apple's apps and unsigned ones have none.
    static func developerKey(for app: String) throws -> String {
        guard let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app)?.path else { throw CLIError("No app with bundle ID \(app) is installed, so its developer can't be read. Pass team:<Team ID> instead.") }
        let team = DeveloperRule.team(atPath: path)
        guard DeveloperRule.eligible(identifier: app, team: team), let team else { throw CLIError("\(app) has no developer Team ID a rule can use (Apple's software and unsigned apps don't).") }
        return DeveloperRule.key(team)
    }

    static let ruleUsage = "Use rules add <allow|block> <bundle-id|process:name> <domain|IP|CIDR> [--port N] [--protocol any|tcp|udp] [--direction any|outgoing|incoming] [--exact] [--profile name] [--minutes 1…1440] [--json], or rules remove <rule-id>."

    /// `kilobat rules add|remove …`.
    static func rules(_ args: [String]) throws {
        let json = args.contains("--json")
        var words: [String] = [], options: [String: String] = [:], exact = false, index = 1
        while index < args.count {
            let word = args[index]
            switch word {
            case "--json": index += 1
            case "--exact": exact = true; index += 1
            case "--port", "--protocol", "--direction", "--profile", "--minutes":
                guard index + 1 < args.count else { throw CLIError(ruleUsage) }
                options[word] = args[index + 1]; index += 2
            default:
                guard !word.hasPrefix("--") else { throw CLIError(ruleUsage) }
                words.append(word); index += 1
            }
        }
        let store = TrafficStore(startMonitoring: false)
        switch words.first {
        case "add":
            guard words.count == 4, ["allow", "block"].contains(words[1]) else { throw CLIError(ruleUsage) }
            let profile = try options["--profile"].map { name -> NetworkProfile in
                guard let profile = NetworkProfile.named(name) else { throw CLIError("Choose " + NetworkProfile.allCases.map(\.cliName).formatted(.list(type: .or)) + ".") }
                return profile
            }
            let minutes = try options["--minutes"].map { text -> Int in
                guard let value = Int(text), (1...1440).contains(value) else { throw CLIError("Use --minutes 1…1440.") }
                return value
            }
            let result = try saveDestinationRule(store, allowed: words[1] == "allow", app: words[2], destination: words[3], port: options["--port"],
                                                 transport: options["--protocol"], direction: options["--direction"], exact: exact, profile: profile, minutes: minutes)
            if json { print(String(decoding: try object(result), as: UTF8.self)); return }
            let proto = (result["protocol"] as? String).map { " over " + $0.uppercased() } ?? ""
            print("✓ Saved: \(words[1]) \(result["destination"] as? String ?? "") for \(words[2]) in \(result["profile"] as? String ?? "")\(proto)\(exact ? ", exact host only" : "").")
            print("  Rule id \(result["id"] as? String ?? ""). Enforcement requires the open app and its active signed filter.")
        case "remove":
            guard words.count == 2, let id = UUID(uuidString: words[1]) else { throw CLIError(ruleUsage) }
            guard store.preferences.connectionRules?.contains(where: { $0.id == id }) == true else { throw CLIError("No destination rule has the id \(words[1]). See kilobat rules --json.") }
            store.preferences.connectionRules?.removeAll { $0.id == id }
            if json { print(String(decoding: try object(["id": words[1], "removed": true]), as: UTF8.self)); return }
            print("✓ Rule removed.")
        default: throw CLIError(ruleUsage)
        }
    }

    /// One app's rule for a domain (with or without its subdomains), an IP address or a CIDR range, on a port and
    /// protocol. The CLI's `rules add` and MCP's `set_destination_rule` both save through this.
    static func saveDestinationRule(_ store: TrafficStore, allowed: Bool, app: String, destination: String, port: String?, transport: String?, direction: String?,
                                    exact: Bool, profile: NetworkProfile?, minutes: Int?) throws -> [String: Any] {
        guard RuleBackup.validApp(app) else { throw CLIError("Use a bundle ID such as com.example.App, or process:<name>.") }
        guard let host = ConnectionRule.validDestination(destination) else { throw CLIError("\(destination) isn’t a domain, IP address or CIDR range (10.0.0.0/8, 2001:db8::/32).") }
        let port = port ?? ""
        guard port.isEmpty || Int(port).map({ (1...65535).contains($0) }) == true else { throw CLIError("Use a port from 1 to 65535.") }
        let transport = transport?.lowercased() ?? "any", direction = direction?.lowercased() ?? "any"
        guard ["any", "tcp", "udp"].contains(transport) else { throw CLIError("Use --protocol any, tcp or udp.") }
        guard ["any", "outgoing", "incoming"].contains(direction) else { throw CLIError("Use --direction any, outgoing or incoming.") }
        let target = profile ?? store.preferences.profile
        guard target.keepsRules else { throw CLIError("Unrestricted has no rules. Pass --profile essentials or work, or select one first.") }
        let rule = ConnectionRule(app: app, host: host, port: port, direction: direction, allowed: allowed, profile: target.rawValue,
                                  expires: minutes.map { Date().addingTimeInterval(Double($0) * 60) }, transport: transport == "any" ? nil : transport, exact: exact)
        store.preferences.connectionRules = (store.preferences.connectionRules ?? []) + [rule]
        return ["id": rule.id.uuidString, "app": app, "destination": host, "allowed": allowed, "port": port.isEmpty ? NSNull() : port,
                "protocol": rule.transport ?? NSNull(), "direction": direction, "exact": rule.exact == true, "profile": target.rawValue.lowercased(),
                "expires": rule.expires.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(), "saved": true]
    }

    static func approvals() async throws -> [PendingApproval] {
        guard AppRelay.appRunning else { throw CLIError("Approvals need the Kilobat app running with its network filter on.") }
        guard let data = await AppRelay.ask("approvals") else { throw CLIError("The Kilobat app didn’t answer.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PendingApproval].self, from: data)
    }

    /// Blocks apply at once. An allow opens Kilobat's approval window for the person to confirm, so `confirming`
    /// comes back true and `decided` false.
    static func decide(_ app: String, allowed: Bool, minutes: Int?, duration: ApprovalDuration? = nil, scope: ApprovalAnswer.Scope? = nil) async throws -> (decided: Bool, confirming: Bool) {
        guard AppRelay.appRunning else { throw CLIError("Approvals need the Kilobat app running with its network filter on.") }
        guard !app.contains("|") else { throw CLIError("Use an app id or an approval id from kilobat approvals.") }
        let length = duration?.rawValue ?? minutes.map(String.init) ?? ""
        guard let data = await AppRelay.ask("decide|\(allowed ? "allow" : "block")|\(app)|\(length)\(scope.map { "," + $0.rawValue } ?? "")"),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CLIError("The Kilobat app didn’t answer.") }
        return (reply["decided"] as? Bool == true, reply["confirming"] as? Bool == true)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    static func object(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
}
