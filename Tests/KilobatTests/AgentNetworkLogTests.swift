import Foundation
import Testing
@testable import KilobatCore

/// A made-up process table the tests change between polls: who is whose parent, names, paths and arguments.
final class FakeTable: @unchecked Sendable {
    struct Process { var ppid: Int32; var name: String; var path: String?; var arguments: [String]?; var start: Date; var cwd: String? }
    private let lock = NSLock()
    private var processes: [Int32: Process] = [:]
    let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func add(_ pid: Int32, parent: Int32, _ name: String, path: String? = nil, arguments: [String]? = nil, startedAt offset: TimeInterval = 0, cwd: String? = nil) {
        lock.withLock { processes[pid] = Process(ppid: parent, name: name, path: path, arguments: arguments, start: origin + offset, cwd: cwd) }
    }
    func exit(_ pid: Int32) { lock.withLock { processes[pid] = nil } }
    func reparent(_ pid: Int32, to parent: Int32) { lock.withLock { processes[pid]?.ppid = parent } }

    var source: ProcessSource {
        ProcessSource(all: { self.lock.withLock { Array(self.processes.keys) } },
                      entry: { pid in self.lock.withLock { self.processes[pid].map { ProcessEntry(pid: pid, ppid: $0.ppid, name: $0.name, start: $0.start) } } },
                      children: { pid in self.lock.withLock { self.processes.filter { $0.value.ppid == pid }.map(\.key) } },
                      path: { pid in self.lock.withLock { self.processes[pid]?.path } },
                      arguments: { pid in self.lock.withLock { self.processes[pid]?.arguments } },
                      cwd: { pid in self.lock.withLock { self.processes[pid]?.cwd } })
    }
}

struct AgentIdentificationTests {
    @Test func commandLineAgentsByExecutableScriptOrPackage() {
        #expect(AgentIdentifier.identify(path: "/opt/homebrew/bin/claude", name: "claude")?.name == "Claude Code")
        // The native installer names the binary after its version.
        #expect(AgentIdentifier.identify(path: "/Users/me/.local/share/claude/versions/2.1.223", name: "2.1.223", arguments: ["claude"])?.id == "claude")
        #expect(AgentIdentifier.identify(path: "/usr/local/bin/node", name: "node", arguments: ["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"])?.id == "claude")
        #expect(AgentIdentifier.identify(path: "/opt/homebrew/bin/node", name: "node", arguments: ["node", "--no-warnings", "/opt/homebrew/bin/gemini"])?.name == "Gemini CLI")
        #expect(AgentIdentifier.identify(path: "/usr/bin/python3", name: "python3.12", arguments: ["python3", "-m", "aider", "--model", "x"])?.id == "aider")
        #expect(AgentIdentifier.identify(path: "/Users/me/.local/bin/python3.12", name: "python3.12", arguments: ["python3.12", "/Users/me/.local/bin/aider"])?.id == "aider")
        // Codex inside the ChatGPT app is Codex, not ChatGPT.
        #expect(AgentIdentifier.identify(path: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", name: "codex")?.id == "codex")
        #expect(AgentIdentifier.identify(path: "/opt/homebrew/bin/cursor-agent", name: "cursor-agent")?.name == "Cursor Agent")
    }

    @Test func desktopAppsByTheirMainExecutableOnly() {
        #expect(AgentIdentifier.identify(path: "/Applications/Cursor.app/Contents/MacOS/Cursor", name: "Cursor")?.app == true)
        #expect(AgentIdentifier.identify(path: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)", name: "Cursor Helper (Plugin)") == nil)
        #expect(AgentIdentifier.identify(path: "/Applications/Claude.app/Contents/MacOS/Claude", name: "Claude")?.id == "claude-desktop")
        // Claude Code bundled in the Claude app is Claude Code.
        #expect(AgentIdentifier.identify(path: "/Users/me/Library/Application Support/Claude/claude-code/2.1.3/abc/claude.app/Contents/MacOS/claude", name: "claude")?.id == "claude")
        #expect(AgentIdentifier.identify(path: "/Applications/Windsurf.app/Contents/MacOS/Windsurf", name: "Windsurf")?.name == "Windsurf")
    }

