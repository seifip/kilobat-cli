import Foundation
import Testing
@testable import KilobatCore

/// The firewall additions: approval durations, finer destination rules, blocklist subscriptions, developer rules,
/// alert mode and asking about new destinations. The filter itself isn't run here; its decisions all go through
/// `FilterPolicy` and `ApprovalQueue`, which are.
@Suite struct ApprovalDurationTests {
    private func flow(pid: Int32?) -> FilterPolicy.Flow { .init(app: "com.example.app", process: "app", host: "api.example.com", pid: pid) }

    @Test func untilQuitCoversOnlyItsProcess() {
        var policy = FilterPolicy()
        policy.defaultAllow = false
        policy.temporary["com.example.app"] = TemporaryRule(allowed: true, expires: Date().addingTimeInterval(3_600), pid: 42)
        #expect(policy.decide(flow(pid: 42)).verdict == .allow)
        #expect(policy.decide(flow(pid: 43)).verdict == .block)
        #expect(policy.decide(flow(pid: nil)).verdict == .block)
    }

    @Test func aRuleWithoutAProcessStillCoversEveryProcess() {
        let rule = TemporaryRule(allowed: false, expires: Date().addingTimeInterval(60))
        #expect(rule.applies(pid: 1, now: Date()) && rule.applies(pid: nil, now: Date()))
        #expect(!rule.applies(pid: 1, now: Date().addingTimeInterval(120)))
    }

    @Test func exitedProcessesLoseTheirRules() {
        var rules = ["Work|a": TemporaryRule(allowed: true, expires: .distantFuture, pid: 10),
                     "Work|b": TemporaryRule(allowed: true, expires: .distantFuture, pid: 11),
                     "Work|c": TemporaryRule(allowed: false, expires: .distantFuture)]
        var asked: [Int32] = []
        #expect(TemporaryRule.pruneExited(&rules) { asked.append($0); return $0 == 11 })
        #expect(Set(rules.keys) == ["Work|b", "Work|c"])
        #expect(asked.sorted() == [10, 11])
        #expect(!TemporaryRule.pruneExited(&rules) { _ in true })
    }

    @Test func thePidTravelsToTheFilterAndBack() {
        var preferences = SavedPreferences(); preferences.profile = .work
        preferences.temporaryRules = ["Work|com.example.app": TemporaryRule(allowed: true, expires: Date().addingTimeInterval(600), pid: 77)]
        let policy = FilterPolicy(FilterController.policy(preferences, budgetReached: false))
        #expect(policy.temporary["com.example.app"]?.pid == 77)
    }

    @Test func durationWords() {
        #expect(ApprovalDuration(word: "once") == .once)
        #expect(ApprovalDuration(word: "until-quit") == .untilQuit)
        #expect(ApprovalDuration(word: "quit") == .untilQuit)
        #expect(ApprovalDuration(word: "hour") == .hour)
        #expect(ApprovalDuration(word: "forever") == .forever)
        #expect(ApprovalDuration(word: "60") == nil)
    }

    @Test func theTraceKeepsTheProcess() throws {
        let match = DecisionTrace.Match(.allow, .temporaryRule(TemporaryRule(allowed: true, expires: Date(timeIntervalSince1970: 1_000), pid: 9)))
        let decoded = try JSONDecoder().decode(DecisionTrace.Match.self, from: JSONEncoder().encode(match))
        guard case .temporaryRule(let rule) = decoded.reason else { Issue.record("not a timed rule"); return }
        #expect(rule.pid == 9)
    }
}

@Suite struct FinerDestinationRuleTests {
    private func flow(host: String? = nil, address: String? = nil, port: String? = "443", transport: String? = "tcp") -> FilterPolicy.Flow {
        .init(app: "com.example.app", process: "app", host: host, address: address, port: port, transport: transport)
    }
    private func policy(_ rules: [ConnectionRule]) -> FilterPolicy {
        var policy = FilterPolicy(); policy.defaultAllow = true; policy.connectionRules = rules
        return policy
    }

