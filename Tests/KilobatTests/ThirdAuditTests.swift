import Foundation
import Testing
@testable import KilobatCore

private final class ThirdAuditDNS: DNSSystem, @unchecked Sendable {
    var values: [String: [String]] = [:]
    func serviceServers(_ service: String) async -> [String] { values[service] ?? [] }
    func dhcpServers(interface: String) async -> [String] { ["192.168.1.1"] }
    func managed() async -> Bool { false }
    func gateway() async -> String? { "192.168.1.1" }
}
private struct ThirdAuditNoProbe: DNSProbing {
    func lookup(_ name: String, server: String) async -> DNSLookup { DNSLookup(ms: nil, status: nil) }
    func connect(_ address: String) async -> Double? { nil }
}
private actor DelayedBenchmarkDNS: DNSSystem {
    private var reply: CheckedContinuation<[String], Never>?
    var started: Bool { reply != nil }
    func serviceServers(_ service: String) async -> [String] { [] }
    func dhcpServers(interface: String) async -> [String] { await withCheckedContinuation { reply = $0 } }
    func managed() async -> Bool { false }
    func gateway() async -> String? { nil }
    func resume() { reply?.resume(returning: ["192.168.1.1"]); reply = nil }
}

@MainActor private final class ThirdAuditApply: DNSApplying {
    let system: ThirdAuditDNS
    var fail = false
    var changes: [(String, [String])] = []
    var available: Bool { true }
    init(_ system: ThirdAuditDNS) { self.system = system }
    func apply(servers: [String], service: String) async throws {
        changes.append((service, servers))
        system.values[service] = fail ? Array(servers.prefix(1)) : servers
        if fail { throw NSError(domain: "Fixture", code: 1) }
    }
}
@MainActor struct ThirdAuditTests {
    @Test func dnsBenchmarkDiscardsAnInterruptedRun() async throws {
        let system = DelayedBenchmarkDNS()
        let watch = FastestDNSWatch(directory: nil, system: system, probe: ThirdAuditNoProbe())
        func context(_ key: String) -> FastestDNSWatch.Context {
            .init(network: key, name: key, service: "Wi-Fi", interface: "en0", gateway: nil, resolvers: [],
                  lookupWorked: true, networkUp: true, moment: .init(network: key, busy: true))
        }
        await watch.observe(context("A"))
        watch.measureNow()
        while !(await system.started) { await Task.yield() }
        await watch.observe(context("B"))
        await watch.observe(context("A"))
        await system.resume()
        for _ in 0..<200 where watch.measuring { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!watch.measuring && watch.record?.runs.isEmpty == true)
    }

