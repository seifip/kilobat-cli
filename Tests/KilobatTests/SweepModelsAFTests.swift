import Foundation
import Testing
@testable import KilobatCore

/// Regression tests for defects found in Models A–F: calls and freezes, Fix it, Health's advice, device types,
/// destination history, data packs, cloud gaming and alert ledgers.
struct SweepModelsAFTests {
    // MARK: Calls

    private func pings(_ values: [Double?]) -> [CallSamples.Ping] { values.enumerated().map { .init(at: Double($0.offset), ms: $0.element) } }
    private func report(_ samples: CallSamples) -> CallReport {
        CallAnalysis.report(app: "Zoom", browser: false, start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 600), network: nil, samples: samples)
    }

    @Test func aRouterThatIgnoresPingIsNotTheFreeze() {
        var samples = CallSamples()
        samples.internet = pings(Array(repeating: 30, count: 100) + [400, nil, 380] + Array(repeating: 30, count: 100))
        samples.router = pings(Array(repeating: nil, count: 203))
        #expect(report(samples).freezes.map(\.cause.kind) == [.beyondRouter])
        samples.traffic = [.init(at: 98, app: "Dropbox", upload: 900_000, download: 2_000)]
        #expect(report(samples).freezes.map(\.cause.kind) == [.app])
        // Nothing answered at all, router or internet: still the Wi-Fi.
        var silent = CallSamples()
        silent.internet = pings(Array(repeating: nil, count: 10))
        silent.router = pings(Array(repeating: nil, count: 10))
        #expect(CallAnalysis.cause(from: 2, to: 5, samples: silent).kind == .wifi)
    }

    @Test func aLineThatNeverAnsweredHasNoFreezes() {
        var samples = CallSamples()
        samples.internet = pings(Array(repeating: nil, count: 600))
        samples.router = pings(Array(repeating: 3, count: 600))
        #expect(report(samples).freezes.isEmpty)
        #expect(CallAnalysis.runs(pings(Array(repeating: nil, count: 10)), median: nil).isEmpty)
        #expect(CallAnalysis.runs(pings([30, nil, nil, 30]), median: 30).count == 1)
    }

    @Test func signingInAgainEndsTheLogout() {
        var samples = CallSamples()
        samples.internet = pings(Array(repeating: 30, count: 60) + Array(repeating: nil, count: 20) + Array(repeating: 30, count: 220) + [400, nil, 380] + Array(repeating: 30, count: 97))
        samples.router = pings(Array(repeating: 3, count: 400))
        samples.loggedOut = 55
        samples.traffic = [.init(at: 299, app: "Dropbox", upload: 900_000, download: 2_000)]
        #expect(report(samples).freezes.map(\.cause.kind) == [.portal, .portal])
        samples.signedInAgain = 82
        #expect(report(samples).freezes.map(\.cause.kind) == [.portal, .app])
    }

    // MARK: Fix it: a sign-in page hidden while ping passes

    private let ownDNS = PortalBlockers(ownDNS: ["1.1.1.1", "1.0.0.1"])
    private func portalSnapshot(internet: [Double]) -> DiagnosticSnapshot {
        let radio = RadioSample.basic(ssid: "Hotel", interface: "en0", rssi: -55, noise: -92, transmitMbps: 400, channel: 36, band: "5 GHz")
        return DiagnosticSnapshot(date: Date(), radio: radio, gateway: "10.0.0.1", router: PingResult(host: "r", samples: [3, 3], lossPercent: 0),
                                  internet: PingResult(host: "i", samples: internet, lossPercent: internet.isEmpty ? 100 : 0), dnsMilliseconds: nil,
                                  dnsServers: ["1.1.1.1"], captivePortal: nil, networkService: "Wi-Fi")
    }

    @Test func aHiddenPageWithPingPassingIsNotSignedIn() throws {
        let snapshot = portalSnapshot(internet: [30, 31])
        let cause = try #require(FixPlanner.cause(FixSituation(snapshot: snapshot, portalPlace: "Lobby", portalBlockers: ownDNS, portalSeenHere: true)))
        #expect(cause == .signIn(place: "Lobby", blockers: ownDNS))
        #expect(!cause.metric(FixReading(snapshot)).good)
        // A plain portal, nothing of this Mac's in the way, keeps reading ping as through.
        #expect(FixCause.signIn(place: nil).metric(FixReading(internetMs: 40, portal: false)).good)
    }

    @MainActor final class Bench {
        var readings: [FixReading]
        var applied: [FixAction] = []
        init(_ readings: [FixReading]) { self.readings = readings }
        var actions: FixRunner.Actions {
            FixRunner.Actions(plan: { FixPlanner.steps(for: .signIn(place: nil, blockers: PortalBlockers(ownDNS: ["1.1.1.1"])), helper: true) },
                              measure: { self.readings.count > 1 ? self.readings.removeFirst() : self.readings[0] },
                              apply: { step in
                                  self.applied.append(step.action)
                                  return FixUndo.dns(service: "Wi-Fi", previous: ["1.1.1.1"], applied: [], tracked: false)
                              }, undo: { _ in }, wait: { _ in await Task.yield() })
        }
    }
    private let pingOnly = FixReading(internetMs: 30, portal: false, reachable: true)
    private let signedIn = FixReading(dnsMs: 25, internetMs: 30, portal: false)

    @MainActor private func run(_ bench: Bench) async -> FixRunner {
        let runner = FixRunner(cause: .signIn(place: nil, blockers: ownDNS), live: nil, actions: bench.actions)
        let task = Task { await runner.run() }
        while true {
            if case .person(_, false) = runner.phase { break }
            if runner.finished { break }
            await Task.yield()
        }
        runner.proceed()
        await task.value
        return runner
    }

    @MainActor @Test func aHiddenPageWithPingPassingRunsTheSignInStep() async {
        let bench = Bench([pingOnly, signedIn, signedIn, signedIn, signedIn])
        let runner = await run(bench)
        #expect(bench.applied == [.signInOnNetworkDNS])
        #expect(runner.outcome == .fixed)
    }

    @MainActor @Test func lookupsFailingAgainAfterTheRestoreIsSaid() async {
        let bench = Bench([FixReading(portal: false), signedIn, signedIn, signedIn, pingOnly])
        let runner = await run(bench)
        #expect(runner.outcome == .fixed && runner.restoreBroke)
    }

    // MARK: Fix it: the router

    @Test func aRestartBeingFollowedUpIsNotASlowdown() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var record = RouterRecord(network: "home", mac: "f4:92:bf:10:20:30", name: "Home", lastSeen: now)
        var restart = RouterRestart(date: now.addingTimeInterval(-86_400), source: .button)
        restart.outcome = .fixed; restart.before = 70; restart.after = 4; restart.checked = now.addingTimeInterval(-3_600)
        record.restarts = [restart]
        let report = RouterReport(record, now: now)
        #expect(report.showsFinding && report.state != .degraded && report.followUp != nil)
    }

    @Test func aSlowingRouterOffersTheRestart() {
        #expect(!FixCause.router.metric(FixReading(routerMs: 12, routerSlowing: true)).good)
        let steps = FixPlanner.steps(for: .router, helper: true)
        #expect(FixEngine(cause: .router, steps: steps, baseline: FixReading(routerMs: 12, routerSlowing: true)).command == .person(FixStep(id: 0, action: .restartRouter)))
        #expect(FixEngine(cause: .router, steps: steps, baseline: FixReading(routerMs: 12)).command == .finish(.noIssue))
    }

    // MARK: Health's advice

    private func ping(_ ms: [Double], loss: Double?, host: String = "1.1.1.1") -> PingResult { PingResult(host: host, samples: ms, lossPercent: loss) }
    private func sample(internet: PingResult, secondary: PingResult?) -> DiagnosticSnapshot {
        let radio = RadioSample.basic(ssid: "Home", interface: "en0", rssi: -50, noise: -95, transmitMbps: 400, channel: 36, band: "5 GHz")
        var value = DiagnosticSnapshot(date: Date(), radio: radio, gateway: "192.168.1.1", router: ping([3, 3], loss: 0, host: "192.168.1.1"), internet: internet,
                                       dnsMilliseconds: 20, dnsServers: ["192.168.1.1"], captivePortal: nil, networkService: "Wi-Fi")
        value.secondary = secondary
        return value
    }

    @Test func adviceReadsTheTargetThatAnswered() {
        let filtered = sample(internet: ping([], loss: 100), secondary: ping([18, 19], loss: 0, host: "8.8.8.8"))
        #expect(!filtered.advice.contains { $0.hasPrefix("Some internet ping replies were lost") })
        #expect(filtered.advice.contains { $0.hasPrefix("The internet ping target did not reply") })
        let slow = sample(internet: ping([], loss: 100), secondary: ping([200, 210], loss: 0, host: "8.8.8.8"))
        #expect(slow.advice.contains { $0.hasPrefix("Your router responds quickly") })
    }

    // MARK: Device types

    private func classify(hostname: String) -> DeviceGuess { DeviceClassifier.classify(signals: nil, vendor: nil, hostname: hostname) }

    @Test func anOwnersNameDoesNotTypeTheDevice() {
        let phone = classify(hostname: "Charlottes-iPhone")
        #expect(phone.type == .phone && phone.brand == "Apple" && phone.confidence == .medium)
        #expect(classify(hostname: "Carlos-MacBook-Pro").type == .computer)
        #expect(classify(hostname: "Arlos-iPad").type == .phone)
        #expect(classify(hostname: "Marlons-iPad").type == .phone)
        #expect(classify(hostname: "Shellys-iPhone").type == .phone)
        #expect(classify(hostname: "Kasandras-iPhone").type == .phone)
        #expect(classify(hostname: "Carlos-PC").type == .computer)
        // The brands' own names still read as theirs.
        #expect(classify(hostname: "Arlo-Pro-4").type == .camera)
        #expect(classify(hostname: "VMC4040P").type == .camera)
        #expect(classify(hostname: "shellyplug-s-A1B2C3").type == .plug)
        #expect(CameraUpload.cameras([KnownDevice(mac: "a8:00:00:00:00:02", hostname: "Charlottes-iPhone", firstSeen: Date(timeIntervalSince1970: 1_800_000_000))]).isEmpty)
    }

    // MARK: Destination history

    @Test func anAppPastItsCapKeepsOneOtherSitesRow() {
        var records: [DestinationRecord] = [], index: [String: Int] = [:]
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func add(_ host: String, _ bytes: UInt64, at date: Date = now) {
            DestinationHistory.add(app: "Torrent", host: host, address: nil, received: bytes, sent: 0, at: date, to: &records, index: &index, calendar: calendar)
        }
        for n in 0..<DestinationHistory.maxHostsPerDay { add("peer\(n).example", 10) }
        add("late1.example", 100); add("late2.example", 200)
        #expect(records.count == DestinationHistory.maxHostsPerDay + 1)
        #expect(records.first { $0.host == "" }?.received == 300)
        add("peer0.example", 5)
        #expect(records.first { $0.host == "peer0.example" }?.received == 15)
        add("late1.example", 7, at: now.addingTimeInterval(86_400))
        #expect(records.last?.host == "late1.example" && records.last?.received == 7)
    }

    // MARK: Data packs

    @Test func aHugeCorrectionIsRefusedWhereItIsParsed() throws {
        #expect(throws: DataPackError.self) { try PackCommand.parse(["correct", "50000000000"]) }
        #expect(try PackCommand.parse(["correct", "10000"]).command == .correct(leftGB: 10_000, pack: nil))
    }

    @Test func anOldCorrectionIsNotWrittenToTheLedger() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var pack = try DataPack.make(gb: 10, days: 90, start: now.addingTimeInterval(-50 * 86_400), networks: DataPackNetworks(keys: ["phone": "Phone"]), calendar: calendar)
        pack.correction = DataPackCorrection(at: now.addingTimeInterval(-40 * 86_400), leftBytes: 9_000_000_000, macBytes: 0)
        let status = DataPackStatus(pack: pack, used: 1_000_000_000, macBytes: 1_000_000_000, left: 9_000_000_000, state: .active, perDay: nil, paceDays: 0,
                                    runsOut: nil, daysEarly: nil, now: now)
        var ledger = AlertLedger()
        #expect(DataPackAlert.due([status], ledger: &ledger, now: now, calendar: calendar).isEmpty)
        #expect(ledger == AlertLedger())
    }

    // MARK: Cloud gaming

    @Test func twoSamplesReadTogetherDontMultiplyTheRate() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000), id = "udp4 192.168.1.20:54000<->203.0.113.7:49004"
        func snapshot(_ at: TimeInterval, _ received: UInt64) -> TrafficSnapshot {
            TrafficSnapshot(timestamp: t0.addingTimeInterval(at), processes: [ProcessTraffic(pid: 20, process: "p20", received: received, sent: 0,
                connections: [ConnectionTraffic(id: id, route: .internet, interface: "en0", received: received, sent: 0)])])
        }
        let client: (ProcessTraffic) -> CloudGamingFlows.Client? = { $0.pid == 20 ? .app("geforcenow") : nil }
        var flows = CloudGamingFlows()
        flows.ingest(snapshot(0, 0), client: client)
        flows.ingest(snapshot(1, 3_000_000), client: client)
        let seconds = flows.ingest(snapshot(1.0002, 6_000_000), client: client)
        #expect(seconds[.app("geforcenow")]?.down == 3_000_000)
    }

    // MARK: App names

    @Test func anAppsNameIsTheSameWhenAskedAgain() {
        let first = AppTrafficGroup.displayName("/System/Applications/Mail.app")
        #expect(AppTrafficGroup.displayName("/System/Applications/Mail.app") == first)
        #expect(!first.hasSuffix(".app"))
    }

    // MARK: Alert ledger

    @Test func aThresholdStillPassedDoesntChangeTheLedger() {
        var ledger = AlertLedger()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ledger.crossed([80], fraction: 0.9, key: "k", now: t0) == [80])
        let saved = ledger
        #expect(ledger.crossed([80], fraction: 0.9, key: "k", now: t0.addingTimeInterval(30)).isEmpty)
        #expect(ledger == saved)
        _ = ledger.crossed([80], fraction: 0.9, key: "k", now: t0.addingTimeInterval(2 * 86_400))
        ledger.prune(now: t0.addingTimeInterval(36 * 86_400))
        #expect(ledger.crossed([80], fraction: 0.9, key: "k", now: t0.addingTimeInterval(36 * 86_400)).isEmpty)
    }
}
