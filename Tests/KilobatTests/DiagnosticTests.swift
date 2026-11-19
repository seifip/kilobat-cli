import Foundation
import Testing
@testable import KilobatCore

struct DiagnosticTests {
    @Test func strongBandwidthStillExplainsUnstablePing() {
        let baseline = PingResult(host: "test", samples: [89.458, 26.727, 108.511, 26.697, 104.289], lossPercent: 0)
        let loaded = PingResult(host: "test", samples: [30, 31, 29], lossPercent: nil)
        let result = SpeedTestResult(date: Date(), downloadMbps: 32.8, uploadMbps: 41.4, baseline: baseline, downloadLoaded: loaded, uploadLoaded: loaded, downloadSeconds: 8, uploadSeconds: 3, transferredBytes: 1000)
        #expect(result.videoReadiness.contains("may stutter"))
        #expect(result.callCautionReasons == ["Variable ping (76 ms jitter)"])
        #expect(result.streamingReadiness == "4K bandwidth")
        // The app's one scale: the jitter that makes calls stutter is the Calls row's reason, beside its grade.
        let line = RealtimeLine(speed: result, ping: nil)
        #expect(line.grade(.calls) == RealtimeGrade(.fair, "Variable ping (76 ms jitter)"))
        #expect(line.grade(.gaming)?.level == result.gamingLevel)
        #expect(line.grade(.agents)?.level == result.agentLevel)
        #expect(line.grade(.streaming) == RealtimeGrade(.good, "Watch in 4K"))
    }

    @Test func realtimeGradesPreferLivePingAndNameWhatDecidedThem() {
        let steady = PingResult(host: "test", samples: [20, 21, 19, 20, 20], lossPercent: 0)
        let speed = SpeedTestResult(date: Date(), downloadMbps: 30, uploadMbps: 10, baseline: steady, downloadLoaded: steady, uploadLoaded: steady,
                                    downloadSeconds: 8, uploadSeconds: 8, transferredBytes: 1000)
        let idle = RealtimeLine(speed: speed, ping: nil)
        #expect(idle.grade(.calls) == RealtimeGrade(.good, "1080p video"))
        #expect(idle.grade(.gaming) == RealtimeGrade(.good, "Competitive · 20 ms ping"))
        #expect(idle.grade(.cloudGaming) == RealtimeGrade(.good, "1080p · 30 Mbps download"))
        #expect(idle.grade(.remote) == RealtimeGrade(.good, "Typing echoes in 20 ms"))
        // OBS set up: the upload against its bitrate plus 30% headroom (6,000 kbps needs 7.8 Mbps).
        #expect(idle.grade(.streaming, obs: true, bitrate: 6_000)?.level == .good)
        #expect(idle.grade(.streaming, obs: true, bitrate: 9_000)?.level == .fair)
        #expect(idle.grade(.streaming, obs: true, bitrate: 12_000)?.level == .poor)
        #expect(idle.grade(.streaming, obs: true)?.reason == "Go live at up to 7,600 kbps")

        // A slower live ping replaces the test's idle one; the bandwidth stays the test's.
        let live = RealtimeLine(speed: speed, ping: PingResult(host: "1.1.1.1", samples: [70, 72, 68, 70], lossPercent: 0))
        #expect(live.latency == 70)
        #expect(live.grade(.gaming) == RealtimeGrade(.fair, "Casual · 70 ms ping"))
        #expect(live.grade(.cloudGaming) == RealtimeGrade(.fair, "70 ms ping"))
        // Too few replies isn't a reading.
        #expect(RealtimeLine(speed: speed, ping: PingResult(host: "1.1.1.1", samples: [300], lossPercent: 75)).latency == 20)

        // Without a speed test, only what ping can judge.
        let pingOnly = RealtimeLine(speed: nil, ping: steady)
        #expect(pingOnly.grade(.calls) == nil)
        #expect(pingOnly.grade(.cloudGaming) == nil)
        #expect(pingOnly.grade(.gaming)?.level == .good)
        #expect(RealtimeLine(speed: nil, ping: nil).grade(.gaming) == nil)

        let lossy = RealtimeLine(latency: 30, jitter: 5, loss: 3, down: 50, up: 20)
        #expect(lossy.grade(.gaming) == RealtimeGrade(.poor, "Laggy · 3.0% loss"))
        #expect(lossy.grade(.calls)?.level == .fair)
        #expect(RealtimeLine(latency: 20, jitter: 2, loss: 0, down: 0.05, up: 0.05).grade(.calls)?.level == .poor)
    }

