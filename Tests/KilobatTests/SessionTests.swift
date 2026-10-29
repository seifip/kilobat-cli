import Foundation
import Testing
@testable import KilobatCore

/// A made-up process tree whose CPU time the test advances between ticks; real pids still count as alive.
@MainActor final class FakeProcesses {
    var children: [Int32: [Int32]] = [:]
    var cpu: [Int32: UInt64] = [:]
    var alive: Set<Int32> = []
    nonisolated var probe: ProcessProbe {
        ProcessProbe(children: { pid in MainActor.assumeIsolated { self.children[pid] ?? [] } },
                     cpuTime: { pid in MainActor.assumeIsolated { self.cpu[pid] ?? 0 } },
                     alive: { pid in MainActor.assumeIsolated { self.alive.contains(pid) } || kill(pid, 0) == 0 },
                     path: { _ in nil })
    }
    /// Adds `cores` of work over `seconds` to each process.
    func burn(_ pids: [Int32], cores: Double, seconds: Double = 2) { for pid in pids { cpu[pid, default: 0] += UInt64(cores * seconds * 1e9) } }
}

@MainActor struct SessionTests {
    /// Registered values are never saved, and notifications stay off outside an app bundle.
    /// The test runner's own CPU never counts: processes come from a made-up tree.
    private func store(directory: URL? = nil, quietMinutes: Int = 3, processes: FakeProcesses = FakeProcesses()) -> SessionStore {
        let defaults = UserDefaults(suiteName: "co.seifi.kilobat.tests." + UUID().uuidString)!
        defaults.register(defaults: ["awake.agents": false, "awake.notify": false, "awake.quietMinutes": quietMinutes, "awake.webhook": ""])
        let sessions = SessionStore(directory: directory, defaults: defaults)
        sessions.probe = processes.probe
        return sessions
    }
    private func traffic(_ id: String = "com.example.Sync", rate: Double, pid: Int32 = getpid()) -> AppTraffic {
        AppTraffic(id: id, name: id.hasPrefix("process:") ? String(id.dropFirst(8)) : String(id.split(separator: ".").last ?? ""), processIDs: [pid], downloadRate: rate - rate / 10, uploadRate: rate / 10)
    }

    @Test func untilQuietEndsAfterTheQuietMinutes() {
        let sessions = store(), start = Date()
        sessions.start(.untilQuiet(app: nil, name: ""), now: start)
        #expect(sessions.holdingAwake)
        var now = start
        for _ in 0..<30 {
            now += 2; sessions.tick(apps: [traffic(rate: 200_000)], interval: 2, now: now)
        }
        #expect(sessions.awake != nil && sessions.quietSince == nil)
        while sessions.awake != nil && now < start + 900 {
            now += 2; sessions.tick(apps: [traffic(rate: 1_000)], interval: 2, now: now)
        }
        let session = sessions.history.first
        #expect(session?.ended == "Went quiet")
        #expect(!sessions.holdingAwake)
        // Quiet starts once the 30-second average drops below the threshold, then has to last three minutes.
        let quietFor = (session?.end ?? now).timeIntervalSince(start + 60)
        #expect(quietFor >= 180 && quietFor <= 240)
        #expect((session?.received ?? 0) > (session?.sent ?? 0) && (session?.apps["Sync"] ?? 0) > 10_000_000)
    }

    @Test func untilQuietWatchesOnlyItsApp() {
        let sessions = store(quietMinutes: 1), start = Date()
        sessions.start(.untilQuiet(app: "com.example.Sync", name: "Sync"), now: start)
        var now = start
        while sessions.awake != nil && now < start + 600 {
            now += 2; sessions.tick(apps: [traffic(rate: 0), traffic("com.example.Other", rate: 500_000), traffic("com.example.Sync Helper", rate: 2_000)], interval: 2, now: now)
        }
        // Helpers named after the app count towards it; other apps don't.
        #expect(sessions.history.first?.ended == "Went quiet")
        #expect(sessions.history.first?.received == 3_600 * 31 && sessions.history.first?.apps["Other"] == nil)
    }

    @Test func timerEnds() {
        let sessions = store(), start = Date()
        sessions.start(.timer(until: start + 60), now: start)
        sessions.tick(apps: [], interval: 2, now: start + 30)
        #expect(sessions.awake != nil)
        var ended: WorkSession?
        sessions.onEnd = { ended = $0 }
        sessions.tick(apps: [], interval: 2, now: start + 61)
        #expect(sessions.awake == nil && !sessions.holdingAwake)
        #expect(ended?.ended == "Timer ended" && ended?.kind == .awake)
    }

    @Test func agentRunStartsWithTrafficAndEndsWhenQuiet() {
        let sessions = store(), start = Date()
        sessions.tick(apps: [traffic("process:claude", rate: 1_000)], interval: 2, now: start)
        #expect(sessions.agents.isEmpty)
        sessions.tick(apps: [traffic("process:claude", rate: 500_000)], interval: 2, now: start + 2)
        #expect(sessions.agents["Claude Code"] != nil)
        sessions.tick(apps: [traffic("process:claude", rate: 500_000)], interval: 2, now: start + 4)
        var now = start + 4
        while !sessions.agents.isEmpty && now < start + 600 {
            now += 2; sessions.tick(apps: [traffic("process:claude", rate: 0)], interval: 2, now: now)
        }
        let run = sessions.history.first
        #expect(run?.kind == .agent && run?.title == "Claude Code" && run?.ended == "Went quiet")
        // The run ends when it last moved data, not when the quiet minutes ran out.
        #expect(run?.end == start + 4)
        #expect(run?.received == 900_000 && run?.sent == 100_000)
        #expect(now >= start + 4 + 180)
    }

    @Test func agentRunEndsWhenTheProcessExits() {
        let sessions = store(), start = Date()
        sessions.tick(apps: [traffic("process:codex", rate: 600_000)], interval: 2, now: start)
        #expect(sessions.agents["Codex"] != nil)
        sessions.tick(apps: [traffic("process:codex", rate: 600_000)], interval: 2, now: start + 2)
        sessions.tick(apps: [], interval: 2, now: start + 2)
        #expect(sessions.agents.isEmpty && sessions.history.first?.ended == "Exited")
        // A process that is gone never starts a run.
        sessions.tick(apps: [traffic("process:codex", rate: 5_000, pid: 999_999)], interval: 2, now: start + 4)
        #expect(sessions.agents.isEmpty)
    }

    @Test func shortBurstsAreNotRuns() {
        let sessions = store(), start = Date()
        var ended: WorkSession?
        sessions.onEnd = { ended = $0 }
        sessions.tick(apps: [traffic("process:claude", rate: 5_000)], interval: 2, now: start)
        sessions.tick(apps: [traffic("process:claude", rate: 5_000)], interval: 2, now: start + 2)
        #expect(sessions.agents["Claude Code"] != nil)
        var now = start + 2
        while !sessions.agents.isEmpty && now < start + 600 {
            now += 2; sessions.tick(apps: [traffic("process:claude", rate: 0)], interval: 2, now: now)
        }
        // Background polling neither lands in history nor notifies.
        #expect(sessions.history.isEmpty && ended == nil)
    }

