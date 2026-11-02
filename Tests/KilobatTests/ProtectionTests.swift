import Foundation
import Testing
@testable import KilobatCore

/// Sample hosts only (.example, .test and documentation addresses): no real malware domain appears in these tests.
struct ProtectionParsingTests {
    @Test func parsesHostsFiles() {
        let text = """
        # Title: sample
        127.0.0.1 localhost
        0.0.0.0 0.0.0.0
        0.0.0.0 Malware.Example   # trailing comment
        0.0.0.0 a.example b.example
        ::1 ip6-localhost
        """
        let parsed = BlocklistParser.parse(text)
        #expect(parsed.domains == ["a.example", "b.example", "malware.example"])
        #expect(parsed.addresses.isEmpty)
    }

    @Test func parsesDomainsAndWildcards() {
        let parsed = BlocklistParser.parse("# comment\nphish.example\n*.scam.example\ntrailing.example.\n\n198.51.100.7\n10.0.0.1\nnot a domain\n")
        #expect(parsed.domains == ["phish.example", "scam.example", "trailing.example"])
        // Bare addresses are kept (URLhaus lists IPs); the local network never is.
        #expect(parsed.addresses == ["198.51.100.7"])
        #expect(parsed.skipped == 2)
    }

    @Test func parsesAdblockRules() {
        let text = """
        [Adblock Plus]
        ! Title: sample
        ||tracker.example^
        ||ads.example^$important
        @@||allowed.example^
        ||cdn.example/path.js
        ||third.example^$third-party
        ##.banner
        """
        let parsed = BlocklistParser.parse(text)
        #expect(parsed.domains == ["ads.example", "tracker.example"])
        // The exception, the path and the third-party rule; ## cosmetic filters read as comments.
        #expect(parsed.skipped == 3)
    }

    @Test func normalisesNames() {
        #expect(HostName.normalize("Evil.Example.") == "evil.example")
        #expect(HostName.normalize("bücher.example") == "xn--bcher-kva.example")
        #expect(HostName.normalize("xn--bcher-kva.example") == "xn--bcher-kva.example")
        #expect(HostName.normalize("[2001:db8::1]") == "2001:db8::1")
        #expect(HostName.normalize("has space.example") == nil)
        #expect(HostName.normalize("") == nil)
        #expect(HostName.punycode("münchen") == "mnchen-3ya")
    }
}

struct ProtectionIndexTests {
    static func slot(_ number: UInt8, _ id: String, _ category: ProtectionCategory) -> ProtectionIndex.Slot {
        ProtectionIndex.Slot(slot: number, id: id, name: id, category: category, entries: 0)
    }
    static func sample() -> ProtectionIndex {
        ProtectionIndex(data: ProtectionIndex.build([
            (slot(1, "threats", .threat), ["evil.example", "xn--bcher-kva.example", "198.51.100.7", "2001:db8::bad"]),
            (slot(2, "malware", .malware), ["evil.example", "payload.test"]),
            (slot(3, "trackers", .tracker), ["tracker.example"]),
            (slot(250, "agent-known", .known), ["registry.example"]),
        ]))!
    }

    @Test func matchesSubdomainsButNotParentsOrLookalikes() {
        let index = Self.sample()
        #expect(index.match(host: "evil.example")?.entry == "evil.example")
        #expect(index.match(host: "a.b.evil.example")?.entry == "evil.example")
        #expect(index.match(host: "example") == nil)
        #expect(index.match(host: "notevil.example") == nil)
        #expect(index.match(host: "evil.example.org") == nil)
        #expect(index.match(host: "good.example") == nil)
    }

    @Test func reportsEveryListAndFiltersByCategory() {
        let index = Self.sample()
        #expect(index.match(host: "evil.example")?.categories == [.threat, .malware])
        #expect(index.match(host: "tracker.example", in: ProtectionCategory.threats) == nil)
        #expect(index.match(host: "tracker.example", in: [.tracker]) != nil)
        #expect(index.match(host: "registry.example", in: [.known]) != nil)
    }

