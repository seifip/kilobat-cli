import Darwin
import Foundation
import Testing
@testable import KilobatCore

/// What the app's quit and digest loop rely on from the core: a cast's hold is let go by its owner, the digest
/// schedule can say "not now" without the history, and the Protection ledger is kept without loading the rest.
struct SweepAppSupportTests {
    private let utc: Calendar = { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!; return calendar }()
    private func at(_ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }
    private func status(_ pid: Int32) -> UInt32? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
        return info.pbi_status
    }

    @Test func releasingTheCastResumesWhatItPaused() throws {
        let ledger = FileManager.default.temporaryDirectory.appendingPathComponent("held-\(UUID().uuidString).json")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]
        try child.run()
        defer { kill(child.processIdentifier, SIGCONT); child.terminate(); try? FileManager.default.removeItem(at: ledger) }
        #expect(CallMode.hold([child.processIdentifier], app: "Dropbox", owner: CallMode.cast, ledger: ledger).count == 1)
        #expect(status(child.processIdentifier) == UInt32(SSTOP))
        #expect(CallMode.resume(owner: CallMode.cast, ledger: ledger).map(\.pid) == [child.processIdentifier])
        #expect(status(child.processIdentifier) != UInt32(SSTOP))
        #expect(CallMode.held(ledger: ledger).isEmpty)
    }

    @Test func theScheduleWaitsWithoutLookingAtHistory() {
        // 2 November 2026 is a Monday; the slot is at 9.
        let slot = at(2, 9), now = at(2, 9, 10)
        #expect(DigestSchedule(enabled: false).decide(now: now, last: nil, historyStart: .distantPast, calendar: utc) == .wait)
        #expect(DigestSchedule().decide(now: now, last: slot, historyStart: .distantPast, calendar: utc) == .wait)
        #expect(DigestSchedule().decide(now: now, last: slot.addingTimeInterval(-7 * 86_400), historyStart: .distantPast, calendar: utc) != .wait)
    }

    @Test func theLedgerIsRefreshedFromTheFilterLogAlone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("digest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        let events = [FilterEvent(date: now, app: "node", endpoint: "x.example:443", direction: "outgoing", reason: "",
                                  protection: ProtectionDetail(kind: .malware, list: "URLhaus", host: "x.example"))]
        try JSONEncoder().encode(events).write(to: folder.appendingPathComponent("filter-events.json"))
        DigestLedger.refresh(directory: folder, now: now)
        let file = DigestLedger.file(folder)
        #expect(DigestLedger.load(directory: folder).days[DigestLedger.key(now)]?.threats == 1)
        let written = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: file.path)
        // Nothing new: the file is left alone.
        DigestLedger.refresh(directory: folder, now: now)
        #expect(written != nil)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == Date(timeIntervalSince1970: 1_000_000))
    }
}
