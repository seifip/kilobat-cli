import Foundation
import Testing
@testable import KilobatCore

struct TrafficTests {
    @Test func testProcessNamesWithDotsAndSpacesParse() {
        let row = NettopMonitor.parseRow("Example App Helper.1234,1024,256,")
        #expect(row?.pid == 1234)
        #expect(row?.process == "Example App Helper")
        #expect(row?.total == 1280)
        #expect(NettopMonitor.parseRow("python3.12.456,8,9,")?.process == "python3.12")
        #expect(NettopMonitor.parseRow(",bytes_in,bytes_out,") == nil)
        #expect(NettopMonitor.parseRow("broken,abc,123,") == nil)
    }

    @Test @MainActor func testRulesTargetAnotherProfileAndCanBeRemoved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrafficStore(directory: directory, startMonitoring: false)
        store.preferences.profile = .work
        store.setAllowed("com.example.App", true, in: .travel)
        store.setTemporary("com.example.App", allowed: false, minutes: 5, in: .travel)
        #expect(store.preferences.rules["Travel"]?["com.example.App"] == true)
        #expect(store.preferences.rules["Work"]?["com.example.App"] == nil)
        #expect(store.preferences.temporaryRules?["Travel|com.example.App"]?.allowed == false)
        #expect(store.removeRule("com.example.App", in: .travel))
        #expect(store.preferences.rules["Travel"]?["com.example.App"] == nil)
        #expect(store.preferences.temporaryRules?["Travel|com.example.App"] == nil)
        #expect(!store.removeRule("com.example.App", in: .travel))
    }

    @Test @MainActor func testLifetimeTrafficIsNotCountedAndRatesUseElapsedTime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrafficStore(directory: directory, startMonitoring: false)
        let start = Date()
        store.consume(TrafficSnapshot(timestamp: start, processes: [ProcessTraffic(pid: 123456, process: "example", received: 1_000_000, sent: 500_000)]))
        #expect(store.total == 0)
        store.consume(TrafficSnapshot(timestamp: start.addingTimeInterval(2), processes: [ProcessTraffic(pid: 123456, process: "example", received: 1_000_400, sent: 500_100)]))
        #expect(store.total == 500)
        #expect(store.download == 200)
        #expect(store.upload == 50)
        store.flush()
        #expect(store.usage.last?.total == 500)
    }

    @Test @MainActor func testNewAndReusedPIDsAndResetCountersNeverSpike() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrafficStore(directory: directory, startMonitoring: false)
        let start = Date()
        let samples: [[ProcessTraffic]] = [
            [ProcessTraffic(pid: 123456, process: "first", received: 2000, sent: 2000)],
            [ProcessTraffic(pid: 123456, process: "first", received: 100, sent: 100), ProcessTraffic(pid: 123457, process: "new", received: 999999, sent: 999999)],
            [ProcessTraffic(pid: 123456, process: "different", received: 99999999, sent: 99999999)]
        ]
        for (index, rows) in samples.enumerated() { store.consume(TrafficSnapshot(timestamp: start.addingTimeInterval(Double(index)), processes: rows)) }
        #expect(store.total == 0)
        #expect(store.download == 0)
    }

    @Test @MainActor func testProfileRulesAreIsolatedAndSharedAcrossInstances() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ui = TrafficStore(directory: directory, startMonitoring: false)
        ui.setAllowed("com.example.App", true)
        let cli = TrafficStore(directory: directory, startMonitoring: false)
        #expect(cli.isAllowed("com.example.App"))
        cli.preferences.profile = .work
        #expect(!cli.isAllowed("com.example.App"))
        ui.reloadPreferences()
        #expect(ui.preferences.profile == .work)
        ui.preferences.profile = .travel
        #expect(ui.isAllowed("com.example.App"))
        ui.preferences.profile = .unrestricted
        #expect(ui.isAllowed("anything"))
    }

    @Test @MainActor func testCLIMonitorDoesNotWriteDuplicateHistory() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrafficStore(directory: directory, startMonitoring: false, recordHistory: false)
        let start = Date()
        store.consume(TrafficSnapshot(timestamp: start, processes: [ProcessTraffic(pid: 123456, process: "test", received: 0, sent: 0)]))
        store.consume(TrafficSnapshot(timestamp: start.addingTimeInterval(1), processes: [ProcessTraffic(pid: 123456, process: "test", received: 100, sent: 0)]))
        store.flush()
        #expect(store.total == 100)
        #expect(store.usage.isEmpty)
    }

    @Test func ratesInBitsUseOneNotation() {
        let en = Locale(identifier: "en_US")
        #expect(TrafficFormat.bitRate(0, locale: en) == "0 bps")
        #expect(TrafficFormat.bitRate(80, locale: en) == "640 bps")
        #expect(TrafficFormat.bitRate(106_250, locale: en) == "850 kbps")
        #expect(TrafficFormat.bitRate(400_000, locale: en) == "3.2 Mbps")
        #expect(TrafficFormat.bitRate(156_250_000, locale: en) == "1.25 Gbps")
        #expect(TrafficFormat.bitRate(124_990, locale: en) == "1.0 Mbps", "999.92 kbps rounds up a unit, never shows 1,000 kbps")
        #expect(TrafficFormat.bitRate(400_000, locale: Locale(identifier: "de_DE")) == "3,2 Mbps")
        #expect(TrafficFormat.bitRate(.infinity) == "—")
        #expect(TrafficFormat.bitRate(.nan) == "—")
        #expect(TrafficFormat.bitRate(-1) == "—")
        // The popover splits the number from the unit at the first space.
        #expect(TrafficFormat.bitRate(400_000, locale: en).split(separator: " ").count == 2)
    }

    @Test func theSettingChoosesBitsOrBytes() {
        let suite = "kilobat-test-bits-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(TrafficFormat.shownRate(400_000, defaults: defaults) == TrafficFormat.rate(400_000), "bytes until the person asks for bits")
        defaults.set(true, forKey: TrafficFormat.bitsKey)
        #expect(TrafficFormat.shownRate(400_000, defaults: defaults) == TrafficFormat.bitRate(400_000))
        #expect(TrafficFormat.bitsKey == "menu.bits", "the app, the CLI and existing installs share this key")
    }

    @Test func menuBarRatesAreWholeNumbers() {
        #expect(TrafficFormat.compactRate(3_000_000, bits: false) == "3 MB/s")
        #expect(TrafficFormat.compactRate(3_000_000, bits: true) == "24 Mbps")
        #expect(TrafficFormat.compactRate(100, bits: true) == "800 bps")
        #expect(TrafficFormat.compactRate(100_000, bits: true) == "800 kbps")
        #expect(TrafficFormat.compactRate(500, bits: false) == "500 B/s")
        #expect(TrafficFormat.compactRate(.nan, bits: true) == "—")
    }
}