    @Test func matchesAddressesAndPunycode() {
        let index = Self.sample()
        #expect(index.match(host: nil, address: "198.51.100.7")?.entry == "198.51.100.7")
        #expect(index.match(host: "198.51.100.7") != nil)
        #expect(index.match(host: nil, address: "198.51.100.8") == nil)
        #expect(index.match(host: nil, address: HostName.normalize("2001:0db8:0000::0bad")) != nil)
        #expect(index.match(host: HostName.normalize("Shop.Bücher.Example."))?.entry == "xn--bcher-kva.example")
    }

    @Test func readsBackFromAFileAndRejectsGarbage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let holder = ProtectionIndexHolder(file: directory.appendingPathComponent("protection.index"))
        #expect(holder.index == nil && holder.digest.isEmpty)
        #expect(!holder.install(Data("not an index".utf8)))
        let data = ProtectionIndex.build([(Self.slot(1, "t", .threat), ["evil.example"])])
        #expect(holder.install(data))
        #expect(holder.index?.match(host: "x.evil.example") != nil)
        #expect(holder.digest == ProtectionIndex(data: data)?.digest)
        // A file cut short is refused, and the index already in use stays.
        #expect(!holder.install(data.prefix(data.count - 8)))
        #expect(holder.index?.match(host: "evil.example") != nil)
        #expect(ProtectionIndexHolder(file: directory.appendingPathComponent("protection.index")).index != nil)
    }

    /// 500,000 synthetic domains: build time, size, and lookup time per flow (several suffixes each).
    @Test func performanceWithHalfAMillionDomains() {
        let domains = (0..<500_000).map { "host-\($0)-\(($0 &* 2_654_435_761) % 99_991).sample\($0 % 97).example" }
        var started = Date()
        let data = ProtectionIndex.build([(Self.slot(1, "synthetic", .threat), domains)])
        let build = Date().timeIntervalSince(started)
        let index = ProtectionIndex(data: data)!
        #expect(index.count == 500_000)
        let probes = (0..<20_000).map { $0 % 2 == 0 ? "cdn.a.b.host-\($0)-\(($0 &* 2_654_435_761) % 99_991).sample\($0 % 97).example" : "www.unlisted-\($0).example.org" }
        started = Date()
        var hits = 0
        for probe in probes where index.match(host: probe, in: ProtectionCategory.threats) != nil { hits += 1 }
        let perLookup = Date().timeIntervalSince(started) / Double(probes.count)
        #expect(hits == 10_000)
        print("Protection index: 500,000 domains in \(data.count / 1_048_576) MB (\(data.count) bytes, 8 per entry), built in \(String(format: "%.2f", build)) s, \(String(format: "%.2f", perLookup * 1_000_000)) µs per lookup")
        // Generous for debug builds on a busy machine; release builds are far faster.
        #expect(perLookup < 0.001)  // 15–40 µs in debug builds; the limit leaves room for a loaded machine, and a scan of 500,000 would still fail it
        #expect(data.count < 500_000 * 8 + 4_096)
    }
}

struct ProtectionPolicyTests {
    let index = ProtectionIndexTests.sample()
    let claude = AgentOwner(agent: AgentIdentity(id: "claude", name: "Claude Code"), pid: 4242, process: "npm")

    func policy(threats: Bool = true, trackers: Bool = false, agentGuard: Bool = false, allowed: [String] = [], profile: NetworkProfile = .work,
                rules: [String: Bool] = [:], connectionRules: [ConnectionRule] = [], killSwitch: KillSwitchPolicy = KillSwitchPolicy()) -> FilterPolicy {
        var preferences = SavedPreferences()
        preferences.profile = profile; preferences.defaultAllow = true
        preferences.rules[profile.rawValue] = rules
        preferences.connectionRules = connectionRules
        let settings = ProtectionSettings(threats: threats, trackers: trackers, agentGuard: agentGuard, allowed: allowed)
        return FilterPolicy(FilterController.policy(preferences, budgetReached: false, killSwitch: killSwitch, protection: settings))
    }
    func flow(_ host: String?, app: String? = "com.example.App", address: String? = "203.0.113.10") -> FilterPolicy.Flow {
        .init(app: app, process: "App", host: host, address: address, port: "443")
    }

