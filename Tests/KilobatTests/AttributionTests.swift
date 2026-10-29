import Foundation
import Testing
@testable import KilobatCore

/// Per-process attribution, Internet vs local traffic, interface totals and the services that download for other apps.
@MainActor struct AttributionTests {
    private func store(counters: (() -> [String: ByteCount]?)? = nil, starts: [Int32: Date] = [:]) -> (TrafficStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = TrafficStore(directory: directory, startMonitoring: false)
        store.readCounters = counters
        store.startTime = { starts[$0] }
        return (store, directory)
    }
    private func connection(_ id: String, _ interface: String, _ received: UInt64, _ sent: UInt64 = 0) -> ConnectionTraffic {
        let parts = id.split(separator: "|")
        return ConnectionTraffic(id: String(parts[0]), route: TrafficRoute.classify(parts[0], interface: Substring(interface)), interface: interface, received: received, sent: sent)
    }

    @Test func connectionsAreInternetLocalOrTunnel() {
        let cases: [(String, String, TrafficRoute)] = [
            ("tcp4 192.168.1.20:5000<->17.1.2.3:443", "en0", .internet),
            ("tcp4 192.168.1.20:5000<->192.168.1.30:445", "en0", .local),
            ("tcp4 10.0.0.2:5000<->172.16.4.1:22", "en0", .local),
            ("tcp4 10.0.0.2:5000<->172.32.4.1:443", "en0", .internet),
            // A hotspot's resolver forwards DNS to the Internet.
            ("udp4 172.20.10.2:5000<->172.20.10.1:53", "en0", .internet),
            ("udp4 192.168.1.20:5000<->169.254.10.1:80", "en0", .local),
            ("udp4 *:5353<->*:*", "en0", .local),
            ("udp6 *.5353<->*.*", "en0", .local),
            ("udp4 *:61000<->*:*", "en0", .internet),
            ("udp6 fe80::e88c:60ff:fe81:8e08%awdl0.65253<->fe80::9488:cfff:fefa:5578%awdl0.50123", "awdl0", .local),
            ("udp6 fe80::1%llw0.5000<->fe80::2%llw0.6000", "llw0", .local),
            ("tcp6 fd00::2.5000<->fd00::1.8080", "en0", .local),
            ("tcp6 2001:db8::2.5000<->2606:4700::1111.443", "en0", .internet),
            ("tcp4 192.168.1.20:5000<->::ffff:192.168.1.9:80", "en0", .local),
            ("tcp4 10.8.0.2:5000<->1.1.1.1:443", "utun4", .tunnel),
            // A company network behind a VPN still travels over the Internet.
            ("tcp4 10.8.0.2:5000<->10.0.0.5:22", "utun4", .tunnel),
            ("tcp4 10.8.0.2:5000<->10.0.0.5:22", "ipsec0", .tunnel),
            ("udp4 224.0.0.251:5353<->224.0.0.251:5353", "utun4", .local)
        ]
        for (row, interface, expected) in cases {
            #expect(TrafficRoute.classify(Substring(row), interface: Substring(interface)) == expected, "\(row) on \(interface)")
        }
        #expect(TrafficRoute.isPrivate("100.64.1.1") == false && TrafficRoute.isPrivate("192.168.0.1") && TrafficRoute.isLinkLocalOrLoopback("ff02::fb"))
    }

    @Test func connectionRowsBelongToTheirProcess() {
        var rows: [ProcessTraffic] = []
        for line in ["sharingd.730,,19389,16460,", "udp6 fe80::1%awdl0.65253<->fe80::2%awdl0.50123,awdl0,6752,5962,",
                     "Browser Helper.774,,1000,500,", "tcp4 192.168.1.1:61511<->172.64.148.10:443,en0,900,400,", "tcp4 192.168.1.1:61512<->192.168.1.7:8080,en0,100,100,"] {
            NettopMonitor.parse(line, into: &rows)
        }
        #expect(rows.map(\.pid) == [730, 774] && rows[1].process == "Browser Helper")
        #expect(rows[0].connections.map(\.route) == [.local] && rows[1].connections.map(\.route) == [.internet, .local])
        #expect(rows[1].connections[0].interface == "en0")
    }