    @Test func historySurvivesARestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = store(directory: directory), start = Date()
        sessions.start(.indefinite, now: start)
        sessions.stop(now: start + 30)
        let reloaded = store(directory: directory).history
        #expect(reloaded.count == 1 && reloaded.first?.ended == "Turned off" && reloaded.first?.title == "Until you turn it off")
    }

    @Test func hooksDriveARun() {
        let sessions = store(), start = Date()
        var ended: WorkSession?
        sessions.onEnd = { ended = $0 }
        sessions.receive(AgentEvent(kind: .start, agent: "claude", session: "a1", cwd: "/Users/me/kilobat", pid: getpid(), time: start))
        #expect(sessions.agents["Claude Code|a1"]?.state == .working && sessions.agents["Claude Code|a1"]?.project == "kilobat")
        var now = start
        for _ in 0..<40 { now += 2; sessions.tick(apps: [traffic("process:claude", rate: 400_000)], interval: 2, now: now) }
        sessions.receive(AgentEvent(kind: .waiting, agent: "claude", session: "a1", message: "Claude needs your permission to use Bash", time: now))
        // Waiting for an answer is not the end, however long the person takes.
        while now < start + 1_200 { now += 2; sessions.tick(apps: [traffic("process:claude", rate: 0)], interval: 2, now: now) }
        #expect(sessions.agents["Claude Code|a1"]?.state == .waitingForYou && ended == nil)
        sessions.receive(AgentEvent(kind: .working, agent: "claude", session: "a1", time: now))
        sessions.receive(AgentEvent(kind: .done, agent: "claude", session: "a1", time: now + 30))
        #expect(sessions.agents.isEmpty)
        #expect(ended?.ended == "Finished" && ended?.state == .done && ended?.hooks == true && ended?.session == "a1")
        #expect(ended?.end == now + 30 && ended?.received == 720_000 * 40)
        // Done for a run that already ended changes nothing.
        sessions.receive(AgentEvent(kind: .done, agent: "claude", session: "a1", time: now + 40))
        #expect(sessions.history.count == 1)
    }

    @Test func waitingHoldsAwakeOnlyWhenAsked() {
        let sessions = store(), start = Date()
        sessions.keepAwakeForAgents = true
        sessions.receive(AgentEvent(kind: .working, agent: "codex", cwd: "/tmp/api", time: start))
        #expect(sessions.holdingAwake)
        sessions.receive(AgentEvent(kind: .waiting, agent: "codex", cwd: "/tmp/api", time: start + 5))
        #expect(!sessions.holdingAwake)
        sessions.keepAwakeWhileWaiting = true
        #expect(sessions.holdingAwake)
        sessions.receive(AgentEvent(kind: .done, agent: "codex", cwd: "/tmp/api", time: start + 9))
        #expect(!sessions.holdingAwake)
    }

    @Test func sessionsInDifferentFoldersStaySeparate() {
        let sessions = store(), start = Date()
        sessions.receive(AgentEvent(kind: .start, agent: "claude", session: "one", cwd: "/src/kilobat", time: start))
        sessions.receive(AgentEvent(kind: .start, agent: "claude", session: "two", cwd: "/src/api", time: start))
        sessions.receive(AgentEvent(kind: .waiting, agent: "claude", session: "two", time: start + 1))
        #expect(sessions.agents.count == 2)
        #expect(sessions.agents["Claude Code|one"]?.state == .working && sessions.agents["Claude Code|two"]?.state == .waitingForYou)
        // One process for both: its bytes go to the run that is working, marked as possibly shared.
        sessions.tick(apps: [traffic("process:claude", rate: 300_000)], interval: 2, now: start + 2)
        #expect(sessions.agents["Claude Code|one"]?.received == 540_000 && sessions.agents["Claude Code|one"]?.sharedTraffic == true)
        #expect(sessions.agents["Claude Code|two"]?.received == 0)
        sessions.receive(AgentEvent(kind: .done, agent: "claude", session: "one", time: start + 120))
        #expect(sessions.agents.count == 1 && sessions.history.first?.project == "kilobat")
    }

    @Test func quietHookedRunStallsInsteadOfEnding() {
        let sessions = store(), start = Date()
        sessions.keepAwakeForAgents = true
        sessions.receive(AgentEvent(kind: .working, agent: "claude", session: "s", pid: getpid(), time: start))
        var now = start
        while now < start + 400 { now += 2; sessions.tick(apps: [], interval: 2, now: now) }
        #expect(sessions.agents["Claude Code|s"]?.state == .stalled && !sessions.holdingAwake)
        now += 2; sessions.tick(apps: [traffic("process:claude", rate: 50_000)], interval: 2, now: now)
        #expect(sessions.agents["Claude Code|s"]?.state == .working)
        sessions.record(event: "Lost the network", now: now)
        #expect(sessions.agents["Claude Code|s"]?.state == .networkFailed && sessions.holdingAwake)
        // A session nobody has prompted yet is waiting, not stalled.
        sessions.receive(AgentEvent(kind: .start, agent: "codex", session: "new", pid: getpid(), time: now))
        while now < start + 800 { now += 2; sessions.tick(apps: [], interval: 2, now: now) }
        #expect(sessions.agents["Codex|new"]?.state == .waitingForYou)
    }

    @Test func hooksTakeOverATrafficRun() {
        let sessions = store(), start = Date()
        sessions.tick(apps: [traffic("process:claude", rate: 500_000)], interval: 2, now: start)
        #expect(sessions.agents["Claude Code"] != nil)
        sessions.receive(AgentEvent(kind: .waiting, agent: "Claude Code", session: "x", cwd: "/src/kilobat", time: start + 4))
        #expect(sessions.agents["Claude Code"] == nil && sessions.agents["Claude Code|x"]?.state == .waitingForYou)
        sessions.receive(AgentEvent(kind: .failed, agent: "claude", session: "x", message: "server_error", time: start + 90))
        #expect(sessions.history.first?.ended == "Failed: server_error" && sessions.history.first?.state == .failed)
        // Once hooks report an agent, its traffic alone starts no run.
        sessions.tick(apps: [traffic("process:claude", rate: 500_000)], interval: 2, now: start + 100)
        #expect(sessions.agents.isEmpty)
    }

    @Test func eventsRejectOversizeFields() throws {
        #expect(AgentEvent(kind: .done, agent: "claude").valid)
        #expect(!AgentEvent(kind: .done, agent: "").valid)
        #expect(!AgentEvent(kind: .done, agent: String(repeating: "a", count: 41)).valid)
        #expect(!AgentEvent(kind: .done, agent: "claude", session: String(repeating: "s", count: 129)).valid)
        #expect(!AgentEvent(kind: .done, agent: "claude", cwd: "/" + String(repeating: "d", count: 1024)).valid)
        #expect(!AgentEvent(kind: .done, agent: "claude", message: String(repeating: "m", count: 201)).valid)
        #expect(!AgentEvent(kind: .done, agent: "claude", pid: -1).valid)
        let oversize = try JSONEncoder().encode(AgentEvent(kind: .done, agent: "claude", session: String(repeating: "s", count: 129)))
        #expect(AgentEvent.decode(oversize) == nil)
        #expect(AgentEvent.decode(Data(#"{"kind":"explode","agent":"claude","time":0}"#.utf8)) == nil)
        // The app ignores an invalid event even if one arrives.
        let sessions = store()
        sessions.receive(AgentEvent(kind: .start, agent: String(repeating: "a", count: 41)))
        #expect(sessions.agents.isEmpty)
    }

    @Test func hookJSONMapsToEvents() throws {
        func hook(_ json: String) throws -> AgentEvent.Hook { AgentEvent.Hook(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]) }
        let notification = try hook(#"{"session_id":"abc","cwd":"/src/kilobat","hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"permission_prompt"}"#)
        #expect(notification.kind == .waiting && notification.session == "abc" && notification.cwd == "/src/kilobat" && notification.message == "Claude needs your permission")
        #expect(try hook(#"{"hook_event_name":"Notification","notification_type":"auth_success"}"#).kind == nil)
        #expect(try hook(#"{"hook_event_name":"Stop","last_assistant_message":"secret","background_tasks":[]}"#).kind == .done)
        #expect(try hook(#"{"hook_event_name":"Stop","background_tasks":[{"id":"t"}]}"#).kind == .working)
        #expect(try hook(#"{"hook_event_name":"Stop","last_assistant_message":"secret"}"#).message == nil)
        #expect(try hook(#"{"hook_event_name":"StopFailure","error":"server_error"}"#).message == "server_error")
        #expect(try hook(#"{"hook_event_name":"StopFailure","error":"server_error"}"#).kind == .failed)
        #expect(try hook(#"{"hook_event_name":"UserPromptSubmit","prompt":"hi"}"#).kind == .working)
        let codex = try hook(#"{"type":"agent-turn-complete","thread-id":"t1","cwd":"/src/api","last-assistant-message":"done"}"#)
        #expect(codex.kind == .done && codex.session == "t1" && codex.cwd == "/src/api" && codex.message == nil)
        #expect(try hook(#"{"hook_event_name":"PreToolUse"}"#).kind == nil)
        #expect(try hook(#"{"session_id":"x"}"#).event == nil)
    }

    @Test func rateLimitsAreWaitsWithTheirResetTime() throws {
        func hook(_ object: [String: Any]) -> AgentEvent.Hook { AgentEvent.Hook(object) }
        let usage = hook(["hook_event_name": "Notification", "message": "Claude usage limit reached. Your limit will reset at 3pm (Europe/Prague)."])
        #expect(usage.kind == .waiting && usage.message == "Rate-limited until 3pm (Europe/Prague)")
        let failure = hook(["hook_event_name": "StopFailure", "error": "rate_limit", "last_assistant_message": "API Error: Rate limit reached"])
        #expect(failure.kind == .waiting && failure.message == "Rate-limited")
        #expect(hook(["hook_event_name": "Notification", "message": "Too many requests, try again in 5 minutes"]).message == "Rate-limited for 5 minutes")
        // A full context window isn't a rate limit.
        #expect(hook(["hook_event_name": "Notification", "message": "Context limit reached"]).message == "Context limit reached")
        let sessions = store(), start = Date()
        sessions.receive(AgentEvent(kind: .working, agent: "claude", session: "r", time: start))
        sessions.receive(AgentEvent(kind: .waiting, agent: "claude", session: "r", message: usage.message, time: start + 60))
        #expect(sessions.agents["Claude Code|r"]?.state == .waitingForYou && sessions.agents["Claude Code|r"]?.note == "Rate-limited until 3pm (Europe/Prague)")
        sessions.receive(AgentEvent(kind: .working, agent: "claude", session: "r", time: start + 90))
        #expect(sessions.agents["Claude Code|r"]?.note == nil)
    }

    @Test func backgroundTasksKeepARunAfterDone() {
        let processes = FakeProcesses()
        // The agent (700), an idle MCP server (701) and a background shell (702) running a build (703).
        processes.children = [700: [701, 702], 702: [703]]; processes.alive = [700, 701, 702, 703]
        let sessions = store(processes: processes), start = Date()
        sessions.keepAwakeForAgents = true
        sessions.receive(AgentEvent(kind: .working, agent: "claude", session: "bg", cwd: "/src/kilobat", pid: 700, time: start))
        var now = start
        for _ in 0..<40 { now += 2; processes.burn([703], cores: 0.8); sessions.tick(apps: [], interval: 2, now: now) }
        sessions.receive(AgentEvent(kind: .done, agent: "claude", session: "bg", time: now))
        let run = sessions.agents["Claude Code|bg"]
        #expect(run?.state == .working && run?.note == "1 background task still running" && sessions.holdingAwake)
        for _ in 0..<30 { now += 2; processes.burn([703], cores: 0.8); sessions.tick(apps: [], interval: 2, now: now) }
        #expect(sessions.agents["Claude Code|bg"] != nil)
        let lastBusy = now
        // The build finishes; the idle MCP server doesn't hold the run.
        processes.children = [700: [701]]; processes.alive = [700, 701]
        for _ in 0..<10 { now += 2; sessions.tick(apps: [], interval: 2, now: now) }
        #expect(sessions.agents.isEmpty && !sessions.holdingAwake)
        #expect(sessions.history.first?.ended == "Finished" && sessions.history.first?.end == lastBusy && sessions.history.first?.state == .done)
    }

    @Test func cpuWorkIsNotQuiet() {
        let processes = FakeProcesses()
        processes.alive = [710, 720]
        let sessions = store(processes: processes), start = Date()
        sessions.receive(AgentEvent(kind: .working, agent: "claude", session: "cpu", pid: 710, time: start))
        // A long local build with no traffic and no hook events: still working, not stalled.
        var now = start
        while now < start + 600 { now += 2; processes.burn([710], cores: 0.2); sessions.tick(apps: [], interval: 2, now: now) }
        #expect(sessions.agents["Claude Code|cpu"]?.state == .working && sessions.agents["Claude Code|cpu"]?.lastCPU == now)
        let stopped = now
        while sessions.agents["Claude Code|cpu"]?.state == .working && now < start + 1_200 { now += 2; sessions.tick(apps: [], interval: 2, now: now) }
        // CPU quiet is judged over the quiet window, then the run stalls; quiet never reads as finished.
        #expect(sessions.agents["Claude Code|cpu"]?.state == .stalled && now > stopped + 60 && now <= stopped + 180)
        #expect(sessions.agents["Claude Code|cpu"]?.lastCPU == stopped)

        // Without hooks too: a command-line agent compiling locally hasn't gone quiet.
        let codex = AppTraffic(id: "process:codex", name: "codex", processIDs: [720], downloadRate: 900_000, uploadRate: 100_000)
        var idle = codex; idle.downloadRate = 0; idle.uploadRate = 0
        let traffic = store(processes: processes)
        now = start; traffic.tick(apps: [codex], interval: 2, now: now)
        for _ in 0..<2 { now += 2; traffic.tick(apps: [codex], interval: 2, now: now) }
        while now < start + 600 { now += 2; processes.burn([720], cores: 0.5); traffic.tick(apps: [idle], interval: 2, now: now) }
        #expect(traffic.agents["Codex"] != nil)
        let busy = now
        while traffic.agents["Codex"] != nil && now < start + 1_200 { now += 2; traffic.tick(apps: [idle], interval: 2, now: now) }
        #expect(traffic.history.first?.ended == "Went quiet" && traffic.history.first?.end == busy)
    }

    @Test func installOriginComesFromThePath() {
        let home = "/Users/me"
        let npm = AgentInstall.describe(home + "/.nvm/versions/node/v22.3.0/lib/node_modules/@openai/codex/vendor/aarch64-apple-darwin/codex/codex", home: home,
                                        exists: { $0 == "/opt/homebrew/bin/codex" },
                                        read: { $0 == home + "/.nvm/versions/node/v22.3.0/lib/node_modules/@openai/codex/package.json" ? Data(#"{"version":"0.52.0"}"#.utf8) : nil })
        #expect(npm.origin == "npm (node 22.3.0)" && npm.version == "0.52.0" && npm.others == ["/opt/homebrew/bin/codex"])
        var run = WorkSession(kind: .agent, title: "Codex", start: Date(), lastActive: Date())
        run.describe(npm)
        #expect(run.install == "codex 0.52.0 from npm (node 22.3.0) · /opt/homebrew/bin/codex is another install")
        let brew = AgentInstall.describe("/opt/homebrew/Cellar/codex/0.50.1/bin/codex", home: home, exists: { _ in false }, read: { _ in nil })
        #expect(brew.origin == "Homebrew" && brew.version == "0.50.1" && brew.others.isEmpty)
        let app = AgentInstall.describe(home + "/Library/Application Support/Claude/claude-code/2.1.309/5af865b9901c/claude.app/Contents/MacOS/claude", home: home, exists: { _ in false }, read: { _ in nil })
        #expect(app.origin == "Claude app" && app.version == "2.1.309")
        let local = AgentInstall.describe(home + "/.local/bin/claude", home: home, exists: { _ in false }, read: { _ in nil })
        #expect(local.origin == "~/.local" && local.version == nil)
    }

    @Test func spoolIsBoundedAndDrainsOnce() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/agent-events.jsonl")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let now = Date()
        for index in 0..<1_000 {
            try AgentEventSpool.append(AgentEvent(kind: .working, agent: "claude", session: "s\(index)", cwd: "/src/" + String(repeating: "p", count: 200), time: now), to: file)
        }
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0
        #expect(size > 0 && size <= AgentEventSpool.maxBytes)
        try AgentEventSpool.append(AgentEvent(kind: .done, agent: "claude", session: "old", time: now - 7 * 3600), to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("not json\n".utf8)); try handle.close()
        let events = AgentEventSpool.drain(file, now: now)
        #expect(!events.isEmpty && events.count <= AgentEventSpool.maxLines && events.last?.session == "s999")
        #expect(!events.contains { $0.session == "old" })
        #expect(AgentEventSpool.drain(file, now: now).isEmpty)
    }

    @Test func historyFromBeforeHooksStillLoads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let saved = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"agent","title":"Codex","start":0,"end":600,"ended":"Went quiet","received":5000000,"sent":10000,"apps":{},"destinations":[],"events":[],"peakThermal":"nominal","lastActive":600}]"#
        try Data(saved.utf8).write(to: directory.appendingPathComponent("sessions.json"))
        let history = store(directory: directory).history
        #expect(history.count == 1 && history.first?.state == nil && history.first?.project == nil)
    }

    @Test func summaryNamesDataEventsAndBattery() {
        let start = Date()
        let long = WorkSession(kind: .agent, title: "Codex", start: start, end: start + 5_400, received: 1_200_000, sent: 30_000,
                               events: ["Wi-Fi changed"], batteryStart: 80, batteryEnd: 62, lastActive: start)
        #expect(long.summary.contains("↓ 1.2 MB  ↑ 30 KB"))
        #expect(long.summary.contains("1 network change") && long.summary.contains("battery −18%"))
        #expect(!long.summary.contains("under a minute"))
        let short = WorkSession(kind: .awake, title: "Until you turn it off", start: start, end: start + 20, batteryStart: 50, batteryEnd: 50, lastActive: start)
        #expect(short.summary == "under a minute · ↓ 0 B  ↑ 0 B")
    }
}