    @Test func settingsSurviveTheFilterConfiguration() {
        let settings = ProtectionSettings(threats: true, trackers: true, agentGuard: true, uploadLimit: 50_000_000, allowed: ["ok.example"], digest: "abc")
        #expect(ProtectionSettings(settings.configuration) == settings)
        #expect(ProtectionSettings(ProtectionSettings().configuration) == ProtectionSettings())
    }

    @Test func threatsWinOverAllowRulesAndUnrestricted() {
        let rule = ConnectionRule(app: "com.example.App", host: "evil.example", allowed: true, profile: NetworkProfile.work.rawValue)
        for filter in [policy(rules: ["com.example.App": true]), policy(profile: .unrestricted), policy(connectionRules: [rule])] {
            let decision = filter.decide(flow("cdn.evil.example"), index: index)
            #expect(decision.verdict == .block)
            guard case .protection(let detail) = decision.reason else { Issue.record("not Protection"); continue }
            #expect(detail.kind == .malware && detail.host == "evil.example")
        }
        #expect(policy(threats: false).decide(flow("evil.example"), index: index).verdict == .allow)
    }

    @Test func theKillSwitchComesFirst() {
        let down = KillSwitchPolicy(armed: true, vpnDown: true)
        #expect(policy(killSwitch: down).decide(flow("evil.example"), index: index).reason == .killSwitch)
    }

    @Test func allowThisSiteLocalNetworkAndAppleAreNeverBlocked() {
        #expect(policy(allowed: ["evil.example"]).decide(flow("a.evil.example"), index: index).verdict == .allow)
        let lan = FilterPolicy.Flow(app: "com.example.App", process: "App", host: nil, address: "192.168.1.20", port: "80")
        let listedLAN = ProtectionIndex(data: ProtectionIndex.build([(ProtectionIndexTests.slot(1, "t", .threat), ["192.168.1.20", "apple.com"])]))!
        #expect(policy().decide(lan, index: listedLAN).verdict == .allow)
        #expect(policy().decide(flow("printer.local", address: nil), index: index).verdict == .allow)
        #expect(policy().decide(flow("gs.apple.com"), index: listedLAN).verdict == .allow)
    }

    @Test func blocksListedAddressesWithoutANameAndFlowsWithoutAnApp() {
        let decision = policy().decide(flow(nil, app: nil, address: "198.51.100.7"), index: index)
        #expect(decision.verdict == .block)
    }

    @Test func trackersLoseToAllowRules() {
        let trackers = policy(threats: false, trackers: true)
        guard case .protection(let detail) = trackers.decide(flow("pixel.tracker.example"), index: index).reason else { Issue.record("not blocked"); return }
        #expect(detail.kind == .tracker)
        #expect(policy(threats: false, trackers: true, allowed: ["tracker.example"]).decide(flow("pixel.tracker.example"), index: index).verdict == .allow)
        #expect(policy(threats: false, trackers: true, profile: .unrestricted).decide(flow("pixel.tracker.example"), index: index).verdict == .allow)
        let rule = ConnectionRule(app: "com.example.App", host: "tracker.example", allowed: true, profile: NetworkProfile.work.rawValue)
        #expect(policy(threats: false, trackers: true, connectionRules: [rule]).decide(flow("pixel.tracker.example"), index: index).verdict == .allow)
        // Off by default.
        #expect(policy(threats: false).decide(flow("pixel.tracker.example"), index: index).verdict == .allow)
    }

    @Test func namesTheAgentBehindAThreat() {
        var asked = 0
        let decision = policy().decide(flow("evil.example"), index: index, agent: { asked += 1; return claude })
        guard case .protection(let detail) = decision.reason else { Issue.record("not blocked"); return }
        #expect(detail.agent == "Claude Code" && detail.process == "npm" && detail.agentPID == 4242)
        #expect(ProtectionText.title(detail, app: "node") == "Blocked: npm (started by Claude Code) tried to reach a known malware host")
        // Asked only when something matched.
        _ = policy().decide(flow("good.example"), index: index, agent: { asked += 1; return claude })
        #expect(asked == 1)
    }

