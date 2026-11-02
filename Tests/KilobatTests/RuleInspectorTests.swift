import Foundation
import Testing
@testable import KilobatCore

struct DecisionTraceTests {
    let index = ProtectionIndex(data: ProtectionIndex.build([
        (ProtectionIndexTests.slot(1, "HaGeZi Threat Intelligence Feeds", .threat), ["evil.example"]),
        (ProtectionIndexTests.slot(2, "Phishing Army", .phishing), ["phish.example"]),
        (ProtectionIndexTests.slot(3, "HaGeZi Multi Light", .tracker), ["tracker.example"]),
    ]))!
    let slack = "com.tinyspeck.slackmacgap"

    func policy(_ change: (inout SavedPreferences) -> Void = { _ in }, budget: Bool = false, quota: [String] = [], metered: Bool = false,
                killSwitch: KillSwitchPolicy = KillSwitchPolicy(), protection: ProtectionSettings = ProtectionSettings(threats: true, trackers: true)) -> FilterPolicy {
        var preferences = SavedPreferences(); preferences.profile = .work; preferences.defaultAllow = true
        change(&preferences)
        return FilterPolicy(FilterController.policy(preferences, budgetReached: budget, quotaReached: quota, metered: metered, killSwitch: killSwitch, protection: protection))
    }
    func flow(_ host: String?, app: String? = "com.tinyspeck.slackmacgap", process: String = "Slack", port: String = "443") -> FilterPolicy.Flow {
        .init(app: app, process: process, host: host, address: "203.0.113.10", port: port)
    }

    @Test func protectionDecidesAndTheRulesUnderItStillShow() {
        let filter = policy { $0.rules["Work"] = [slack: true]; $0.temporaryRules = ["Work|" + slack: TemporaryRule(allowed: false, expires: Date().addingTimeInterval(600))] }
        let trace = filter.trace(flow("login.phish.example"), index: index)
        #expect(trace.verdict == .block)
        guard case .protection(let detail) = trace.decision.reason else { Issue.record("\(trace.decision)"); return }
        #expect(detail.kind == .phishing && detail.list == "Phishing Army" && detail.host == "phish.example")
        // The timed block and the saved allow rule applied too, in the filter's order: the saved rule is what's left when the block ends.
        #expect(trace.others.map(\.reason.rule) == ["timedRule", "appRule"])
        #expect(trace.matches.count == 3 && trace.decided == 0)
    }

    @Test func savedRulesBehindATimedRuleAreNotShownTwice() {
        // A saved rule under a timed one: the filter takes the timed one; the saved one is checked only if it's gone.
        let filter = policy { $0.rules["Work"] = [slack: false]; $0.temporaryRules = ["Work|" + slack: TemporaryRule(allowed: true, expires: Date().addingTimeInterval(600))] }
        let trace = filter.trace(flow("slack.com"), index: index)
        #expect(trace.decision.reason.rule == "timedRule" && trace.verdict == .allow)
        #expect(trace.others.map(\.reason) == [.appRule(false)])
    }

    @Test func everyMatchingDestinationRuleShowsNewestFirst() {
        let old = ConnectionRule(app: slack, host: "slack.com", allowed: false, profile: "Work")
        let new = ConnectionRule(app: slack, host: "files.slack.com", allowed: true, profile: "Work")
        let trace = policy { $0.connectionRules = [old, new] }.trace(flow("files.slack.com"), index: index)
        #expect(trace.matches.map(\.reason) == [.connectionRule(new), .connectionRule(old)])
        #expect(trace.verdict == .allow)
    }

    @Test func notesExplainWithoutDeciding() {
        // An allowed site keeps a listed host out of Protection's reach: a note, then the rules decide as usual.
        let protection = ProtectionSettings(threats: true, allowed: ["phish.example"])
        let trace = policy(protection: protection).trace(flow("login.phish.example"), index: index)
        #expect(trace.matches.first?.reason == .siteAllowed("phish.example"))
        #expect(trace.verdict == .allow && trace.decision.reason == .newAppDefault(true))
        // The kill switch paused for five minutes, and the local network let through while it blocks.
        let paused = KillSwitchPolicy(armed: true, vpnDown: true, allowedUntil: Date().addingTimeInterval(300))
        #expect(policy(killSwitch: paused).trace(flow("slack.com"), index: index).matches.first.map { if case .killSwitchPaused = $0.reason { true } else { false } } == true)
        let down = KillSwitchPolicy(armed: true, vpnDown: true)
        let lan = FilterPolicy.Flow(app: slack, process: "Slack", host: nil, address: "192.168.1.4", port: "80")
        let local = policy(killSwitch: down).trace(lan, index: index)
        #expect(local.matches.first?.reason == .killSwitchExempt(.localNetwork) && local.decision.reason == .newAppDefault(true))
    }