    @Test func aRuleSavedBeforeTheseFieldsKeepsItsMeaning() throws {
        let old = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","app":"com.example.app","host":"example.com","port":"","direction":"any","allowed":false,"profile":"Work"}]"#
        let rules = try JSONDecoder().decode([ConnectionRule].self, from: Data(old.utf8))
        #expect(rules[0].transport == nil && rules[0].exact == nil)
        let policy = policy(rules)
        #expect(policy.decide(flow(host: "example.com")).verdict == .block)
        #expect(policy.decide(flow(host: "api.example.com", transport: "udp")).verdict == .block)
        #expect(policy.decide(flow(host: "notexample.com")).verdict == .allow)
    }

    @Test func protocolNarrowsARule() {
        let policy = policy([ConnectionRule(app: "com.example.app", host: "example.com", allowed: false, profile: "Work", transport: "udp")])
        #expect(policy.decide(flow(host: "example.com", transport: "udp")).verdict == .block)
        #expect(policy.decide(flow(host: "example.com", transport: "tcp")).verdict == .allow)
        // A flow whose protocol is unknown matches only rules for any protocol.
        #expect(policy.decide(flow(host: "example.com", transport: nil)).verdict == .allow)
    }

    @Test func exactLeavesOutSubdomains() {
        let policy = policy([ConnectionRule(app: "com.example.app", host: "example.com", allowed: false, profile: "Work", exact: true)])
        #expect(policy.decide(flow(host: "example.com")).verdict == .block)
        #expect(policy.decide(flow(host: "www.example.com")).verdict == .allow)
    }

    @Test func rangesMatchAddressesInThem() {
        let policy = policy([ConnectionRule(app: "com.example.app", host: "10.0.0.0/8", allowed: false, profile: "Work"),
                             ConnectionRule(app: "com.example.app", host: "2001:db8::/32", allowed: false, profile: "Work")])
        #expect(policy.decide(flow(host: "api.example.com", address: "10.20.30.40")).verdict == .block)
        #expect(policy.decide(flow(address: "11.0.0.1")).verdict == .allow)
        #expect(policy.decide(flow(address: "2001:db8:1::5")).verdict == .block)
        #expect(policy.decide(flow(address: "2001:db9::5")).verdict == .allow)
        // An IPv4-mapped address matches the IPv4 range.
        #expect(policy.decide(flow(address: "::ffff:10.1.1.1")).verdict == .block)
    }

    @Test func aSingleAddressMatchesInAnySpelling() {
        let policy = policy([ConnectionRule(app: "com.example.app", host: "2001:db8::1", allowed: false, profile: "Work")])
        #expect(policy.decide(flow(address: "2001:0db8:0:0::1")).verdict == .block)
    }

    @Test func destinationsAreChecked() {
        #expect(ConnectionRule.validDestination("Example.COM.") == "example.com")
        #expect(ConnectionRule.validDestination("*.example.com") == "example.com")
        #expect(ConnectionRule.validDestination("10.1.2.3/8") == "10.0.0.0/8")
        #expect(ConnectionRule.validDestination("2001:db8::7/32") == "2001:db8::/32")
        #expect(ConnectionRule.validDestination("0.0.0.0/0") == nil)
        #expect(ConnectionRule.validDestination("10.0.0.0/33") == nil)
        #expect(ConnectionRule.validDestination("not a host") == nil)
        #expect(ConnectionRule.validDestination("203.0.113.5") == "203.0.113.5")
    }

    @Test func exactIsIgnoredForAddresses() {
        #expect(ConnectionRule(app: "a.b", host: "10.0.0.0/8", allowed: true, profile: "Work", exact: true).exact == nil)
        #expect(ConnectionRule(app: "a.b", host: "x.example", allowed: true, profile: "Work", transport: "QUIC").transport == nil)
    }

