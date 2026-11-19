import Foundation
import Darwin

/// How long the filter may go on applying what only the running app can know: a budget or app limit being used up,
/// and pauses for a metered network or a Focus. The app renews it while it runs; if Kilobat quits or crashes, those
/// blocks end with the lease instead of outliving the cycle or the network they were worked out for. Counted in awake
/// time within one boot, so sleep doesn't run it down and a restart ends it.
public struct StateLease: Equatable, Sendable {
    /// The boot it was issued in (`kern.bootsessionuuid`); empty when that couldn't be read.
    public var boot: String
    /// `ProcessInfo.systemUptime` at which it ends.
    public var until: TimeInterval
    /// Renewed this often; a lease holds for one to two of these.
    public static let length: TimeInterval = 900

    public init(boot: String, until: TimeInterval) { self.boot = boot; self.until = until }
    /// The lease to hand out now. It only changes every `length` seconds, so the saved policy does too.
    public static func issued(boot: String, uptime: TimeInterval) -> StateLease {
        StateLease(boot: boot, until: ((uptime / length).rounded(.down) + 2) * length)
    }
    /// An unreadable boot on either side counts as the same boot: then only the time decides, as before a restart.
    public func holds(boot: String, uptime: TimeInterval) -> Bool {
        (boot.isEmpty || self.boot.isEmpty || boot == self.boot) && uptime < until
    }
    public init?(_ configuration: [String: Any]?) {
        guard let configuration, let until = configuration["until"] as? Double else { return nil }
        self.init(boot: configuration["boot"] as? String ?? "", until: until)
    }
    public var configuration: [String: Any] { ["boot": boot, "until": until] }

    /// This boot, read once: it can't change while the process lives.
    public static let currentBoot: String = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }()
}

/// The rules the filter enforces, parsed from the configuration the host saves for it. The filter, the
/// connection doctor and the app all decide through `decide`, so they can't disagree about a connection.
public struct FilterPolicy: Sendable {
    public var enabled = true
    public var unrestricted = false
    public var budgetReached = false
    /// Rule keys of apps that used up a blocking app limit.
    public var quotaReached: Set<String> = []
    /// On a metered network with pausing on: updater helpers (`UpdaterHelpers`) are blocked, the apps they update aren't.
    public var updatersPaused = false
    /// On a metered network with pausing on: cloud storage clients (`CloudSyncClients`) are blocked.
    public var syncPaused = false
    /// The lease the budget, app-limit and pause fields came with; nil from an app that sends none.
    public var stateLease: StateLease?
    public var teamsBlockedApps: Set<String> = []
    public var defaultAllow = false
    public var askNewApps = false
    /// Alert mode: apps without a rule connect (with `defaultAllow`), and the filter lists them for review.
    public var alertNewApps = false
    /// Rule keys of apps that ask before reaching a destination their rules don't cover.
    public var askDestinations: Set<String> = []
    public var allowApple = false
    public var profile = ""
    public var rules: [String: Bool] = [:] { didSet { compileDeveloperRules() } }
    /// Developer rules (`team:<Team ID>` keys among `rules`) by Team ID, kept apart once instead of per flow.
    public private(set) var developerRules: [String: Bool] = [:]
    private mutating func compileDeveloperRules() {
        developerRules = rules.reduce(into: [:]) { output, item in if let team = DeveloperRule.team(item.key) { output[team] = item.value } }
    }
    public var temporary: [String: TemporaryRule] = [:]
    public var connectionRules: [ConnectionRule] = [] { didSet { compileConnectionRules() } }
    /// The same, newest first, with address ranges parsed once instead of for every flow.
    private var compiledRules: [CompiledConnectionRule] = []
    private var rulesHaveRanges = false
    private mutating func compileConnectionRules() {
        compiledRules = connectionRules.reversed().map(CompiledConnectionRule.init)
        rulesHaveRanges = compiledRules.contains { $0.range != nil }
    }
    public var blockedEntries: [String] = [] { didSet { compileBlocklist() } }
    public var domainExceptions: [String: [String]] = [:] { didSet { compileBlocklist() } }
    /// The two above, parsed once instead of for every flow.
    private var compiledBlocklist = DomainPolicy.Compiled()
    private mutating func compileBlocklist() { compiledBlocklist = DomainPolicy.Compiled(domains: blockedEntries, exceptions: domainExceptions) }
    /// The VPN kill switch; it applies in every profile, Unrestricted included.
    public var killSwitch = KillSwitchPolicy()
    /// Threat and tracker blocking and the agent guard; like the kill switch, threats apply in every profile.
    public var protection = ProtectionSettings()

