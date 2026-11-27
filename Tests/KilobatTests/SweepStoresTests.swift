import Foundation
import Testing
import Observation
@testable import KilobatCore

/// Turning "while plugged in" off lasts until the Mac restarts, counted from the real boot time, not from time awake.
@MainActor struct SweepAwakeOffTests {
    @Test func aTurnOffFromThisBootSurvivesSleepSinceThen() {
        let suite = "co.seifi.kilobat.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "awake.power")
        defaults.set(Date() - 3_600, forKey: "awake.powerOff")
        let now = Date().timeIntervalSince1970
        #expect(SessionStore(defaults: defaults, bootTime: now - 7_200).powerSuppressed)
        #expect(!SessionStore(defaults: defaults, bootTime: now - 60).powerSuppressed)
    }
}

/// A protection list that couldn't be reached is asked again within the hour, not the next day.
struct SweepProtectionRetryTests {
    @Test func aListThatCouldNotBeReachedIsTriedAgainSoon() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = ProtectionUpdateTests.Server()
        let updater = ProtectionUpdater(directory: directory) { try await server.fetch($0) }
        let list = ProtectionUpdateTests.list
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        server.responses = [(200, "a.example\nb.example\nc.example\nd.example\n", ["ETag": "\"v1\""])]
        _ = await updater.update([list], now: start)
        server.responses = []
        var state = await updater.update([list], now: start + 86_400)
        #expect(state.lists["sample"]?.error != nil && server.requests.count == 2)
        // Not straight away,
        _ = await updater.update([list], now: start + 86_400 + 600)
        #expect(server.requests.count == 2)
        // but within the hour.
        server.responses = [(304, "", [:])]
        state = await updater.update([list], now: start + 86_400 + 3_600)
        #expect(server.requests.count == 3 && state.lists["sample"]?.error == nil)
        // Back to the daily rhythm once it went through.
        _ = await updater.update([list], now: start + 86_400 + 7_200)
        #expect(server.requests.count == 3)
    }

    @Test func aDownloadThatFailedItsCheckWaitsForTheNextDay() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = ProtectionUpdateTests.Server()
        let updater = ProtectionUpdater(directory: directory) { try await server.fetch($0) }
        let list = ProtectionUpdateTests.list
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        server.responses = [(200, "a.example\nb.example\nc.example\nd.example\n", [:])]
        _ = await updater.update([list], now: start)
        server.responses = [(200, "<html><body>Rate limited</body></html>", [:])]
        let state = await updater.update([list], now: start + 86_400)
        #expect(state.lists["sample"]?.error != nil)
        _ = await updater.update([list], now: start + 86_400 + 3_600)
        #expect(server.requests.count == 2)
    }
}

