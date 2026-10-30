import Foundation
import Testing
@testable import KilobatCore

@MainActor struct AwakeOnPowerTests {
    let start = Date()
    final class Power {
        var state = PowerState(batteryPercent: 80, onAC: false, thermal: "nominal", lowPowerMode: false)
        func plug(_ onAC: Bool) { state = PowerState(batteryPercent: 80, onAC: onAC, thermal: "nominal", lowPowerMode: false) }
    }

    /// The adapter is whatever the test says, and the test reports each switch itself, as the watcher would.
    /// A suite the test names lasts across stores, for a relaunch; the caller removes it.
    private func store(_ power: Power, suite named: String? = nil) -> SessionStore {
        let suite = named ?? "co.seifi.kilobat.tests." + UUID().uuidString
        let sessions = SessionStore(defaults: UserDefaults(suiteName: suite)!)
        defer { if named == nil { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) } }
        sessions.probe = FakeProcesses().probe
        sessions.observesWorkspace = false
        sessions.readPower = { power.state }
        sessions.notify = false; sessions.webhook = ""; sessions.keepAwakeForAgents = false
        sessions.allowLidClosed = false; sessions.lidClosedForAwake = false; sessions.keepDisplayOn = false
        return sessions
    }
    private func plug(_ sessions: SessionStore, _ power: Power, _ onAC: Bool, at seconds: TimeInterval) {
        power.plug(onAC); sessions.powerChanged(now: start + seconds)
    }

    @Test func pluggingInStartsItAndUnpluggingEndsIt() {
        let power = Power(), sessions = store(power)
        sessions.awakeOnPower = true
        #expect(sessions.awake == nil && !sessions.holdingAwake)
        plug(sessions, power, true, at: 5)
        #expect(sessions.mode == .indefinite && sessions.awakeByPower && sessions.holdingAwake)
        #expect(sessions.awakeTitle == "While plugged in" && sessions.awake?.title == "While plugged in")
        // Another notification with the adapter still in changes nothing.
        let id = sessions.awake?.id
        sessions.powerChanged(now: start + 6)
        #expect(sessions.awake?.id == id)
        plug(sessions, power, false, at: 10)
        #expect(sessions.awake == nil && !sessions.awakeByPower && !sessions.holdingAwake)
        #expect(sessions.history.first?.ended == "Unplugged" && sessions.history.first?.title == "While plugged in")
        plug(sessions, power, true, at: 15)
        #expect(sessions.awakeByPower)
    }

    @Test func turningItOffWaitsForTheNextPlugIn() {
        let power = Power(), sessions = store(power)
        sessions.awakeOnPower = true
        plug(sessions, power, true, at: 5)
        sessions.stop(now: start + 10)
        #expect(sessions.awake == nil && sessions.powerSuppressed && sessions.history.first?.ended == "Turned off")
        // Not on another notification, and not by turning the setting off and on during this plug-in.
        sessions.powerChanged(now: start + 12)
        sessions.awakeOnPower = false; sessions.awakeOnPower = true
        #expect(sessions.awake == nil)
        plug(sessions, power, false, at: 20)
        plug(sessions, power, true, at: 25)
        #expect(sessions.awakeByPower && !sessions.powerSuppressed)
    }

    @Test func turningItOffLastsAcrossARelaunchOnTheSamePlugIn() {
        let power = Power(), suite = "co.seifi.kilobat.tests." + UUID().uuidString
        power.plug(true)
        let first = store(power, suite: suite)
        first.awakeOnPower = true
        #expect(first.awakeByPower)
        first.stop(now: start + 5)
        let second = store(power, suite: suite)
        second.watchPower(now: start + 10)
        #expect(second.awakeOnPower && second.awake == nil && second.powerSuppressed)
        // Launching on battery clears it.
        power.plug(false)
        let third = store(power, suite: suite)
        third.watchPower(now: start + 20)
        #expect(!third.powerSuppressed)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @Test func launchingOrTurningItOnWhilePluggedInStartsIt() {
        let power = Power(), suite = "co.seifi.kilobat.tests." + UUID().uuidString
        power.plug(true)
        UserDefaults(suiteName: suite)!.set(true, forKey: "awake.power")
        let launched = store(power, suite: suite)
        // Reading the setting alone starts nothing, as in the CLI; the app's launch does.
        #expect(launched.awakeOnPower && launched.awake == nil)
        launched.watchPower(now: start)
        #expect(launched.awakeByPower && launched.holdingAwake)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)

        let turnedOn = store(power)
        turnedOn.awakeOnPower = true
        #expect(turnedOn.awakeByPower && turnedOn.mode == .indefinite)
    }

    @Test func turningTheSettingOffEndsOnlyItsOwnSession() {
        let power = Power(), sessions = store(power)
        power.plug(true)
        sessions.awakeOnPower = true
        sessions.awakeOnPower = false
        #expect(sessions.awake == nil && !sessions.holdingAwake && sessions.history.first?.ended == "Turned off" && !sessions.powerSuppressed)
        sessions.start(.indefinite, now: start + 5)
        sessions.awakeOnPower = true
        sessions.awakeOnPower = false
        #expect(sessions.mode == .indefinite && !sessions.awakeByPower && sessions.holdingAwake)
    }

    @Test func pluggingLeavesEverythingElseAlone() {
        let power = Power(), sessions = store(power)
        sessions.keepAwakeForAgents = true; sessions.allowLidClosed = true
        sessions.awakeOnPower = true
        // A session started by hand on battery is neither replaced by plugging in nor ended by unplugging.
        sessions.start(.indefinite, now: start)
        plug(sessions, power, true, at: 5)
        #expect(sessions.mode == .indefinite && !sessions.awakeByPower)
        plug(sessions, power, false, at: 10)
        #expect(sessions.mode == .indefinite && sessions.history.isEmpty)
        sessions.stop(now: start + 12)
        #expect(!sessions.powerSuppressed)

        // A transfer, a frontmost condition, an agent run and a CLI lid hold, all going when the adapter comes out.
        let keynote = FrontmostCondition(app: "com.apple.Keynote", name: "Keynote", display: true)
        sessions.start(.untilQuiet(app: "com.example.Sync", name: "Sync"), now: start + 15)
        sessions.watchFrontmost(keynote, current: "com.apple.Keynote", now: start + 15)
        sessions.receive(AgentEvent(kind: .working, agent: "claude", session: "s1", time: start + 15))
        sessions.holdLid(owner: getpid(), until: start + 3600, reason: "kilobat awake", now: start + 15)
        plug(sessions, power, true, at: 20)
        plug(sessions, power, false, at: 25)
        #expect(sessions.mode == .untilQuiet(app: "com.example.Sync", name: "Sync") && !sessions.awakeByPower)
        #expect(sessions.frontmost == keynote && sessions.holdingFrontmost)
        #expect(sessions.agents["Claude Code|s1"]?.state == .working && sessions.lidRequest?.reason.contains("kilobat awake") == true)
        #expect(sessions.history.count == 1)

        // With the plugged-in session running beside them, unplugging ends only it.
        sessions.stop(now: start + 30)
        sessions.watchFrontmost(keynote, current: "com.apple.Keynote", now: start + 30)
        plug(sessions, power, true, at: 35)
        #expect(sessions.awakeByPower)
        plug(sessions, power, false, at: 40)
        #expect(sessions.awake == nil && sessions.history.first?.ended == "Unplugged")
        #expect(sessions.frontmost == keynote && sessions.agents.count == 1 && sessions.holdingAwake && sessions.lidRequest != nil)
    }

    @Test func startingASessionByHandTakesItOver() {
        let power = Power(), sessions = store(power)
        sessions.awakeOnPower = true
        plug(sessions, power, true, at: 5)
        sessions.start(.timer(until: start + 3600), now: start + 10)
        #expect(!sessions.awakeByPower && sessions.history.first?.ended == "Replaced")
        plug(sessions, power, false, at: 15)
        #expect(sessions.mode == .timer(until: start + 3600))
    }

    @Test func theScreenChoiceApplies() {
        let power = Power(), sessions = store(power)
        sessions.awakeOnPower = true
        plug(sessions, power, true, at: 5)
        #expect(sessions.holdingAwake && !sessions.displayHeld)
        // One screen setting for everything the app keeps awake, the plugged-in session included.
        sessions.keepDisplayOn = true
        #expect(sessions.holdingAwake && sessions.displayHeld)
        sessions.keepDisplayOn = false
        #expect(sessions.holdingAwake && !sessions.displayHeld)
    }

    @Test func neverAsksForTheLid() {
        let power = Power(), sessions = store(power)
        sessions.allowLidClosed = true; sessions.lidClosedForAwake = true
        sessions.awakeOnPower = true
        plug(sessions, power, true, at: 5)
        sessions.tick(apps: [], interval: 2, now: start + 7)
        #expect(sessions.awakeByPower && sessions.lidRequest == nil)
        // A session started by hand would.
        sessions.start(.indefinite, now: start + 10)
        #expect(sessions.lidRequest != nil)
    }
}
