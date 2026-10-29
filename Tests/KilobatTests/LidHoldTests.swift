import Foundation
import Testing
@testable import KilobatCore

/// SleepDisabled and the power source, as the keeper sees them; nothing here touches the Mac.
final class FakePower: @unchecked Sendable {
    var sleepDisabled: Bool? = false
    var sets: [Bool] = []
    var setWorks = true
    var power = PowerState(batteryPercent: 80, onAC: false, thermal: "nominal", lowPowerMode: false)
    var system: LidKeeper.System {
        LidKeeper.System(sleepDisabled: { self.sleepDisabled },
                         setSleepDisabled: { on in self.sets.append(on); if self.setWorks { self.sleepDisabled = on }; return self.setWorks },
                         power: { self.power })
    }
}

@MainActor final class LidRecorder: LidHolding {
    var requests: [LidLease?] = []
    var last: LidLease? { requests.last ?? nil }
    func request(_ lease: LidLease?) { requests.append(lease) }
}

struct LidPolicyTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func power(_ percent: Int? = 80, ac: Bool = false, thermal: String = "nominal") -> PowerState {
        PowerState(batteryPercent: percent, onAC: ac, thermal: thermal, lowPowerMode: false)
    }

    @Test func failsafesEndAHold() {
        let lease = LidLease(until: start + 7200, reason: "Claude Code working", batteryFloor: 20)
        #expect(LidPolicy.stop(lease, since: start, power: power(), now: start + 60) == nil)
        #expect(LidPolicy.stop(lease, since: start, power: power(20), now: start + 60) == "battery at 20%")
        // On the adapter the floor doesn't matter.
        #expect(LidPolicy.stop(lease, since: start, power: power(5, ac: true), now: start + 60) == nil)
        #expect(LidPolicy.stop(lease, since: start, power: power(thermal: "fair"), now: start + 60) == nil)
        #expect(LidPolicy.stop(lease, since: start, power: power(ac: true, thermal: "serious"), now: start + 60) == "running hot")
        #expect(LidPolicy.stop(lease, since: start, power: power(ac: true, thermal: "critical"), now: start + 60) == "running hot")
        var plugged = lease; plugged.onlyOnAC = true
        #expect(LidPolicy.stop(plugged, since: start, power: power(90, ac: true), now: start + 60) == nil)
        #expect(LidPolicy.stop(plugged, since: start, power: power(90), now: start + 60) == "unplugged")
        #expect(LidPolicy.stop(lease, since: start, power: power(), now: start + 7200) == "time limit reached")
        // A desktop has no battery to run down.
        #expect(LidPolicy.stop(lease, since: start, power: power(nil, ac: true), now: start + 60) == nil)
    }

    @Test func theAppGetsAMinuteToComeBack() {
        let lease = LidLease(until: start + 7200, reason: "x")
        #expect(LidPolicy.stop(lease, since: start, power: power(), now: start + 159, disconnected: start + 100) == nil)
        #expect(LidPolicy.stop(lease, since: start, power: power(), now: start + 160, disconnected: start + 100) == "Kilobat quit")
    }

    @Test func requestsAreClamped() {
        let since = start - 3600
        let lease = LidPolicy.clamp(LidLease(until: start + 86_400, reason: "  " + String(repeating: "a", count: 200), batteryFloor: 1), since: since)
        #expect(lease.until == since + 8 * 3600)
        #expect(lease.reason.count == 80 && lease.batteryFloor == 5)
        #expect(LidPolicy.clamp(LidLease(until: start, reason: " ", batteryFloor: 99), since: start).reason == "Kilobat")
        #expect(LidPolicy.clamp(LidLease(until: start, reason: "x", batteryFloor: 99), since: start).batteryFloor == 90)
    }

    @Test func readsSleepDisabledFromPmset() {
        let output = "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n standby              1\n sleep                1 (sleep prevented by Kilobat)\n"
        #expect(LidPolicy.sleepDisabled(output) == true)
        #expect(LidPolicy.sleepDisabled(output.replacingOccurrences(of: "\t\t1", with: "\t\t0")) == false)
        #expect(LidPolicy.sleepDisabled("Currently in use:\n sleep 1\n") == nil)
    }

    @Test func relayRequestsRoundTrip() {
        let hold = LidRelayRequest.hold(until: Date(timeIntervalSince1970: 1_800_003_600), owner: 4242, reason: "While make runs")
        #expect(hold.action == "lid|hold|1800003600|4242|While make runs")
        #expect(LidRelayRequest(hold.action) == hold)
        #expect(LidRelayRequest(LidRelayRequest.release(owner: 7).action) == .release(owner: 7))
        // A reason may hold the separators.
        #expect(LidRelayRequest("lid|hold|1800003600|1|a|b:c") == .hold(until: Date(timeIntervalSince1970: 1_800_003_600), owner: 1, reason: "a|b:c"))
        #expect(LidRelayRequest("lid|hold|1800003600|1|") == .hold(until: Date(timeIntervalSince1970: 1_800_003_600), owner: 1, reason: "Command line"))
        for bad in ["lid|hold|soon|1|x", "lid|hold|1800003600|0|x", "lid|hold|1800003600|-3|x", "lid|release|", "lid|release|1|2", "lid|stop|1", "agent|hold|1|1|x",
                    "lid|hold|1800003600|1|" + String(repeating: "x", count: 81)] {
            #expect(LidRelayRequest(bad) == nil, "\(bad)")
        }
        #expect(AppRelay.known("lid|hold|1800003600|1|x"))
    }
}

