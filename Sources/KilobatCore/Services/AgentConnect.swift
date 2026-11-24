import Foundation
import CryptoKit

/// Connecting AI agents to Kilobat from the app: which agents are on this Mac, whether each already has Kilobat's
/// skills (and, where the agent has them, the run-tracking hooks or chat tools), and adding or removing them.
///
/// Skills are the core. They are folders of Markdown that run the `kilobat` command, copied into the folder each agent
/// reads its personal skills from: the same folders `npx skills add` (skills.sh) uses, so either install keeps working.
/// Hooks go in the file each agent documents for them, merged with whatever is already there. The Claude app's chat
/// can't run commands, so it gets Kilobat's MCP server instead. Nothing here runs unless someone clicks Connect.
public enum AgentKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude, codex, cursor, gemini, copilot, windsurf, opencode
    public var id: String { rawValue }

    /// The personal skills folder, relative to the home folder, as skills.sh writes it for this agent.
    public var skillsFolder: String {
        switch self {
        case .claude: ".claude/skills"
        // Codex reads ~/.agents/skills, the folder several agents share.
        case .codex: ".agents/skills"
        case .cursor: ".cursor/skills"
        case .gemini: ".gemini/skills"
        case .copilot: ".copilot/skills"
        case .windsurf: ".codeium/windsurf/skills"
        case .opencode: ".config/opencode/skills"
        }
    }

    /// Run-tracking hooks: the file the agent documents for them, the events Kilobat listens to, and `--agent`.
    public var hooks: AgentHooks? {
        switch self {
        case .claude: AgentHooks(file: ".claude/settings.json", events: ["SessionStart", "UserPromptSubmit", "Notification", "Stop", "StopFailure", "SessionEnd"], agent: "claude")
        case .codex: AgentHooks(file: ".codex/hooks.json", events: ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop"], agent: "codex")
        case .gemini: AgentHooks(file: ".gemini/settings.json", events: ["SessionStart", "BeforeAgent", "Notification", "AfterAgent"], agent: "gemini")
        default: nil
        }
    }
}

public struct AgentHooks: Equatable, Sendable {
    /// Relative to the home folder.
    public let file: String
    public let events: [String]
    public let agent: String

    /// `/opt/homebrew/bin/kilobat agent-event --agent claude --stdin-json`. A full path, because an agent started from
    /// the Dock doesn't get the shell's PATH.
    public func command(kilobat: String) -> String {
        AgentConnector.shellWord(kilobat) + " agent-event --agent " + agent + " --stdin-json"
    }
}

/// Where to look: the home folder, the Applications folders and the folders command-line agents install into.
/// Tests point it at a temporary folder.
public struct AgentEnvironment: Sendable {
    public var home: URL
    public var applications: [String]
    public var bin: [String]

    public init(home: URL, applications: [String]? = nil, bin: [String]? = nil) {
        self.home = home
        self.applications = applications ?? ["/Applications", home.appendingPathComponent("Applications").path]
        let h = home.path
        self.bin = bin ?? ["/opt/homebrew/bin", "/usr/local/bin", h + "/.local/bin", h + "/.claude/local", h + "/.npm-global/bin", h + "/.bun/bin", h + "/.volta/bin", h + "/.opencode/bin"]
    }

    public static var current: AgentEnvironment { AgentEnvironment(home: URL(fileURLWithPath: NSHomeDirectory())) }

    public func url(_ relative: String) -> URL { home.appendingPathComponent(relative) }

    func app(_ names: [String]) -> String? {
        for folder in applications { for name in names { let path = folder + "/" + name; if FileManager.default.fileExists(atPath: path) { return path } } }
        return nil
    }

    func tool(_ name: String) -> String? {
        bin.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The Claude app's chat configuration, the documented place for a local MCP server.
    var claudeChatConfig: URL { url("Library/Application Support/Claude/claude_desktop_config.json") }
    var claudeExtensions: URL { url("Library/Application Support/Claude/Claude Extensions") }
}

/// An agent found on this Mac.
public struct DetectedAgent: Equatable, Sendable, Identifiable {
    public let kind: AgentKind
    /// As people know it: Claude, Codex, Cursor, VS Code.
    public let name: String
    /// The app whose icon to show, when there is one.
    public let appPath: String?
    /// The Claude app, whose chat gets Kilobat's tools as an MCP server.
    public let chat: Bool
    public var id: String { kind.rawValue }

