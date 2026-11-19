import Foundation
import Testing
@testable import KilobatCore

/// The Bluetooth and AirDrop comparison, on simulated readings: nothing here touches a radio.
struct RadioComparisonTests {
    private func reading(_ p95: Double?, median: Double? = 4, spikes: Int = 0, mbps: Double? = nil) -> RadioReading {
        RadioReading(medianMs: median, p95Ms: p95, spikes: spikes, downloadMbps: mbps)
    }

    // MARK: AirDrop's channels

    @Test func socialChannelsShareAndOthersHop() {
        #expect(AWDLChannels.fit(channel: 149, band: "5 GHz") == .shares)
        #expect(AWDLChannels.fit(channel: 44, band: "5 GHz") == .shares)
        #expect(AWDLChannels.fit(channel: 6, band: "2.4 GHz") == .shares)
        #expect(AWDLChannels.fit(channel: 36, band: "5 GHz") == .offChannel)
        #expect(AWDLChannels.fit(channel: 11, band: "2.4 GHz") == .offChannel)
        // 6 GHz numbers overlap 5 GHz ones, but AirDrop's link isn't on 6 GHz.
        #expect(AWDLChannels.fit(channel: 149, band: "6 GHz") == .offChannel)
        #expect(AWDLChannels.fit(channel: nil, band: "5 GHz") == .unknown)
        #expect(AWDLChannels.fit(channel: 36, band: nil) == .unknown)
    }
    @Test func channelNoteNamesTheChannelAndTheFix() {
        let note = AWDLChannels.note(channel: 36, band: "5 GHz")
        #expect(note?.contains("channel 36") == true && note?.contains("149 or 44") == true)
        #expect(AWDLChannels.note(channel: 149, band: "5 GHz")?.contains("rarely has to leave") == true)
        #expect(AWDLChannels.note(channel: nil, band: nil) == nil)
        #expect(AWDLChannels.note(channel: 1, band: "2.4 GHz")?.contains("channel 6") == true)
    }
    @Test func periodicStutterVerdictAddsTheChannel() {
        // Spikes every second on the router, AirDrop's link up and the Wi-Fi on channel 36.
        var samples = [Double?](repeating: 4, count: 400)
        for beat in stride(from: 10, to: 400, by: 20) { samples[beat] = 140 }
        var result = StutterTest.analyze(samples, target: "router", host: "192.168.1.1", awdl: AWDLStatus(available: true, up: true, active: true))
        #expect(result.pattern == .periodic)
        result.channel = 36; result.band = "5 GHz"
        #expect(result.verdict.contains("channel 36"))
        // Paused, AirDrop can't be the cause, so its channel isn't either.
        var paused = StutterTest.analyze(samples, target: "router", host: "192.168.1.1", awdl: AWDLStatus(available: true, up: false, active: false))
        paused.channel = 36; paused.band = "5 GHz"
        #expect(!paused.verdict.contains("channel 36") && paused.verdict.contains("paused"))
    }

    // MARK: Judging one switch

    @Test func bluetoothOffClearlyFasterIsHelped() {
        // The r/MacOS M5 Air readings: 260 Mbps with Bluetooth on and idle, 380 with it off.
        let effect = RadioComparison.effect(.bluetooth, before: reading(9, mbps: 260), off: reading(8, mbps: 380), back: reading(10, mbps: 255))
        #expect(effect.speed == .better && effect.latency == .same && effect.helped)
    }
    @Test func spikesThatGoAwayCountEvenWhenP95HidesThem() {
        let effect = RadioComparison.effect(.airDrop, before: reading(12, spikes: 9), off: reading(11, spikes: 1), back: reading(12, spikes: 8))
        #expect(effect.latency == .better)
    }
    @Test func lowerPingIsHelped() {
        let effect = RadioComparison.effect(.airDrop, before: reading(120), off: reading(18), back: reading(110))
        #expect(effect.latency == .better)
        #expect(RadioComparison.line(effect).contains("120") && RadioComparison.line(effect).contains("18"))
    }
    @Test func aChangeThatStaysAfterwardsIsNotTheSwitch() {
        // Better with it off, and still better once it was back: the line improved by itself.
        let effect = RadioComparison.effect(.bluetooth, before: reading(120), off: reading(18), back: reading(20))
        #expect(effect.latency == .unclear && !effect.helped && effect.unclear)
    }
    @Test func smallMovesAreNoChange() {
        let effect = RadioComparison.effect(.bluetooth, before: reading(30, mbps: 300), off: reading(26, mbps: 320), back: reading(31, mbps: 295))
        #expect(effect.latency == .same && effect.speed == .same && !effect.helped && !effect.unclear)
    }
    @Test func worseWithItOffIsWorse() {
        let effect = RadioComparison.effect(.airDrop, before: reading(20), off: reading(90), back: reading(22))
        #expect(effect.latency == .worse)
    }
    @Test func noDownloadOnMeteredIsNotMeasured() {
        let effect = RadioComparison.effect(.bluetooth, before: reading(20), off: reading(19), back: reading(21))
        #expect(effect.speed == .notMeasured)
    }

