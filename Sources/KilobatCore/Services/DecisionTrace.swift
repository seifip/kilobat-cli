import Foundation

// The rule inspector's record: every rule that applied to one connection, in the order `FilterPolicy.decide` checks
// them, and which one decided. Compiled into the filter too, so Foundation and the policy evaluator only.

/// Every rule that applied to a connection, in the order the filter checks them, and the one that decided.
/// `FilterPolicy.decide` stops at the first rule; `FilterPolicy.trace` runs the same checks to the end and records
/// each one that applies, so a rule that lost (an allow rule under a threat, a hold under a block) still shows.
public struct DecisionTrace: Sendable, Equatable {
    public struct Match: Sendable, Equatable {
        public var verdict: FilterPolicy.Verdict
        public var reason: FilterPolicy.Reason
        public init(_ verdict: FilterPolicy.Verdict, _ reason: FilterPolicy.Reason) { self.verdict = verdict; self.reason = reason }
    }
    /// In the filter's order. Notes (an allowed site, the kill switch's local network) sit where they were checked.
    public private(set) var matches: [Match]
    /// The position in `matches` of the rule that decided.
    public private(set) var decided: Int

    public init(matches: [Match], decided: Int) {
        precondition(matches.indices.contains(decided), "a trace needs the rule that decided")
        self.matches = matches; self.decided = decided
    }
    /// One rule alone: what the filter decided outside `decide`, such as the agent guard's large-upload limit.
    public init(_ verdict: FilterPolicy.Verdict, _ reason: FilterPolicy.Reason) { self.init(matches: [Match(verdict, reason)], decided: 0) }

    public var decision: Match { matches[decided] }
    public var verdict: FilterPolicy.Verdict { decision.verdict }
    /// Everything that applied apart from the deciding rule, in order.
    public var others: [Match] { matches.indices.filter { $0 != decided }.map { matches[$0] } }

    /// Collects matches while `FilterPolicy.evaluate` runs. A class so the evaluator's no-trace path stays a nil check.
    final class Builder {
        var matches: [Match] = []
        var decided: Int?
        init() { matches.reserveCapacity(6) }
        /// A rule that decides when nothing earlier did.
        func rule(_ verdict: FilterPolicy.Verdict, _ reason: FilterPolicy.Reason) {
            if decided == nil { decided = matches.count }
            matches.append(Match(verdict, reason))
        }
        /// A rule that applies but never decides on its own.
        func note(_ verdict: FilterPolicy.Verdict, _ reason: FilterPolicy.Reason) { matches.append(Match(verdict, reason)) }
        func finish() -> DecisionTrace { DecisionTrace(matches: matches, decided: decided ?? 0) }
    }
}

extension FilterPolicy.Reason {
    /// False for what only explains a decision and never makes one: a site you allowed past Protection, the kill
    /// switch letting the local network through or paused for a while.
    public var decides: Bool {
        switch self {
        case .siteAllowed, .killSwitchPaused, .killSwitchExempt(.localNetwork): false
        default: true
        }
    }
    /// A stable name for JSON, the CLI and MCP.
    public var rule: String {
        switch self {
        case .filterOff: "filterOff"
        case .unrestricted: "unrestricted"
        case .killSwitch: "killSwitch"
        case .killSwitchExempt: "killSwitchExempt"
        case .killSwitchPaused: "killSwitchPaused"
        case .connectionRule: "destinationRule"
        case .protection: "protection"
        case .siteAllowed: "allowedSite"
        case .blocklist: "blocklist"
        case .temporaryRule: "timedRule"
        case .budget: "budget"
        case .quota: "quota"
        case .updaterPaused: "updaterPaused"
        case .appRule: "appRule"
        case .recentDecision: "approval"
        case .appleSoftware: "appleSoftware"
        case .askNewApps: "askNewApps"
        case .newAppDefault: "profileDefault"
        case .noAppRule: "noAppRule"
        }
    }
}

extension FilterPolicy.Verdict: Codable {
    public var name: String {
        switch self { case .allow: "allow"; case .block: "block"; case .ask: "ask" }
    }
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "allow": self = .allow
        case "block": self = .block
        case "ask": self = .ask
        default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown verdict \(value)"))
        }
    }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(name) }
}

