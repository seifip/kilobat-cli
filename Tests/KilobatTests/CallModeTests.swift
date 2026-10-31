import Darwin
import Foundation
import Testing
@testable import KilobatCore

struct CallModeTests {
    private func status(_ pid: Int32) -> UInt32? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
        return info.pbi_status
    }

    @Test func holdsAndAlwaysResumesAProcess() throws {
        let ledger = FileManager.default.temporaryDirectory.appendingPathComponent("held-\(UUID().uuidString).json")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }
        let held = CallMode.hold([child.processIdentifier, 1, getpid()], app: "Dropbox", ledger: ledger)
        #expect(held.map(\.pid) == [child.processIdentifier])
        #expect(status(child.processIdentifier) == UInt32(SSTOP))
        // Written down before it stopped, so a crash still resumes it.
        #expect(CallMode.held(ledger: ledger).count == 1)
        #expect(CallMode.resume(ledger: ledger).count == 1)
        #expect(status(child.processIdentifier) != UInt32(SSTOP))
        #expect(CallMode.held(ledger: ledger).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ledger.path))
    }

    @Test func neverResumesAReusedPID() throws {
        let ledger = FileManager.default.temporaryDirectory.appendingPathComponent("held-\(UUID().uuidString).json")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]
        try child.run()
        defer { kill(child.processIdentifier, SIGCONT); child.terminate() }
        kill(child.processIdentifier, SIGSTOP)
        CallMode.save([CallMode.Held(pid: child.processIdentifier, started: 1, app: "Steam")], ledger)
        CallMode.resume(ledger: ledger)
        #expect(status(child.processIdentifier) == UInt32(SSTOP))
    }

    @Test func findsTheCallInAMeeting() {
        #expect(PreflightCheck.meeting(in: "Join: https://us02web.zoom.us/j/8123456789?pwd=abc") == "Zoom")
        #expect(PreflightCheck.meeting(in: "https://meet.google.com/abc-defg-hij") == "Google Meet")
        #expect(PreflightCheck.meeting(in: "Microsoft Teams meeting https://teams.microsoft.com/l/meetup-join/19%3a") == "Microsoft Teams")
        #expect(PreflightCheck.meeting(in: "Lunch at the café on 5th") == nil)
    }

    @Test func saysWhatToFixBeforeACall() {
        let result = Preflight(date: Date(), issues: [.init(kind: .app, app: "Dropbox", uploading: true), .init(kind: .wifi), .init(kind: .app, app: "Mail", uploading: false)])
        // The list's commas follow the Mac's locale.
        #expect(result.summary.hasPrefix("Dropbox is uploading, Wi-Fi is weak"))
        #expect(result.summary.hasSuffix("Mail is downloading"))
        #expect(result.holdable == ["Dropbox"])
        #expect(Preflight(date: Date(), issues: []).clear)
    }

    @Test func knowsTheAppsItHolds() {
        #expect(CallMode.name(of: "com.getdropbox.dropbox") == "Dropbox")
        #expect(CallMode.name(of: "com.valvesoftware.steam.helper") == "Steam")
        #expect(CallMode.name(of: "com.google.Chrome") == nil)
        #expect(CallMode.name(of: "com.apple.bird") == nil)
    }
}
