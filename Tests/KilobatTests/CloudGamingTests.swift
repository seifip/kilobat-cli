import Foundation
import Testing
@testable import KilobatCore

/// Cloud gaming sessions: which app or browser plays which service, when a stream counts as a cloud game (and when
/// ordinary video or a call doesn't), what a stutter is, what it's put down to, and the data a session uses.
struct CloudGamingTests {
    // MARK: Services and clients

    @Test func recognisesTheMacAppsByNameBundleOrPath() {
        #expect(CloudGamingService.app(id: "com.nvidia.gfnpc.mall", name: "GeForceNOW")?.id == "geforcenow")
        #expect(CloudGamingService.app(id: "process:GeForceNOWStreamer", name: "GeForceNOWStreamer")?.id == "geforcenow")
        #expect(CloudGamingService.app(id: "com.example.unknown", name: "Helper", path: "/Applications/GeForce NOW.app")?.id == "geforcenow")
        #expect(CloudGamingService.app(id: "process:Helper", name: "Helper", path: "/Applications/GeForce NOW.app/Contents/MacOS/Helper")?.id == "geforcenow")
        #expect(CloudGamingService.app(id: "process:Helper", name: "Helper", path: "/Applications/GeForce NOW.app/Contents/Helpers/Helper.app/Contents/MacOS/Helper")?.id == "geforcenow")
        #expect(CloudGamingService.app(id: "com.example.boost", name: "Boosteroid")?.id == "boosteroid")
        #expect(CloudGamingService.app(id: "com.example.shadow", name: "Shadow PC")?.id == "shadow")
        #expect(CloudGamingService.app(id: "com.example.shadow", name: "Shadow")?.id == "shadow")
        // Only the whole name "Shadow": a proxy app that starts with it is not a cloud PC.
        #expect(CloudGamingService.app(id: "com.qiuyuzhou.ShadowsocksX-NG", name: "ShadowsocksX-NG") == nil)
        #expect(CloudGamingService.app(id: "com.google.Chrome", name: "Google Chrome") == nil)
    }

    @Test func browsersIncludeTheirHelpersAndWebKitsNetworkingProcess() {
        #expect(CloudGamingService.browser(id: "com.google.Chrome.helper") == "Chrome")
        #expect(CloudGamingService.browser(id: "com.apple.WebKit.Networking") == "Safari")
        #expect(CloudGamingService.browser(id: "com.microsoft.edgemac") == "Edge")
        #expect(CloudGamingService.browser(id: "process:helper", path: "/Applications/Opera GX.app") == "Opera GX")
        #expect(CloudGamingService.browser(id: "us.zoom.xos") == nil)
    }

    @Test func hostsNameTheServiceAndNothingElse() {
        #expect(CloudGamingService.service(hosts: ["www.google.com", "uks.gssv-play-prod.xboxlive.com"])?.id == "xbox")
        #expect(CloudGamingService.service(hosts: ["play.geforcenow.com"])?.id == "geforcenow")
        #expect(CloudGamingService.service(hosts: ["prod.cloudmatchbeta.nvidiagrid.net."])?.id == "geforcenow")
        #expect(CloudGamingService.service(hosts: ["luna.amazon.co.uk"])?.id == "luna")
        #expect(CloudGamingService.service(hosts: ["cloud.boosteroid.com"])?.id == "boosteroid")
        #expect(CloudGamingService.service(hosts: ["pc.shadow.tech"])?.id == "shadow")
        // Lookalikes and ordinary video aren't.
        #expect(CloudGamingService.service(hosts: ["notboosteroid.com", "www.youtube.com", "rr3---sn-4g5e6nsz.googlevideo.com", "www.xbox.com"]) == nil)
        #expect(CloudGamingService.service(hosts: ["luna.amazon.com.evil.example", "luna.amazon.co.uk.evil.example", "gssv-play.evil.example", "luna.amazon.evil"]) == nil)
        // Opening a service's marketing site in another tab does not identify an unrelated stream.
        #expect(CloudGamingService.service(hosts: ["www.geforcenow.com", "www.boosteroid.com", "www.shadow.tech"]) == nil)
    }

    @MainActor @Test func mapsAppRowsToClients() {
        let apps = [AppTraffic(id: "com.google.Chrome.helper", name: "Google Chrome Helper", processIDs: [10, 11], bundlePath: nil),
                    AppTraffic(id: "com.nvidia.gfnpc.mall", name: "GeForceNOW", processIDs: [20], bundlePath: nil),
                    AppTraffic(id: "com.getdropbox.dropbox", name: "Dropbox", processIDs: [30], bundlePath: nil)]
        let clients = CloudGamingStore.clients(apps)
        #expect(clients[10]?.client == .browser("Chrome") && clients[11]?.client == .browser("Chrome"))
        #expect(clients[20]?.client == .app("geforcenow"))
        #expect(clients[30] == nil)
    }