extension DecisionTrace.Match: Codable {
    private enum Keys: String, CodingKey { case rule, verdict, allowed, expires, until, destination, protection, entry, app, helper, exemption, name }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        verdict = try values.decode(FilterPolicy.Verdict.self, forKey: .verdict)
        let allowed = { try values.decode(Bool.self, forKey: .allowed) }
        let text = { (key: Keys) in try values.decode(String.self, forKey: key) }
        switch try values.decode(String.self, forKey: .rule) {
        case "filterOff": reason = .filterOff
        case "unrestricted": reason = .unrestricted
        case "killSwitch": reason = .killSwitch
        case "killSwitchExempt":
            let name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
            switch try text(.exemption) {
            case "kilobat": reason = .killSwitchExempt(.kilobat)
            case "vpnApp": reason = .killSwitchExempt(.vpnApp(name))
            case "appleNetworking": reason = .killSwitchExempt(.appleNetworking(name))
            default: reason = .killSwitchExempt(.localNetwork)
            }
        case "killSwitchPaused": reason = .killSwitchPaused(try values.decode(Date.self, forKey: .until))
        case "destinationRule": reason = .connectionRule(try values.decode(ConnectionRule.self, forKey: .destination))
        case "protection": reason = .protection(try values.decode(ProtectionDetail.self, forKey: .protection))
        case "allowedSite": reason = .siteAllowed(try text(.entry))
        case "blocklist": reason = .blocklist(try text(.entry))
        case "timedRule": reason = .temporaryRule(TemporaryRule(allowed: try allowed(), expires: try values.decode(Date.self, forKey: .expires)))
        case "budget": reason = .budget
        case "quota": reason = .quota(try text(.app))
        case "updaterPaused": reason = .updaterPaused(try text(.helper))
        case "appRule": reason = .appRule(try allowed())
        case "approval": reason = .recentDecision(try allowed())
        case "appleSoftware": reason = .appleSoftware
        case "askNewApps": reason = .askNewApps
        case "profileDefault": reason = .newAppDefault(try allowed())
        case "noAppRule": reason = .noAppRule
        case let other: throw DecodingError.dataCorruptedError(forKey: .rule, in: values, debugDescription: "Unknown rule \(other)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Keys.self)
        try values.encode(reason.rule, forKey: .rule)
        try values.encode(verdict, forKey: .verdict)
        switch reason {
        case .killSwitchExempt(let exemption):
            switch exemption {
            case .kilobat: try values.encode("kilobat", forKey: .exemption)
            case .vpnApp(let name): try values.encode("vpnApp", forKey: .exemption); try values.encode(name, forKey: .name)
            case .appleNetworking(let name): try values.encode("appleNetworking", forKey: .exemption); try values.encode(name, forKey: .name)
            case .localNetwork: try values.encode("localNetwork", forKey: .exemption)
            }
        case .killSwitchPaused(let until): try values.encode(until, forKey: .until)
        case .connectionRule(let rule): try values.encode(rule, forKey: .destination)
        case .protection(let detail): try values.encode(detail, forKey: .protection)
        case .siteAllowed(let site): try values.encode(site, forKey: .entry)
        case .blocklist(let entry): try values.encode(entry, forKey: .entry)
        case .temporaryRule(let rule): try values.encode(rule.allowed, forKey: .allowed); try values.encode(rule.expires, forKey: .expires)
        case .quota(let key): try values.encode(key, forKey: .app)
        case .updaterPaused(let helper): try values.encode(helper, forKey: .helper)
        case .appRule(let allowed), .recentDecision(let allowed), .newAppDefault(let allowed): try values.encode(allowed, forKey: .allowed)
        case .filterOff, .unrestricted, .killSwitch, .budget, .appleSoftware, .askNewApps, .noAppRule: break
        }
    }
}

extension DecisionTrace: Codable {
    private enum Keys: String, CodingKey { case verdict, decided, matched }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        let verdict = try values.decode(FilterPolicy.Verdict.self, forKey: .verdict)
        let matches = try values.decode([Match].self, forKey: .matched)
        let decided = try values.decode(Int.self, forKey: .decided)
        guard matches.indices.contains(decided) else { throw DecodingError.dataCorruptedError(forKey: .decided, in: values, debugDescription: "No such rule") }
        guard matches[decided].verdict == verdict, matches[decided].reason.decides else {
            throw DecodingError.dataCorruptedError(forKey: .verdict, in: values, debugDescription: "Decision does not match its trace")
        }
        self.init(matches: matches, decided: decided)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Keys.self)
        try values.encode(verdict, forKey: .verdict)
        try values.encode(decided, forKey: .decided)
        try values.encode(matches, forKey: .matched)
    }
}
