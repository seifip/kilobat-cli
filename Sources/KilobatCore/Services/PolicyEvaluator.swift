import Foundation

/// The rules the filter enforces, parsed from the configuration the host saves for it. The filter, the
/// connection doctor and the app all decide through `decide`, so they can't disagree about a connection.
public struct FilterPolicy: Sendable {
    public var enabled = true
    public var unrestricted = false
    public var budgetReached = false
    /// Rule keys of apps that used up their quota.
    public var quotaReached: Set<String> = []
    /// On a metered network with pausing on: updater helpers (`UpdaterHelpers`) are blocked, the apps they update aren't.
    public var updatersPaused = false
    public var defaultAllow = false
    public var askNewApps = false
    public var allowApple = false
    public var profile = ""
    public var rules: [String: Bool] = [:]
    public var temporary: [String: TemporaryRule] = [:]
    public var connectionRules: [ConnectionRule] = []
    public var blockedEntries: [String] = []
    public var domainExceptions: [String: [String]] = [:]
    /// The VPN kill switch; it applies in every profile, Unrestricted included.
    public var killSwitch = KillSwitchPolicy()
    /// Threat and tracker blocking and the agent guard; like the kill switch, threats apply in every profile.
    public var protection = ProtectionSettings()

    public init() {}

    /// From the extension's vendor configuration (see `FilterController.policy`).
    public init(_ configuration: [String: Any]) {
        enabled = configuration["enabled"] as? Bool ?? false
        unrestricted = configuration["unrestricted"] as? Bool == true
        budgetReached = configuration["budgetReached"] as? Bool == true
        quotaReached = Set(configuration["quotaReached"] as? [String] ?? [])
        updatersPaused = configuration["updatersPaused"] as? Bool == true
        defaultAllow = configuration["defaultAllow"] as? Bool ?? false
        askNewApps = configuration["askNewApps"] as? Bool == true
        allowApple = configuration["allowApple"] as? Bool == true
        profile = configuration["profile"] as? String ?? ""
        rules = configuration["rules"] as? [String: Bool] ?? [:]
        for (key, value) in configuration["temporary"] as? [String: [String: Any]] ?? [:] {
            if let allowed = value["allowed"] as? Bool, let expires = value["expires"] as? Double {
                temporary[key] = TemporaryRule(allowed: allowed, expires: Date(timeIntervalSince1970: expires))
            }
        }
        if let encoded = configuration["connectionRules"] as? String, let data = Data(base64Encoded: encoded) {
            connectionRules = (try? JSONDecoder().decode([ConnectionRule].self, from: data)) ?? []
        }
        blockedEntries = configuration["blockedDomains"] as? [String] ?? []
        domainExceptions = configuration["domainExceptions"] as? [String: [String]] ?? [:]
        killSwitch = KillSwitchPolicy(configuration["killSwitch"] as? [String: Any])
        protection = ProtectionSettings(configuration["protection"] as? [String: Any])
    }

    /// One connection, as the filter sees it.
    public struct Flow: Sendable {
        public var app: String?
        public var process: String
        public var host: String?
        public var address: String?
        public var port: String?
        public var direction: String
        /// The process that made the connection for `app`, when another one did: nsurlsessiond for Music, or a
        /// Sparkle download service for its app. Only pausing updaters looks at it; rules stay with `app`.
        public var via: String?
        public init(app: String?, process: String, host: String?, address: String? = nil, port: String? = nil, direction: String = "outgoing", via: String? = nil) {
            self.app = app; self.process = process; self.host = host; self.address = address; self.port = port; self.direction = direction; self.via = via
        }
    }

    public enum Verdict: Sendable, Equatable { case allow, block, ask }

    /// Why a connection is allowed, blocked or held, in the order the filter checks.
    public enum Reason: Sendable, Equatable {
        case filterOff, unrestricted
        /// The VPN is down and the kill switch holds new connections back.
        case killSwitch
        /// The kill switch blocks, but this connection is what the VPN needs to come back.
        case killSwitchExempt(KillSwitchPolicy.Exemption)
        /// Only in a trace: the VPN is down, but "allow for 5 minutes" lets everything through until then.
        case killSwitchPaused(Date)
        case connectionRule(ConnectionRule)
        /// Protection: a known threat, a tracker, or the agent guard.
        case protection(ProtectionDetail)
        /// Only in a trace: the site the person allowed past Protection, which one of its lists has.
        case siteAllowed(String)
        case blocklist(String)
        case temporaryRule(TemporaryRule)
        case budget
        /// The app used up its data quota; carries its rule key.
        case quota(String)
        /// An updater helper on a metered network; carries the helper's name.
        case updaterPaused(String)
        case appRule(Bool)
        case recentDecision(Bool)
        case appleSoftware
        case askNewApps
        case newAppDefault(Bool)
        /// No app was given, so only rules that apply to every app were checked.
        case noAppRule