    @Test func fallbacksOnlyWhenNothingElseDecided() {
        // An app rule decides; the profile default and Apple software never show beside it.
        let trace = policy { $0.rules["Work"] = [slack: false]; $0.allowApple = true; $0.askNewApps = true }.trace(flow("slack.com"), index: index)
        #expect(trace.matches.map(\.reason) == [.appRule(false)])
        // The budget stops the app; the saved allow rule shows as also matched.
        let budget = policy({ $0.rules["Work"] = [slack: true] }, budget: true).trace(flow("slack.com"), index: index)
        #expect(budget.matches.map(\.reason) == [.budget, .appRule(true)])
        // Unrestricted decides; a tracker under it shows, the threat check comes first and wins outright.
        let unrestricted = policy { $0.profile = .unrestricted }.trace(flow("pixel.tracker.example"), index: index)
        #expect(unrestricted.decision.reason == .unrestricted && unrestricted.others.count == 1)
    }

    /// The trace's decision is always `decide`'s, over every rule kind.
    @Test func traceAlwaysAgreesWithDecide() {
        let now = Date()
        let rule = ConnectionRule(app: slack, host: "slack.com", allowed: false, profile: "Work")
        let changes: [(inout SavedPreferences) -> Void] = [
            { _ in }, { $0.defaultAllow = false }, { $0.askNewApps = true }, { $0.askNewApps = true; $0.allowApple = true },
            { $0.rules["Work"] = [self.slack: false] }, { $0.rules["Work"] = ["process:Slack": true] }, { $0.connectionRules = [rule] },
            { $0.blockedHosts = ["slack.com"] }, { $0.profile = .unrestricted }, { $0.pauseUpdaters = true },
            { $0.temporaryRules = ["Work|" + self.slack: TemporaryRule(allowed: false, expires: now.addingTimeInterval(60))] },
            { $0.temporaryRules = ["Work|" + self.slack: TemporaryRule(allowed: true, expires: now.addingTimeInterval(-60))] },
        ]
        let kills = [KillSwitchPolicy(), KillSwitchPolicy(armed: true, vpnDown: true), KillSwitchPolicy(armed: true, vpnDown: true, allowLAN: false)]
        let flows = [flow("slack.com"), flow("evil.example"), flow("pixel.tracker.example"), flow(nil, app: nil), flow("slack.com", app: "com.google.GoogleUpdater", process: "GoogleUpdater"),
                     FilterPolicy.Flow(app: slack, process: "Slack", host: nil, address: "192.168.1.4", port: "80"), flow("slack.com", app: "io.tailscale.ipn.macsys")]
        var checked = 0
        for change in changes {
            for kill in kills {
                for budget in [false, true] {
                    for recent in [nil, true, false] as [Bool?] {
                        let filter = policy(change, budget: budget, quota: budget ? [slack] : [], metered: true, killSwitch: kill)
                        for flow in flows {
                            let decision = filter.decide(flow, now: now, appleSigned: { true }, recentDecision: recent, index: index)
                            let trace = filter.trace(flow, now: now, appleSigned: { true }, recentDecision: recent, index: index)
                            #expect(trace.decision.verdict == decision.verdict && trace.decision.reason == decision.reason, "\(flow) \(trace.matches)")
                            #expect(trace.decision.reason.decides)
                            checked += 1
                        }
                    }
                }
            }
        }
        #expect(checked == changes.count * kills.count * 2 * 3 * flows.count)
    }

