import AppKit
import Darwin
import Foundation

/// Which SSH, Mosh and remote desktop sessions are open, without the microphone and without reading a byte of them.
///
/// SSH and Mosh are found by process: an `ssh` or `mosh-client` with a terminal of its own (a controlling tty, or a
/// terminal app among its parents) and no sign of being a copy, a tunnel or git. Remote desktop apps are found by bundle
/// ID or process name. The host comes from the process's socket peer, as nettop lists it. Whether a session counts is
/// decided later from its traffic: input sent while the app holding it was in front.
public enum RemoteSessionDetector {
    /// A process as `ps -o pid,ppid,tty,args` would show it, with what the scan learned about its parents.
    public struct Process: Sendable, Equatable {
        public let pid: Int32
        public let ppid: Int32
        /// The executable's file name: ssh, mosh-client, parsecd.
        public let name: String
        public let args: [String]
        /// Has a controlling terminal.
        public let tty: Bool
        /// The parent process's file name: zsh, scp, git.
        public var parent: String?
        /// The bundle ID of the app among its parents, such as com.apple.Terminal.
        public var app: String?
        public init(pid: Int32, ppid: Int32, name: String, args: [String], tty: Bool, parent: String? = nil, app: String? = nil) {
            self.pid = pid; self.ppid = ppid; self.name = name; self.args = args; self.tty = tty; self.parent = parent; self.app = app
        }
    }

    /// What an ssh process is for. Only `interactive` gets a report; `multiplexMaster` and `proxy` carry another's bytes.
    public enum SSHUse: String, Sendable, Equatable {
        /// A shell or a full-screen program someone types into.
        case interactive
        /// A single remote command, with no terminal: `ssh host uptime`, an editor's or agent's remote server.
        case command
        /// Port forwarding only (`-N`) or sent to the background (`-f`).
        case tunnel
        /// scp, sftp, rsync and sshfs.
        case transfer
        /// git fetch, pull and push over ssh.
        case git
        /// `ssh -O` talking to a ControlMaster.
        case control
        /// A ControlMaster holding the connection that interactive clients share.
        case multiplexMaster
        /// `ssh -W`, the hop under ProxyJump.
        case proxy
    }

