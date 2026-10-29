import AppKit
import Darwin

/// Presentation attribution only: ownership never replaces a process's firewall identity.
public enum ProcessOwnership {
    public static func outerApplication(in path: String) -> String? {
        let parts = URL(fileURLWithPath: path).standardized.pathComponents
        guard let end = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return NSString.path(withComponents: Array(parts[...end]))
    }

    public static func executablePath(pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    public enum Kind: Int, Sendable, Comparable {
        case app, tool, system
        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }
    /// Apps people open, command-line tools they or their agents run, or macOS's own services, from where the code lives.
    public static func kind(bundlePath: String?, executable: String?) -> Kind {
        if let bundle = bundlePath, bundle.hasSuffix(".app"), !bundle.hasPrefix("/System/Library/") { return .app }
        let path = executable ?? bundlePath ?? ""
        let system = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/", "/Library/Application Support/Apple/"]
        return system.contains(where: path.hasPrefix) || path.isEmpty ? .system : .tool
    }

    public static func applicationPath(pid: Int32) -> String? {
        var current = pid
        var visited = Set<Int32>()
        for _ in 0..<32 {
            guard current > 1, visited.insert(current).inserted else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_uid == getuid() else { return nil }
            var path = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(current, &path, UInt32(path.count)) > 0,
               let owner = outerApplication(in: String(cString: path)) { return owner }
            current = Int32(info.pbi_ppid)
        }
        return nil
    }
}