    @Test func tracesSurviveJSONAndTheJournal() throws {
        let rule = ConnectionRule(app: slack, host: "slack.com", port: "443", allowed: false, profile: "Work", expires: Date(timeIntervalSince1970: 1_800_000_000))
        let matches: [DecisionTrace.Match] = [
            .init(.allow, .killSwitchExempt(.vpnApp("io.tailscale.ipn"))), .init(.allow, .killSwitchExempt(.localNetwork)), .init(.allow, .killSwitchPaused(Date(timeIntervalSince1970: 1_800_000_000))),
            .init(.block, .protection(ProtectionDetail(kind: .agentGuard, list: "paste site", host: "paste.example", agent: "Claude Code", agentPID: 7, process: "curl"))),
            .init(.allow, .siteAllowed("ok.example")), .init(.block, .connectionRule(rule)), .init(.block, .blocklist("ads.example")),
            .init(.block, .temporaryRule(TemporaryRule(allowed: false, expires: Date(timeIntervalSince1970: 1_800_000_000)))), .init(.block, .budget), .init(.block, .quota(slack)),
            .init(.block, .updaterPaused("Google Updater")), .init(.allow, .appRule(true)), .init(.block, .recentDecision(false)), .init(.allow, .appleSoftware),
            .init(.ask, .askNewApps), .init(.block, .newAppDefault(false)), .init(.allow, .noAppRule), .init(.allow, .unrestricted), .init(.block, .killSwitch), .init(.allow, .filterOff),
        ]
        let trace = DecisionTrace(matches: matches, decided: 3)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(DecisionTrace.self, from: encoder.encode(trace)) == trace)
        let json = try #require(try JSONSerialization.jsonObject(with: encoder.encode(DecisionTrace(.block, .budget))) as? [String: Any])
        #expect(json["verdict"] as? String == "block" && json["decided"] as? Int == 0 && (json["matched"] as? [[String: Any]])?.first?["rule"] as? String == "budget")
        // Events from filters without traces still decode, and ones with a trace keep it.
        let old = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "date": 0, "app": "x", "endpoint": "y", "direction": "outgoing", "reason": "r"])
        #expect(try JSONDecoder().decode(FilterEvent.self, from: old).trace == nil)
        let event = FilterEvent(app: slack, endpoint: "slack.com:443", direction: "outgoing", reason: "App block rule", trace: DecisionTrace(.block, .appRule(false)))
        #expect(try JSONDecoder().decode(FilterEvent.self, from: JSONEncoder().encode(event)).trace == event.trace)
        // A trace whose deciding rule isn't there is refused.
        #expect(throws: (any Error).self) { try JSONDecoder().decode(DecisionTrace.self, from: Data(#"{"verdict":"allow","decided":2,"matched":[]}"#.utf8)) }
        // A recorded verdict cannot disagree with the rule it names as decisive.
        #expect(throws: (any Error).self) { try JSONDecoder().decode(DecisionTrace.self, from: Data(#"{"verdict":"allow","decided":0,"matched":[{"verdict":"block","rule":"budget"}]}"#.utf8)) }
    }

    @Test func blockedEventHistoryIncludesHostsInNondecidingRules() {
        let rule = ConnectionRule(app: slack, host: "rule.example", allowed: true, profile: "Work")
        let event = FilterEvent(app: slack, endpoint: "[2001:db8::1]:443", direction: "outgoing", reason: "VPN kill switch",
                                protection: ProtectionDetail(kind: .phishing, list: "Example", host: "protected.example"),
                                trace: DecisionTrace(matches: [.init(.block, .killSwitch),
                                                               .init(.block, .protection(ProtectionDetail(kind: .threat, list: "Example", host: "trace.example"))),
                                                               .init(.allow, .connectionRule(rule)), .init(.block, .blocklist("blocked.example"))], decided: 0))
        #expect(event.historyHosts == ["2001:db8::1", "protected.example", "trace.example", "rule.example", "blocked.example"])
        let allowedSite = FilterEvent(app: slack, endpoint: "203.0.113.9:443", direction: "outgoing", reason: "Budget",
                                      trace: DecisionTrace(matches: [.init(.allow, .siteAllowed("allowed.example")), .init(.block, .budget)], decided: 1))
        #expect(allowedSite.historyHosts == ["203.0.113.9", "allowed.example"])
        #expect(FilterEvent(app: slack, endpoint: "site.example:443", direction: "outgoing", reason: "r").historyHosts == ["site.example"])
        #expect(FilterEvent(app: slack, endpoint: "203.0.113.8:443", direction: "outgoing", reason: "Blocklist: *.legacy.example").historyHosts == ["203.0.113.8", "legacy.example"])
        #expect(FilterEvent(app: slack, endpoint: "203.0.113.8:443", direction: "outgoing", reason: "Destination rule: old.example:443 · outgoing").historyHosts == ["203.0.113.8", "old.example"])
    }

    /// Protection's own per-lookup test is `performanceWithHalfAMillionDomains`; this one is the whole decision with and
    /// without a trace, over a realistic policy: 200,000 listed hosts, 50 destination rules, a 20-entry blocklist (it is a linear scan that parses every entry, so a long one would only measure itself).
    @Test func traceCostsLittleAndDecideNothing() {
        let index = ProtectionIndex(data: ProtectionIndex.build([
            (ProtectionIndexTests.slot(1, "synthetic", .threat), (0..<200_000).map { "host-\($0).sample\($0 % 97).example" }),
            (ProtectionIndexTests.slot(2, "trackers", .tracker), (0..<20_000).map { "pixel-\($0).tracker.example" }),
        ]))!
        let filter = policy { preferences in
            preferences.defaultAllow = false
            preferences.rules["Work"] = Dictionary(uniqueKeysWithValues: (0..<300).map { ("com.example.App\($0)", $0 % 3 != 0) })
            preferences.connectionRules = (0..<50).map { ConnectionRule(app: "com.example.App\($0)", host: "api\($0).example.com", allowed: $0 % 2 == 0, profile: "Work") }
            preferences.blockedDomains = (0..<20).map { "blocked-\($0).example.net" }
            preferences.temporaryRules = ["Work|com.example.App7": TemporaryRule(allowed: false, expires: Date().addingTimeInterval(600))]
        }
        let flows = (0..<2_000).map { i -> FilterPolicy.Flow in
            let host = switch i % 5 {
            case 0: "cdn.host-\(i).sample\(i % 97).example"
            case 1: "pixel-\(i).tracker.example"
            case 2: "api\(i % 60).example.com"
            case 3: "blocked-\(i).example.net"
            default: "www.unlisted-\(i).example.org"
            }
            return .init(app: "com.example.App\(i % 400)", process: "App", host: host, address: "203.0.113.\(i % 250)", port: "443")
        }
        // Rounds alternate the two, so a busy machine slows both alike; the best round of each counts.
        var decide = Double.infinity, trace = Double.infinity, blocks = 0, rules = 0
        for _ in 0..<5 {
            var started = Date()
            blocks = 0
            for flow in flows where filter.decide(flow, index: index).verdict == .block { blocks += 1 }
            decide = min(decide, Date().timeIntervalSince(started) / Double(flows.count))
            started = Date()
            rules = 0
            for flow in flows { rules += filter.trace(flow, index: index).matches.count }
            trace = min(trace, Date().timeIntervalSince(started) / Double(flows.count))
        }
        print("Rule inspector: decide \(String(format: "%.2f", decide * 1_000_000)) µs, trace \(String(format: "%.2f", trace * 1_000_000)) µs per flow (\(String(format: "%.2f", trace / decide))×), \(rules) rules over \(flows.count) flows")
        #expect(blocks > 0 && rules > flows.count)
        // The rounds alternate, so the ratio holds on a busy machine where absolute times don't: a trace runs the same
        // checks to the end and keeps a few matches. The filter traces only the flows it blocks.
        #expect(trace < decide * 3)
        // Two Protection lookups and the rules per flow, in a debug build that may share the machine with others. The
        // limit is there to catch a scan or a runaway trace, not to time the code.
        #expect(decide < 0.01 && trace < 0.01)
    }
}