    @Test func notAgents() {
        #expect(AgentIdentifier.identify(path: "/usr/local/bin/node", name: "node", arguments: ["node", "server.js"]) == nil)
        #expect(AgentIdentifier.identify(path: "/usr/local/bin/node", name: "node", arguments: ["node", "/Users/me/claude.js"]) == nil)
        #expect(AgentIdentifier.identify(path: "/usr/bin/curl", name: "curl", arguments: ["curl", "https://claude.ai"]) == nil)
        // A browser's native messaging host runs the Claude Code binary, but isn't an agent run.
        #expect(AgentIdentifier.identify(path: "/Users/me/.local/share/claude/versions/2.1.223", name: "2.1.223", arguments: ["/Users/me/.local/share/claude/versions/2.1.223", "--chrome-native-host"]) == nil)
        #expect(AgentIdentifier.identify(path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", name: "Electron") == nil)
    }

    @Test func argumentsFromKernelLayout() {
        var bytes = withUnsafeBytes(of: Int32(3)) { Array($0) }
        bytes += Array("/usr/local/bin/node".utf8) + [0, 0, 0] + Array("node".utf8) + [0] + Array("cli.js".utf8) + [0] + Array("--yes".utf8) + [0] + Array("HOME=/x".utf8) + [0]
        #expect(ProcessArguments.parse(bytes) == ["node", "cli.js", "--yes"])
    }

    @Test func hostsInArgumentsKeepOnlyTheHost() {
        #expect(AgentHostRules.hosts(inArguments: ["curl", "-fsSL", "https://user:token@bun.sh/install?x=1"]) == ["bun.sh"])
        #expect(AgentHostRules.hosts(inArguments: ["git-remote-https", "origin", "https://github.com/owner/repo.git"]) == ["github.com"])
        #expect(AgentHostRules.hosts(inArguments: ["curl", "http://10.0.0.1:8080/x", "https://[::1]/", "file:///etc/hosts"]).isEmpty)
    }
}