    @Test func budgetsAndQuotasCountOnlyInternetBytes() throws {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date()
        func sample(_ at: Double, internet: UInt64, local: UInt64) -> TrafficSnapshot {
            TrafficSnapshot(timestamp: start.addingTimeInterval(at), processes: [ProcessTraffic(pid: 123456, process: "sync", received: internet + local, sent: 0, connections: [
                connection("tcp4 192.168.1.20:5000<->17.1.2.3:443", "en0", internet), connection("tcp4 192.168.1.20:5001<->192.168.1.30:445", "en0", local)])])
        }
        store.consume(sample(0, internet: 1_000, local: 1_000))
        store.consume(sample(1, internet: 4_000, local: 9_000))
        #expect(store.total == 3_000 && store.local == 8_000)
        #expect(store.apps.first?.total == 11_000 && store.apps.first?.internet == 3_000 && store.apps.first?.local == 8_000)
        // Local bytes still show as activity.
        #expect(store.download == 11_000)
        store.preferences.quotas = [AppQuota(name: "sync", apps: ["process:sync"], bytes: 5_000)]
        store.flush()
        let entry = try #require(store.usage.last)
        #expect(entry.total == 3_000 && entry.apps["sync"] == 3_000 && entry.localBytes == 8_000 && entry.appsLocal?["sync"] == 8_000)
        #expect(store.budgetUsedBytes == 3_000 && store.quotaUsed(store.preferences.quotas![0]) == 3_000 && store.quotaReached.isEmpty)
        #expect(UsageSummary(store.usage, days: 1).topApps.first?.bytes == 3_000 && UsageSummary(store.usage, days: 1).localBytes == 8_000)
    }

