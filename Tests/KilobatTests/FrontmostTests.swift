import Foundation
import Testing
@testable import KilobatCore

@MainActor struct FrontmostTests {
    let keynote = FrontmostCondition(app: "com.apple.Keynote", name: "Keynote", display: true)
    let start = Date()
    final class Power { var state = PowerState(batteryPercent: 80, onAC: true, thermal: "nominal", lowPowerMode: false) }

    /// Activations come from the test, not the workspace, and the battery is whatever the test says.
    private func store(_ power: Power = Power()) -> SessionStore {
        let suite = "co.seifi.kilobat.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let sessions = SessionStore(defaults: defaults)
        sessions.probe = FakeProcesses().probe
        sessions.observesWorkspace = false
        sessions.readPower = { power.state }
        sessions.notify = false; sessions.webhook = ""; sessions.keepAwakeForAgents = false
        sessions.allowLidClosed = false; sessions.lidBatteryFloor = 20
        defaults.removePersistentDomain(forName: suite)
        return sessions
    }

    @Test func holdsOnlyWhileTheAppIsInFront() {
        let sessions = store()
        sessions.watchFrontmost(keynote, current: "com.apple.finder", now: start)
        #expect(sessions.frontmost == keynote && !sessions.frontmostActive && !sessions.holdingAwake)
        sessions.activated("com.apple.Keynote", now: start + 5)
        #expect(sessions.frontmostActive && sessions.holdingFrontmost && sessions.holdingAwake)
        sessions.activated("com.apple.Safari", now: start + 10)
        #expect(!sessions.holdingFrontmost && !sessions.holdingAwake && sessions.frontmost == keynote)
        sessions.activated(nil, now: start + 12)
        #expect(!sessions.holdingFrontmost)
        sessions.activated("com.apple.Keynote", now: start + 15)
        #expect(sessions.holdingFrontmost)
        // Ticks don't change what focus decided.
        sessions.tick(apps: [], interval: 2, now: start + 17)
        #expect(sessions.holdingFrontmost && sessions.frontmostEnded == nil)
    }

    @Test func endsWhenItsAppQuits() {
        let sessions = store()
        sessions.watchFrontmost(keynote, current: "com.apple.Keynote", now: start)
        sessions.terminated("com.apple.Safari")
        #expect(sessions.holdingFrontmost)
        sessions.terminated("com.apple.Keynote")
        #expect(sessions.frontmost == nil && !sessions.holdingAwake && sessions.frontmostEnded == "Keynote quit")
        // Later activations of the app don't bring it back.
        sessions.activated("com.apple.Keynote", now: start + 5)
        #expect(!sessions.holdingAwake)
    }

    @Test func focusAndQuittingLeaveAgentsAndSessionsAlone() {
        let sessions = store()
        sessions.keepAwakeForAgents = true
        sessions.receive(AgentEvent(kind: .working, agent: "claude", session: "s1", time: start))
        sessions.start(.untilQuiet(app: "com.example.Sync", name: "Sync"), now: start)
        sessions.watchFrontmost(keynote, current: "com.apple.Keynote", now: start)
        #expect(sessions.holdingFrontmost && sessions.holdingAwake)
        sessions.activated("com.apple.Safari", now: start + 5)
        #expect(!sessions.holdingFrontmost && sessions.holdingAwake)
        sessions.terminated("com.apple.Keynote")
        #expect(sessions.frontmost == nil && sessions.holdingAwake)
        #expect(sessions.agents["Claude Code|s1"]?.state == .working && sessions.awake != nil && sessions.mode == .untilQuiet(app: "com.example.Sync", name: "Sync"))
        #expect(sessions.history.isEmpty)
        // Ending the transfer leaves the agent's hold.
        sessions.stop(now: start + 10)
        #expect(sessions.agents.count == 1 && sessions.holdingAwake)
    }

    @Test func turningItOffWinsAndStoppingTheConditionKeepsTheSession() {
        let sessions = store()
        sessions.start(.indefinite, now: start)
        sessions.watchFrontmost(keynote, current: "com.apple.Keynote", now: start)
        sessions.stopFrontmost()
        #expect(sessions.frontmost == nil && sessions.frontmostEnded == "Turned off" && sessions.mode == .indefinite && sessions.holdingAwake)
        sessions.watchFrontmost(keynote, current: "com.apple.Keynote", now: start)
        sessions.stop(now: start + 5)
        #expect(sessions.frontmost == nil && sessions.mode == nil && !sessions.holdingAwake)
    }