        /// The short reason the blocked-connection journal records.
        public var summary: String {
            switch self {
            case .filterOff: "Filter off"
            case .unrestricted: "Unrestricted profile"
            case .killSwitch: "VPN kill switch: the VPN is down"
            case .killSwitchExempt: "Needed while the VPN reconnects"
            case .killSwitchPaused: "VPN kill switch paused"
            case .connectionRule(let rule): "Destination rule: \(rule.host)\(rule.port.isEmpty ? "" : ":" + rule.port) · \(rule.direction)"
            case .protection(let detail): detail.summary
            case .siteAllowed(let site): "Allowed site: " + site
            case .blocklist(let entry): "Blocklist: " + entry
            case .temporaryRule: "Temporary app rule"
            case .budget: "Network budget reached"
            case .quota: "App quota reached"
            case .updaterPaused: UpdaterHelpers.reason
            case .appRule(let allowed): allowed ? "App allow rule" : "App block rule"
            case .recentDecision(let allowed): allowed ? "Allowed when asked" : "Blocked when asked"
            case .appleSoftware: "Apple software"
            case .askNewApps: "Asking about new apps"
            case .newAppDefault(let allowed): allowed ? "New apps allowed" : "Default-deny profile"
            case .noAppRule: "No rule for every app"
            }
        }
    }

    /// The decision for a flow. `appleSigned` is asked only when it matters, because checking a signature
    /// costs a lookup; `recentDecision` is an answer given moments ago, before the saved rule arrives.
    /// `tunnelUp` lets the filter check the VPN's interface itself (see `KillSwitchPolicy.blocks`). `index` holds the
    /// Protection lists and `agent` says which AI agent's process tree the flow came from; it is asked only when needed.
    public func decide(_ flow: Flow, now: Date = Date(), appleSigned: () -> Bool = { false }, recentDecision: Bool? = nil,
                       tunnelUp: (String) -> Bool = { _ in true }, index: ProtectionIndex? = nil,
                       agent: () -> AgentOwner? = { nil }) -> (verdict: Verdict, reason: Reason) {
        evaluate(flow, now: now, appleSigned: appleSigned, recentDecision: recentDecision, tunnelUp: tunnelUp, index: index, agent: agent, trace: nil)
    }

    /// The same checks as `decide`, run to the end: every rule that applies, in order, and the one that decided
    /// (`DecisionTrace.decision` is always what `decide` returns). For the rule inspector, off the filter's hot path.
    public func trace(_ flow: Flow, now: Date = Date(), appleSigned: () -> Bool = { false }, recentDecision: Bool? = nil,
                      tunnelUp: (String) -> Bool = { _ in true }, index: ProtectionIndex? = nil,
                      agent: () -> AgentOwner? = { nil }) -> DecisionTrace {
        let builder = DecisionTrace.Builder()
        _ = evaluate(flow, now: now, appleSigned: appleSigned, recentDecision: recentDecision, tunnelUp: tunnelUp, index: index, agent: agent, trace: builder)
        return builder.finish()
    }