struct ConnectionDoctorTests {
    private func rules(_ preferences: SavedPreferences, host: String = "api.example.com", app: String? = nil, filter: Bool = true, budget: Bool = false) -> DoctorStep {
        ConnectionDoctor.rules(host: host, port: "443", app: app, policy: .init(preferences: preferences, filterActive: filter, budgetReached: budget))
    }

    @Test func budgetBlocksOnlyWhileTheFilterRuns() {
        #expect(rules(SavedPreferences(), budget: true).status == .failed)
        let off = rules(SavedPreferences(), filter: false, budget: true)
        #expect(off.status == .warning && off.detail.contains("filter is off"))
    }

    @Test func unrestrictedAllowsEverything() {
        var preferences = SavedPreferences(); preferences.profile = .unrestricted; preferences.blockedDomains = ["example.com"]
        #expect(rules(preferences, app: "com.example.App").status == .ok)
    }

    @Test func blocklistMatchesSubdomainsUnlessExcepted() {
        var preferences = SavedPreferences(); preferences.blockedDomains = ["example.com"]
        let blocked = rules(preferences)
        #expect(blocked.status == .failed && blocked.detail.contains("example.com on your blocklist"))
        preferences.domainExceptions = ["com.apple.Safari": ["example.com"]]
        preferences.rules = ["Travel": ["com.apple.Safari": true]]
        #expect(rules(preferences, app: "com.apple.Safari").status == .ok)
        #expect(rules(preferences, host: "example.org").status == .ok)
    }

