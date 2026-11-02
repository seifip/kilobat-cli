import Foundation
import Testing
@testable import KilobatCore

/// Clear and "Forget this site" across Blocked attempts, the agent network log, agent runs and Protection's notices.
struct HostMatchTests {
    @Test func readsWhatPeopleType() {
        #expect(HostMatch("Example.COM.")?.host == "example.com")
        #expect(HostMatch("https://www.example.com/path?q=1")?.host == "www.example.com")
        #expect(HostMatch("example.com:443")?.host == "example.com")
        #expect(HostMatch("[2001:db8::1]:443")?.host == "2001:db8::1")
        #expect(HostMatch("203.0.113.4")?.host == "203.0.113.4")
        #expect(HostMatch("not a host") == nil)
        #expect(HostMatch("https://") == nil)
        #expect(HostMatch("file:///tmp/example") == nil)
        #expect(HostMatch("") == nil)
        #expect(HostMatch("203.0.113.4", subdomains: true)?.subdomains == false, "an address has no subdomains")
    }

    @Test func matchesEndpointsAndSubdomainsOnlyWhenAsked() throws {
        let exact = try #require(HostMatch("example.com"))
        let wide = try #require(HostMatch("example.com", subdomains: true))
        for candidate in ["example.com", "EXAMPLE.com:443", "example.com."] { #expect(exact.matches(candidate), "\(candidate)") }
        #expect(!exact.matches("www.example.com:443"))
        #expect(wide.matches("www.example.com:443") && wide.matches("a.b.example.com") && wide.matches("example.com"))
        #expect(!wide.matches("notexample.com") && !wide.matches("example.com.evil.test") && !wide.matches(nil) && !wide.matches("Unknown endpoint"))
        let v6 = try #require(HostMatch("2001:db8::1"))
        #expect(v6.matches("[2001:db8::1]:443") && v6.matches("2001:db8::1.443") && v6.matches("2001:db8::1"))
        let v4 = try #require(HostMatch("203.0.113.4"))
        #expect(v4.matches("203.0.113.4:443") && !v4.matches("203.0.113.40:443"))
    }

    @Test func rangesEndNow() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000 + 5_000)
        #expect(HistoryRange.hour.cutoff(now: now, calendar: calendar) == now - 3_600)
        #expect(HistoryRange.today.cutoff(now: now, calendar: calendar) == calendar.startOfDay(for: now))
        #expect(HistoryRange.all.cutoff(now: now, calendar: calendar) == nil)
    }
}

