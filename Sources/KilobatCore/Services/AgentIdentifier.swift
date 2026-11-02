import Foundation
import Darwin

/// An AI agent Kilobat recognises from its executable, its command line or its app bundle.
public struct AgentIdentity: Codable, Hashable, Sendable {
    /// Short and stable, for `--agent` and JSON: claude, codex, cursor.
    public let id: String
    /// As Kilobat shows it: Claude Code, Codex, Cursor.
    public let name: String
    /// A desktop app, which may run all day; command-line agents run per task.
    public let app: Bool
    public init(id: String, name: String, app: Bool = false) { self.id = id; self.name = name; self.app = app }
}

/// Which process is an agent. Command-line agents by executable name (or, run by node, bun, deno or Python, by the
/// package or script they run); desktop apps by their bundle's main executable. Nothing is read beyond the path and arguments.
public enum AgentIdentifier {
    static let commands: [String: AgentIdentity] = {
        let list: [(String, String)] = [("claude", "Claude Code"), ("codex", "Codex"), ("cursor-agent", "Cursor Agent"), ("gemini", "Gemini CLI"),
                                        ("aider", "Aider"), ("opencode", "OpenCode"), ("goose", "Goose"), ("amp", "Amp"), ("droid", "Factory Droid"),
                                        ("qwen", "Qwen Code"), ("copilot", "Copilot CLI"), ("crush", "Crush"), ("cline", "Cline")]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.0, AgentIdentity(id: $0.0, name: $0.1)) })
    }()
    /// npm and PyPI packages whose entry point an interpreter runs.
    static let packages: [(marker: String, id: String)] = [
        ("@anthropic-ai/claude-code", "claude"), ("@openai/codex", "codex"), ("@google/gemini-cli", "gemini"), ("@qwen-code/qwen-code", "qwen"),
        ("opencode-ai", "opencode"), ("@sourcegraph/amp", "amp"), ("@github/copilot", "copilot"), ("@charmland/crush", "crush"), ("site-packages/aider/", "aider")]
    /// Desktop apps that run agents: their own and the commands, MCP servers and terminals they start.
    static let apps: [String: AgentIdentity] = [
        "Cursor.app": AgentIdentity(id: "cursor", name: "Cursor", app: true), "Windsurf.app": AgentIdentity(id: "windsurf", name: "Windsurf", app: true),
        "Claude.app": AgentIdentity(id: "claude-desktop", name: "Claude Desktop", app: true), "ChatGPT.app": AgentIdentity(id: "chatgpt", name: "ChatGPT", app: true)]

    public static func identify(path: String?, name: String, arguments: [String]? = nil) -> AgentIdentity? {
        let arguments = arguments ?? []
        // Claude Code also serves as a browser's native messaging host; that is the browser's helper, not an agent run.
        if arguments.contains("--chrome-native-host") { return nil }
        let executable = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? name
        if let agent = commands[executable] ?? commands[name] { return agent }
        // Claude Code's native installer names the binary after its version: ~/.local/share/claude/versions/2.1.3.
        if let path, path.contains("/claude/versions/") { return commands["claude"] }
        if let first = arguments.first, let agent = commands[URL(fileURLWithPath: first).lastPathComponent] { return agent }
        if let path, let agent = app(path) { return agent }
        guard interpreter(executable) || interpreter(name) else { return nil }
        // `node …/@openai/codex/bin/codex.js`, `bun …/bin/gemini`, `python3 -m aider`, `python3 ~/.local/bin/aider`.
        let rest = Array(arguments.dropFirst())
        if let index = rest.firstIndex(of: "-m"), index + 1 < rest.count, let agent = commands[rest[index + 1]] { return agent }
        for argument in rest.prefix(4) where !argument.hasPrefix("-") {
            if let match = packages.first(where: { argument.contains($0.marker) }) { return commands[match.id] }
            if let agent = commands[URL(fileURLWithPath: argument).lastPathComponent] { return agent }
        }
        return nil
    }

    static func interpreter(_ name: String) -> Bool {
        ["node", "bun", "deno", "python", "python3", "ruby"].contains(name) || (name.hasPrefix("python3.") && name.dropFirst(8).allSatisfy(\.isNumber))
    }

    /// The app's own executable, not a helper inside it: /Applications/Cursor.app/Contents/MacOS/Cursor.
    static func app(_ path: String) -> AgentIdentity? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[parts.count - 2] == "MacOS", parts[parts.count - 3] == "Contents" else { return nil }
        let bundle = parts[parts.count - 4]
        guard let agent = apps[bundle], parts.last == String(bundle.dropLast(4)) else { return nil }
        return agent
    }
}