struct LidKeeperTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func keeper(_ fake: FakePower, directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-lid-" + UUID().uuidString)) -> LidKeeper {
        LidKeeper(directory: directory, system: fake.system)
    }

    @Test func holdsAndRestoresWhatWasThere() {
        let fake = FakePower(), keeper = keeper(fake)
        let status = keeper.hold(LidLease(until: start + 3600, reason: "Codex working"), now: start)
        #expect(status.lease?.reason == "Codex working" && status.since == start)
        #expect(fake.sets == [true] && keeper.marker == LidKeeper.Marker(previous: false, since: start))
        // Renewing doesn't touch pmset again.
        _ = keeper.hold(LidLease(until: start + 5400, reason: "Codex working"), now: start + 60)
        #expect(fake.sets == [true] && keeper.lease?.until == start + 5400)
        let released = keeper.release("no longer needed", now: start + 120)
        #expect(released.lease == nil && released.released == LidRelease(reason: "no longer needed", date: start + 120))
        #expect(fake.sets == [true, false] && fake.sleepDisabled == false && keeper.marker == nil)
    }

    @Test func leavesSleepDisabledOnWhenSomethingElseSetIt() {
        let fake = FakePower(); fake.sleepDisabled = true
        let keeper = keeper(fake)
        #expect(keeper.hold(LidLease(until: start + 3600, reason: "x"), now: start).lease != nil)
        keeper.release("done", now: start + 60)
        #expect(fake.sets.isEmpty && fake.sleepDisabled == true && keeper.marker == nil)
    }

    @Test func neverStartsAHoldThatWouldEndAtOnce() {
        let fake = FakePower(); fake.power = PowerState(batteryPercent: 15, onAC: false, thermal: "nominal", lowPowerMode: false)
        let keeper = keeper(fake)
        let status = keeper.hold(LidLease(until: start + 3600, reason: "x", batteryFloor: 20), now: start)
        #expect(status.lease == nil && status.released?.reason == "battery at 15%" && fake.sets.isEmpty && keeper.marker == nil)
        fake.sleepDisabled = nil; fake.power = PowerState(batteryPercent: 80, onAC: true, thermal: "nominal", lowPowerMode: false)
        #expect(keeper.hold(LidLease(until: start + 3600, reason: "x"), now: start).released?.reason == "couldn’t read the power settings")
        fake.sleepDisabled = false; fake.setWorks = false
        #expect(keeper.hold(LidLease(until: start + 3600, reason: "x"), now: start).released?.reason == "macOS refused" && keeper.marker == nil)
    }

    @Test func checkRunsTheFailsafes() {
        let fake = FakePower(), keeper = keeper(fake)
        _ = keeper.hold(LidLease(until: start + 3600, reason: "x", batteryFloor: 20), now: start)
        #expect(keeper.check(now: start + 600).lease != nil)
        fake.power = PowerState(batteryPercent: 19, onAC: false, thermal: "nominal", lowPowerMode: false)
        #expect(keeper.check(now: start + 900).released?.reason == "battery at 19%")
        #expect(fake.sleepDisabled == false)
    }

    @Test func endsAMinuteAfterTheAppGoesAwayUnlessItComesBack() {
        let fake = FakePower(), keeper = keeper(fake)
        _ = keeper.hold(LidLease(until: start + 3600, reason: "x"), now: start)
        keeper.disconnect(now: start + 100)
        #expect(keeper.check(now: start + 150).lease != nil)
        // The app restarted and asked again.
        _ = keeper.hold(LidLease(until: start + 3600, reason: "x"), now: start + 155)
        #expect(keeper.check(now: start + 400).lease != nil)
        keeper.disconnect(now: start + 500)
        #expect(keeper.check(now: start + 560).released?.reason == "Kilobat quit")
        #expect(fake.sleepDisabled == false)
    }

    @Test func renewalsNeverPassEightHours() {
        let fake = FakePower(); fake.power = PowerState(batteryPercent: 100, onAC: true, thermal: "nominal", lowPowerMode: false)
        let keeper = keeper(fake)
        var now = start
        while now < start + 9 * 3600 && (keeper.lease != nil || now == start) {
            _ = keeper.hold(LidLease(until: now + 3600, reason: "x"), now: now)
            now += 600; keeper.check(now: now)
        }
        #expect(keeper.lease == nil && keeper.released?.reason == "time limit reached")
        #expect(now <= start + 8 * 3600 + 600)
    }

    @Test func aRestartPutsSleepBack() {
        let fake = FakePower(), directory = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-lid-" + UUID().uuidString)
        _ = keeper(fake, directory: directory).hold(LidLease(until: start + 3600, reason: "x"), now: start)
        #expect(fake.sleepDisabled == true)
        // The helper crashed, or the Mac restarted with SleepDisabled still on.
        fake.setWorks = false
        let failed = keeper(fake, directory: directory)
        failed.start(now: start + 60)
        #expect(fake.sleepDisabled == true && failed.marker != nil)
        fake.setWorks = true
        let next = keeper(fake, directory: directory)
        next.start(now: start + 120)
        #expect(fake.sleepDisabled == false && next.marker == nil && next.lease == nil)
        #expect(next.released?.reason == "Kilobat’s helper restarted")
        // A clean start does nothing.
        let sets = fake.sets.count
        keeper(fake, directory: directory).start(now: start + 180)
        #expect(fake.sets.count == sets)
    }
}

