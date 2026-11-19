import Foundation
import Testing
import CryptoKit
@testable import KilobatCore

@Suite struct TeamsTests {
    @Test func sanitizerExcludesIdentifiersAndUnknownIsNotZero() throws {
        let radio = RadioSample.basic(bssid: "private-bssid", ssid: "private-ssid", interface: nil, rssi: nil, noise: nil, transmitMbps: nil, channel: nil, band: "private-band")
        let snapshot = DiagnosticSnapshot(date: Date(), radio: radio, gateway: "192.168.1.1", router: nil, internet: PingResult(host: "private-host", samples: [], lossPercent: nil), dnsMilliseconds: nil, dnsServers: ["10.0.0.1"], networkService: "private-service")
        let sample = TeamsHealthSample(snapshot: snapshot, interval: 60, vpn: nil)
        let data = try TeamsJSON.encoder().encode(sample)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("private")); #expect(!json.contains("192.168")); #expect(!json.contains("10.0"))
        #expect(sample.internetLatencyMs == nil && sample.internetLossPercent == nil && sample.dnsLatencyMs == nil)
        #expect(sample.health == "unknown" && sample.vpnState == "unknown")
    }
    @Test func signatureChecksIdentityExpiryAndKey() throws {
        let key = Curve25519.Signing.PrivateKey(); let now = Date()
        let payload = TeamsEntitlement.Claims(schemaVersion: 1, organizationId: "org", deviceId: "mac", issuedAt: now.addingTimeInterval(-60), expiresAt: now.addingTimeInterval(3600), epoch: 2, features: ["teams", "pro"])
        let bytes = try TeamsJSON.encoder().encode(payload)
        func url(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        let envelope = TeamsEntitlement(keyId: "test", payload: url(bytes), signature: url(try key.signature(for: bytes)))
        let keys = ["test": key.publicKey.rawRepresentation]
        #expect(envelope.verified(keys: keys, organization: "org", device: "mac", now: now, lastSeen: now) != nil)
        #expect(envelope.verified(keys: keys, organization: "other", device: "mac", now: now, lastSeen: now) == nil)
        #expect(envelope.verified(keys: [:], organization: "org", device: "mac", now: now, lastSeen: now) == nil)
        #expect(envelope.verified(keys: keys, organization: "org", device: "mac", now: now, lastSeen: now.addingTimeInterval(7200)) == nil)
        #expect(envelope.verified(keys: keys, organization: "org", device: "mac", now: now, lastSeen: now, minimumEpoch: 3) == nil)
    }
    @Test func spoolIsDurableBoundedAndAcknowledgesExactly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = DiagnosticSnapshot(date: Date(), radio: .basic(ssid: nil, interface: nil, rssi: nil, noise: nil, transmitMbps: nil, channel: nil, band: nil), gateway: nil, router: nil, internet: PingResult(host: "secret", samples: [], lossPercent: nil), dnsMilliseconds: nil, dnsServers: [], networkService: nil)
        let sample = TeamsHealthSample(snapshot: snapshot, interval: 60, vpn: nil)
        var spool = TeamsSpool(); try spool.append(sample); spool.sealPending(); try spool.append(sample); spool.sealPending()
        let first = try #require(spool.batches.first?.batchId)
        let url = directory.appendingPathComponent("spool.json"); try spool.save(to: url)
        var restored = try TeamsJSON.decoder().decode(TeamsSpool.self, from: Data(contentsOf: url))
        restored.acknowledge("unknown"); #expect(restored.batches.count == 2)
        restored.acknowledge(first); #expect(restored.batches.count == 1)
        try restored.append(sample, maxBytes: 1); #expect(restored.batches.isEmpty); #expect(restored.droppedSamples == 2)
    }
    @Test func pendingSamplesSealWithoutChangingAttemptedBytes() throws {
        let now = Date()
        let snapshot = DiagnosticSnapshot(date: now, radio: .basic(ssid: nil, interface: nil, rssi: nil, noise: nil, transmitMbps: nil, channel: nil, band: nil), gateway: nil, router: nil, internet: PingResult(host: "secret", samples: [], lossPercent: nil), dnsMilliseconds: nil, dnsServers: [], networkService: nil)
        let sample = TeamsHealthSample(snapshot: snapshot, interval: 60, vpn: nil)
        var spool = TeamsSpool()
        for _ in 0..<4 { try spool.append(sample, now: now) }
        #expect(spool.batches.isEmpty && spool.pending.count == 4)
        try spool.append(sample, now: now)
        let first = try #require(spool.batches.first)
        let bytes = try TeamsJSON.encoder().encode(first)
        try spool.append(sample, now: now)
        #expect(try TeamsJSON.encoder().encode(spool.batches[0]) == bytes)
        #expect(spool.pending.count == 1 && spool.sampleCount == 6)
        spool.sealDue(now: now.addingTimeInterval(301)); #expect(spool.batches.count == 2)
    }
    @Test func userWritableMarkerCannotAuthorizeManagedEnrolment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("installation.json")
        try Data("{\"installation_id\":\"\(UUID().uuidString)\",\"primary_uid\":501}".utf8).write(to: file)
        #expect(throws: (any Error).self) { try TeamsMachineOwnership.load(path: file.path, uid: 501) }
    }
    @Test func ordinaryDefaultsCannotMasqueradeAsMDM() {
        let name = UUID().uuidString; let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("stolen-token", forKey: "TeamToken"); defaults.set(false, forKey: "AutomaticUpdates")
        #expect(TeamsManagedPreferences.string("TeamToken", defaults: defaults) == nil)
        #expect(TeamsManagedPreferences.bool("AutomaticUpdates", defaults: defaults) == nil)
    }
    @Test func lockedBlockWinsOverUnrestrictedAndAllow() {
        var policy = FilterPolicy(); policy.unrestricted = true; policy.rules = ["com.example.app": true]; policy.teamsBlockedApps = ["com.example.app"]
        let flow = FilterPolicy.Flow(app: "com.example.app", process: "Example", host: "example.com")
        #expect(policy.decide(flow).verdict == .block)
        policy.enabled = false
        #expect(policy.decide(flow).verdict == .block)
    }
}
