import Foundation
import Testing
@testable import KilobatCore

@MainActor struct ReliabilityTests {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func legacyTruncatedProcessRulesStillApply() throws {
        #expect(ProcessRuleKey.keys("process:com.docker.backend") == ["process:com.docker.backend", "process:com.docker.back"])
        #expect(ProcessRuleKey.keys("process:curl") == ["process:curl"])
        #expect(ProcessRuleKey.keys("com.example.App") == ["com.example.App"])
        let rule = ConnectionRule(app: "process:com.docker.back", host: "example.com", allowed: false, profile: "Travel")
        #expect(rule.matches(app: "com.docker", process: "com.docker.backend", host: "example.com", address: nil, port: nil, direction: "outgoing"))

        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let store = TrafficStore(directory: path, startMonitoring: false)
        store.preferences.defaultAllow = false
        store.preferences.rules["Travel"] = ["process:com.docker.back": true]
        #expect(store.isAllowed("process:com.docker.backend"))
        store.setAllowed("process:com.docker.backend", false)
        #expect(!store.isAllowed("process:com.docker.backend"))
        #expect(store.removeRule("process:com.docker.backend"))
        #expect(store.preferences.rules["Travel"]?.isEmpty == true)
    }

    @Test func standardHostsFileImports() throws {
        let hosts = """
        ##
        127.0.0.1\tlocalhost
        255.255.255.255\tbroadcasthost
        ::1             localhost
        fe80::1%lo0     localhost
        127.0.0.1 local
        0.0.0.0 0.0.0.0
        0.0.0.0 ads.example.com # tracker
        """
        #expect(try DomainPolicy.parseList(Data(hosts.utf8)) == ["ads.example.com"])
        #expect(throws: (any Error).self) { try DomainPolicy.parseList(Data("127.0.0.1 localhost\n0.0.0.0 0.0.0.0".utf8)) }
    }

    @Test func meteredNetworkSwitchesOnceAndRestores() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let file = path.appendingPathComponent("preferences.json")
        let store = TrafficStore(directory: path, startMonitoring: false)
        store.preferences.profile = .work
        store.meteredChanged(false)
        store.meteredChanged(true)
        #expect(store.preferences.profile == .travel)
        store.preferences.profile = .unrestricted
        store.meteredChanged(true)
        #expect(store.preferences.profile == .unrestricted)
        store.meteredChanged(false)
        #expect(store.preferences.profile == .unrestricted)
        #expect(store.preferences.autoProfileFrom == nil)

        store.preferences.profile = .work
        store.meteredChanged(true)
        store.meteredChanged(false)
        #expect(store.preferences.profile == .work)
        let saved = try Data(contentsOf: file)
        store.meteredChanged(false)
        store.preferences = store.preferences
        #expect(try Data(contentsOf: file) == saved)

        let sampler = TrafficStore(directory: path, startMonitoring: false, recordHistory: false)
        sampler.meteredChanged(true)
        #expect(sampler.preferences.profile == .work)
        #expect(try Data(contentsOf: file) == saved)
    }

    @Test func unreadableFilesAreKeptAside() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        try Data("{not json".utf8).write(to: path.appendingPathComponent("preferences.json"))
        try Data("[{]".utf8).write(to: path.appendingPathComponent("events.json"))
        let store = TrafficStore(directory: path, startMonitoring: false)
        #expect(store.preferences == SavedPreferences())
        _ = NetworkJournal(directory: path)
        #expect(try Data(contentsOf: path.appendingPathComponent("preferences.json.corrupt")) == Data("{not json".utf8))
        #expect(FileManager.default.fileExists(atPath: path.appendingPathComponent("events.json.corrupt").path))
    }

    @Test func oldUsageCompactsIntoHourlyBuckets() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hour = calendar.dateInterval(of: .hour, for: now.addingTimeInterval(-3 * 86_400))!.start
        let old = (0..<120).map { UsageEntry(date: hour.addingTimeInterval(Double($0) * 30), received: 10, sent: 1, apps: ["curl": 11], networkKey: "home") }
        let other = UsageEntry(date: hour.addingTimeInterval(60), received: 5, sent: 0, apps: ["ssh": 5], networkKey: "cafe")
        let recent = UsageEntry(date: now.addingTimeInterval(-60), received: 7, sent: 7, apps: [:], networkKey: "home")
        let compacted = TrafficStore.compact(old + [other, recent], now: now, calendar: calendar)
        #expect(compacted.count == 3)
        let home = compacted.first { $0.networkKey == "home" && $0.date == hour }
        #expect(home?.received == 1200 && home?.sent == 120 && home?.apps["curl"] == 1320)
        #expect(compacted.last?.id == recent.id)
        #expect(Set(TrafficStore.compact(compacted, now: now, calendar: calendar).map(\.id)) == Set(compacted.map(\.id)))
        #expect(UsageSummary(compacted, days: 7, now: now, calendar: calendar).downloadBytes == 1212)
    }

    @Test func usageOlderThanAMonthCompactsIntoDays() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = calendar.startOfDay(for: now.addingTimeInterval(-60 * 86_400))
        let hours = (0..<24).map { UsageEntry(date: day.addingTimeInterval(Double($0) * 3600), received: 100, sent: 10, apps: ["curl": 110], networkKey: "home") }
        let compacted = TrafficStore.compact(hours, now: now, calendar: calendar)
        #expect(compacted.count == 1)
        #expect(compacted.first?.date == day && compacted.first?.received == 2400 && compacted.first?.apps["curl"] == 2640)
    }

    @Test func slowCheckIntervalsStillRecordOutages() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let journal = NetworkJournal(directory: path); journal.alerts = false
        let sample = DiagnosticSnapshot(date: Date(), radio: RadioSample(ssid: "Network", interface: "en0", rssi: -50, noise: -90, transmitMbps: 100, channel: 1, band: "2.4 GHz"), gateway: "192.168.1.1", router: nil, internet: PingResult(host: "1.1.1.1", samples: [], lossPercent: 100), dnsMilliseconds: 5, dnsServers: [], captivePortal: false, networkService: "Wi-Fi")
        let noReply = PingResult(host: "8.8.8.8", samples: [], lossPercent: 100)
        let start = Date()
        for i in 0..<3 { journal.ingest(sample, secondary: noReply, httpReachable: false, interval: 300, date: start.addingTimeInterval(Double(i) * 310)) }
        #expect(journal.events.count == 1)
    }

    @Test func reusedRequestIDsAllFinish() async {
        var replies = 0
        let slow = MCPTool(name: "slow", title: "Slow", description: "", annotations: MCPToolAnnotations(readOnly: true)) { arguments, _ in
            try await Task.sleep(for: .milliseconds(arguments["ms"] as? Int ?? 0)); return .text("done")
        }
        let server = MCPServer(name: "kilobat", title: "Kilobat", version: "1.0", instructions: "", tools: [slow]) { _ in replies += 1 }
        server.receive(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"slow","arguments":{"ms":150}}}"#.utf8))
        server.receive(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"slow","arguments":{"ms":1}}}"#.utf8))
        await server.drain()
        #expect(replies == 2)
    }

    @Test func cancelledTransferNeverStartsOnClosedSession() async {
        let transfer = SpeedTransfer()
        transfer.close()
        await #expect(throws: CancellationError.self) {
            try await transfer.request(URLRequest(url: URL(string: "https://speed.cloudflare.com/__down?bytes=1")!), body: nil) { _ in }
        }
    }
}