struct HistoryEraserTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    var events: [FilterEvent] {
        [FilterEvent(date: now - 60, app: "com.apple.curl", endpoint: "paste.example:443", direction: "outgoing", reason: "Blocklist: paste.example"),
         FilterEvent(date: now - 7_200, app: "node", endpoint: "203.0.113.66:443", direction: "outgoing", reason: "",
                     protection: ProtectionDetail(kind: .malware, list: "URLhaus", host: "cdn.malware.example")),
         FilterEvent(date: now - 3 * 86_400, app: "com.example.Game", endpoint: "updates.game.example:443", direction: "outgoing", reason: "App block rule")]
    }

    @Test func blockedAttemptsByEndpointOrTheHostProtectionMatched() throws {
        var list = events
        #expect(HistoryEraser.apply(.forget(try #require(HostMatch("malware.example", subdomains: true))), to: &list, now: now).count == 1)
        #expect(list.map(\.endpoint) == ["paste.example:443", "updates.game.example:443"])
        #expect(HistoryEraser.apply(.forget(try #require(HostMatch("game.example"))), to: &list, now: now).isEmpty, "without subdomains only the host itself")
        list = events
        #expect(HistoryEraser.apply(.clear(.hour), to: &list, now: now).count == 1)
        #expect(list.count == 2)
        #expect(HistoryEraser.apply(.clear(.all), to: &list, now: now).count == 2 && list.isEmpty)
    }

    @Test func forgetsHostNamesKeptInTheRuleReason() throws {
        var list = [FilterEvent(date: now, app: "curl", endpoint: "203.0.113.4:443", direction: "outgoing", reason: "Blocklist: secret.example"),
                    FilterEvent(date: now, app: "curl", endpoint: "203.0.113.5:443", direction: "outgoing", reason: "Destination rule: *.secret.example:443 · outgoing"),
                    FilterEvent(date: now, app: "curl", endpoint: "203.0.113.6:443", direction: "outgoing", reason: "Blocklist: keep.example")]
        #expect(HistoryEraser.apply(.forget(try #require(HostMatch("secret.example"))), to: &list, now: now).count == 2)
        #expect(list.map(\.reason) == ["Blocklist: keep.example"])
    }

    func session(_ key: String, ended: Bool, hosts: [AgentHostRecord]) -> AgentNetworkSession {
        var session = AgentNetworkSession(key: key, agent: AgentIdentity(id: "claude", name: "Claude Code"), pid: 1, start: now - 10_000)
        session.end = ended ? now - 100 : nil
        session.hosts = hosts
        return session
    }
    func record(_ host: String?, _ address: String, last: TimeInterval) -> AgentHostRecord {
        AgentHostRecord(process: "curl", address: address, port: "443", transport: "TCP", host: host, nameSource: host == nil ? nil : "filter",
                        first: now - last - 10, last: now - last, sent: 10, received: 10, connections: 1)
    }

    @Test func agentLogForgetsNamesAddressesAndRememberedHosts() throws {
        var sessions = [session("a", ended: true, hosts: [record("api.example.com", "192.0.2.1", last: 50)]),
                        session("b", ended: false, hosts: [record("example.com", "192.0.2.2", last: 50), record(nil, "198.51.100.7", last: 50), record("other.test", "192.0.2.3", last: 5_000)])]
        var past: Set<String> = ["example.com", "old.example.com", "keep.test"]
        let removed = HistoryEraser.apply(.forget(try #require(HostMatch("example.com", subdomains: true))), to: &sessions, pastHosts: &past, now: now)
        #expect(removed == 2 + 2)
        #expect(sessions.map(\.key) == ["b"], "an ended session with nothing left goes; a running one stays")
        #expect(sessions[0].hosts.map(\.address) == ["198.51.100.7", "192.0.2.3"])
        #expect(past == ["keep.test"])
        #expect(HistoryEraser.apply(.forget(try #require(HostMatch("198.51.100.7"))), to: &sessions, pastHosts: &past, now: now) == 1)
    }

    @Test func agentLogClearsByWhenAHostWasLastSeen() {
        var sessions = [session("a", ended: true, hosts: [record("recent.test", "192.0.2.1", last: 60), record("older.test", "192.0.2.2", last: 7_200)])]
        var past: Set<String> = ["kept.test"]
        #expect(HistoryEraser.apply(.clear(.hour), to: &sessions, pastHosts: &past, now: now) == 1)
        #expect(sessions[0].hosts.map(\.host) == ["older.test"] && past == ["kept.test"])
        #expect(HistoryEraser.apply(.clear(.all), to: &sessions, pastHosts: &past, now: now) == 2)
        #expect(sessions.isEmpty && past.isEmpty)
    }

    @Test func runsLoseDestinationsBySiteOrPeriod() throws {
        var old = WorkSession(kind: .agent, title: "Codex", start: now - 3 * 86_400, lastActive: now - 3 * 86_400)
        old.end = now - 3 * 86_400 + 600; old.destinations = ["api.example.com:443", "pypi.org:443"]
        var recent = WorkSession(kind: .agent, title: "Claude Code", start: now - 1_800, lastActive: now - 60)
        recent.destinations = ["example.com:443", "registry.npmjs.org:443"]
        var sessions = [old, recent]
        #expect(HistoryEraser.apply(.forget(try #require(HostMatch("example.com", subdomains: true))), to: &sessions, now: now) == 2)
        #expect(sessions[0].destinations == ["pypi.org:443"] && sessions[1].destinations == ["registry.npmjs.org:443"])
        #expect(HistoryEraser.apply(.clear(.hour), to: &sessions, now: now) == 1, "only the session still running in the last hour")
        #expect(sessions[0].destinations == ["pypi.org:443"] && sessions[1].destinations.isEmpty)
        #expect(sessions.count == 2, "the sessions themselves stay")
    }

    @Test func noticeMemoryBySiteOrPeriod() throws {
        var limiter = ProtectionNoticeLimiter()
        limiter.sent = ["npm|malware.example": now - 60, "chrome|login.phish.example": now - 7_200, "curl|paste.example": now - 30]
        #expect(HistoryEraser.apply(.forget(try #require(HostMatch("phish.example", subdomains: true))), to: &limiter, now: now) == 1)
        #expect(Set(limiter.sent.keys) == ["npm|malware.example", "curl|paste.example"])
        #expect(HistoryEraser.apply(.clear(.hour), to: &limiter, now: now) == 2 && limiter.sent.isEmpty)
    }
}

@MainActor struct HostHistoryStoreTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func forgottenBlocksDontComeBackFromTheFilter() throws {
        let folder = try directory()
        let file = folder.appendingPathComponent("filter-events.json")
        let journal = FilterEventJournal(file: file)
        let blocked = [FilterEvent(date: now - 60, app: "node", endpoint: "paste.example:443", direction: "outgoing", reason: "Blocklist: paste.example"),
                       FilterEvent(date: now - 30, app: "node", endpoint: "keep.test:443", direction: "outgoing", reason: "App block rule")]
        // An old, more permissive journal is replaced with private metadata.
        try JSONEncoder().encode(blocked).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try journal.ingest(blocked, now: now)
        #expect(try journal.erase(.forget(try #require(HostMatch("paste.example"))), now: now) == 1)
        // The filter keeps its latest blocks in memory and sends them again on every read.
        try journal.ingest(blocked, now: now + 5)
        #expect(journal.events.map(\.endpoint) == ["keep.test:443"])
        let reopened = FilterEventJournal(file: file)
        try reopened.ingest(blocked, now: now + 10)
        #expect(reopened.events.map(\.endpoint) == ["keep.test:443"], "the removed ids survive a restart")
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("filter-events-removed.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let journalAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((journalAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try reopened.erase(.clear(.all), now: now + 20) == 1 && reopened.events.isEmpty)
    }

    @Test func liveStoresForgetAndSave() throws {
        let folder = try directory()
        let log = AgentNetworkLogStore(directory: folder)
        let sessions = SessionStore(directory: folder, defaults: UserDefaults(suiteName: "kilobat-test-" + UUID().uuidString)!)
        #expect(try log.erase(.forget(try #require(HostMatch("example.com"))), now: now) == 0)
        #expect(try sessions.erase(.clear(.all), now: now) == 0)
        let protection = UserDefaults(suiteName: "kilobat-test-" + UUID().uuidString)!
        var limiter = ProtectionNoticeLimiter(); limiter.sent = ["npm|malware.example": now - 60]
        protection.set(try JSONEncoder().encode(limiter), forKey: "protection.notices")
        #expect(try ProtectionStore.erase(.forget(try #require(HostMatch("malware.example"))), defaults: protection, now: now) == 1)
        let saved = try JSONDecoder().decode(ProtectionNoticeLimiter.self, from: try #require(protection.data(forKey: "protection.notices")))
        #expect(saved.sent.isEmpty)
    }

    @Test func failedErasureIsNotReportedAsSuccess() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let blocked = folder.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: blocked)
        let log = AgentNetworkLogStore(directory: blocked)
        let sessions = SessionStore(directory: blocked, defaults: UserDefaults(suiteName: "kilobat-test-" + UUID().uuidString)!)
        #expect(throws: (any Error).self) { try log.erase(.clear(.all), now: now) }
        #expect(throws: (any Error).self) { try sessions.erase(.clear(.all), now: now) }
        for (filename, kind) in [("sessions.json", HostHistoryKind.sessions), ("agent-network-log.json", .agentLog), ("filter-events.json", .blockedAttempts)] {
            let file = folder.appendingPathComponent(filename)
            try Data("corrupt fixture".utf8).write(to: file)
            #expect(throws: (any Error).self) {
                try HostHistoryFiles.erase(.clear(.all), kinds: [kind], directory: folder, appDefaults: nil, now: now)
            }
            #expect(try Data(contentsOf: file) == Data("corrupt fixture".utf8), "unreadable histories must be preserved for recovery")
        }
        let defaults = UserDefaults(suiteName: "kilobat-test-" + UUID().uuidString)!
        defaults.set(Data("corrupt fixture".utf8), forKey: "protection.notices")
        #expect(throws: (any Error).self) { try ProtectionStore.erase(.clear(.all), defaults: defaults, now: now) }
    }

    /// The command line's path while the app isn't running: every file changes, and nothing outside the site.
    @Test func filesForgetASiteEverywhere() throws {
        let folder = try directory()
        try JSONEncoder().encode([FilterEvent(date: now - 60, app: "curl", endpoint: "www.example.com:443", direction: "outgoing", reason: "Blocklist: example.com"),
                                  FilterEvent(date: now - 60, app: "curl", endpoint: "keep.test:443", direction: "outgoing", reason: "App block rule")])
            .write(to: folder.appendingPathComponent("filter-events.json"))
        var agent = AgentNetworkSession(key: "1@1", agent: AgentIdentity(id: "claude", name: "Claude Code"), pid: 1, start: now - 600)
        agent.end = now - 60
        agent.hosts = [AgentHostRecord(process: "curl", address: "192.0.2.1", port: "443", transport: "TCP", host: "example.com", nameSource: "filter", first: now - 300, last: now - 200),
                       AgentHostRecord(process: "curl", address: "192.0.2.2", port: "443", transport: "TCP", host: "keep.test", nameSource: "filter", first: now - 300, last: now - 200)]
        try AgentLogFile(recording: true, updated: now, sessions: [agent], pastHosts: ["cdn.example.com", "keep.test"]).data()
            .write(to: folder.appendingPathComponent("agent-network-log.json"))
        var run = WorkSession(kind: .agent, title: "Claude Code", start: now - 600, lastActive: now - 60)
        run.end = now - 60; run.destinations = ["example.com:443", "keep.test:443"]
        try JSONEncoder().encode([run]).write(to: folder.appendingPathComponent("sessions.json"))
        let defaults = UserDefaults(suiteName: "kilobat-test-" + UUID().uuidString)!
        var limiter = ProtectionNoticeLimiter(); limiter.sent = ["curl|example.com": now - 60, "curl|keep.test": now - 60]
        defaults.set(try JSONEncoder().encode(limiter), forKey: "protection.notices")

        let change = try HostHistoryFiles.erase(.forget(try #require(HostMatch("example.com", subdomains: true))), directory: folder, appDefaults: defaults, now: now)
        #expect(change.blockedAttempts == 1 && change.agentLogHosts == 2 && change.sessionDestinations == 1 && change.notices == 1 && change.total == 5)
        #expect(FilterEventJournal(file: folder.appendingPathComponent("filter-events.json")).events.map(\.endpoint) == ["keep.test:443"])
        let log = try #require(AgentLogFile.load(folder.appendingPathComponent("agent-network-log.json")))
        #expect(log.sessions.first?.hosts.map(\.host) == ["keep.test"] && log.pastHosts == ["keep.test"])
        let runs = try JSONDecoder().decode([WorkSession].self, from: Data(contentsOf: folder.appendingPathComponent("sessions.json")))
        #expect(runs.first?.destinations == ["keep.test:443"])
        let remaining = try JSONDecoder().decode(ProtectionNoticeLimiter.self, from: try #require(defaults.data(forKey: "protection.notices")))
        #expect(Array(remaining.sent.keys) == ["curl|keep.test"])
        // Nothing left to forget the second time, and missing files are fine.
        #expect(try HostHistoryFiles.erase(.forget(try #require(HostMatch("example.com", subdomains: true))), directory: folder, appDefaults: defaults, now: now).total == 0)
        #expect(try HostHistoryFiles.erase(.clear(.all), directory: try directory(), appDefaults: nil, now: now).total == 0)
    }
}

struct HistoryCommandTests {
    @Test func parsesForgetAndClear() throws {
        #expect(try HistoryCommand.parse(["forget", "example.com"]) == .forget(try #require(HostMatch("example.com")), json: false))
        #expect(try HistoryCommand.parse(["forget", "https://www.example.com/x", "--subdomains", "--json"]) == .forget(try #require(HostMatch("www.example.com", subdomains: true)), json: true))
        #expect(try HistoryCommand.parse(["clear", "--today"]) == .clear(.today, json: false))
        #expect(try HistoryCommand.parse(["clear", "--all", "--json"]) == .clear(.all, json: true))
        for args in [[], ["clear"], ["clear", "--hour", "--all"], ["clear", "--week"], ["forget"], ["forget", "not a host"], ["forget", "a.test", "b.test"], ["wipe"]] {
            #expect(throws: HistoryCommand.Failure.self, "\(args)") { try HistoryCommand.parse(args) }
        }
    }

    @Test func travelsToTheAppAndBack() throws {
        for command in [HistoryCommand.clear(.hour, json: false), .forget(try #require(HostMatch("example.com", subdomains: true)), json: false),
                        .forget(try #require(HostMatch("203.0.113.4")), json: true)] {
            #expect(HistoryCommand.fromRelay(command.relayAction) == command.action)
        }
        #expect(HistoryCommand.fromRelay("history|clear|week") == nil)
        #expect(HistoryCommand.fromRelay("history|forget|1|not a host") == nil)
        #expect(HistoryCommand.fromRelay("history|forget|yes|example.com") == nil)
        #expect(AppRelay.known("history|forget|0|example.com"))
    }
}
