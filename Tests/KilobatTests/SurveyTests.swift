import Foundation
import Testing
@testable import KilobatCore

struct SurveyTests {
    @Test func wakePacketHasSixSyncBytesAndSixteenMACs() throws {
        let packet = try DeviceActions.magicPacket(mac: "01:23:45:67:89:ab")
        #expect(packet.count == 102)
        #expect(Array(packet.prefix(6)) == Array(repeating: 255, count: 6))
        for offset in stride(from: 6, to: 102, by: 6) { #expect(Array(packet[offset..<offset+6]) == [1, 35, 69, 103, 137, 171]) }
        #expect(throws: (any Error).self) { try DeviceActions.magicPacket(mac: "zz:11:22:33:44:55") }
        #expect(throws: (any Error).self) { try DeviceActions.magicPacket(mac: "1:2:3") }
    }
    @Test @MainActor func observationsPersistAreBoundedAndDoNotSaveEmptySpots() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = SurveyJournal(directory: directory)
        let radio = RadioSample(ssid: "Home", interface: "en0", rssi: -50, noise: -90, transmitMbps: 100, channel: 1, band: "2.4 GHz")
        journal.saveSpot(name: "   ", radio: radio)
        #expect(journal.spots.isEmpty)
        journal.saveSpot(name: " Desk ", radio: radio)
        for _ in 0..<35 { journal.saveScan([]) }
        journal.saveRoute(host: "example.com", output: "test route")
        let loaded = SurveyJournal(directory: directory)
        #expect(loaded.spots.first?.name == "Desk")
        #expect(loaded.scans.count == 30)
        #expect(loaded.routes.first?.host == "example.com")
        loaded.removeSpot(try #require(loaded.spots.first?.id))
        #expect(SurveyJournal(directory: directory).spots.isEmpty)
    }
}

struct ConnectionRuleTests {
    @Test func matchesAppDirectionPortExpiryAndDomainBoundaries() {
        let rule = ConnectionRule(app: "com.example.app", host: "Example.COM.", port: "443", direction: "outgoing", allowed: false, profile: "Travel", expires: Date(timeIntervalSince1970: 100))
        let now = Date(timeIntervalSince1970: 50)
        #expect(rule.matches(app: "com.example.app", process: "app", host: "api.example.com", address: nil, port: "443", direction: "outgoing", now: now))
        #expect(!rule.matches(app: "com.example.app", process: "app", host: "evil-example.com", address: nil, port: "443", direction: "outgoing", now: now))
        #expect(!rule.matches(app: "other", process: "app", host: "example.com", address: nil, port: "443", direction: "outgoing", now: now))
        #expect(!rule.matches(app: "com.example.app", process: "app", host: "example.com", address: nil, port: "80", direction: "outgoing", now: now))
        #expect(!rule.matches(app: "com.example.app", process: "app", host: "example.com", address: nil, port: "443", direction: "incoming", now: now))
        #expect(!rule.matches(app: "com.example.app", process: "app", host: "example.com", address: nil, port: "443", direction: "outgoing", now: Date(timeIntervalSince1970: 101)))
    }
}

struct RouterCounterTests {
    @Test func acceptsNumericCounterAndRejectsFaultOrNegativeValue() throws {
        #expect(try RouterCounters.parse(Data("<Envelope><NewTotalBytesReceived>123456</NewTotalBytesReceived></Envelope>".utf8), field: "NewTotalBytesReceived") == 123456)
        #expect(throws: (any Error).self) { try RouterCounters.parse(Data("<Fault>Unsupported</Fault>".utf8), field: "NewTotalBytesReceived") }
        #expect(throws: (any Error).self) { try RouterCounters.parse(Data("<NewTotalBytesReceived>-1</NewTotalBytesReceived>".utf8), field: "NewTotalBytesReceived") }
        #expect(TrafficFormat.rate(.infinity) == "—")
        #expect(TrafficFormat.rate(.nan) == "—")
        #expect(TrafficFormat.bytes(0) == "0 B")
    }
}

struct DomainListTests {
    @Test func hostsCommentsDuplicatesAndUnsupportedSyntax() throws {
        let list = "# comment\n0.0.0.0 Ads.Example.com tracker.example.com\n127.0.0.1 localhost\nads.example.com\n"
        #expect(try DomainPolicy.parseList(Data(list.utf8)) == ["ads.example.com", "tracker.example.com"])
        #expect(throws: (any Error).self) { try DomainPolicy.parseList(Data("||example.com^".utf8)) }
        #expect(throws: (any Error).self) { try DomainPolicy.parseList(Data("https://example.com".utf8)) }
        #expect(throws: (any Error).self) { try DomainPolicy.parseList(Data("123.45.67.89".utf8)) }
    }
    @Test func remoteEndpointRequiresConnectedSocketAndKeepsIPv6() {
        let row = SocketDestination(pid: 1, process: "a", transport: "TCP", endpoint: "[::1]:50000->[2001:db8::1]:443", state: "ESTABLISHED", date: Date())
        #expect(row.remoteHostAndPort?.0 == "2001:db8::1")
        #expect(row.remoteHostAndPort?.1 == "443")
        let listener = SocketDestination(pid: 1, process: "a", transport: "TCP", endpoint: "*:443", state: "LISTEN", date: Date())
        #expect(listener.remoteHostAndPort == nil)
    }
}

struct FilterPolicyTests {
    @Test @MainActor func connectionRulesSurviveSerializableVendorConfiguration() throws {
        let controller = FilterController()
        var preferences = SavedPreferences()
        preferences.connectionRules = [ConnectionRule(app: "com.example.app", host: "example.com", allowed: false, profile: "Travel")]
        let policy = controller.policy(preferences, budgetReached: false)
        let json = try JSONSerialization.data(withJSONObject: policy, options: .sortedKeys)
        #expect(!json.isEmpty)
        let encoded = try #require(policy["connectionRules"] as? String)
        let decoded = try JSONDecoder().decode([ConnectionRule].self, from: #require(Data(base64Encoded: encoded)))
        #expect(decoded == preferences.connectionRules)
    }
}


struct ProcessControlTests {
    @Test @MainActor func onlyStopsTheSelectedDisposableChild() async throws {
        for force in [false, true] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["60"]
            try child.run()
            defer { if child.isRunning { child.terminate() } }
            let selection = try await ProcessControl.inspect(pid: child.processIdentifier)
            #expect(selection.name.contains("sleep"))
            try await ProcessControl.terminate(selection, force: force)
            for _ in 0..<30 where child.isRunning { try await Task.sleep(for: .milliseconds(50)) }
            #expect(!child.isRunning)
        }
        await #expect(throws: (any Error).self) { try await ProcessControl.inspect(pid: ProcessInfo.processInfo.processIdentifier) }
        await #expect(throws: (any Error).self) { try await ProcessControl.inspect(pid: 1) }
    }
}

struct FilterEventTests {
    @Test @MainActor func deduplicatesBoundsExpiresAndPersistsPrivateMetadata() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("events.json")
        let journal = FilterEventJournal(file: file)
        let now = Date()
        let event = FilterEvent(date: now, app: "test", endpoint: "example.com:443", direction: "outgoing", reason: "App block rule")
        let expired = FilterEvent(date: now.addingTimeInterval(-8 * 86400), app: "expired", endpoint: "x", direction: "incoming", reason: "test")
        try journal.ingest([event, event, expired], now: now)
        #expect(journal.events.count == 1)
        try journal.ingest([event], now: now)
        #expect(journal.events.count == 1)
        #expect(FilterEventJournal(file: file).events.first?.reason == "App block rule")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try journal.ingest((0..<1100).map { _ in FilterEvent(date: now, app: "test", endpoint: "x", direction: "outgoing", reason: "test") }, now: now)
        #expect(journal.events.count == 1000)
    }
}