    @Test func theTraceAgreesWithTheDecision() {
        let policy = policy([ConnectionRule(app: "com.example.app", host: "10.0.0.0/8", allowed: true, profile: "Work"),
                             ConnectionRule(app: "com.example.app", host: "10.1.0.0/16", allowed: false, profile: "Work", transport: "tcp")])
        let flow = flow(address: "10.1.2.3")
        let trace = policy.trace(flow)
        #expect(trace.decision.verdict == policy.decide(flow).verdict)
        #expect(trace.matches.count == 2)
    }

    @Test func rulesFilesCarryProtocolAndExactness() throws {
        var preferences = SavedPreferences(); preferences.profile = .work
        preferences.connectionRules = [ConnectionRule(app: "com.example.app", host: "example.com", port: "53", allowed: false, profile: NetworkProfile.work.rawValue, transport: "udp", exact: true),
                                       ConnectionRule(app: "com.example.app", host: "192.168.0.0/16", allowed: true, profile: NetworkProfile.work.rawValue)]
        let data = try RuleBackup(preferences).data()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""protocol" : "udp""#))
        let backup = try RuleBackup.parse(data)
        let plan = RuleImportPlan(backup, into: SavedPreferences(), mode: .merge)
        let imported = plan.result.connectionRules ?? []
        #expect(imported.contains { $0.host == "example.com" && $0.transport == "udp" && $0.exact == true && $0.port == "53" })
        #expect(imported.contains { $0.host == "192.168.0.0/16" && $0.allowed })
        // Importing the same file again changes nothing.
        #expect(RuleImportPlan(backup, into: plan.result, mode: .merge).isEmpty)
    }

    @Test func anOlderRulesFileStillImports() throws {
        let file = #"{"format":"kilobat-rules","version":1,"profiles":[{"id":"work","destinations":[{"app":"com.example.app","host":"example.com","allow":false}]}]}"#
        let plan = RuleImportPlan(try RuleBackup.parse(Data(file.utf8)), into: SavedPreferences(), mode: .merge)
        let rule = try #require(plan.result.connectionRules?.first)
        #expect(rule.transport == nil && rule.exact == nil && rule.host == "example.com")
    }
}

@Suite struct BlocklistSubscriptionTests {
    @Test func onlyHTTPSAddressesWithoutCredentials() {
        #expect(BlocklistSubscription.validURL("https://example.com/hosts.txt") != nil)
        #expect(BlocklistSubscription.validURL("http://example.com/hosts.txt") == nil)
        #expect(BlocklistSubscription.validURL("https://user:secret@example.com/list") == nil)
        #expect(BlocklistSubscription.validURL("file:///etc/hosts") == nil)
    }

    @Test func addingChecksDuplicatesAndTheLimit() throws {
        var preferences = SavedPreferences()
        let first = try BlocklistSubscription.add(name: "", url: "https://lists.example/one.txt", to: &preferences)
        #expect(first.name == "lists.example")
        #expect(throws: BlocklistSubscription.Failure.duplicate) { try BlocklistSubscription.add(name: nil, url: "https://lists.example/one.txt", to: &preferences) }
        for index in 2...BlocklistSubscription.maximumCount { try BlocklistSubscription.add(name: nil, url: "https://lists.example/\(index).txt", to: &preferences) }
        #expect(throws: BlocklistSubscription.Failure.tooMany) { try BlocklistSubscription.add(name: nil, url: "https://lists.example/more.txt", to: &preferences) }
        #expect(BlocklistSubscription.set(first.id, on: false, in: &preferences))
        #expect(ProtectionPreferences.subscriptions(preferences).count == BlocklistSubscription.maximumCount - 1)
        #expect(BlocklistSubscription.remove(first.id, from: &preferences))
        #expect(!BlocklistSubscription.remove(first.id, from: &preferences))
    }

    @Test func noneByDefault() {
        let preferences = SavedPreferences()
        #expect(ProtectionPreferences.subscriptions(preferences).isEmpty)
        #expect(ProtectionPreferences.settings(preferences, pro: true).blocklists == false)
    }