struct AgentProcessTreeTests {
    /// Claude Code under a terminal's shell, its zsh running npm, which runs node; an unrelated curl beside it.
    private func table() -> FakeTable {
        let table = FakeTable()
        table.add(50, parent: 1, "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
        table.add(60, parent: 50, "zsh", path: "/bin/zsh")
        table.add(100, parent: 60, "claude", path: "/opt/homebrew/bin/claude", arguments: ["claude"], cwd: "/Users/me/GitHub/shop")
        table.add(101, parent: 100, "zsh", path: "/bin/zsh")
        table.add(102, parent: 101, "npm", path: "/opt/homebrew/bin/npm")
        table.add(103, parent: 102, "node", path: "/opt/homebrew/bin/node", arguments: ["node", "install.js"])
        table.add(200, parent: 60, "curl", path: "/usr/bin/curl")
        return table
    }

    @Test func descendantsThroughAShellBelongToTheAgent() {
        let table = table(), tree = AgentProcessTree(source: table.source)
        tree.poll(now: table.origin)
        #expect(tree.liveRoots.map(\.agent.id) == ["claude"])
        #expect(tree.liveRoots.first?.cwd == "/Users/me/GitHub/shop")
        let root = tree.liveRoots[0].key
        #expect(tree.owner(pid: 103)?.root == root)
        #expect(tree.owner(pid: 102)?.process == "npm")
        #expect(tree.owner(pid: 200) == nil)
        #expect(tree.owner(pid: 60) == nil)
    }

    @Test func aChildTooNewForTheWalkIsFoundThroughItsParents() {
        let table = table(), tree = AgentProcessTree(source: table.source)
        tree.poll(now: table.origin)
        table.add(104, parent: 101, "curl", path: "/usr/bin/curl", startedAt: 5)
        #expect(tree.owner(pid: 104)?.root == tree.liveRoots[0].key)
    }

    @Test func reparentedChildrenStayTheAgents() {
        let table = table(), tree = AgentProcessTree(source: table.source)
        tree.poll(now: table.origin)
        // npm daemonizes: its shell exits and launchd adopts it; its own child keeps counting too.
        table.exit(101); table.reparent(102, to: 1)
        table.add(105, parent: 102, "node", path: "/opt/homebrew/bin/node", startedAt: 8)
        tree.walk(now: table.origin + 1)
        let root = tree.liveRoots[0].key
        #expect(tree.owner(pid: 102)?.root == root)
        #expect(tree.owner(pid: 105)?.root == root)
        // The agent exits; what it left running keeps its session open.
        table.exit(100)
        tree.discover(now: table.origin + 2); tree.walk(now: table.origin + 2)
        #expect(tree.running(root))
        table.exit(102); table.exit(103); table.exit(105)
        tree.walk(now: table.origin + 3)
        #expect(!tree.running(root))
    }

    @Test func anExitedChildKeepsItsAgentForLateRows() {
        let table = table(), tree = AgentProcessTree(source: table.source)
        tree.poll(now: table.origin)
        table.exit(103)
        tree.walk(now: table.origin + 1)
        #expect(tree.owner(pid: 103)?.root == tree.liveRoots[0].key)
        tree.walk(now: table.origin + 60)
        #expect(tree.owner(pid: 103) == nil)
    }

    @Test func theNearestAgentWins() {
        let table = FakeTable()
        table.add(10, parent: 1, "Cursor", path: "/Applications/Cursor.app/Contents/MacOS/Cursor")
        table.add(11, parent: 10, "Cursor Helper", path: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper")
        table.add(12, parent: 11, "zsh", path: "/bin/zsh")
        table.add(13, parent: 12, "claude", path: "/opt/homebrew/bin/claude")
        table.add(14, parent: 13, "curl", path: "/usr/bin/curl")
        let tree = AgentProcessTree(source: table.source)
        tree.poll(now: table.origin)
        let keys = Dictionary(uniqueKeysWithValues: tree.liveRoots.map { ($0.agent.id, $0.key) })
        #expect(tree.owner(pid: 14)?.root == keys["claude"])
        #expect(tree.owner(pid: 12)?.root == keys["cursor"])
        #expect(tree.owner(pid: 11)?.root == keys["cursor"])
    }

    @Test func aReusedPidIsAnotherProcess() {
        let table = table(), tree = AgentProcessTree(source: table.source)
        tree.poll(now: table.origin)
        table.exit(103)
        table.add(103, parent: 60, "node", path: "/opt/homebrew/bin/node", startedAt: 20)
        #expect(tree.owner(pid: 103) == nil)
    }
}

@MainActor struct AgentNetworkLogTests {
    private func connection(_ remote: String, port: Int = 443, local: Int = 50_000, proto: String = "tcp4", received: UInt64, sent: UInt64) -> ConnectionTraffic {
        let id = "\(proto) 192.168.1.20:\(local)<->\(remote)\(proto.hasSuffix("6") ? "." : ":")\(port)"
        return ConnectionTraffic(id: id, route: .internet, interface: "en0", received: received, sent: sent)
    }
    private func process(_ pid: Int32, _ name: String, _ connections: [ConnectionTraffic], extraReceived: UInt64 = 0, extraSent: UInt64 = 0) -> ProcessTraffic {
        ProcessTraffic(pid: pid, process: name, received: connections.reduce(extraReceived) { $0 + $1.received }, sent: connections.reduce(extraSent) { $0 + $1.sent }, connections: connections)
    }
    private func setup() -> (FakeTable, AgentNetworkLogStore) {
        let table = FakeTable()
        table.add(60, parent: 1, "zsh", path: "/bin/zsh", startedAt: -100)
        table.add(100, parent: 60, "claude", path: "/opt/homebrew/bin/claude", startedAt: -50, cwd: "/Users/me/GitHub/shop")
        table.add(101, parent: 100, "zsh", path: "/bin/zsh", startedAt: -40)
        table.add(102, parent: 101, "npm", path: "/opt/homebrew/bin/npm", startedAt: -30)
        table.add(300, parent: 60, "curl", path: "/usr/bin/curl", startedAt: -20)
        let store = AgentNetworkLogStore(tree: AgentProcessTree(source: table.source), lookup: HostLookup(forward: { _ in [] }, reverse: { _ in nil }))
        store.filterNames = { ["104.16.5.34": "registry.npmjs.org", "104.16.6.34": "registry.npmjs.org", "198.51.100.7": "pastebin.com", "203.0.113.9": "example.org"] }
        return (table, store)
    }

    @Test func firstSightingIsABaselineThenOnlyDeltasCount() {
        let (table, store) = setup()
        let t0 = table.origin
        store.consume(TrafficSnapshot(timestamp: t0, processes: [process(102, "npm", [connection("104.16.5.34", received: 5_000_000, sent: 10_000)])]))
        #expect(store.report.isEmpty)
        store.consume(TrafficSnapshot(timestamp: t0 + 1, processes: [process(102, "npm", [connection("104.16.5.34", received: 7_000_000, sent: 12_000),
                                                                                          connection("104.16.6.34", local: 50_001, received: 1_000, sent: 500)]),
                                                                    process(300, "curl", [connection("203.0.113.9", received: 900, sent: 100)])]))
        let entry = try! #require(store.report.first)
        #expect(entry.agent == "Claude Code" && entry.project == "shop")
        // Both Cloudflare addresses are one npm row; the unrelated curl isn't Claude's.
        #expect(entry.hosts.map(\.host) == ["registry.npmjs.org"])
        let npm = entry.hosts[0]
        #expect(npm.received == 2_001_000 && npm.sent == 2_500 && npm.connections == 1 && npm.addresses.sorted() == ["104.16.5.34", "104.16.6.34"])
        #expect(entry.hostCount == 1 && entry.received == 2_001_000)
    }

    @Test func aProcessStartedSinceTheLastSampleCountsInFull() {
        let (table, store) = setup()
        let t0 = table.origin
        store.consume(TrafficSnapshot(timestamp: t0, processes: []))
        table.add(103, parent: 101, "curl", path: "/usr/bin/curl", startedAt: 0.5)
        store.consume(TrafficSnapshot(timestamp: t0 + 1, processes: [process(103, "curl", [connection("198.51.100.7", received: 300, sent: 20_000_000)])]))
        let host = try! #require(store.report.first?.hosts.first)
        #expect(host.process == "curl" && host.host == "pastebin.com" && host.sent == 20_000_000)
        #expect(host.flags.contains(.shareOrTunnel) && host.category == "paste site" && host.flags.contains(.largeUpload) && host.flags.contains(.newHost))
    }

    @Test func socketsThatClosedBetweenSamplesCountAsUnmatched() {
        let (table, store) = setup()
        let t0 = table.origin
        store.consume(TrafficSnapshot(timestamp: t0, processes: [process(102, "npm", [connection("104.16.5.34", received: 100, sent: 100)])]))
        store.consume(TrafficSnapshot(timestamp: t0 + 1, processes: [process(102, "npm", [connection("104.16.5.34", received: 200, sent: 150)], extraReceived: 4_000, extraSent: 50)]))
        let entry = try! #require(store.report.first)
        #expect(entry.unmatchedReceived == 4_000 && entry.unmatchedSent == 50)
        #expect(entry.received == 4_100)
    }

    @Test func sessionsEndWhenTheAgentAndItsChildrenExit() {
        let (table, store) = setup()
        let t0 = table.origin
        store.consume(TrafficSnapshot(timestamp: t0, processes: [process(102, "npm", [])]))
        store.consume(TrafficSnapshot(timestamp: t0 + 1, processes: [process(102, "npm", [connection("104.16.5.34", local: 50_010, received: 0, sent: 0)])]))
        #expect(store.running.count == 1)
        table.exit(102); table.exit(101); table.exit(100)
        store.tree.discover(now: t0 + 2)
        store.consume(TrafficSnapshot(timestamp: t0 + 2, processes: []))
        store.tree.walk(now: t0 + 40)
        store.consume(TrafficSnapshot(timestamp: t0 + 40, processes: []))
        #expect(store.running.isEmpty)
        #expect(store.report.first?.end != nil)
    }

    @Test func nothingIsRecordedWithoutPro() {
        let (table, store) = setup()
        store.allowed = { false }
        store.consume(TrafficSnapshot(timestamp: table.origin, processes: []))
        store.consume(TrafficSnapshot(timestamp: table.origin + 1, processes: [process(102, "npm", [connection("104.16.5.34", received: 9, sent: 9)])]))
        #expect(store.sessions.isEmpty)
    }

    @Test func retentionDropsOldSessionsButRemembersTheirHosts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-agentlog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        var old = AgentNetworkSession(key: "1@1", agent: AgentIdentity(id: "codex", name: "Codex"), pid: 1, start: now - 40 * 86_400)
        old.end = now - 31 * 86_400
        old.hosts = [AgentHostRecord(process: "codex", address: "203.0.113.9", port: "443", transport: "TCP", host: "example.org", nameSource: "filter", first: old.start, last: old.start, sent: 1, received: 1, connections: 1)]
        var recent = old; recent.id = UUID(); recent.key = "2@2"; recent.start = now - 86_400; recent.end = now - 80_000
        let file = AgentLogFile(recording: true, updated: now, sessions: [old, recent])
        try file.data().write(to: directory.appendingPathComponent("agent-network-log.json"))
        let store = AgentNetworkLogStore(directory: directory, tree: AgentProcessTree(source: FakeTable().source))
        #expect(store.sessions.map(\.key) == ["2@2"])
        #expect(store.pastHosts.contains("example.org"))
        // Known from the dropped session, so not new.
        #expect(store.report.first?.hosts.first?.flags.contains(.newHost) == false)
        store.clear()
        #expect(store.sessions.isEmpty && store.pastHosts.isEmpty)
        #expect(AgentLogFile.load(directory.appendingPathComponent("agent-network-log.json"))?.sessions.isEmpty == true)
    }
}

struct AgentHostFlagTests {
    private func session(_ agent: String, start: Date, _ records: [AgentHostRecord]) -> AgentNetworkSession {
        var session = AgentNetworkSession(key: UUID().uuidString, agent: AgentIdentity(id: agent, name: agent), pid: 1, start: start)
        session.end = start + 60; session.hosts = records
        return session
    }
    private func record(_ process: String, _ host: String?, address: String = "203.0.113.1", port: String = "443", source: String? = "lookup", sent: UInt64 = 1_000) -> AgentHostRecord {
        AgentHostRecord(process: process, address: address, port: port, transport: "TCP", host: host, nameSource: host == nil ? nil : source, first: .distantPast, last: .distantPast, sent: sent, received: 10, connections: 1)
    }

