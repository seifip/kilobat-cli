import Foundation
import Testing
@testable import KilobatCore

struct SupportReportTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(_ minutesAgo: Double, router: Double, internet: Double, ssid: String = "Home Wi-Fi") -> DiagnosticSnapshot {
        DiagnosticSnapshot(date: now.addingTimeInterval(-minutesAgo * 60),
                           radio: RadioSample(ssid: ssid, interface: "en0", rssi: -55, noise: -95, transmitMbps: 400, channel: 149, band: "5 GHz"),
                           gateway: "192.168.1.1", router: PingResult(host: "192.168.1.1", samples: [router], lossPercent: 0),
                           internet: PingResult(host: "1.1.1.1", samples: [internet], lossPercent: 0), dnsMilliseconds: 20,
                           dnsServers: ["192.168.1.1"], captivePortal: false, networkService: "Wi-Fi")
    }

    @Test func blamesNothingButSaysWhereTheDelayStarts() {
        let samples = (0..<30).map { sample(Double(30 - $0) * 10, router: 3, internet: 180) }
        let report = SupportReport.make(samples: samples, events: [], speedTests: [], hours: 24, mac: "Mac", now: now)
        #expect(report.findings.first?.contains("The delay starts beyond the router.") == true)
        #expect(report.latency?.routerMedianMs == 3)
        #expect(report.latency?.internetMedianMs == 180)
    }

    @Test func slowRouterPointsBeforeTheInternet() {
        let samples = (0..<10).map { sample(Double(10 - $0) * 10, router: 40, internet: 60) }
        let report = SupportReport.make(samples: samples, events: [], speedTests: [], hours: 24, mac: "Mac", now: now)
        #expect(report.findings.first?.contains("The router itself answered slowly") == true)
    }

    @Test func countsOutagesOnThisNetworkOnly() {
        let samples = [sample(30, router: 3, internet: 30)]
        let events = [NetworkEvent(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-3000), network: "Home Wi-Fi", kind: "Unreachable", detail: ""),
                      NetworkEvent(start: now.addingTimeInterval(-1800), end: now.addingTimeInterval(-1700), network: "Café", kind: "Unreachable", detail: ""),
                      NetworkEvent(start: now.addingTimeInterval(-900), end: now.addingTimeInterval(-900), network: "Home Wi-Fi", kind: "Wi-Fi roam", detail: "")]
        let report = SupportReport.make(samples: samples, events: events, speedTests: [], hours: 24, mac: "Mac", now: now)
        #expect(report.outages.count == 1)
        #expect(report.outages.first?.minutes == 10)
        #expect(report.findings.first?.contains("unreachable once") == true)
    }

    @Test func neverIncludesTheNetworkNameOrLocalAddresses() {
        let samples = [sample(30, router: 3, internet: 30, ssid: "Smith Family 5G")]
        let check = DoctorReport(target: "https://github.com/", host: "github.com", app: nil, verdict: "Works from this Mac.", next: "",
                                 steps: [DoctorStep(layer: "Network", status: .ok, detail: "Online; the router at 192.168.1.254 answers."),
                                         DoctorStep(layer: "DNS", status: .ok, detail: "github.com → 140.82.121.4 in 1 ms from 10.0.0.1 via fe80::1%en0.")],
                                 date: now)
        let report = SupportReport.make(samples: samples, events: [], speedTests: [], hours: 24, check: check, mac: "Mac", now: now)
        for output in [report.text, report.markdown, report.html] {
            #expect(!output.contains("Smith Family"))
            #expect(!output.contains("192.168."))
            #expect(!output.contains("10.0.0.1"))
            #expect(!output.contains("fe80"))
            #expect(output.contains("140.82.121.4"))
            #expect(output.contains(SupportReport.footer))
        }
        #expect(report.connection == "Wi-Fi 5 GHz, channel 149, signal -55 dBm, link 400 Mbps")
    }

    @Test func comparesSpeedsWithThePlan() {
        let ping = PingResult(host: "1.1.1.1", samples: [20, 21], lossPercent: 0)
        let result = SpeedTestResult(date: now.addingTimeInterval(-600), downloadMbps: 50, uploadMbps: 10, baseline: ping, downloadLoaded: ping, uploadLoaded: ping,
                                     downloadSeconds: 8, uploadSeconds: 8, transferredBytes: 1000)
        let samples = [sample(30, router: 3, internet: 30)]
        let saved = SavedSpeedTest(networkKey: samples[0].networkKey, networkName: "Home Wi-Fi", result: result)
        let report = SupportReport.make(samples: samples, events: [], speedTests: [saved], hours: 24, planMbps: 200, mac: "Mac", now: now)
        #expect(report.findings.contains { $0.contains("50 Mbps down") && $0.contains("25% of the 200 Mbps plan") })
    }
}