    @Test func downloadsAreChecked() throws {
        let list = try #require(BlocklistSubscription(name: "Mine", url: "https://lists.example/a").list)
        #expect(throws: ProtectionUpdater.Failure.self) { try ProtectionUpdater.validate(Data(), list: list, previous: 0) }
        #expect(throws: ProtectionUpdater.Failure.self) { try ProtectionUpdater.validate(Data("<!DOCTYPE html><html>Not found</html>".utf8), list: list, previous: 0) }
        #expect(throws: ProtectionUpdater.Failure.self) { try ProtectionUpdater.validate(Data("# only comments\n".utf8), list: list, previous: 0) }
        // Hosts files, plain domains and Adblock rules it can use; the rest is skipped, not refused.
        let parsed = try ProtectionUpdater.validate(Data("0.0.0.0 ads.example\ntracker.example\n||pixel.example^\n##.banner\n@@||good.example^\n/path/ad.js\n".utf8), list: list, previous: 0)
        #expect(Set(parsed.domains) == ["ads.example", "tracker.example", "pixel.example"])
        #expect(parsed.skipped >= 2)
        // A sudden collapse keeps the last good copy.
        #expect(throws: ProtectionUpdater.Failure.self) { try ProtectionUpdater.validate(Data("a.example\n".utf8), list: list, previous: 1_000) }
    }

    @Test func theUpdaterFetchesASubscriptionAndTheIndexHasIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kb-subs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let updater = ProtectionUpdater(directory: directory) { request in
            (Data("0.0.0.0 ads.example\n0.0.0.0 track.example\n".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["ETag": "\"1\""])!)
        }
        let subscription = BlocklistSubscription(name: "Mine", url: "https://lists.example/a", id: "sub-test")
        let list = try #require(subscription.list)
        let state = await updater.update([list])
        #expect(state.lists["sub-test"]?.entries == 2)
        #expect(state.lists["sub-test"]?.error == nil)
        let index = try #require(updater.build([list]))
        #expect(index.match(host: "x.ads.example", in: [.blocklist])?.lists.first?.name == "Mine")
        updater.forget("sub-test")
        #expect(updater.loadState().lists["sub-test"] == nil)
    }

    private func policy(exceptions: [String: [String]] = [:], allowed: [String] = []) -> FilterPolicy {
        var policy = FilterPolicy(); policy.defaultAllow = true
        policy.protection = ProtectionSettings(allowed: allowed, blocklists: true)
        policy.domainExceptions = exceptions
        return policy
    }
    private var index: ProtectionIndex {
        ProtectionIndex(data: ProtectionIndex.build([(ProtectionIndex.Slot(slot: 9, id: "sub-a", name: "Mine", category: .blocklist, entries: 3), ["ads.example", "apple.com", "203.0.113.9"])]))!
    }
    private func flow(_ host: String?, address: String? = nil, app: String? = "com.example.app") -> FilterPolicy.Flow {
        .init(app: app, process: "app", host: host, address: address)
    }

    @Test func subscribedListsBlockEveryApp() {
        let decision = policy().decide(flow("cdn.ads.example"), index: index)
        #expect(decision.verdict == .block)
        #expect(decision.reason == .subscribedList(entry: "ads.example", list: "Mine"))
        #expect(policy().decide(flow("cdn.ads.example", app: nil), index: index).verdict == .block)
        #expect(policy().decide(flow(nil, address: "203.0.113.9"), index: index).verdict == .block)
    }

    @Test func whatTheyNeverBlock() {
        #expect(policy().decide(flow("www.apple.com"), index: index).verdict == .allow)
        #expect(policy(allowed: ["ads.example"]).decide(flow("ads.example"), index: index).verdict == .allow)
        #expect(policy(exceptions: ["com.example.app": ["ads.example"]]).decide(flow("ads.example"), index: index).verdict == .allow)
        var withRule = policy()
        withRule.connectionRules = [ConnectionRule(app: "com.example.app", host: "ads.example", allowed: true, profile: "Work")]
        #expect(withRule.decide(flow("ads.example"), index: index).verdict == .allow)
        var off = policy(); off.protection.blocklists = false
        #expect(off.decide(flow("ads.example"), index: index).verdict == .allow)
    }

    @Test func theRecordReadsAsABlocklistForOlderReaders() throws {
        let match = DecisionTrace.Match(.block, .subscribedList(entry: "ads.example", list: "Mine"))
        let data = try JSONEncoder().encode(match)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["rule"] as? String == "blocklist")
        #expect(try JSONDecoder().decode(DecisionTrace.Match.self, from: data).reason == match.reason)
    }

    @Test func theSwitchTravelsInTheConfiguration() {
        let settings = ProtectionSettings(blocklists: true)
        #expect(settings.active)
        #expect(ProtectionSettings(settings.configuration).blocklists)
    }

    @Test func statusShowsEachList() {
        var preferences = SavedPreferences()
        preferences.blocklistSubscriptions = [BlocklistSubscription(name: "Mine", url: "https://lists.example/a", id: "sub-a")]
        var state = ProtectionState(); var entry = ProtectionListState(); entry.entries = 12; entry.error = "HTTP 404"
        state.lists["sub-a"] = entry
        let status = BlocklistStatus.make(preferences, state: state, filterActive: true)
        #expect(status.lists.first?.entries == 12)
        #expect(BlocklistStatus.detail(status.lists[0]).contains("HTTP 404"))
    }
}