    // MARK: When a stream is a cloud game

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A process with connections whose bytes grow by `down`/`up` each second.
    static func snapshot(_ second: Int, _ flows: [(pid: Int32, id: String, down: UInt64, up: UInt64)]) -> TrafficSnapshot {
        var processes: [Int32: ProcessTraffic] = [:]
        for flow in flows {
            let received = flow.down * UInt64(second), sent = flow.up * UInt64(second)
            var process = processes[flow.pid] ?? ProcessTraffic(pid: flow.pid, process: "p\(flow.pid)", received: 0, sent: 0)
            process.connections.append(ConnectionTraffic(id: flow.id, route: .internet, interface: "en0", received: received, sent: sent))
            processes[flow.pid] = process
        }
        return TrafficSnapshot(timestamp: t0.addingTimeInterval(Double(second)), processes: Array(processes.values))
    }

    static func browser(_ process: ProcessTraffic) -> CloudGamingFlows.Client? { process.pid == 10 ? .browser("Chrome") : process.pid == 20 ? .app("geforcenow") : nil }

    @Test func aHeavyOneWayUDPStreamCounts() {
        var flows = CloudGamingFlows()
        for second in 0...12 {
            flows.ingest(Self.snapshot(second, [(10, "udp4 192.168.1.20:54000<->203.0.113.7:49004", 3_000_000, 40_000),
                                                (10, "tcp4 192.168.1.20:54001<->198.51.100.4:443", 2_000, 1_000)]), client: Self.browser)
        }
        let media = flows.media
        #expect(media.count == 1)
        #expect(media.first?.client == .browser("Chrome") && media.first?.server == "203.0.113.7")
        #expect((media.first?.down ?? 0) > 2_900_000)
    }

    @Test func webSocketsWithoutAnAddressCountForBrowsers() {
        var flows = CloudGamingFlows()
        for second in 0...12 { flows.ingest(Self.snapshot(second, [(10, "udp4 192.168.1.20:54000<->*:*", 2_500_000, 30_000)]), client: Self.browser) }
        #expect(flows.media.first?.client == .browser("Chrome") && flows.media.first?.server == nil)
    }

    @Test func ordinaryVideoAndCallsDoNot() {
        // YouTube over QUIC on 443, Netflix over TCP, and a two-way call.
        var flows = CloudGamingFlows()
        for second in 0...12 {
            flows.ingest(Self.snapshot(second, [(10, "udp4 192.168.1.20:54000<->142.250.1.1:443", 6_000_000, 60_000),
                                                (10, "tcp4 192.168.1.20:54002<->198.38.96.1:443", 4_000_000, 20_000)]), client: Self.browser)
        }
        #expect(flows.media.isEmpty)
        var call = CloudGamingFlows()
        for second in 0...12 { call.ingest(Self.snapshot(second, [(10, "udp4 192.168.1.20:54000<->203.0.113.9:3478", 500_000, 400_000)]), client: Self.browser) }
        #expect(call.media.isEmpty)
        // A short burst isn't a session either.
        var burst = CloudGamingFlows()
        for second in 0...12 { burst.ingest(Self.snapshot(second, [(10, "udp4 192.168.1.20:54000<->203.0.113.7:49004", second >= 8 ? 4_000_000 : 0, 1_000)]), client: Self.browser) }
        #expect(burst.media.isEmpty)
    }

    @Test func macAppsCountTCPStreamsAwayFromTheWebPorts() {
        var flows = CloudGamingFlows()
        for second in 0...12 { flows.ingest(Self.snapshot(second, [(20, "tcp4 192.168.1.20:54000<->203.0.113.50:8443", 2_000_000, 20_000)]), client: Self.browser) }
        #expect(flows.media.first?.client == .app("geforcenow"))
        // A browser's TCP never counts.
        var tab = CloudGamingFlows()
        for second in 0...12 { tab.ingest(Self.snapshot(second, [(10, "tcp4 192.168.1.20:54000<->203.0.113.50:8443", 2_000_000, 20_000)]), client: Self.browser) }
        #expect(tab.media.isEmpty)
    }

