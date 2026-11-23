import Foundation
import Testing
@testable import KilobatCore

struct WiFiAttentionTests {
    let joinedAt = Date(timeIntervalSince1970: 1_000_000)
    func radio(_ ssid: String? = "Accor") -> RadioSample {
        RadioSample(ssid: ssid, interface: "en0", rssi: -55, noise: -90, transmitMbps: 300, channel: 36, band: "5 GHz")
    }
    func sample(at offset: TimeInterval, ssid: String = "Accor", gateway: String? = "10.0.0.1", replies: [Double] = [], https: Bool? = false) -> DiagnosticSnapshot {
        var value = DiagnosticSnapshot(date: joinedAt.addingTimeInterval(offset), radio: radio(ssid), gateway: gateway, router: nil,
                                       internet: PingResult(host: "1.1.1.1", samples: replies, lossPercent: replies.isEmpty ? 100 : 0),
                                       dnsMilliseconds: nil, dnsServers: [], captivePortal: nil, networkService: "Wi-Fi")
        value.secondary = PingResult(host: "8.8.8.8", samples: replies, lossPercent: replies.isEmpty ? 100 : 0)
        value.httpReachable = replies.isEmpty ? https : nil
        return value
    }
    func judge(_ snapshot: DiagnosticSnapshot?, portal: Bool = false, joining: Bool = false, at offset: TimeInterval) -> WiFiAttention? {
        WiFiAttention.judge(radio: radio(), snapshot: snapshot, portalInTheWay: portal, joining: joining, associatedAt: joinedAt, now: joinedAt.addingTimeInterval(offset))
    }

    @Test func joiningCyclesUntilTheRouterAnswers() {
        #expect(judge(nil, joining: true, at: 0) == .connecting)
        // The check taken before the router's address arrived: still joining, not "no internet".
        #expect(judge(sample(at: 1, gateway: nil), at: 5) == .connecting)
        #expect(judge(sample(at: 6, replies: [12, 13]), at: 8) == nil)
    }

    @Test func theJoinEndsWhenTheRouterGivesAnAddress() {
        func addressed(_ snapshot: DiagnosticSnapshot?, at offset: TimeInterval) -> WiFiAttention? {
            WiFiAttention.judge(radio: radio(), snapshot: snapshot, portalInTheWay: false, joining: false, associatedAt: joinedAt, addressed: true,
                                now: joinedAt.addingTimeInterval(offset))
        }
        // As macOS's icon: the bars stop cycling with the address, before the first check has finished.
        #expect(addressed(nil, at: 3) == nil)
        // A check taken before the address arrived doesn't say there's none, in the join window or after it.
        #expect(addressed(sample(at: 1, gateway: nil), at: 5) == nil)
        #expect(addressed(sample(at: 1, gateway: nil), at: 45) == nil)
        // The first real check still decides.
        #expect(addressed(sample(at: 6), at: 8) == .noInternet)
        // Kilobat's own Join keeps cycling until it returns.
        #expect(WiFiAttention.judge(radio: radio(), snapshot: nil, portalInTheWay: false, joining: true, associatedAt: joinedAt, addressed: true, now: joinedAt) == .connecting)
    }

    @Test @MainActor func aHotspotIsKnownTheMomentItIsJoinedAgain() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-hotspot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let store = TrafficStore(directory: dir, startMonitoring: false, ownsFiles: true)
        // A network never seen: nothing says hotspot until the address is in and macOS calls the connection metered.
        #expect(!store.showsAsHotspot(ssid: "iPhone", addressed: false))
        store.pathChanged(connected: true, expensive: true, kind: "Wi-Fi")
        #expect(!store.showsAsHotspot(ssid: "iPhone", addressed: false))
        #expect(store.showsAsHotspot(ssid: "iPhone", addressed: true))
        // Its first check: the store is on it, and remembers it.
        store.switchNetwork(sample(at: 6, ssid: "iPhone", replies: [20]))
        #expect(store.showsAsHotspot(ssid: "iPhone", addressed: true))
        // Home Wi-Fi, then the hotspot again: known before any address or check.
        store.pathChanged(connected: true, expensive: false, kind: "Wi-Fi")
        store.switchNetwork(sample(at: 60, ssid: "Home", replies: [8]))
        #expect(!store.showsAsHotspot(ssid: "Home", addressed: true))
        #expect(store.showsAsHotspot(ssid: "iPhone", addressed: false))
        #expect(TrafficStore(directory: dir, startMonitoring: false).hotspotNames == ["iPhone"])
        #expect(!store.showsAsHotspot(ssid: nil, addressed: true))
    }

    @Test func noAddressOnceTheJoinWindowPasses() {
        #expect(judge(sample(at: 1, gateway: nil), at: 45) == .noAddress)
    }

    @Test func noInternetOnlyWhenEveryProbeFailed() {
        #expect(judge(sample(at: 6), at: 8) == .noInternet)
        // HTTPS not tried: one silent ping target alone isn't an outage.
        #expect(judge(sample(at: 6, https: nil), at: 8) == nil)
    }

    @Test func signInPageWinsOverEverythingElse() {
        #expect(judge(sample(at: 6), portal: true, at: 8) == .signIn)
        // The portal status belongs to a check on this network, after joining.
        #expect(judge(sample(at: -60), portal: true, at: 40) == nil)
    }

    @Test func checksFromAnotherNetworkDontCount() {
        #expect(judge(sample(at: 6, ssid: "Biwako"), at: 40) == nil)
        #expect(WiFiAttention.judge(radio: RadioSample(ssid: nil, interface: "en0", rssi: nil, noise: nil, transmitMbps: nil, channel: nil, band: nil),
                                    snapshot: sample(at: 6), portalInTheWay: true, joining: true, associatedAt: joinedAt, now: joinedAt) == nil)
    }

    @Test func aJoinIsANewNetworkOrSignalAfterNone() {
        let off = RadioSample(ssid: nil, interface: "en0", rssi: nil, noise: nil, transmitMbps: nil, channel: nil, band: nil)
        #expect(DiagnosticStore.newlyJoined(radio(), after: off))
        #expect(DiagnosticStore.newlyJoined(radio("Biwako"), after: radio()))
        #expect(!DiagnosticStore.newlyJoined(radio(), after: radio()))
        #expect(!DiagnosticStore.newlyJoined(off, after: radio()))
    }
}
