import Foundation
import Testing
@testable import KilobatCore

/// The session connection log in the filter and the rule-hit counts behind the Rules list's Used column.
@Suite struct ConnectionLogTests {
    private func decode(_ data: Data) throws -> ConnectionLogSnapshot {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ConnectionLogSnapshot.self, from: data)
    }
    private func record(_ log: ConnectionLogRecorder, app: String = "com.example.app", host: String = "api.example.com", verdict: String = "allow", uptime: TimeInterval, reason: @escaping () -> String = { "App allow rule" }) {
        log.record(uid: 501, app: app, process: "app", host: host, address: "203.0.113.5", port: "443", transport: "tcp", direction: "outgoing",
                   verdict: verdict, reason: reason, uptime: uptime)
    }

    @Test func nothingIsKeptUntilTheAppAsks() throws {
        let log = ConnectionLogRecorder()
        var worded = 0
        record(log, uptime: 100) { worded += 1; return "x" }
        #expect(worded == 0)
        let first = try decode(log.snapshot(uid: 501, record: true, browsers: false, uptime: 100))
        #expect(first.entries.isEmpty && first.since != nil)
        record(log, uptime: 101); record(log, uptime: 102); record(log, verdict: "block", uptime: 103)
        let second = try decode(log.snapshot(uid: 501, record: true, browsers: false, uptime: 104))
        #expect(second.entries.count == 2)
        #expect(second.entries.first { $0.verdict == "allow" }?.count == 2)
        #expect(try decode(log.snapshot(uid: 502, record: true, browsers: false, uptime: 104)).entries.isEmpty)
    }

    @Test func aMinuteWithoutAskingForgetsIt() throws {
        let log = ConnectionLogRecorder()
        _ = log.snapshot(uid: 501, record: true, browsers: false, uptime: 100)
        record(log, uptime: 101)
        record(log, uptime: 200)   // more than a minute later: stops and empties
        #expect(try decode(log.snapshot(uid: 501, record: true, browsers: false, uptime: 201)).entries.isEmpty)
    }

    @Test func pausingStopsAndEmpties() throws {
        let log = ConnectionLogRecorder()
        _ = log.snapshot(uid: 501, record: true, browsers: false, uptime: 100)
        record(log, uptime: 101)
        #expect(try decode(log.snapshot(uid: 501, record: false, browsers: false, uptime: 102)).entries.isEmpty)
        record(log, uptime: 103)
        #expect(try decode(log.snapshot(uid: 501, record: true, browsers: false, uptime: 104)).entries.isEmpty)
    }

    @Test func browsersOnlyWhenAskedFor() throws {
        let log = ConnectionLogRecorder()
        _ = log.snapshot(uid: 501, record: true, browsers: false, uptime: 100)
        record(log, app: "com.google.Chrome", host: "private.example", uptime: 101)
        #expect(try decode(log.snapshot(uid: 501, record: true, browsers: true, uptime: 102)).entries.isEmpty)
        record(log, app: "com.google.Chrome", host: "private.example", uptime: 103)
        #expect(try decode(log.snapshot(uid: 501, record: true, browsers: true, uptime: 104)).entries.count == 1)
        // Turning browsers off again drops their rows at once.
        #expect(try decode(log.snapshot(uid: 501, record: true, browsers: false, uptime: 105)).entries.isEmpty)
    }

    @Test func itStaysBounded() throws {
        let log = ConnectionLogRecorder()
        _ = log.snapshot(uid: 501, record: true, browsers: false, uptime: 100)
        for index in 0..<(ConnectionLogRecorder.capacity + 50) { record(log, host: "h\(index).example", uptime: 101) }
        #expect(try decode(log.snapshot(uid: 501, record: true, browsers: false, uptime: 102)).entries.count == ConnectionLogRecorder.capacity)
    }

    @Test func hitsAreCountedAlwaysAndHandedOverOnce() throws {
        let log = ConnectionLogRecorder()
        log.hit("app:Work|com.example.app", uid: 501); log.hit("app:Work|com.example.app", uid: 501); log.hit("blocked:ads.example", uid: 0)
        let first = try decode(log.snapshot(uid: 501, record: false, browsers: false))
        #expect(first.hits == ["app:Work|com.example.app": 2, "blocked:ads.example": 1])
        #expect(try decode(log.snapshot(uid: 501, record: false, browsers: false)).hits.isEmpty)
    }

    @Test func eachDecisionNamesItsRule() {
        var policy = FilterPolicy(); policy.profile = "Work"
        policy.rules = ["process:curl": false, "team:AB12CD34EF": true]
        let curl = FilterPolicy.Flow(app: "com.apple.curl", process: "curl", host: "x.example")
        #expect(policy.ruleHitKey(curl, reason: .appRule(false)) == "app:Work|process:curl")
        let rule = ConnectionRule(app: "a.b", host: "x.example", allowed: true, profile: "Work")
        #expect(policy.ruleHitKey(curl, reason: .connectionRule(rule)) == "destination:" + rule.id.uuidString)
        #expect(policy.ruleHitKey(curl, reason: .teamRule(team: "AB12CD34EF", allowed: true)) == "app:Work|team:AB12CD34EF")
        #expect(policy.ruleHitKey(curl, reason: .blocklist("ads.example")) == "blocked:ads.example")
        #expect(policy.ruleHitKey(curl, reason: .newAppDefault(true)) == nil)
    }

    @Test @MainActor func theRulesListReadsTodaysCounts() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kb-hits-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = RuleHitStore(file: file)
        let morning = Date(timeIntervalSince1970: 1_800_000_000)
        store.add(["app:Work|com.example.app": 3], now: morning)
        store.add(["app:Work|com.example.app": 2], now: morning.addingTimeInterval(600))
        #expect(store.today("app:Work|com.example.app", now: morning.addingTimeInterval(700)) == 5)
        #expect(store.today("app:Work|com.example.app", now: morning.addingTimeInterval(2 * 86_400)) == 0)
        store.add(["app:Work|com.example.app": 1], now: morning.addingTimeInterval(2 * 86_400))
        #expect(store.counts["app:Work|com.example.app"]?.total == 6)
        store.save(now: morning.addingTimeInterval(2 * 86_400))
        #expect(RuleHitStore.load(file: file)["app:Work|com.example.app"]?.today == 1)
        let listed = ListedRule(origin: .app(profile: "Work", key: "com.example.app"), allowed: true, app: "com.example.app", host: nil, profile: "Work")
        #expect(RuleHitStore.key(listed) == "app:Work|com.example.app")
    }

    @Test @MainActor func theAppKeepsOnlyTheLastHour() {
        let store = ConnectionLogStore()
        let now = Date()
        store.take(ConnectionLogSnapshot(entries: [
            ConnectionLogEntry(app: "a.b", process: "b", destination: "new.example", port: "443", transport: "tcp", direction: "outgoing", verdict: "allow", reason: "x", last: now),
            ConnectionLogEntry(app: "a.b", process: "b", destination: "old.example", port: "443", transport: "tcp", direction: "outgoing", verdict: "allow", reason: "x", last: now.addingTimeInterval(-4_000))]), now: now)
        #expect(store.entries.map(\.destination) == ["new.example"])
        store.clear()
        #expect(store.entries.isEmpty)
    }
}