/// The agent log: how often it is saved, which hosts it keeps resolving, and the report kept between renders.
@MainActor struct SweepAgentLogTests {
    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var hosts: [String] = []
        func note(_ host: String) { lock.withLock { hosts.append(host) } }
        var all: [String] { lock.withLock { hosts } }
    }

    private func connection(_ remote: String, local: Int = 50_000, received: UInt64, sent: UInt64) -> ConnectionTraffic {
        ConnectionTraffic(id: "tcp4 192.168.1.20:\(local)<->\(remote):443", route: .internet, interface: "en0", received: received, sent: sent)
    }
    private func process(_ pid: Int32, _ name: String, _ connections: [ConnectionTraffic]) -> ProcessTraffic {
        ProcessTraffic(pid: pid, process: name, received: connections.reduce(0) { $0 + $1.received }, sent: connections.reduce(0) { $0 + $1.sent }, connections: connections)
    }
    private func table() -> FakeTable {
        let table = FakeTable()
        table.add(60, parent: 1, "zsh", path: "/bin/zsh", startedAt: -100)
        table.add(100, parent: 60, "claude", path: "/opt/homebrew/bin/claude", startedAt: -50, cwd: "/Users/me/GitHub/shop")
        table.add(101, parent: 100, "zsh", path: "/bin/zsh", startedAt: -40)
        table.add(102, parent: 101, "npm", path: "/opt/homebrew/bin/npm", startedAt: -30)
        table.add(103, parent: 101, "curl", path: "/usr/bin/curl", arguments: ["curl", "-sL", "https://docs.example/guide"], startedAt: -20)
        return table
    }

    @Test func onlyByteCountsWaitAMinuteToBeSaved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-agentlog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let table = table()
        let store = AgentNetworkLogStore(directory: directory, tree: AgentProcessTree(source: table.source), lookup: HostLookup(forward: { _ in [] }, reverse: { _ in nil }))
        store.filterNames = { ["104.16.5.34": "registry.npmjs.org", "104.16.6.34": "registry.npmjs.org"] }
        let url = directory.appendingPathComponent("agent-network-log.json"), t0 = table.origin
        func sample(_ at: Double, _ received: UInt64, second: Bool = false) {
            var connections = [connection("104.16.5.34", received: received, sent: 100)]
            if second { connections.append(connection("104.16.6.34", local: 50_001, received: 10, sent: 10)) }
            store.consume(TrafficSnapshot(timestamp: t0 + at, processes: [process(102, "npm", connections)]))
            store.waitForWrites()
        }
        sample(0, 1_000); sample(1, 2_000)
        let first = try Data(contentsOf: url)
        #expect(AgentLogFile.load(url)?.sessions.first?.hosts.count == 1)
        sample(11, 3_000); sample(21, 4_000)
        #expect(try Data(contentsOf: url) == first)
        // A new host is saved within the ten seconds,
        sample(22, 5_000, second: true); sample(33, 6_000, second: true)
        let second = try Data(contentsOf: url)
        #expect(second != first && AgentLogFile.load(url)?.sessions.first?.hosts.count == 2)
        // and the byte counts once a minute.
        sample(100, 7_000, second: true)
        #expect(try Data(contentsOf: url) != second)
    }

    /// Lets the store's resolve pass finish: it runs in a task on the main actor.
    private func settle() async throws {
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)) }
    }

    private func store(_ asked: Asked) -> (FakeTable, AgentNetworkLogStore) {
        let table = table()
        let store = AgentNetworkLogStore(tree: AgentProcessTree(source: table.source),
                                         lookup: HostLookup(forward: { host in asked.note(host); return [] }, reverse: { _ in nil }))
        return (table, store)
    }
    /// The curl names docs.example and connects to an address nothing names, so every resolve pass runs.
    private func curl(_ store: AgentNetworkLogStore, at seconds: Double, origin: Date, sent: UInt64) {
        store.consume(TrafficSnapshot(timestamp: origin + seconds, processes: [process(103, "curl", [connection("192.0.2.50", received: 10, sent: sent)])]))
    }

    @Test func aCommandsHostIsResolvedForAnHourOnly() async throws {
        let asked = Asked()
        let (table, store) = store(asked)
        curl(store, at: 0, origin: table.origin, sent: 100)
        curl(store, at: 1, origin: table.origin, sent: 200)
        try await settle()
        #expect(asked.all.contains("docs.example"))
        let before = asked.all.count
        curl(store, at: 1 + 3_600 + 700, origin: table.origin, sent: 300)
        try await settle()
        let later = Array(asked.all.dropFirst(before))
        #expect(!later.isEmpty && !later.contains("docs.example"))
    }

    @Test func aForgottenHostIsNoLongerResolved() async throws {
        let asked = Asked()
        let (table, store) = store(asked)
        curl(store, at: 0, origin: table.origin, sent: 100)
        curl(store, at: 1, origin: table.origin, sent: 200)
        try await settle()
        #expect(asked.all.contains("docs.example"))
        try store.erase(.forget(try #require(HostMatch("docs.example"))), now: table.origin + 2)
        let before = asked.all.count
        curl(store, at: 700, origin: table.origin, sent: 300)
        try await settle()
        let later = Array(asked.all.dropFirst(before))
        #expect(!later.isEmpty && !later.contains("docs.example"))
    }

    private func record(_ host: String, address: String, at date: Date, sent: UInt64 = 1_000) -> AgentHostRecord {
        AgentHostRecord(process: "node", address: address, port: "443", transport: "TCP", host: host, nameSource: "filter", first: date, last: date, sent: sent, received: 10, connections: 1)
    }

    @Test func theKeptReportMatchesOneBuiltFromScratch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-agentlog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Whole seconds, as the file keeps them.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        func session(_ key: String, daysAgo: Double, _ hosts: [(String, String)]) -> AgentNetworkSession {
            var session = AgentNetworkSession(key: key, agent: AgentIdentity(id: "codex", name: "Codex"), pid: 1, start: now - daysAgo * 86_400)
            session.end = session.start + 600
            session.hosts = hosts.map { record($0.0, address: $0.1, at: session.start) }
            return session
        }
        let sessions = [session("1@1", daysAgo: 29.99, [("old.example", "203.0.113.1")]),
                        session("2@2", daysAgo: 5, [("shared.example", "203.0.113.2"), ("old.example", "203.0.113.1")]),
                        session("3@3", daysAgo: 4, [("shared.example", "203.0.113.2"), ("new.example", "203.0.113.3")]),
                        session("4@4", daysAgo: 3, [("new.example", "203.0.113.3")])]
        try AgentLogFile(recording: true, updated: now, sessions: sessions).data().write(to: directory.appendingPathComponent("agent-network-log.json"))
        let store = AgentNetworkLogStore(directory: directory, tree: AgentProcessTree(source: FakeTable().source))
        func check(_ comment: Comment) {
            let fresh = AgentNetworkLog.report(store.sessions, pastHosts: store.pastHosts, running: [])
            #expect(store.report == fresh, comment)
            #expect(store.report == fresh, comment)
        }
        check("as loaded")
        #expect(store.report.first { $0.start == sessions[1].start }?.hosts.first { $0.host == "shared.example" }?.flags.contains(.newHost) == true)
        // The oldest session passes the 30 days: its host is remembered, and the next session no longer calls it new.
        store.consume(TrafficSnapshot(timestamp: now + 3_600, processes: []))
        #expect(store.pastHosts.contains("old.example"))
        check("after the oldest went")
        // Forgetting a host takes it out of every session.
        try store.erase(.forget(try #require(HostMatch("shared.example"))), now: now)
        check("after forgetting a host")
        #expect(store.report.first { $0.start == sessions[2].start }?.hosts.contains { $0.host == "shared.example" } == false)
        store.clear()
        check("after clearing")
    }
}

/// Reverse names for Service speed keep coming once 4,000 addresses have been looked up.
@MainActor struct SweepServiceSpeedTests {
    actor Counter {
        var asked: Set<String> = []
        func note(_ address: String) { asked.insert(address) }
        var count: Int { asked.count }
        func has(_ address: String) -> Bool { asked.contains(address) }
    }

    @Test func reverseLookupsGoOnPastTheCap() async throws {
        let counter = Counter()
        let watch = ServiceSpeedWatch(directory: nil)
        watch.lookup = HostLookup(forward: { _ in [] }, reverse: { address in await counter.note(address); return nil })
        let t0 = Date()
        func snapshot(_ at: Double, _ addresses: [String], bytes: UInt64) -> TrafficSnapshot {
            let rows = addresses.enumerated().map { index, address in
                ConnectionTraffic(id: "tcp4 192.168.1.20:\(10_000 + index)<->\(address):443", route: .internet, interface: "en0", received: bytes, sent: 0)
            }
            return TrafficSnapshot(timestamp: t0 + at, processes: [ProcessTraffic(pid: 4242, process: "downloader", received: bytes * UInt64(rows.count), sent: 0, connections: rows)])
        }
        let many = (0..<4_000).map { "11.\($0 / 256).\($0 % 256).1" }
        watch.consume(snapshot(0, many, bytes: 100), network: "home", name: "Home", vpn: false)
        watch.consume(snapshot(1, many, bytes: 200), network: "home", name: "Home", vpn: false)
        for _ in 0..<2_000 where await counter.count < 4_000 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await counter.count == 4_000)
        try await Task.sleep(for: .milliseconds(100))
        watch.consume(snapshot(2, ["203.0.113.9"], bytes: 100), network: "home", name: "Home", vpn: false)
        watch.consume(snapshot(3, ["203.0.113.9"], bytes: 200), network: "home", name: "Home", vpn: false)
        for _ in 0..<200 where await !counter.has("203.0.113.9") { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await counter.has("203.0.113.9"))
    }
}

/// On Wi-Fi whose name macOS hides, the sign-in state follows each check.
@MainActor struct SweepPortalTests {
    @Test func aHiddenNetworkClearsSignInNeededOnceThrough() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-portal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let watch = PortalWatch(directory: folder, notifies: false)
        watch.allowed = { true }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        watch.observe(PortalCheck(state: .portal, url: URL(string: "http://login.example.net/")!), network: "unknown", name: "Wi-Fi", identified: false, now: start)
        #expect(watch.status == .signInNeeded && watch.intercepting == true)
        watch.observe(PortalCheck(state: .open), network: "unknown", name: "Wi-Fi", identified: false, now: start + 60)
        #expect(watch.status == .none && watch.intercepting == false && watch.networks.isEmpty)
        #expect(!watch.due(network: "unknown", internetFailed: false, now: start + 70))
        // Offline says nothing either way.
        watch.observe(PortalCheck(state: .portal, url: URL(string: "http://login.example.net/")!), network: "unknown", name: "Wi-Fi", identified: false, now: start + 120)
        watch.observe(PortalCheck(state: .offline), network: "unknown", name: "Wi-Fi", identified: false, now: start + 180)
        #expect(watch.status == .signInNeeded && watch.intercepting == nil)
    }
}

