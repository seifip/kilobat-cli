import Foundation

public struct ConnectionRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var app: String
    public var host: String
    public var port: String
    public var direction: String
    public var allowed: Bool
    public var profile: String
    public var expires: Date?
    /// "tcp" or "udp"; nil is either protocol, as every rule saved before protocols were chosen.
    public var transport: String?
    /// For a domain: true matches that exact host name only; nil or false matches the domain and its subdomains, as
    /// every rule saved before this choice did. Addresses and ranges ignore it.
    public var exact: Bool?
    public init(app: String, host: String, port: String = "", direction: String = "any", allowed: Bool, profile: String, expires: Date? = nil,
                transport: String? = nil, exact: Bool? = nil) {
        self.id = UUID(); self.app = app; self.host = Self.storedHost(host); self.port = port; self.direction = direction; self.allowed = allowed; self.profile = profile; self.expires = expires
        self.transport = transport.flatMap { ["tcp", "udp"].contains($0.lowercased()) ? $0.lowercased() : nil }
        self.exact = exact == true && AddressRange(self.host) == nil ? true : nil
    }
    /// The same rule in another profile, with a new id.
    public func copy(profile: String) -> ConnectionRule {
        ConnectionRule(app: app, host: host, port: port, direction: direction, allowed: allowed, profile: profile, expires: expires, transport: transport, exact: exact)
    }
    /// Lower case without outer dots; a CIDR range in its canonical form (10.0.0.7/8 becomes 10.0.0.0/8).
    static func storedHost(_ raw: String) -> String {
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if host.contains("/"), let range = AddressRange(host) { return range.network.description }
        return host
    }
    /// Whether the rule names an IP address or a CIDR range (IPv4 or IPv6) rather than a domain.
    public var isAddressRule: Bool { AddressRange(host) != nil }

    /// A destination as a rule stores it: a domain (its subdomains are a separate choice), an IP address, or a CIDR
    /// range such as 10.0.0.0/8 or 2001:db8::/32. Nil for anything else, and for a range covering every address.
    public static func validDestination(_ raw: String) -> String? {
        let host = storedHost(raw.hasPrefix("*.") ? String(raw.dropFirst(2)) : raw)
        if let range = AddressRange(host) { return range.isEverything ? nil : host }
        guard !host.contains("/"), DomainPolicy.entry(host) == host else { return nil }
        return host
    }

    public func matches(app: String, process: String, host: String?, address: String?, port: String?, direction: String, transport: String? = nil, now: Date = Date()) -> Bool {
        appliesTo(app: app, process: process, port: port, direction: direction, transport: transport, now: now)
            && destinationMatches(host: host, ip: (address.flatMap(AddressRange.parse) ?? host.flatMap(AddressRange.parse)), range: AddressRange(self.host), address: address)
    }
    /// Everything but the destination.
    func appliesTo(app: String, process: String, port: String?, direction: String, transport: String?, now: Date) -> Bool {
        (self.app == app || ProcessRuleKey.keys("process:" + process).contains(self.app))
            && (expires == nil || expires! > now)
            && (self.port.isEmpty || self.port == port)
            && (self.direction == "any" || self.direction == direction)
            && (self.transport == nil || self.transport == transport)
    }
    /// `ip` is the flow's address (or an IP literal it named), parsed once per flow; `range` is this rule's own, parsed
    /// once per policy. A single address matches as a /32 or /128, the same address in any spelling.
    func destinationMatches(host: String?, ip: [UInt8]?, range: AddressRange?, address: String?) -> Bool {
        if let range { return ip.map(range.contains) ?? false }
        if address?.lowercased() == self.host { return true }
        guard let host = host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) else { return false }
        return host == self.host || (exact != true && host.hasSuffix("." + self.host))
    }
}

/// A destination rule with its address range parsed once, as the filter keeps it.
struct CompiledConnectionRule: Sendable {
    let rule: ConnectionRule
    let range: AddressRange?
    init(_ rule: ConnectionRule) { self.rule = rule; range = AddressRange(rule.host) }
    func matches(_ flow: FilterPolicy.Flow, app: String, ip: [UInt8]?, now: Date) -> Bool {
        rule.appliesTo(app: app, process: flow.process, port: flow.port, direction: flow.direction, transport: flow.transport, now: now)
            && rule.destinationMatches(host: flow.host, ip: ip, range: range, address: flow.address)
    }
}