    // MARK: Verdicts

    @Test func noneHelpedSaysSoWithoutAnotherToggle() {
        let flat = RadioComparison.effect(.bluetooth, before: reading(40), off: reading(38), back: reading(41))
        let still = RadioComparison.effect(.airDrop, before: reading(41), off: reading(42), back: reading(39))
        let comparison = RadioComparison(effects: [flat, still], channel: 149, band: "5 GHz")
        #expect(comparison.verdict == .noneHelped)
        #expect(comparison.detail.contains("macOS or the Wi-Fi firmware"))
        #expect(!comparison.detail.contains("Pause AirDrop") && !comparison.detail.contains("Turn Bluetooth off"))
    }
    @Test func bluetoothOn5GHzPointsAtMacOSAndTheChannelLink() {
        let effect = RadioComparison.effect(.bluetooth, before: reading(9, mbps: 30), off: reading(8, mbps: 190), back: reading(9, mbps: 28))
        let comparison = RadioComparison(effects: [effect], channel: 36, band: "5 GHz")
        #expect(comparison.verdict == .helped([.bluetooth]))
        #expect(comparison.detail.contains("Feedback Assistant") && comparison.detail.contains("149"))
        // Already on 149: no channel suggestion.
        #expect(!RadioComparison(effects: [effect], channel: 149, band: "5 GHz").detail.contains("to 149"))
        // On 2.4 GHz the advice is the band.
        #expect(RadioComparison(effects: [effect], channel: 6, band: "2.4 GHz").detail.contains("5 GHz network"))
    }
    @Test func airDropOffChannelSuggestsItsChannel() {
        let effect = RadioComparison.effect(.airDrop, before: reading(140), off: reading(15), back: reading(150))
        let comparison = RadioComparison(effects: [effect], channel: 36, band: "5 GHz")
        #expect(comparison.verdict == .helped([.airDrop]))
        #expect(comparison.detail.contains("channel 36") && comparison.detail.contains("Pause AirDrop"))
    }
    @Test func bothHelpedNamesBoth() {
        let bluetooth = RadioComparison.effect(.bluetooth, before: reading(9, mbps: 160), off: reading(8, mbps: 380), back: reading(9, mbps: 150))
        let airDrop = RadioComparison.effect(.airDrop, before: reading(140), off: reading(15), back: reading(150))
        #expect(RadioComparison(effects: [bluetooth, airDrop]).verdict == .helped([.bluetooth, .airDrop]))
    }
    @Test func nothingTestedWhenBothWereOff() {
        let comparison = RadioComparison(effects: [], skipped: [.bluetooth: .alreadyOff, .airDrop: .unavailable])
        #expect(comparison.verdict == .nothingTested)
        #expect(comparison.plainSummary.contains("bluetooth: not tested (alreadyOff)"))
    }

    // MARK: Where it's offered

    @Test func offeredAfterUnfixedRadioCausesOnWiFi() {
        #expect(RadioCheckPolicy.offered(after: .airDrop(.call("Zoom")), outcome: .notYourMac(.provider), onWiFi: true))
        #expect(RadioCheckPolicy.offered(after: .router, outcome: .better, onWiFi: true))
        #expect(!RadioCheckPolicy.offered(after: .router, outcome: .fixed, onWiFi: true))
        #expect(!RadioCheckPolicy.offered(after: .router, outcome: .notYourMac(.router), onWiFi: false))
        #expect(!RadioCheckPolicy.offered(after: .dnsSlow, outcome: .notYourMac(.provider), onWiFi: true))
    }
    @Test func stutterOffersItForLocalSpikesOnly() {
        var samples = [Double?](repeating: 4, count: 200)
        samples[50] = 200; samples[120] = 220
        let local = StutterTest.analyze(samples, target: "router", host: "192.168.1.1")
        #expect(local.pattern == .few && RadioCheckPolicy.offered(after: local))
        let internet = StutterTest.analyze(samples, target: "internet", host: "1.1.1.1")
        #expect(!RadioCheckPolicy.offered(after: internet))
        let steady = StutterTest.analyze([Double?](repeating: 4, count: 200), target: "router", host: "192.168.1.1")
        #expect(!RadioCheckPolicy.offered(after: steady))
    }
}