    @Test func eachRule() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let report = AgentNetworkLog.report([session("claude", start: start, [
            record("node", "api.anthropic.com", sent: 80_000_000),          // own service: a big upload is the agent working
            record("npm", "registry.npmjs.org"),                            // well known: never new
            record("curl", "downloads.example.net", port: "80"),            // plain HTTP, new
            record("python3", "files.example.com", sent: 11_000_000),       // large upload, new
            record("node", nil, address: "198.51.100.200"),                 // no name at all
            record("node", "server-1.example.cloudfront.net", source: "reverse"), // a reverse name is not the name asked for
            record("ssh", "abc.trycloudflare.com"),                         // tunnel
        ])])
        let flags = Dictionary(uniqueKeysWithValues: report[0].hosts.map { ($0.host, Set($0.flags)) })
        #expect(flags["api.anthropic.com"] == [])
        #expect(flags["registry.npmjs.org"] == [])
        #expect(flags["downloads.example.net"] == [.newHost, .plainHTTP])
        #expect(flags["files.example.com"] == [.newHost, .largeUpload])
        #expect(flags["198.51.100.200"] == [.newHost, .addressOnly])
        #expect(flags["server-1.example.cloudfront.net"] == [.newHost, .addressOnly])
        #expect(flags["abc.trycloudflare.com"] == [.newHost, .shareOrTunnel])
        #expect(report[0].hosts.first { $0.host == "abc.trycloudflare.com" }?.notes == "first time, tunnel")
    }

