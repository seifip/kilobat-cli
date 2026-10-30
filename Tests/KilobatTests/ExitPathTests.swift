import Foundation
import Testing
@testable import KilobatCore

/// Where traffic leaves (VPN and public IP), speed-test comparisons, route history and the iperf3 reader.
struct ExitPathTests {
    // MARK: Exit path

    @Test func connectedVPNsComeOnlyFromConnectedServices() {
        let output = """
        Available network connection services in the current set (*=enabled):
        * (Disconnected)   B536B234-5CEB-4D51-AF26-B6F741235B8E VPN (io.tailscale.ipn.macsys) "Tailscale"                      [VPN:io.tailscale.ipn.macsys]
        * (Connected)      1F2E3D4C-0000-1111-2222-333344445555 VPN (com.wireguard.macos) "Office WireGuard"              [VPN:com.wireguard.macos]
          (Connecting)     99999999-0000-1111-2222-333344445555 IPSec              "Lab IKEv2"                           [IPSec]
        """
        #expect(ExitPath.connectedVPNs(output) == ["Office WireGuard"])
        #expect(ExitPath.connectedVPNs("No services") == [])
    }

    @Test func vpnStateFollowsTheDefaultRouteNotJustAConnectedService() {
        let full = ExitPath(interface: "utun3", connected: ["Office WireGuard"])
        #expect(full.vpn == .full && full.tunnel && full.vpnName == "Office WireGuard")
        #expect(full.interfaceLabel == "utun3 (Office WireGuard)")
        // Tailscale without an exit node: connected, but the default route stays on Wi-Fi.
        let split = ExitPath(interface: "en0", connected: ["Tailscale"])
        #expect(split.vpn == .partial && !split.tunnel)
        #expect(split.summary.contains("only some destinations"))
        #expect(split.badge == "Split")
        // A tunnel macOS doesn't list (wg-quick, a TUN-mode proxy) is still a tunnel, unnamed.
        let unnamed = ExitPath(interface: "utun5")
        #expect(unnamed.vpn == .full && unnamed.vpnName == nil && unnamed.interfaceLabel == "utun5 (a VPN or tunnel)")
        // Several connected: which one carries the route isn't known, so none is named.
        #expect(ExitPath(interface: "utun3", connected: ["A", "B"]).vpnName == nil)
        #expect(ExitPath(interface: "en0").vpn == .off)
        #expect(ExitPath(interface: nil).summary.hasPrefix("No default route"))
    }

    @Test func summaryStatesTheRegistryCountryWithoutClaimingPrivacy() {
        var path = ExitPath(interface: "utun3", connected: ["WireGuard"])
        path.publicAddress = .init(address: "203.0.113.9", country: "DE")
        #expect(path.summary.hasPrefix("Traffic leaves through utun3 (WireGuard) · exit IP in "))
        let ports = ExitPath.hardwarePorts("Hardware Port: Wi-Fi\nDevice: en0\nEthernet Address: aa\n\nHardware Port: Thunderbolt Ethernet\nDevice: en5\n")
        #expect(ports == ["en0": "Wi-Fi", "en5": "Thunderbolt Ethernet"])
        #expect(ExitPath(interface: "en0", port: "Wi-Fi").summary == "Traffic leaves through Wi-Fi (en0)")
        #expect(ExitPath(interface: "en3", port: "Ethernet Adapter (en3)").interfaceLabel == "Ethernet Adapter (en3)")
        #expect(path.summary.hasSuffix("(registry data)"))
        #expect(path.badge == "On DE")
        for text in [path.summary, ExitPath.registryNote, ExitPath.lookupNote] {
            #expect(!text.lowercased().contains("you are private") && !text.lowercased().contains("protected"))
        }
        #expect(ExitPath.registryNote.contains("not where you"))
        #expect(ExitPath.lookupNote.contains("Cloudflare sees that request"))
    }

    @Test func cloudflareTraceGivesOnlyAValidAddress() {
        let trace = "fl=123f45\nh=www.cloudflare.com\nip=203.0.113.9\nts=1730000000.1\nloc=DE\nwarp=off\n"
        #expect(ExitPath.traceAddress(trace) == "203.0.113.9")
        #expect(ExitPath.traceAddress("ip=2001:db8::1\n") == "2001:db8::1")
        #expect(ExitPath.traceAddress("ip=<script>\n") == nil)
        #expect(ExitPath.traceAddress("<html>blocked</html>") == nil)
    }