/// The comparison run itself, with switches that only record what they were asked.
@MainActor final class RadioBench {
    var on: [RadioSwitch: Bool?]
    var readings: [RadioStage: RadioReading]
    var calls: [String] = []
    var failing: Set<RadioSwitch> = []
    /// Presses Stop when this reading starts.
    var stopAt: RadioStage?
    weak var runner: RadioCheckRunner?
    init(on: [RadioSwitch: Bool?], readings: [RadioStage: RadioReading]) { self.on = on; self.readings = readings }
    var actions: RadioCheckRunner.Actions {
        RadioCheckRunner.Actions(
            measure: { [unowned self] stage in
                self.calls.append("measure \(stage.rawValue)")
                if stage == self.stopAt { self.runner?.stop() }
                return self.readings[stage]
            },
            isOn: { [unowned self] radio in self.on[radio] ?? nil },
            set: { [unowned self] radio, value in
                self.calls.append("\(radio.rawValue) \(value ? "on" : "off")")
                if self.failing.contains(radio), !value { throw DiagnosticError("cancelled") }
                self.on[radio] = value
            },
            wait: { _ in })
    }
}

@MainActor struct RadioCheckRunnerTests {
    private let slow = RadioReading(medianMs: 5, p95Ms: 9, spikes: 0, downloadMbps: 160)
    private let fast = RadioReading(medianMs: 5, p95Ms: 8, spikes: 0, downloadMbps: 380)

    /// Answers each question as it comes, until the run ends.
    private func drive(_ runner: RadioCheckRunner, answers: [Bool]) async {
        var answers = answers
        let task = Task { await runner.run() }
        for _ in 0..<200 where !runner.finished {
            if case .confirming = runner.phase { answers.isEmpty ? runner.stop() : (answers.removeFirst() ? runner.proceed() : runner.skip()) }
            await Task.yield()
        }
        await task.value
    }

    @Test func measuresEachSwitchOffAndBackAndRestores() async {
        let bench = RadioBench(on: [.bluetooth: true, .airDrop: true],
                               readings: [.asIs: slow, .bluetoothOff: fast, .bluetoothBack: slow, .airDropPaused: slow, .airDropBack: slow])
        let runner = RadioCheckRunner(channel: 36, band: "5 GHz", actions: bench.actions)
        await drive(runner, answers: [true, true])
        #expect(bench.calls == ["measure asIs", "bluetooth off", "measure bluetoothOff", "bluetooth on", "measure bluetoothBack",
                                "airDrop off", "measure airDropPaused", "airDrop on", "measure airDropBack"])
        #expect(runner.result?.verdict == .helped([.bluetooth]))
        #expect(bench.on[.bluetooth] == true && bench.on[.airDrop] == true && runner.switchedOff.isEmpty)
    }
    @Test func declinedSwitchIsSkippedAndNeverTouched() async {
        let bench = RadioBench(on: [.bluetooth: true, .airDrop: true], readings: [.asIs: slow, .airDropPaused: slow, .airDropBack: slow])
        let runner = RadioCheckRunner(actions: bench.actions)
        await drive(runner, answers: [false, true])
        #expect(!bench.calls.contains("bluetooth off"))
        #expect(runner.result?.skipped[.bluetooth] == .declined)
        #expect(runner.result?.verdict == .noneHelped)
    }
    @Test func stopPutsBluetoothBack() async {
        let bench = RadioBench(on: [.bluetooth: true, .airDrop: nil], readings: [.asIs: slow, .bluetoothOff: fast])
        let runner = RadioCheckRunner(actions: bench.actions)
        bench.stopAt = .bluetoothOff; bench.runner = runner
        await drive(runner, answers: [true])
        #expect(runner.phase == .stopped)
        #expect(bench.on[.bluetooth] == true)
        #expect(bench.calls.last == "bluetooth on")
    }
    @Test func aFailedSwitchIsReportedNotJudged() async {
        let bench = RadioBench(on: [.bluetooth: nil, .airDrop: true], readings: [.asIs: slow])
        bench.failing = [.airDrop]
        let runner = RadioCheckRunner(actions: bench.actions)
        await drive(runner, answers: [true])
        #expect(runner.result?.skipped[.airDrop] == .failed && runner.result?.skipped[.bluetooth] == .unavailable)
        #expect(runner.result?.verdict == .nothingTested)
        #expect(runner.error == "cancelled")
    }
    @Test func nothingToSwitchMeasuresNothing() async {
        let bench = RadioBench(on: [.bluetooth: false, .airDrop: nil], readings: [.asIs: slow])
        let runner = RadioCheckRunner(actions: bench.actions)
        await runner.run()
        #expect(bench.calls.isEmpty)
        #expect(runner.result?.verdict == .nothingTested)
    }
}
