import Foundation
import Testing
@testable import KilobatCore

struct CallReportTests {
    private func pings(_ values: [Double?]) -> [CallSamples.Ping] { values.enumerated().map { .init(at: Double($0.offset), ms: $0.element) } }
    private func report(_ samples: CallSamples) -> CallReport {
        CallAnalysis.report(app: "Zoom", browser: false, start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 600), network: nil, samples: samples)
    }

    @Test func aSteadyLineIsACleanCall() {
        var samples = CallSamples()
        samples.internet = pings(Array(repeating: 30, count: 300) + [nil] + Array(repeating: 31, count: 300))
        samples.router = pings(Array(repeating: 3, count: 601))
        let card = report(samples)
        #expect(card.clean)
        #expect(card.verdict == "Clean call")
        #expect(card.median == 30.5)
    }

    @Test func blamesTheAppUploadingAtTheTime() {
        var samples = CallSamples()
        samples.internet = pings(Array(repeating: 30, count: 100) + [400, nil, 380] + Array(repeating: 30, count: 100) + [nil, nil] + Array(repeating: 30, count: 100))
        samples.router = pings(Array(repeating: 3, count: 305))
        samples.traffic = [.init(at: 98, app: "Dropbox", upload: 900_000, download: 2_000), .init(at: 200, app: "Dropbox", upload: 1_200_000, download: 0)]
        let card = report(samples)
        #expect(card.freezes.count == 2)
        #expect(card.freezes.first?.seconds == 3)
        #expect(card.freezes.first?.peak == 400)
        #expect(card.verdict == "2 freezes, caused by Dropbox uploading")
        #expect(card.advice?.contains("Dropbox") == true)
    }

    @Test func blamesTheWiFiWhenTheRouterStallsToo() {
        var samples = CallSamples()
        samples.internet = pings(Array(repeating: 30, count: 50) + [nil, nil] + Array(repeating: 30, count: 50) + [500, 600] + Array(repeating: 30, count: 50))
        samples.router = pings(Array(repeating: 3, count: 50) + [nil, 300] + Array(repeating: 3, count: 104))
        samples.weakSignal = [45]
        samples.traffic = [.init(at: 102, app: "Steam", upload: 0, download: 5_000_000)]
        let card = report(samples)
        #expect(card.freezes.map(\.cause.kind) == [.wifi, .app])
        #expect(card.verdict == "2 freezes: 1 on weak Wi-Fi and 1 caused by Steam downloading")
    }

    @Test func aLoneSlowSecondIsNotAFreeze() {
        var samples = CallSamples()
        samples.internet = pings([30, 30, 500, 30, 30, nil, 30, 30])
        #expect(report(samples).freezes.isEmpty)
        // One good reply inside a bad stretch doesn't split it.
        samples.internet = pings([30, 30, nil, nil, 30, nil, 30, 30, 30])
        #expect(report(samples).freezes.count == 1)
        #expect(report(samples).freezes.first?.cause.kind == .beyondRouter)
    }

    @Test func squeezesTheLineToItsWorstPoints() {
        let line = CallAnalysis.line(pings((0..<1000).map { $0 == 500 ? 900 : 20 }), points: 240)
        #expect(line.count == 240)
        #expect(line.compactMap { $0 }.max() == 900)
    }

    @Test func blamesTheMacWhenTheLineIsClean() {
        var samples = CallSamples()
        samples.internet = pings(Array(repeating: 30, count: 300))
        samples.router = pings(Array(repeating: 3, count: 300))
        samples.load = (0..<60).map { (i: Int) -> CallSamples.Load in
            let busy = i < 40, top: String? = busy ? (i % 4 == 0 ? "WindowServer" : "Xcode") : nil
            return CallSamples.Load(at: Double(i * 5), load: MacLoad(cpu: busy ? 97 : 40, top: top, memory: i >= 50 ? 4 : 1))
        }
        let card = report(samples)
        #expect(!card.clean)
        #expect(card.freezes.isEmpty)
        #expect(card.strain.map(\.kind) == [.cpu, .memory])
        #expect(card.strain.first?.top == "Xcode")
        #expect(card.verdict == "No network freezes, but the Mac was overloaded")
        #expect(card.count == "Mac overloaded")
        #expect(card.advice?.contains("Xcode") == true)
        // A moment of load is not strain.
        samples.load = (0..<60).map { (i: Int) -> CallSamples.Load in CallSamples.Load(at: Double(i * 5), load: MacLoad(cpu: i == 10 ? 99 : 30)) }
        #expect(report(samples).clean)
    }

    @Test func readsTheHungriestProcess() {
        #expect(MacLoad.topProcess(" 98.0 ps\n 97.5 Xcode\n 12.0 WindowServer\n") == "Xcode")
        #expect(MacLoad.topProcess("") == nil)
        #expect(MacLoad.ticks() != nil)
    }

    @Test func blamesAnotherDeviceOnTheNetwork() {
        var samples = CallSamples()
        samples.internet = pings(Array(repeating: 30, count: 100) + [nil, 600, nil] + Array(repeating: 30, count: 100))
        samples.router = pings(Array(repeating: 3, count: 203))
        samples.traffic = [.init(at: 99, app: "Mail", upload: 2_000, download: 4_000)]
        samples.household = [.init(at: 95, upload: 20_000, download: 4_000_000)]
        let card = report(samples)
        #expect(card.freezes.first?.cause.kind == .otherDevice)
        #expect(card.verdict == "1 freezes, caused by another device on your network downloading")
        #expect(card.household == true)
        // Without the router's counters, Kilobat says it couldn't see other devices.
        samples.household = nil
        let blind = report(samples)
        #expect(blind.freezes.first?.cause.kind == .beyondRouter)
        #expect(blind.advice?.contains("UPnP") == true)
    }

    @Test func findsTheRoutersCounters() {
        let reply = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=120\r\nLOCATION: http://192.168.1.1:5000/rootDesc.xml\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n"
        #expect(RouterCounters.locationHeader(reply) == "http://192.168.1.1:5000/rootDesc.xml")
        let description = Data("""
        <root><device><serviceList><service><serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType><controlURL>/ctl/L3F</controlURL></service>
        <service><serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType><controlURL>/ctl/CmnIfCfg</controlURL></service></serviceList></device></root>
        """.utf8)
        #expect(RouterCounters.controlURL(description: description, base: URL(string: "http://192.168.1.1:5000/rootDesc.xml")!) == "http://192.168.1.1:5000/ctl/CmnIfCfg")
    }

    @Test func findsTheCallingApp() {
        #expect(CallDetector.call(microphone: ["us.zoom.xos"])?.app == "Zoom")
        #expect(CallDetector.call(microphone: ["com.google.Chrome.helper"]) == CallDetector.Call(app: "Chrome", browser: true, own: ["com.google.Chrome"]))
        #expect(CallDetector.call(microphone: ["com.google.Chrome.helper", "com.microsoft.teams2"])?.app == "Microsoft Teams")
        #expect(CallDetector.call(microphone: ["company.thebrowser.dia.helper"]) == CallDetector.Call(app: "Dia", browser: true, own: ["company.thebrowser.dia"]))
        #expect(CallDetector.call(microphone: ["com.apple.avconferenced"])?.own.contains("avconferenced") == true)
        #expect(CallDetector.call(microphone: ["com.apple.VoiceMemos"]) == nil)
    }

    @Test func keepsReportsReadableByTheCLI() throws {
        var samples = CallSamples()
        samples.internet = pings(Array(repeating: 30, count: 120))
        let data = try JSONEncoder().encode([report(samples)])
        #expect(try JSONDecoder().decode([CallReport].self, from: data).first?.app == "Zoom")
    }
}