struct RuleInspectorTests {
    let index = DecisionTraceTests().index
    let slack = "com.tinyspeck.slackmacgap"

    func inspector(_ change: (inout SavedPreferences) -> Void = { _ in }, metered: Bool = false, context: RuleContext = RuleContext(names: ["com.tinyspeck.slackmacgap": "Slack"], filterActive: true)) -> RuleInspector {
        var preferences = SavedPreferences(); preferences.profile = .work; preferences.defaultAllow = true
        change(&preferences)
        return RuleInspector(preferences: preferences, budgetReached: false, metered: metered, protection: ProtectionSettings(threats: true, trackers: true), index: index, context: context)
    }

    @Test func saysWhatBlockedItAndWhatElseMatched() {
        var context = RuleContext(names: [slack: "Slack"], filterActive: true)
        context.holders[slack] = .sendLater(.unmetered, network: "iPhone")
        let result = inspector({ $0.temporaryRules = ["Work|" + slack: TemporaryRule(allowed: false, expires: Date().addingTimeInterval(1_800))] }, metered: true, context: context)
            .inspect(host: "login.phish.example", port: "443", app: slack)
        #expect(result.verdict == .block)
        #expect(result.summary == "Blocked by Protection: phish.example is on the phishing list (Phishing Army)")
        #expect(result.decided?.change.place == .protection && result.decided?.change.command == "kilobat protect allow phish.example")
        #expect(result.alsoMatched.map(\.line) == ["Also matched: Slack is paused while on iPhone, a metered network, until an unmetered one"])
        #expect(result.alsoMatched.first?.change.command == "kilobat uploads resume \(slack)")
        #expect(result.note == nil && result.enforced == true && !result.recorded)
    }