struct AwakeOptionsTests {
    func parse(_ text: String) throws -> AwakeOptions { try AwakeOptions.parse(["awake"] + text.split(separator: " ").map(String.init)) }
    func error(_ text: String) -> String? {
        do { _ = try parse(text); return nil } catch let invalid as AwakeOptions.Invalid { return invalid.message } catch { return "\(error)" }
    }

    @Test func acceptsTheLidWithEveryMode() throws {
        #expect(try parse("--lid-closed") == AwakeOptions(lidClosed: true))
        #expect(try parse("--for 2h --lid-closed").duration == 7200)
        #expect(try parse("--until-quiet --app com.example.App --quiet 5 --lid-closed") == AwakeOptions(untilQuiet: true, app: "com.example.App", quietMinutes: 5, lidClosed: true))
        let wrapped = try parse("--lid-closed --display -- make test --lid-closed")
        #expect(wrapped.lidClosed && wrapped.display && wrapped.command == ["make", "test", "--lid-closed"])
        #expect(try !parse("--for 90m").lidClosed)
    }

    @Test func rejectsWhatCanNotWork() {
        #expect(error("--lid-closed --for 9h") == "--lid-closed holds 8 hours at most; use --for 8h or less.")
        #expect(error("--for 9h") == nil)
        #expect(error("--lid") == "Unexpected '--lid'. Run kilobat awake --help.")
        #expect(error("--lid-closed --for") == "--for needs a value. Run kilobat awake --help.")
        #expect(error("--for 2h --until-quiet") == "Choose one of --for, --until-quiet or -- <command>.")
        #expect(error("--lid-closed --") == "Name a command after --, e.g. kilobat awake -- make test.")
        #expect(error("--app com.example.App") == "--app and --quiet go with --until-quiet.")
        #expect(error("--for soon") == "--for takes a duration such as 45s, 90m or 2h, up to 24h.")
        #expect(AwakeOptions.seconds("1h30m") == 5400 && AwakeOptions.seconds("90") == 5400 && AwakeOptions.seconds("x") == nil)
    }
}