/// A rule for everything one developer signed: the rule key `team:<Team ID>` in a profile's app rules. An app (or a
/// helper that shows up later) with no rule of its own follows it. It matches by code-signing identity, the Team ID
/// the filter checks against the signature, never by which process started which, so it stays clear of process
/// ancestry in enforcement (RESEARCH-DECISIONS, area 4, and "Same-developer rules").
///
/// Never for Apple: Apple's platform code has no Team ID, Apple's own apps are never offered one, and the filter never
/// applies a developer rule to code Apple signed, so one rule can't take out or let through macOS's own services.
public enum DeveloperRule {
    public static let prefix = "team:"

    public static func key(_ team: String) -> String { prefix + team }
    /// The Team ID a rule key names; nil for an app's own key.
    public static func team(_ key: String) -> String? {
        guard key.hasPrefix(prefix) else { return nil }
        let team = String(key.dropFirst(prefix.count))
        return valid(team) ? team : nil
    }
    /// Team IDs are ten upper-case letters and digits.
    public static func valid(_ team: String) -> Bool {
        team.count == 10 && team.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
    }
    /// Whether an app may be offered a developer rule: it has a Team ID and isn't one of Apple's own.
    public static func eligible(identifier: String, team: String?) -> Bool {
        guard let team, valid(team) else { return false }
        return !identifier.hasPrefix("com.apple.")
    }
}

public enum ProcessRuleKey {
    /// Rule keys for an app ID, newest first. Rules saved before full executable names were
    /// resolved use nettop's 15-character truncation.
    public static func keys(_ id: String) -> [String] {
        guard id.hasPrefix("process:"), id.count > 23 else { return [id] }
        return [id, String(id.prefix(23))]
    }
}

/// An app rule that lapses back to the profile default.
public struct TemporaryRule: Codable, Equatable, Sendable {
    public let allowed: Bool
    public let expires: Date
    public let ownership: UUID?
    /// "Until quit": the rule covers only connections from this process, and the app removes it once the process has
    /// exited. `expires` stays as a backstop (a day), so a rule whose end the app never saw still ends.
    public let pid: Int32?
    public init(allowed: Bool, expires: Date, ownership: UUID? = nil, pid: Int32? = nil) {
        self.allowed = allowed; self.expires = expires; self.ownership = ownership; self.pid = pid
    }
    /// Whether the rule covers a connection from `flowPID` at `now`. A process-bound rule never covers a connection
    /// whose process isn't known.
    public func applies(pid flowPID: Int32?, now: Date) -> Bool {
        expires > now && (pid == nil || pid == flowPID)
    }
    /// The longest an "until quit" rule lasts, should the app never see its process exit.
    public static let untilQuitBackstop: TimeInterval = 86_400

    /// Drops process-bound rules whose process has exited; true when any went. `alive` is asked once per pid.
    @discardableResult public static func pruneExited(_ rules: inout [String: TemporaryRule], alive: (Int32) -> Bool) -> Bool {
        var gone = false, known: [Int32: Bool] = [:]
        for (key, rule) in rules {
            guard let pid = rule.pid else { continue }
            let running = known[pid] ?? alive(pid)
            known[pid] = running
            if !running { rules.removeValue(forKey: key); gone = true }
        }
        return gone
    }
}

/// How long an answer in the approval window lasts. Forever is what Allow and Block always did, and stays the default.
public enum ApprovalDuration: String, CaseIterable, Codable, Sendable {
    /// Only the connections waiting now, and the same app's next half-minute (the filter's recent answer); no rule is saved.
    case once
    /// Until the process that asked exits.
    case untilQuit = "until-quit"
    case hour
    case forever

    /// The CLI's and the relay's words: once, until-quit (or quit), hour, forever.
    public init?(word: String) {
        switch word.lowercased() {
        case "once": self = .once
        case "until-quit", "quit", "untilquit": self = .untilQuit
        case "hour", "1h": self = .hour
        case "forever", "always": self = .forever
        default: return nil
        }
    }
}