    @Test func reviewCountSkipsRoutineHostsAndDeduplicatesUploads() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = AgentNetworkLog.report([session("codex", start: start, [
            record("node", nil, address: "198.51.100.200"),
            record("curl", "first-seen.example.org"),
            record("curl", "read.trycloudflare.com", sent: 0),
            record("node", "upload.example.org", sent: 6_000_000),
            record("curl", "upload.example.org", sent: 6_000_000),
            record("curl", "send.trycloudflare.com", sent: 4_000)
        ])])[0]
        #expect(entry.reviewCount == 2)
        #expect(Set(entry.hosts.filter(\.needsReview).map(\.host)) == ["upload.example.org", "send.trycloudflare.com"])
        #expect(entry.flaggedCount > entry.reviewCount)
    }

    @Test func aHostIsNewOnlyTheFirstTime() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let report = AgentNetworkLog.report([session("codex", start: start, [record("codex", "example.org")]),
                                             session("claude", start: start + 3_600, [record("curl", "example.org")])])
        #expect(report[0].agent == "claude" && report[0].hosts[0].flags.isEmpty)
        #expect(report[1].hosts[0].flags == [.newHost])
    }

    @Test func sortedByProcessThenBytesSentAndMarkdown() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = AgentNetworkLog.report([session("claude", start: start, [
            record("git-remote-https", "github.com", sent: 5_000), record("npm", "registry.npmjs.org", sent: 9_000),
            record("npm", "nodejs.org", sent: 20_000), record("git-remote-https", "codeload.github.com", sent: 1)])])[0]
        #expect(entry.processes.map(\.process) == ["npm", "git-remote-https"])
        #expect(entry.hosts.map(\.host) == ["nodejs.org", "registry.npmjs.org", "github.com", "codeload.github.com"])
        let markdown = AgentNetworkLog.markdown(entry)
        #expect(markdown.hasPrefix("## claude"))
        #expect(markdown.contains("| npm | nodejs.org | 443/TCP | 20 KB | 10 B | 1 |"))
    }
}