@Suite struct DeveloperRuleTests {
    @Test func keysAndTeams() {
        #expect(DeveloperRule.key("AB12CD34EF") == "team:AB12CD34EF")
        #expect(DeveloperRule.team("team:AB12CD34EF") == "AB12CD34EF")
        #expect(DeveloperRule.team("team:short") == nil)
        #expect(DeveloperRule.team("com.example.app") == nil)
        #expect(DeveloperRule.team("team:ab12cd34ef") == nil)
    }

    @Test func neverForAppleOrWithoutATeam() {
        #expect(DeveloperRule.eligible(identifier: "com.example.app", team: "AB12CD34EF"))
        #expect(!DeveloperRule.eligible(identifier: "com.apple.Safari", team: "AB12CD34EF"))
        #expect(!DeveloperRule.eligible(identifier: "com.example.app", team: nil))
        #expect(!DeveloperRule.eligible(identifier: "com.example.app", team: ""))
    }

    private func policy() -> FilterPolicy {
        var policy = FilterPolicy(); policy.defaultAllow = false
        policy.rules = ["team:AB12CD34EF": true]
        return policy
    }
    private let flow = FilterPolicy.Flow(app: "com.example.helper", process: "helper", host: "api.example.com")

    @Test func aHelperWithoutARuleFollowsItsDeveloper() {
        let decision = policy().decide(flow, team: { "AB12CD34EF" })
        #expect(decision.verdict == .allow)
        #expect(decision.reason == .teamRule(team: "AB12CD34EF", allowed: true))
    }

    @Test func theAppsOwnRuleWins() {
        var policy = policy(); policy.rules["com.example.helper"] = false
        #expect(policy.decide(flow, team: { "AB12CD34EF" }).verdict == .block)
    }

    @Test func anUnprovenOrAppleSignatureMatchesNothing() {
        // The filter answers nil for code Apple signed and for a signature that doesn't prove the team.
        #expect(policy().decide(flow, team: { nil }).reason == .newAppDefault(false))
        #expect(policy().decide(flow, team: { "ZZ99ZZ99ZZ" }).verdict == .block)
    }

    @Test func theTeamIsAskedOnlyWhenARuleCouldUseIt() {
        var asked = 0
        var plain = FilterPolicy(); plain.defaultAllow = true
        _ = plain.decide(flow, team: { asked += 1; return "AB12CD34EF" })
        #expect(asked == 0)
    }

    @Test func theRecordReadsAsAnAppRuleForOlderReaders() throws {
        let match = DecisionTrace.Match(.allow, .teamRule(team: "AB12CD34EF", allowed: true))
        let data = try JSONEncoder().encode(match)
        #expect((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["rule"] as? String == "appRule")
        #expect(try JSONDecoder().decode(DecisionTrace.Match.self, from: data).reason == match.reason)
    }