/// A live ping readout past 65,536 pings, and its length.
struct SweepPingStreamTests {
    private func reply(_ sequence: Int) -> String { "64 bytes from 192.0.2.1: icmp_seq=\(sequence) ttl=64 time=1.0 ms\n" }

    @Test func theSequenceNumberStartingOverKeepsTheOrder() async {
        let stream = PingStream.address("192.0.2.1", start: Date())
        for sequence in [65_534, 65_535, 0, 1] { await stream.ingest(reply(sequence)) }
        await stream.ingest("Request timeout for icmp_seq 65538\n")
        let times = await stream.current().map(\.at)
        #expect(times.count == 5)
        #expect(zip(times, times.dropFirst()).allSatisfy { $1 - $0 == 1 })
    }

    @Test func aLiveReadoutKeepsOnlyRecentPings() async {
        let stream = PingStream.address("192.0.2.1", start: Date())
        for sequence in 0..<2_000 { await stream.ingest(reply(sequence)) }
        let pings = await stream.current()
        #expect(pings.count <= 1_800 && pings.last?.at == 1_999)
    }
}

/// The failing-connection watch samples the apps it can say something about, then the newest processes.
struct SweepServiceWatchTests {
    @Test func theSampleKeepsKnownAppsAndTheNewestProcesses() {
        let apps = (1...100).map { pid -> AppTraffic in
            var app = pid == 100 ? AppTraffic(id: "process:claude", name: "claude", bundlePath: nil) : AppTraffic(id: "process:daemon\(pid)", name: "daemon\(pid)", bundlePath: nil)
            app.processIDs = [Int32(pid)]
            return app
        }
        #expect(!ServiceCatalog.services(for: apps[99]).isEmpty)
        let sampled = ServiceTriggers.sampled(apps)
        #expect(sampled.count == 64 && sampled.first == 100 && Set(sampled).count == 64)
        #expect(sampled.contains(99) && !sampled.contains(1))
    }
}

