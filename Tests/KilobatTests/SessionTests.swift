import Foundation
import Testing
@testable import KilobatCore

@MainActor struct SessionTests {
    /// Registered values are never saved, and notifications stay off outside an app bundle.
    private func store(directory: URL? = nil, quietMinutes: Int = 3) -> SessionStore {
        let defaults = UserDefaults(suiteName: "co.seifi.kilobat.tests." + UUID().uuidString)!
        defaults.register(defaults: ["awake.agents": false, "awake.notify": false, "awake.quietMinutes": quietMinutes, "awake.webhook": ""])
        return SessionStore(directory: directory, defaults: defaults)
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
        sessions.tick(apps: [traffic("process:claude", rate: 5_000)], interval: 2, now: start + 2)
        #expect(sessions.agents["Claude Code"] != nil)
        sessions.tick(apps: [traffic("process:claude", rate: 5_000)], interval: 2, now: start + 4)
        var now = start + 4
        while !sessions.agents.isEmpty && now < start + 600 {
            now += 2; sessions.tick(apps: [traffic("process:claude", rate: 0)], interval: 2, now: now)
        }
        let run = sessions.history.first
        #expect(run?.kind == .agent && run?.title == "Claude Code" && run?.ended == "Went quiet")
        // The run ends when it last moved data, not when the quiet minutes ran out.
        #expect(run?.end == start + 4)
        #expect(run?.received == 9_000 && run?.sent == 1_000)
        #expect(now >= start + 4 + 180)
    }

    @Test func agentRunEndsWhenTheProcessExits() {
        let sessions = store(), start = Date()
        sessions.tick(apps: [traffic("process:codex", rate: 5_000)], interval: 2, now: start)
        #expect(sessions.agents["Codex"] != nil)
        sessions.tick(apps: [], interval: 2, now: start + 2)
        #expect(sessions.agents.isEmpty && sessions.history.first?.ended == "Exited")
        // A process that is gone never starts a run.
        sessions.tick(apps: [traffic("process:codex", rate: 5_000, pid: 999_999)], interval: 2, now: start + 4)
        #expect(sessions.agents.isEmpty)
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
        #expect(report([("VPN & proxy", .warning), ("Connection", .failed)]).next.contains("VPN or proxy off"))
        #expect(!report([("VPN & proxy", .ok), ("Connection", .failed)]).next.contains("VPN"))
        #expect(report([("Secure connection", .failed)]).verdict.contains("secure connection"))
        #expect(report([("Server", .failed)]).verdict == "The server is having problems.")
        let refused = ConnectionDoctor.report("example.com", "example.com", nil, [DoctorStep(layer: "Server", status: .warning, detail: "The server answered but refused access (HTTP 403).")])
        #expect(refused.ok && refused.verdict == "Your Mac reaches it fine." && refused.next.contains("login"))
        let missing = ConnectionDoctor.report("example.com", "example.com", nil, [DoctorStep(layer: "Server", status: .warning, detail: "The server answered with HTTP 404.")])
        #expect(missing.ok && !missing.next.contains("login") && missing.next.contains("address"))
        let fine = report([("Network", .ok), ("VPN & proxy", .warning), ("Server", .ok)])
        #expect(fine.ok && fine.next.contains("kilobat why"))
    }
}
