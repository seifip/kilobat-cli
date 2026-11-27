import Foundation
import Testing
@testable import KilobatCore

@MainActor struct SweepCLITests {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The MCP setters load preferences, await the app, then save: a store loaded before another one saved has to
    /// reload before its own change, or it writes the older copy back.
    @Test func reloadingBeforeAChangeKeepsAnotherStoresSave() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let first = TrafficStore(directory: path, startMonitoring: false, recordHistory: false)
        let second = TrafficStore(directory: path, startMonitoring: false, recordHistory: false)
        first.preferences.blockedHosts = ["a.example"]
        second.reloadPreferences()
        second.preferences.allowApple = true
        let after = TrafficStore(directory: path, startMonitoring: false, recordHistory: false)
        #expect(after.preferences.blockedHosts == ["a.example"])
        #expect(after.preferences.allowApple == true)
    }
}
