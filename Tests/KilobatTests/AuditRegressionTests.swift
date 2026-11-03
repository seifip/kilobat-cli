import Darwin
import Foundation
import Network
import Testing
@testable import KilobatCore

// Regressions for process recovery, policy isolation and network accounting.
@Suite(.serialized) @MainActor struct AuditRegressionTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-audit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func sleeper() throws -> Process {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["30"]
        try process.run(); return process
    }
    func cleanup(_ process: Process) { kill(process.processIdentifier, SIGCONT); process.terminate(); process.waitUntilExit() }
    func snapshot(ssid: String? = "Home", gateway: String = "192.168.1.1", wired: String? = nil, rssi: Int = -50) -> DiagnosticSnapshot {
        DiagnosticSnapshot(date: Date(), radio: RadioSample(ssid: ssid, interface: "en0", rssi: rssi, noise: -90, transmitMbps: 100, channel: 1, band: "2.4 GHz"), gateway: gateway,
                           router: PingResult(host: gateway, samples: [1], lossPercent: 0), internet: PingResult(host: "1.1.1.1", samples: [10], lossPercent: 0),
                           dnsMilliseconds: 1, dnsServers: [], captivePortal: false, networkService: wired == nil ? "Wi-Fi" : "USB Ethernet", wiredInterface: wired)
    }
    @Test func publicDHCPPortMustNotBypassKillSwitch() {
        var policy = FilterPolicy(); policy.defaultAllow = true
        policy.killSwitch = KillSwitchPolicy(armed: true, vpnDown: true, allowLAN: false)
        let verdict = policy.decide(.init(app: "example.app", process: "app", host: nil, address: "8.8.8.8", port: "67"))
        #expect(verdict.verdict == .block)
    }
    @Test func expiredSpecificTemporaryRuleMustNotHideLiveProcessRule() {
        var policy = FilterPolicy(); policy.defaultAllow = true
        policy.temporary["example.app"] = TemporaryRule(allowed: true, expires: .distantPast)
        policy.temporary["process:worker"] = TemporaryRule(allowed: false, expires: .distantFuture)
        #expect(policy.decide(.init(app: "example.app", process: "worker", host: "example.com")).verdict == .block)
    }
    @Test func failedLidRestoreMustPreserveOriginalMarkerAcrossNextHold() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let power = FakePower(), keeper = LidKeeper(directory: dir, system: power.system), now = Date()
        _ = keeper.hold(LidLease(until: now + 3600, reason: "one"), now: now)
        power.setWorks = false; keeper.release("done", now: now + 1)
        power.setWorks = true
        _ = keeper.hold(LidLease(until: now + 3600, reason: "two"), now: now + 2)
        keeper.release("done", now: now + 3)
        #expect(power.sleepDisabled == false)
    }
    @Test func mustNotSuspendIfLedgerCannotBeWritten() throws {
        let dir = try folder(), child = try sleeper(); defer { cleanup(child); try? FileManager.default.removeItem(at: dir) }
        let blocker = dir.appendingPathComponent("not-a-directory"); try Data().write(to: blocker)
        let ledger = blocker.appendingPathComponent("held.json")
        let held = CallMode.hold([child.processIdentifier], app: "Audit", ledger: ledger)
        #expect(held.isEmpty)
        #expect(CallMode.held(ledger: ledger).count == held.count)
    }
    @Test func uploadResumeMustPreserveLaterUserRules() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let traffic = TrafficStore(directory: dir, startMonitoring: false)
        traffic.networkKey = "home"; traffic.connected = true; traffic.preferences.profile = .travel
        traffic.apps = [AppTraffic(id: "com.example.Uploader", name: "Uploader")]
        let uploads = UploadStore(ledger: dir.appendingPathComponent("held.json"))
        uploads.allowed = { true }; uploads.filterActive = { true }; uploads.start(traffic: traffic, polling: false)
        try uploads.hold("Uploader", until: .manual)
        traffic.setTemporary("com.example.Uploader", allowed: false, minutes: 60)
        traffic.setTemporary("com.example.Uploader", allowed: true, minutes: 60, in: .work)
        uploads.resume("Uploader")
        #expect(traffic.temporaryRule("com.example.Uploader") != nil)
        #expect(traffic.preferences.temporaryRules?["Work|com.example.Uploader"] != nil)
    }
    @Test func approvalsDoNotExposeOrDecideAnotherUsersFlows() throws {
        let queue = ApprovalQueue<Int>()
        var resumed: [Int: Bool] = [:]
        queue.resume = { resumed[$0] = $1 }
        _ = queue.encoded(for: 501)
        #expect(queue.listening(for: 501))
        #expect(!queue.listening(for: 502))
        for (uid, host) in [(UInt32(501), "first.example"), (502, "second.example")] {
            queue.hold(Int(uid), approval: .init(app: "example.app", process: "app", path: nil,
                signer: nil, signatureValid: false, pid: 1, uid: uid,
                destinations: [.init(host: host, address: nil, port: nil)]))
        }
        let pending = try JSONDecoder().decode([PendingApproval].self, from: queue.encoded(for: 501))
        #expect(pending.flatMap(\.destinations).compactMap(\.host) == ["first.example"])
        #expect(queue.decide("example.app", allowed: true, uid: 501))
        #expect(resumed == [501: true])
        #expect(queue.recentDecision("example.app", uid: 501) == true)
        #expect(queue.recentDecision("example.app", uid: 502) == nil)
        #expect(queue.decide("example.app", allowed: false, uid: 502))
        #expect(resumed == [501: true, 502: false])
    }
    @Test func resumingOneCallAppClearsOnlyItsOwnBlock() throws {
        let dir = try folder(), first = try sleeper(), second = try sleeper()
        defer { cleanup(first); cleanup(second); try? FileManager.default.removeItem(at: dir) }
        let ledger = dir.appendingPathComponent("held.json")
        let store = TrafficStore(directory: dir, startMonitoring: false)
        let calls = CallStore(directory: dir, ledger: ledger)
        calls.allowed = { true }
        calls.start(traffic: store, diagnostics: DiagnosticStore(), polling: false)
        var dropbox = AppTraffic(id: "com.getdropbox.dropbox", name: "Dropbox")
        var onedrive = AppTraffic(id: "com.microsoft.OneDrive", name: "OneDrive")
        dropbox.processIDs = [first.processIdentifier]
        onedrive.processIDs = [second.processIdentifier]
        store.apps = [dropbox, onedrive]
        calls.holdBeforeCall(["Dropbox", "OneDrive"])
        defer { calls.release() }
        #expect(store.temporaryRule(dropbox.id)?.allowed == false)
        #expect(store.temporaryRule(onedrive.id)?.allowed == false)
        calls.resume("Dropbox")
        #expect(store.temporaryRule(dropbox.id) == nil)
        #expect(store.temporaryRule(onedrive.id)?.allowed == false)
        #expect(CallMode.held(ledger: ledger).map(\.app) == ["OneDrive"])
    }
    @Test func focusMustHoldNewProcessesOfAnAlreadyHeldApp() throws {
        let dir = try folder(), first = try sleeper(), second = try sleeper()
        defer { cleanup(first); cleanup(second); try? FileManager.default.removeItem(at: dir) }
        let ledger = dir.appendingPathComponent("held.json"), focus = FocusFilterStore(directory: dir, ledger: ledger)
        focus.allowed = { true }; focus.gameInFront = { false }; focus.skipped = { [] }
        focus.processes = { [("com.getdropbox.dropbox", [first.processIdentifier], nil)] }
        focus.apply(FocusFilter(holdApps: true))
        focus.processes = { [("com.getdropbox.dropbox", [first.processIdentifier, second.processIdentifier], nil)] }
        focus.rescan()
        #expect(CallMode.held(ledger: ledger).contains { $0.pid == second.processIdentifier })
        focus.quit()
    }
    @Test func localBytesDuringCounterFailureMustNotBeBilled() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = TrafficStore(directory: dir, startMonitoring: false), now = Date()
        store.startTime = { _ in nil }
        var reading: [String: ByteCount]? = ["en0": ByteCount()]
        store.readCounters = { reading }
        func sample(_ offset: Double, _ bytes: UInt64) {
            store.consume(TrafficSnapshot(timestamp: now + offset, processes: [ProcessTraffic(pid: 1234567, process: "audit", received: bytes, sent: 0,
                connections: [.init(id: "lan", route: .local, interface: "en0", received: bytes, sent: 0)])]))
        }
        sample(0, 0); reading = nil; sample(1, 1000)
        reading = ["en0": ByteCount(received: 1000)]; sample(2, 1000)
        #expect(store.total == 0)
    }
    @Test func aggregateRateMustNotCountCarrierTwice() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        ProxyRouting.shared.update(ProxyEnvironment(date: Date(), system: .init(), clients: [], carriers: [.init(pid: 1234568, name: "mihomo", kind: "proxy")]))
        defer { ProxyRouting.shared.update(ProxyEnvironment(date: Date(), system: .init(), clients: [], carriers: [])) }
        let store = TrafficStore(directory: dir, startMonitoring: false), now = Date(); store.startTime = { _ in nil }
        for (offset, bytes) in [(0.0, UInt64(0)), (1.0, UInt64(1000))] {
            store.consume(TrafficSnapshot(timestamp: now + offset, processes: [ProcessTraffic(pid: 1234567, process: "client", received: bytes, sent: 0), ProcessTraffic(pid: 1234568, process: "mihomo", received: bytes, sent: 0)]))
        }
        #expect(store.total == 1000)
        #expect(store.download == 1000)
    }
    @Test func vpnGatewayMustNotCreateAnotherPhysicalNetworkBudget() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = TrafficStore(directory: dir, startMonitoring: false)
        store.switchNetwork(snapshot()); store.preferences.limitGB = 42
        var tunneled = snapshot(gateway: "10.8.0.1")
        tunneled.physicalGateway = "192.168.1.1"
        tunneled.tunneledRoute = true
        store.switchNetwork(tunneled)
        #expect(store.preferences.limitGB == 42)
    }
    @Test func ethernetIdentityRequiresPhysicalRouterEvidence() {
        var home = snapshot(wired: "en5")
        #expect(!home.networkIdentified)
        #expect(home.networkKey == "unknown")
        home.gatewayMAC = "00:11:22:33:44:55"
        var hotel = home
        hotel.gatewayMAC = "00:11:22:33:44:66"
        #expect(home.networkIdentified && hotel.networkIdentified)
        #expect(home.networkKey != hotel.networkKey)
    }
    @Test func ipv6OutsideTunnelPreventsProtectedState() {
        var exit = ExitPath(interface: "utun4")
        exit.ipv6Interface = "en0"
        var preferences = SavedPreferences()
        preferences.killSwitch = true
        let state = KillSwitchState.evaluate(preferences, pro: true, filterActive: true, exit: exit, armed: true)
        #expect(exit.vpn == .partial)
        #expect(state.status == .blocking)
        #expect(state.policy().blocks())
        exit.ipv6Interface = "utun4"
        #expect(exit.vpn == .full)
    }
    @Test func focusLeavesCurrentForegroundAppRunning() throws {
        let dir = try folder(), child = try sleeper()
        defer { cleanup(child); try? FileManager.default.removeItem(at: dir) }
        let ledger = dir.appendingPathComponent("held.json")
        let focus = FocusFilterStore(directory: dir, ledger: ledger)
        focus.allowed = { true }; focus.gameInFront = { false }; focus.skipped = { [] }
        focus.frontmost = { "com.getdropbox.dropbox" }
        focus.processes = { [("com.getdropbox.dropbox", [child.processIdentifier], nil)] }
        focus.apply(FocusFilter(holdApps: true))
        #expect(CallMode.held(ledger: ledger).isEmpty)
        focus.quit()
    }
    @Test func poorUnusedWiFiMustNotDegradeEthernet() {
        #expect(snapshot(wired: "en5", rssi: -88).health == .good)
    }
    @Test func routerDescriptionMustHonorURLBase() {
        let description = Data("<root><URLBase>http://192.168.1.1:49000/base/</URLBase><serviceList><service><serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType><controlURL>control/WANCommon</controlURL></service></serviceList></root>".utf8)
        #expect(RouterCounters.controlURL(description: description, base: URL(string: "http://192.168.1.1:5000/root.xml")!) == "http://192.168.1.1:49000/base/control/WANCommon")
    }
    @Test func publicDNSOutsideVPNMustBeReported() {
        let result = TunnelCheck.make(exit: ExitPath(interface: "utun4"), proxy: ProxyEnvironment(date: Date(), system: .init(), clients: [], carriers: []), dnsServer: "8.8.8.8", dnsInterface: "en0", ipv6Interface: "utun4")
        #expect(result.findings.contains { $0.id == "dnsOutsideVPN" })
    }
    @Test func householdTimeoutMustFinishBeforePeerCloses() async throws {
        let server = HouseholdServer(onConnection: { link in
            Task { try? await Task.sleep(for: .milliseconds(500)); link.cancel() }
        })
        try server.start(name: "Audit", txt: [:], loopback: true); defer { server.stop() }
        let port = try #require(await server.ready())
        let connection = try await HouseholdConnection.connect(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        defer { connection.cancel() }
        let start = Date()
        do { _ = try await connection.receive(timeout: 0.05) } catch { }
        #expect(Date().timeIntervalSince(start) < 0.25)
    }
    @Test func commandTimeoutMustEscalateWhenSIGTERMIgnored() async {
        let start = Date()
        _ = await CommandRunner.run("/bin/sh", ["-c", "trap '' TERM; /bin/sleep 1"], timeout: 0.05)
        #expect(Date().timeIntervalSince(start) < 0.5)
    }
}