    public init(kind: AgentKind, name: String, appPath: String?, chat: Bool = false) {
        self.kind = kind; self.name = name; self.appPath = appPath; self.chat = chat
    }
}

public enum AgentPartState: String, Equatable, Sendable { case missing, current, outdated }

/// What an agent has of Kilobat right now.
public struct AgentConnection: Equatable, Sendable {
    public var skills: AgentPartState
    /// Nil for an agent without hooks.
    public var hooks: AgentPartState?
    /// The Claude app's chat tools; nil elsewhere.
    public var chat: AgentPartState?
    /// Codex runs new hooks only once someone approves them in its /hooks screen.
    public var hooksNeedReview = false

    public init(skills: AgentPartState, hooks: AgentPartState? = nil, chat: AgentPartState? = nil, hooksNeedReview: Bool = false) {
        self.skills = skills; self.hooks = hooks; self.chat = chat; self.hooksNeedReview = hooksNeedReview
    }

    public enum Overall: Equatable, Sendable { case off, partial, connected }
    public var overall: Overall {
        let parts = [skills] + [hooks, chat].compactMap { $0 }
        if parts.allSatisfy({ $0 == .current }) { return .connected }
        if parts.allSatisfy({ $0 == .missing }) { return .off }
        return .partial
    }
}

public struct AgentConnectError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Detection

public enum AgentDetector {
    /// The agents on this Mac, in a fixed order. One Claude row covers the Claude app (whose Claude Code shares
    /// ~/.claude with the command) and the `claude` command.
    public static func detect(in env: AgentEnvironment = .current) -> [DetectedAgent] {
        var found: [DetectedAgent] = []
        let claudeApp = env.app(["Claude.app"])
        if claudeApp != nil || env.tool("claude") != nil {
            found.append(DetectedAgent(kind: .claude, name: claudeApp != nil ? "Claude" : "Claude Code", appPath: claudeApp, chat: claudeApp != nil))
        }
        let codexApp = env.app(["Codex.app"])
        let chatGPTCodex = env.app(["ChatGPT.app"]).map { $0 + "/Contents/Resources/codex-cli/bin/codex" }.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
        if codexApp != nil || env.tool("codex") != nil || chatGPTCodex != nil {
            // Codex lives in the ChatGPT app too, so ChatGPT's icon stands for it when there's no Codex app.
            found.append(DetectedAgent(kind: .codex, name: "Codex", appPath: codexApp ?? env.app(["ChatGPT.app"])))
        }
        let cursor = env.app(["Cursor.app"])
        if cursor != nil || env.tool("cursor-agent") != nil { found.append(DetectedAgent(kind: .cursor, name: "Cursor", appPath: cursor)) }
        if env.tool("gemini") != nil { found.append(DetectedAgent(kind: .gemini, name: "Gemini", appPath: nil)) }
        let code = env.app(["Visual Studio Code.app", "Visual Studio Code - Insiders.app"])
        if code != nil || env.tool("copilot") != nil {
            found.append(DetectedAgent(kind: .copilot, name: code != nil ? "VS Code" : "Copilot CLI", appPath: code))
        }
        if let windsurf = env.app(["Windsurf.app"]) { found.append(DetectedAgent(kind: .windsurf, name: "Windsurf", appPath: windsurf)) }
        if env.tool("opencode") != nil { found.append(DetectedAgent(kind: .opencode, name: "OpenCode", appPath: nil)) }
        return found
    }
}

// MARK: - The bundled skills

/// The skills folder inside Kilobat.app (the repo's skills/), one folder per skill with a SKILL.md.
public struct AgentSkillBundle: Sendable {
    public let root: URL
    /// Skill name and a hash of its files.
    public let skills: [(name: String, hash: String)]

    public init?(root: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return nil }
        let skills = names.sorted().filter { fm.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent("SKILL.md").path) }
            .compactMap { name in AgentConnector.hash(of: root.appendingPathComponent(name)).map { (name: name, hash: $0) } }
        guard !skills.isEmpty else { return nil }
        self.root = root; self.skills = skills
    }

    public var names: [String] { skills.map(\.name) }
}

// MARK: - Status, connecting and disconnecting

public enum AgentConnector {
    /// Left in each skill folder Kilobat copies, so a later version can tell its own folders from someone else's.
    public static let marker = ".kilobat-skill"
    static let claudePlugin = "kilobat@kilobat"