struct ProcessOwnershipTests {
    @Test func nestedHelpersBelongToOuterApp() {
        #expect(ProcessOwnership.outerApplication(in: "/Applications/Example.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper") == "/Applications/Example.app")
        #expect(ProcessOwnership.outerApplication(in: "/Applications/Example.app/Contents/Resources/bin/worker") == "/Applications/Example.app")
        #expect(ProcessOwnership.outerApplication(in: "/opt/homebrew/bin/node") == nil)
        #expect(ProcessOwnership.outerApplication(in: "/tmp/example.application/bin/worker") == nil)
    }
    @Test func invalidProcessesHaveNoOwner() {
        #expect(ProcessOwnership.applicationPath(pid: 0) == nil)
        #expect(ProcessOwnership.applicationPath(pid: 1) == nil)
        #expect(ProcessOwnership.applicationPath(pid: -1) == nil)
    }
}

struct AppTrafficGroupTests {
    @Test func combinesTrafficWithoutLosingMembersOrRules() {
        var a = AppTraffic(id: "helper-a", name: "Worker A", bundlePath: nil)
        a.ownerPath = "/Applications/Example.app"; a.received = 200; a.sent = 30; a.downloadRate = 5; a.uploadRate = 3; a.processIDs = [10]
        var b = AppTraffic(id: "helper-b", name: "Worker B", bundlePath: nil)
        b.ownerPath = a.ownerPath; b.received = 400; b.sent = 70; b.downloadRate = 15; b.uploadRate = 7; b.processIDs = [11]
        let groups = AppTrafficGroup.make([a, b], grouped: true)
        #expect(groups.count == 1)
        #expect(groups[0].summary.total == 700)
        #expect(groups[0].summary.downloadRate == 20)
        #expect(groups[0].summary.uploadRate == 10)
        #expect(groups[0].summary.processIDs == [10, 11])
        #expect(Set(groups[0].members.map(\.id)) == ["helper-a", "helper-b"])
        #expect(AppTrafficGroup.make([a, b], grouped: false).count == 2)
    }
    @Test func distinctOwnersAndUnknownProcessesStaySeparate() {
        var a = AppTraffic(id: "a", name: "Worker", bundlePath: nil)
        a.ownerPath = "/Applications/One/Example.app"
        var b = AppTraffic(id: "b", name: "Worker", bundlePath: nil)
        b.ownerPath = "/Applications/Two/Example.app"
        let c = AppTraffic(id: "c", name: "Standalone", bundlePath: nil)
        #expect(AppTrafficGroup.make([a, b, c], grouped: true).count == 3)
    }
    @Test func commandLineAgentsGoByTheirProductName() {
        var cli = AppTraffic(id: "claude", name: "claude", bundlePath: "/Users/me/.local/share/claude/versions/2.1.3")
        cli.processIDs = [20, 21]
        let groups = AppTrafficGroup.make([cli, AppTraffic(id: "curl", name: "curl", bundlePath: nil)], grouped: true)
        #expect(groups.first { $0.id == "claude" }?.summary.name == "Claude Code")
        #expect(groups.first { $0.id == "curl" }?.summary.name == "curl")
    }
    @Test func interfaceReadingsPreferTheWideCounters() {
        let narrow = ByteCount(received: 1_705_032_704, sent: 5)
        let wide = ExpertTools.reading(name: "en0", up: true, narrow: narrow, wide: ["en0": ByteCount(received: 6_000_000_000, sent: 7_000_000_000)])
        #expect(wide.received == 6_000_000_000 && wide.sent == 7_000_000_000)
        let none = ExpertTools.reading(name: "en0", up: true, narrow: narrow, wide: nil)
        #expect(none.received == 1_705_032_704 && none.sent == 5)
        let missing = ExpertTools.reading(name: "en0", up: true, narrow: narrow, wide: ["en1": ByteCount(received: 1, sent: 1)])
        #expect(missing.received == 1_705_032_704 && missing.sent == 5)
    }
}