    @Test func changesLogVPNAndAddressChangesOnly() {
        let off = ExitPath(interface: "en0")
        let on = ExitPath(interface: "utun3", connected: ["WireGuard"])
        #expect(on.changes(since: nil).isEmpty)
        #expect(on.changes(since: off).map(\.kind) == ["VPN on"])
        #expect(off.changes(since: on).map(\.kind) == ["VPN off"])
        #expect(off.changes(since: on).first?.detail.contains("WireGuard is no longer connected") == true)
        var before = off, after = off
        before.publicAddress = .init(address: "198.51.100.1", country: nil)
        after.publicAddress = .init(address: "198.51.100.2", country: nil)
        #expect(after.changes(since: before).map(\.kind) == ["Public IP changed"])
        #expect(before.changes(since: before).isEmpty)
        // Without a lookup on both sides there's nothing to compare.
        #expect(off.changes(since: before).isEmpty)
    }

    @Test func publicLookupNeverRunsUnaskedAndRepeatsOnChanges() {
        let now = Date()
        var looked = ExitPath(interface: "en0")
        looked.publicAddress = .init(address: "198.51.100.1", country: nil, date: now.addingTimeInterval(-60))
        let same = ExitPath(interface: "en0")
        #expect(!ExitPath.lookupDue(enabled: false, previous: nil, current: same, network: "a", previousNetwork: nil))
        #expect(!ExitPath.lookupDue(enabled: true, previous: nil, current: ExitPath(interface: nil), network: "a", previousNetwork: nil))
        #expect(ExitPath.lookupDue(enabled: true, previous: nil, current: same, network: "a", previousNetwork: nil))
        #expect(!ExitPath.lookupDue(enabled: true, previous: looked, current: same, network: "a", previousNetwork: "a", now: now))
        #expect(ExitPath.lookupDue(enabled: true, previous: looked, current: ExitPath(interface: "utun3"), network: "a", previousNetwork: "a", now: now))
        #expect(ExitPath.lookupDue(enabled: true, previous: looked, current: same, network: "b", previousNetwork: "a", now: now))
        #expect(ExitPath.lookupDue(enabled: true, previous: looked, current: same, network: "a", previousNetwork: "a", now: now.addingTimeInterval(1800)))
    }

    // MARK: Speed tests

    private func test(_ date: Date, network: String = "Home", down: Double = 100, up: Double = 20, ping: Double = 20, streams: Int? = 1,
                      server: String? = "Cloudflare FRA", context: SpeedTestContext? = SpeedTestContext(interface: "en0", kind: "Wi-Fi", band: "5 GHz", rssi: -55, otherBytes: 0)) -> SavedSpeedTest {
        let baseline = PingResult(host: "1.1.1.1", samples: [ping, ping, ping], lossPercent: 0)
        var result = SpeedTestResult(date: date, downloadMbps: down, uploadMbps: up, baseline: baseline, downloadLoaded: baseline, uploadLoaded: baseline,
                                     downloadSeconds: 8, uploadSeconds: 8, transferredBytes: 60_000_000)
        result.streams = streams; result.server = server; result.context = context
        return SavedSpeedTest(networkKey: network, networkName: network, result: result)
    }

    @Test func comparisonListsWhatDifferedEarlierTestFirst() {
        let morning = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
        let a = test(morning)
        let b = test(morning.addingTimeInterval(3600), down: 300, streams: 4, server: "Cloudflare AMS",
                     context: SpeedTestContext(interface: "utun3", kind: "VPN", vpn: "WireGuard", band: "2.4 GHz", rssi: -70, otherBytes: 40_000_000))
        let comparison = SpeedComparison(b, a)
        #expect(comparison.first.id == a.id && comparison.second.id == b.id)
        #expect(comparison.downloadChangePercent == 200)
        let factors = comparison.differences.map(\.factor)
        #expect(factors == ["server", "method", "connection", "vpn", "band", "signal", "otherTraffic"])
        #expect(comparison.differences.first { $0.factor == "vpn" }?.second == "WireGuard")
        #expect(comparison.summary.contains("What differed: server, number of connections"))
        #expect(comparison.unknown.isEmpty)
        #expect(comparison.text.contains("method: 1 connection → 4 connections."))
    }

    @Test func comparisonOfLikeTestsBlamesNothingItCannotSee() {
        let start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        let comparison = SpeedComparison(test(start), test(start.addingTimeInterval(600), down: 60))
        #expect(comparison.differences.isEmpty)
        #expect(comparison.summary.contains("Nothing Kilobat records differed"))
        #expect(comparison.summary.contains("other devices on the network"))
    }

    @Test func olderTestsSayWhatWasNotRecorded() {
        let start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        let comparison = SpeedComparison(test(start, streams: nil, server: nil, context: nil), test(start.addingTimeInterval(600)))
        #expect(comparison.unknown.contains("server") && comparison.unknown.contains("VPN"))
        #expect(!comparison.differences.contains { $0.factor == "method" })
    }