    @Test func pingKeepsLossAndComputesConsecutiveJitter() {
        let output = "64 bytes from 1.1.1.1: icmp_seq=0 ttl=56 time=20.1 ms\n64 bytes from 1.1.1.1: icmp_seq=1 ttl=56 time=25.1 ms\n4 packets transmitted, 2 packets received, 50.0% packet loss"
        let ping = DiagnosticProbe.parsePing(output, host: "1.1.1.1")
        #expect(ping.samples == [20.1, 25.1])
        #expect(ping.lossPercent == 50)
        #expect(ping.average == 22.6)
        #expect(ping.jitter == 5)
        #expect(DiagnosticProbe.parsePing("Request timeout", host: "example").average == nil)
    }
    @Test func serviceNameMatchesInterfaceWithoutGuessingServiceLabel() {
        let output = "(1) USB 10/100/1000 LAN\n(Hardware Port: USB 10/100/1000 LAN, Device: en5)\n(2) My Wi-Fi 'Network'\n(Hardware Port: Wi-Fi, Device: en0)\n"
        #expect(DiagnosticProbe.serviceName(output, interface: "en0") == "My Wi-Fi 'Network'")
        #expect(DiagnosticProbe.serviceName(output, interface: "en6") == nil)
    }
    /// The network key names every network's history, budgets and profiles. These literals never change: a failure here
    /// means something that feeds the key changed, and history would be filed under a new network.
    @Test func networkKeysAreStable() {
        func wifi(_ ssid: String?) -> RadioSample { RadioSample(ssid: ssid, interface: "en0", rssi: -50, noise: -90, transmitMbps: 100, channel: 1, band: "2.4 GHz") }
        let noReply = PingResult(host: "1.1.1.1", samples: [], lossPercent: 100)
        func sample(_ radio: RadioSample, gateway: String?, service: String?, wired: String? = nil, physical: String? = nil, mac: String? = nil, tunneled: Bool? = nil) -> DiagnosticSnapshot {
            DiagnosticSnapshot(date: Date(), radio: radio, gateway: gateway, router: nil, internet: noReply, dnsMilliseconds: 5, dnsServers: [], captivePortal: false,
                               networkService: service, wiredInterface: wired, physicalGateway: physical, gatewayMAC: mac, tunneledRoute: tunneled)
        }
        #expect(sample(wifi("Home"), gateway: "192.168.1.1", service: "Wi-Fi").networkKey == "eb24eee989ebdded0aa402e5")
        #expect(sample(wifi("Home"), gateway: "192.168.0.1", service: "Wi-Fi").networkKey == "96494283f7846e53b9667263")
        #expect(sample(wifi(nil), gateway: "192.168.1.1", service: "Wi-Fi").networkKey == "unknown")
        #expect(sample(wifi("Home"), gateway: "192.168.1.1", service: "USB 10/100/1000 LAN", wired: "en7", physical: "192.168.1.1", mac: "aa:bb:cc:dd:ee:ff").networkKey == "62f1f5816e2cc907b9c581b7")
        #expect(sample(wifi("Home"), gateway: "192.168.1.1", service: "USB 10/100/1000 LAN", wired: "en7", physical: "192.168.1.1").networkKey == "unknown")
        // Behind a tunnel the physical router names the network, the same as without the tunnel.
        #expect(sample(wifi("Home"), gateway: "10.64.0.1", service: "Wi-Fi", physical: "192.168.1.1", tunneled: true).networkKey == "eb24eee989ebdded0aa402e5")
    }
    @Test func routeAndResolverParsersAreStable() {
        let normal = """
           route to: default
        destination: default
               mask: default
            gateway: 192.0.2.1
          interface: en0
              flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
         recvpipe  sendpipe  ssthresh  rtt,msec    rttvar  hopcount      mtu     expire
               0         0         0         0         0         0      1500         0
        """
        let route = DiagnosticProbe.parseRoute(normal)
        #expect(route.gateway == "192.0.2.1" && route.interface == "en0")
        let tunnel = DiagnosticProbe.parseRoute("""
           route to: default
        destination: default
               mask: default
          interface: utun4
              flags: <UP,DONE,CLONING,STATIC,GLOBAL>
        """)
        #expect(tunnel.gateway == nil && tunnel.interface == "utun4")
        let missing = DiagnosticProbe.parseRoute("route: writing to routing socket: not in table")
        #expect(missing.gateway == nil && missing.interface == nil)
        let scutil = """
        DNS configuration

        resolver #1
          nameserver[0] : 192.0.2.53
          nameserver[1] : 1.1.1.1
          flags    : Request A records, Request AAAA records

        resolver #2
          domain   : local
          options  : mdns

        resolver #3
          domain   : corp.example
          nameserver[0] : 198.51.100.7

        DNS configuration (for scoped queries)

        resolver #1
          nameserver[0] : 192.0.2.53
          nameserver[1] : 1.1.1.1
          if_index : 11 (en0)
          flags    : Scoped, Request A records, Request AAAA records
        """
        #expect(DiagnosticProbe.parseResolvers(scutil) == ["1.1.1.1", "192.0.2.53", "198.51.100.7"])
        #expect(DiagnosticProbe.parseResolvers("No DNS configuration available") == [])
    }
    @Test func dnsArgumentsAreShellQuoted() {
        #expect(DNSService.shellQuote("a'b") == "'a'\\''b'")
        #expect(DNSService.shellQuote("Wi-Fi $(echo bad)") == "'Wi-Fi $(echo bad)'")
    }
    @Test func switchingDNSUsesTheOneResolverList() {
        #expect(DNSService.arguments(.network) == ["Empty"])
        #expect(DNSService.arguments(.cloudflare) == ["1.1.1.1", "1.0.0.1"])
        #expect(DNSService.arguments(DNSResolverChoice.custom("94.140.14.14")!) == ["94.140.14.14"])
        // The command line's names still work: automatic is Network DNS.
        #expect(DNSResolverChoice.named("automatic") == .network)
        #expect(DNSResolverChoice.named("Quad9") == .quad9)
    }
    @Test func dnsBenchmarkTimesTheResolversFastestDNSTimes() {
        #expect(ResolverBenchmark.resolvers(DNSResolverChoice.candidates(excluded: [], extra: [])) == ["System", "1.1.1.1", "9.9.9.9", "8.8.8.8"])
        // One left out in Settings isn't timed; one added there is.
        #expect(ResolverBenchmark.resolvers(DNSResolverChoice.candidates(excluded: ["google"], extra: ["94.140.14.14"])) == ["System", "1.1.1.1", "9.9.9.9", "94.140.14.14"])
    }
    @Test func channelOverlapWeightsNearbyStrongNetworks() {
        let network = NearbyNetwork(id: "a", ssid: "a", rssi: -40, noise: -90, channel: 1, band: "2.4 GHz", widthMHz: 20)
        #expect(DiagnosticProbe.congestion(channel: 1, band: "2.4 GHz", networks: [network]) > 0)
        #expect(DiagnosticProbe.congestion(channel: 6, band: "2.4 GHz", networks: [network]) == 0)
        #expect(DiagnosticProbe.congestion(channel: 1, band: "5 GHz", networks: [network]) == 0)
    }
    @MainActor @Test func placeCardUsesTheNewestCompleteTestOnThisNetwork() {
        let journal = NetworkJournal(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let ping = PingResult(host: "test", samples: [20, 21, 22], lossPercent: 0)
        func test(_ mbps: Double) -> SpeedTestResult {
            SpeedTestResult(date: Date(), downloadMbps: mbps, uploadMbps: mbps, baseline: ping, downloadLoaded: ping, uploadLoaded: ping, downloadSeconds: 8, uploadSeconds: 8, transferredBytes: 1000)
        }
        journal.speedTests = [SavedSpeedTest(networkKey: "cafe", networkName: "Cafe", result: test(40)),
                              SavedSpeedTest(networkKey: "cafe", networkName: "Cafe", networkChanged: true, result: test(90)),
                              SavedSpeedTest(networkKey: "home", networkName: "Home", result: test(300))]
        #expect(journal.latestSpeedTest(onNetwork: "cafe")?.downloadMbps == 40)
        #expect(journal.latestSpeedTest(onNetwork: "hotel") == nil)
        #expect(journal.latestSpeedTest(onNetwork: "unknown") == nil)
        #expect(journal.latestSpeedTest(onNetwork: nil) == nil)
    }
    @Test func shortSpeedTestsDoNotClaimBufferbloatGrade() {
        let ping = PingResult(host: "test", samples: [10], lossPercent: 0)
        let loaded = PingResult(host: "test", samples: [100], lossPercent: 0)
        let result = SpeedTestResult(date: Date(), downloadMbps: 100, uploadMbps: 100, baseline: ping, downloadLoaded: loaded, uploadLoaded: loaded, downloadSeconds: 0.5, uploadSeconds: 0.5, transferredBytes: 1000)
        #expect(result.bufferbloat == "Inconclusive")
        #expect(result.addedLatency == nil)
    }
    @Test func unreliableIdleLatencyDoesNotProduceBufferbloatGrade() {
        let baseline = PingResult(host: "test", samples: [10, 11, 9], lossPercent: 40)
        let loaded = PingResult(host: "test", samples: [100, 120, 110], lossPercent: nil)
        let result = SpeedTestResult(date: Date(), downloadMbps: 10, uploadMbps: 10, baseline: baseline, downloadLoaded: loaded, uploadLoaded: loaded, downloadSeconds: 5, uploadSeconds: 5, transferredBytes: 1000)
        #expect(result.bufferbloat == "Inconclusive")
    }
    @Test func missingRadioIsUnknownAndScoresAreBounded() {
        let sample = RadioSample(ssid: nil, interface: nil, rssi: nil, noise: nil, transmitMbps: nil, channel: nil, band: nil)
        #expect(sample.score == nil)
        #expect(sample.health == .unknown)
        let strong = RadioSample(ssid: "test", interface: "en0", rssi: -20, noise: -90, transmitMbps: 100, channel: 1, band: "2.4 GHz")
        #expect(strong.score == 100)
        #expect(strong.snr == 70)
    }
    @Test func linkDetailsNameTheStandardSecurityAndPower() {
        #expect(WiFiLink.standard(phyMode: 6, band: "5 GHz")! == ("Wi-Fi 6", "802.11ax"))
        #expect(WiFiLink.standard(phyMode: 6, band: "6 GHz")!.name == "Wi-Fi 6E")
        #expect(WiFiLink.standard(phyMode: 7, band: "6 GHz")!.name == "Wi-Fi 7")
        #expect(WiFiLink.standard(phyMode: 3, band: "2.4 GHz")! == ("802.11g", "802.11g"))
        #expect(WiFiLink.standard(phyMode: 0, band: nil) == nil)
        #expect(WiFiLink.standard(phyMode: nil, band: "5 GHz") == nil)
        #expect(WiFiLink.security(11)?.level == .strong)
        #expect(WiFiLink.security(4)?.name == "WPA2 Personal")
        #expect(WiFiLink.security(4)?.note == nil)
        #expect(WiFiLink.security(0)?.level == .open)
        #expect(WiFiLink.security(0)?.note != nil)
        #expect(WiFiLink.security(1)?.level == .weak)
        #expect(WiFiLink.security(2)?.level == .weak)
        #expect(WiFiLink.security(3)?.level == .weak)
        #expect(WiFiLink.security(8)?.level == .weak)
        #expect(WiFiLink.security(14)?.level == .strong)
        #expect(WiFiLink.security(Int.max) == nil)
        #expect(WiFiLink.dBm(milliwatts: 100) == 20)
        #expect(WiFiLink.dBm(milliwatts: 0) == nil)
        #expect(WiFiLink.dBm(milliwatts: 50) == 17)
        var radio = RadioSample(ssid: "Home", interface: "en0", rssi: -50, noise: -90, transmitMbps: 1200, channel: 37, band: "6 GHz")
        radio.security = "WEP"
        #expect(radio.securityInfo?.level == .weak)
        #expect(WiFiLink.security(named: "WPA3 Personal")?.level == .strong)
        #expect(WiFiLink.security(named: "Something new") == nil)
    }
    @Test func nearbyNetworkSecurityIsTheStrongestOffered() {
        #expect(WiFiLink.strongest(supported: [11, 4]) == 13)
        #expect(WiFiLink.strongest(supported: [11]) == 11)
        #expect(WiFiLink.strongest(supported: [4, 3, 2]) == 4)
        #expect(WiFiLink.strongest(supported: [0]) == 0)
        #expect(WiFiLink.strongest(supported: [14, 0]) == 14)
        #expect(WiFiLink.strongest(supported: []) == nil)
    }
    @Test func savedRadioSamplesWithoutLinkDetailsStillDecode() throws {
        let old = #"{"ssid":"Home","interface":"en0","rssi":-58,"noise":-92,"transmitMbps":300,"channel":36,"band":"5 GHz"}"#
        let radio = try JSONDecoder().decode(RadioSample.self, from: Data(old.utf8))
        #expect(radio.standard == nil)
        #expect(radio.securityInfo == nil)
        let network = try JSONDecoder().decode(NearbyNetwork.self, from: Data(#"{"id":"a","ssid":"a","rssi":-40,"noise":-90,"channel":1,"band":"2.4 GHz","widthMHz":20}"#.utf8))
        #expect(network.securityInfo == nil)
    }

    // MARK: The verdict across every probe

    private func ping(_ ms: [Double], loss: Double?, host: String = "1.1.1.1") -> PingResult { PingResult(host: host, samples: ms, lossPercent: loss) }
    private func sample(internet: PingResult, secondary: PingResult? = nil, http: Bool? = nil) -> DiagnosticSnapshot {
        let radio = RadioSample.basic(ssid: "Home", interface: "en0", rssi: -50, noise: -95, transmitMbps: 400, channel: 36, band: "5 GHz")
        var value = DiagnosticSnapshot(date: Date(), radio: radio, gateway: "192.168.1.1", router: ping([3, 3], loss: 0, host: "192.168.1.1"), internet: internet,
                                       dnsMilliseconds: 20, dnsServers: ["192.168.1.1"], captivePortal: nil, networkService: "Wi-Fi")
        value.secondary = secondary
        value.httpReachable = http
        return value
    }
    @Test func lostRepliesComeFromTheLossShare() {
        #expect(ping([20, 21, 22], loss: 25).lost == 1)
        #expect(ping([20, 21], loss: 50).lost == 2)
        #expect(ping([20, 21, 22, 23], loss: 0).lost == 0)
        #expect(ping([], loss: 100).lost == nil)
        #expect(ping([20], loss: nil).lost == nil)
    }
    @Test func oneLostReplyIsNotPoor() {
        #expect(sample(internet: ping([20, 21, 22], loss: 25), secondary: ping([18, 19], loss: 0, host: "8.8.8.8")).health == .good)
    }
    @Test func twoLostRepliesArePoor() {
        #expect(sample(internet: ping([20, 21], loss: 50), secondary: ping([18, 19], loss: 0, host: "8.8.8.8")).health == .poor)
        // The second target confirms the first one's lost reply.
        #expect(sample(internet: ping([20, 21, 22], loss: 25), secondary: ping([18], loss: 50, host: "8.8.8.8")).health == .poor)
    }
    @Test func aTargetThatDropsPingsIsNotAnOutage() {
        let s = sample(internet: ping([], loss: 100), secondary: ping([18, 19], loss: 0, host: "8.8.8.8"))
        #expect(s.reachability == .up)
        #expect(s.health == .good)
        #expect(s.measured.host == "8.8.8.8")
        #expect(sample(internet: ping([], loss: 100), secondary: ping([200, 210], loss: 0, host: "8.8.8.8")).health == .degraded)
    }
    @Test func httpsAloneProvesTheInternetWorks() {
        let s = sample(internet: ping([], loss: 100), secondary: ping([], loss: 100, host: "8.8.8.8"), http: true)
        #expect(s.reachability == .up)
        #expect(s.health == .good)
    }
    @Test func everyProbeFailingIsPoor() {
        let s = sample(internet: ping([], loss: 100), secondary: ping([], loss: 100, host: "8.8.8.8"), http: false)
        #expect(s.reachability == .down)
        #expect(s.health == .poor)
    }
    @Test func samplesSavedBeforeKeepTheirVerdict() throws {
        #expect(sample(internet: ping([20, 21, 22], loss: 25)).health == .poor)
        #expect(sample(internet: ping([], loss: 100)).health == .poor)
        #expect(sample(internet: ping([], loss: nil)).health == .unknown)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sample(internet: ping([20], loss: 0), secondary: ping([18], loss: 0), http: true))) as! [String: Any]
        #expect(json["secondary"] != nil && json["httpReachable"] != nil)
        json.removeValue(forKey: "secondary")
        json.removeValue(forKey: "httpReachable")
        let decoded = try JSONDecoder().decode(DiagnosticSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.secondary == nil && decoded.httpReachable == nil)
    }

    @Test func healthRunsMergeNeighbours() {
        #expect(ConnectionHealth.runs([]).isEmpty)
        let runs = ConnectionHealth.runs([.good, .good, .degraded, .good, .poor, .poor])
        #expect(runs.map(\.health) == [.good, .degraded, .good, .poor])
        #expect(runs.map(\.count) == [2, 1, 1, 2])
    }

    @Test func worseHealthDrawsTaller() {
        #expect(ConnectionHealth.unknown.timelineHeight < ConnectionHealth.good.timelineHeight)
        #expect(ConnectionHealth.good.timelineHeight < ConnectionHealth.degraded.timelineHeight)
        #expect(ConnectionHealth.degraded.timelineHeight < ConnectionHealth.poor.timelineHeight)
        #expect(ConnectionHealth.poor.timelineHeight == 1)
    }
}
