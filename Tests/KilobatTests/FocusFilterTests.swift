import Darwin
import Foundation
import Testing
@testable import KilobatCore

@MainActor struct FocusFilterTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("focus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func stopped(_ pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return false }
        return info.pbi_status == UInt32(SSTOP)
    }
    private func sleeper() throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]
        try child.run()
        return child
    }
    private func store(_ path: URL, traffic: TrafficStore, pro: Bool = true, processes: [(id: String, pids: [Int32], download: Double?)] = []) -> FocusFilterStore {
        let focus = FocusFilterStore(directory: path, ledger: path.appendingPathComponent("held.json"))
        focus.allowed = { pro }; focus.traffic = { traffic }; focus.processes = { processes }; focus.skipped = { [] }; focus.gameInFront = { false }
        return focus
    }

    @Test func switchesTheProfileAndPutsItBack() throws {
        let path = try folder(); defer { try? FileManager.default.removeItem(at: path) }
        let traffic = TrafficStore(directory: path, startMonitoring: false)
        traffic.preferences.profile = .unrestricted
        let focus = store(path, traffic: traffic)
        #expect(focus.apply(FocusFilter(profile: .work)))
        #expect(traffic.preferences.profile == .work)
        // A second Focus straight after the first still returns to the profile from before both.
        focus.apply(FocusFilter(profile: .travel))
        #expect(traffic.preferences.profile == .travel)
        focus.apply(FocusFilter())
        #expect(traffic.preferences.profile == .unrestricted)
        #expect(focus.state == nil && !FileManager.default.fileExists(atPath: path.appendingPathComponent("focus.json").path))
    }

    @Test func aProfilePickedDuringTheFocusStays() throws {
        let path = try folder(); defer { try? FileManager.default.removeItem(at: path) }
        let traffic = TrafficStore(directory: path, startMonitoring: false)
        traffic.preferences.profile = .unrestricted
        let focus = store(path, traffic: traffic)
        focus.apply(FocusFilter(profile: .work))
        traffic.preferences.profile = .travel
        focus.apply(FocusFilter())
        #expect(traffic.preferences.profile == .travel)
    }

    @Test func pausesUpdatersOnAnyNetworkUntilTheFocusEnds() throws {
        let path = try folder(); defer { try? FileManager.default.removeItem(at: path) }
        let traffic = TrafficStore(directory: path, startMonitoring: false)
        traffic.preferences.profile = .work
        let focus = store(path, traffic: traffic)
        focus.apply(FocusFilter(pauseUpdaters: true))
        #expect(FilterController.policy(traffic.preferences, budgetReached: false, metered: false)["updatersPaused"] as? Bool == true)
        #expect(focus.summary == "Focus · updaters paused")
        // The setting for metered networks is separate: turning it off doesn't undo the Focus.
        traffic.preferences.pauseUpdaters = false
        #expect(UpdaterPause.active(traffic.preferences, metered: false))
        focus.apply(FocusFilter())
        #expect(traffic.preferences.focusPausesUpdaters == nil)
        #expect(FilterController.policy(traffic.preferences, budgetReached: false, metered: false)["updatersPaused"] as? Bool == false)
    }

    @Test func withoutProOnlyUnrestrictedApplies() throws {
        let path = try folder(); defer { try? FileManager.default.removeItem(at: path) }
        let traffic = TrafficStore(directory: path, startMonitoring: false)
        traffic.preferences.profile = .travel
        let focus = store(path, traffic: traffic, pro: false)
        #expect(!focus.apply(FocusFilter(profile: .work, pauseUpdaters: true)))
        #expect(traffic.preferences.profile == .travel && traffic.preferences.focusPausesUpdaters == nil)
        #expect(focus.state == nil && focus.refused != nil && focus.summary != nil)
        #expect(focus.apply(FocusFilter(profile: .unrestricted)))
        #expect(traffic.preferences.profile == .unrestricted)
        focus.apply(FocusFilter())
        #expect(traffic.preferences.profile == .travel && focus.refused == nil)
    }

    @Test func holdsAppsAndLetsGoWhenTheFocusEnds() throws {
        let path = try folder(); defer { try? FileManager.default.removeItem(at: path) }
        let child = try sleeper(); defer { kill(child.processIdentifier, SIGCONT); child.terminate() }
        let traffic = TrafficStore(directory: path, startMonitoring: false)
        let focus = store(path, traffic: traffic, processes: [("com.getdropbox.dropbox", [child.processIdentifier], nil), ("com.google.Chrome", [child.processIdentifier], nil)])
        focus.apply(FocusFilter(profile: .work, holdApps: true))
        #expect(stopped(child.processIdentifier))
        #expect(focus.holding == ["Dropbox"])
        #expect(focus.summary == "Focus: Work is holding Dropbox")
        focus.apply(FocusFilter())
        #expect(!stopped(child.processIdentifier))
        #expect(CallMode.held(ledger: path.appendingPathComponent("held.json")).isEmpty)
    }

    @Test func aCallEndingKeepsWhatTheFocusHoldsAndTheOtherWayRound() throws {
        let path = try folder(); defer { try? FileManager.default.removeItem(at: path) }
        let ledger = path.appendingPathComponent("held.json")
        let child = try sleeper(); defer { kill(child.processIdentifier, SIGCONT); child.terminate() }
        let focus = store(path, traffic: TrafficStore(directory: path, startMonitoring: false), processes: [("com.getdropbox.dropbox", [child.processIdentifier], nil)])
        focus.apply(FocusFilter(holdApps: true))
        // A call starts and holds the same app: it's noted as the call's too, without a second stop.
        #expect(CallMode.hold([child.processIdentifier], app: "Dropbox", owner: CallMode.call, ledger: ledger).count == 1)
        CallMode.resume(owner: CallMode.call, ledger: ledger)
        #expect(stopped(child.processIdentifier))
        // Now the other way: the call holds it again, the Focus ends, the call still has it.
        CallMode.hold([child.processIdentifier], app: "Dropbox", owner: CallMode.call, ledger: ledger)
        focus.apply(FocusFilter())
        #expect(stopped(child.processIdentifier))
        CallMode.resume(app: "Dropbox", owner: CallMode.call, ledger: ledger)
        #expect(!stopped(child.processIdentifier))
    }

    @Test func anAppBroughtToTheFrontRunsForTheRestOfTheFocus() throws {
        let path = try folder(); defer { try? FileManager.default.removeItem(at: path) }
        let child = try sleeper(); defer { kill(child.processIdentifier, SIGCONT); child.terminate() }
        let focus = store(path, traffic: TrafficStore(directory: path, startMonitoring: false), processes: [("com.valvesoftware.steam", [child.processIdentifier], 5_000_000)])
        focus.apply(FocusFilter(holdApps: true))
        #expect(stopped(child.processIdentifier))
        focus.letGo("com.valvesoftware.steam")
        focus.rescan()
        #expect(!stopped(child.processIdentifier) && focus.holding.isEmpty)
    }

    @Test func launchersAreHeldOnlyWhileDownloadingAndNoGameIsInFront() throws {
        let path = try folder(); defer { try? FileManager.default.removeItem(at: path) }
        let child = try sleeper(); defer { kill(child.processIdentifier, SIGCONT); child.terminate() }
        var rate = 0.0, gaming = false
        let focus = store(path, traffic: TrafficStore(directory: path, startMonitoring: false))
        focus.processes = { [("com.valvesoftware.steam", [child.processIdentifier], rate)] }
        focus.gameInFront = { gaming }
        focus.apply(FocusFilter(holdApps: true))
        #expect(!stopped(child.processIdentifier) && focus.holding.isEmpty)
        rate = 5_000_000; gaming = true
        focus.rescan()
        #expect(!stopped(child.processIdentifier))
        gaming = false
        focus.rescan()
        #expect(stopped(child.processIdentifier) && focus.holding == ["Steam"])
        // A game comes to the front later in the Focus: the launcher runs again.
        gaming = true
        focus.rescan()
        #expect(!stopped(child.processIdentifier) && focus.holding.isEmpty)
        focus.apply(FocusFilter())
    }

    @Test func skipsAppsCallModeLeavesAlone() throws {
        let path = try folder(); defer { try? FileManager.default.removeItem(at: path) }
        let child = try sleeper(); defer { kill(child.processIdentifier, SIGCONT); child.terminate() }
        let focus = store(path, traffic: TrafficStore(directory: path, startMonitoring: false), processes: [("com.getdropbox.dropbox", [child.processIdentifier], nil)])
        var skipped: Set<String> = []
        focus.skipped = { skipped }
        focus.apply(FocusFilter(holdApps: true))
        #expect(stopped(child.processIdentifier))
        skipped = ["Dropbox"]
        focus.rescan()
        #expect(!stopped(child.processIdentifier) && focus.holding.isEmpty)
    }

    @Test func aRelaunchPutsBackWhatAFocusThatEndedChanged() throws {
        let path = try folder(); defer { try? FileManager.default.removeItem(at: path) }
        let traffic = TrafficStore(directory: path, startMonitoring: false)
        traffic.preferences.profile = .unrestricted
        store(path, traffic: traffic).apply(FocusFilter(profile: .work, pauseUpdaters: true))
        // Crash: nothing ran on the way out. The next launch finds no Focus on.
        let relaunched = store(path, traffic: traffic)
        #expect(relaunched.state?.appliedProfile == .work)
        relaunched.reconcile(nil)
        #expect(traffic.preferences.profile == .unrestricted && traffic.preferences.focusPausesUpdaters == nil && relaunched.state == nil)
    }

    @Test func theLaunchCheckNeverOverrulesAFocusThatArrived() throws {
        let path = try folder(); defer { try? FileManager.default.removeItem(at: path) }
        let traffic = TrafficStore(directory: path, startMonitoring: false)
        traffic.preferences.profile = .unrestricted
        let focus = store(path, traffic: traffic)
        focus.apply(FocusFilter(profile: .travel))
        focus.reconcile(nil)
        #expect(traffic.preferences.profile == .travel)
    }
}
