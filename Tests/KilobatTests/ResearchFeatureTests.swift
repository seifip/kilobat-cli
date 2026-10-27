import Foundation
import Testing
@testable import KilobatCore

struct ResearchFeatureTests {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func sample(reachable: Bool = false, ssid: String = "Network") -> DiagnosticSnapshot {
        DiagnosticSnapshot(date: Date(), radio: RadioSample(ssid: ssid, interface: "en0", rssi: -50, noise: -90, transmitMbps: 100, channel: 1, band: "2.4 GHz"), gateway: "192.168.1.1", router: nil, internet: PingResult(host: "1.1.1.1", samples: reachable ? [10, 11, 12] : [], lossPercent: reachable ? 0 : 100), dnsMilliseconds: 5, dnsServers: [], captivePortal: false, networkService: "Wi-Fi")
    }
    @Test @MainActor func outageNeedsThreeFailuresAndTwoRecoveries() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let journal = NetworkJournal(directory: path); journal.alerts = false
        let noReply = PingResult(host: "8.8.8.8", samples: [], lossPercent: 100)
        let start = Date()
        for i in 0..<2 { journal.ingest(sample(), secondary: noReply, httpReachable: false, date: start.addingTimeInterval(Double(i) * 12)) }
        #expect(journal.events.isEmpty)
        journal.ingest(sample(), secondary: noReply, httpReachable: false, date: start.addingTimeInterval(24))
        #expect(journal.events.count == 1)
        #expect(journal.events[0].end == nil)
        journal.ingest(sample(reachable: true), secondary: noReply, httpReachable: nil, date: start.addingTimeInterval(36))
        #expect(journal.events[0].end == nil)
        journal.ingest(sample(reachable: true), secondary: noReply, httpReachable: nil, date: start.addingTimeInterval(48))
        #expect(journal.events[0].end?.timeIntervalSince(start) == 48)
        #expect(NetworkJournal(directory: path).events.count == 1)
    }
    @Test @MainActor func httpFallbackAndSleepDoNotCreateDowntime() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let journal = NetworkJournal(directory: path); journal.alerts = false
        let noReply = PingResult(host: "8.8.8.8", samples: [], lossPercent: 100)
        for i in 0..<4 { journal.ingest(sample(), secondary: noReply, httpReachable: true, date: Date().addingTimeInterval(Double(i))) }
        #expect(journal.events.isEmpty)
        journal.ingest(sample(), secondary: noReply, httpReachable: false)
        journal.suspend()
        journal.ingest(sample(), secondary: noReply, httpReachable: false)
        #expect(journal.events.isEmpty)
    }
    @Test func domainExceptionsRespectHostnameBoundaries() {
        #expect(DomainPolicy.matches("a.track.example", domain: "track.example"))
        #expect(!DomainPolicy.matches("nottrack.example", domain: "track.example"))
        #expect(DomainPolicy.blocked("a.track.example", app: "allowed.app", domains: ["track.example"], exceptions: ["allowed.app": ["track.example"]]) == nil)
        #expect(DomainPolicy.blocked("a.track.example", app: "other.app", domains: ["track.example"], exceptions: ["allowed.app": ["track.example"]]) != nil)
    }
    @Test @MainActor func legacyPreferencesAndTemporaryRuleExpiry() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let old = #"{"profile":"Travel","rules":{},"limitGB":5,"autoHotspot":true,"defaultAllow":false}"#
        try Data(old.utf8).write(to: path.appendingPathComponent("preferences.json"))
        let store = TrafficStore(directory: path, startMonitoring: false)
        #expect(store.preferences.limitGB == 5)
        store.setTemporary("test.app", allowed: true)
        #expect(store.isAllowed("test.app"))
        store.preferences.temporaryRules?["Travel|test.app"] = TemporaryRule(allowed: true, expires: Date.distantPast)
        #expect(!store.isAllowed("test.app"))
        store.preferences.profile = .work
        #expect(!store.isAllowed("test.app"))
    }
    @Test func socketsPreservePIDProtocolAndSeparateConnections() {
        let rows = ExpertTools.parseSockets("p42\ncApp\nf1\nPTCP\nn1.1.1.1:443\nTST=ESTABLISHED\nf2\nPUDP\nn8.8.8.8:53\n")
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.pid == 42 && $0.process == "App" })
        #expect(rows.contains { $0.endpoint == "1.1.1.1:443" && $0.state == "ESTABLISHED" })
    }
    @Test func encryptedDNSProfileRejectsUnsafeSchemesAndHasRollbackPayload() throws {
        #expect(throws: (any Error).self) { try ExpertTools.encryptedDNSProfile(url: "http://example.com/dns-query") }
        let data = try ExpertTools.encryptedDNSProfile(url: "https://dns.example/dns-query")
        let profile = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let content = try #require(profile["PayloadContent"] as? [[String: Any]])
        #expect(content.first?["PayloadType"] as? String == "com.apple.dnsSettings.managed")
    }
}

struct NetworkAccountingTests {
    private func sample(_ name: String) -> DiagnosticSnapshot {
        DiagnosticSnapshot(date: Date(), radio: RadioSample(ssid: name, interface: "en0", rssi: -50, noise: -90, transmitMbps: 100, channel: 1, band: "2.4 GHz"), gateway: "192.168.1.1", router: nil, internet: PingResult(host: "test", samples: [10, 11, 12], lossPercent: 0), dnsMilliseconds: 1, dnsServers: [], captivePortal: false, networkService: "Wi-Fi")
    }
    @Test @MainActor func switchingNetworksPreservesSeparateBudgetsAndResetsCounterBaseline() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let store = TrafficStore(directory: path, startMonitoring: false)
        let home = sample("Home"), hotel = sample("Hotel")
        store.switchNetwork(home); store.preferences.limitGB = 12
        store.received = 100; store.sent = 50; store.rememberNetwork()
        store.switchNetwork(hotel)
        #expect(store.total == 0)
        #expect(store.preferences.limitGB == 5)
        store.received = 20
        store.switchNetwork(home)
        #expect(store.total == 150)
        #expect(store.preferences.limitGB == 12)
        #expect(store.networkSessions[hotel.networkKey]?.received == 20)
        store.resetSession()
        store.switchNetwork(hotel); store.switchNetwork(home)
        #expect(store.total == 0)
    }
    @Test func callReadinessDoesNotHideHighLatencyOrInsufficientBandwidth() {
        let ping = PingResult(host: "test", samples: [400, 450, 500], lossPercent: 0)
        let result = SpeedTestResult(date: Date(), downloadMbps: 20, uploadMbps: 5, baseline: ping, downloadLoaded: ping, uploadLoaded: ping, downloadSeconds: 5, uploadSeconds: 5, transferredBytes: 1_000_000)
        #expect(result.voiceReadiness.contains("may stutter"))
        #expect(result.videoReadiness.contains("1080p"))
        #expect(result.streamingReadiness == "4K bandwidth")
        let slow = SpeedTestResult(date: Date(), downloadMbps: 0.05, uploadMbps: 0.05, baseline: ping, downloadLoaded: ping, uploadLoaded: ping, downloadSeconds: 5, uploadSeconds: 5, transferredBytes: 1000)
        #expect(slow.voiceReadiness == "Low bandwidth")
        #expect(slow.videoReadiness == "Low bandwidth")
    }
}
