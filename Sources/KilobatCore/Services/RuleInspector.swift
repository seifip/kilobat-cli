import Foundation

/// What only the running app knows about the rules behind a trace: who set a timed block, the apps' names, the
/// network. Everything has a default, so the CLI without the app still explains a trace, in less detail.
public struct RuleContext: Sendable {
    /// Who holds an app with a timed block: Send later, call mode, or a stream going live.
    public enum Holder: Sendable, Equatable {
        case sendLater(UploadCondition, network: String)
        case callMode
        case stream
    }
    /// By rule key (a bundle ID or process:name).
    public var holders: [String: Holder] = [:]
    /// Display names by rule key; without one the key is shown, process: dropped.
    public var names: [String: String] = [:]
    public var metered = false
    /// Travel is on because Kilobat switched to it for a metered network.
    public var autoTravel = false
    /// A Focus pauses updaters on every network.
    public var focusPausesUpdaters = false
    /// Blocklist entries the person blocked one by one (`block-host`), not from an imported list.
    public var handBlocked: Set<String> = []
    /// Whether the network filter enforces the rules now; nil when nobody could say (the CLI without the app).
    public var filterActive: Bool?
    public init(holders: [String: Holder] = [:], names: [String: String] = [:], metered: Bool = false, autoTravel: Bool = false,
                focusPausesUpdaters: Bool = false, handBlocked: Set<String> = [], filterActive: Bool? = nil) {
        self.holders = holders; self.names = names; self.metered = metered; self.autoTravel = autoTravel
        self.focusPausesUpdaters = focusPausesUpdaters; self.handBlocked = handBlocked; self.filterActive = filterActive
    }

    public func name(_ key: String) -> String {
        if let name = names[key] { return name }
        return key.hasPrefix("process:") ? String(key.dropFirst(8)) : key
    }
}

/// Where a rule is changed: a place in the app, its words, and the CLI command when there is one.
public struct RuleChange: Codable, Sendable, Equatable {
    public enum Place: String, Codable, Sendable {
        case protection, allowedSites, killSwitch, profiles, destinationRules, blocklist, timedRules, sendLater, callMode, stream, budget,
             quotas, updaters, appRules, approvals, newApps, appleSoftware, filter
    }
    public var place: Place
    /// "Settings › Protection".
    public var label: String
    public var command: String?
    public init(_ place: Place, _ label: String, command: String? = nil) { self.place = place; self.label = label; self.command = command }
}

/// One rule of a trace in plain words.
public struct RuleLine: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable {
        /// The rule that decided.
        case decided
        /// It applies too, but an earlier rule decided.
        case alsoMatched
        /// It explains the decision without making one: an allowed site, the kill switch's local network.
        case note
    }
    /// Its position in the filter's order.
    public var id: Int
    /// `FilterPolicy.Reason.rule`: protection, appRule, timedRule…
    public var rule: String
    public var verdict: FilterPolicy.Verdict
    public var role: Role
    /// What set it, as a name: Protection, Send later, App rule.
    public var source: String
    /// "phish.example is on the phishing list (HaGeZi Threat Intelligence Feeds)".
    public var text: String
    /// The whole sentence: "Blocked by Protection: …", "Also matched: …".
    public var line: String
    public var change: RuleChange
}

/// A connection or blocked attempt explained: every rule that matched and which one decided.
public struct RuleInspection: Codable, Sendable {
    public var app: String?
    public var appName: String?
    public var host: String?
    public var address: String?
    public var port: String?
    public var direction: String
    public var verdict: FilterPolicy.Verdict
    /// The deciding rule's sentence.
    public var summary: String
    /// In the filter's order.
    public var rules: [RuleLine]
    /// True when the filter recorded the trace as it blocked; false when Kilobat checked the rules as they are now.
    public var recorded: Bool
    /// When the filter decided, for a recorded trace.
    public var date: Date?
    /// Whether the filter enforces these rules; nil when unknown.
    public var enforced: Bool?
    public var note: String?
    public var trace: DecisionTrace

    public var decided: RuleLine? { rules.first { $0.role == .decided } }
    public var alsoMatched: [RuleLine] { rules.filter { $0.role == .alsoMatched } }
    public var notes: [RuleLine] { rules.filter { $0.role == .note } }