    @Test func namesTravelAndTheFilterBeingOff() {
        var context = RuleContext(names: [slack: "Slack"], filterActive: false)
        context.names["process:curl"] = nil
        let result = inspector({ $0.profile = .travel; $0.autoHotspot = true; $0.rules["Travel"] = [slack: false] }, metered: true, context: context)
            .inspect(host: "slack.com", app: slack)
        #expect(result.summary == "Blocked by App rule: Slack is blocked in Travel, which Kilobat switched to for this metered network")
        #expect(result.decided?.change.command == "kilobat reset \(slack) --profile travel")
        #expect(result.note?.contains("filter is off") == true)
        // An app Kilobat has no name for shows as its process.
        #expect(inspector().inspect(host: "example.org", app: "process:curl").summary == "Allowed by Profile default: curl has no rule, and Work allows apps without one")
    }

    @Test func blockedAttemptsUseTheFiltersOwnTrace() {
        let recorded = FilterEvent(date: Date(timeIntervalSince1970: 1_800_000_000), app: slack, endpoint: "slack.com:443", direction: "outgoing", reason: "App block rule",
                                   trace: DecisionTrace(matches: [.init(.block, .budget), .init(.allow, .appRule(true))], decided: 0))
        let result = inspector().inspect(recorded)
        #expect(result.recorded && result.date == recorded.date && result.host == "slack.com" && result.port == "443")
        #expect(result.summary.hasPrefix("Blocked by Data budget:") && result.alsoMatched.count == 1)
        // Without one, the rules as they are now, saying so.
        let old = FilterEvent(app: slack, endpoint: "[2001:db8::1]:443", direction: "outgoing", reason: "App block rule")
        let now = inspector { $0.rules["Work"] = [slack: false] }.inspect(old)
        #expect(!now.recorded && now.host == "2001:db8::1" && now.port == "443" && now.verdict == .block)
        #expect(now.note?.contains("App block rule") == true)
        let unidentified = FilterEvent(app: "Unknown app", endpoint: "example.org:443", direction: "outgoing",
                                       reason: "Default-deny rule; app identity unavailable", trace: DecisionTrace(.block, .newAppDefault(false)))
        let unknown = inspector().inspect(unidentified)
        #expect(unknown.recorded && unknown.verdict == .block && unknown.app == nil)
        #expect(unknown.summary == "Blocked by Profile default: Kilobat couldn’t identify the app, so Work blocks this connection")
        #expect(RuleInspector.endpoint("Unknown endpoint") == (nil, nil) && RuleInspector.endpoint("evil.example") == ("evil.example", nil))
    }

    @Test func inspectionsEncodeForTheCLIAndMCP() throws {
        let result = inspector().inspect(host: "evil.example", app: slack)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RuleInspection.self, from: encoder.encode(result))
        #expect(decoded.summary == result.summary && decoded.rules == result.rules && decoded.trace == result.trace)
        #expect(result.text.hasPrefix("Blocked by Protection: evil.example is on the threat list"))
    }

    @Test func unverifiedAppleIdentifierDoesNotPretendToBeSigned() {
        let result = inspector { $0.askNewApps = true; $0.allowApple = true }
            .inspect(host: "example.org", app: "com.apple.FakeNetworkingApp")
        #expect(result.verdict == .ask)
        #expect(result.decided?.rule == "askNewApps")
        #expect(result.note?.contains("Apple signing wasn’t verified") == true)
        let verified = inspector { $0.askNewApps = true; $0.allowApple = true }
            .inspect(host: "example.org", app: "com.apple.Safari", appleSigned: true)
        #expect(verified.verdict == .allow && verified.decided?.rule == "appleSoftware")
    }
}