@MainActor struct LidSessionTests {
    let start = Date()
    /// Registered defaults are shared by every test in the process, so each store is set up through its properties instead.
    private func store(_ configure: (SessionStore) -> Void = { _ in }) -> (SessionStore, LidRecorder) {
        let suite = "co.seifi.kilobat.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let sessions = SessionStore(defaults: defaults), recorder = LidRecorder()
        sessions.probe = FakeProcesses().probe
        sessions.notify = false; sessions.webhook = ""; sessions.quietMinutes = 3
        sessions.keepAwakeForAgents = true; sessions.keepAwakeWhileWaiting = false
        sessions.allowLidClosed = true; sessions.lidClosedForAwake = false
        sessions.lidBatteryFloor = 20; sessions.lidOnlyOnAC = false; sessions.lidMaxHours = 4
        configure(sessions)
        defaults.removePersistentDomain(forName: suite)
        sessions.lid = recorder
        return (sessions, recorder)
    }
    /// Settings changes count from the clock, a moment after `start`.
    private func near(_ date: Date?, _ expected: Date) -> Bool { date.map { abs($0.timeIntervalSince(expected)) < 5 } ?? false }
    private func event(_ kind: AgentEvent.Kind, _ time: Date, message: String? = nil) -> AgentEvent {
        AgentEvent(kind: kind, agent: "claude", session: "s1", cwd: "/Users/me/kilobat", message: message, pid: getpid(), time: time)
    }

    @Test func holdsOnlyWhenAllowed() {
        let start = Date()
        let (sessions, recorder) = store { $0.allowLidClosed = false }
        sessions.receive(event(.working, start))
        #expect(sessions.lidRequest == nil && recorder.last == nil)
        sessions.allowLidClosed = true
        #expect(recorder.last?.reason == "Claude Code working")
        // Turning it on counts from now, not from the run's start.
        #expect(near(recorder.last?.until, start + 4 * 3600) && recorder.last?.batteryFloor == 20 && recorder.last?.onlyOnAC == false)
        sessions.lidBatteryFloor = 30; sessions.lidOnlyOnAC = true
        #expect(recorder.last?.batteryFloor == 30 && recorder.last?.onlyOnAC == true)
        sessions.receive(event(.done, start + 60))
        // Attaching the recorder, allowing, the floor, power only, done.
        #expect(sessions.lidRequest == nil && recorder.requests.count == 5 && recorder.last == nil)
    }