    public var inspectsHostnames: Bool {
        protection.active || (!unrestricted && (!blockedEntries.isEmpty || connectionRules.contains { !$0.allowed }))
    }

    public init() {}

    /// From the extension's vendor configuration (see `FilterController.policy`). `boot` and `uptime` say when it is
    /// read: the budget, app-limit and pause fields apply only while their lease holds then.
    public init(_ configuration: [String: Any], boot: String = StateLease.currentBoot, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.init(saved: configuration)
        self = leased(boot: boot, uptime: uptime)
    }

    /// The configuration as saved, before its lease is checked: what `FilterPolicyCache` keeps. It reads nothing
    /// but the configuration, so equal configurations give equal policies whenever they are parsed.
    init(saved configuration: [String: Any]) {
        enabled = configuration["enabled"] as? Bool ?? false
        unrestricted = configuration["unrestricted"] as? Bool == true
        budgetReached = configuration["budgetReached"] as? Bool == true
        quotaReached = Set(configuration["quotaReached"] as? [String] ?? [])
        updatersPaused = configuration["updatersPaused"] as? Bool == true
        syncPaused = configuration["syncPaused"] as? Bool == true
        stateLease = StateLease(configuration["stateLease"] as? [String: Any])
        defaultAllow = configuration["defaultAllow"] as? Bool ?? false
        askNewApps = configuration["askNewApps"] as? Bool == true
        alertNewApps = configuration["alertNewApps"] as? Bool == true
        askDestinations = Set(configuration["askDestinations"] as? [String] ?? [])
        allowApple = configuration["allowApple"] as? Bool == true
        profile = configuration["profile"] as? String ?? ""
        teamsBlockedApps = Set(configuration["teamsBlockedApps"] as? [String] ?? [])
        rules = configuration["rules"] as? [String: Bool] ?? [:]
        for (key, value) in configuration["temporary"] as? [String: [String: Any]] ?? [:] {
            if let allowed = value["allowed"] as? Bool, let expires = value["expires"] as? Double {
                temporary[key] = TemporaryRule(allowed: allowed, expires: Date(timeIntervalSince1970: expires), pid: (value["pid"] as? NSNumber)?.int32Value)
            }
        }
        if let encoded = configuration["connectionRules"] as? String, let data = Data(base64Encoded: encoded) {
            connectionRules = (try? JSONDecoder().decode([ConnectionRule].self, from: data)) ?? []
        }
        blockedEntries = configuration["blockedDomains"] as? [String] ?? []
        domainExceptions = configuration["domainExceptions"] as? [String: [String]] ?? [:]
        killSwitch = KillSwitchPolicy(configuration["killSwitch"] as? [String: Any])
        protection = ProtectionSettings(configuration["protection"] as? [String: Any])
        // Property observers don't run inside an initialiser.
        compileBlocklist()
        compileConnectionRules()
        compileDeveloperRules()
    }