    @Test func eveningAndNetworkDifferencesAreNamed() {
        let morning = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        let evening = Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: Date())!
        let factors = SpeedComparison(test(morning), test(evening, network: "Café")).differences.map(\.factor)
        #expect(factors.prefix(2) == ["network", "time"])
    }

    @Test func testsAreFoundByPlaceOrIdPrefix() {
        let older = test(Date().addingTimeInterval(-600)), newer = test(Date())
        let tests = [older, newer]
        #expect(SpeedComparison.find("1", in: tests)?.id == newer.id)
        #expect(SpeedComparison.find("2", in: tests)?.id == older.id)
        #expect(SpeedComparison.find("3", in: tests) == nil)
        #expect(SpeedComparison.find(String(older.id.uuidString.prefix(8)), in: tests)?.id == older.id)
        #expect(SpeedComparison.find("ab", in: tests) == nil)
        #expect(SpeedComparison.latestPair(tests).map { [$0.0.id, $0.1.id] } == [older.id, newer.id])
        #expect(SpeedComparison.latestPair([newer]) == nil)
    }

    @Test func savedTestsFromEarlierVersionsStillDecode() throws {
        let baseline = PingResult(host: "1.1.1.1", samples: [10], lossPercent: 0)
        let old = SpeedTestResult(date: Date(timeIntervalSince1970: 0), downloadMbps: 1, uploadMbps: 1, baseline: baseline, downloadLoaded: baseline, uploadLoaded: baseline,
                                  downloadSeconds: 1, uploadSeconds: 1, transferredBytes: 1)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json.removeValue(forKey: "streams"); json.removeValue(forKey: "server"); json.removeValue(forKey: "context")
        let decoded = try JSONDecoder().decode(SpeedTestResult.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.streams == nil && decoded.context == nil && decoded.downloadMbps == 1)
    }

    @Test func speedTestServerAndOtherTraffic() {
        #expect(SpeedTest.dataCenter("8a1b2c3d4e5f6789-FRA") == "FRA")
        #expect(SpeedTest.dataCenter("8a1b2c3d4e5f6789") == nil)
        #expect(SpeedTest.dataCenter("abc-12") == nil)
        let before = ["en0": ByteCount(received: 1_000, sent: 1_000), "utun3": ByteCount(received: 0, sent: 0), "lo0": ByteCount()]
        let after = ["en0": ByteCount(received: 61_000_000, sent: 21_000_000), "utun3": ByteCount(received: 60_000_000, sent: 20_000_000), "lo0": ByteCount(received: 5_000_000, sent: 5_000_000)]
        // The tunnel and loopback aren't counted, so a VPN's bytes aren't counted twice.
        #expect(SpeedTest.otherBytes(before: before, after: after, test: 80_000_000) == 1_998_000)
        #expect(SpeedTest.otherBytes(before: before, after: before, test: 10) == 0)
        #expect(SpeedTest.method(streams: 4).hasPrefix("4 HTTPS connections at once"))
        #expect(SpeedTest.method(streams: nil).hasPrefix("One HTTPS connection"))
    }

    @Test func contextNamesTheLinkFromTheRouteAndRadio() {
        let radio = RadioSample(ssid: "Home", interface: "en0", rssi: -60, noise: -92, transmitMbps: 866, channel: 36, band: "5 GHz")
        let wifi = SpeedTestContext(exit: ExitPath(interface: "en0"), radio: radio)
        #expect(wifi.kind == "Wi-Fi" && wifi.band == "5 GHz" && wifi.vpn == nil)
        let vpn = SpeedTestContext(exit: ExitPath(interface: "utun3", connected: ["WireGuard"]), radio: radio)
        #expect(vpn.kind == "VPN" && vpn.vpn == "WireGuard" && vpn.rssi == -60)
        let wired = SpeedTestContext(exit: ExitPath(interface: "en7"), radio: RadioSample(ssid: nil, interface: nil, rssi: nil, noise: nil, transmitMbps: nil, channel: nil, band: nil))
        #expect(wired.kind == "Ethernet" && wired.band == nil)
    }

    // MARK: Routes

    /// Real `traceroute -n -q 3` output: load-balanced hops on continuation lines and a star before an address.
    static let trace = """
    traceroute to 1.1.1.1 (1.1.1.1), 12 hops max, 40 byte packets
     1  192.168.1.254  3.583 ms  4.643 ms  5.405 ms
     2  196.70.120.1  20.620 ms  18.727 ms  45.089 ms
     3  81.192.92.210  28.033 ms
        81.192.92.206  43.741 ms
        81.192.92.210  29.097 ms
     4  * * *
     5  * 84.16.6.50  66.480 ms  54.911 ms

    Intermediate routers may ignore probes; * alone is not evidence of packet loss.
    """

    @Test func traceroutesParseHopByHop() {
        let hops = RouteTrace.parse(Self.trace)
        #expect(hops.map(\.ttl) == [1, 2, 3, 4, 5])
        #expect(hops[0].samples == [3.583, 4.643, 5.405] && hops[0].probes == 3)
        #expect(hops[2].addresses == ["81.192.92.210", "81.192.92.206"] && hops[2].samples.count == 3)
        #expect(hops[3].addresses.isEmpty && hops[3].probes == 3 && hops[3].samples.isEmpty)
        #expect(hops[4].addresses == ["84.16.6.50"] && hops[4].probes == 3 && hops[4].samples.count == 2)
        #expect(RouteTrace.parse("traceroute: unknown host nowhere.invalid").isEmpty)
        #expect(RouteTrace.parse("Automatic outage trace\n" + Self.trace).count == 5)
    }

    @Test func historyFindsWhereDelayStartsAndRouteChanges() {
        let earlier = SavedRoute(date: Date(timeIntervalSince1970: 0), host: "example.com", output: """
         1  192.168.1.1  2 ms  2 ms  2 ms
         2  10.0.0.1  10 ms  11 ms  12 ms
         3  203.0.113.5  80 ms  82 ms  81 ms
         4  198.51.100.7  85 ms  84 ms  86 ms
        """)
        let later = SavedRoute(date: Date(timeIntervalSince1970: 60), host: "example.com", output: """
         1  192.168.1.1  2 ms  3 ms  2 ms
         2  10.0.0.2  11 ms  12 ms  10 ms
         3  203.0.113.5  79 ms  83 ms  80 ms
         4  198.51.100.7  84 ms  86 ms  85 ms
        """)
        let other = SavedRoute(date: Date(timeIntervalSince1970: 30), host: "other.com", output: " 1  192.168.1.1  2 ms")
        let history = RouteHistory(host: "example.com", routes: [later, other, earlier])
        #expect(history.runs == 2 && history.hops.count == 4)
        #expect(history.hops[1].changed && !history.hops[0].changed)
        #expect(history.pathChanges == 1)
        #expect(history.hops[0].replies == 6 && history.hops[0].lossPercent == 0)
        #expect(history.verdict.contains("hop 3 (203.0.113.5)"))
        #expect(history.text.contains("route changed 1 time"))
        #expect(RouteHistory.hosts([earlier, other, later]) == ["example.com", "other.com"])
    }

    @Test func skippedRepliesBeforeAnAnsweringHopAreNotLoss() {
        let route = SavedRoute(date: Date(), host: "1.1.1.1", output: """
         1  192.168.1.1  2 ms  2 ms  2 ms
         2  * * *
         3  10.0.0.9  * 12 ms *
         4  1.1.1.1  13 ms  12 ms  14 ms
        """)
        let history = RouteHistory(host: "1.1.1.1", routes: [route])
        #expect(history.hops[2].lossPercent > 60)
        #expect(history.verdict.contains("rate-limiting probes, not loss"))
        #expect(RouteHistory(host: "nowhere", routes: [route]).verdict == "No saved traces to this host.")
    }

    // MARK: LAN

    @Test func iperfResultsReadAsMbps() throws {
        let json = """
        {"start":{"test_start":{"num_streams":1,"duration":5}},
         "end":{"sum_sent":{"seconds":5.0,"bytes":580000000,"bits_per_second":928000000,"retransmits":12},
                "sum_received":{"seconds":5.01,"bytes":578000000,"bits_per_second":923000000}}}
        """
        let result = try LANTestResult.parse(Data(json.utf8), host: "nas.local", reverse: false)
        #expect(result.direction == "upload" && result.streams == 1 && result.retransmits == 12)
        #expect(result.receivedMbps == 923 && result.sentMbps == 928)
        #expect(result.summary.hasPrefix("This Mac → nas.local: 923 Mbps"))
        #expect(result.summary.contains("not your internet connection"))
        #expect(throws: DiagnosticError.self) { try LANTestResult.parse(Data(#"{"error":"unable to connect to server: Connection refused"}"#.utf8), host: "x", reverse: true) }
        #expect(throws: DiagnosticError.self) { try LANTestResult.parse(Data("not json".utf8), host: "x", reverse: true) }
        #expect(ExpertTools.iperf3(path: "/nonexistent") == nil || FileManager.default.isExecutableFile(atPath: ExpertTools.iperf3(path: "/nonexistent")!))
    }
}
