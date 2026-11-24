import Foundation
import Testing
@testable import KilobatCore

/// Connect your agents, on a made-up home folder: detection, skills, hooks and the Claude app's chat server.
struct AgentConnectTests {
    let root: URL
    let home: URL
    let env: AgentEnvironment
    let bundle: AgentSkillBundle

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-connect-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        env = AgentEnvironment(home: home, applications: [root.appendingPathComponent("Applications").path], bin: [root.appendingPathComponent("bin").path])
        let skills = root.appendingPathComponent("skills")
        for name in ["kilobat", "mac-wifi-troubleshooting"] {
            try Self.put("---\nname: \(name)\n---\n# \(name)\n", to: skills.appendingPathComponent(name).appendingPathComponent("SKILL.md"))
        }
        try Self.put("Notes", to: skills.appendingPathComponent("kilobat/references/notes.md"))
        bundle = try #require(AgentSkillBundle(root: skills))
    }

    func write(_ text: String, to url: URL) throws { try Self.put(text, to: url) }
    static func put(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func tool(_ name: String) throws {
        let url = root.appendingPathComponent("bin").appendingPathComponent(name)
        try write("#!/bin/sh\n", to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    func app(_ name: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Applications/\(name).app/Contents"), withIntermediateDirectories: true)
    }
    func read(_ relative: String) throws -> String { try String(contentsOf: home.appendingPathComponent(relative), encoding: .utf8) }

    // MARK: Detection

    @Test func findsOnlyInstalledAgentsInAFixedOrder() throws {
        #expect(AgentDetector.detect(in: env).isEmpty)
        try tool("codex"); try tool("gemini"); try app("Cursor")
        #expect(AgentDetector.detect(in: env).map(\.kind) == [.codex, .cursor, .gemini])
        #expect(AgentDetector.detect(in: env).first { $0.kind == .cursor }?.appPath?.hasSuffix("Cursor.app") == true)
    }

    @Test func oneClaudeRowCoversTheAppAndTheCommand() throws {
        try tool("claude")
        let command = try #require(AgentDetector.detect(in: env).first)
        #expect(command.name == "Claude Code" && !command.chat && command.appPath == nil)
        try app("Claude")
        let both = AgentDetector.detect(in: env).filter { $0.kind == .claude }
        #expect(both.count == 1)
        #expect(both[0].name == "Claude" && both[0].chat)
    }

    @Test func vsCodeAndCodexInsideChatGPT() throws {
        try app("Visual Studio Code")
        #expect(AgentDetector.detect(in: env).map(\.name) == ["VS Code"])
        let bundled = root.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        try write("#!/bin/sh\n", to: bundled)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
        #expect(AgentDetector.detect(in: env).map(\.kind) == [.codex, .copilot])
    }

    // MARK: Skills

    @Test func connectCopiesSkillsIntoTheAgentsOwnFolder() throws {
        let cursor = DetectedAgent(kind: .cursor, name: "Cursor", appPath: nil)
        #expect(AgentConnector.status(of: cursor, bundle: bundle, env: env).overall == .off)
        try AgentConnector.connect(cursor, bundle: bundle, kilobat: "/opt/homebrew/bin/kilobat", env: env)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".cursor/skills/kilobat/references/notes.md").path))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".cursor/skills/kilobat/\(AgentConnector.marker)").path))
        #expect(AgentConnector.status(of: cursor, bundle: bundle, env: env) == AgentConnection(skills: .current))
        // An edited or missing skill is out of date.
        try write("old", to: home.appendingPathComponent(".cursor/skills/kilobat/SKILL.md"))
        #expect(AgentConnector.status(of: cursor, bundle: bundle, env: env).overall == .partial)
        try AgentConnector.refreshSkills(cursor, bundle: bundle, env: env)
        #expect(AgentConnector.status(of: cursor, bundle: bundle, env: env).overall == .connected)
    }

    @Test func codexSharesTheAgentsFolderAndASkillsShLinkCounts() throws {
        #expect(AgentKind.codex.skillsFolder == ".agents/skills")
        // skills.sh keeps the copy in ~/.agents/skills and links it from ~/.claude/skills.
        let canonical = home.appendingPathComponent(".agents/skills")
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        for name in bundle.names { try FileManager.default.copyItem(at: bundle.root.appendingPathComponent(name), to: canonical.appendingPathComponent(name)) }
        let claudeSkills = home.appendingPathComponent(".claude/skills")
        try FileManager.default.createDirectory(at: claudeSkills, withIntermediateDirectories: true)
        for name in bundle.names { try FileManager.default.createSymbolicLink(atPath: claudeSkills.appendingPathComponent(name).path, withDestinationPath: "../../.agents/skills/" + name) }
        #expect(AgentConnector.skillState(.claude, bundle: bundle, env: env) == .current)
        #expect(AgentConnector.skillState(.codex, bundle: bundle, env: env) == .current)
    }

    @Test func refreshRemovesSkillsTheAppDroppedAndLeavesOthersAlone() throws {
        let folder = home.appendingPathComponent(".gemini/skills")
        try AgentConnector.installSkills(bundle, into: folder)
        try write("old", to: folder.appendingPathComponent("mac-old-skill/SKILL.md"))
        try write("x", to: folder.appendingPathComponent("mac-old-skill/\(AgentConnector.marker)"))
        try write("mine", to: folder.appendingPathComponent("someone-elses/SKILL.md"))
        #expect(AgentConnector.staleSkills(bundle, in: folder) == ["mac-old-skill"])
        try AgentConnector.installSkills(bundle, into: folder)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("mac-old-skill").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("someone-elses/SKILL.md").path))
        try AgentConnector.removeSkills(bundle, from: folder)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["someone-elses"])
    }

    @Test func refreshLeavesAFolderWhoseSkillsWereRemovedByHand() throws {
        let cursor = DetectedAgent(kind: .cursor, name: "Cursor", appPath: nil)
        try AgentConnector.refreshSkills(cursor, bundle: bundle, env: env)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".cursor/skills").path))
    }

    @Test func theClaudeCodePluginAlreadyProvidesTheSkills() throws {
        try write(#"{"version": 2, "plugins": {"kilobat@kilobat": [{"scope": "user"}]}}"#, to: home.appendingPathComponent(".claude/plugins/installed_plugins.json"))
        let claude = DetectedAgent(kind: .claude, name: "Claude Code", appPath: nil)
        try AgentConnector.connect(claude, bundle: bundle, kilobat: "/usr/local/bin/kilobat", env: env)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/skills/kilobat").path))
        #expect(AgentConnector.status(of: claude, bundle: bundle, env: env).overall == .connected)
    }

    // MARK: Hooks

    @Test func claudeHooksJoinExistingSettingsWithoutReorderingThem() throws {
        let settings = """
        {
          "model": "opus",
          "permissions": {"allow": ["Bash(ls)"], "deny": []},
          "hooks": {
            "Stop": [{"hooks": [{"type": "command", "command": "notify.sh", "timeout": 1.50}]}]
          },
          "tui": "default"
        }
        """
        try write(settings, to: home.appendingPathComponent(".claude/settings.json"))
        let claude = DetectedAgent(kind: .claude, name: "Claude Code", appPath: nil)
        #expect(AgentConnector.status(of: claude, bundle: bundle, env: env).hooks == .missing)
        try AgentConnector.connect(claude, bundle: bundle, kilobat: "/opt/homebrew/bin/kilobat", env: env)
        let root = try OrderedJSON.parse(try read(".claude/settings.json"))
        #expect(root.members?.map(\.key) == ["model", "permissions", "hooks", "tui"])
        let stop = try #require(root["hooks"]?["Stop"]?.array)
        #expect(stop.count == 2)
        #expect(stop[0]["hooks"]?.array?.first?["command"]?.string == "notify.sh")
        #expect(stop[0]["hooks"]?.array?.first?["timeout"] == .number("1.50"))
        #expect(stop[1]["hooks"]?.array?.first?["command"]?.string == "/opt/homebrew/bin/kilobat agent-event --agent claude --stdin-json")
        #expect(root["hooks"]?.members?.map(\.key) == ["Stop", "SessionStart", "UserPromptSubmit", "Notification", "StopFailure", "SessionEnd"])
        #expect(AgentConnector.status(of: claude, bundle: bundle, env: env).overall == .connected)

        // Connecting again adds nothing; disconnecting gives back the original hooks.
        let once = try read(".claude/settings.json")
        try AgentConnector.connect(claude, bundle: bundle, kilobat: "/opt/homebrew/bin/kilobat", env: env)
        #expect(try read(".claude/settings.json") == once)
        try AgentConnector.disconnect(claude, bundle: bundle, env: env)
        let after = try OrderedJSON.parse(try read(".claude/settings.json"))
        #expect(after == (try OrderedJSON.parse(settings)))
        #expect(AgentConnector.status(of: claude, bundle: bundle, env: env).overall == .off)
    }

    @Test func aHandWrittenKilobatHookCountsAndIsntDoubled() throws {
        let root = try OrderedJSON.parse(#"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "kilobat agent-event --agent claude --stdin-json"}]}]}}"#)
        #expect(AgentConnector.hookEvents(in: root) == ["Stop"])
        let hooks = try #require(AgentKind.claude.hooks)
        let added = try AgentConnector.addingHooks(to: root, hooks: hooks, kilobat: "/x/kilobat")
        #expect(added["hooks"]?["Stop"]?.array?.count == 1)
        #expect(AgentConnector.hookEvents(in: added) == Set(hooks.events))
    }

    @Test func aSharedGroupKeepsTheOtherHooks() throws {
        let root = try OrderedJSON.parse(#"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "a.sh"}, {"type": "command", "command": "'/Users/me/bin/kilobat' agent-event --agent codex --stdin-json"}]}], "Other": []}}"#)
        let removed = AgentConnector.removingHooks(from: root)
        #expect(removed == (try OrderedJSON.parse(#"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "a.sh"}]}], "Other": []}}"#)))
    }

    @Test func refusesToRewriteAFileItCantRead() throws {
        try write("{ // comments\n \"a\": 1 }", to: home.appendingPathComponent(".codex/hooks.json"))
        let codex = DetectedAgent(kind: .codex, name: "Codex", appPath: nil)
        #expect(throws: AgentConnectError.self) { try AgentConnector.connect(codex, bundle: bundle, kilobat: "/k", env: env) }
        #expect(try read(".codex/hooks.json") == "{ // comments\n \"a\": 1 }")
        #expect(throws: AgentConnectError.self) { try AgentConnector.addingHooks(to: .array([]), hooks: AgentKind.codex.hooks!, kilobat: "/k") }
    }

    @Test func codexHooksNeedApprovalUntilConfigRecordsThem() throws {
        let codex = DetectedAgent(kind: .codex, name: "Codex", appPath: nil)
        try write(#"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "node flush.js"}]}]}}"#, to: home.appendingPathComponent(".codex/hooks.json"))
        try AgentConnector.connect(codex, bundle: bundle, kilobat: "/opt/homebrew/bin/kilobat", env: env)
        let status = AgentConnector.status(of: codex, bundle: bundle, env: env)
        #expect(status.overall == .connected && status.hooksNeedReview)
        // Codex keys approval by file, event, group and hook: ours went after the existing Stop group.
        let file = home.appendingPathComponent(".codex/hooks.json").path
        let keys = ["session_start:0:0", "user_prompt_submit:0:0", "permission_request:0:0", "stop:1:0"].map { "[hooks.state.\"\(file):\($0)\"]\ntrusted_hash = \"sha256:x\"\n" }
        try write("model = \"gpt\"\n" + keys.joined(), to: home.appendingPathComponent(".codex/config.toml"))
        #expect(!AgentConnector.status(of: codex, bundle: bundle, env: env).hooksNeedReview)
        #expect(AgentConnector.snakeCase("UserPromptSubmit") == "user_prompt_submit")
    }

    @Test func hookCommandsQuoteAPathWithSpaces() {
        let hooks = AgentKind.gemini.hooks!
        #expect(hooks.command(kilobat: "/opt/homebrew/bin/kilobat") == "/opt/homebrew/bin/kilobat agent-event --agent gemini --stdin-json")
        #expect(hooks.command(kilobat: "/Applications/My Apps/Kilobat.app/Contents/Helpers/kilobat") == "'/Applications/My Apps/Kilobat.app/Contents/Helpers/kilobat' agent-event --agent gemini --stdin-json")
        #expect(AgentKind.cursor.hooks == nil && AgentKind.copilot.hooks == nil)
    }

    // MARK: The Claude app's chat

    @Test func claudeAppChatGetsTheMCPServerBesideItsPreferences() throws {
        try app("Claude")
        let config = "Library/Application Support/Claude/claude_desktop_config.json"
        try write(#"{"mcpServers": {"other": {"command": "x"}}, "preferences": {"menuBarEnabled": true}}"#, to: home.appendingPathComponent(config))
        let claude = try #require(AgentDetector.detect(in: env).first)
        try tool("kilobat")
        let kilobat = root.appendingPathComponent("bin/kilobat").path
        try AgentConnector.connect(claude, bundle: bundle, kilobat: kilobat, env: env)
        let root = try OrderedJSON.parse(try read(config))
        #expect(root.members?.map(\.key) == ["mcpServers", "preferences"])
        #expect(root["mcpServers"]?.members?.map(\.key) == ["other", "kilobat"])
        #expect(root["mcpServers"]?["kilobat"]?["args"] == .array([.string("mcp")]))
        let status = AgentConnector.status(of: claude, bundle: bundle, env: env)
        #expect(status.chat == .current && status.overall == .connected)
        try AgentConnector.disconnect(claude, bundle: bundle, env: env)
        #expect(try OrderedJSON.parse(try read(config))["mcpServers"]?.members?.map(\.key) == ["other"])
    }

    @Test func aChatServerWhoseCommandIsGoneIsOutOfDate() throws {
        try write(#"{"mcpServers": {"kilobat": {"command": "/nowhere/kilobat", "args": ["mcp"]}}}"#, to: home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"))
        #expect(AgentConnector.chatState(env) == .outdated)
    }

    // MARK: Ordered JSON

    @Test func orderedJSONRoundTripsKeysNumbersAndEscapes() throws {
        let text = #"{"b": 1, "a": [true, null, -2.50e3], "s": "line\n\"quoted\" é 😀 / tab\t", "e": {}, "l": []}"#
        let value = try OrderedJSON.parse(text)
        #expect(value.members?.map(\.key) == ["b", "a", "s", "e", "l"])
        #expect(value["a"] == .array([.bool(true), .null, .number("-2.50e3")]))
        #expect(value["s"]?.string == "line\n\"quoted\" é 😀 / tab\t")
        #expect(try OrderedJSON.parse(value.serialized()) == value)
        #expect(OrderedJSON.object([.init("k", .array([.number("1")]))]).serialized() == "{\n  \"k\": [\n    1\n  ]\n}\n")
        for bad in ["{", "{\"a\" 1}", "[1,]x", "tru", "{\"a\": 01x}", "\"\u{01}\""] { #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse(bad) } }
    }

    @Test func connectionOverallState() {
        #expect(AgentConnection(skills: .missing, hooks: .missing).overall == .off)
        #expect(AgentConnection(skills: .current, hooks: .missing).overall == .partial)
        #expect(AgentConnection(skills: .current, hooks: .current, chat: .current).overall == .connected)
        #expect(AgentConnection(skills: .outdated).overall == .partial)
    }
}