    @Test func aSessionEndsAfterTwentyQuietSeconds() {
        var flows = CloudGamingFlows()
        var received: UInt64 = 0
        var last = Self.t0
        for second in 0...60 {
            if second <= 20 { received += 3_000_000 }
            last = Self.t0.addingTimeInterval(Double(second))
            let process = ProcessTraffic(pid: 10, process: "Chrome", received: received, sent: 0,
                                         connections: [ConnectionTraffic(id: "udp4 192.168.1.20:54000<->203.0.113.7:49004", route: .internet, interface: "en0", received: received, sent: 0)])
            flows.ingest(TrafficSnapshot(timestamp: last, processes: [process]), client: Self.browser)
            if second == 30 { #expect(!flows.ended(.browser("Chrome"), now: last)) }
        }
        #expect(flows.ended(.browser("Chrome"), now: last))
        #expect(flows.lastActive(.browser("Chrome")) == Self.t0.addingTimeInterval(20))
    }

    @Test func aGapLikeSleepOnlyRebaselines() {
        var flows = CloudGamingFlows()
        flows.ingest(Self.snapshot(1, [(10, "udp4 192.168.1.20:54000<->203.0.113.7:49004", 3_000_000, 0)]), client: Self.browser)
        let seconds = flows.ingest(Self.snapshot(100, [(10, "udp4 192.168.1.20:54000<->203.0.113.7:49004", 3_000_000, 0)]), client: Self.browser)
        #expect(seconds.isEmpty)
    }

    // MARK: The report

    /// A 20-minute session at 25 Mbps with a ping of 20 ms, plus whatever each test adds.
    static func samples(minutes: Int = 20, mbps: Double = 25) -> CloudGamingSamples {
        var samples = CloudGamingSamples()
        let seconds = minutes * 60
        samples.line.internet = (0..<seconds).map { .init(at: Double($0), ms: 20 + Double($0 % 4)) }
        samples.line.router = (0..<seconds).map { .init(at: Double($0), ms: 3) }
        samples.seconds = (0..<seconds).map { .init(at: Double($0), down: mbps * 1_000_000 / 8, up: 40_000) }
        return samples
    }
    static let geforce = CloudGamingService.service("geforcenow")!

    @Test func aWiFiStallOn24GHzWhileICloudPhotosUploaded() {
        var samples = Self.samples()
        for i in 600..<640 { samples.line.internet[i] = .init(at: Double(i), ms: i % 3 == 0 ? nil : 260); samples.line.router[i] = .init(at: Double(i), ms: 180) }
        samples.band24 = (0..<1200).map(Double.init)
        samples.line.traffic = (600..<640).map { .init(at: Double($0), app: "cloudphotod", upload: 900_000, download: 0) }
        let report = CloudGamingAnalysis.report(service: Self.geforce, browser: nil, start: Self.t0, end: Self.t0.addingTimeInterval(1200), network: nil, metered: false, samples: samples)
        #expect(report.stutters.count == 1)
        let stutter = report.stutters[0]
        #expect(stutter.factors.map(\.kind) == [.band24, .app])
        #expect(stutter.factors.last?.app == "iCloud Photos" && stutter.factors.last?.uploading == true)
        #expect(stutter.phrase == "2.4 GHz Wi-Fi while iCloud Photos uploaded")
        #expect(abs(stutter.seconds - 40) <= 1)
        #expect(report.verdict == "Stuttered at \(report.clock(stutter)) for 40s: 2.4 GHz Wi-Fi while iCloud Photos uploaded"
                || report.verdict == "Stuttered at \(report.clock(stutter)) for 40 s: 2.4 GHz Wi-Fi while iCloud Photos uploaded")
        #expect(report.count == "Stuttered once")
        #expect(report.advice?.contains("5 GHz") == true)
        #expect(report.measured == .internet)
    }

    @Test func airDropAndAWeakSignalAreNamedTogether() {
        var samples = Self.samples()
        for i in 300..<304 { samples.line.internet[i] = .init(at: Double(i), ms: nil); samples.line.router[i] = .init(at: Double(i), ms: nil) }
        samples.airDrop = [290]
        samples.line.weakSignal = [298]
        let report = CloudGamingAnalysis.report(service: Self.geforce, browser: "Chrome", start: Self.t0, end: Self.t0.addingTimeInterval(1200), network: nil, metered: false, samples: samples)
        #expect(report.stutters.first?.factors.map(\.kind) == [.weakSignal, .airDrop])
        #expect(report.stutters.first?.phrase == "weak Wi-Fi and AirDrop scanning")
        #expect(report.title == "GeForce NOW in Chrome")
    }