    /// This policy as it applies at `uptime` in `boot`. What the app worked out lapses with its lease; a configuration
    /// without one (an older app) holds as it always did. Rules, the kill switch and Protection never lapse.
    public func leased(boot: String = StateLease.currentBoot, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> FilterPolicy {
        guard let stateLease, !stateLease.holds(boot: boot, uptime: uptime) else { return self }
        var policy = self
        policy.budgetReached = false; policy.quotaReached = []; policy.updatersPaused = false; policy.syncPaused = false
        return policy
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
        /// The app's process id (from its audit token), for rules that last until it quits; nil when unknown.
        public var pid: Int32?
        /// "tcp" or "udp"; nil when unknown, which only rules for any protocol match.
        public var transport: String?
        public init(app: String?, process: String, host: String?, address: String? = nil, port: String? = nil, direction: String = "outgoing", via: String? = nil,
                    pid: Int32? = nil, transport: String? = nil) {
            self.app = app; self.process = process; self.host = host; self.address = address; self.port = port; self.direction = direction; self.via = via
            self.pid = pid; self.transport = transport
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
        /// The app used up its blocking app limit (once called a quota); carries its rule key.
        case quota(String)
        /// An updater helper on a metered network; carries the helper's name.
        case updaterPaused(String)
        case syncPaused(String)
        case appRule(Bool)
        case recentDecision(Bool)
        case appleSoftware
        case askNewApps
        case newAppDefault(Bool)
        /// No app was given, so only rules that apply to every app were checked.
        case noAppRule
        /// A blocklist the person subscribed to by URL: the entry that matched and the list's name.
        case subscribedList(entry: String, list: String)
        /// A rule for everything one developer signed (its Team ID), which an app without its own rule follows.
        case teamRule(team: String, allowed: Bool)
        /// The app asks about new destinations, and no rule of its own covers this one.
        case askNewDestination

        /// The short reason the blocked-connection journal records.
        public var summary: String {
            switch self {
            case .filterOff: "Filter off"
            case .unrestricted: "Unrestricted profile"
            case .killSwitch: "VPN kill switch: the VPN is down"
            case .killSwitchExempt: "Needed while the VPN reconnects"
            case .killSwitchPaused: "VPN kill switch paused"
            case .connectionRule(let rule): "Destination rule: \(rule.host)\(rule.port.isEmpty ? "" : ":" + rule.port) · \(rule.direction)\(rule.transport.map { " · " + $0.uppercased() } ?? "")\(rule.exact == true ? " · exact host" : "")"
            case .protection(let detail): detail.summary
            case .siteAllowed(let site): "Allowed site: " + site
            case .blocklist(let entry): "Blocklist: " + entry
            case .temporaryRule: "Temporary app rule"
            case .budget: "Network budget reached"
            case .quota: "App limit reached"
            case .updaterPaused: UpdaterHelpers.reason
            case .syncPaused: CloudSyncClients.reason
            case .appRule(let allowed): allowed ? "App allow rule" : "App block rule"
            case .recentDecision(let allowed): allowed ? "Allowed when asked" : "Blocked when asked"
            case .appleSoftware: "Apple software"
            case .askNewApps: "Asking about new apps"
            case .newAppDefault(let allowed): allowed ? "New apps allowed" : "Default-deny profile"
            case .noAppRule: "No rule for every app"
            case .subscribedList(let entry, let list): "Blocklist (\(list)): \(entry)"
            case .teamRule(let team, let allowed): allowed ? "Developer allow rule (Team \(team))" : "Developer block rule (Team \(team))"
            case .askNewDestination: "Asking about new destinations"
            }
        }
    }

    /// The rules a server name read from a connection's own bytes is judged by: trackers don't apply to a name only
    /// guessed from the address, nor to a connection the person allowed by their own rule.
    public func sniffedRules(explicit: Bool, guessed: Bool = false) -> FilterPolicy {
        var rules = self
        if guessed || explicit { rules.protection.trackers = false }
        return rules
    }

    /// The block a read server name leads to, for a connection already allowed without one: only a Protection,
    /// blocklist or destination-rule block counts, since the app's own rules were applied when the connection
    /// started. Nil lets it through. The same for a name read from TLS or HTTP on TCP and from QUIC on UDP.
    public func sniffedBlock(_ flow: Flow, explicit: Bool, guessed: Bool = false, index: ProtectionIndex?,
                             agent: () -> AgentOwner?) -> (reason: Reason, trace: DecisionTrace)? {
        let rules = sniffedRules(explicit: explicit, guessed: guessed)
        let decision = rules.decide(flow, index: index, agent: agent)
        guard decision.verdict == .block else { return nil }
        switch decision.reason {
        case .protection, .blocklist, .subscribedList, .connectionRule: return (decision.reason, rules.trace(flow, index: index, agent: agent))
        default: return nil
        }
    }

    /// The decision for a flow. `appleSigned` is asked only when it matters, because checking a signature
    /// costs a lookup; `recentDecision` is an answer given moments ago, before the saved rule arrives.
    /// `tunnelUp` lets the filter check the VPN's interface itself (see `KillSwitchPolicy.blocks`). `index` holds the
    /// Protection lists and `agent` says which AI agent's process tree the flow came from; it is asked only when needed.
    /// `team` is the Team ID the app's signature proves, asked only when a developer rule could decide; the filter
    /// answers nil for code Apple signed. `destinationAnswer` is an answer given moments ago about this destination.
    public func decide(_ flow: Flow, now: Date = Date(), appleSigned: () -> Bool = { false }, recentDecision: Bool? = nil,
                       tunnelUp: (String) -> Bool = { _ in true }, index: ProtectionIndex? = nil,
                       agent: () -> AgentOwner? = { nil }, team: () -> String? = { nil }, destinationAnswer: Bool? = nil) -> (verdict: Verdict, reason: Reason) {
        evaluate(flow, now: now, appleSigned: appleSigned, recentDecision: recentDecision, tunnelUp: tunnelUp, index: index, agent: agent,
                 team: team, destinationAnswer: destinationAnswer, trace: nil)
    }

    /// The same checks as `decide`, run to the end: every rule that applies, in order, and the one that decided
    /// (`DecisionTrace.decision` is always what `decide` returns). For the rule inspector, off the filter's hot path.
    public func trace(_ flow: Flow, now: Date = Date(), appleSigned: () -> Bool = { false }, recentDecision: Bool? = nil,
                      tunnelUp: (String) -> Bool = { _ in true }, index: ProtectionIndex? = nil,
                      agent: () -> AgentOwner? = { nil }, team: () -> String? = { nil }, destinationAnswer: Bool? = nil) -> DecisionTrace {
        let builder = DecisionTrace.Builder()
        _ = evaluate(flow, now: now, appleSigned: appleSigned, recentDecision: recentDecision, tunnelUp: tunnelUp, index: index, agent: agent,
                     team: team, destinationAnswer: destinationAnswer, trace: builder)
        return builder.finish()
    }


    /// The rule a decision counts as a hit for in the Rules list: a destination rule, the app's own or timed rule (by
    /// the key that matched), a developer rule, a blocked host, a subscribed list. Nil for everything else.
    public func ruleHitKey(_ flow: Flow, reason: Reason) -> String? {
        switch reason {
        case .connectionRule(let rule): return RuleHitKey.destination(rule.id)
        case .appRule:
            guard let app = flow.app, let key = ([app] + ProcessRuleKey.keys("process:" + flow.process)).first(where: { rules[$0] != nil }) else { return nil }
            return RuleHitKey.app(profile: profile, key: key)
        case .temporaryRule:
            guard let app = flow.app, let key = ([app] + ProcessRuleKey.keys("process:" + flow.process)).first(where: { temporary[$0] != nil }) else { return nil }
            return RuleHitKey.timedPrefix + profile + "|" + key
        case .teamRule(let team, _): return RuleHitKey.app(profile: profile, key: DeveloperRule.key(team))
        case .blocklist(let entry): return RuleHitKey.blocked(entry)
        case .subscribedList(_, let list): return RuleHitKey.subscription(list)
        default: return nil
        }
    }

    /// The one decision path. Without `trace` it returns at the first rule that applies, as the filter needs; with
    /// one it records that rule and keeps checking, so the rules that lost show too. Rules that only stand in for a
    /// missing one (Apple software, asking, the profile default) are checked only while nothing has decided.
    func evaluate(_ flow: Flow, now: Date, appleSigned: () -> Bool, recentDecision: Bool?, tunnelUp: (String) -> Bool,
                  index: ProtectionIndex?, agent: () -> AgentOwner?, team: () -> String? = { nil }, destinationAnswer: Bool? = nil,
                  trace: DecisionTrace.Builder?) -> (verdict: Verdict, reason: Reason) {
        var decided: (verdict: Verdict, reason: Reason)?
        /// Records a rule that applies; true when checking stops here.
        func apply(_ verdict: Verdict, _ reason: Reason) -> Bool {
            if decided == nil { decided = (verdict, reason) }
            guard let trace else { return true }
            trace.rule(verdict, reason)
            return false
        }
        if let app = flow.app, teamsBlockedApps.contains(app) { _ = apply(.block, .appRule(false)); return decided! }
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
        if let app = flow.app, !compiledRules.isEmpty {
            // The flow's address is parsed once, and only when a rule names an address or range.
            let ip = rulesHaveRanges ? (flow.address.flatMap(AddressRange.parse) ?? flow.host.flatMap(AddressRange.parse)) : nil
            if trace == nil {
                if let rule = compiledRules.first(where: { $0.matches(flow, app: app, ip: ip, now: now) })?.rule {
                    _ = apply(rule.allowed ? .allow : .block, .connectionRule(rule)); return decided!
                }
            } else {
                // Newest first, as the filter takes them: the first decides, the rest show as also matched.
                for compiled in compiledRules where compiled.matches(flow, app: app, ip: ip, now: now) {
                    _ = apply(compiled.rule.allowed ? .allow : .block, .connectionRule(compiled.rule))
                }
            }
        }
        if let entry = compiledBlocklist.first(flow.host, address: flow.address, app: flow.app ?? ""),
           apply(.block, .blocklist(entry)) { return decided! }
        // Lists subscribed to by URL block for every app, like the blocklist and with its per-app exceptions.
        if let hit = ProtectionCheck.subscribed(flow, settings: protection, index: index),
           !compiledBlocklist.excepts(flow.host, address: flow.address, app: flow.app ?? ""),
           apply(.block, .subscribedList(entry: hit.entry, list: hit.list)) { return decided! }
        // Trackers lose to the allow rules above: Unrestricted, a destination rule and "Allow this site".
        if let detail = ProtectionCheck.tracker(flow, settings: protection, index: index), apply(.block, .protection(detail)) { return decided! }
        guard let app = flow.app else {
            if budgetReached, apply(.block, .budget) { return decided! }
            if decided == nil { _ = apply(.allow, .noAppRule) }
            return decided!
        }
        let keys = [app] + ProcessRuleKey.keys("process:" + flow.process)
        // Explicit rules win over the budget, quotas and paused updaters, so "allow for N minutes" still works.
        if let rule = keys.lazy.compactMap({ temporary[$0] }).first(where: { $0.applies(pid: flow.pid, now: now) }), apply(rule.allowed ? .allow : .block, .temporaryRule(rule)) { return decided! }
        if budgetReached, apply(.block, .budget) { return decided! }
        if let key = keys.first(where: quotaReached.contains), apply(.block, .quota(key)) { return decided! }
        if updatersPaused, let helper = UpdaterHelpers.helper(app, process: flow.process) ?? UpdaterHelpers.helper(flow.via),
           apply(.block, .updaterPaused(helper.name)) { return decided! }
        if syncPaused, let client = CloudSyncClients.client(app, process: flow.process),
           apply(.block, .syncPaused(client.name)) { return decided! }
        // An app marked "Ask for new destinations" that its rules let through asks about a destination no destination
        // rule of its own covered (those were checked first): only for outgoing connections beyond the local network.
        let asksDestination = !askDestinations.isEmpty && keys.contains(where: askDestinations.contains) && flow.direction == "outgoing"
            && (flow.host != nil || flow.address != nil) && !HostName.isLocal(flow.host, address: flow.address)
        func allowOrAsk(_ reason: Reason) -> Bool {
            guard asksDestination else { return apply(.allow, reason) }
            if let destinationAnswer { return apply(destinationAnswer ? .allow : .block, .recentDecision(destinationAnswer)) }
            return apply(.ask, .askNewDestination)
        }
        let saved = keys.lazy.compactMap({ rules[$0] }).first
        if let saved, saved ? allowOrAsk(.appRule(true)) : apply(.block, .appRule(false)) { return decided! }
        // An answer given moments ago stands in for the saved rule until it arrives.
        if saved == nil, let recentDecision, apply(recentDecision ? .allow : .block, .recentDecision(recentDecision)) { return decided! }
        // A rule for everything the app's developer signed stands in for a rule of its own.
        if saved == nil, recentDecision == nil, !developerRules.isEmpty, let team = team(), let allowed = developerRules[team],
           allowed ? allowOrAsk(.teamRule(team: team, allowed: true)) : apply(.block, .teamRule(team: team, allowed: false)) { return decided! }
        guard decided == nil else { return decided! }
        if (askNewApps || !defaultAllow) && allowApple && appleSigned() { _ = apply(.allow, .appleSoftware) }
        else if askNewApps { _ = apply(.ask, .askNewApps) }
        else if defaultAllow { _ = allowOrAsk(.newAppDefault(true)) }
        else { _ = apply(.block, .newAppDefault(false)) }
        return decided!
    }
}

/// The filter's parsed policy, kept between connections. The saved configuration is compared on every call, before
/// anything is decided, so a change the app saves decides the very next connection; nothing waits for a notification.
/// What it keeps is the policy as saved; the lease on the budget, app-limit and pause fields is judged on every call
/// against the clock of that call, so keeping a policy never keeps a lapsed block alive.
public final class FilterPolicyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var last: (configuration: NSDictionary, policy: FilterPolicy)?
    private var count = 0
    /// How many times the policy was parsed; for tests.
    public var builds: Int { lock.withLock { count } }
    public init() {}

    public func policy(for configuration: [String: Any], boot: String = StateLease.currentBoot,
                       uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> FilterPolicy {
        saved(configuration).leased(boot: boot, uptime: uptime)
    }

    private func saved(_ configuration: [String: Any]) -> FilterPolicy {
        lock.lock(); defer { lock.unlock() }
        if let last, last.configuration.isEqual(to: configuration) { return last.policy }
        let policy = FilterPolicy(saved: configuration)
        // A copy of our own, so nothing the system hands over can change under the comparison.
        last = (NSDictionary(dictionary: configuration, copyItems: true), policy); count += 1
        return policy
    }
}