    @Test func aPendingDNSWriteIsRecoveredAfterRestart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pending = DNSApplied(network: "A", networkName: "A", service: "Wi-Fi", resolver: "quad9",
                                 servers: DNSResolverChoice.quad9.servers, gateway: nil, date: Date())
        let saved = FastestDNSWatch.Saved(current: "A", networks: [], switches: [], applied: nil, pending: pending)
        try JSONEncoder().encode(saved).write(to: folder.appendingPathComponent(FastestDNSWatch.fileName))
        let system = ThirdAuditDNS()
        system.values["Wi-Fi"] = Array(pending.servers.prefix(1))
        let watch = FastestDNSWatch(directory: folder, system: system, probe: ThirdAuditNoProbe())
        let helper = ThirdAuditApply(system)
        watch.applier = helper
        await watch.observe(.init(network: "B", name: "B", service: "Ethernet", interface: "en1", gateway: nil, resolvers: [],
                                 lookupWorked: true, networkUp: true, moment: .init(network: "B", busy: true)))
        #expect(system.values["Wi-Fi"] == [] && helper.changes.first?.0 == "Wi-Fi")
        #expect(FastestDNSWatch.load(directory: folder).pending == nil)
    }

    @Test func serviceSpeedDiscardsADownloadAcrossNetworkChanges() async throws {
        let watch = ServiceSpeedWatch(directory: nil)
        let target = try #require(ServiceSpeedTarget.all.first)
        let snapshot = TrafficSnapshot(timestamp: Date(), processes: [])
        watch.consume(snapshot, network: "A", name: "A", vpn: false)
        var response: CheckedContinuation<ServiceTransfer, Never>?
        watch.runTest = { _, _ in await withCheckedContinuation { response = $0 } }
        let running = Task { await watch.test(target, metered: false) }
        while response == nil { await Task.yield() }
        watch.consume(snapshot, network: "B", name: "B", vpn: false)
        watch.consume(snapshot, network: "A", name: "A", vpn: false)
        response?.resume(returning: .init(date: Date(), seconds: 5, bytes: 20_000_000, mbps: 32, tested: true))
        await running.value
        #expect(watch.log.networks.isEmpty && watch.testError != nil)
    }

    @Test func controlledAuditFindings() async throws {
        let now = Date()
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fixtures-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let complete = Array("GET / HTTP/1.1\r\nHost: malware.example\r\n\r\n".utf8)
        for split in 1..<complete.count {
            guard case .needMore = FlowSniffer.sniff(Array(complete.prefix(split))) else {
                Issue.record("HTTP header was decided at byte \(split)")
                continue
            }
        }
        #expect(FlowSniffer.sniff(complete) == .name("malware.example"))
        func applied() -> DNSApplied { DNSApplied(network: "home", networkName: "Home", service: "Wi-Fi", resolver: "quad9", servers: DNSResolverChoice.quad9.servers, gateway: "192.168.1.1", date: now) }
        func record() -> DNSNetworkRecord { DNSNetworkRecord(network: "home", name: "Home", lastSeen: now) }
        func context(_ key: String = "home", service: String = "Wi-Fi") -> FastestDNSWatch.Context {
            FastestDNSWatch.Context(network: key, name: key, service: service, interface: "en0", gateway: "192.168.1.1", resolvers: ["192.168.1.1"], lookupWorked: true, networkUp: true, moment: .init(network: key, busy: true))
        }
        let system1 = ThirdAuditDNS(); system1.values["Wi-Fi"] = ["10.0.0.53"] // user changed DNS after Kilobat's earlier setting
        let apply1 = ThirdAuditApply(system1)
        let dns1 = FastestDNSWatch(directory: nil, system: system1, probe: ThirdAuditNoProbe())
        dns1.applier = apply1; dns1.preview(record(), applied: applied())
        await dns1.undo()
        #expect(system1.values["Wi-Fi"] == ["10.0.0.53"] && apply1.changes.isEmpty, "Audit #44")

        let system2 = ThirdAuditDNS(); system2.values["Wi-Fi"] = DNSResolverChoice.quad9.servers; system2.values["Ethernet"] = []
        let apply2 = ThirdAuditApply(system2)
        let dns2 = FastestDNSWatch(directory: nil, system: system2, probe: ThirdAuditNoProbe())
        dns2.applier = apply2; dns2.preview(record(), applied: applied())
        await dns2.observe(context("office", service: "Ethernet"), now: now)
        #expect(dns2.applied == nil && system2.values["Wi-Fi"] == [] && apply2.changes.first?.0 == "Wi-Fi", "Audit #45")

        let day = cal.startOfDay(for: now)
        let minute = cal.dateInterval(of: .hour, for: now)!.start
        let future = DataPack(name: "Future", bytes: 2000, start: minute + 3500, end: minute + 86400, networks: .init(keys: ["A": "A"]))
        let beforeStart = minute + 100
        let owner = DataPacks.owner(of: "A", name: "A", at: beforeStart, in: [future], calendar: cal)
        #expect(!future.active(at: beforeStart) && owner == nil, "Audit #47")
        let oldStart = day - 31 * 86400 + 12 * 3600
        let pack = DataPack(name: "Long pack", bytes: 10000, start: oldStart, end: oldStart + 90 * 86400, networks: .init(keys: ["A": "A"]))
        let oldUsage = [UsageEntry(date: oldStart + 3600, received: 1000, sent: 0, apps: [:], networkKey: "A")]
        let compacted = TrafficStore.compact(oldUsage, now: now, calendar: cal, packs: [pack])
        let before = DataPacks.macBytes(pack, packs: [pack], usage: oldUsage, names: { _ in "A" }, to: now, calendar: cal)
        let after = DataPacks.macBytes(pack, packs: [pack], usage: compacted, names: { _ in "A" }, to: now, calendar: cal)
        #expect(before == 1000 && after == 1000, "Audit #48")
        var corrected = pack
        try DataPacks.correct(&corrected, leftBytes: 5000, macBytes: 1000, now: now - 300)
        let recentUsage = [UsageEntry(date: now - 30, received: 100, sent: 0, apps: [:], networkKey: "A")]
        let correctedStatus = DataPacks.status(corrected, packs: [corrected], usage: recentUsage, names: { _ in "A" }, now: now, calendar: cal)
        #expect(correctedStatus.left == 4900, "Audit #49")

        func sample(_ date: Date, name: String, up: Bool = true) -> DiagnosticSnapshot {
            DiagnosticSnapshot(date: date, radio: RadioSample(ssid: name, interface: "en0", rssi: -55, noise: -95, transmitMbps: 400, channel: 149, band: "5 GHz"), gateway: "192.168.1.1", router: PingResult(host: "192.168.1.1", samples: [3], lossPercent: 0), internet: PingResult(host: "1.1.1.1", samples: up ? [20] : [], lossPercent: up ? 0 : 100), dnsMilliseconds: 20, dnsServers: ["192.168.1.1"], captivePortal: false, networkService: "Wi-Fi")
        }
        let j1 = NetworkJournal(directory: folder.appendingPathComponent("network")); j1.alerts = false
        let secondary = PingResult(host: "8.8.8.8", samples: [20], lossPercent: 0)
        j1.ingest(sample(now, name: "A"), secondary: secondary, httpReachable: true, date: now)
        j1.ingest(sample(now + 10, name: "B"), secondary: secondary, httpReachable: true, date: now + 10)
        let wrong = SupportReport.make(samples: j1.samples, events: j1.events, speedTests: [], hours: 1, mac: "Mac", now: now + 10)
        #expect(j1.samples.last?.networkName == "B" && j1.events.last?.network == "B" && wrong.latency?.checks == 1, "Audit #50")
        let outageFolder = folder.appendingPathComponent("outage")
        let j2 = NetworkJournal(directory: outageFolder); j2.alerts = false
        let noPing = PingResult(host: "8.8.8.8", samples: [], lossPercent: 100)
        for i in 0..<6 { let t = now - 600 + Double(i * 60); j2.ingest(sample(t, name: "A", up: false), secondary: noPing, httpReachable: false, date: t) }
        let restarted = NetworkJournal(directory: outageFolder)
        let event = restarted.events.first { $0.kind == "Unreachable" }
        #expect(event.flatMap { event in event.end?.timeIntervalSince(event.start) } == 300, "Audit #51")

        var book = DeviceBook(); book.setHome(true, network: "A", name: "A")
        book.observe([.init(mac: "02:11:22:33:44:55", address: "192.168.1.2", hostname: "Ritas-iPad")], network: "A", name: "A", now: now - 600)
        book.setVerdict(.mine, mac: "02:11:22:33:44:55", network: "A")
        let newcomers = book.observe([.init(mac: "02:66:77:88:99:aa", address: "192.168.1.3", hostname: "Ritas-iPad-2")], network: "A", name: "A", now: now)
        let newDevice = book.device(mac: "02:66:77:88:99:aa", network: "A")
        #expect(newcomers.count == 1 && newDevice?.verdict != .mine && book.networks["A"]?.devices.count == 2, "Audit #52")

        let registryFolder = folder.appendingPathComponent("registry")
        let registry = DeviceRegistry(directory: registryFolder)
        registry.observe([.init(mac: "02:11:22:33:44:55", address: "192.168.1.2")], network: "A", name: "A", now: now)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: registryFolder.path)
        registry.rename(mac: "02:11:22:33:44:55", to: "New name", network: "A")
        let failed = registry.persistenceError != nil
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: registryFolder.path)
        registry.rename(mac: "02:11:22:33:44:55", to: "New name", network: "A")
        let reloaded = DeviceRegistry(directory: registryFolder)
        #expect(failed && reloaded.device(mac: "02:11:22:33:44:55", network: "A")?.name == "New name", "Audit #53")

        let peerID = HouseholdBook.newID()
        var householdBook = HouseholdBook()
        householdBook.add(HouseholdPeer(id: peerID, name: "Peer", network: "A", networkName: "A", paired: now))
        let h = HouseholdStore(directory: folder.appendingPathComponent("household"), keys: MemoryHouseholdKeys())
        h.allowed = { true }; h.network = { HouseholdNetwork(key: "A", name: "A", home: true) }
        let summary = HouseholdSummary.make(id: peerID, name: "Peer", download: 100000, upload: 100000, apps: [], onCall: false, now: now)
        h.preview(book: householdBook, live: [HouseholdLive(summary: summary, received: now)], unreachable: [peerID])
        let peer = h.report().peers.first
        #expect(peer?.reachable == false && peer?.live != nil, "Audit #55")

        var started = false, completed = false, writes = 0
        let tool = MCPTool(name: "fixture", title: "Fixture", description: "Fixture only", annotations: .init(readOnly: true)) { _, _ in
            started = true
            try await Task.sleep(for: .milliseconds(150))
            completed = true
            return .text("completed")
        }
        let server = MCPServer(name: "fixture", title: "Fixture", version: "1", instructions: "", tools: [tool], write: { _ in writes += 1 })
        server.receive(Data("[{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"tools/call\",\"params\":{\"name\":\"fixture\"}}]".utf8))
        while !started { await Task.yield() }
        server.receive(Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":42}}".utf8))
        await server.drain()
        #expect(!completed && writes == 0, "Audit #56")

        let c = RouterConnection(kind: .fritzbox, network: "A", networkName: "A", url: "http://192.168.1.1", entered: "192.168.1.1")
        let home = HomeUsageStore(directory: nil, secrets: MemoryRouterSecrets())
        var oldPoll = RouterPoll(date: now - 60, clients: [], wan: RouterWAN(down: 3_000_000_000, up: 0, bits: 32), perDevice: false)
        oldPoll.uptime = 10000
        var newPoll = RouterPoll(date: now, clients: [], wan: RouterWAN(down: 100, up: 0, bits: 32), perDevice: false)
        newPoll.uptime = 10
        home.ingest(oldPoll, connection: c, calendar: cal); home.ingest(newPoll, connection: c, calendar: cal)
        let phantom = home.ledger.today(now: now, calendar: cal, network: "A")[HomeUsageLedger.home]?.down ?? 0
        #expect(phantom == 0, "Audit #57")

        let system3 = ThirdAuditDNS()
        let failApply = ThirdAuditApply(system3); failApply.fail = true
        let dns3 = FastestDNSWatch(directory: nil, system: system3, probe: ThirdAuditNoProbe(), calendar: cal)
        var winning = record()
        func resolver(_ id: String, _ ms: Double) -> DNSResolverRun { DNSResolverRun(id: id, server: "1.1.1.1", firstMs: Array(repeating: ms, count: 10), repeatMs: Array(repeating: ms / 2, count: 10), queries: 20, failures: 0, rewritesMissing: false) }
        winning.runs = (0..<4).map { DNSRun(date: now - Double(3 - $0) * 86400, resolvers: [resolver("network", 48), resolver("quad9", 12)]) }
        dns3.preview(winning)
        var preferences = SavedPreferences(); preferences.setFastestDNS(true, network: nil)
        dns3.allowed = { true }; dns3.preferences = { preferences }; dns3.applier = failApply
        await dns3.observe(context(), now: now + 1)
        await dns3.observe(context(), now: now + 2)
        #expect(dns3.applied == nil && system3.values["Wi-Fi"] == [] && failApply.changes.contains { $0.1.isEmpty }, "Audit #60")
    }
}