    @Test func developerNames() {
        #expect(DeveloperName.name(signer: "Developer ID Application: Example Inc (AB12CD34EF) · AB12CD34EF", team: "AB12CD34EF") == "Example Inc")
        #expect(DeveloperName.name(signer: nil, team: "AB12CD34EF") == "Team AB12CD34EF")
    }

    @Test func rulesFilesKeepDeveloperRules() throws {
        var preferences = SavedPreferences(); preferences.profile = .work
        preferences.rules[NetworkProfile.work.rawValue] = ["team:AB12CD34EF": false]
        let backup = try RuleBackup.parse(RuleBackup(preferences).data())
        #expect(RuleImportPlan(backup, into: SavedPreferences(), mode: .merge).result.rules[NetworkProfile.work.rawValue]?["team:AB12CD34EF"] == false)
    }
}

@Suite struct AlertModeTests {
    @Test func modesRoundTrip() {
        for mode in NewAppPolicy.Mode.allCases {
            var preferences = SavedPreferences()
            mode.apply(to: &preferences)
            #expect(NewAppPolicy.mode(preferences) == mode)
        }
        // A Kilobat that predates alert mode reads it as allow.
        var preferences = SavedPreferences(); NewAppPolicy.Mode.alert.apply(to: &preferences)
        #expect(preferences.defaultAllow && preferences.askNewApps == nil)
    }

    @Test func alertAllowsAndTellsTheFilterToList() {
        var preferences = SavedPreferences(); preferences.profile = .work
        NewAppPolicy.Mode.alert.apply(to: &preferences)
        let policy = FilterPolicy(FilterController.policy(preferences, budgetReached: false))
        #expect(policy.alertNewApps)
        #expect(policy.decide(.init(app: "com.new.app", process: "new", host: "x.example")).reason == .newAppDefault(true))
    }

    @Test func rulesFilesKeepAlertModeForOlderReaders() throws {
        var preferences = SavedPreferences(); NewAppPolicy.Mode.alert.apply(to: &preferences)
        let backup = RuleBackup(preferences)
        #expect(backup.newApps == "allow" && backup.alertNewApps == true)
        let plan = RuleImportPlan(try RuleBackup.parse(backup.data()), into: SavedPreferences(), mode: .merge)
        #expect(NewAppPolicy.mode(plan.result) == .alert)
    }

    @Test func theRecorderListsEachAppOnce() {
        let recorder = NewAppRecorder()
        var appleAsked = 0
        for host in ["a.example:443", "b.example:443", "a.example:443"] {
            recorder.record(uid: 501, app: "com.new.app", process: "new", destination: host) { appleAsked += 1; return false }
        }
        recorder.record(uid: 501, app: "com.google.Chrome", process: "Chrome", destination: "private.example:443") { false }
        recorder.record(uid: 501, app: "com.apple.Notes", process: "Notes", destination: "icloud.com:443") { true }
        recorder.record(uid: 501, app: "com.apple.Notes", process: "Notes", destination: "icloud.com:443") { appleAsked += 100; return true }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let rows = (try? decoder.decode([NewAppSighting].self, from: recorder.encoded(for: 501))) ?? []
        #expect(appleAsked == 1)
        let app = rows.first { $0.app == "com.new.app" }
        #expect(app?.connections == 3 && app?.destinations == ["a.example:443", "b.example:443"])
        #expect(rows.first { $0.app == "com.google.Chrome" }?.destinations == [])
        #expect(!rows.contains { $0.app == "com.apple.Notes" })
        #expect(recorder.encoded(for: 502) == Data("[]".utf8))
    }