    @Test func appAndConnectionRules() {
        var preferences = SavedPreferences(); preferences.rules = ["Travel": ["com.example.App": false, "process:curl": true]]
        let app = rules(preferences, app: "com.example.App")
        #expect(app.status == .failed && app.detail.contains("blocked in the Travel profile"))
        #expect(rules(preferences, app: "process:curl").status == .ok)
        #expect(rules(preferences, app: "com.example.App", filter: false).status == .warning)
        // A newer connection rule wins over the app rule.
        preferences.connectionRules = [ConnectionRule(app: "com.example.App", host: "example.com", allowed: true, profile: "Travel")]
        #expect(rules(preferences, app: "com.example.App").detail == "A connection rule allows this.")
        preferences.connectionRules?.append(ConnectionRule(app: "process:curl", host: "api.example.com", port: "443", allowed: false, profile: "Travel"))
        #expect(rules(preferences, app: "process:curl").status == .failed)
        // Default allow covers apps without a rule.
        preferences.defaultAllow = true
        #expect(rules(preferences, app: "com.example.New").status == .ok)
    }

    @Test func verdictFollowsTheFirstFailedLayer() {
        func report(_ steps: [(String, DoctorStep.Status)]) -> DoctorReport {
            ConnectionDoctor.report("example.com", "example.com", nil, steps.map { DoctorStep(layer: $0.0, status: $0.1, detail: "") })
        }
        #expect(report([("Network", .failed)]).verdict.contains("isn’t connected"))
        let dns = report([("Network", .ok), ("DNS", .failed)])
        #expect(!dns.ok && dns.verdict.contains("doesn’t resolve"))
        #expect(report([("DNS", .ok), ("Kilobat rules", .failed)]).verdict == "Kilobat is blocking it.")
        #expect(report([("Interface", .warning), ("IPv4", .failed), ("IPv6", .skipped)]).next.contains("VPN or proxy off"))
        #expect(report([("Proxy", .warning), ("IPv4", .failed)]).next.contains("VPN or proxy off"))
        #expect(!report([("Interface", .ok), ("Proxy", .ok), ("IPv4", .failed), ("IPv6", .failed)]).next.contains("VPN"))
        #expect(report([("Secure connection", .failed)]).verdict.contains("secure connection"))
        #expect(report([("Server", .failed)]).verdict == "The server is having problems.")
        let refused = ConnectionDoctor.report("example.com", "example.com", nil, [DoctorStep(layer: "Server", status: .warning, detail: "The server answered but refused access (HTTP 403).")])
        #expect(refused.ok && refused.verdict == "This Mac reaches the server, but it refuses this request." && refused.next.contains("login"))
        #expect(refused.next.contains("another network"))
        let missing = ConnectionDoctor.report("example.com", "example.com", nil, [DoctorStep(layer: "Server", status: .warning, detail: "The server answered with HTTP 404.")])
        #expect(missing.ok && !missing.next.contains("login") && missing.next.contains("address"))
        let fine = report([("Network", .ok), ("Interface", .warning), ("Server", .ok)])
        #expect(fine.ok && fine.next.contains("kilobat why"))
    }

    @Test func aPassingCheckCoversThisRequestAndPathOnly() {
        let fine = ConnectionDoctor.report("example.com", "example.com", nil, [step("IPv4", .ok), step("Server", .ok)], over: "over Wi-Fi (en0)")
        #expect(fine.verdict == "This request works from this Mac over Wi-Fi (en0) right now." && fine.next.contains("this path only"))
        #expect(!fine.next.contains("inside the app") && !fine.next.contains("won’t help"))
        #expect(report([step("Server", .failed)]).next.contains("The network gets there"))
    }

    @Test func theProxyTheAppUsesWorksWhileDirectFails() {
        let wifi = ConnectionProbe.Link(name: "en0", kind: "Wi-Fi")
        let family = ConnectionDoctor.familyStep("IPv4", .init(tcp: .init(outcome: .timedOut, address: "192.0.2.1")), host: "example.com", port: 443, available: true)
        #expect(family.status == .failed)
        let steps = ConnectionDoctor.viaProxy([step("Proxy", .warning), family, step("IPv6", .skipped), step("Server", .ok)], layers: ["IPv4", "IPv6"])
        #expect(steps[1].status == .warning && steps[1].detail.hasSuffix("Requests through the proxy don’t take this path."))
        let route = ConnectionDoctor.pathStep(via: "the system proxy (proxy.example:8080)", over: wifi, direct: false, through: true, leftovers: [])
        #expect(route?.status == .ok && route?.detail.hasPrefix("Through the system proxy (proxy.example:8080) it works; direct connections over Wi-Fi (en0) don’t.") == true)
        let works = report(steps + [route!])
        #expect(works.ok && works.verdict == "This request works through the proxy, not directly." && works.next.contains("HTTPS_PROXY"))
        // Without a working proxy, the direct failure stays the verdict.
        #expect(report([step("Proxy", .warning), family, step("IPv6", .skipped)]).verdict == "The server can’t be reached.")
    }

    @Test func aProxyNamedForTheAppIsComparedWithTheSystem() {
        let differs = ConnectionDoctor.namedProxyStep("http://127.0.0.1:7890", app: "Model Loader", system: "proxy.example:8080", answers: true)
        #expect(differs.status == .warning && differs.detail == "Model Loader uses its own proxy at 127.0.0.1:7890, as you said; the system uses proxy.example:8080, so a browser or speed test takes another path. The request below goes through it.")
        #expect(report([differs, step("Server", .ok)]).next.contains("speed test doesn’t take the app’s path"))
        #expect(ConnectionDoctor.namedProxyStep("127.0.0.1:7890", app: nil, system: "127.0.0.1:7890", answers: true).status == .ok)
        let secret = ConnectionDoctor.namedProxyStep("http://me:hunter2@127.0.0.1:7890", app: nil, system: nil, answers: true)
        #expect(!secret.detail.contains("hunter2") && !secret.detail.contains("me:") && secret.detail.hasSuffix("needs a password, so Kilobat only checked that it answers."))
        let dead = ConnectionDoctor.namedProxyStep("socks5://127.0.0.1:1080", app: "Model Loader", system: nil, answers: false)
        #expect(dead.status == .failed && report([dead, step("IPv4", .ok)]).verdict == "The app’s proxy isn’t answering.")
        #expect(ConnectionDoctor.at("http://me:hunter2@proxy.example") == "proxy.example:80")
    }

