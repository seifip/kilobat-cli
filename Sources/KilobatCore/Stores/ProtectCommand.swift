import Foundation

/// `kilobat protect …`, parsed: status, on/off for threats, trackers or the agent guard, update, check, allow, unallow.
public enum ProtectCommand: Equatable, Sendable {
    public enum Part: String, Sendable, CaseIterable { case threats, trackers, agents }
    case status(json: Bool)
    case set(on: Bool, parts: [Part], trackerList: String?)
    case update(json: Bool)
    case check(host: String, json: Bool)
    case allow(String)
    case unallow(String)

    public static let usage = "Use protect [status|on|off|update] [--threats|--trackers|--agents] [--list hagezi-light|hagezi-normal|oisd-small|stevenblack], protect check <host>, or protect allow|unallow <host>."

    public static func parse(_ arguments: [String]) throws -> ProtectCommand {
        var args = arguments.first == "protect" ? Array(arguments.dropFirst()) : arguments
        let json = args.contains("--json")
        args.removeAll { $0 == "--json" }
        let verb = args.first ?? "status"
        let rest = Array(args.dropFirst())
        func failure(_ message: String) -> ProtectionUpdater.Failure { ProtectionUpdater.Failure(message: message + " " + usage) }
        func site(_ text: String) -> String? { HostName.normalize(text.hasPrefix("*.") ? String(text.dropFirst(2)) : text) }
        switch verb {
        case "status":
            guard rest.isEmpty else { throw failure("status takes no arguments.") }
            return .status(json: json)
        case "update":
            guard rest.isEmpty else { throw failure("update takes no arguments.") }
            return .update(json: json)
        case "check":
            guard rest.count == 1, HostName.normalize(rest[0]) != nil || URL(string: rest[0])?.host != nil else { throw failure("check takes one host, such as malware.example.") }
            return .check(host: rest[0], json: json)
        case "allow", "unallow":
            guard rest.count == 1, site(rest[0]) != nil else { throw failure("\(verb) takes one host, such as example.com.") }
            return verb == "allow" ? .allow(rest[0]) : .unallow(rest[0])
        case "on", "off":
            var parts: [Part] = [], list: String?, index = 0
            while index < rest.count {
                switch rest[index] {
                case "--threats": parts.append(.threats)
                case "--trackers": parts.append(.trackers)
                case "--agents", "--agent-guard": parts.append(.agents)
                case "--list":
                    guard index + 1 < rest.count, ProtectionLists.trackers.contains(where: { $0.id == rest[index + 1] }) else {
                        throw failure("--list takes hagezi-light, hagezi-normal, oisd-small or stevenblack.")
                    }
                    list = rest[index + 1]; index += 1
                default: throw failure("Unexpected '\(rest[index])'.")
                }
                index += 1
            }
            if list != nil && verb == "off" { throw failure("--list goes with protect on --trackers.") }
            if list != nil && !parts.contains(.trackers) { parts.append(.trackers) }
            let unique = Part.allCases.filter(parts.contains)
            return .set(on: verb == "on", parts: unique.isEmpty ? [.threats] : unique, trackerList: list)
        default: throw failure("Unknown '\(verb)'.")
        }
    }

    /// Applies on/off, allow and unallow to the preferences; false when there was nothing to change.
    @discardableResult public func apply(to preferences: inout SavedPreferences) -> Bool {
        switch self {
        case .set(let on, let parts, let list):
            for part in parts {
                switch part {
                case .threats: preferences.protectThreats = on ? nil : false
                case .trackers: preferences.protectTrackers = on ? true : nil
                case .agents: preferences.agentGuard = on ? true : nil
                }
            }
            if let list { preferences.trackerList = list == ProtectionLists.defaultTracker ? nil : list }
            return true
        case .allow(let site): return ProtectionPreferences.allow(site, in: &preferences) != nil
        case .unallow(let site): return ProtectionPreferences.unallow(site, in: &preferences)
        default: return false
        }
    }
}
