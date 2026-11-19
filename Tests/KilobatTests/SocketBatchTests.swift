import Foundation
import Testing
@testable import KilobatCore

/// Counts lsof launches and answers from a fixed table of per-pid sockets, as lsof does for `-p 1,2,3`.
private final class FakeLsof: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    let table: [Int32: String]
    init(table: [Int32: String] = [:]) { self.table = table }
    var launches: Int { lock.withLock { calls.count } }
    var lists: [[Int32]] { lock.withLock { calls.map { ($0.last ?? "").split(separator: ",").compactMap { Int32($0) } } } }
    var launcher: ExpertTools.CommandLauncher {
        { _, args, _ in
            self.lock.withLock { self.calls.append(args) }
            let wanted = (args.last ?? "").split(separator: ",").compactMap { Int32($0) }
            // A pid with no entry (exited, or no sockets) prints nothing and makes lsof exit 1.
            let output = wanted.compactMap { self.table[$0] }.joined()
            return CommandResult(output: output, status: wanted.contains { self.table[$0] == nil } ? 1 : 0)
        }
    }
}

private func socket(_ pid: Int32, _ remote: String, name: String = "node") -> String {
    "p\(pid)\nc\(name)\nf12\nPTCP\nn192.0.2.1:50000->\(remote)\nTST=ESTABLISHED\nTQR=0\nTQS=0\n"
}

struct SocketBatchTests {
    @Test func threeAgentsCostOneLaunchAndEachKeepsItsOwnRows() async throws {
        let families: [String: Set<Int32>] = ["a": Set(100..<110), "b": Set(200..<220), "c": Set(300..<305)]
        var table: [Int32: String] = [:]
        for pid in families.values.flatMap({ $0 }) { table[pid] = socket(pid, "198.51.100.\(pid % 250):443") }
        let fake = FakeLsof(table: table)
        let rows = try await ExpertTools.destinations(pids: families.values.flatMap { $0 }, launch: fake.launcher)
        #expect(fake.launches == 1)   // before this change: 10 + 20 + 5 = 35
        #expect(rows.count == 35)
        let owned = SessionStore.attribute(rows, to: families)
        for (key, family) in families {
            #expect(Set(owned[key]!.map(\.pid)) == family)
            #expect(owned[key]!.count == family.count)
        }
    }

    @Test func aMissingPidYieldsNoRowsAndNoError() async throws {
        let fake = FakeLsof(table: [10: socket(10, "198.51.100.1:443")])
        let rows = try await ExpertTools.destinations(pids: [10, 11], launch: fake.launcher)
        #expect(rows.map(\.pid) == [10])
        let none = try await ExpertTools.destinations(pids: [11], launch: fake.launcher)
        #expect(none.isEmpty)
        let failing: ExpertTools.CommandLauncher = { _, _, _ in CommandResult(output: "lsof: illegal option", status: 2) }
        await #expect(throws: (any Error).self) { try await ExpertTools.destinations(pids: [10], launch: failing) }
        let empty = FakeLsof()
        _ = try await ExpertTools.destinations(pids: [], launch: empty.launcher)
        #expect(empty.launches == 0)
    }

    @Test func longListsAreChunked() async throws {
        let fake = FakeLsof()
        _ = try await ExpertTools.destinations(pids: Array(1...450), launch: fake.launcher)
        #expect(fake.launches == 3)
        #expect(fake.lists.map(\.count) == [200, 200, 50])
        let exact = FakeLsof()
        _ = try await ExpertTools.destinations(pids: Array(1...200), launch: exact.launcher)
        #expect(exact.launches == 1)
    }

    @Test func parserAttributesRowsToTheRightProcess() {
        // Shape of real `lsof +c 0 -nP -iTCP -iUDP -FpcPfnT -a -p …` output, addresses replaced by documentation ones.
        let output = """
        p501
        cnode
        f21
        PTCP
        n192.0.2.1:50123->198.51.100.7:443
        TST=ESTABLISHED
        TQR=0
        TQS=0
        f22
        PTCP
        n[2001:db8::1]:50124->[2001:db8::2]:443
        TST=ESTABLISHED
        TQR=0
        TQS=0
        p502
        cgit-remote-https
        f5
        PUDP
        n*:5353
        f9
        PTCP
        n192.0.2.1:50200->203.0.113.9:22
        TST=CLOSE_WAIT
        TQR=0
        TQS=0
        p503
        cpython3
        f3
        PTCP
        n127.0.0.1:8080
        TST=LISTEN

        """
        let rows = ExpertTools.parseSockets(output)
        func ends(_ pid: Int32) -> Set<String> { Set(rows.filter { $0.pid == pid }.map(\.endpoint)) }
        #expect(ends(501) == ["192.0.2.1:50123->198.51.100.7:443", "[2001:db8::1]:50124->[2001:db8::2]:443"])
        #expect(ends(502) == ["*:5353", "192.0.2.1:50200->203.0.113.9:22"])
        #expect(ends(503) == ["127.0.0.1:8080"])
        #expect(rows.filter { $0.pid == 502 }.allSatisfy { $0.process == "git-remote-https" })
        #expect(rows.first { $0.endpoint.hasSuffix("203.0.113.9:22") }?.state == "CLOSE_WAIT")
    }
}