struct AgentLogQueryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func parsesEveryOption() throws {
        let query = try AgentLogQuery.parse(["agent-log", "--all", "--agent", "claude", "--flagged", "--json"], now: now)
        #expect(query == AgentLogQuery(all: true, agent: "claude", flagged: true, json: true))
        #expect(try AgentLogQuery.parse(["agent-log", "--since", "2h"], now: now).since == now - 7_200)
        #expect(try AgentLogQuery.parse(["--since", "3d"], now: now).since == now - 3 * 86_400)
        #expect(AgentLogQuery.since("2026-10-30", now: now) != nil)
        #expect(AgentLogQuery.since("2026-10-30T14:05:00Z", now: now) == Date(timeIntervalSince1970: 1_793_369_100))
        #expect(AgentLogQuery.since("today", now: now) == Calendar.current.startOfDay(for: now))
    }

    @Test func rejectsWhatItDoesntKnow() {
        #expect(throws: AgentLogQuery.Failure.self) { try AgentLogQuery.parse(["agent-log", "--since"], now: now) }
        #expect(throws: AgentLogQuery.Failure.self) { try AgentLogQuery.parse(["agent-log", "--since", "soon"], now: now) }
        #expect(throws: AgentLogQuery.Failure.self) { try AgentLogQuery.parse(["agent-log", "--agent", "--json"], now: now) }
        #expect(throws: AgentLogQuery.Failure.self) { try AgentLogQuery.parse(["agent-log", "--verbose"], now: now) }
        // A date still ahead is a mistake, not a filter.
        #expect(AgentLogQuery.since("2099-01-01", now: now) == nil)
    }

    @Test func selectsTheLatestTheOwnSessionOrAllSince() {
        func entry(_ agent: String, pid: Int32, start: TimeInterval, running: Bool) -> AgentLogEntry {
            AgentLogEntry(id: UUID(), agent: agent, agentID: agent.lowercased(), pid: pid, start: now - start, end: running ? nil : now - start + 60, running: running,
                          cwd: nil, project: nil, executable: nil, sent: 0, received: 0, unmatchedSent: 0, unmatchedReceived: 0, hostCount: 1, flaggedCount: 0, hosts: [])
        }
        let entries = [entry("Codex", pid: 7, start: 100, running: true), entry("Claude", pid: 9, start: 3_000, running: true), entry("Claude", pid: 5, start: 90_000, running: false)]
        #expect(AgentLogQuery().select(entries).map(\.pid) == [7])
        // Run from inside Claude Code: its own session.
        #expect(AgentLogQuery().select(entries, within: [12, 9, 1]).map(\.pid) == [9])
        #expect(AgentLogQuery(agent: "claude").select(entries).map(\.pid) == [9])
        #expect(AgentLogQuery(all: true).select(entries).count == 3)
        #expect(AgentLogQuery(since: now - 7_200).select(entries).map(\.pid) == [7, 9])
    }
}