    @Test @MainActor func theReviewListMergesAndForgets() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kb-new-apps-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let review = NewAppReview(file: file)
        let now = Date()
        review.merge([NewAppSighting(app: "com.new.app", process: "new", first: now, last: now, connections: 2, destinations: ["a.example:443"])], now: now)
        review.merge([NewAppSighting(app: "com.new.app", process: "new", first: now, last: now, connections: 5, destinations: ["b.example:443"])], now: now)
        #expect(review.items.first?.connections == 5 && review.items.first?.destinations == ["a.example:443", "b.example:443"])
        #expect(NewAppReview(file: file).items.count == 1)
        var preferences = SavedPreferences(); preferences.profile = .work
        #expect(review.pending(preferences).count == 1)
        preferences.rules[NetworkProfile.work.rawValue] = ["com.new.app": true]
        #expect(review.pending(preferences).isEmpty)
        review.dismiss("com.new.app")
        review.merge([NewAppSighting(app: "com.new.app", process: "new")], now: now)
        #expect(review.items.isEmpty)
        // Thirty days on, an old sighting goes.
        review.clear()
        review.merge([NewAppSighting(app: "com.old.app", process: "old", first: now.addingTimeInterval(-40 * 86_400), last: now.addingTimeInterval(-40 * 86_400))], now: now)
        #expect(review.items.isEmpty)
    }
}

@Suite struct DestinationApprovalTests {
    private func approval(_ host: String, site: String? = "example.com", uid: UInt32 = 501) -> PendingApproval {
        PendingApproval(app: "com.example.app", process: "app", path: nil, signer: nil, signatureValid: true, pid: 1, uid: uid,
                        destinations: [.init(host: host, address: nil, port: "443")], site: site)
    }

    @Test func sitesGroupABurst() {
        #expect(PendingApproval.site(for: .init(host: "a.cdn.example.com", address: nil, port: nil)) == "example.com")
        #expect(PendingApproval.site(for: .init(host: "www.bbc.co.uk", address: nil, port: nil)) == "bbc.co.uk")
        #expect(PendingApproval.site(for: .init(host: nil, address: "203.0.113.5", port: nil)) == "203.0.113.5")
        #expect(PendingApproval.site(for: .init(host: "example.com", address: nil, port: nil)) == "example.com")
    }

    @Test func aChangedPromptRefusesTheOldAnswer() throws {
        let queue = ApprovalQueue<Int>()
        var resumed: [Int: Bool] = [:]
        queue.resume = { resumed[$0] = $1 }
        queue.hold(1, approval: approval("api.example.com"))
        let shown = try JSONDecoder().decode([PendingApproval].self, from: queue.encoded(for: 501))[0]
        queue.hold(2, approval: approval("cdn.example.com"))
        let now = try JSONDecoder().decode([PendingApproval].self, from: queue.encoded(for: 501))[0]
        #expect(now.approvalID != shown.approvalID)
        #expect(now.destinations.count == 2)
        #expect(!queue.answer(ApprovalAnswer(shown, allowed: true, scope: .domain), uid: 501))
        #expect(resumed.isEmpty)
        #expect(queue.answer(ApprovalAnswer(now, allowed: true, scope: .domain), uid: 501))
        #expect(resumed == [1: true, 2: true])
    }

    @Test func aHostAnswerLeavesTheRestWaiting() throws {
        let queue = ApprovalQueue<Int>()
        var resumed: [Int: Bool] = [:]
        queue.resume = { resumed[$0] = $1 }
        queue.hold(1, approval: approval("api.example.com"))
        queue.hold(2, approval: approval("cdn.example.com"))
        var shown = try JSONDecoder().decode([PendingApproval].self, from: queue.encoded(for: 501))[0]
        shown.destinations = [.init(host: "api.example.com", address: nil, port: "443")]
        #expect(queue.answer(ApprovalAnswer(shown, allowed: false, scope: .host), uid: 501))
        #expect(resumed == [1: false])
        let rest = try JSONDecoder().decode([PendingApproval].self, from: queue.encoded(for: 501))
        #expect(rest.count == 1 && rest[0].destinations.map(\.host) == ["cdn.example.com"] && rest[0].approvalID != shown.approvalID)
        #expect(queue.recentDestination("com.example.app", destination: .init(host: "api.example.com", address: nil, port: "443"), uid: 501) == false)
        #expect(queue.recentDestination("com.example.app", destination: .init(host: "cdn.example.com", address: nil, port: "443"), uid: 501) == nil)
    }