    /// The plain-text version for the CLI and the clipboard.
    public var text: String {
        var lines = [summary]
        lines += rules.filter { $0.role != .decided }.map(\.line)
        if let note { lines.append(note) }
        return lines.joined(separator: "\n")
    }
}

/// The rule inspector: why the filter allows, blocks or holds a connection, with every rule that matched. Build one
/// from the rules once and ask it about as many connections as needed (a log's rows): each answer is one
/// `FilterPolicy.trace`, a few microseconds. The app, the CLI and MCP all explain through it.
public struct RuleInspector: @unchecked Sendable {
    public var policy: FilterPolicy
    public var index: ProtectionIndex?
    public var context: RuleContext

    public init(policy: FilterPolicy, index: ProtectionIndex? = nil, context: RuleContext = RuleContext()) {
        self.policy = policy; self.index = index; self.context = context
    }
    /// The policy exactly as `FilterController` hands it to the filter.
    public init(preferences: SavedPreferences, budgetReached: Bool, quotaReached: [String] = [], metered: Bool = false, killSwitch: KillSwitchPolicy = KillSwitchPolicy(),
                protection: ProtectionSettings = ProtectionSettings(), index: ProtectionIndex? = nil, context: RuleContext = RuleContext()) {
        var context = context
        context.metered = metered
        if context.handBlocked.isEmpty { context.handBlocked = Set(preferences.blockedHosts ?? []) }
        if preferences.profile == .travel, metered, preferences.autoHotspot { context.autoTravel = true }
        if preferences.focusPausesUpdaters == true { context.focusPausesUpdaters = true }
        self.init(policy: FilterPolicy(FilterController.policy(preferences, budgetReached: budgetReached, quotaReached: quotaReached, metered: metered,
                                                              killSwitch: killSwitch, protection: protection)),
                  index: index, context: context)
    }

    /// The trace alone, for callers that keep it compact (a log row) and explain it later with `explain`.
    public func trace(host: String?, address: String? = nil, port: String? = nil, app: String?, process: String? = nil, direction: String = "outgoing",
                      via: String? = nil, recentDecision: Bool? = nil, appleSigned: Bool? = nil, now: Date = Date()) -> DecisionTrace {
        let address = address ?? host.flatMap { HostName.isAddress($0) ? $0 : nil }
        let process = process ?? app.map { $0.hasPrefix("process:") ? String($0.dropFirst(8)) : $0 } ?? ""
        return policy.trace(.init(app: app, process: process, host: host, address: address, port: port, direction: direction, via: via), now: now,
                            // A caller-provided com.apple identifier alone is not proof of an Apple signature.
                            appleSigned: { appleSigned == true }, recentDecision: recentDecision, index: index)
    }

    /// Every rule that applies to this connection now, in words.
    public func inspect(host: String?, address: String? = nil, port: String? = nil, app: String?, process: String? = nil, direction: String = "outgoing",
                        via: String? = nil, recentDecision: Bool? = nil, appleSigned: Bool? = nil, now: Date = Date()) -> RuleInspection {
        let trace = trace(host: host, address: address, port: port, app: app, process: process, direction: direction, via: via, recentDecision: recentDecision, appleSigned: appleSigned, now: now)
        var result = inspection(trace, app: app, host: host, address: address ?? host.flatMap { HostName.isAddress($0) ? $0 : nil }, port: port, direction: direction, recorded: false, date: nil)
        if appleSigned == nil, policy.allowApple, app?.hasPrefix("com.apple.") == true {
            let caveat = String(localized: "Apple signing wasn’t verified for this lookup. The filter checks the actual signature before allowing Apple software.",
                                comment: "Rule inspector: an app ID alone cannot prove Apple code signing")
            result.note = [result.note, caveat].compactMap { $0 }.joined(separator: " ")
        }
        return result
    }

