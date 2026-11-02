import Foundation
import Testing
@testable import KilobatCore

/// Service speed: turning nettop's connection rows into per-service downloads, naming them, and when a slow one is clear.
struct ServiceSpeedTests {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// 4 January 2027 at `hour`:`minute` UTC, `day` days later.
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2027, month: 1, day: 4, hour: hour, minute: minute))!.addingTimeInterval(Double(day) * 86_400)
    }

    // MARK: Flows

    private func connection(_ remote: String, _ received: UInt64, _ sent: UInt64 = 0, port: Int = 50_000) -> ConnectionTraffic {
        ConnectionTraffic(id: "tcp4 192.168.1.20:\(port)<->\(remote)", route: .internet, interface: "en0", received: received, sent: sent)
    }
    private func sample(_ second: Int, _ connections: [ConnectionTraffic], pid: Int32 = 501) -> TrafficSnapshot {
        TrafficSnapshot(timestamp: at(0, 20).addingTimeInterval(Double(second)), processes: [ProcessTraffic(pid: pid, process: "git", received: 0, sent: 0, connections: connections)])
    }
    private func github(_ process: ProcessTraffic, _ address: String, _ port: String, _ proto: String) -> ServiceAttribution? {
        ServiceAttribution(key: "github", via: "github", host: "objects.githubusercontent.com", app: "process:git")
    }

    @Test func parallelConnectionsToOneServiceAreOneTransfer() {
        var tracker = ServiceFlowTracker(), ended: [(key: String, transfer: ServiceTransfer)] = []
        // Two connections at 1 MB/s each for ten seconds; the first row of each is only a baseline.
        for second in 0...10 {
            let bytes = UInt64(second) * 1_000_000 + 400_000
            ended += tracker.ingest(sample(second, [connection("140.82.121.4:443", bytes, port: 50_001), connection("140.82.121.5:443", bytes, port: 50_002)]), identify: github)
        }
        #expect(ended.isEmpty)
        // Quiet for nine seconds: it ends.
        for second in 11...20 { ended += tracker.ingest(sample(second, []), identify: github) }
        #expect(ended.count == 1)
        let transfer = ended[0].transfer
        #expect(ended[0].key == "github")
        #expect(transfer.bytes == 20_000_000 && transfer.seconds == 10)
        #expect(abs(transfer.mbps - 16) < 0.01)
        #expect(transfer.host == "objects.githubusercontent.com" && transfer.via == "github")
        #expect(transfer.address == "140.82.121.4")
        #expect(transfer.otherMbps == 0)
    }

    @Test func smallUploadsAndPacedFlowsDontCount() {
        // 3 MB: under the 5 MB floor.
        var tracker = ServiceFlowTracker(), ended: [(key: String, transfer: ServiceTransfer)] = []
        for second in 0...3 { ended += tracker.ingest(sample(second, [connection("140.82.121.4:443", UInt64(second) * 1_000_000)]), identify: github) }
        ended += tracker.finish()
        #expect(ended.isEmpty)
        // An upload-heavy flow, like a call: as much sent as received.
        tracker = ServiceFlowTracker()
        for second in 0...10 { ended += tracker.ingest(sample(second, [connection("140.82.121.4:443", UInt64(second) * 1_000_000, UInt64(second) * 500_000)]), identify: github) }
        ended += tracker.finish()
        #expect(ended.isEmpty)
        // Video: never measured.
        tracker = ServiceFlowTracker()
        for second in 0...10 { ended += tracker.ingest(sample(second, [connection("142.250.1.1:443", UInt64(second) * 2_000_000)]), identify: { _, _, _, _ in nil }) }
        ended += tracker.finish()
        #expect(ended.isEmpty)
    }

    @Test func otherDownloadsDuringATransferAreRecorded() {
        var tracker = ServiceFlowTracker(), ended: [(key: String, transfer: ServiceTransfer)] = []
        let identify: (ProcessTraffic, String, String, String) -> ServiceAttribution? = { _, address, _, _ in
            address.hasPrefix("140.") ? ServiceAttribution(key: "github", via: "github", host: nil, app: nil) : ServiceAttribution(key: "net:akamai", via: "akamai", host: nil, app: nil)
        }
        for second in 0...8 {
            ended += tracker.ingest(sample(second, [connection("140.82.121.4:443", UInt64(second) * 1_000_000, port: 1), connection("23.1.1.1:443", UInt64(second) * 3_000_000, port: 2)]), identify: identify)
        }
        ended += tracker.finish()
        let github = ended.first { $0.key == "github" }?.transfer, akamai = ended.first { $0.key == "net:akamai" }?.transfer
        #expect(github.map { abs($0.mbps - 8) < 0.01 && abs(($0.otherMbps ?? 0) - 24) < 0.01 } == true)
        #expect(akamai.map { abs($0.mbps - 24) < 0.01 } == true)
    }

    @Test func aGapStartsOverFromBaselines() {
        var tracker = ServiceFlowTracker(), ended: [(key: String, transfer: ServiceTransfer)] = []
        for second in 0...6 { ended += tracker.ingest(sample(second, [connection("140.82.121.4:443", UInt64(second) * 2_000_000)]), identify: github) }
        // The Mac slept: the transfer so far ends, and the next counters are baselines, not one huge second.
        ended += tracker.ingest(sample(600, [connection("140.82.121.4:443", 900_000_000)]), identify: github)
        #expect(ended.count == 1 && ended[0].transfer.bytes == 12_000_000)
        ended += tracker.ingest(sample(601, [connection("140.82.121.4:443", 901_000_000)]), identify: github)
        ended += tracker.finish()
        #expect(ended.count == 1)
    }

    @Test func endpointsParse() {
        #expect(ServiceFlowTracker.endpoint("tcp4 192.168.1.20:5000<->140.82.121.4:443")! == ("tcp4", "140.82.121.4", "443"))
        #expect(ServiceFlowTracker.endpoint("tcp6 fd00::1.5000<->2606:50c0:8000::154.443")! == ("tcp6", "2606:50c0:8000::154", "443"))
        #expect(ServiceFlowTracker.endpoint("udp4 *:5353<->*:*") == nil)
    }

    // MARK: Naming

    @Test func networksByAddress() throws {
        let packed = try Data(contentsOf: GeoIP.resources.first!.appendingPathComponent("networks.deflate"))
        let owners = NetworkOwners(packed: packed)
        #expect(owners.available)
        #expect(owners.owner("140.82.121.4") == "github")
        #expect(owners.owner("185.199.108.133") == "github")
        #expect(owners.owner("17.253.1.1") == "apple")
        #expect(owners.owner("151.101.1.1") == "fastly")
        #expect(owners.owner("104.16.1.1") == "cloudflare")
        #expect(owners.owner("155.133.244.1") == "valve")
        #expect(owners.owner("162.125.1.1") == "dropbox")
        #expect(owners.owner("13.32.1.1") == "cloudfront")
        #expect(owners.owner("8.8.8.8") == "google")
        #expect(owners.owner("192.168.1.1") == nil && owners.owner("10.0.0.1") == nil && owners.owner("not an address") == nil)
    }

    @Test func servicesByHostAppAndNetwork() {
        func key(host: String? = nil, reverse: String? = nil, app: String? = nil, owner: String? = nil) -> String? {
            ServiceSpeedCatalog.attribute(host: host, reverse: reverse, app: app, owner: owner)?.key
        }
        // The host wins: GitHub's downloads come through Fastly's addresses.
        #expect(key(host: "objects.githubusercontent.com", owner: "fastly") == "github")
        #expect(key(host: "registry.npmjs.org", owner: "cloudflare") == "npm")
        #expect(key(host: "p123-content.icloud-content.com", owner: "apple") == "icloud")
        #expect(key(host: "swcdn.apple.com", owner: "akamai") == "apple")
        // Then the app: Steam downloads from Akamai and others.
        #expect(key(app: "com.valvesoftware.steam", owner: "akamai") == "steam")
        #expect(key(app: "process:bird", owner: "apple") == "icloud")
        // Then a network that carries only one service, by ASN.
        #expect(key(owner: "valve") == "steam")
        #expect(key(owner: "github") == "github")
        #expect(key(owner: "dropbox") == "dropbox")
        // A shared CDN stays a network.
        #expect(key(owner: "akamai") == "net:akamai")
        #expect(key(app: "com.apple.Safari", owner: "fastly") == "net:fastly")
        #expect(key(reverse: "a23-1-1-1.deploy.static.akamaitechnologies.com") == "net:akamai")
        #expect(key(reverse: "lb-140-82-121-4-fra.github.com") == "github")
        #expect(key() == "other")
        // Video, music and calls: never measured.
        #expect(key(host: "rr3---sn-abc.googlevideo.com", owner: "google") == nil)
        #expect(key(app: "com.spotify.client") == nil)
        #expect(key(app: "us.zoom.xos") == nil)
        #expect(key(owner: "netflix") == nil)
    }

    // MARK: When it's clear

    private func transfer(_ date: Date, _ mbps: Double, other: Double = 0) -> ServiceTransfer {
        ServiceTransfer(date: date, seconds: 10, bytes: UInt64(mbps * 1_250_000), mbps: mbps, otherMbps: other, address: "140.82.121.4")
    }
    private func log(_ services: [String: [ServiceTransfer]], network: String = "home") -> ServiceSpeedLog {
        var log = ServiceSpeedLog()
        for (key, transfers) in services { for transfer in transfers { log.add(transfer, key: key, network: network, name: "Home", now: at(1, 0)) } }
        log.current = network
        return log
    }
    private func speedTest(_ date: Date, _ mbps: Double, network: String = "home") -> SavedSpeedTest {
        let ping = PingResult(host: "1.1.1.1", samples: [12, 13, 12], lossPercent: 0)
        return SavedSpeedTest(networkKey: network, networkName: "Home", result: SpeedTestResult(date: date, downloadMbps: mbps, uploadMbps: 40, baseline: ping, downloadLoaded: ping,
                                                                                                uploadLoaded: ping, downloadSeconds: 8, uploadSeconds: 8, transferredBytes: 60_000_000))
    }
    private func report(_ log: ServiceSpeedLog, tests: [SavedSpeedTest] = [], statuses: [String: ServiceStatus] = [:], now: Date? = nil) -> ServiceSpeedReport {
        ServiceSpeedReport(log: log, network: "home", speedTests: tests, statuses: statuses, now: now ?? at(0, 23), calendar: calendar)
    }

    @Test func threeSlowDownloadsWhileOthersAreFastIsAFinding() throws {
        let slow = [transfer(at(0, 20), 6), transfer(at(0, 21), 8), transfer(at(0, 22), 5)]
        let fast = [transfer(at(0, 20, 10), 280), transfer(at(0, 21, 20), 300), transfer(at(0, 22, 5), 290)]
        let result = report(log(["github": slow, "net:akamai": fast]), tests: [speedTest(at(0, 12), 310)])
        let finding = try #require(result.finding)
        #expect(finding.key == "github" && finding.kind == "route")
        #expect(finding.slowTransfers == 3 && finding.slowMbps == 6)
        #expect(finding.headline.contains("GitHub") && finding.headline.contains("tonight"))
        #expect(finding.detail.contains("not your Wi-Fi"))
        #expect(finding.traceAddress == "140.82.121.4")
        #expect(result.capacity?.mbps == 310 && result.capacity?.source == "speedTest")
        #expect(result.rows.first?.key == "github" && result.rows.first?.state == "slow")
        #expect(result.providerLine?.contains("GitHub") == true)
    }

    @Test func twoSlowDownloadsAreNotEnough() {
        let slow = [transfer(at(0, 20), 6), transfer(at(0, 21), 8)]
        let fast = [transfer(at(0, 20, 10), 280), transfer(at(0, 21, 20), 300)]
        #expect(report(log(["github": slow, "net:akamai": fast]), tests: [speedTest(at(0, 12), 310)]).finding == nil)
    }

    @Test func slowWithNothingFastWithinTheHourIsNotAFinding() {
        // The line may have been slow then too: the only fast numbers are from the morning.
        let slow = [transfer(at(0, 20), 6), transfer(at(0, 21), 8), transfer(at(0, 22), 5)]
        let fast = [transfer(at(0, 9), 280), transfer(at(0, 10), 300)]
        #expect(report(log(["github": slow, "net:akamai": fast]), tests: [speedTest(at(0, 8), 310)]).finding == nil)
    }

    @Test func aSpeedTestWithinTheHourCountsAsFastElsewhere() {
        let slow = [transfer(at(0, 20), 6), transfer(at(0, 20, 20), 8), transfer(at(0, 20, 40), 5)]
        #expect(report(log(["github": slow]), tests: [speedTest(at(0, 20, 30), 300)]).finding?.key == "github")
    }

    @Test func aBusyLineIsNotASlowRoute() {
        // Other downloads took the line at the same time: the transfer was crowded out.
        let busy = [transfer(at(0, 20), 40, other: 250), transfer(at(0, 21), 50, other: 240), transfer(at(0, 22), 45, other: 250)]
        let fast = [transfer(at(0, 20, 10), 280), transfer(at(0, 21, 20), 300), transfer(at(0, 22, 5), 290)]
        #expect(report(log(["github": busy, "net:akamai": fast]), tests: [speedTest(at(0, 12), 310)]).finding == nil)
    }

    @Test func mostlyFastServiceIsNotAFinding() {
        let mixed = [transfer(at(0, 20), 6), transfer(at(0, 21), 8), transfer(at(0, 22), 5), transfer(at(0, 13), 250), transfer(at(0, 14), 260), transfer(at(0, 15), 270)]
        let fast = [transfer(at(0, 20, 10), 280), transfer(at(0, 21, 20), 300), transfer(at(0, 22, 5), 290)]
        #expect(report(log(["github": mixed, "net:akamai": fast]), tests: [speedTest(at(0, 12), 310)]).finding == nil)
    }

    @Test func slowOnEveryNetworkIsTheServiceNotTheRoute() {
        var both = log(["github": [transfer(at(0, 20), 6), transfer(at(0, 21), 8), transfer(at(0, 22), 5)],
                        "net:akamai": [transfer(at(0, 20, 10), 280), transfer(at(0, 21, 20), 300), transfer(at(0, 22, 5), 290)]])
        for (index, day) in [-5, -4, -3].enumerated() {
            both.add(transfer(at(day, 10 + index), 4), key: "github", network: "office", name: "Office", now: at(1, 0))
            both.add(transfer(at(day, 11 + index), 400), key: "net:fastly", network: "office", name: "Office", now: at(1, 0))
        }
        #expect(report(both, tests: [speedTest(at(0, 12), 310)]).finding == nil)
    }

    @Test func aStatusPageProblemMeansItsThem() throws {
        let slow = [transfer(at(0, 20), 6), transfer(at(0, 21), 8), transfer(at(0, 22), 5)]
        let fast = [transfer(at(0, 20, 10), 280), transfer(at(0, 21, 20), 300), transfer(at(0, 22, 5), 290)]
        let status = ServiceStatus(id: "github", service: "GitHub", state: .degraded, incident: "Degraded performance for Git Operations",
                                   page: URL(string: "https://www.githubstatus.com")!, checked: at(0, 22, 30))
        let finding = try #require(report(log(["github": slow, "net:akamai": fast]), tests: [speedTest(at(0, 12), 310)], statuses: ["github": status]).finding)
        #expect(finding.kind == "service" && finding.statusPage != nil)
        #expect(finding.evidence.contains { $0.contains("Git Operations") })
        #expect(finding.traceAddress == nil)
    }

    @Test func aTraceShowsWhereTheDelayRises() throws {
        let output = """
        traceroute to 140.82.121.4 (140.82.121.4), 12 hops max, 52 byte packets
         1  192.168.1.1  2.1 ms  1.9 ms  2.0 ms
         2  10.20.0.1  9.0 ms  8.8 ms  9.4 ms
         3  80.10.1.1  11.0 ms  12.0 ms  11.5 ms
         4  80.10.9.9  64.0 ms  66.0 ms  65.0 ms
         5  140.82.121.4  67.0 ms  66.5 ms  68.0 ms
        """
        let trace = ServiceRouteTrace(date: at(0, 22, 40), address: "140.82.121.4", output: output)
        #expect(trace.hop == 4 && (trace.riseMs ?? 0) > 50)
        var saved = log(["github": [transfer(at(0, 20), 6), transfer(at(0, 21), 8), transfer(at(0, 22), 5)],
                         "net:akamai": [transfer(at(0, 20, 10), 280), transfer(at(0, 21, 20), 300), transfer(at(0, 22, 5), 290)]])
        saved.setTrace(trace, key: "github", network: "home")
        let finding = try #require(report(saved, tests: [speedTest(at(0, 12), 310)]).finding)
        #expect(finding.evidence.contains { $0.contains("hop 4") })
        #expect(finding.traceAddress == nil)
    }

    // MARK: Time of day

    @Test func slowEveryEveningIsAPattern() throws {
        var transfers: [ServiceTransfer] = []
        for day in -9...0 {
            transfers.append(transfer(at(day, 20), 8)); transfers.append(transfer(at(day, 21, 30), 6))
            transfers.append(transfer(at(day, 10), 250)); transfers.append(transfer(at(day, 15), 240))
        }
        let pattern = try #require(ServiceSpeedPattern.find(transfers, capacity: 300, calendar: calendar))
        #expect(pattern.startHour == 20 && pattern.endHour == 22)
        #expect(pattern.evening && pattern.days == 10)
        #expect(pattern.slowInside == 20 && pattern.slowOutside == 0)
    }

    @Test func noPatternWithoutAClearWindow() {
        // Slow at random hours.
        let scattered = (0..<16).map { index in transfer(at(-index, (index * 7) % 24), index.isMultiple(of: 2) ? 8 : 250) }
        #expect(ServiceSpeedPattern.find(scattered, capacity: 300, calendar: calendar) == nil)
        // Every evening, but only two days.
        let short = (0..<2).flatMap { day in [transfer(at(-day, 20), 8), transfer(at(-day, 21), 7), transfer(at(-day, 10), 250), transfer(at(-day, 11), 260), transfer(at(-day, 12), 255)] }
        #expect(ServiceSpeedPattern.find(short, capacity: 300, calendar: calendar) == nil)
    }

    // MARK: The active test

    @Test func theTestRefusesMeteredNetworks() async {
        #expect(throws: ServiceSpeedTest.Refusal.metered) { try ServiceSpeedTest.check(metered: true, bytes: 25_000_000) }
        #expect(throws: ServiceSpeedTest.Refusal.budget) { try ServiceSpeedTest.check(metered: false, bytes: 50_000_000) }
        // Refused before anything is sent.
        await #expect(throws: ServiceSpeedTest.Refusal.metered) { _ = try await ServiceSpeedTest.run(ServiceSpeedTarget.all[0], metered: true) }
        #expect(throws: Never.self) { try ServiceSpeedTest.check(metered: false, bytes: 25_000_000) }
    }

    @Test func testRequestsAreBounded() {
        for target in ServiceSpeedTarget.all {
            let request = ServiceSpeedTest.request(target, bytes: 25_000_000)
            #expect(request.url?.scheme == "https")
            if target.sized { #expect(request.url?.query == "bytes=25000000") } else { #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-24999999") }
        }
        #expect(Set(ServiceSpeedTarget.all.map(\.id)).count == ServiceSpeedTarget.all.count)
        #expect(ServiceSpeedTarget.find("GitHub")?.id == "github" && ServiceSpeedTarget.find("steam") == nil)
    }

    // MARK: CLI and storage

    @Test func cliOptions() throws {
        #expect(try ServiceSpeedReport.Options.parse([]) == ServiceSpeedReport.Options())
        let all = try ServiceSpeedReport.Options.parse(["--all", "--json"])
        #expect(all.all && all.json)
        let test = try ServiceSpeedReport.Options.parse(["service-speed", "--test", "github", "--budget-mb", "10"])
        #expect(test.test == "github" && test.budgetMB == 10)
        #expect(try ServiceSpeedReport.Options.parse(["--list"]).list)
        #expect(throws: (any Error).self) { try ServiceSpeedReport.Options.parse(["--test"]) }
        #expect(throws: (any Error).self) { try ServiceSpeedReport.Options.parse(["--test", "github", "--all"]) }
        #expect(throws: (any Error).self) { try ServiceSpeedReport.Options.parse(["--budget-mb", "80"]) }
        #expect(throws: (any Error).self) { try ServiceSpeedReport.Options.parse(["github"]) }
    }

    @Test func theLogKeepsThirtyDaysAndCapsEachService() {
        var saved = ServiceSpeedLog()
        saved.add(transfer(at(-40, 10), 100), key: "github", network: "home", name: "Home", now: at(0, 12))
        #expect(saved.networks["home"]?.services["github"]?.isEmpty == true)
        for index in 0..<(ServiceSpeedLog.perService + 20) { saved.add(transfer(at(0, 0).addingTimeInterval(Double(index)), 100), key: "npm", network: "home", name: "Home", now: at(0, 12)) }
        #expect(saved.networks["home"]?.services["npm"]?.count == ServiceSpeedLog.perService)
        saved.prune(now: at(40, 0))
        #expect(saved.networks.isEmpty)
    }

    @Test func theProviderReportGetsTheRoute() throws {
        func sample(_ ssid: String) -> DiagnosticSnapshot {
            let ping = PingResult(host: "1.1.1.1", samples: [14, 15], lossPercent: 0)
            return DiagnosticSnapshot(date: at(0, 22, 50), radio: RadioSample(ssid: ssid, interface: "en0", rssi: -55, noise: -92, transmitMbps: 866, channel: 149, band: "5 GHz"),
                                      gateway: "192.168.1.1", router: ping, internet: ping, dnsMilliseconds: 20, dnsServers: [], captivePortal: false, networkService: "Wi-Fi")
        }
        let home = sample("Home"), network = home.networkKey
        let slow = [transfer(at(0, 20), 6), transfer(at(0, 21), 8), transfer(at(0, 22), 5)]
        let fast = [transfer(at(0, 20, 10), 280), transfer(at(0, 21, 20), 300), transfer(at(0, 22, 5), 290)]
        let services = ServiceSpeedReport(log: log(["github": slow, "net:akamai": fast], network: network), network: network,
                                          speedTests: [speedTest(at(0, 12), 310, network: network)], now: at(0, 23), calendar: calendar)
        let support = SupportReport.make(samples: [home], events: [], speedTests: [], hours: 24, serviceSpeed: services, mac: "Mac", now: at(0, 23))
        let route = try #require(support.serviceRoute)
        #expect(route.service == "GitHub" && route.transfers == 3)
        #expect(support.findings.contains { $0.contains("GitHub") })
        #expect(support.text.contains("Slow route to GitHub") && support.markdown.contains("Slow route to GitHub") && support.html.contains("Slow route to GitHub"))
        // Another network's report leaves it out.
        let elsewhere = SupportReport.make(samples: [sample("Café")], events: [], speedTests: [], hours: 24, serviceSpeed: services, mac: "Mac", now: at(0, 23))
        #expect(elsewhere.serviceRoute == nil)
    }
}