    @Test func waitingHoldsOnlyWhenAskedAndForHalfAnHour() {
        let (sessions, recorder) = store()
        sessions.receive(event(.working, start))
        sessions.receive(event(.waiting, start + 60, message: "Claude needs your permission to use Bash"))
        #expect(sessions.lidRequest == nil)
        sessions.keepAwakeWhileWaiting = true
        #expect(recorder.last?.until == start + 60 + LidPolicy.waiting)
        var now = start + 60
        while now < start + 60 + LidPolicy.waiting - 2 { now += 2; sessions.tick(apps: [], interval: 2, now: now) }
        #expect(sessions.lidRequest != nil)
        now += 4; sessions.tick(apps: [], interval: 2, now: now)
        #expect(sessions.lidRequest == nil && sessions.agents.values.first?.state == .waitingForYou)
        // An answer starts it working again, and a later wait gets its own half hour.
        sessions.receive(event(.working, now))
        #expect(sessions.lidRequest != nil)
    }

    @Test func aStalledRunLetsTheLidGo() {
        let (sessions, _) = store()
        sessions.receive(event(.working, start))
        var now = start
        while sessions.agents.values.first?.state != .stalled && now < start + 600 { now += 2; sessions.tick(apps: [], interval: 2, now: now) }
        #expect(sessions.agents.values.first?.state == .stalled && sessions.lidRequest == nil)
    }

    @Test func theTimeLimitHoldsForTheWholeStretch() {
        let (sessions, recorder) = store { $0.lidMaxHours = 1 }
        sessions.receive(event(.working, start))
        #expect(recorder.last?.until == start + 3600)
        var now = start
        // The run keeps reporting work past the limit; the lid isn't asked for again until it ends.
        while now < start + 7200 {
            now += 60
            sessions.receive(event(.working, now)); sessions.tick(apps: [], interval: 2, now: now)
            if now > start + 3600 { #expect(sessions.lidRequest == nil) }
        }
        sessions.receive(event(.done, now))
        sessions.receive(AgentEvent(kind: .working, agent: "claude", session: "s2", cwd: "/Users/me/kilobat", pid: getpid(), time: now + 60))
        #expect(sessions.lidRequest?.until == now + 60 + 3600)
    }

    @Test func awakeSessionsHoldTheLidWhenChosen() {
        let start = Date()
        let (sessions, recorder) = store()
        sessions.start(.timer(until: start + 1800), now: start)
        #expect(sessions.lidRequest == nil)
        sessions.lidClosedForAwake = true
        #expect(recorder.last?.until == start + 1800 && recorder.last?.reason.hasPrefix("Awake until") == true)
        // The run outlasts the timer, so the hold runs to the time limit.
        sessions.receive(event(.working, start + 10))
        #expect(near(sessions.lidRequest?.until, start + 4 * 3600))
        sessions.stop(now: start + 20)
        #expect(sessions.lidRequest?.reason == "Claude Code working")
    }

    @Test func otherProcessesHoldWhileTheyRun() {
        let (sessions, recorder) = store { $0.keepAwakeForAgents = false }
        #expect(sessions.holdLid(owner: getpid(), until: start + 1800, reason: "kilobat awake", now: start)?.until == start + 1800)
        #expect(recorder.last?.reason == "kilobat awake")
        sessions.tick(apps: [], interval: 2, now: start + 2)
        #expect(sessions.lidRequest != nil)
        sessions.releaseLid(owner: getpid(), now: start + 4)
        #expect(sessions.lidRequest == nil)
        // A process that exited lets go on the next tick; one that asks too late gets nothing.
        _ = sessions.holdLid(owner: 999_999, until: start + 1800, reason: "gone", now: start + 6)
        #expect(sessions.lidRequest == nil)
        #expect(sessions.holdLid(owner: getpid(), until: start, reason: "late", now: start + 8) == nil)
        sessions.allowLidClosed = false
        #expect(sessions.holdLid(owner: getpid(), until: start + 1800, reason: "x", now: start + 10) == nil)
    }
}
