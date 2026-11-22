import Foundation
import Testing
@testable import KilobatCore

struct AgentHostTests {
    static let claude = AgentIdentity(id: "claude", name: "Claude Code")
    static let t3 = "/Applications/T3 Code (Beta).app/Contents/MacOS/T3 Code (Beta)"

    @Test func newDesktopAgentsByTheirMainExecutable() {
        #expect(AgentIdentifier.identify(path: Self.t3, name: "T3 Code (Beta)")?.id == "t3code")
        #expect(AgentIdentifier.identify(path: "/Applications/T3 Code.app/Contents/MacOS/T3 Code", name: "T3 Code")?.name == "T3 Code")
        #expect(AgentIdentifier.identify(path: "/Applications/Conductor.app/Contents/MacOS/Conductor", name: "Conductor")?.id == "conductor")
        #expect(AgentIdentifier.identify(path: "/Applications/Codex.app/Contents/MacOS/Codex", name: "Codex")?.id == "codex-app")
        #expect(AgentIdentifier.identify(path: "/Applications/Codex.app/Contents/MacOS/Codex", name: "Codex")?.app == true)
        // A helper inside the app isn't the app.
        #expect(AgentIdentifier.identify(path: "/Applications/T3 Code (Beta).app/Contents/Frameworks/T3 Code (Beta) Helper.app/Contents/MacOS/T3 Code (Beta) Helper",
                                         name: "T3 Code (Beta) Helper") == nil)
        // The codex command stays Codex, wherever it is installed.
        #expect(AgentIdentifier.identify(path: "/Applications/Codex.app/Contents/Resources/codex", name: "codex")?.id == "codex")
    }

    @Test func hostsByOutermostBundle() {
        #expect(AgentHost.named(path: Self.t3) == "T3 Code")
        #expect(AgentHost.named(path: "/Applications/T3 Code.app/Contents/MacOS/T3 Code") == "T3 Code")
        #expect(AgentHost.named(path: "/Applications/T3 Code (Beta).app/Contents/Frameworks/T3 Code (Beta) Helper.app/Contents/MacOS/T3 Code (Beta) Helper") == "T3 Code")
        #expect(AgentHost.named(path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron") == "VS Code")
        #expect(AgentHost.named(path: "/Applications/Visual Studio Code - Insiders.app/Contents/MacOS/Electron") == "VS Code Insiders")
        #expect(AgentHost.named(path: "/Applications/Conductor.app/Contents/MacOS/Conductor") == "Conductor")
        #expect(AgentHost.named(path: "/Applications/Zed.app/Contents/MacOS/zed") == "Zed")
        #expect(AgentHost.named(path: "/Applications/Warp.app/Contents/MacOS/stable") == "Warp")
        // Terminals and other apps are not hosts.
        #expect(AgentHost.named(path: "/Applications/iTerm.app/Contents/MacOS/iTerm2") == nil)
        #expect(AgentHost.named(path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal") == nil)
        #expect(AgentHost.named(path: "/Applications/Ghostty.app/Contents/MacOS/ghostty") == nil)
        #expect(AgentHost.named(path: "/opt/homebrew/bin/claude") == nil)
    }

    /// pid → (parent, path).
    static func find(_ pid: Int32, _ table: [Int32: (Int32, String)], agent: AgentIdentity = claude) -> String? {
        AgentHost.find(pid: pid, agent: agent, parent: { table[$0]?.0 }, path: { table[$0]?.1 })
    }

    @Test func walksUpToTheFirstApp() {
        // T3 Code runs claude directly.
        #expect(Self.find(30, [30: (20, "/Users/me/.local/share/claude/versions/2.1.3"), 20: (10, Self.t3), 10: (1, Self.t3)]) == "T3 Code")
        // VS Code's terminal: claude under a shell under the app's helper.
        let vscode: [Int32: (Int32, String)] = [40: (Int32(30), "/opt/homebrew/bin/claude"), 30: (20, "/bin/zsh"),
                      20: (10, "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"),
                      10: (1, "/Applications/Visual Studio Code.app/Contents/MacOS/Electron")]
        #expect(Self.find(40, vscode) == "VS Code")
        // A terminal: the first app is iTerm, so no host, even if something above it would be one.
        let iterm: [Int32: (Int32, String)] = [40: (Int32(30), "/opt/homebrew/bin/claude"), 30: (20, "/bin/zsh"), 20: (10, "/usr/bin/login"),
                     10: (5, "/Applications/iTerm.app/Contents/MacOS/iTerm2"), 5: (1, Self.t3)]
        #expect(Self.find(40, iterm) == nil)
        #expect(Self.find(40, [40: (1, "/opt/homebrew/bin/claude")]) == nil)
        // The Codex app running its own codex: not worth saying.
        let codex = AgentIdentity(id: "codex", name: "Codex")
        #expect(Self.find(20, [20: (10, "/Applications/Codex.app/Contents/Resources/codex"), 10: (1, "/Applications/Codex.app/Contents/MacOS/Codex")], agent: codex) == nil)
        // A desktop agent has no host.
        #expect(Self.find(10, [10: (5, Self.t3), 5: (1, Self.t3)], agent: AgentIdentity(id: "t3code", name: "T3 Code", app: true)) == nil)
    }

    @Test func labelSaysWhereItRan() {
        #expect(AgentHost.label("Claude Code", host: "T3 Code") == "Claude in T3 Code")
        #expect(AgentHost.label("Claude Code", host: nil) == "Claude Code")
        #expect(AgentHost.label("Codex", host: "T3 Code") == "Codex in T3 Code")
        #expect(AgentHost.label("Claude Code", host: nil) == "Claude Code")
        let detail = ProtectionDetail(kind: .agentGuard, list: "paste site", host: "paste.example", agent: "Claude Code", process: "curl", agentHostApp: "T3 Code")
        #expect(detail.agentLabel == "Claude in T3 Code")
        #expect(ProtectionText.who(detail, app: "curl") == "curl (started by Claude in T3 Code)")
    }

    @Test func treeRecordsTheHostAndKeepsTheAgent() {
        let table = FakeTable()
        table.add(10, parent: 1, "T3 Code (Beta)", path: Self.t3)
        table.add(20, parent: 10, "T3 Code (Beta)", path: Self.t3)
        table.add(30, parent: 20, "claude", path: "/opt/homebrew/bin/claude", arguments: ["claude"])
        table.add(40, parent: 1, "claude", path: "/opt/homebrew/bin/claude", arguments: ["claude"])
        let tree = AgentProcessTree(source: table.source)
        tree.discover()
        let roots = Dictionary(uniqueKeysWithValues: tree.liveRoots.map { ($0.pid, $0) })
        #expect(roots[30]?.agent.id == "claude")
        #expect(roots[30]?.hostApp == "T3 Code")
        #expect(roots[40]?.hostApp == nil)
        #expect(roots[10]?.agent.id == "t3code")
        #expect(roots[10]?.hostApp == nil)
        // A T3 Code helper is T3 Code's, the claude it ran stays its own agent.
        #expect(tree.owner(pid: 30)?.root == roots[30]?.key)
    }

    @Test func lineageCarriesTheHost() {
        struct Row { var ppid: Int32; var name: String; var path: String }
        let rows: [Int32: Row] = [10: Row(ppid: 1, name: "T3 Code (Beta)", path: Self.t3), 30: Row(ppid: 10, name: "claude", path: "/opt/homebrew/bin/claude"),
                                  50: Row(ppid: 30, name: "curl", path: "/usr/bin/curl")]
        let lineage = AgentLineage(lookup: .init(entry: { rows[$0].map { AgentLineage.Process(ppid: $0.ppid, name: $0.name, start: 1) } },
                                                 path: { rows[$0]?.path }, arguments: { rows[$0].map { [$0.name] } }))
        let owner = lineage.owner(pid: 50)
        #expect(owner?.agent.id == "claude")
        #expect(owner?.hostApp == "T3 Code")
    }

    @Test func oldLogsAndSessionsStillDecode() throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let session = #"{"id":"6E0B1F4C-1A0B-4D7E-9C55-2B9E4E1B7C11","key":"1@1","agent":"Claude Code","agentID":"claude","pid":1,"start":"2026-11-01T10:00:00Z","hosts":[],"unmatchedSent":0,"unmatchedReceived":0}"#
        let decoded = try decoder.decode(AgentNetworkSession.self, from: Data(session.utf8))
        #expect(decoded.hostApp == nil)
        let detail = try JSONDecoder().decode(ProtectionDetail.self, from: Data(#"{"kind":"malware","list":"URLhaus","host":"x.example","agent":"Codex"}"#.utf8))
        #expect(detail.agentLabel == "Codex")
        // The host goes through the report.
        var hosted = decoded
        hosted.hostApp = "T3 Code"
        hosted.hosts = [AgentHostRecord(process: "claude", address: "1.2.3.4", port: "443", transport: "TCP", host: "api.anthropic.com", nameSource: "filter",
                                        first: hosted.start, last: hosted.start, sent: 10)]
        let entry = try #require(AgentNetworkLog.report([hosted]).first)
        #expect(entry.agentID == "claude")
        #expect(entry.title == "Claude in T3 Code")
        #expect(AgentLogQuery(agent: "claude").matches(entry))
    }

    @Test func workSessionLabel() {
        var run = WorkSession(kind: .agent, title: "Claude Code", start: Date(), lastActive: Date())
        #expect(run.label == "Claude Code")
        run.hostApp = "Conductor"
        #expect(run.label == "Claude in Conductor")
        #expect(run.title == "Claude Code")
    }
}