    @Test func agentsAreKeptFromThreatsEvenWithThreatsOff() {
        let guarded = policy(threats: false, agentGuard: true)
        #expect(guarded.decide(flow("evil.example"), index: index, agent: { claude }).verdict == .block)
        #expect(guarded.decide(flow("evil.example"), index: index, agent: { nil }).verdict == .allow)
    }

    @Test func theAgentGuardsStricterRules() {
        let guarded = policy(threats: false, agentGuard: true)
        guard case .protection(let paste) = guarded.decide(flow("pastebin.com"), index: index, agent: { claude }).reason else { Issue.record("paste site not blocked"); return }
        #expect(paste.kind == .agentGuard && paste.list == "paste site")
        #expect(guarded.decide(flow("pastebin.com"), index: index, agent: { nil }).verdict == .allow)
        // Asked for by address: a public raw IP is blocked for agents, a private one never.
        #expect(guarded.decide(flow("203.0.113.9", address: "203.0.113.9"), index: index, agent: { claude }).verdict == .block)
        #expect(guarded.decide(flow("10.0.0.5", address: "10.0.0.5"), index: index, agent: { claude }).verdict == .allow)
        #expect(guarded.decide(flow("100.100.1.2", address: "100.100.1.2"), index: index, agent: { claude }).verdict == .allow)
        // No name seen isn't a raw IP.
        #expect(guarded.decide(flow(nil, address: "203.0.113.9"), index: index, agent: { claude }).verdict == .allow)
        // Without the guard, agents may use them.
        #expect(policy().decide(flow("pastebin.com"), index: index, agent: { claude }).verdict == .allow)
    }

    @Test func uploadLimitOnlyForAgentsAndNewHosts() {
        let settings = ProtectionSettings(agentGuard: true, uploadLimit: 10_000_000)
        #expect(ProtectionCheck.uploadLimit(flow("drop.example"), settings: settings, index: index, agent: { claude })?.limit == 10_000_000)
        #expect(ProtectionCheck.uploadLimit(flow("drop.example"), settings: settings, index: index, agent: { nil }) == nil)
        #expect(ProtectionCheck.uploadLimit(flow("registry.example"), settings: settings, index: index, agent: { claude }) == nil)
        #expect(ProtectionCheck.uploadLimit(flow("registry.npmjs.org"), settings: settings, index: index, agent: { claude }) == nil)
        #expect(ProtectionCheck.uploadLimit(flow("api.anthropic.com"), settings: settings, index: index, agent: { claude }) == nil)
        #expect(ProtectionCheck.uploadLimit(flow("drop.example"), settings: ProtectionSettings(), index: index, agent: { claude }) == nil)
    }
}