    @Test func historyFromBeforeLocalSplitStillLoads() throws {
        let old = #"[{"id":"6B1C4C6E-0E8B-4C55-9A1B-6F0E1D3C2B10","date":700000000,"received":10,"sent":5,"apps":{"Safari":15},"networkKey":"home"}]"#
        let entries = try JSONDecoder().decode([UsageEntry].self, from: Data(old.utf8))
        #expect(entries[0].localBytes == nil && entries[0].appsLocal == nil && entries[0].unattributed == nil && entries[0].total == 15)
        let session = try JSONDecoder().decode([String: NetworkSession].self, from: Data(#"{"home":{"name":"Home","received":1,"sent":2}}"#.utf8))
        #expect(session["home"]?.local == nil)
        // Merging old and new entries keeps what was recorded and leaves what wasn't missing.
        let date = Date().addingTimeInterval(-3 * 86_400)
        var new = UsageEntry(date: date.addingTimeInterval(60), received: 1, sent: 1, apps: ["Safari": 2], networkKey: "home")
        new.localBytes = 7; new.appsLocal = ["Safari": 7]
        let merged = TrafficStore.compact([UsageEntry(date: date, received: 1, sent: 1, apps: ["Safari": 2], networkKey: "home"), new])
        #expect(merged.count == 1 && merged[0].localBytes == 7 && merged[0].appsLocal?["Safari"] == 7 && merged[0].unattributed == nil)
        let untouched = TrafficStore.compact([UsageEntry(date: date, received: 1, sent: 1, apps: [:], networkKey: "home"), UsageEntry(date: date.addingTimeInterval(9), received: 1, sent: 1, apps: [:], networkKey: "home")])
        #expect(untouched[0].localBytes == nil)
    }

    @Test func interfaceCountersGiveTheMacTotalAndUnattributedBytes() {
        var en0 = ByteCount(received: 1_000_000, sent: 1_000_000), awdl = ByteCount(received: 0, sent: 0)
        var failing = false
        let (store, directory) = store(counters: { MainActor.assumeIsolated { failing ? nil : ["en0": en0, "awdl0": awdl, "utun3": awdl] } })
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date()
        var cumulative = ByteCount(), lan: UInt64 = 0, at = 0.0
        func step(internet: UInt64, local: UInt64 = 0, link: UInt64, peer: UInt64 = 0) {
            cumulative.received += internet + local; lan += local
            en0.received += link; awdl.received += peer; at += 1
            store.consume(TrafficSnapshot(timestamp: start.addingTimeInterval(at), processes: [ProcessTraffic(pid: 123456, process: "sync", received: cumulative.received, sent: 0, connections: [
                connection("tcp4 192.168.1.20:5001<->192.168.1.30:445", "en0", lan)])]))
        }
        step(internet: 0, link: 0)
        // 300 to the Internet and 200 to the LAN from the app; the interface also carried 500 no process accounts for. AirDrop isn't counted.
        step(internet: 300, local: 200, link: 1_000, peer: 50_000)
        #expect(store.total == 800 && store.local == 200 && store.unattributedBytes == 500 && store.countsInterfaces)
        // Less on the interface than the processes claim never makes unattributed negative.
        step(internet: 1_000, link: 100)
        #expect(store.unattributedBytes == 0 && store.total == 900)
        // A reset counter starts over instead of counting backwards, and an impossible jump is dropped.
        en0 = ByteCount(); step(internet: 0, link: 0)
        step(internet: 0, link: 400)
        #expect(store.total == 1_300)
        step(internet: 0, link: 50_000_000_000_000)
        #expect(store.total == 1_300)
        // A missed reading is caught up by the next.
        failing = true; step(internet: 0, link: 700)
        #expect(store.total == 1_300 && store.countsInterfaces)
        failing = false; step(internet: 0, link: 0)
        #expect(store.total == 2_000)
        // After a wake the first sample only sets baselines, for processes and interfaces.
        store.rebaseline(); step(internet: 9_000, link: 9_000)
        #expect(store.total == 2_000 && store.apps.first.map { $0.total } == 1_500)
        step(internet: 100, link: 100)
        #expect(store.total == 2_100)
        // Counters gone for good: what processes account for stands in.
        failing = true
        for _ in 0..<5 { step(internet: 10, link: 10) }
        #expect(!store.countsInterfaces && store.total == 2_110)
    }

    @Test func shortLivedAndReusedProcesses() {
        let start = Date()
        var starts: [Int32: Date] = [70: start.addingTimeInterval(-3_600), 71: start.addingTimeInterval(-3_600)]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrafficStore(directory: directory, startMonitoring: false)
        store.startTime = { pid in MainActor.assumeIsolated { starts[pid] } }
        store.consume(TrafficSnapshot(timestamp: start, processes: [ProcessTraffic(pid: 70, process: "app", received: 5_000, sent: 0)]))
        // 71 ran long before monitoring: its first sighting only sets a baseline. 72 started after the last sample: all of it is new.
        starts[72] = start.addingTimeInterval(0.5)
        store.consume(TrafficSnapshot(timestamp: start.addingTimeInterval(1), processes: [
            ProcessTraffic(pid: 70, process: "app", received: 5_100, sent: 0), ProcessTraffic(pid: 71, process: "daemon", received: 90_000, sent: 0),
            ProcessTraffic(pid: 72, process: "curl", received: 2_000, sent: 30)]))
        #expect(store.total == 2_130)
        // 72 has exited (no start time) but still shows: counted from where it was. Then its pid comes back as another process.
        starts[72] = nil
        store.consume(TrafficSnapshot(timestamp: start.addingTimeInterval(2), processes: [ProcessTraffic(pid: 72, process: "curl", received: 2_500, sent: 30)]))
        #expect(store.total == 2_630)
        starts[72] = start.addingTimeInterval(2.5)
        store.consume(TrafficSnapshot(timestamp: start.addingTimeInterval(3), processes: [ProcessTraffic(pid: 72, process: "curl", received: 400, sent: 0)]))
        #expect(store.total == 3_030)
        // The same pid with an earlier start than the last sample and another name is a baseline, not a spike.
        starts[72] = start.addingTimeInterval(-10)
        store.consume(TrafficSnapshot(timestamp: start.addingTimeInterval(4), processes: [ProcessTraffic(pid: 72, process: "python3", received: 999_999, sent: 0)]))
        #expect(store.total == 3_030)
    }

    @Test func runsCountOnlyTheirOwnHelpers() {
        let processes = FakeProcesses()
        // Two Claude Code sessions (800, 900) each run curl (801, 901); another curl (999) belongs to neither.
        processes.children = [800: [801], 900: [901]]; processes.alive = [800, 801, 900, 901, 999]
        let defaults = UserDefaults(suiteName: "co.seifi.kilobat.tests." + UUID().uuidString)!
        defaults.register(defaults: ["awake.agents": false, "awake.notify": false, "awake.quietMinutes": 3, "awake.webhook": ""])
        let sessions = SessionStore(directory: nil, defaults: defaults)
        sessions.probe = processes.probe
        let start = Date()
        sessions.receive(AgentEvent(kind: .working, agent: "claude", session: "a", pid: 800, time: start))
        sessions.receive(AgentEvent(kind: .working, agent: "claude", session: "b", pid: 900, time: start))
        let claude = AppTraffic(id: "process:claude", name: "claude", processIDs: [800, 900])
        var curl = AppTraffic(id: "process:curl", name: "curl", processIDs: [801, 901, 999], downloadRate: 1_400_000)
        curl.rates = [801: ProcessRate(down: 100_000, up: 0), 901: ProcessRate(down: 300_000, up: 0), 999: ProcessRate(down: 1_000_000, up: 0)]
        sessions.tick(apps: [claude, curl], interval: 2, now: start + 2)
        let a = sessions.agents["Claude Code|a"], b = sessions.agents["Claude Code|b"]
        #expect(a?.apps["curl"] == 200_000 && b?.apps["curl"] == 600_000)
        #expect(a?.sharedTraffic != true && b?.sharedTraffic != true)
    }

    @Test func onlyKeepsTheChosenProcesses() {
        var app = AppTraffic(id: "process:node", name: "node", processIDs: [1, 2], received: 1_000, sent: 200, downloadRate: 40, uploadRate: 4)
        app.rates = [1: ProcessRate(down: 30, up: 1), 2: ProcessRate(down: 10, up: 3)]
        let one = app.only([2])
        #expect(one.processIDs == [2] && one.downloadRate == 10 && one.uploadRate == 3 && one.received == 500)
        #expect(app.only([1, 2, 3]).downloadRate == 40)
        // Without per-process rates, processes share equally.
        let even = AppTraffic(id: "process:node", name: "node", processIDs: [1, 2], downloadRate: 40).only([1])
        #expect(even.downloadRate == 20)
    }

    @Test func systemDownloadsShowWhoTheyAreFor() throws {
        let now = Date()
        let flows = [DelegatedFlows(process: "com.apple.nsurlsessiond", app: "com.apple.Music", allowed: 3, last: now.addingTimeInterval(-60)),
                     DelegatedFlows(process: "com.apple.nsurlsessiond", app: "com.apple.Podcasts", allowed: 1, last: now),
                     DelegatedFlows(process: "com.apple.mobileassetd", app: "com.apple.Music", blocked: 1, last: now),
                     DelegatedFlows(process: "com.example.helper", app: "com.example.App", allowed: 1, last: now)]
        let apps = SystemDownloads.apps(flows)
        #expect(apps["nsurlsessiond"] == ["com.apple.Podcasts", "com.apple.Music"] && apps["mobileassetd"] == ["com.apple.Music"] && apps.count == 2)
        let services = [AppTraffic(id: "process:nsurlsessiond", name: "nsurlsessiond"), AppTraffic(id: "process:softwareupdated", name: "softwareupdated"),
                        AppTraffic(id: "com.apple.Safari", name: "Safari")]
        #expect(SystemDownloads.service(for: services[0])?.process == "nsurlsessiond" && SystemDownloads.service(for: services[2]) == nil)
        let groups = AppTrafficGroup.make(services, grouped: true)
        #expect(groups.first { $0.id == AppTrafficGroup.systemDownloads }?.members.count == 2 && groups.first { $0.id == AppTrafficGroup.systemDownloads }?.summary.name == "System downloads")
        #expect(AppTrafficGroup.make(services, grouped: false).count == 3)
        // Blocked events from before the filter recorded the delegating service still decode.
        let event = try JSONDecoder().decode(FilterEvent.self, from: Data(#"{"id":"6B1C4C6E-0E8B-4C55-9A1B-6F0E1D3C2B10","date":700000000,"app":"com.apple.Music","endpoint":"x","direction":"outgoing","reason":"r"}"#.utf8))
        #expect(event.via == nil)
        let encoded = try JSONEncoder().encode(FilterEvent(app: "com.apple.Music", endpoint: "x", direction: "outgoing", reason: "r", via: "com.apple.nsurlsessiond"))
        #expect(try JSONDecoder().decode(FilterEvent.self, from: encoded).via == "com.apple.nsurlsessiond")
    }

    @Test func unrecognizedToolsAreTheOnesOutsideAppsAndMacOS() {
        for path in ["/opt/homebrew/bin/node", "/Users/me/.local/bin/deno", "/Users/me/.bun/bin/bun", "/usr/local/bin/python3", "/Users/me/go/bin/agent", "/tmp/x"] {
            #expect(CommandLineTools.unrecognized(path), "\(path)")
        }
        for path in ["/usr/bin/curl", "/usr/libexec/nsurlsessiond", "/System/Library/CoreServices/x", "/Applications/Foo.app/Contents/MacOS/Foo",
                     "/Users/me/Applications/Bar.app/Contents/Helpers/bar", "/Library/Developer/CommandLineTools/usr/bin/git", "relative"] {
            #expect(!CommandLineTools.unrecognized(path), "\(path)")
        }
    }
}