/// Usage history and the clock: a clock set back still flushes, and a finished pack keeps its figure.
@MainActor struct SweepTrafficTests {
    private func store() -> (TrafficStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = TrafficStore(directory: directory, startMonitoring: false)
        store.startTime = { _ in nil }
        store.ownerPath = { _ in nil }
        return (store, directory)
    }
    private func sample(_ date: Date, _ received: UInt64) -> TrafficSnapshot {
        TrafficSnapshot(timestamp: date, processes: [ProcessTraffic(pid: 123456, process: "sync", received: received, sent: 0, connections: [
            ConnectionTraffic(id: "tcp4 192.168.1.20:5000<->17.1.2.3:443", route: .internet, interface: "en0", received: received, sent: 0)])])
    }

    @Test func aClockSetBackStillFlushesEveryHalfMinute() {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hourAgo = Date() - 3_600
        store.consume(sample(hourAgo, 1_000))
        store.consume(sample(hourAgo + 1, 2_000))
        store.consume(sample(hourAgo + 32, 3_000))
        #expect(store.usage.count == 1)
    }

    @Test func aFinishedPackKeepsWhatItUsed() throws {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        store.networkKey = "phone"; store.networkName = "Sam’s iPhone"
        store.preferences.historyDays = 30
        let pack = try DataPack.make(gb: 20, days: 14, start: now - 54 * 86_400, networks: DataPackNetworks(keys: ["phone": "Sam’s iPhone"]))
        store.addPack(pack, now: now)
        let used: UInt64 = 12_000_000_000
        store.usage = [UsageEntry(date: pack.start + 2 * 86_400, received: used, sent: 0, apps: ["Safari": used], networkKey: "phone")]
        store.retainUsage(at: now)
        #expect(store.usage.isEmpty)
        let kept = try #require(store.dataPacks.first)
        #expect(store.packStatus(kept, now: now).used == used)
        store.retainUsage(at: now + 86_400)
        #expect(store.packStatuses(now: now + 86_400).first?.used == used)
    }

