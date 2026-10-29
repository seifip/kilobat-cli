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
                    guard app == nil else { throw CLIError(bandwidthUsage) }
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
                print("\(item.app)  \(item.requests) request\(item.requests == 1 ? "" : "s") · \(item.signatureValid ? "valid signature" : "signature not valid")\(item.signer.map { " · " + $0 } ?? "")")
                for destination in item.destinations.prefix(5) { print("  → \(destination.label)") }
            }
        case "approve", "deny":
            var minutes: Int?
            if words.count == 4, words[2] == "--minutes" { minutes = Int(words[3]).flatMap { (1...1440).contains($0) ? $0 : nil }; guard minutes != nil else { throw CLIError("Use --minutes 1…1440.") } }
            guard words.count == 2 || minutes != nil else { throw CLIError("Use \(words[0]) <app-id> [--minutes 1…1440].") }
            let result = try await decide(words[1], allowed: words[0] == "approve", minutes: minutes)
            if json { print(String(decoding: try object(["app": words[1], "decided": result.decided, "confirming": result.confirming]), as: UTF8.self)); return }
            if result.confirming { print("Kilobat is asking you to confirm allowing \(words[1]) in its approval window.") }
            else { print(result.decided ? "✓ Blocked \(words[1])\(minutes.map { " for \($0) minutes" } ?? "")." : "\(words[1]) isn’t waiting for approval.") }
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
                "newApps": preferences.profile == .unrestricted ? "allow" : preferences.askNewApps == true ? "ask" : preferences.defaultAllow ? "allow" : "block",
                "allowApple": preferences.allowApple == true, "blockedHosts": preferences.blockedHosts ?? []]
    }

    static func setMode(_ store: TrafficStore, newApps: String?, allowApple: Bool?) throws -> [String: Any] {
        if let newApps {
            guard ["allow", "ask", "block"].contains(newApps) else { throw CLIError("Choose allow, ask or block.") }
            store.preferences.askNewApps = newApps == "ask" ? true : nil
            if newApps != "ask" { store.preferences.defaultAllow = newApps == "allow" }
        }
        if let allowApple { store.preferences.allowApple = allowApple }
        return mode(store).merging(["saved": true]) { $1 }
    }

    /// Blocks a domain, IP or range for every app, or adds a connection rule for one app.
    static func blockDestination(_ target: String, app: String?, block: Bool, store: TrafficStore) throws -> [String: Any] {
        guard let entry = DomainPolicy.entry(target) else { throw CLIError("\(target) isn’t a domain, IP address or CIDR range.") }
        if let app {
            guard store.preferences.profile != .unrestricted else { throw CLIError("Unrestricted has no rules. Switch to Travel or Work first.") }
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

    static func approvals() async throws -> [PendingApproval] {
        guard AppRelay.appRunning else { throw CLIError("Approvals need the Kilobat app running with its network filter on.") }
        guard let data = await AppRelay.ask("approvals") else { throw CLIError("The Kilobat app didn’t answer.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PendingApproval].self, from: data)
    }

    /// Blocks apply at once. An allow opens Kilobat's approval window for the person to confirm, so `confirming`
    /// comes back true and `decided` false.
    static func decide(_ app: String, allowed: Bool, minutes: Int?) async throws -> (decided: Bool, confirming: Bool) {
        guard AppRelay.appRunning else { throw CLIError("Approvals need the Kilobat app running with its network filter on.") }
        guard let data = await AppRelay.ask("decide|\(allowed ? "allow" : "block")|\(app)|\(minutes.map(String.init) ?? "")"),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CLIError("The Kilobat app didn’t answer.") }
        return (reply["decided"] as? Bool == true, reply["confirming"] as? Bool == true)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    static func object(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
}