    @Test func eachSiteAsksOnItsOwnAndTheAppPromptStaysApart() throws {
        let queue = ApprovalQueue<Int>()
        queue.resume = { _, _ in }
        queue.hold(1, approval: approval("api.example.com"))
        queue.hold(2, approval: approval("telemetry.other.net", site: "other.net"))
        queue.hold(3, approval: approval("x.example.com", site: nil))
        let prompts = try JSONDecoder().decode([PendingApproval].self, from: queue.encoded(for: 501))
        #expect(Set(prompts.map(\.id)) == ["com.example.app|example.com", "com.example.app|other.net", "com.example.app"])
        #expect(queue.decide("com.example.app", allowed: true, uid: 501))
        #expect(try JSONDecoder().decode([PendingApproval].self, from: queue.encoded(for: 501)).count == 2)
        #expect(queue.recentDecision("com.example.app", uid: 501) == true)
    }

    @Test func heldConnectionsGiveUpAfterAMinute() {
        let queue = ApprovalQueue<Int>()
        var resumed: [Int: Bool] = [:]
        queue.resume = { resumed[$0] = $1 }
        queue.hold(1, approval: approval("api.example.com"))
        queue.expire(now: Date().addingTimeInterval(61))
        #expect(resumed == [1: false])
    }

    private func policy(rules: [ConnectionRule] = []) -> FilterPolicy {
        var policy = FilterPolicy(); policy.defaultAllow = false
        policy.rules = ["com.example.app": true]
        policy.askDestinations = ["com.example.app"]
        policy.connectionRules = rules
        return policy
    }
    private func flow(_ host: String, direction: String = "outgoing") -> FilterPolicy.Flow {
        .init(app: "com.example.app", process: "app", host: host, direction: direction)
    }

    @Test func anUncoveredDestinationAsks() {
        #expect(policy().decide(flow("new.example")).reason == .askNewDestination)
        // Off for an app that wasn't marked.
        var other = policy(); other.askDestinations = []
        #expect(other.decide(flow("new.example")).verdict == .allow)
    }

    @Test func whatDoesNotAsk() {
        let covered = policy(rules: [ConnectionRule(app: "com.example.app", host: "known.example", allowed: true, profile: "Work")])
        #expect(covered.decide(flow("api.known.example")).verdict == .allow)
        #expect(policy().decide(flow("printer.local")).verdict == .allow)
        #expect(policy().decide(flow("new.example", direction: "incoming")).verdict == .allow)
        #expect(policy().decide(flow("new.example"), destinationAnswer: true).verdict == .allow)
        #expect(policy().decide(flow("new.example"), destinationAnswer: false).verdict == .block)
        var blocked = policy(); blocked.rules = ["com.example.app": false]
        #expect(blocked.decide(flow("new.example")).verdict == .block)
    }

    @Test @MainActor func answersBecomeRules() {
        var approval = approval("api.example.com")
        approval.destinations.append(.init(host: "cdn.example.com", address: nil, port: "443"))
        let host = FilterController.destinationRules(approval, allowed: true, scope: .host, duration: .forever, profile: "Work")
        #expect(Set(host.map(\.host)) == ["api.example.com", "cdn.example.com"] && host.allSatisfy { $0.exact == true && $0.expires == nil })
        let domain = FilterController.destinationRules(approval, allowed: false, scope: .domain, duration: .hour, profile: "Work")
        #expect(domain.count == 1 && domain[0].host == "example.com" && domain[0].exact == nil && domain[0].expires != nil && !domain[0].allowed)
        #expect(FilterController.destinationRules(approval, allowed: true, scope: .domain, duration: .once, profile: "Work").isEmpty)
        #expect(FilterController.destinationRules(approval, allowed: true, scope: .anywhere, duration: .forever, profile: "Work").isEmpty)
    }

    @Test func turningItOnNeedsProTurningItOffNever() {
        #expect(!RuleLoosening.permitted(.askDestinations(on: true), hasPro: false))
        #expect(RuleLoosening.permitted(.askDestinations(on: false), hasPro: false))
    }
}