    /// Terminal apps and editors with a terminal, by bundle ID prefix: an ssh under one of them is typed into.
    public static let terminals = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.github.wez.wezterm", "org.alacritty",
                                   "net.kovidgoyal.kitty", "dev.warp.Warp", "co.zeit.hyper", "org.tabby", "com.raphaelamorim.rio", "com.microsoft.VSCode",
                                   "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.exafunction.windsurf", "com.panic.Nova", "com.jetbrains.", "com.termius"]
    public static func isTerminal(_ bundleID: String?) -> Bool { bundleID.map { id in terminals.contains { id.hasPrefix($0) } } ?? false }

    /// Programs that run ssh to copy files.
    static let transferParents: Set<String> = ["scp", "sftp", "rsync", "sshfs", "rclone", "unison", "mutagen", "borg", "restic", "duplicity"]
    /// ssh options that take a value, from ssh(1).
    static let valued = Set("BbcDEeFIiJLlmOoPpQRSWw")

    /// What this ssh is for, from its arguments, its parent and whether it has a terminal.
    public static func classify(ssh process: Process) -> SSHUse {
        let args = process.args
        // A ControlMaster renames itself "ssh: /path/to/socket [mux]".
        let joined = args.joined(separator: " ")
        if joined.hasPrefix("ssh:"), joined.contains("[mux]") { return .multiplexMaster }
        let parent = process.parent.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() } ?? ""
        if parent == "git" || parent.hasPrefix("git-") { return .git }
        if transferParents.contains(parent) { return .transfer }
        var flags = Set<Character>(), options: [String] = [], positional: [String] = [], index = 1
        while index < args.count {
            let arg = args[index]
            if !positional.isEmpty { positional.append(arg); index += 1; continue }
            if arg == "--" { positional = Array(args[(index + 1)...]); break }
            guard arg.hasPrefix("-"), arg.count > 1 else { positional.append(arg); index += 1; continue }
            // Flags run together (-NfL 8080:…); the first that takes a value takes the rest, or the next argument.
            for (offset, flag) in arg.dropFirst().enumerated() {
                flags.insert(flag)
                guard valued.contains(flag) else { continue }
                let rest = String(arg.dropFirst(offset + 2))
                let value = rest.isEmpty ? (index + 1 < args.count ? args[index + 1] : "") : rest
                if rest.isEmpty { index += 1 }
                if flag == "o" { options.append(value.lowercased()) }
                break
            }
            index += 1
        }
        if flags.contains("O") { return .control }
        if flags.contains("W") { return .proxy }
        if flags.contains("N") || flags.contains("f") { return .tunnel }
        if flags.contains("s") { return .transfer }
        let command = positional.dropFirst()
        if let remote = command.first {
            if remote.hasPrefix("git-") { return .git }
            if ["scp", "rsync", "sftp-server", "internal-sftp"].contains(URL(fileURLWithPath: remote).lastPathComponent) { return .transfer }
        }
        if options.contains("requesttty=no") || options.contains("sessiontype=none") { return command.isEmpty ? .tunnel : .command }
        let forcedTTY = flags.contains("t") || options.contains("requesttty=yes") || options.contains("requesttty=force")
        if flags.contains("T") || (!command.isEmpty && !forcedTTY) { return .command }
        return process.tty || isTerminal(process.app) ? .interactive : .command
    }

    /// The host as typed, without the user: `me@build.example.com` and `ssh://me@build.example.com:2222` read build.example.com.
    public static func destination(ssh args: [String]) -> String? {
        var index = 1
        while index < args.count {
            let arg = args[index]
            if arg == "--" { return index + 1 < args.count ? host(args[index + 1]) : nil }
            guard arg.hasPrefix("-"), arg.count > 1 else { return host(arg) }
            if let flag = arg.dropFirst().first(where: { valued.contains($0) }), arg.hasSuffix(String(flag)) { index += 1 }
            index += 1
        }
        return nil
    }
    static func host(_ raw: String) -> String {
        var value = raw
        if value.hasPrefix("ssh://") { value = String(value.dropFirst(6)) }
        if let at = value.lastIndex(of: "@") { value = String(value[value.index(after: at)...]) }
        if raw.hasPrefix("ssh://"), !value.hasPrefix("["), let colon = value.lastIndex(of: ":") { value = String(value[..<colon]) }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    /// mosh-client's arguments: `mosh-client -# 'build.example.com' | 203.0.113.5 60001`. The name the person typed, and the address and port.
    public static func mosh(_ args: [String]) -> (host: String?, address: String?, port: String?) {
        var name: String?
        if let mark = args.firstIndex(of: "-#") {
            let typed = args[(mark + 1)...].prefix { $0 != "|" }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
            name = typed.last { !$0.hasPrefix("-") && !$0.isEmpty }.map(host)
        }
        let tail = args.suffix(2)
        guard tail.count == 2, Int(tail.last!) != nil, tail.first!.contains(where: { $0 == "." || $0 == ":" }) else { return (name, nil, nil) }
        return (name ?? tail.first, tail.first, tail.last)
    }

    /// `ps -axww -o pid=,ppid=,tty=,args=` lines, for recorded fixtures: `??` means no terminal.
    public static func parse(ps text: String) -> [Process] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 4, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { return nil }
            let args = Array(parts[3...])
            let name = args[0].hasPrefix("ssh:") ? "ssh" : URL(fileURLWithPath: args[0]).lastPathComponent
            return Process(pid: pid, ppid: ppid, name: name, args: args, tty: parts[2] != "??")
        }
    }

    /// Each process's parent's name, looked up in the same list.
    public static func linkParents(_ processes: [Process]) -> [Process] {
        let names = Dictionary(processes.map { ($0.pid, $0.name) }) { first, _ in first }
        return processes.map { var copy = $0; if copy.parent == nil { copy.parent = names[copy.ppid] }; return copy }
    }

    // MARK: Remote desktop apps

    /// Remote desktop viewers, by bundle ID prefix and process name. Chrome Remote Desktop runs inside a browser tab,
    /// where its traffic can't be told from the browser's, so it isn't here.
    public static let viewers: [(kind: RemoteSessionReport.Kind, bundles: [String], processes: [String])] = [
        (.screenSharing, ["com.apple.ScreenSharing"], ["Screen Sharing"]),
        (.parsec, ["tv.parsec."], ["parsecd", "Parsec"]),
        (.jump, ["com.p5sys.jump.mac.viewer"], ["Jump Desktop"]),
        (.windowsApp, ["com.microsoft.rdc."], ["Windows App", "Microsoft Remote Desktop"]),
        (.anyDesk, ["com.philandro.anydesk"], ["AnyDesk"]),
        (.teamViewer, ["com.teamviewer."], ["TeamViewer"]),
        (.rustDesk, ["com.carriez.rustdesk", "com.carriez.RustDesk"], ["RustDesk", "rustdesk"]),
    ]

    public static func viewer(bundleID: String?, process: String?) -> RemoteSessionReport.Kind? {
        viewers.first { entry in
            (bundleID.map { id in entry.bundles.contains { id.hasPrefix($0) } } ?? false) || (process.map(entry.processes.contains) ?? false)
        }?.kind
    }

    // MARK: Sockets

    /// One connection of one process from `nettop -p <pid> -J bytes_in,bytes_out,rtt_avg`, with TCP's smoothed round trip.
    public struct Socket: Sendable, Equatable {
        public let pid: Int32
        public let transport: String
        public let address: String
        public let port: String
        public let received: UInt64
        public let sent: UInt64
        /// TCP's smoothed round trip in ms; nil for UDP.
        public let rtt: Double?
        public var total: UInt64 { received + sent }
    }

    /// nettop's rows: a process row (`ssh.123,in,out,,`) then its connections (`tcp4 a:1<->b:22,in,out,31.5 ms,4 ms,`).
    /// Columns come in nettop's own order, so they are read from its header.
    public static func sockets(nettop text: String) -> [Socket] {
        var pid: Int32?, columns: [String: Int] = [:], result: [Socket] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if fields.first == "" { for (index, name) in fields.enumerated() where !name.isEmpty { columns[name] = index }; continue }
            guard let head = fields.first else { continue }
            guard let arrow = head.range(of: "<->") else { pid = head.lastIndex(of: ".").flatMap { Int32(head[head.index(after: $0)...]) }; continue }
            guard let pid, let space = head.firstIndex(of: " ") else { continue }
            let proto = String(head[..<space])
            let (address, port) = TrafficRoute.endpoint(head[arrow.upperBound...], v6: proto.hasSuffix("6"))
            guard address != "*", port != "*", !port.isEmpty, !OpenConnections.isLoopback(address) else { continue }
            func value(_ name: String, _ fallback: Int) -> String { let index = columns[name] ?? fallback; return index < fields.count ? fields[index] : "" }
            // "41.50 ms", or "2354.62 m" when nettop cuts the column short.
            let rtt = Double(value("rtt_avg", 3).trimmingCharacters(in: .whitespaces).prefix { $0.isNumber || $0 == "." })
            result.append(Socket(pid: pid, transport: proto.hasPrefix("udp") ? "UDP" : "TCP", address: address, port: port,
                                 received: UInt64(value("bytes_in", 1)) ?? 0, sent: UInt64(value("bytes_out", 2)) ?? 0, rtt: rtt))
        }
        return result
    }

    /// The connection a session runs over: ssh's TCP one, Mosh's UDP one, a viewer's busiest; for Screen Sharing the
    /// VNC (5900–5999) or Apple Remote Desktop (3283) port first.
    public static func peer(_ kind: RemoteSessionReport.Kind, sockets: [Socket]) -> Socket? {
        let usable = sockets.filter { !TrafficRoute.isLinkLocalOrLoopback($0.address) }
        switch kind {
        case .ssh: return usable.filter { $0.transport == "TCP" }.max { $0.total < $1.total }
        case .mosh: return usable.filter { $0.transport == "UDP" }.max { $0.total < $1.total }
        case .screenSharing:
            let screen = usable.filter { $0.port == "3283" || (Int($0.port).map { (5900...5999).contains($0) } ?? false) }
            return (screen.isEmpty ? usable : screen).max { $0.total < $1.total }
        default: return usable.max { $0.total < $1.total }
        }
    }

    /// One snapshot of a process's connections, with TCP round trips.
    public static func sockets(pid: Int32) async -> [Socket] {
        let result = await CommandRunner.run("/usr/bin/nettop", ["-L", "1", "-n", "-x", "-p", String(pid), "-J", "bytes_in,bytes_out,rtt_avg"], timeout: 4)
        return sockets(nettop: result.output)
    }

    // MARK: Whether it counts

    /// One second of a session: what its own process moved, and whether the app it lives in was in front.
    public struct Second: Sendable, Equatable {
        public let at: Double
        public let up: Double
        public let down: Double
        public let front: Bool
        public init(at: Double, up: Double, down: Double, front: Bool) { self.at = at; self.up = up; self.down = down; self.front = front }
        /// Someone typed or clicked into it: it sent something while in front. Keystrokes only reach the app in front.
        public var input: Bool { front && up > 0 }
    }

    /// A session shorter than this isn't worth a report: a quick `ssh host` to check something.
    public static let shortest: TimeInterval = 60
    /// Seconds of input before a session counts: a few keystrokes for a terminal, more for a viewer, which also sends
    /// mouse moves. A tunnel, a copy or `git fetch` never sends input from a terminal in front for this long.
    public static func interactive(_ kind: RemoteSessionReport.Kind, seconds: [Second]) -> Bool {
        let input = seconds.filter(\.input).count
        guard kind.terminal else {
            // A viewer receives the screen: more down than up, or it's this Mac being shared out.
            let down = seconds.reduce(0) { $0 + $1.down }, up = seconds.reduce(0) { $0 + $1.up }
            return input >= 10 && down > up
        }
        return input >= 5
    }

    /// Long enough and typed into.
    public static func counts(_ kind: RemoteSessionReport.Kind, start: Date, end: Date, seconds: [Second]) -> Bool {
        end.timeIntervalSince(start) >= shortest && interactive(kind, seconds: seconds)
    }

    // MARK: Live scan

    /// Every ssh and mosh-client of this user, with arguments, tty, parent and enclosing app. Reads the process table
    /// directly; nothing is launched.
    public static func terminalProcesses() -> [Process] {
        var pids = [Int32](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        guard count > 0 else { return [] }
        var found: [Process] = []
        for pid in pids.prefix(count) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid() else { continue }
            let name = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard name == "ssh" || name == "mosh-client" else { continue }
            let parentName = Self.name(of: Int32(info.pbi_ppid))
            let app = ProcessOwnership.applicationPath(pid: pid).flatMap { Bundle(path: $0)?.bundleIdentifier }
            found.append(Process(pid: pid, ppid: Int32(info.pbi_ppid), name: name, args: arguments(pid) ?? [name],
                                 tty: info.pbi_flags & UInt32(PROC_FLAG_CONTROLT) != 0, parent: parentName, app: app))
        }
        return found
    }

    static func name(of pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// A process's arguments from KERN_PROCARGS2: argc, the executable path, then argv. Own processes only.
    static func arguments(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args.isEmpty ? nil : args
    }
}