    /// The one decision path. Without `trace` it returns at the first rule that applies, as the filter needs; with
    /// one it records that rule and keeps checking, so the rules that lost show too. Rules that only stand in for a
    /// missing one (Apple software, asking, the profile default) are checked only while nothing has decided.
    func evaluate(_ flow: Flow, now: Date, appleSigned: () -> Bool, recentDecision: Bool?, tunnelUp: (String) -> Bool,
                  index: ProtectionIndex?, agent: () -> AgentOwner?, trace: DecisionTrace.Builder?) -> (verdict: Verdict, reason: Reason) {
        var decided: (verdict: Verdict, reason: Reason)?
        /// Records a rule that applies; true when checking stops here.
        func apply(_ verdict: Verdict, _ reason: Reason) -> Bool {
            if decided == nil { decided = (verdict, reason) }
            guard let trace else { return true }
            trace.rule(verdict, reason)
            return false
        }
        guard enabled else { _ = apply(.allow, .filterOff); return decided! }
        // Before every rule: an allow rule for an app mustn't leak it past a VPN that is down. What the VPN needs to
        // reconnect goes through even where a profile would otherwise block it; local traffic still follows the rules.
        if killSwitch.blocks(now: now, tunnelUp: tunnelUp) {
            switch killSwitch.exemption(flow, appleSigned: appleSigned) {
            case nil: if apply(.block, .killSwitch) { return decided! }
            case .localNetwork?: trace?.note(.allow, .killSwitchExempt(.localNetwork))
            case let exemption?: if apply(.allow, .killSwitchExempt(exemption)) { return decided! }
            }
        } else if let trace, let until = killSwitch.pausedUntil(now: now, tunnelUp: tunnelUp) {
            trace.note(.allow, .killSwitchPaused(until))
        }
        // Known threats win over every allow rule: only the local network, Apple's and Kilobat's own domains and the
        // person's "Allow this site" stay out of reach (Kilobat itself and DNS are exempt in the filter before this).
        if let detail = ProtectionCheck.threat(flow, settings: protection, index: index, agent: agent) {
            if apply(.block, .protection(detail)) { return decided! }
        } else if let trace, let site = ProtectionCheck.allowedSite(flow, settings: protection, index: index) {
            trace.note(.allow, .siteAllowed(site))
        }
        if unrestricted, apply(.allow, .unrestricted) { return decided! }
        if let app = flow.app {
            if trace == nil {
                if let rule = connectionRules.reversed().first(where: {
                    $0.matches(app: app, process: flow.process, host: flow.host, address: flow.address, port: flow.port, direction: flow.direction)
                }) { _ = apply(rule.allowed ? .allow : .block, .connectionRule(rule)); return decided! }
            } else {
                // Newest first, as the filter takes them: the first decides, the rest show as also matched.
                for rule in connectionRules.reversed() where rule.matches(app: app, process: flow.process, host: flow.host, address: flow.address, port: flow.port, direction: flow.direction) {
                    _ = apply(rule.allowed ? .allow : .block, .connectionRule(rule))
                }
            }
        }
        if let entry = DomainPolicy.blocked(flow.host, address: flow.address, app: flow.app ?? "", domains: blockedEntries, exceptions: domainExceptions),
           apply(.block, .blocklist(entry)) { return decided! }
        // Trackers lose to the allow rules above: Unrestricted, a destination rule and "Allow this site".
        if let detail = ProtectionCheck.tracker(flow, settings: protection, index: index), apply(.block, .protection(detail)) { return decided! }
        guard let app = flow.app else {
            if budgetReached, apply(.block, .budget) { return decided! }
            if decided == nil { _ = apply(.allow, .noAppRule) }
            return decided!
        }
        let keys = [app] + ProcessRuleKey.keys("process:" + flow.process)
        // Explicit rules win over the budget, quotas and paused updaters, so "allow for N minutes" still works.
        if let rule = keys.lazy.compactMap({ temporary[$0] }).first(where: { $0.expires > now }), apply(rule.allowed ? .allow : .block, .temporaryRule(rule)) { return decided! }
        if budgetReached, apply(.block, .budget) { return decided! }
        if let key = keys.first(where: quotaReached.contains), apply(.block, .quota(key)) { return decided! }
        if updatersPaused, let helper = UpdaterHelpers.helper(app, process: flow.process) ?? UpdaterHelpers.helper(flow.via),
           apply(.block, .updaterPaused(helper.name)) { return decided! }
        let saved = keys.lazy.compactMap({ rules[$0] }).first
        if let saved, apply(saved ? .allow : .block, .appRule(saved)) { return decided! }
        // An answer given moments ago stands in for the saved rule until it arrives.
        if saved == nil, let recentDecision, apply(recentDecision ? .allow : .block, .recentDecision(recentDecision)) { return decided! }
        guard decided == nil else { return decided! }
        if (askNewApps || !defaultAllow) && allowApple && appleSigned() { _ = apply(.allow, .appleSoftware) }
        else if askNewApps { _ = apply(.ask, .askNewApps) }
        else { _ = apply(defaultAllow ? .allow : .block, .newAppDefault(defaultAllow)) }
        return decided!
    }
}