    @Test func queryValuesStayInTheRequestButNotTheOutput() throws {
        let target = "https://me:pw@cdn.example.net/file.gguf?X-Amz-Signature=secret123&X-Amz-Expires=3600&sig=a%2Fb&flag#part"
        let request = try #require(ConnectionDoctor.requestURL(target))
        #expect(request.absoluteString == target && request.path == "/file.gguf")
        #expect(ConnectionDoctor.requestURL("cdn.example.net/file.gguf?token=secret123")?.absoluteString == "https://cdn.example.net/file.gguf?token=secret123")
        let shown = ConnectionProbe.redacted(request)
        #expect(shown == "https://cdn.example.net/file.gguf?X-Amz-Signature=[redacted]&X-Amz-Expires=[redacted]&sig=[redacted]&[redacted]")
        #expect(ConnectionProbe.redacted(URL(string: "https://example.com")!) == "https://example.com/")
        // An error message that quotes the URL loses the query and password too, in either encoding.
        let message = "Couldn’t load \(target); query X-Amz-Signature=secret123&X-Amz-Expires=3600&sig=a/b&flag."
        let scrubbed = ConnectionProbe.scrubbed(message, [request])
        #expect(!scrubbed.contains("secret123") && !scrubbed.contains("a%2Fb") && !scrubbed.contains("a/b") && !scrubbed.contains(":pw@"))
        #expect(scrubbed.contains("X-Amz-Signature=[redacted]"))
        let context = ConnectionDoctor.contextStep(.remote, host: "cdn.example.net", url: shown)
        #expect(context?.detail.hasSuffix("curl -sv '\(shown)'") == true && context?.detail.contains("secret123") == false)
        let report = ConnectionDoctor.report(shown, "cdn.example.net", nil, [step("Server", .ok)], hops: [.init(url: shown, host: "cdn.example.net", method: "HEAD", status: 200, error: nil)])
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!json.contains("secret123") && json.contains("X-Amz-Signature"))
    }

    @Test func aRefusedHeadIsRetriedAsGet() {
        typealias Hop = ConnectionProbe.Hop
        let url = URL(string: "https://files.example.net/model.bin?token=t")!
        #expect(ConnectionProbe.refusesHead(.status(405)) && ConnectionProbe.refusesHead(.status(403)) && ConnectionProbe.refusesHead(.status(501)))
        #expect(ConnectionProbe.refusesHead(.closed("The network connection was lost.")) && !ConnectionProbe.refusesHead(.status(404)) && !ConnectionProbe.refusesHead(.failed("timed out")))
        let get = ConnectionDoctor.requestSteps([Hop(url: url, answer: .status(206), head: .status(405))])
        #expect(get.map(\.layer) == ["Server"] && get[0].status == .ok && get[0].detail == "The server refuses HEAD requests but answers GET (HTTP 206).")
        #expect(Hop(url: url, answer: .status(206), head: .status(405)).method == "GET")
        let both = ConnectionDoctor.requestSteps([Hop(url: url, answer: .status(403), head: .status(403))])
        #expect(both[0].status == .warning && both[0].detail.hasPrefix("The server refuses HEAD requests (HTTP 403), and GET fails too. The server answered but refused access"))
        let closed = ConnectionDoctor.requestSteps([Hop(url: url, answer: .failed("The request timed out."), head: .closed("The network connection was lost."))])
        #expect(closed[0].layer == "Request" && closed[0].detail == "The server refuses HEAD requests (The network connection was lost), and GET fails too. The request timed out.")
        #expect(report(closed).verdict == "The request failed.")
    }

    @Test func aFailingRedirectHopIsNamed() {
        typealias Hop = ConnectionProbe.Hop
        let start = URL(string: "https://www.example.com/download")!, cdn = URL(string: "https://cdn.example.net/blob?X-Amz-Signature=s")!
        let hops = [Hop(url: start, answer: .status(302), location: cdn), Hop(url: cdn, answer: .failed("A server with the specified hostname could not be found."))]
        let steps = ConnectionDoctor.requestSteps(hops)
        #expect(steps.first?.status == .failed && steps.first?.detail == "This address redirects to cdn.example.net, which fails: www.example.com (HTTP 302) → cdn.example.net (A server with the specified hostname could not be found).")
        let shown: [DoctorHop] = [.init(url: "https://www.example.com/download", host: "www.example.com", method: "HEAD", status: 302, error: nil),
                                  .init(url: "https://cdn.example.net/blob?X-Amz-Signature=[redacted]", host: "cdn.example.net", method: "HEAD", status: nil, error: "not found")]
        let failed = ConnectionDoctor.report("www.example.com", "www.example.com", nil, [step("IPv4", .ok)] + steps, hops: shown)
        #expect(!failed.ok && failed.verdict == "This address redirects to cdn.example.net, which fails." && failed.next.contains("the one it sends you to doesn’t"))
        // The final host gets its own IPv4 and IPv6 check.
        let v6 = ConnectionDoctor.familyStep("Redirect IPv6", .init(tcp: .init(outcome: .timedOut, address: "2001:db8::10")), host: "cdn.example.net", port: 443, available: true, named: true)
        #expect(v6.detail == "No answer from cdn.example.net at 2001:db8::10 on port 443 within 5 seconds.")
        let ok = ConnectionDoctor.requestSteps([Hop(url: start, answer: .status(302), location: cdn), Hop(url: cdn, answer: .status(200))])
        #expect(ok.map(\.layer) == ["Redirects", "Server"] && ok[0].detail == "www.example.com (HTTP 302) → cdn.example.net (HTTP 200).")
        let family = ConnectionDoctor.report("www.example.com", "www.example.com", nil, [step("IPv4", .ok), step("IPv6", .ok)] + ok + [step("Redirect IPv4", .ok), v6], hops: shown)
        #expect(family.verdict == "This address redirects to cdn.example.net, which works over IPv4 but not IPv6." && family.next.contains("Link-local only"))
        let loop = ConnectionDoctor.requestSteps((0...5).map { _ in Hop(url: start, answer: .status(301), location: start) })
        #expect(loop.first?.detail.hasPrefix("More than 5 redirects") == true && report(loop).verdict == "This address redirects too many times.")
    }

    @Test func theAppsOpenConnectionIsComparedWithTheFreshOne() {
        let v6 = OpenDestination(address: "2001:db8::10", ports: ["443"], protocols: ["TCP"], received: 1_200_000, sent: 3_000, connections: 1)
        let other = ConnectionDoctor.existingStep("Model Loader", host: "cdn.example.net", open: [v6], fresh: "192.0.2.10")
        #expect(other.status == .warning && other.detail.contains("It uses IPv6; this check’s fresh connection chose IPv4 (192.0.2.10)"))
        #expect(other.detail.hasSuffix("watch it in Model Loader’s bandwidth panel or with kilobat bandwidth \"Model Loader\"."))
        let mismatch = report([step("IPv4", .ok), step("IPv6", .ok), step("Server", .ok), other])
        #expect(mismatch.ok && mismatch.verdict.hasSuffix("but the app’s open connection takes another path."))
        let same = ConnectionDoctor.existingStep("Model Loader", host: "cdn.example.net", open: [v6], fresh: "2001:db8::20")
        #expect(same.status == .ok && same.detail.contains("reached another server (2001:db8::20)"))
        #expect(ConnectionDoctor.existingStep("Model Loader", host: "cdn.example.net", open: [v6], fresh: "2001:db8::10").detail.contains("another server") == false)
        #expect(ConnectionDoctor.existingStep("Model Loader", host: "cdn.example.net", open: [], fresh: nil).status == .skipped)
    }

    /// Acceptance case from lmstudio-bug-tracker#1031 (opened Sep 2025 on macOS, LM Studio 0.3.27; comments to Aug 2026, Windows too): large model
    /// downloads time out and need a manual resume, and several users said turning off LM Studio's Hugging Face proxy, some with a restart, fixed
    /// their case. User reports, not a diagnosis: the doctor may point at the setting, never claim the cause, a finished download or an auto-resume.
    @Test func aLargeHuggingFaceDownloadThroughTheAppsProxy() throws {
        typealias Hop = ConnectionProbe.Hop
        let lmStudio = DoctorClient(id: "ai.elementlabs.lmstudio", name: "LM Studio", version: "0.3.27")
        let url = try #require(URL(string: "https://huggingface.co/org/model-GGUF/resolve/main/model-Q8_0.gguf?download=true"))
        let wifi = ConnectionProbe.Link(name: "en0", kind: "Wi-Fi")
        let failedAt = Date(timeIntervalSince1970: 1_790_000_000), checked = failedAt.addingTimeInterval(1_800)
        // The general check is healthy: the network, the system proxy (none), DNS, and TCP and TLS over IPv4 and IPv6.
        let general = [step("Network", .ok), step("Interface", .ok), step("Proxy", .ok, "No system proxy for this address."), step("DNS", .ok), step("IPv4", .ok), step("IPv6", .ok)]
        // The app's path: its own proxy answers, but the request through it times out.
        let path = DoctorPath(kind: .appProxy, proxy: ConnectionDoctor.at("http://127.0.0.1:7890")), via = ConnectionDoctor.via(path, app: "LM Studio")
        let named = ConnectionDoctor.namedProxyStep("http://127.0.0.1:7890", app: "LM Studio", system: nil, answers: true)
        let request = ConnectionDoctor.requestSteps([Hop(url: url, answer: .failed("The request timed out."))])
        let direct = try #require(ConnectionDoctor.pathStep(via: via, over: wifi, direct: true, through: false, leftovers: []))
        // The download already under way went quiet: two samples four seconds apart, no new bytes.
        let open = OpenDestination(address: "18.244.0.10", ports: ["443"], protocols: ["TCP"], received: 3_200_000_000, sent: 90_000, connections: 1)
        let quiet = try #require(ConnectionDoctor.transferStep("LM Studio", host: "huggingface.co", earlier: [open], now: [open], seconds: 4))
        let setting = try #require(ConnectionDoctor.appSetting(for: lmStudio.id, hosts: ["huggingface.co"]))
        let steps = general + [named, ConnectionDoctor.appSettingStep(setting, path: path)] + request + [direct, quiet]
        let hops = [DoctorHop(url: ConnectionProbe.redacted(url), host: "huggingface.co", method: "HEAD", status: nil, error: "The request timed out")]
        let failing = ConnectionDoctor.report(ConnectionProbe.redacted(url), "huggingface.co", lmStudio.id, steps, hops: hops, over: "over Wi-Fi (en0) through \(via)",
                                              client: lmStudio, path: path, failedAt: failedAt, date: checked)

        // A healthy general check doesn't make this request healthy: the verdict tells the network apart from the app's path.
        #expect(!failing.ok && request.map(\.layer) == ["Request"] && direct.status == .failed)
        #expect(failing.verdict == "The network is fine: direct connections work. This request through LM Studio’s own proxy (127.0.0.1:7890) fails.")
        #expect(failing.next.hasPrefix("So LM Studio’s own path stops it, not this Mac’s connection. Check LM Studio’s Hugging Face proxy setting. In lmstudio-bug-tracker#1031 (Mar–Aug 2026), users reported"))
        #expect(failing.next.contains("Developer mode") && failing.next.contains("user reports, not a confirmed fix") && failing.next.hasSuffix("Kilobat doesn’t change LM Studio’s settings."))
        // Recorded: the real client and its version, the URL and the method sent, the path, and when the app failed beside when the check ran.
        #expect(failing.client == lmStudio && failing.app == "ai.elementlabs.lmstudio")
        #expect(failing.target == "https://huggingface.co/org/model-GGUF/resolve/main/model-Q8_0.gguf?download=[redacted]" && failing.method == "HEAD")
        #expect(failing.path == DoctorPath(kind: .appProxy, proxy: "127.0.0.1:7890", untested: "LM Studio’s Hugging Face proxy setting"))
        #expect(failing.failedAt == failedAt && failing.date == checked)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let json = try #require(try JSONSerialization.jsonObject(with: encoder.encode(failing)) as? [String: Any])
        #expect((json["client"] as? [String: String]) == ["id": "ai.elementlabs.lmstudio", "name": "LM Studio", "version": "0.3.27"])
        #expect((json["path"] as? [String: String])?["kind"] == "appProxy" && json["method"] as? String == "HEAD" && json["failedAt"] as? String == "2026-09-21T14:13:20Z")

        // Quiet is said as quiet, never as finished.
        #expect(quiet.status == .warning && quiet.detail == "LM Studio’s open connection to huggingface.co received nothing in 4 seconds (↓ \(TrafficFormat.bytes(3_200_000_000)) since it opened), so the transfer went quiet. That can be a stalled download, or a finished one whose connection is still open; Kilobat can’t tell which, so this doesn’t mean the download finished.")

        // The same quiet transfer with only the general check, which didn't go through the app's setting: the network works, the request isn't vouched for.
        let unverified = DoctorPath(kind: .direct, proxy: nil)
        let general2 = general + [ConnectionDoctor.appSettingStep(setting, path: unverified), step("Server", .ok), quiet]
        let healthy = ConnectionDoctor.report("https://huggingface.co/", "huggingface.co", lmStudio.id, general2, over: "over Wi-Fi (en0)", client: lmStudio, path: unverified, failedAt: failedAt, date: checked)
        #expect(healthy.ok && healthy.verdict == "The network reaches huggingface.co from this Mac over Wi-Fi (en0) right now, but LM Studio’s open transfer went quiet.")
        #expect(healthy.next.hasPrefix("Quiet isn’t finished: Kilobat can’t tell a stalled download from a completed one. Check the download in LM Studio; if it stopped, pause and resume it there. Check LM Studio’s Hugging Face proxy setting."))
        #expect(healthy.next.contains("This check ran after LM Studio failed at") && healthy.path?.untested == "LM Studio’s Hugging Face proxy setting")
        #expect(general2[6].detail.hasPrefix("LM Studio has its own Hugging Face proxy setting, which Kilobat can’t read or send a request through, so this check went directly."))
        let untested = ConnectionDoctor.report("https://huggingface.co/", "huggingface.co", lmStudio.id, general + [step("Server", .ok)], over: "over Wi-Fi (en0)", client: lmStudio, path: unverified)
        #expect(untested.ok && untested.verdict == "The network reaches huggingface.co from this Mac over Wi-Fi (en0) right now, but this check didn’t go through LM Studio’s Hugging Face proxy setting.")
        #expect(!untested.verdict.contains("This request works"))

        // Nothing claims a finished download, promises the app resumes on its own, or changes the app's settings.
        for report in [failing, healthy, untested] {
            let text = ([report.verdict, report.next] + report.steps.map(\.detail)).joined(separator: " ").lowercased()
            for claim in ["download is complete", "download completed", "finished downloading", "has finished", "resume automatically", "resumes automatically", "will resume", "auto-resume", "turned off for you", "kilobat turned"] {
                #expect(!text.contains(claim), "\(claim) in \(report.verdict)")
            }
        }
    }

    @Test func transfersAndSettingsAreToldApart() {
        let before = OpenDestination(address: "2001:db8::10", ports: ["443"], protocols: ["TCP"], received: 1_000_000, sent: 3_000, connections: 1)
        var after = before; after.received += 40_000_000
        #expect(ConnectionDoctor.transferStep("Model Loader", host: "cdn.example.net", earlier: [before], now: [after], seconds: 4)?.status == .ok)
        // A connection that opened or closed between the samples isn't compared.
        var reopened = before; reopened.connections = 2
        #expect(ConnectionDoctor.transferStep("Model Loader", host: "cdn.example.net", earlier: [before], now: [reopened], seconds: 4) == nil)
        #expect(ConnectionDoctor.transferStep("Model Loader", host: "cdn.example.net", earlier: [], now: [after], seconds: 4) == nil)
        // Keep-alives aren't a download moving.
        var trickle = before; trickle.received += 900
        #expect(ConnectionDoctor.transferStep("Model Loader", host: "cdn.example.net", earlier: [before], now: [trickle], seconds: 4)?.status == .warning)

        #expect(ConnectionDoctor.appSetting(for: "ai.elementlabs.lmstudio", hosts: ["cas-bridge.xethub.hf.co"])?.name == "LM Studio")
        #expect(ConnectionDoctor.appSetting(for: "ai.elementlabs.lmstudio", hosts: ["example.com", "nothf.co"]) == nil)
        #expect(ConnectionDoctor.appSetting(for: "com.example.App", hosts: ["huggingface.co"]) == nil)

        let now = Date(timeIntervalSince1970: 1_790_000_000), utc = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
        #expect(ConnectionDoctor.failureTime("2026-09-21T13:00:00Z", now: now) == Date(timeIntervalSince1970: 1_790_000_000 - 4_400))
        #expect(ConnectionDoctor.failureTime("14:00", now: now, calendar: utc) == Date(timeIntervalSince1970: 1_790_000_000 - 800))
        #expect(ConnectionDoctor.failureTime("15:00", now: now, calendar: utc) == Date(timeIntervalSince1970: 1_790_000_000 - 800 + 3_600 - 86_400))
        #expect(ConnectionDoctor.failureTime("2027-01-01T00:00:00Z", now: now) == nil && ConnectionDoctor.failureTime("soon", now: now) == nil)
    }

    private func report(_ steps: [DoctorStep]) -> DoctorReport { ConnectionDoctor.report("example.com", "example.com", nil, steps) }
    private func step(_ layer: String, _ status: DoctorStep.Status, _ detail: String = "") -> DoctorStep { DoctorStep(layer: layer, status: status, detail: detail) }

    @Test func oneBrokenIPVersionGetsItsOwnVerdict() {
        let v6 = report([step("IPv4", .ok), step("IPv6", .failed), step("Server", .ok)])
        #expect(!v6.ok && v6.verdict == "IPv4 works, but IPv6 is broken for this host." && v6.next.contains("Link-local only"))
        let v4 = report([step("IPv4", .failed), step("IPv6", .ok)])
        #expect(v4.verdict == "IPv6 works, but IPv4 is broken for this host." && !v4.next.contains("Link-local"))
        #expect(report([step("IPv4", .failed), step("IPv6", .failed)]).verdict == "The server can’t be reached.")
        #expect(report([step("IPv4", .failed), step("IPv6", .skipped)]).verdict == "The server can’t be reached.")
        #expect(report([step("IPv4", .failed), step("IPv6", .skipped), step("Secure connection", .failed)]).verdict.contains("secure connection"))
        let elsewhere = report([step("IPv4", .failed), step("Other networks", .warning, "It connects over Ethernet (en8), but not over Wi-Fi (en0).")])
        #expect(elsewhere.verdict.contains("over this network") && elsewhere.next.hasPrefix("It connects over Ethernet (en8)"))
    }

    @Test func familyStepsSayWhatHappened() {
        typealias Attempt = ConnectionProbe.Attempt
        let connected = Attempt(outcome: .connected, ms: 20, address: "192.0.2.1")
        func family(_ tcp: Attempt, _ tls: Attempt? = nil, available: Bool = true) -> DoctorStep {
            ConnectionDoctor.familyStep("IPv6", ConnectionDoctor.FamilyProbe(tcp: tcp, tls: tls), host: "example.com", port: 443, available: available)
        }
        #expect(family(connected, Attempt(outcome: .connected, ms: 30)).detail == "192.0.2.1: connected in 20 ms, secure connection in 30 ms.")
        let tls = family(connected, Attempt(outcome: .tlsFailed("certificate is expired")))
        #expect(tls.status == .failed && tls.detail.hasSuffix("but the secure connection failed: certificate is expired."))
        #expect(family(Attempt(outcome: .refused, address: "2001:db8::1")).detail == "2001:db8::1 refused the connection on port 443.")
        #expect(family(Attempt(outcome: .timedOut)).detail.contains("within 5 seconds"))
        #expect(family(Attempt(outcome: .noAddress)).status == .skipped)
        #expect(family(connected, available: false).detail == "This network has no IPv6.")
    }

    @Test func proxyURLsLoseTheirCredentials() {
        #expect(ConnectionProbe.redacted("http://user:secret@proxy.corp:8080") == "http://proxy.corp:8080")
        #expect(ConnectionProbe.redacted("socks5://me:p@ss@127.0.0.1:1080/") == "socks5://127.0.0.1:1080/")
        #expect(ConnectionProbe.redacted("user:pw@proxy:3128") == "proxy:3128")
        #expect(ConnectionProbe.redacted("http://proxy:8080/a@b") == "http://proxy:8080/a@b")
        #expect(ConnectionProbe.endpoint("proxy.corp")! == ("proxy.corp", 80))
        #expect(ConnectionProbe.endpoint("socks5h://127.0.0.1")! == ("127.0.0.1", 1080))
    }

    @Test func readsTheProxyFromAProcessEnvironment() {
        // KERN_PROCARGS2: argc, the executable path, padding, the arguments (one empty), the environment, then Apple's own strings.
        var buffer = withUnsafeBytes(of: Int32(3).littleEndian) { Array($0) }
        for text in ["/usr/local/bin/codex", "", "", "codex", "", "--yolo", "HTTPS_PROXY=http://me:secret@127.0.0.1:7890", "NO_PROXY=localhost,.corp.example", "TERM", "", "ptr_munge="] {
            buffer += Array(text.utf8) + [0]
        }
        let environment = ConnectionProbe.processEnvironment(buffer)
        #expect(environment == ["HTTPS_PROXY": "http://me:secret@127.0.0.1:7890", "NO_PROXY": "localhost,.corp.example"])
        #expect(ConnectionProbe.processEnvironment([1, 0]) == nil)
        let values = environment ?? [:]
        #expect(ConnectionProbe.environmentProxy(values, for: URL(string: "https://api.openai.com")!) == .init(variable: "HTTPS_PROXY", value: "http://127.0.0.1:7890"))
        #expect(ConnectionProbe.environmentProxy(values, for: URL(string: "https://git.corp.example")!)?.bypassed == true)
        #expect(ConnectionProbe.environmentProxy(["ALL_PROXY": "socks5://127.0.0.1:1080"], for: URL(string: "http://example.com")!)?.variable == "ALL_PROXY")
        #expect(ConnectionProbe.environmentProxy(["NO_PROXY": "*"], for: URL(string: "https://example.com")!) == nil)
    }

    @Test func appProxyComparesWithTheSystem() {
        let url = URL(string: "https://api.openai.com")!, found = ConnectionProbe.Environment.found(name: "Codex", values: ["HTTPS_PROXY": "http://u:p@127.0.0.1:7890"])
        let different = ConnectionDoctor.appProxyStep(found, app: "process:codex", url: url, system: nil, answers: true)
        #expect(different?.status == .warning && different?.detail == "Codex uses HTTPS_PROXY=http://127.0.0.1:7890 from its environment; the system uses none.")
        #expect(ConnectionDoctor.appProxyStep(found, app: "process:codex", url: url, system: "127.0.0.1:7890", answers: true)?.status == .ok)
        let dead = ConnectionDoctor.appProxyStep(found, app: "process:codex", url: url, system: nil, answers: false)
        #expect(dead?.status == .failed && dead?.detail.hasSuffix("nothing answers at 127.0.0.1:7890.") == true)
        #expect(report([dead!, step("IPv4", .ok)]).verdict == "The app’s proxy isn’t answering.")
        let none = ConnectionDoctor.appProxyStep(.found(name: "Codex", values: ["PATH": "/usr/bin"]), app: "process:codex", url: url, system: "proxy.corp:8080", answers: nil)
        #expect(none?.status == .warning && none?.detail.contains("connect directly") == true)
        #expect(ConnectionDoctor.appProxyStep(.notRunning, app: "process:codex", url: url, system: nil, answers: nil)?.detail == "codex isn’t running, so its proxy settings weren’t checked.")
        #expect(ConnectionDoctor.appProxyStep(.unreadable, app: "process:curl", url: url, system: nil, answers: nil) == nil)
    }

    @Test func splitDNSNamesThePrivateResolver() {
        let scutil = """
        DNS configuration

        resolver #1
          search domain[0] : home.arpa
          nameserver[0] : 192.168.1.254
          if_index : 11 (en0)

        resolver #2
          domain   : tail1234.ts.net
          nameserver[0] : 100.100.100.100

        resolver #3
          domain   : local
          options  : mdns

        DNS configuration (for scoped queries)

        resolver #1
          nameserver[0] : 10.0.0.1
        """
        let tailnet = ConnectionProbe.resolver(for: "Box.tail1234.ts.net", in: scutil)
        #expect(tailnet == .init(server: "100.100.100.100", domain: "tail1234.ts.net"))
        #expect(tailnet?.description == "100.100.100.100, the private resolver for tail1234.ts.net")
        #expect(ConnectionProbe.resolver(for: "example.com", in: scutil) == .init(server: "192.168.1.254"))

        let silent = ConnectionDoctor.dnsFailure("box.tail1234.ts.net", resolver: tailnet, private: nil, public: [])
        #expect(silent.detail == "box.tail1234.ts.net goes to 100.100.100.100, the private resolver for tail1234.ts.net, and it doesn’t answer. Public DNS works.")
        #expect(report([silent]).verdict == "Private DNS isn’t answering.")
        #expect(report([ConnectionDoctor.dnsFailure("x.tail1234.ts.net", resolver: tailnet, private: [], public: [])]).verdict == "The private resolver can’t resolve it.")
        let mine = ConnectionDoctor.dnsFailure("example.com", resolver: .init(server: "192.168.1.254"), private: nil, public: ["93.184.215.14"])
        #expect(mine.detail.contains("but 1.1.1.1 resolves it") && report([mine]).verdict == "Your DNS server can’t resolve it.")
        #expect(report([ConnectionDoctor.dnsFailure("nope.invalid", resolver: nil, private: nil, public: [])]).verdict == "The name doesn’t resolve.")
    }

    @Test func aTunnelThatFailsWhileTheDirectPathWorks() {
        let wifi = ConnectionProbe.Link(name: "en0", kind: "Wi-Fi")
        let left = ConnectionProbe.leftovers([("en0", "192.168.1.20"), ("en8", "172.20.10.2"), ("en5", "169.254.3.1"), ("utun4", "198.18.0.1"), ("bridge100", "192.168.64.1")], active: ["en0", "utun4"])
        #expect(left == ["en8 (172.20.10.2)"])
        let stale = ConnectionDoctor.pathStep(via: "the VPN (utun4)", over: wifi, direct: true, through: false, leftovers: left)
        #expect(stale?.status == .failed && stale?.detail == "Direct connections over Wi-Fi (en0) work; through the VPN (utun4) they fail. en8 (172.20.10.2) still has an address from a network that’s no longer in use.")
        let tunnel = report([step("Interface", .warning), step("IPv4", .failed), stale!])
        #expect(tunnel.verdict == "Direct connections work; traffic through the VPN or proxy fails." && tunnel.next.contains("network you left"))
        let fresh = ConnectionDoctor.pathStep(via: "the system proxy (proxy.corp:8080)", over: wifi, direct: true, through: false, leftovers: [])
        #expect(!report([step("Server", .ok), fresh!]).next.contains("network you left"))
        // Kilobat's own block is the surer cause.
        #expect(report([step("Kilobat rules", .failed), stale!]).verdict == "Kilobat is blocking it.")
        #expect(ConnectionDoctor.pathStep(via: "the VPN (utun4)", over: wifi, direct: false, through: false, leftovers: [])?.status == .warning)
        #expect(ConnectionDoctor.pathStep(via: "the VPN (utun4)", over: wifi, direct: true, through: nil, leftovers: []) == nil)
    }

    @Test func comparesInterfaces() {
        let wifi = ConnectionProbe.Link(name: "en0", kind: "Wi-Fi"), phone = ConnectionProbe.Link(name: "en8", kind: "Ethernet", expensive: true)
        #expect(phone.label == "Ethernet (en8, metered)")
        let results = [(wifi, ConnectionProbe.Attempt(outcome: .timedOut)), (phone, ConnectionProbe.Attempt(outcome: .connected, ms: 40))]
        let rescue = ConnectionDoctor.comparisonStep(results, reached: false)
        #expect(rescue?.status == .warning && rescue?.detail == "It connects over Ethernet (en8, metered), but not over Wi-Fi (en0).")
        #expect(ConnectionDoctor.comparisonStep(results, reached: true)?.detail == "Wi-Fi (en0) doesn’t connect; Ethernet (en8, metered) connects in 40 ms.")
        #expect(ConnectionDoctor.comparisonStep(Array(results.prefix(1)), reached: false) == nil)
        #expect(ConnectionDoctor.interfaceStep(phone, source: "172.20.10.2", underlying: nil).detail.hasPrefix("Connections leave through Ethernet (en8, metered) from 172.20.10.2. macOS marks it metered"))
        #expect(ConnectionDoctor.interfaceStep(ConnectionProbe.Link(name: "utun4", kind: "VPN"), underlying: wifi).status == .warning)
    }

    @Test func notesWhenTheCodeRunsElsewhere() {
        #expect(ConnectionDoctor.contextStep(nil, host: "example.com", url: "https://example.com/") == nil)
        let container = ConnectionDoctor.contextStep(.container, host: "example.com", url: "https://example.com/")
        #expect(container?.status == .skipped && container?.detail.hasSuffix("Check from there: docker run --rm curlimages/curl -sv https://example.com/") == true)
        let service = ConnectionDoctor.contextStep(nil, host: "db", url: "https://db:5432/")
        #expect(service?.detail.hasPrefix("db looks like a name inside a container") == true && service?.detail.contains("--network <network>") == true)
        #expect(ConnectionDoctor.contextStep(.container, host: "localhost", url: "http://localhost:3000/")?.detail.contains("host.docker.internal") == true)
        #expect(ConnectionDoctor.contextStep(.remote, host: "api.example.com", url: "https://api.example.com/")?.detail.hasSuffix("ssh <host> curl -sv https://api.example.com/") == true)
        #expect(ConnectionDoctor.looksInternal("api.svc.cluster.local") && !ConnectionDoctor.looksInternal("10.0.0.1") && !ConnectionDoctor.looksInternal("localhost"))
        // Unreachable from the Mac: the next step is to check from there. A broken IPv6 path stays the Mac's own problem.
        let note = container!
        #expect(report([step("IPv4", .failed), note]).next == note.detail)
        #expect(report([step("IPv4", .ok), step("IPv6", .failed), note]).next.contains("Link-local"))
        #expect(report([step("DNS", .failed, "db didn’t resolve to an address."), note]).verdict == "The name doesn’t resolve on this Mac.")
    }

    @Test func aManagedProviderCantReachAPrivateEndpoint() throws {
        let warp = "dev.warp.Warp-Stable"
        #expect(ConnectionDoctor.Context.allCases.map(\.rawValue) == ["container", "vm", "remote", "provider"])
        #expect(ConnectionDoctor.provider(for: warp)?.name == "Warp" && ConnectionDoctor.provider(for: "com.example.App") == nil && ConnectionDoctor.provider(for: nil) == nil)
        func reach(_ host: String, _ addresses: [String] = [], _ resolver: ConnectionProbe.Resolver? = nil) -> String? {
            ConnectionDoctor.privateReach(host, addresses: addresses, resolver: resolver)
        }
        #expect(reach("localhost") == "localhost is this Mac itself" && reach("127.0.0.1") == "127.0.0.1 is this Mac itself" && reach("::1") == "::1 is this Mac itself")
        #expect(reach("192.168.1.20") == "192.168.1.20 is a private address" && reach("100.101.102.103") == "100.101.102.103 is a private address")
        #expect(reach("fd7a:115c:a1e0::1") == "fd7a:115c:a1e0::1 is a private address")
        #expect(reach("gpu.tail1234.ts.net", ["100.88.1.2"]) == "gpu.tail1234.ts.net resolves to 100.88.1.2, a private address")
        #expect(reach("llm.corp.example", ["203.0.113.9"], .init(server: "10.0.0.53", domain: "corp.example")) == "llm.corp.example resolves only through private DNS (10.0.0.53)")
        #expect(reach("studio.local") != nil && reach("nas") != nil && reach("api.example.com", ["93.184.215.14"]) == nil && reach("93.184.215.14") == nil)

        // Declared: the endpoint works from the Mac, but Warp's servers can't reach it. Real options, dated, no SSH and no tunnel.
        let url = "http://localhost:11434/v1/models"
        let declared = try #require(ConnectionDoctor.contextStep(.provider, host: "localhost", url: url, provider: ConnectionDoctor.provider(for: warp)))
        #expect(declared.layer == "Provider" && declared.status == .failed)
        #expect(declared.detail.hasPrefix("Warp’s docs (Oct 2026) say requests to a custom inference endpoint go through Warp’s servers") && declared.detail.contains("localhost is this Mac itself, so Warp’s servers can’t reach it."))
        let works = ConnectionDoctor.report(url, "localhost", warp, [step("IPv4", .ok), step("Server", .ok), declared], over: "over Wi-Fi (en0)")
        #expect(!works.ok && works.verdict == "This works from this Mac over Wi-Fi (en0), but Warp’s servers can’t reach a private address.")
        #expect(works.next.hasPrefix("Point it at an endpoint you control with a public address") && works.next.contains("OpenAI, Anthropic or Google key"))
        #expect(works.next.contains("Warp’s docs (Oct 2026), https://docs.warp.dev/") && works.next.contains("won’t change it"))
        for text in [works.next, declared.detail] { #expect(!text.lowercased().contains("ssh") && !text.lowercased().contains("tunnel") && !text.contains("ngrok")) }

        // A failure on the Mac comes first; the provider's reach stays unmeasured, not merged into it.
        let down = ConnectionDoctor.report(url, "localhost", warp, [step("IPv4", .failed, "127.0.0.1 refused the connection on port 11434."), declared])
        #expect(down.verdict == "The server can’t be reached." && !down.next.contains("Warp"))

        // A public endpoint: nothing known blocks it, and Kilobat says it can't measure from there.
        let open = try #require(ConnectionDoctor.contextStep(.provider, host: "llm.example.com", url: "https://llm.example.com/", provider: ConnectionDoctor.provider(for: warp), addresses: ["93.184.215.14"]))
        #expect(open.status == .skipped && open.detail.hasSuffix("Kilobat can’t test from Warp’s servers, so whether they reach it is unknown."))
        let fine = ConnectionDoctor.report("https://llm.example.com/", "llm.example.com", warp, [step("Server", .ok), open])
        #expect(fine.ok && fine.verdict == "This request works from this Mac right now." && fine.next == open.detail)

        // Warp picked as the app with no context: Warp also runs commands on the Mac, so the note is an if.
        let guessed = try #require(ConnectionDoctor.contextStep(nil, host: "192.168.1.20", url: "http://192.168.1.20:1234/", provider: ConnectionDoctor.provider(for: warp)))
        #expect(guessed.status == .warning && guessed.detail.hasPrefix("If this is Warp’s custom inference endpoint: "))
        let maybe = ConnectionDoctor.report("http://192.168.1.20:1234/", "192.168.1.20", warp, [step("Server", .ok), guessed])
        #expect(maybe.verdict == "This works from this Mac, but if Warp makes the request from its servers, they can’t reach a private address." && maybe.next.hasPrefix("Point it at"))
        let unsure = ConnectionDoctor.contextStep(nil, host: "api.example.com", url: "https://api.example.com/", provider: ConnectionDoctor.provider(for: warp), addresses: ["93.184.215.14"])!
        #expect(ConnectionDoctor.report("https://api.example.com/", "api.example.com", warp, [step("Server", .ok), unsure]).next.contains("kilobat why --proxy"))

        // An unnamed provider: no provider-specific or dated claim.
        let generic = try #require(ConnectionDoctor.contextStep(.provider, host: "10.0.0.5", url: "http://10.0.0.5/"))
        #expect(generic.detail.hasPrefix("The provider’s servers make this request, not this Mac. 10.0.0.5 is a private address") && !generic.detail.contains("docs"))
        let unnamed = ConnectionDoctor.report("http://10.0.0.5/", "10.0.0.5", nil, [step("Server", .ok), generic])
        #expect(unnamed.verdict.hasSuffix("but the provider’s servers can’t reach a private address.") && unnamed.next.contains("a route the provider supports") && !unnamed.next.contains("Source"))
        // A context the person names wins over the app.
        #expect(ConnectionDoctor.contextStep(.container, host: "localhost", url: url, provider: ConnectionDoctor.provider(for: warp))?.layer == "Context")
    }

    @Test func parsesADirectDNSAnswer() {
        let query = ConnectionProbe.dnsQuery("example.com", id: 0x1234)
        #expect(Array(query.prefix(4)) == [0x12, 0x34, 0x01, 0x00] && query.count == 12 + 13 + 4)
        // The query echoed back with one compressed A record answer.
        var answer = Array(query)
        answer[2] = 0x81; answer[3] = 0x80; answer[7] = 1
        answer += [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0x0e, 0x10, 0, 4, 93, 184, 215, 14]
        #expect(ConnectionProbe.dnsAnswers(Data(answer), id: 0x1234) == ["93.184.215.14"])
        #expect(ConnectionProbe.dnsAnswers(Data(answer), id: 0x9999) == nil)
        answer[3] = 0x83
        #expect(ConnectionProbe.dnsAnswers(Data(answer), id: 0x1234) == [])
    }
}
