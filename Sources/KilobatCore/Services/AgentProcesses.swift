import Foundation
import Darwin

/// How SessionStore sees an agent's processes: its children, CPU time and executable. Tests swap in a made-up tree.
public struct ProcessProbe: Sendable {
    public var children: @Sendable (Int32) -> [Int32]
    /// User and system CPU time in nanoseconds; nil once the process is gone.
    public var cpuTime: @Sendable (Int32) -> UInt64?
    public var alive: @Sendable (Int32) -> Bool
    public var path: @Sendable (Int32) -> String?

    public init(children: @escaping @Sendable (Int32) -> [Int32], cpuTime: @escaping @Sendable (Int32) -> UInt64?,
                alive: @escaping @Sendable (Int32) -> Bool, path: @escaping @Sendable (Int32) -> String?) {
        self.children = children; self.cpuTime = cpuTime; self.alive = alive; self.path = path
    }

    public static let live = ProcessProbe(
        children: { pid in
            var children = [Int32](repeating: 0, count: 256)
            let count = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<Int32>.size))
            return count > 0 ? children.prefix(Int(count)).filter { $0 > 0 } : []
        },
        cpuTime: { pid in
            var info = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) } }
            guard status == 0 else { return nil }
            // In Mach ticks, which are not nanoseconds on Apple silicon.
            var base = mach_timebase_info_data_t(); mach_timebase_info(&base)
            return (info.ri_user_time + info.ri_system_time) * UInt64(base.numer) / UInt64(max(1, base.denom))
        },
        alive: { kill($0, 0) == 0 },
        path: { pid in
            var buffer = [UInt8](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        })

    /// Every process descended from `roots`, roots included.
    public func family(_ roots: [Int32]) -> Set<Int32> {
        var family = Set(roots), queue = roots
        while let pid = queue.popLast() {
            for child in children(pid) where family.insert(child).inserted { queue.append(child) }
        }
        return family
    }
}

/// Where an agent's executable came from, read from its path alone: no package manager runs.
/// Shows when two installs of one agent are around, such as codex from npm and from Homebrew.
public struct AgentInstall: Equatable, Sendable {
    public var executable: String
    /// Homebrew, npm (node 22.3.0), Claude app, ~/.local…; nil when the path says nothing.
    public var origin: String?
    public var version: String?
    /// Other executables with the same name in the usual install places.
    public var others: [String]

    public static func describe(_ path: String, home: String = NSHomeDirectory(),
                                exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                                read: (String) -> Data? = { FileManager.default.contents(atPath: $0) }) -> AgentInstall {
        let parts = path.split(separator: "/").map(String.init), name = parts.last ?? path
        func after(_ marker: String, _ offset: Int = 1) -> String? {
            parts.lastIndex(of: marker).flatMap { $0 + offset < parts.count ? parts[$0 + offset] : nil }
        }
        let isVersion = { (text: String) in text.range(of: #"^v?\d+(\.\d+)+$"#, options: .regularExpression) != nil }
        let node = zip(parts, parts.dropFirst()).first { ["node", "node-versions", "nodejs"].contains($0.0) && isVersion($0.1) }?.1
        var origin: String?, version: String?
        if after("Cellar") != nil { origin = "Homebrew"; version = after("Cellar", 2) }
        else if after("Caskroom") != nil { origin = "Homebrew cask"; version = after("Caskroom", 2) }
        else if parts.contains("node_modules") { origin = "npm" + (node.map { " (node \($0.hasPrefix("v") ? String($0.dropFirst()) : $0))" } ?? "") }
        else if parts.contains(".bun") { origin = "bun" }
        else if parts.contains(".cargo") { origin = "cargo" }
        else if let support = parts.firstIndex(of: "Application Support"), support + 1 < parts.count { origin = String(localized: "\(parts[support + 1]) app") }
        else if let bundle = parts.first(where: { $0.hasSuffix(".app") }) { origin = String(localized: "\(String(bundle.dropLast(4))) app") }
        else if path.hasPrefix(home + "/.local/") { origin = "~/.local" }
        // An npm package's own version, from its package.json; a cheap read.
        if version == nil, let modules = parts.lastIndex(of: "node_modules"), modules + 1 < parts.count {
            let depth = parts[modules + 1].hasPrefix("@") ? 3 : 2
            let root = "/" + parts.prefix(modules + depth).joined(separator: "/") + "/package.json"
            version = read(root).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["version"] as? String
        }
        if version == nil { version = parts.dropLast().last(where: isVersion).map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 } }
        let places = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.npm-global/bin", home + "/.bun/bin",
                      home + "/.cargo/bin", home + "/.volta/bin", home + "/.claude/local"]
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let others = places.map { $0 + "/" + name }.filter { exists($0) && URL(fileURLWithPath: $0).resolvingSymlinksInPath().path != real }
        return AgentInstall(executable: path, origin: origin, version: version, others: others)
    }
}
