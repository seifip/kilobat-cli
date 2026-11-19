import Foundation
import Testing
@testable import KilobatCore

@MainActor struct HealthSampleFileTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let reply = PingResult(host: "8.8.8.8", samples: [20], lossPercent: 0)
    private let noReply = PingResult(host: "8.8.8.8", samples: [], lossPercent: 100)

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func sample(_ date: Date, ssid: String = "Network", reachable: Bool = true) -> DiagnosticSnapshot {
        DiagnosticSnapshot(date: date, radio: RadioSample(ssid: ssid, interface: "en0", rssi: -50, noise: -90, transmitMbps: 100, channel: 1, band: "2.4 GHz"), gateway: "192.168.1.1", router: nil,
                           internet: reachable ? PingResult(host: "1.1.1.1", samples: [20], lossPercent: 0) : PingResult(host: "1.1.1.1", samples: [], lossPercent: 100),
                           dnsMilliseconds: 5, dnsServers: [], captivePortal: false, networkService: "Wi-Fi")
    }
    private func minute(_ n: Int) -> Date { start.addingTimeInterval(Double(n) * 60) }
    private func journal(_ dir: URL) -> NetworkJournal { let j = NetworkJournal(directory: dir); j.alerts = false; return j }
    private func ingest(_ j: NetworkJournal, _ date: Date, ssid: String = "Network") { j.ingest(sample(date, ssid: ssid), secondary: reply, httpReachable: nil, date: date) }
    private func bytes(_ dir: URL, _ name: String) -> Data? { try? Data(contentsOf: dir.appendingPathComponent(name)) }
    private func exists(_ dir: URL, _ name: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) }
    private func tailLines(_ dir: URL) -> Int { (bytes(dir, HealthSampleFile.tail) ?? Data()).split(separator: 0x0A).count }
    private func wholeFile(_ dir: URL) -> [DiagnosticSnapshot] { (bytes(dir, HealthSampleFile.name)).flatMap { try? JSONDecoder().decode([DiagnosticSnapshot].self, from: $0) } ?? [] }

    @Test func samplesReadBackAcrossWholeFileAndTail() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let j = journal(dir)
        for i in 0..<5 { ingest(j, minute(i)) }
        #expect(wholeFile(dir).count == 1)
        #expect(tailLines(dir) == 4)
        let reopened = journal(dir)
        #expect(reopened.samples.map(\.date) == (0..<5).map(minute))
    }

    @Test func aQuietCheckOnlyAppends() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let j = journal(dir)
        for i in 0..<3 { ingest(j, minute(i)) }
        let whole = bytes(dir, HealthSampleFile.name)
        let tailBefore = tailLines(dir)
        let eventsFile = bytes(dir, "events.json")
        ingest(j, minute(3))
        #expect(bytes(dir, HealthSampleFile.name) == whole)
        #expect(tailLines(dir) == tailBefore + 1)
        #expect(bytes(dir, "events.json") == eventsFile)
        // One check's write is one sample's JSON, not a megabyte.
        let line = try JSONEncoder().encode(j.samples.last!)
        #expect(line.count < 4096)
    }

    @Test func aQuietCheckWritesOneSampleNotTheWholeDay() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let j = journal(dir)
        // A full day, rewritten hourly: the whole file stays at its hourly size while the tail is at most 120 rows.
        for i in 0..<1440 { ingest(j, minute(i)) }
        let wholeSize = bytes(dir, HealthSampleFile.name)?.count ?? 0
        let tailSize = bytes(dir, HealthSampleFile.tail)?.count ?? 0
        let eventsFile = bytes(dir, "events.json")
        ingest(j, minute(1440))
        let wholeAfter = bytes(dir, HealthSampleFile.name)?.count ?? 0
        let tailAfter = bytes(dir, HealthSampleFile.tail)?.count ?? 0
        print("WRITES whole: \(wholeSize) -> \(wholeAfter), tail: \(tailSize) -> \(tailAfter), events unchanged: \(bytes(dir, "events.json") == eventsFile)")
        #expect(bytes(dir, "events.json") == eventsFile)
        // Either a plain append (tail grew by under 4 KB) or the hourly rewrite (tail gone); never both files every minute.
        #expect(tailAfter - tailSize < 4096)
        #expect(j.samples.count == 1440)
        #expect(journal(dir).samples.count == 1440)
    }

    @Test func unchangedEventsAreNotSavedAgain() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let j = journal(dir)
        ingest(j, minute(0)); ingest(j, minute(1))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("events.json"))
        ingest(j, minute(2))
        #expect(!exists(dir, "events.json"))
        for i in 3..<6 { j.ingest(sample(minute(i), reachable: false), secondary: noReply, httpReachable: false, date: minute(i)) }
        #expect(exists(dir, "events.json"))
        #expect(journal(dir).events.contains { $0.kind == "Unreachable" })
    }

    @Test func anHourLaterTheWholeFileIsRewrittenAndTheTailGoes() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let j = journal(dir)
        ingest(j, start); ingest(j, start.addingTimeInterval(60))
        #expect(exists(dir, HealthSampleFile.tail))
        ingest(j, start.addingTimeInterval(3660))
        #expect(wholeFile(dir).count == 3)
        #expect(!exists(dir, HealthSampleFile.tail))
    }

    @Test func aNewNetworkRewritesTheWholeFileAtOnce() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let j = journal(dir)
        ingest(j, minute(0), ssid: "A"); ingest(j, minute(1), ssid: "A")
        ingest(j, minute(2), ssid: "B")
        #expect(wholeFile(dir).last?.radio.ssid == "B")
        #expect(wholeFile(dir).count == 3)
        #expect(!exists(dir, HealthSampleFile.tail))
    }

    @Test func aCutShortTailLineIsSkipped() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        try HealthSampleFile.append(sample(minute(1)), directory: dir)
        let handle = try FileHandle(forWritingTo: dir.appendingPathComponent(HealthSampleFile.tail))
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"date\":3".utf8)); try handle.close()
        #expect(HealthSampleFile.read(dir).map(\.date) == [minute(1)])
    }

    @Test func rowsInBothFilesAreNotCountedTwice() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        try JSONEncoder().encode([sample(minute(0)), sample(minute(1))]).write(to: dir.appendingPathComponent(HealthSampleFile.name))
        for i in 0..<3 { try HealthSampleFile.append(sample(minute(i)), directory: dir) }
        #expect(HealthSampleFile.read(dir).map(\.date) == [minute(0), minute(1), minute(2)])
    }

    @Test func theDayCapHoldsAcrossBothFiles() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        try JSONEncoder().encode((0..<1440).map { sample(minute($0)) }).write(to: dir.appendingPathComponent(HealthSampleFile.name))
        for i in 1440..<1450 { try HealthSampleFile.append(sample(minute(i)), directory: dir) }
        let rows = HealthSampleFile.read(dir)
        #expect(rows.count == 1440)
        #expect(rows.last?.date == minute(1449))
        #expect(rows.first?.date == minute(10))
    }

    @Test func theDigestReadsTheTailToo() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let j = journal(dir)
        for i in 0..<4 { ingest(j, minute(i)) }
        #expect(tailLines(dir) == 3)
        #expect(DigestInput.saved(directory: dir).samples.count == j.samples.count)
    }

    @Test func aVisitingReaderLeavesAnUnreadableFileWhereItIs() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not json".utf8).write(to: dir.appendingPathComponent(HealthSampleFile.name))
        try HealthSampleFile.append(sample(minute(1)), directory: dir)
        #expect(HealthSampleFile.read(dir, quarantine: false).count == 1)
        #expect(exists(dir, HealthSampleFile.name))
        #expect(!exists(dir, HealthSampleFile.name + ".corrupt"))
    }
}
