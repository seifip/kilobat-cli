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
    @Test func dnsArgumentsAreShellQuoted() {
        #expect(DNSService.shellQuote("a'b") == "'a'\\''b'")
        #expect(DNSService.shellQuote("Wi-Fi $(echo bad)") == "'Wi-Fi $(echo bad)'")
    }
    @Test func channelOverlapWeightsNearbyStrongNetworks() {
        let network = NearbyNetwork(id: "a", ssid: "a", rssi: -40, noise: -90, channel: 1, band: "2.4 GHz", widthMHz: 20)
        #expect(DiagnosticProbe.congestion(channel: 1, band: "2.4 GHz", networks: [network]) > 0)
        #expect(DiagnosticProbe.congestion(channel: 6, band: "2.4 GHz", networks: [network]) == 0)
        #expect(DiagnosticProbe.congestion(channel: 1, band: "5 GHz", networks: [network]) == 0)
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
}