    @Test func itsTimerEndsItEvenInFront() {
        let sessions = store()
        let capped = FrontmostCondition(app: keynote.app, name: keynote.name, display: false, until: start + 60)
        sessions.watchFrontmost(capped, current: "com.apple.Keynote", now: start)
        sessions.tick(apps: [], interval: 2, now: start + 30)
        #expect(sessions.holdingFrontmost)
        sessions.tick(apps: [], interval: 2, now: start + 60)
        #expect(sessions.frontmost == nil && !sessions.holdingAwake && sessions.frontmostEnded == "Timer ended")
        // A timer already past never starts it.
        sessions.watchFrontmost(capped, current: "com.apple.Keynote", now: start + 61)
        #expect(sessions.frontmost == nil && !sessions.holdingAwake)
    }

    @Test func anAwakeTimerEndsOnTimeBesideIt() {
        let sessions = store()
        sessions.start(.timer(until: start + 60), now: start)
        sessions.watchFrontmost(keynote, current: "com.apple.Keynote", now: start)
        sessions.tick(apps: [], interval: 2, now: start + 61)
        #expect(sessions.mode == nil && sessions.history.first?.ended == "Timer ended")
        #expect(sessions.holdingFrontmost && sessions.frontmost == keynote)
    }

    @Test func theBatteryFloorWins() {
        let power = Power(), sessions = store(power)
        sessions.keepAwakeForAgents = true
        sessions.receive(AgentEvent(kind: .working, agent: "codex", session: "a", time: start))
        sessions.watchFrontmost(keynote, current: "com.apple.Keynote", now: start)
        #expect(sessions.holdingFrontmost)
        // On power, a low charge doesn't matter.
        power.state = PowerState(batteryPercent: 10, onAC: true, thermal: "nominal", lowPowerMode: false)
        sessions.tick(apps: [], interval: 2, now: start + 2)
        #expect(sessions.holdingFrontmost)
        power.state = PowerState(batteryPercent: 20, onAC: false, thermal: "nominal", lowPowerMode: false)
        sessions.tick(apps: [], interval: 2, now: start + 4)
        #expect(sessions.frontmost == nil && !sessions.holdingFrontmost && sessions.frontmostEnded == "Battery at 20%")
        #expect(sessions.agents["Codex|a"] != nil && sessions.holdingAwake)
        // Below the floor it never starts, in front or not.
        sessions.watchFrontmost(keynote, current: "com.apple.Keynote", now: start + 6)
        #expect(sessions.frontmost == nil && !sessions.holdingFrontmost)
    }

    @Test func neverAsksForTheLid() {
        let sessions = store()
        sessions.allowLidClosed = true; sessions.lidClosedForAwake = true
        sessions.watchFrontmost(keynote, current: "com.apple.Keynote", now: start)
        sessions.tick(apps: [], interval: 2, now: start + 2)
        #expect(sessions.holdingFrontmost && sessions.lidRequest == nil)
    }

    @Test func theScreenChoiceAppliesToTheConditionSetNow() {
        let sessions = store()
        sessions.keepDisplayOn = true
        sessions.watchFrontmost(keynote, current: "com.apple.Keynote", now: start)
        sessions.keepDisplayOn = false
        #expect(sessions.frontmost?.display == false && sessions.frontmostActive && sessions.holdingFrontmost)
        sessions.activated("com.apple.Safari")
        sessions.keepDisplayOn = true
        #expect(sessions.frontmost?.display == true && !sessions.holdingFrontmost)
    }
}

struct FrontmostOptionsTests {
    func parse(_ text: String) throws -> AwakeOptions { try AwakeOptions.parse(["awake"] + text.split(separator: " ").map(String.init)) }
    func error(_ text: String) -> String? {
        do { _ = try parse(text); return nil } catch let invalid as AwakeOptions.Invalid { return invalid.message } catch { return "\(error)" }
    }

    @Test func takesAnAppWithTheScreenAndATimer() throws {
        #expect(try parse("--while-frontmost Keynote") == AwakeOptions(frontmost: "Keynote"))
        let options = try parse("--while-frontmost com.apple.Preview --display --for 2h --json")
        #expect(options.frontmost == "com.apple.Preview" && options.display && options.duration == 7200 && options.json)
    }

    @Test func rejectsWhatDoesNotGoWithIt() {
        #expect(error("--while-frontmost") == "--while-frontmost needs a value. Run kilobat awake --help.")
        #expect(error("--while-frontmost --display") == "--while-frontmost takes an app's name or bundle ID, e.g. Keynote or com.apple.Preview.")
        #expect(error("--while-frontmost Keynote --until-quiet") == "--while-frontmost goes with --for and --display only.")
        #expect(error("--while-frontmost Keynote -- make test") == "--while-frontmost goes with --for and --display only.")
        #expect(error("--while-frontmost Keynote --lid-closed") == "--while-frontmost can't hold the lid: with it closed, no app is in front.")
    }
}