/// A process's arguments, from KERN_PROCARGS2: argc, the executable path, padding, then argv. Same user only.
public enum ProcessArguments {
    public static func read(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: min(size, 262_144))
        size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parse(Array(buffer.prefix(size)))
    }

    static func parse(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > 4 else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = 4
        while index < bytes.count && bytes[index] != 0 { index += 1 }   // the executable path
        while index < bytes.count && bytes[index] == 0 { index += 1 }   // its padding
        var arguments: [String] = []
        while arguments.count < min(argc, 256) && index < bytes.count {
            let end = bytes[index...].firstIndex(of: 0) ?? bytes.count
            arguments.append(String(decoding: bytes[index..<end], as: UTF8.self))
            index = end + 1
        }
        return arguments
    }
}

/// Which agent started a process, by walking up its parents: what the filter asks when Protection blocks a connection
/// or the agent guard needs to know. Unlike `AgentProcessTree` it sees only the live parent chain, so a process an
/// agent started that was reparented to launchd (a daemonised server) no longer counts as the agent's.
public final class AgentLineage: @unchecked Sendable {
    public struct Process: Sendable, Equatable {
        public var ppid: Int32
        public var name: String
        public var start: UInt64
        public init(ppid: Int32, name: String, start: UInt64) { self.ppid = ppid; self.name = name; self.start = start }
    }
    public struct Lookup: Sendable {
        public var entry: @Sendable (Int32) -> Process?
        public var path: @Sendable (Int32) -> String?
        public var arguments: @Sendable (Int32) -> [String]?
        public init(entry: @escaping @Sendable (Int32) -> Process?, path: @escaping @Sendable (Int32) -> String?, arguments: @escaping @Sendable (Int32) -> [String]?) {
            self.entry = entry; self.path = path; self.arguments = arguments
        }

        /// Every user's processes: the filter runs as root.
        public static let live = Lookup(
            entry: { pid in
                var info = proc_bsdinfo()
                let size = Int32(MemoryLayout<proc_bsdinfo>.size)
                guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
                let long = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                let short = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                return Process(ppid: Int32(info.pbi_ppid), name: long.isEmpty ? short : long, start: info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec)
            },
            path: { pid in
                var buffer = [UInt8](repeating: 0, count: 4096)
                guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
                return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
            },
            arguments: { ProcessArguments.read($0) })
    }

    private let lookup: Lookup
    private let lock = NSLock()
    /// What each process is, by pid and start: the agent it is, or none. Bounded.
    private var identities: [String: AgentIdentity?] = [:]
    public init(lookup: Lookup = .live) { self.lookup = lookup }

    /// The nearest agent among the process and its parents. A desktop agent app's own main process is not its own
    /// agent run, only what it starts is; a command-line agent's own connections are.
    public func owner(pid: Int32) -> AgentOwner? {
        guard let first = lookup.entry(pid) else { return nil }
        var current = (pid: pid, entry: first), depth = 0
        while depth < 32 {
            if let agent = identity(current.pid, current.entry), !(agent.app && depth == 0) {
                return AgentOwner(agent: agent, pid: current.pid, process: depth == 0 ? first.name : Self.command(first.name, arguments: lookup.arguments(pid)))
            }
            let parent = current.entry.ppid
            guard parent > 1, parent != current.pid, let entry = lookup.entry(parent) else { return nil }
            current = (parent, entry); depth += 1
        }
        return nil
    }

    /// The command a person would name: npm for `node …/npm/bin/npm-cli.js`, pip for `python3 -m pip`, else the process.
    static func command(_ name: String, arguments: [String]?) -> String {
        guard AgentIdentifier.interpreter(name), let arguments else { return name }
        let rest = Array(arguments.dropFirst())
        if let index = rest.firstIndex(of: "-m"), index + 1 < rest.count { return rest[index + 1] }
        guard let script = rest.first(where: { !$0.hasPrefix("-") }) else { return name }
        var base = URL(fileURLWithPath: script).lastPathComponent
        for suffix in [".js", ".cjs", ".mjs", ".py", ".rb"] where base.hasSuffix(suffix) { base.removeLast(suffix.count) }
        if base.hasSuffix("-cli") { base.removeLast(4) }
        return base.isEmpty ? name : base
    }

    private func identity(_ pid: Int32, _ entry: Process) -> AgentIdentity? {
        let key = "\(pid)@\(entry.start)"
        if let known = lock.withLock({ identities[key] }) { return known }
        let path = lookup.path(pid)
        let executable = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? entry.name
        let needsArguments = AgentIdentifier.interpreter(entry.name) || AgentIdentifier.interpreter(executable)
            || AgentIdentifier.commands[entry.name] != nil || path?.contains("/claude/versions/") == true
        let agent = AgentIdentifier.identify(path: path, name: entry.name, arguments: needsArguments ? lookup.arguments(pid) : nil)
        lock.withLock {
            if identities.count > 4_096 { identities = [:] }
            identities[key] = .some(agent)
        }
        return agent
    }
}
