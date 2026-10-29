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
        case connectionRule(ConnectionRule)
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
            case .connectionRule(let rule): "Destination rule: \(rule.host)\(rule.port.isEmpty ? "" : ":" + rule.port) · \(rule.direction)"
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
    public func decide(_ flow: Flow, now: Date = Date(), appleSigned: () -> Bool = { false }, recentDecision: Bool? = nil) -> (verdict: Verdict, reason: Reason) {
        guard enabled else { return (.allow, .filterOff) }
        if unrestricted { return (.allow, .unrestricted) }
        if let app = flow.app, let rule = connectionRules.reversed().first(where: {
            $0.matches(app: app, process: flow.process, host: flow.host, address: flow.address, port: flow.port, direction: flow.direction)
        }) { return (rule.allowed ? .allow : .block, .connectionRule(rule)) }
        if let entry = DomainPolicy.blocked(flow.host, address: flow.address, app: flow.app ?? "", domains: blockedEntries, exceptions: domainExceptions) {
            return (.block, .blocklist(entry))
        }
        guard let app = flow.app else { return budgetReached ? (.block, .budget) : (.allow, .noAppRule) }
        let keys = [app] + ProcessRuleKey.keys("process:" + flow.process)
        // Explicit rules win over the budget, quotas and paused updaters, so "allow for N minutes" still works.
        if let rule = keys.lazy.compactMap({ temporary[$0] }).first, rule.expires > now { return (rule.allowed ? .allow : .block, .temporaryRule(rule)) }
        if budgetReached { return (.block, .budget) }
        if let key = keys.first(where: quotaReached.contains) { return (.block, .quota(key)) }
        if updatersPaused, let helper = UpdaterHelpers.helper(app, process: flow.process) ?? UpdaterHelpers.helper(flow.via) {
            return (.block, .updaterPaused(helper.name))
        }
        if let saved = keys.lazy.compactMap({ rules[$0] }).first { return (saved ? .allow : .block, .appRule(saved)) }
        if let recentDecision { return (recentDecision ? .allow : .block, .recentDecision(recentDecision)) }
        if (askNewApps || !defaultAllow) && allowApple && appleSigned() { return (.allow, .appleSoftware) }
        if askNewApps { return (.ask, .askNewApps) }
        return (defaultAllow ? .allow : .block, .newAppDefault(defaultAllow))
    }
}