struct AgentLineageTests {
    /// launchd → Terminal → zsh → claude → zsh → node (npm) → curl, and a lone curl from another shell.
    static let table: [Int32: (AgentLineage.Process, String, [String])] = [
        100: (.init(ppid: 1, name: "Terminal", start: 1), "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", []),
        200: (.init(ppid: 100, name: "zsh", start: 2), "/bin/zsh", ["-zsh"]),
        300: (.init(ppid: 200, name: "2.1.3", start: 3), "/Users/me/.local/share/claude/versions/2.1.3", ["claude"]),
        400: (.init(ppid: 300, name: "zsh", start: 4), "/bin/zsh", ["/bin/zsh", "-c", "npm install"]),
        500: (.init(ppid: 400, name: "node", start: 5), "/opt/homebrew/bin/node", ["node", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js", "install"]),
        600: (.init(ppid: 500, name: "curl", start: 6), "/usr/bin/curl", ["curl", "https://malware.example"]),
        700: (.init(ppid: 200, name: "curl", start: 7), "/usr/bin/curl", ["curl", "https://example.com"]),
        800: (.init(ppid: 1, name: "Cursor", start: 8), "/Applications/Cursor.app/Contents/MacOS/Cursor", []),
        900: (.init(ppid: 800, name: "git", start: 9), "/usr/bin/git", ["git", "push"]),
    ]
    static let lookup = AgentLineage.Lookup(entry: { table[$0]?.0 }, path: { table[$0]?.1 }, arguments: { table[$0]?.2 })

    @Test func findsTheAgentThroughShells() {
        let lineage = AgentLineage(lookup: Self.lookup)
        #expect(lineage.owner(pid: 600)?.agent.id == "claude")
        #expect(lineage.owner(pid: 600)?.pid == 300)
        #expect(lineage.owner(pid: 600)?.process == "curl")
        // npm runs as node; it's named after its script.
        #expect(lineage.owner(pid: 500)?.process == "npm")
        // The agent's own connections count; a curl typed by the person doesn't.
        #expect(lineage.owner(pid: 300)?.agent.name == "Claude Code")
        #expect(lineage.owner(pid: 700) == nil)
        #expect(lineage.owner(pid: 12345) == nil)
    }

    @Test func desktopAgentsCountForWhatTheyStart() {
        let lineage = AgentLineage(lookup: Self.lookup)
        #expect(lineage.owner(pid: 900)?.agent.id == "cursor")
        #expect(lineage.owner(pid: 800) == nil)
    }
}

struct FlowSnifferTests {
    /// A TLS ClientHello with an SNI for `host` and some padding extensions.
    static func clientHello(_ host: String?) -> [UInt8] {
        var extensions: [UInt8] = [0x00, 0x15, 0x00, 0x04, 0, 0, 0, 0]   // padding first, as some clients randomise order
        if let host {
            let name = Array(host.utf8)
            let list: [UInt8] = [0] + [UInt8(name.count >> 8), UInt8(name.count & 0xFF)] + name
            extensions += [0x00, 0x00] + [UInt8((list.count + 2) >> 8), UInt8((list.count + 2) & 0xFF)] + [UInt8(list.count >> 8), UInt8(list.count & 0xFF)] + list
        }
        var body: [UInt8] = [0x03, 0x03] + [UInt8](repeating: 7, count: 32) + [0] + [0x00, 0x02, 0x13, 0x01] + [0x01, 0x00]
        body += [UInt8(extensions.count >> 8), UInt8(extensions.count & 0xFF)] + extensions
        let handshake: [UInt8] = [0x01, 0, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body
        return [0x16, 0x03, 0x01, UInt8(handshake.count >> 8), UInt8(handshake.count & 0xFF)] + handshake
    }

    @Test func readsTheServerNameFromAClientHello() {
        #expect(FlowSniffer.sniff(Self.clientHello("Malware.Example")) == .name("malware.example"))
        #expect(FlowSniffer.sniff(Self.clientHello(nil)) == .address)
        let hello = Self.clientHello("malware.example")
        #expect(FlowSniffer.sniff(Array(hello.prefix(40))) == .needMore(hello.count))
    }

    @Test func readsTheHostHeader() {
        #expect(FlowSniffer.sniff(Array("GET / HTTP/1.1\r\nHost: Tracker.Example:8080\r\nAccept: */*\r\n\r\n".utf8)) == .name("tracker.example"))
        #expect(FlowSniffer.sniff(Array("POST /x HTTP/1.1\r\nHost: 203.0.113.9\r\n\r\n".utf8)) == .address)
        #expect(FlowSniffer.sniff(Array("SSH-2.0-OpenSSH_9.6\r\n".utf8)) == .unknown)
    }
}

struct ProtectionUpdateTests {
    static let list = ProtectionList(id: "sample", name: "Sample", url: URL(string: "https://lists.example/sample.txt")!, homepage: URL(string: "https://lists.example")!,
                                     licence: "CC0-1.0", category: .threat, group: .threats, minimum: 3)

    final class Server: @unchecked Sendable {
        var responses: [(Int, String, [String: String])] = []
        var requests: [URLRequest] = []
        func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            guard !responses.isEmpty else { throw URLError(.notConnectedToInternet) }
            let (status, body, headers) = responses.removeFirst()
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
    }

    @Test func keepsTheLastGoodCopyAndUsesValidators() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = Server()
        let updater = ProtectionUpdater(directory: directory) { try await server.fetch($0) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        server.responses = [(200, "a.example\nb.example\nc.example\nd.example\n", ["ETag": "\"v1\"", "Last-Modified": "Sun, 01 Nov 2026 08:00:00 GMT"])]
        var state = await updater.update([Self.list], now: start)
        #expect(state.lists["sample"]?.entries == 4 && state.lists["sample"]?.error == nil)
        #expect(updater.build([Self.list])?.match(host: "x.a.example") != nil)

        // Within a day nothing is fetched.
        _ = await updater.update([Self.list], now: start.addingTimeInterval(3_600))
        #expect(server.requests.count == 1)

        // An HTML error page, a collapse to too few entries, and a network failure all keep the copy.
        server.responses = [(200, "<html><body>Rate limited</body></html>", [:])]
        state = await updater.update([Self.list], force: true, now: start.addingTimeInterval(90_000))
        #expect(state.lists["sample"]?.error != nil && state.lists["sample"]?.entries == 4)
        #expect(server.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
        #expect(server.requests.last?.value(forHTTPHeaderField: "If-Modified-Since") == "Sun, 01 Nov 2026 08:00:00 GMT")
        state = await updater.update([Self.list], force: true, now: start.addingTimeInterval(90_100))
        #expect(state.lists["sample"]?.error != nil)
        #expect(updater.build([Self.list])?.match(host: "b.example") != nil)

        // Not modified keeps it and clears the error.
        server.responses = [(304, "", [:])]
        state = await updater.update([Self.list], force: true, now: start.addingTimeInterval(90_200))
        #expect(state.lists["sample"]?.error == nil && state.lists["sample"]?.entries == 4)
    }

    @Test func refusesASuddenCollapse() throws {
        let big = ProtectionList(id: "big", name: "Big", url: Self.list.url, homepage: Self.list.homepage, licence: "MIT", category: .threat, group: .threats, minimum: 2)
        #expect(throws: ProtectionUpdater.Failure.self) { try ProtectionUpdater.validate(Data("a.example\nb.example\n".utf8), list: big, previous: 10) }
        #expect(try ProtectionUpdater.validate(Data("a.example\nb.example\n".utf8), list: big, previous: 4).count == 2)
    }
}

struct ProtectionNoticeTests {
    @Test func oncePerAppPerHostPerDay() {
        var limiter = ProtectionNoticeLimiter()
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let base = 1_800_000_000.0
        let morning = Date(timeIntervalSince1970: base - base.truncatingRemainder(dividingBy: 86_400) + 8 * 3_600)
        let answers = [limiter.allow(app: "com.apple.curl", host: "malware.example", now: morning, calendar: calendar),
                       limiter.allow(app: "com.apple.curl", host: "MALWARE.example", now: morning.addingTimeInterval(3_600), calendar: calendar),
                       limiter.allow(app: "node", host: "malware.example", now: morning.addingTimeInterval(3_600), calendar: calendar),
                       limiter.allow(app: "com.apple.curl", host: "phish.example", now: morning.addingTimeInterval(3_600), calendar: calendar),
                       limiter.allow(app: "com.apple.curl", host: "malware.example", now: morning.addingTimeInterval(86_400), calendar: calendar)]
        #expect(answers == [true, false, true, true, true])
    }
}

struct ProtectCommandTests {
    @Test func parsesTheCommands() throws {
        #expect(try ProtectCommand.parse(["protect"]) == .status(json: false))
        #expect(try ProtectCommand.parse(["protect", "status", "--json"]) == .status(json: true))
        #expect(try ProtectCommand.parse(["protect", "on"]) == .set(on: true, parts: [.threats], trackerList: nil))
        #expect(try ProtectCommand.parse(["protect", "off", "--agents", "--trackers"]) == .set(on: false, parts: [.trackers, .agents], trackerList: nil))
        #expect(try ProtectCommand.parse(["protect", "on", "--list", "oisd-small"]) == .set(on: true, parts: [.trackers], trackerList: "oisd-small"))
        #expect(try ProtectCommand.parse(["protect", "check", "malware.example", "--json"]) == .check(host: "malware.example", json: true))
        #expect(try ProtectCommand.parse(["protect", "allow", "*.example.com"]) == .allow("*.example.com"))
        #expect(throws: ProtectionUpdater.Failure.self) { try ProtectCommand.parse(["protect", "on", "--everything"]) }
        #expect(throws: ProtectionUpdater.Failure.self) { try ProtectCommand.parse(["protect", "on", "--list", "nope"]) }
        #expect(throws: ProtectionUpdater.Failure.self) { try ProtectCommand.parse(["protect", "check"]) }
        #expect(throws: ProtectionUpdater.Failure.self) { try ProtectCommand.parse(["protect", "allow", "not a host"]) }
    }

    @Test func appliesToPreferences() {
        var preferences = SavedPreferences()
        ProtectCommand.set(on: false, parts: [.threats], trackerList: nil).apply(to: &preferences)
        #expect(preferences.protectThreats == false && !ProtectionPreferences.threats(preferences, pro: true))
        ProtectCommand.set(on: true, parts: [.threats, .trackers, .agents], trackerList: "stevenblack").apply(to: &preferences)
        #expect(ProtectionPreferences.threats(preferences, pro: true) && preferences.protectTrackers == true && preferences.agentGuard == true && preferences.trackerList == "stevenblack")
        // Threats and the agent guard are Pro; trackers aren't.
        #expect(ProtectionPreferences.lists(preferences, pro: false).map(\.id) == ["stevenblack"])
        #expect(ProtectionPreferences.lists(preferences, pro: true).count == ProtectionLists.threats.count + 1)
        let allowed = ProtectCommand.allow("Shop.Example.").apply(to: &preferences)
        #expect(allowed && preferences.allowedSites == ["shop.example"])
        let removed = ProtectCommand.unallow("shop.example").apply(to: &preferences)
        #expect(removed && preferences.allowedSites == nil)
        let again = ProtectCommand.unallow("shop.example").apply(to: &preferences)
        #expect(!again)
    }

    @Test func checkSaysWhatAndWhy() {
        let index = ProtectionIndexTests.sample()
        let result = ProtectionCheckResult.check("https://cdn.evil.example/x", index: index, settings: ProtectionSettings(threats: true))
        #expect(result?.host == "cdn.evil.example" && result?.entry == "evil.example" && result?.listed == true && result?.wouldBlock == true)
        #expect(result?.category == "malware" && result?.lists.count == 2)
        #expect(ProtectionCheckResult.check("good.example", index: index, settings: ProtectionSettings(threats: true))?.listed == false)
        #expect(ProtectionCheckResult.check("tracker.example", index: index, settings: ProtectionSettings(threats: true))?.wouldBlock == false)
        #expect(ProtectionCheckResult.check("evil.example", index: index, settings: ProtectionSettings(threats: true, allowed: ["evil.example"]))?.wouldBlock == false)
        #expect(ProtectionCheckResult.check("not a host", index: index, settings: ProtectionSettings()) == nil)
    }
}

@MainActor struct ProtectionAgentLogTests {
    @Test func marksBlockedRowsInTheAgentsSession() {
        let tree = AgentProcessTree(source: ProcessSource(all: { [4242] }, entry: { $0 == 4242 ? ProcessEntry(pid: 4242, ppid: 1, name: "claude", start: Date(timeIntervalSince1970: 1)) : nil },
                                                           children: { _ in [] }, path: { _ in "/usr/local/bin/claude" }, arguments: { _ in ["claude"] }, cwd: { _ in "/tmp/app" }))
        let log = AgentNetworkLogStore(tree: tree)
        log.consume(TrafficSnapshot(timestamp: Date(timeIntervalSince1970: 100), processes: []))
        let detail = ProtectionDetail(kind: .malware, list: "URLhaus", host: "malware.example", agent: "Claude Code", agentPID: 4242, process: "curl")
        #expect(log.recordBlocked(FilterEvent(date: Date(timeIntervalSince1970: 101), app: "com.apple.curl", endpoint: "malware.example:443", direction: "outgoing",
                                              reason: detail.summary, protection: detail)))
        let host = log.report.first?.hosts.first
        #expect(host?.host == "malware.example" && host?.flags.first == .blocked && host?.blocked == "malware" && host?.notes.hasPrefix("Blocked: URLhaus") == true)
        #expect(!log.knownHosts.contains("malware.example"))
        // Another agent's pid, or none, isn't recorded.
        #expect(!log.recordBlocked(FilterEvent(app: "x", endpoint: "y", direction: "outgoing", reason: "r",
                                               protection: ProtectionDetail(kind: .malware, list: "l", host: "h.example", agentPID: 1))))
    }
}
