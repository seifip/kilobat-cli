import Foundation
import Testing
@testable import KilobatCore

/// What one background health check costs. The counters are global: run this suite alone
/// (`--filter HealthCheckCostTests`) when reading the printed numbers.
@Suite(.serialized) struct HealthCheckCostTests {
    /// Launches read-only system tools and sends a few pings and one DNS query, so only on request:
    /// `KILOBAT_COST_BASELINE=1` with `--filter HealthCheckCostTests`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KILOBAT_COST_BASELINE"] != nil))
    func printsLaunchesPerCheck() async {
        _ = IdleCounters.take()
        _ = await DiagnosticProbe().snapshot(checkPortal: false)
        print("COST snapshot: \(Self.line(IdleCounters.take()))")
        _ = await ExitPath.current()
        print("COST exit: \(Self.line(IdleCounters.take()))")
    }
    @Test func checksRunFastOnlyWhileHealthSpeedOrRadarShows() {
        #expect(DiagnosticStore.checkDelay(visible: true, interval: 12, lowPower: false) == 12)
        #expect(DiagnosticStore.checkDelay(visible: true, interval: 30, lowPower: false) == 30)
        #expect(DiagnosticStore.checkDelay(visible: false, interval: 12, lowPower: false) == 60)
        #expect(DiagnosticStore.checkDelay(visible: false, interval: 300, lowPower: false) == 300)
        #expect(DiagnosticStore.checkDelay(visible: false, interval: 12, lowPower: true) == 120)
    }
    @Test func offlineChecksBackOffAfterTheOutageIsRecorded() {
        #expect((1...6).map { DiagnosticStore.offlineDelay(failures: $0) } == [60, 60, 120, 300, 300, 300])
        #expect(DiagnosticStore.expectedGap(offlineChecks: 0, interval: 12) == 60)
        #expect(DiagnosticStore.expectedGap(offlineChecks: 4, interval: 12) == 300)
        #expect(DiagnosticStore.expectedGap(offlineChecks: 1, interval: 600) == 600)
    }
    /// The offline check's sample, on the backed-off schedule: the outage opens at the third check as before, the long
    /// waits don't read as a pause, the router counts fill in, and two good checks close it.
    @MainActor @Test func offlineScheduleStillRecordsAndClosesTheOutage() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-offline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: path) }
        let journal = NetworkJournal(directory: path); journal.alerts = false
        let radio = RadioSample(ssid: "Network", interface: "en0", rssi: -50, noise: -90, transmitMbps: 100, channel: 1, band: "2.4 GHz")
        var offline = DiagnosticSnapshot(date: Date(), radio: radio, gateway: "192.168.1.1", router: PingResult(host: "192.168.1.1", samples: [], lossPercent: 100),
                                         internet: DiagnosticProbe.unanswered("1.1.1.1"), dnsMilliseconds: nil, dnsServers: [], captivePortal: false, networkService: "Wi-Fi")
        offline.secondary = DiagnosticProbe.unanswered("8.8.8.8"); offline.httpReachable = false
        #expect(offline.reachability == .down)
        let start = Date()
        var at = 0.0, checks = 0
        func check(_ sample: DiagnosticSnapshot, offlineBefore: Int, secondary: PingResult, http: Bool?) {
            journal.ingest(sample, secondary: secondary, httpReachable: http, interval: DiagnosticStore.expectedGap(offlineChecks: offlineBefore, interval: 12),
                           date: start.addingTimeInterval(at))
        }
        for _ in 0..<6 {
            checks += 1
            check(offline, offlineBefore: checks, secondary: offline.secondary!, http: false)
            if checks == 3 {
                #expect(journal.events.filter { $0.kind == "Unreachable" }.count == 1)
                #expect(at == 120)  // the same two minutes after the first failed check as at the usual cadence
            }
            at += DiagnosticStore.offlineDelay(failures: checks)
        }
        let open = journal.events.filter { $0.kind == "Unreachable" }
        #expect(open.count == 1 && open[0].end == nil)
        #expect(open[0].routerChecks == 6 && open[0].routerAnswered == 0)
        let up = DiagnosticSnapshot(date: Date(), radio: radio, gateway: "192.168.1.1", router: PingResult(host: "192.168.1.1", samples: [2], lossPercent: 0),
                                    internet: PingResult(host: "1.1.1.1", samples: [20, 21], lossPercent: 0), dnsMilliseconds: 5, dnsServers: [], captivePortal: false, networkService: "Wi-Fi")
        let reply = PingResult(host: "8.8.8.8", samples: [20], lossPercent: 0)
        // The path came back partway through a five-minute wait: checked at once, then a minute later.
        at -= 200
        check(up, offlineBefore: checks, secondary: reply, http: nil)
        at += 60
        check(up, offlineBefore: 0, secondary: reply, http: nil)
        let closed = journal.events.filter { $0.kind == "Unreachable" }
        #expect(closed.count == 1 && closed[0].end != nil)
        #expect(closed[0].detail.contains("Recovered"))
    }
    @Test func runnerLooksAtALongCommandFiveTimesASecond() async {
        // The polls a two-second command costs, from the schedule itself (the counter is shared with every other suite).
        var pause = 5, slept = 0, polls = 0
        while slept < 2000 { polls += 1; slept += pause; pause = CommandRunner.nextPause(after: pause) }
        #expect(polls < 25)
        #expect([5, 10, 20, 40].map { CommandRunner.nextPause(after: $0) } == [10, 20, 40, 80])
        let started = ContinuousClock.now
        let result = await CommandRunner.run("/usr/bin/true", [])
        #expect(result.status == 0)
        // A loose bound: the schedule above is what is tested, and a loaded machine can take a while to start a process.
        #expect(ContinuousClock.now - started < .seconds(5))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KILOBAT_COST_BASELINE"] != nil))
    func printsPollsForATwoSecondCommand() async {
        _ = IdleCounters.take()
        _ = await CommandRunner.run("/bin/sleep", ["2"])
        let polls = IdleCounters.take()["runner poll"] ?? 0
        print("COST sleep 2: runner poll=\(polls)")
        #expect(polls < 25)
    }
    static func line(_ counts: [String: Int]) -> String { counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") }
}