    @Test func aBusyAppAloneReadsAsTheCause() {
        var samples = Self.samples()
        for i in 400..<406 { samples.line.internet[i] = .init(at: Double(i), ms: 240) }
        samples.line.traffic = (395..<406).map { .init(at: Double($0), app: "Dropbox", upload: 1_200_000, download: 0) }
        let report = CloudGamingAnalysis.report(service: Self.geforce, browser: nil, start: Self.t0, end: Self.t0.addingTimeInterval(1200), network: nil, metered: false, samples: samples)
        #expect(report.stutters.first?.phrase == "Dropbox was uploading")
        #expect(report.advice?.contains("Kilobat holds it") == true)
    }

    @Test func aBitrateDipWithASteadyLineIsBeyondTheRouter() {
        var samples = Self.samples()
        for i in 500..<510 { samples.seconds[i] = .init(at: Double(i), down: 4_000_000 / 8, up: 40_000) }
        // The ramp-up in the first half minute and the wind-down at the end are not stutters.
        for i in 0..<20 { samples.seconds[i] = .init(at: Double(i), down: 2_000_000 / 8, up: 40_000) }
        for i in 1190..<1200 { samples.seconds[i] = .init(at: Double(i), down: 1_000_000 / 8, up: 40_000) }
        let report = CloudGamingAnalysis.report(service: Self.geforce, browser: nil, start: Self.t0, end: Self.t0.addingTimeInterval(1200), network: nil, metered: false, samples: samples)
        #expect(report.stutters.count == 1)
        #expect(report.stutters.first.map { $0.at == 500 && $0.seconds == 10 } == true)
        #expect(report.stutters.first?.low == 4)
        #expect(report.stutters.first?.factors.map(\.kind) == [.beyondRouter])
        #expect(report.stutters.first?.peak == nil)
        // Without the router's counters, the advice says other devices can't be seen.
        #expect(report.advice?.contains("UPnP") == true)
    }

    @Test func aCleanSessionAndItsNumbers() {
        let report = CloudGamingAnalysis.report(service: Self.geforce, browser: nil, start: Self.t0, end: Self.t0.addingTimeInterval(1200), network: ("k", "Home"), metered: true, samples: Self.samples())
        #expect(report.clean && report.verdict == "Smooth session" && report.advice == nil)
        #expect((21...22).contains(report.median ?? 0))
        #expect(abs((report.averageMbps ?? 0) - 25) < 0.1)
        #expect(report.bytes == 1200 * 3_125_000)
        #expect(abs((report.bytesPerHour ?? 0) - 11.25e9) < 1e6)
        #expect(report.data?.contains("metered") == true)
        #expect(report.line.count == 240 && report.bitrate.count == 240)
    }

    @Test func theServersOwnPingIsUsedWhenItAnswers() {
        var samples = Self.samples()
        samples.server = (0..<1200).map { .init(at: Double($0), ms: 14) }
        let report = CloudGamingAnalysis.report(service: Self.geforce, browser: nil, start: Self.t0, end: Self.t0.addingTimeInterval(1200), network: nil, metered: false, samples: samples)
        #expect(report.measured == .server && report.median == 14)
        var silent = Self.samples()
        silent.server = (0..<1200).map { .init(at: Double($0), ms: $0 % 3 == 0 ? 14 : nil) }
        #expect(CloudGamingAnalysis.report(service: Self.geforce, browser: nil, start: Self.t0, end: Self.t0.addingTimeInterval(1200), network: nil, metered: false, samples: silent).measured == .internet)
    }

    @Test func mixedCausesAreCountedInTheVerdict() {
        var samples = Self.samples()
        for start in [200, 400] { for i in start..<start + 3 { samples.line.internet[i] = .init(at: Double(i), ms: nil); samples.line.router[i] = .init(at: Double(i), ms: nil) } }
        samples.airDrop = [190, 395]
        for i in 800..<804 { samples.line.internet[i] = .init(at: Double(i), ms: 300) }
        let report = CloudGamingAnalysis.report(service: Self.geforce, browser: nil, start: Self.t0, end: Self.t0.addingTimeInterval(1200), network: nil, metered: false, samples: samples)
        #expect(report.stutters.count == 3)
        #expect(report.verdict.hasPrefix("Stuttered 3 times: AirDrop scanning (2)"))
        #expect(report.advice?.contains("AirDrop") == true)
    }