    /// A blocked attempt: the filter's own trace when it recorded one, otherwise the rules as they are now.
    public func inspect(_ event: FilterEvent, now: Date = Date()) -> RuleInspection {
        let target = Self.endpoint(event.endpoint)
        let host = event.protection?.host ?? target.host
        let app = event.app == "Unknown app" ? nil : event.app
        if let trace = event.trace {
            return inspection(trace, app: app, host: host, address: target.host.flatMap { HostName.isAddress($0) ? $0 : nil }, port: target.port,
                              direction: event.direction, recorded: true, date: event.date)
        }
        var result = inspect(host: host, port: target.port, app: app, direction: event.direction, via: event.via, now: now)
        result.note = [String(localized: "The filter recorded only “\(event.reason)” for this attempt; these are your rules as they are now.",
                              comment: "Rule inspector: a blocked attempt recorded before traces, or without one"), result.note].compactMap { $0 }.joined(separator: " ")
        return result
    }

    /// "host:443", "[2001:db8::1]:443", "203.0.113.7:443" or a bare name, as the filter writes endpoints.
    static func endpoint(_ text: String) -> (host: String?, port: String?) {
        guard text != "Unknown endpoint", !text.isEmpty else { return (nil, nil) }
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            return (host, rest.hasPrefix(":") ? String(rest.dropFirst()) : nil)
        }
        if text.filter({ $0 == ":" }).count == 1, let colon = text.lastIndex(of: ":") {
            return (String(text[..<colon]), String(text[text.index(after: colon)...]))
        }
        return (text, nil)
    }

    func inspection(_ trace: DecisionTrace, app: String?, host: String?, address: String?, port: String?, direction: String, recorded: Bool, date: Date?) -> RuleInspection {
        let lines = explain(trace, app: app, host: host ?? address)
        var note: String?
        if context.filterActive == false {
            note = String(localized: "The network filter is off, so Kilobat doesn’t enforce these rules right now.", comment: "Rule inspector note")
        }
        return RuleInspection(app: app, appName: app.map(context.name), host: host, address: address, port: port, direction: direction, verdict: trace.verdict,
                              summary: lines.first { $0.role == .decided }?.line ?? "", rules: lines, recorded: recorded, date: date,
                              enforced: context.filterActive, note: note, trace: trace)
    }

    /// Each match in words, in the filter's order.
    public func explain(_ trace: DecisionTrace, app: String?, host: String?) -> [RuleLine] {
        trace.matches.enumerated().map { position, match in
            let role: RuleLine.Role = position == trace.decided ? .decided : match.reason.decides ? .alsoMatched : .note
            let words = describe(match, app: app, host: host)
            let line: String = switch role {
            case .decided:
                switch match.verdict {
                case .allow: String(localized: "Allowed by \(words.source): \(words.text)", comment: "Rule inspector: the deciding rule, e.g. Allowed by App rule: Slack is allowed in Work")
                case .block: String(localized: "Blocked by \(words.source): \(words.text)", comment: "Rule inspector: the deciding rule, e.g. Blocked by Protection: phish.example is on the phishing list (HaGeZi)")
                case .ask: String(localized: "Held by \(words.source): \(words.text)", comment: "Rule inspector: the deciding rule holds the connection until you answer")
                }
            case .alsoMatched: String(localized: "Also matched: \(words.text)", comment: "Rule inspector: a rule that applies too but didn't decide, e.g. Also matched: Slack is paused while on a metered network")
            case .note: words.source + ": " + words.text
            }
            return RuleLine(id: position, rule: match.reason.rule, verdict: match.verdict, role: role, source: words.source, text: words.text, line: line, change: words.change)
        }
    }

    func describe(_ match: DecisionTrace.Match, app: String?, host: String?) -> (source: String, text: String, change: RuleChange) {
        let name = app.map(context.name) ?? String(localized: "This app", comment: "Rule inspector: an app Kilobat couldn't name")
        let target = host ?? String(localized: "this destination", comment: "Rule inspector: a connection without a host name")
        let profile = policy.profile.isEmpty ? String(localized: "this profile", comment: "Rule inspector") : NetworkProfile(rawValue: policy.profile)?.title ?? policy.profile
        func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
        let killSwitchChange = RuleChange(.killSwitch, String(localized: "Settings › Network › VPN kill switch", comment: "Rule inspector: where to change it"), command: "kilobat settings kill-switch off")
        let newApps = RuleChange(.newApps, String(localized: "Settings › Network › New apps", comment: "Rule inspector: where to change it"), command: app.map { "kilobat allow \($0)" })
        let appRules = RuleChange(.appRules, String(localized: "Profiles › \(profile)", comment: "Rule inspector: where to change it, e.g. Profiles › Work"),
                                  command: app.map { "kilobat reset \($0) --profile \(policy.profile.lowercased())" })
        switch match.reason {
        case .filterOff:
            return (String(localized: "Network filter", comment: "Rule inspector source"),
                    String(localized: "the network filter is off, so nothing is blocked", comment: "Rule inspector"),
                    RuleChange(.filter, String(localized: "Settings › Network › Network filter", comment: "Rule inspector: where to change it")))
        case .unrestricted:
            return (String(localized: "Unrestricted", comment: "Rule inspector source: the profile"),
                    String(localized: "the Unrestricted profile allows every connection", comment: "Rule inspector"),
                    RuleChange(.profiles, String(localized: "Profiles", comment: "Rule inspector: where to change it"), command: "kilobat profile work"))
        case .killSwitch:
            return (String(localized: "VPN kill switch", comment: "Rule inspector source"),
                    String(localized: "the VPN is down, so new connections wait until it’s back", comment: "Rule inspector"), killSwitchChange)
        case .killSwitchExempt(let exemption):
            let text: String = switch exemption {
            case .kilobat: String(localized: "the VPN is down, but Kilobat itself always gets through", comment: "Rule inspector")
            case .vpnApp(let vpn): String(localized: "the VPN is down, and \(context.name(vpn)) is let through so the VPN can reconnect", comment: "Rule inspector")
            case .appleNetworking(let service): String(localized: "the VPN is down, and \(context.name(service)) is a macOS networking service the VPN needs", comment: "Rule inspector")
            case .localNetwork: String(localized: "the VPN is down, but the local network stays reachable", comment: "Rule inspector")
            }
            return (String(localized: "VPN kill switch", comment: "Rule inspector source"), text, killSwitchChange)
        case .killSwitchPaused(let until):
            return (String(localized: "VPN kill switch", comment: "Rule inspector source"),
                    String(localized: "the VPN is down, but you allowed traffic until \(time(until))", comment: "Rule inspector"), killSwitchChange)
        case .connectionRule(let rule):
            let destination = rule.host + (rule.port.isEmpty ? "" : ":" + rule.port)
            let who = context.name(rule.app)
            var text = rule.allowed ? String(localized: "\(who) may connect to \(destination)", comment: "Rule inspector: a destination rule")
                                    : String(localized: "\(who) may not connect to \(destination)", comment: "Rule inspector: a destination rule")
            if rule.direction != "any" { text += " (" + (rule.direction == "incoming" ? String(localized: "incoming", comment: "Rule inspector") : String(localized: "outgoing", comment: "Rule inspector")) + ")" }
            if let expires = rule.expires { text += " " + String(localized: "until \(time(expires))", comment: "Rule inspector: a rule's end, e.g. until 14:05") }
            return (String(localized: "Destination rule", comment: "Rule inspector source"), text,
                    RuleChange(.destinationRules, String(localized: "Tools › Destination rules", comment: "Rule inspector: where to change it"), command: "kilobat remove-connection-rule \(rule.id.uuidString)"))
        case .protection(let detail):
            let allow = RuleChange(.protection, String(localized: "Settings › Protection", comment: "Rule inspector: where to change it"), command: "kilobat protect allow \(detail.host)")
            switch detail.kind {
            case .agentGuard:
                let who = ProtectionText.who(detail, app: name)
                let text = detail.list == "large upload to a new host"
                    ? String(localized: "\(who) sent a large upload to \(detail.host), a host no agent on this Mac used before", comment: "Rule inspector: the agent guard's upload limit")
                    : String(localized: "\(who) may not reach a \(ProtectionText.rule(detail.list)): \(detail.host)", comment: "Rule inspector: the agent guard, e.g. npm (started by Claude Code) may not reach a paste site: pastebin.com")
                return (String(localized: "Agent guard", comment: "Rule inspector source"), text, allow)
            case .tracker:
                return (String(localized: "Protection", comment: "Rule inspector source"),
                        String(localized: "\(detail.host) is on the tracker list (\(detail.list))", comment: "Rule inspector"), allow)
            case .malware, .phishing, .scam, .threat:
                let list: String = switch detail.kind {
                case .malware: String(localized: "malware", comment: "Rule inspector: the kind of list")
                case .phishing: String(localized: "phishing", comment: "Rule inspector: the kind of list")
                case .scam: String(localized: "scam", comment: "Rule inspector: the kind of list")
                default: String(localized: "threat", comment: "Rule inspector: the kind of list")
                }
                var text = String(localized: "\(detail.host) is on the \(list) list (\(detail.list))", comment: "Rule inspector, e.g. phish.example is on the phishing list (HaGeZi Threat Intelligence Feeds)")
                if let agent = detail.agent { text += " · " + String(localized: "started by \(agent)", comment: "Rule inspector: the AI agent behind a connection") }
                return (String(localized: "Protection", comment: "Rule inspector source"), text, allow)
            }
        case .siteAllowed(let site):
            return (String(localized: "Allowed site", comment: "Rule inspector source"),
                    String(localized: "you allowed \(site), so no Protection list applies to it", comment: "Rule inspector"),
                    RuleChange(.allowedSites, String(localized: "Settings › Protection › Allowed sites", comment: "Rule inspector: where to change it"), command: "kilobat protect unallow \(site)"))
        case .blocklist(let entry):
            let hand = context.handBlocked.contains(entry)
            return (String(localized: "Blocklist", comment: "Rule inspector source"),
                    entry == target ? String(localized: "\(target) is on your blocklist", comment: "Rule inspector")
                                    : String(localized: "\(target) matches \(entry) on your blocklist", comment: "Rule inspector"),
                    RuleChange(.blocklist, String(localized: "Tools › Blocklist", comment: "Rule inspector: where to change it"),
                               command: hand ? "kilobat unblock-host \(entry)" : "kilobat blocklist status"))
        case .temporaryRule(let rule):
            switch app.flatMap({ context.holders[$0] }) {
            case .sendLater(let condition, let network)?:
                let text: String = switch condition.kind {
                case .unmetered: String(localized: "\(name) is paused while on \(network), a metered network, until an unmetered one", comment: "Rule inspector: Send later, e.g. Slack is paused while on iPhone, a metered network, until an unmetered one")
                case .fast: String(localized: "\(name) is paused until a network that uploads at \(Int(condition.mbps ?? SendLater.fastMbps)) Mbps or more", comment: "Rule inspector: Send later")
                case .time: String(localized: "\(name) is paused until \(time(condition.until ?? rule.expires))", comment: "Rule inspector: Send later")
                case .manual: String(localized: "\(name) is paused until you send it", comment: "Rule inspector: Send later")
                }
                return (String(localized: "Send later", comment: "Rule inspector source"), text,
                        RuleChange(.sendLater, String(localized: "Menu › Uploads", comment: "Rule inspector: where to change it"), command: app.map { "kilobat uploads resume \($0)" }))
            case .callMode?:
                return (String(localized: "Call mode", comment: "Rule inspector source"),
                        String(localized: "\(name) is held while you’re on a call", comment: "Rule inspector"),
                        RuleChange(.callMode, String(localized: "Settings › Network › Call mode", comment: "Rule inspector: where to change it")))
            case .stream?:
                return (String(localized: "Going live", comment: "Rule inspector source: holds while streaming"),
                        String(localized: "\(name) is held while you stream", comment: "Rule inspector"),
                        RuleChange(.stream, String(localized: "Settings › Streaming", comment: "Rule inspector: where to change it")))
            case nil:
                return (String(localized: "Timed rule", comment: "Rule inspector source"),
                        rule.allowed ? String(localized: "\(name) is allowed until \(time(rule.expires))", comment: "Rule inspector")
                                     : String(localized: "\(name) is blocked until \(time(rule.expires))", comment: "Rule inspector"),
                        RuleChange(.timedRules, String(localized: "Profiles › Timed rules", comment: "Rule inspector: where to change it"), command: app.map { "kilobat reset \($0)" }))
            }
        case .budget:
            return (String(localized: "Data budget", comment: "Rule inspector source"),
                    String(localized: "this network’s data budget is used up, which stops new connections", comment: "Rule inspector"),
                    RuleChange(.budget, String(localized: "Settings › Budget", comment: "Rule inspector: where to change it"), command: "kilobat limit"))
        case .quota(let key):
            return (String(localized: "App quota", comment: "Rule inspector source"),
                    String(localized: "\(context.name(key)) used up its data quota for this cycle", comment: "Rule inspector"),
                    RuleChange(.quotas, String(localized: "Settings › Budget › App quotas", comment: "Rule inspector: where to change it"), command: "kilobat quota \(key) --remove"))
        case .updaterPaused(let helper):
            let text = context.focusPausesUpdaters && !context.metered
                ? String(localized: "\(helper) is an updater, paused while your Focus is on", comment: "Rule inspector")
                : String(localized: "\(helper) is an updater, paused while this network is metered", comment: "Rule inspector")
            return (String(localized: "Paused updaters", comment: "Rule inspector source"), text,
                    RuleChange(.updaters, String(localized: "Settings › Network › Pause updaters", comment: "Rule inspector: where to change it"), command: "kilobat updaters off"))
        case .appRule(let allowed):
            var text = allowed ? String(localized: "\(name) is allowed in \(profile)", comment: "Rule inspector: an app rule, e.g. Slack is allowed in Work")
                               : String(localized: "\(name) is blocked in \(profile)", comment: "Rule inspector: an app rule, e.g. Slack is blocked in Travel")
            if context.autoTravel { text += String(localized: ", which Kilobat switched to for this metered network", comment: "Rule inspector: after 'Slack is blocked in Travel'") }
            return (String(localized: "App rule", comment: "Rule inspector source"), text, appRules)
        case .recentDecision(let allowed):
            return (String(localized: "Approval", comment: "Rule inspector source"),
                    allowed ? String(localized: "you allowed \(name) when Kilobat asked", comment: "Rule inspector") : String(localized: "you blocked \(name) when Kilobat asked", comment: "Rule inspector"),
                    RuleChange(.approvals, String(localized: "Profiles › \(profile)", comment: "Rule inspector: where to change it, e.g. Profiles › Work"), command: app.map { "kilobat reset \($0)" }))
        case .appleSoftware:
            return (String(localized: "Apple software", comment: "Rule inspector source"),
                    String(localized: "\(name) is Apple software, which \(profile) lets through", comment: "Rule inspector"),
                    RuleChange(.appleSoftware, String(localized: "Settings › Network › Allow Apple software", comment: "Rule inspector: where to change it"), command: "kilobat settings apple-software off"))
        case .askNewApps:
            return (String(localized: "New apps", comment: "Rule inspector source"),
                    String(localized: "\(name) has no rule, so Kilobat asks before it connects", comment: "Rule inspector"), newApps)
        case .newAppDefault(let allowed):
            if app == nil {
                return (String(localized: "Profile default", comment: "Rule inspector source"),
                        allowed ? String(localized: "Kilobat couldn’t identify the app, so \(profile) allows this connection", comment: "Rule inspector: unidentified app with an allow-by-default profile")
                                : String(localized: "Kilobat couldn’t identify the app, so \(profile) blocks this connection", comment: "Rule inspector: unidentified app with a deny-by-default profile"),
                        newApps)
            }
            var text = allowed ? String(localized: "\(name) has no rule, and \(profile) allows apps without one", comment: "Rule inspector")
                               : String(localized: "\(name) has no rule, and \(profile) blocks apps without one", comment: "Rule inspector")
            if context.autoTravel { text += String(localized: ", which Kilobat switched to for this metered network", comment: "Rule inspector: after 'Slack is blocked in Travel'") }
            return (String(localized: "Profile default", comment: "Rule inspector source"), text, newApps)
        case .noAppRule:
            return (String(localized: "No app", comment: "Rule inspector source"),
                    String(localized: "Kilobat couldn’t tell which app this is, and no rule for every app applies", comment: "Rule inspector"),
                    RuleChange(.newApps, String(localized: "Settings › Network › New apps", comment: "Rule inspector: where to change it")))
        }
    }
}
