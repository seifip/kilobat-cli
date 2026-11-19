import Foundation
import Testing
@testable import KilobatCore

struct UsageFileTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func row(_ at: TimeInterval, _ bytes: UInt64) -> UsageEntry {
        UsageEntry(date: Date(timeIntervalSinceReferenceDate: at), received: bytes, sent: 0, apps: [:], networkKey: "n")
    }

    @Test func appendedRowsReadBackAfterTheWholeFile() throws {
        let dir = try folder()
        try JSONEncoder().encode([row(100, 1)]).write(to: dir.appendingPathComponent(UsageFile.name))
        try UsageFile.append(row(200, 2), directory: dir)
        try UsageFile.append(row(300, 3), directory: dir)
        #expect(UsageFile.read(dir).map(\.received) == [1, 2, 3])
    }

    @Test func aTailWithoutAWholeFileStillReads() throws {
        let dir = try folder()
        try UsageFile.append(row(200, 2), directory: dir)
        #expect(UsageFile.read(dir).map(\.received) == [2])
    }

    @Test func rowsAlreadyInTheWholeFileAreNotCountedTwice() throws {
        let dir = try folder()
        try UsageFile.append(row(100, 1), directory: dir)
        try UsageFile.append(row(200, 2), directory: dir)
        // A crash after saving the whole file, before clearing the tail.
        try JSONEncoder().encode([row(100, 1), row(200, 2)]).write(to: dir.appendingPathComponent(UsageFile.name))
        try UsageFile.append(row(300, 3), directory: dir)
        #expect(UsageFile.read(dir).map(\.received) == [1, 2, 3])
    }

    @Test func aLineCutShortByACrashIsSkipped() throws {
        let dir = try folder()
        try UsageFile.append(row(200, 2), directory: dir)
        let handle = try FileHandle(forWritingTo: dir.appendingPathComponent(UsageFile.tail))
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"date\":3".utf8)); try handle.close()
        #expect(UsageFile.read(dir).map(\.received) == [2])
    }

    @Test func removingTheTailLeavesTheWholeFile() throws {
        let dir = try folder()
        try JSONEncoder().encode([row(100, 1)]).write(to: dir.appendingPathComponent(UsageFile.name))
        try UsageFile.append(row(200, 2), directory: dir)
        UsageFile.removeTail(directory: dir)
        #expect(UsageFile.read(dir).map(\.received) == [1])
    }
}