    @Test func storedReportsRoundTripAndExportCompactly() throws {
        var samples = Self.samples()
        for i in 600..<640 { samples.line.router[i] = .init(at: Double(i), ms: 180); samples.line.internet[i] = .init(at: Double(i), ms: 300) }
        samples.band24 = [600]
        var report = CloudGamingAnalysis.report(service: Self.geforce, browser: nil, start: Self.t0, end: Self.t0.addingTimeInterval(1200), network: nil, metered: false, samples: samples)
        report.held = ["Dropbox"]
        let decoded = try JSONDecoder().decode(CloudGamingReport.self, from: JSONEncoder().encode(report))
        #expect(decoded == report)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(CloudGamingReport.Exported(report))) as? [String: Any])
        #expect(object["service"] as? String == "geforcenow" && object["minutes"] as? Int == 20 && object["gigabytes"] as? Double == 3.8)
        #expect(object["line"] == nil && object["bitrate"] == nil)
        let stutter = try #require((object["stutters"] as? [[String: Any]])?.first)
        #expect(stutter["factors"] as? [String] == ["band24"])
        #expect((stutter["sentence"] as? String)?.hasPrefix("Stuttered at") == true)
    }

    // MARK: Live

    @Test func liveCulpritsAreFlaggedWithFriendlyNames() {
        let issues = CloudGamingAnalysis.issues(airDrop: true, band: "2.4 GHz", weak: false, apps: [
            (id: "process:cloudphotod", name: "cloudphotod", up: 1_000_000, down: 0),
            (id: "com.getdropbox.dropbox", name: "Dropbox", up: 600_000, down: 0),
            (id: "com.apple.Music", name: "Music", up: 1_000, down: 20_000)])
        #expect(issues.map(\.kind) == [.airDrop, .band24, .app, .app])
        #expect(issues[2].app == "iCloud Photos" && issues[2].pausable == false && issues[2].phrase == "iCloud Photos is uploading")
        #expect(issues[3].app == "Dropbox" && issues[3].pausable == true)
        #expect(issues[2].advice.contains("Photos"))
        #expect(CloudGamingAnalysis.issues(airDrop: false, band: "5 GHz", weak: false, apps: []).isEmpty)
    }

    @Test func dataPerHourAndTheProjection() {
        // 25 Mbps is 11.25 GB an hour; 20 minutes in with a typical hour, the session heads for 11.25 GB.
        let rate = 3_125_000.0
        let projected = CloudGamingData.projection(used: rate * 1200, rate: rate, elapsed: 1200, typical: 3600)
        #expect(projected.seconds == 3600 && abs(projected.bytes - 11.25e9) < 1)
        // Past the typical length, the next full hour.
        #expect(CloudGamingData.projection(used: rate * 4000, rate: rate, elapsed: 4000, typical: 3600).seconds == 7200)
        #expect(CloudGamingData.runsOut(left: 5e9, rate: rate) == 1600)
        #expect(CloudGamingData.runsOut(left: 5e9, rate: 0) == nil)
        #expect(CloudGamingData.format(11.25e9) == "11 GB" && CloudGamingData.format(9.84e9) == "9.8 GB" && CloudGamingData.format(740e6) == "740 MB")
        func report(_ minutes: Double) -> CloudGamingReport {
            CloudGamingAnalysis.report(service: Self.geforce, browser: nil, start: Self.t0, end: Self.t0.addingTimeInterval(minutes * 60), network: nil, metered: false, samples: CloudGamingSamples())
        }
        #expect(CloudGamingData.typical([report(90), report(100)], service: "geforcenow") == 3600)
        #expect(CloudGamingData.typical([report(90), report(100), report(110), report(5)], service: "geforcenow") == 6000)
        #expect(CloudGamingData.typical([report(5), report(5), report(5)], service: "geforcenow") == 1800)
    }

    @Test func theLiveSummaryOnAMeteredNetwork() {
        var live = CloudGamingStore.Live(service: "xbox", name: "Xbox Cloud Gaming", browser: "Edge", start: Self.t0)
        live.metered = true; live.rate = 2_000_000; live.bytes = 2_000_000 * 600; live.budgetLeft = 3.6e9; live.typical = 3600
        live.pingMs = 31.04; live.mbps = 16; live.issues = [.init(kind: .band24)]
        let json = live.json(now: Self.t0.addingTimeInterval(600))
        #expect(json["title"] as? String == "Xbox Cloud Gaming in Edge")
        #expect(json["gigabytesPerHour"] as? Double == 7.2 && json["projectedGigabytes"] as? Double == 7.2 && json["projectedMinutes"] as? Int == 60)
        #expect(json["budgetRunsOutMinutes"] as? Int == 30 && json["pingMs"] as? Double == 31)
        #expect((json["issues"] as? [[String: Any]])?.first?["kind"] as? String == "band24")
        #expect(live.dataLine(now: Self.t0.addingTimeInterval(600))?.contains("7.2 GB an hour") == true)
        live.metered = false
        #expect(live.dataLine() == nil && live.json()["projectedGigabytes"] == nil)
    }
}