    public static func status(of agent: DetectedAgent, bundle: AgentSkillBundle, env: AgentEnvironment = .current) -> AgentConnection {
        var connection = AgentConnection(skills: skillState(agent.kind, bundle: bundle, env: env))
        if let hooks = agent.kind.hooks {
            let root = (try? readJSON(env.url(hooks.file))) ?? nil
            let present = root.map { hookEvents(in: $0) } ?? []
            connection.hooks = present.isSuperset(of: hooks.events) ? .current : present.isEmpty ? .missing : .outdated
            if agent.kind == .codex, connection.hooks != .missing, let root {
                connection.hooksNeedReview = codexNeedsReview(hooksFile: env.url(hooks.file), root: root, config: try? String(contentsOf: env.url(".codex/config.toml"), encoding: .utf8))
            }
        }
        if agent.chat { connection.chat = chatState(env) }
        return connection
    }

    /// Adds whatever is missing or out of date. Skills are replaced with the app's copies; hooks are added beside the
    /// agent's other hooks; the Claude app's chat gets the MCP server. `kilobat` is the command's full path.
    public static func connect(_ agent: DetectedAgent, bundle: AgentSkillBundle, kilobat: String, env: AgentEnvironment = .current) throws {
        // Every file is read and changed in memory first, so one that can't be read stops the whole connect untouched.
        var writes: [(OrderedJSON, URL)] = []
        if let hooks = agent.kind.hooks {
            let file = env.url(hooks.file)
            let root = try readJSON(file) ?? .object([])
            let updated = try addingHooks(to: root, hooks: hooks, kilobat: kilobat)
            if updated != root { writes.append((updated, file)) }
        }
        if agent.chat {
            let file = env.claudeChatConfig
            let root = try readJSON(file) ?? .object([])
            let updated = try addingChatServer(to: root, kilobat: kilobat)
            if updated != root { writes.append((updated, file)) }
        }
        if !(agent.kind == .claude && claudePluginInstalled(env)) { try installSkills(bundle, into: env.url(agent.kind.skillsFolder)) }
        for (value, file) in writes { try writeJSON(value, to: file) }
    }

    /// Takes out Kilobat's skills, hooks and chat server, and nothing else.
    public static func disconnect(_ agent: DetectedAgent, bundle: AgentSkillBundle, env: AgentEnvironment = .current) throws {
        try removeSkills(bundle, from: env.url(agent.kind.skillsFolder))
        if let hooks = agent.kind.hooks, let root = try readJSON(env.url(hooks.file)) {
            let updated = removingHooks(from: root)
            if updated != root { try writeJSON(updated, to: env.url(hooks.file)) }
        }
        if agent.chat, let root = try readJSON(env.claudeChatConfig) {
            let updated = removingChatServer(from: root)
            if updated != root { try writeJSON(updated, to: env.claudeChatConfig) }
        }
    }

    /// After an app update: brings the skills of an agent someone connected up to the app's copies. Hooks and chat
    /// settings are left as they are.
    public static func refreshSkills(_ agent: DetectedAgent, bundle: AgentSkillBundle, env: AgentEnvironment = .current) throws {
        guard !(agent.kind == .claude && claudePluginInstalled(env)) else { return }
        let folder = env.url(agent.kind.skillsFolder)
        // Leave alone a folder whose skills someone has taken out by hand.
        guard bundle.names.contains(where: { exists(folder.appendingPathComponent($0)) }) else { return }
        if skillState(agent.kind, bundle: bundle, env: env) != .current || staleSkills(bundle, in: folder).count > 0 { try installSkills(bundle, into: folder) }
    }

    // MARK: Skills

    static func skillState(_ kind: AgentKind, bundle: AgentSkillBundle, env: AgentEnvironment) -> AgentPartState {
        if kind == .claude && claudePluginInstalled(env) { return .current }
        let folder = env.url(kind.skillsFolder)
        let installed = bundle.skills.map { skill -> AgentPartState in
            let path = folder.appendingPathComponent(skill.name)
            guard exists(path) else { return .missing }
            return hash(of: path.resolvingSymlinksInPath()) == skill.hash ? .current : .outdated
        }
        if installed.allSatisfy({ $0 == .current }) { return .current }
        if installed.allSatisfy({ $0 == .missing }) { return .missing }
        return .outdated
    }