    private final class Flag: @unchecked Sendable { var raised = false }

    @Test func pendingCountsDontTellHiddenViews() {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        var hidden = true
        store.viewsAreHidden = { hidden }
        store.networkKey = "home"
        store.preferences.budgetCycle = BudgetCycle(period: .daily)
        let quota = AppLimit(name: "sync", apps: ["process:sync"], bytes: 1_000_000)
        store.preferences.quotas = [quota]
        let start = Date()
        store.consume(sample(start, 1_000))
        let told = Flag()
        withObservationTracking {
            _ = store.budgetUsedBytes; _ = store.unattributedBytes; _ = store.limitUsed(quota)
        } onChange: { told.raised = true }
        store.consume(sample(start + 1, 2_000))
        store.consume(sample(start + 2, 3_000))
        #expect(!told.raised)
        #expect(store.budgetUsed(on: "home") == 2_000)
        hidden = false
        store.consume(sample(start + 3, 4_000))
        #expect(told.raised)
    }
}

/// Samples waiting for a busy main actor: only the newest is kept, and it covers the time of those it replaced.
@MainActor struct SweepSampleMailboxTests {
    @Test func onlyTheNewestSampleWaits() {
        let mailbox = SampleMailbox(), t0 = Date()
        let scheduled = (0..<1_000).map { mailbox.put(TrafficSnapshot(timestamp: t0 + Double($0), processes: [])) }
        #expect(scheduled.first == true && scheduled.dropFirst().allSatisfy { !$0 })
        #expect(mailbox.take()?.timestamp == t0 + 999)
        #expect(mailbox.take() == nil)
        #expect(mailbox.put(TrafficSnapshot(timestamp: t0 + 1_000, processes: [])))
    }

    @Test func aLaterSampleCountsTheTimeOfTheOnesSkipped() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrafficStore(directory: directory, startMonitoring: false)
        store.startTime = { _ in nil }
        store.ownerPath = { _ in nil }
        let start = Date()
        func sample(_ at: Double, _ received: UInt64) -> TrafficSnapshot {
            TrafficSnapshot(timestamp: start + at, processes: [ProcessTraffic(pid: 123456, process: "sync", received: received, sent: 0, connections: [
                ConnectionTraffic(id: "tcp4 192.168.1.20:5000<->17.1.2.3:443", route: .internet, interface: "en0", received: received, sent: 0)])])
        }
        store.consume(sample(0, 1_000))
        store.consume(sample(10, 10_001_000))
        #expect(store.download == 1_000_000)
        #expect(store.received == 10_000_000)
    }
}
