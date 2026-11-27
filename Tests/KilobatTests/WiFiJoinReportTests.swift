import Foundation
import Testing
@testable import KilobatCore

struct WiFiJoinReportTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let bssid = "aa:bb:cc:dd:ee:12"
    let ssid = "Hotel <Guest>"

    private func attempt(stage: WiFiJoinAttempt.Stage, date: Date, bssid: String) -> WiFiJoinAttempt {
        var value = WiFiJoinAttempt(name: ssid, started: date)
        let ap = WiFiJoinAttempt.accessPoint(bssid)
        value.steps = [.init(date: date, stage: .seen, ap: ap), .init(date: date + 1, stage: .joining, ap: ap),
                       .init(date: date + 2, stage: stage, ap: ap, suffix: String(bssid.suffix(5)),
                             domain: stage == .joinFailed ? "com.apple.wifi" : nil, code: stage == .joinFailed ? -3958 : nil)]
        return value
    }

    @Test @MainActor func selectedFailureSurvivesRelaunchAndUnrelatedAttempts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = NetworkJournal(directory: dir)
        let first = attempt(stage: .joinFailed, date: now - 30, bssid: bssid)
        let other = attempt(stage: .joinFailed, date: now - 10, bssid: "11:22:33:44:55:66")
        let selected = attempt(stage: .joinFailed, date: now, bssid: bssid)
        for item in [first, other, selected] { journal.record(item) }
        let reloaded = NetworkJournal(directory: dir)
        #expect(reloaded.joinAttempts.map(\.id) == [first.id, other.id, selected.id])
        let report = reloaded.joinReport(try #require(reloaded.joinAttempts.last))
        #expect(report.name == ssid)
        #expect(report.lines.filter { $0.contains("-3958") }.count == 2)
        #expect(!report.text.contains("55:66"))
        #expect(!report.text.contains(bssid))
        #expect(report.text.contains("ee:12"))
        #expect(report.summary.contains("could not confirm"))
        #expect(report.html.contains("Hotel &lt;Guest&gt;"))
    }

    @Test func healthRequiresAJoinedTargetAndAFreshCheckOnItsRadio() {
        var joined = attempt(stage: .joined, date: now, bssid: bssid)
        var radio = RadioSample.basic(bssid: bssid, ssid: ssid, interface: "en0", rssi: -54, noise: nil, transmitMbps: nil, channel: 44, band: "5 GHz")
        func snapshot() -> DiagnosticSnapshot {
            var sample = DiagnosticSnapshot(date: now + 5, radio: radio, gateway: nil, router: nil,
                                            internet: .init(host: "test", samples: [], lossPercent: 100),
                                            dnsMilliseconds: nil, dnsServers: [], networkService: nil)
            sample.radioAddress = LinkAddressState.none
            return sample
        }
        let oldCheck = joined.observe(snapshot(), startedAt: now)
        #expect(!oldCheck)
        var wired = snapshot()
        wired.wiredInterface = "en5"
        let wiredCheck = joined.observe(wired, startedAt: now + 3)
        #expect(!wiredCheck)
        var failed = attempt(stage: .joinFailed, date: now, bssid: bssid)
        let lateJoin = failed.observe(snapshot(), startedAt: now + 3, probesRan: false)
        #expect(lateJoin)
        #expect(failed.checks.last?.internet == nil)
        #expect(failed.checks.last?.dns == nil)
        let lateReport = WiFiJoinReport(attempt: failed, history: [failed], tests: [])
        #expect(lateReport.text.contains("-3958"))
        #expect(lateReport.summary.contains("no usable network address"))
        let targetCheck = joined.observe(snapshot(), startedAt: now + 3)
        #expect(targetCheck)
        let duplicate = joined.observe(snapshot(), startedAt: now + 3)
        #expect(!duplicate)
        radio.bssid = "aa:bb:cc:dd:ee:13"
        let otherRadio = joined.observe(snapshot(), startedAt: now + 3)
        #expect(!otherRadio)
        #expect(joined.problem)
        #expect(WiFiJoinReport(attempt: joined, history: [joined], tests: []).summary.contains("no usable network address"))
    }

    @Test func roundTripThroughHotspotInvalidatesSpeedEvenWhenTheRadioMatchesAgain() {
        let start = WiFiSpeedPath(name: ssid, accessPoint: "radio", revision: 1)
        let returned = WiFiSpeedPath(name: ssid, accessPoint: "radio", revision: 3)
        let context = SpeedTestContext(kind: "Wi-Fi", ssid: ssid)
        #expect(start.verified(endingOn: start, context: context) == "radio")
        #expect(start.verified(endingOn: returned, context: context) == nil)
        #expect(start.verified(endingOn: nil, context: context) == nil)
        #expect(start.verified(endingOn: start, context: SpeedTestContext(kind: "Ethernet", ssid: ssid)) == nil)
    }

    @Test func excludesOtherRoutesOldMeasurementsAndTestsWithoutContinuityProof() {
        let selected = attempt(stage: .joinFailed, date: now, bssid: bssid)
        let ping = PingResult(host: "test", samples: [], lossPercent: nil)
        func test(rate: Double, name: String, ap: String?, changed: Bool? = false, offset: Double = 20) -> SavedSpeedTest {
            SavedSpeedTest(networkKey: "key", networkName: name, networkChanged: changed, verifiedAccessPoint: ap, verifiedStart: now + offset - 2,
                           result: SpeedTestResult(date: now + offset, downloadMbps: rate, uploadMbps: 2, baseline: ping, downloadLoaded: ping,
                                                   uploadLoaded: ping, downloadSeconds: 1, uploadSeconds: 1, transferredBytes: 100))
        }
        let ap = WiFiJoinAttempt.accessPoint(bssid)
        let tests = [test(rate: 34, name: ssid, ap: ap), test(rate: 51, name: "Hotspot", ap: ap),
                     test(rate: 52, name: ssid, ap: "other"), test(rate: 53, name: ssid, ap: nil),
                     test(rate: 54, name: ssid, ap: ap, changed: true), test(rate: 55, name: ssid, ap: ap, offset: -1000)]
        let report = WiFiJoinReport(attempt: selected, history: [selected], tests: tests)
        let speeds = report.lines.filter { $0.contains("Mbps") }
        #expect(speeds.count == 1)
        #expect(speeds.first?.contains("34 Mbps") == true)
        #expect(!report.text.contains("Hotspot"))
        #expect(WiFiJoinAttempt.accessPoint("00:00:00:00:00:00") == nil)
    }
}