    /// Copies each skill in beside the agent's others, replacing an older copy (or a skills.sh link) of the same name,
    /// and removes skills an earlier Kilobat put there that the app no longer has.
    static func installSkills(_ bundle: AgentSkillBundle, into folder: URL) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in staleSkills(bundle, in: folder) { try fm.removeItem(at: folder.appendingPathComponent(name)) }
            for skill in bundle.skills {
                let destination = folder.appendingPathComponent(skill.name)
                let staging = folder.appendingPathComponent(".\(skill.name).kilobat-new")
                if exists(staging) { try fm.removeItem(at: staging) }
                try fm.copyItem(at: bundle.root.appendingPathComponent(skill.name), to: staging)
                try Data("Copied by the Kilobat app, which keeps it up to date.\n".utf8).write(to: staging.appendingPathComponent(marker))
                if exists(destination) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: staging, to: destination)
            }
        } catch {
            throw AgentConnectError(String(localized: "Kilobat couldn’t write to \(abbreviated(folder.path)).", comment: "Connect agents: error; the argument is a folder or file such as ~/.claude/skills"))
        }
    }

    static func removeSkills(_ bundle: AgentSkillBundle, from folder: URL) throws {
        let fm = FileManager.default
        do {
            for name in bundle.names + staleSkills(bundle, in: folder) where exists(folder.appendingPathComponent(name)) {
                try fm.removeItem(at: folder.appendingPathComponent(name))
            }
        } catch {
            throw AgentConnectError(String(localized: "Kilobat couldn’t remove its skills from \(abbreviated(folder.path)).", comment: "Connect agents: error; the argument is a folder such as ~/.claude/skills"))
        }
    }

    /// Folders an earlier Kilobat copied (they hold the marker) for skills the app no longer has.
    static func staleSkills(_ bundle: AgentSkillBundle, in folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !bundle.names.contains($0) && !$0.hasPrefix(".") && FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).appendingPathComponent(marker).path) }
    }

    /// A hash of a skill folder's files and their paths, leaving out the marker and Finder's .DS_Store.
    static func hash(of folder: URL) -> String? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return nil }
        var files: [(String, URL)] = []
        let base = folder.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let name = url.lastPathComponent
            guard name != marker, name != ".DS_Store" else { continue }
            let path = url.standardizedFileURL.path
            files.append((path.hasPrefix(base) ? String(path.dropFirst(base.count)) : name, url))
        }
        guard !files.isEmpty else { return nil }
        var hasher = SHA256()
        for (relative, url) in files.sorted(by: { $0.0 < $1.0 }) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            hasher.update(data: Data(relative.utf8)); hasher.update(data: Data([0]))
            hasher.update(data: data); hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func claudePluginInstalled(_ env: AgentEnvironment) -> Bool {
        guard let root = try? readJSON(env.url(".claude/plugins/installed_plugins.json")) else { return false }
        return root["plugins"]?[claudePlugin] != nil
    }

    // MARK: Hooks

    static func isKilobatHook(_ hook: OrderedJSON) -> Bool {
        guard let command = hook["command"]?.string else { return false }
        return command.contains("kilobat") && command.contains(" agent-event")
    }

    /// The events that already run `kilobat agent-event`.
    public static func hookEvents(in root: OrderedJSON) -> Set<String> {
        guard let events = root["hooks"]?.members else { return [] }
        return Set(events.filter { event in
            (event.value.array ?? []).contains { group in (group["hooks"]?.array ?? []).contains(where: isKilobatHook) }
        }.map(\.key))
    }

    /// Adds one group per missing event, after the agent's existing groups, so the hooks someone already has keep
    /// their places (Codex remembers which hooks were approved by their position).
    public static func addingHooks(to root: OrderedJSON, hooks: AgentHooks, kilobat: String) throws -> OrderedJSON {
        guard root.isObject else { throw AgentConnectError(String(localized: "The agent’s settings file isn’t in the expected format, so Kilobat left it unchanged.", comment: "Connect agents: error")) }
        var root = root
        var events = root["hooks"] ?? .object([])
        guard events.isObject else { throw AgentConnectError(String(localized: "The agent’s settings file isn’t in the expected format, so Kilobat left it unchanged.", comment: "Connect agents: error")) }
        let present = hookEvents(in: root)
        let entry = OrderedJSON.object([.init("hooks", .array([.object([.init("type", .string("command")), .init("command", .string(hooks.command(kilobat: kilobat)))])]))])
        for event in hooks.events where !present.contains(event) {
            var groups = events[event]?.array ?? []
            groups.append(entry)
            events[event] = .array(groups)
        }
        root["hooks"] = events
        return root
    }

    /// Takes out every hook that runs `kilobat agent-event`, and any group or event that leaves empty.
    public static func removingHooks(from root: OrderedJSON) -> OrderedJSON {
        guard var events = root["hooks"]?.members else { return root }
        events = events.compactMap { event in
            guard let groups = event.value.array else { return event }
            let kept = groups.compactMap { group -> OrderedJSON? in
                guard let hooks = group["hooks"]?.array, hooks.contains(where: isKilobatHook) else { return group }
                let others = hooks.filter { !isKilobatHook($0) }
                if others.isEmpty { return nil }
                var group = group; group["hooks"] = .array(others); return group
            }
            if kept.isEmpty && !groups.isEmpty { return nil }
            return .init(event.key, .array(kept))
        }
        var root = root
        root["hooks"] = events.isEmpty ? nil : .object(events)
        return root
    }

    /// Codex records approved hooks in config.toml as `[hooks.state."<file>:<event>:<group>:<hook>"]`.
    static func codexNeedsReview(hooksFile: URL, root: OrderedJSON, config: String?) -> Bool {
        guard let config, let events = root["hooks"]?.members else { return true }
        for event in events {
            for (g, group) in (event.value.array ?? []).enumerated() {
                for (h, hook) in (group["hooks"]?.array ?? []).enumerated() where isKilobatHook(hook) {
                    if !config.contains("\"\(hooksFile.path):\(snakeCase(event.key)):\(g):\(h)\"") { return true }
                }
            }
        }
        return false
    }

    static func snakeCase(_ name: String) -> String {
        var out = ""
        for character in name {
            if character.isUppercase, !out.isEmpty { out += "_" }
            out += character.lowercased()
        }
        return out
    }

    // MARK: The Claude app's chat

    static func chatState(_ env: AgentEnvironment) -> AgentPartState {
        // Installed from the .mcpb bundle instead.
        if let names = try? FileManager.default.contentsOfDirectory(atPath: env.claudeExtensions.path), names.contains(where: { $0.lowercased().contains("kilobat") }) { return .current }
        guard let root = (try? readJSON(env.claudeChatConfig)) ?? nil, let server = root["mcpServers"]?["kilobat"] else { return .missing }
        guard let command = server["command"]?.string else { return .outdated }
        return command == "kilobat" || FileManager.default.isExecutableFile(atPath: command) ? .current : .outdated
    }

    public static func addingChatServer(to root: OrderedJSON, kilobat: String) throws -> OrderedJSON {
        guard root.isObject else { throw AgentConnectError(String(localized: "Claude’s settings file isn’t in the expected format, so Kilobat left it unchanged.", comment: "Connect agents: error")) }
        var root = root
        var servers = root["mcpServers"] ?? .object([])
        guard servers.isObject else { throw AgentConnectError(String(localized: "Claude’s settings file isn’t in the expected format, so Kilobat left it unchanged.", comment: "Connect agents: error")) }
        if let current = servers["kilobat"]?["command"]?.string, current == kilobat || (current == "kilobat") { return root }
        servers["kilobat"] = .object([.init("command", .string(kilobat)), .init("args", .array([.string("mcp")]))])
        root["mcpServers"] = servers
        return root
    }

    public static func removingChatServer(from root: OrderedJSON) -> OrderedJSON {
        guard var servers = root["mcpServers"], servers["kilobat"] != nil else { return root }
        servers["kilobat"] = nil
        var root = root
        root["mcpServers"] = servers
        return root
    }

    // MARK: Files

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Nil when the file doesn't exist or is empty; an error when it can't be read as JSON, so it is never overwritten.
    static func readJSON(_ url: URL) throws -> OrderedJSON? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw AgentConnectError(String(localized: "Kilobat couldn’t read \(abbreviated(url.path)), so it left it unchanged.", comment: "Connect agents: error; the argument is a file such as ~/.claude/settings.json"))
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        do { return try OrderedJSON.parse(text) }
        catch { throw AgentConnectError(String(localized: "\(abbreviated(url.path)) isn’t valid JSON, so Kilobat left it unchanged.", comment: "Connect agents: error; the argument is a file such as ~/.claude/settings.json")) }
    }

    /// Written whole to a temporary file first, then moved over the old one, keeping its permissions.
    static func writeJSON(_ value: OrderedJSON, to url: URL) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let permissions = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions]
            // A settings file that is a link (to a dotfiles repo, say) is written where the link points.
            let target = url.resolvingSymlinksInPath()
            var text = value.serialized()
            // Keep the file's own ending: Claude writes its files without a final newline.
            if let old = try? Data(contentsOf: target), let last = old.last, last != UInt8(ascii: "\n") { text.removeLast() }
            try Data(text.utf8).write(to: target, options: .atomic)
            if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
        } catch {
            throw AgentConnectError(String(localized: "Kilobat couldn’t write to \(abbreviated(url.path)).", comment: "Connect agents: error; the argument is a folder or file such as ~/.claude/skills"))
        }
    }

    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func shellWord(_ value: String) -> String {
        let plain = value.allSatisfy { $0.isLetter || $0.isNumber || "/._-+".contains($0) }
        return plain ? value : "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
