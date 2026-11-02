import Foundation
import Darwin

/// One process as the tree sees it.
public struct ProcessEntry: Equatable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    /// The executable's name, up to 32 characters (nettop cuts at 15).
    public var name: String
    public var start: Date?
    public init(pid: Int32, ppid: Int32, name: String, start: Date?) { self.pid = pid; self.ppid = ppid; self.name = name; self.start = start }
}

/// Where the tree reads processes from. Tests swap in a made-up tree.
public struct ProcessSource: Sendable {
    public var all: @Sendable () -> [Int32]
    public var entry: @Sendable (Int32) -> ProcessEntry?
    public var children: @Sendable (Int32) -> [Int32]
    public var path: @Sendable (Int32) -> String?
    public var arguments: @Sendable (Int32) -> [String]?
    public var cwd: @Sendable (Int32) -> String?

    public init(all: @escaping @Sendable () -> [Int32], entry: @escaping @Sendable (Int32) -> ProcessEntry?, children: @escaping @Sendable (Int32) -> [Int32],
                path: @escaping @Sendable (Int32) -> String?, arguments: @escaping @Sendable (Int32) -> [String]?, cwd: @escaping @Sendable (Int32) -> String?) {
        self.all = all; self.entry = entry; self.children = children; self.path = path; self.arguments = arguments; self.cwd = cwd
    }

    /// This user's processes only: the agents worth logging run as the person, and other users' arguments aren't ours to read.
    public static let live = ProcessSource(
        all: {
            var pids = [Int32](repeating: 0, count: 8192)
            let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
            return count > 0 ? pids.prefix(Int(count)).filter { $0 > 1 } : []
        },
        entry: { pid in
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            let long = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let short = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let start = Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
            return ProcessEntry(pid: pid, ppid: Int32(info.pbi_ppid), name: long.isEmpty ? short : long, start: start)
        },
        children: { pid in
            var children = [Int32](repeating: 0, count: 512)
            let count = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<Int32>.size))
            return count > 0 ? children.prefix(Int(count)).filter { $0 > 0 } : []
        },
        path: { ProcessOwnership.executablePath(pid: $0) },
        arguments: { ProcessArguments.read($0) },
        cwd: { pid in
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
            let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return path.isEmpty ? nil : path
        })
}

/// Which agent each process belongs to: every descendant of an agent's process (through shells, npm, make…) is
/// the nearest agent's, and stays so once seen even after it is reparented to launchd. Walked every half second; with
/// `watchForks`, the kernel also reports each fork of a process already in a tree (kqueue), so a curl that runs for
/// a tenth of a second is placed while it runs, and nettop's rows about it after it exits still count.
public final class AgentProcessTree: @unchecked Sendable {
    public struct Root: Equatable, Sendable {
        public var pid: Int32
        public var start: Date?
        public var agent: AgentIdentity
        public var path: String?
        public var cwd: String?
        public var key: String { AgentProcessTree.key(pid, start) }
    }
    public struct Member: Equatable, Sendable {
        /// The agent process's key, `pid@start`.
        public var root: String
        public var pid: Int32
        public var start: Date?
        public var process: String
    }

    public static func key(_ pid: Int32, _ start: Date?) -> String { "\(pid)@\(start.map { String(Int64($0.timeIntervalSince1970 * 1000)) } ?? "?")" }

    private let source: ProcessSource
    private let lock = NSLock()
    private var roots: [Int32: Root] = [:]
    private var members: [Int32: (member: Member, seen: Date)] = [:]
    /// Processes known not to be agents, by pid and start, so a full scan reads each one's path and arguments once.
    private var notAgents: [String: Date] = [:]
    /// Pids an ancestor walk found outside every agent, until the roots change.
    private var outside: Set<String> = []
    private var lastDiscovery = Date.distantPast
    /// Agents whose process, or a process it started, ran at the last walk.
    private var active: Set<String> = []
    /// Exited members are kept this long, for nettop's last rows about them.
    static let keepExited: TimeInterval = 30

    private var forks: ForkWatcher?

    public init(source: ProcessSource = .live, watchForks: Bool = false) {
        self.source = source
        if watchForks { forks = ForkWatcher { [weak self] pid, event in self?.changed(pid, event) } }
    }

    /// A process in a tree forked or ran a new program: place its new children now, before they can exit.
    private func changed(_ pid: Int32, _ event: ForkWatcher.Event) {
        guard let parent = lock.withLock({ members[pid]?.member }) else { return }
        switch event {
        case .exec:
            if let entry = source.entry(pid), entry.start == parent.start { lock.withLock { members[pid]?.member.process = entry.name } }
        case .fork:
            let now = Date()
            var queue = [pid], added: [Int32] = []
            while let current = queue.popLast(), added.count < 256 {
                for child in source.children(current) {
                    guard lock.withLock({ members[child] == nil && roots[child] == nil }), let entry = source.entry(child) else { continue }
                    lock.withLock { members[child] = (Member(root: parent.root, pid: child, start: entry.start, process: entry.name), now) }
                    added.append(child); queue.append(child)
                }
            }
            forks?.watch(added)
        }
    }

    public var liveRoots: [Root] { lock.withLock { Array(roots.values) } }
    /// Whether a full scan has run, so an agent missing from the roots has really exited.
    public var discovered: Bool { lock.withLock { scanned } }
    private var scanned = false
    public func arguments(_ pid: Int32) -> [String]? { source.arguments(pid) }
    /// Whether the process with this `pid@start` key still runs.
    public func alive(_ key: String) -> Bool {
        guard let pid = key.split(separator: "@").first.flatMap({ Int32($0) }), let entry = source.entry(pid) else { return false }
        return Self.key(pid, entry.start) == key
    }

    /// Finds agents every few seconds and their descendants every call.
    public func poll(now: Date = Date()) {
        if now.timeIntervalSince(lastDiscovery) >= 5 { discover(now: now) }
        walk(now: now)
    }

    /// Scans every process for agents. Cheap after the first pass: only new processes are identified.
    public func discover(now: Date = Date()) {
        lastDiscovery = now
        var found: [Int32: Root] = [:]
        let previous = lock.withLock { roots }
        var seen: [String: Date] = [:]
        for pid in source.all() {
            guard let entry = source.entry(pid) else { continue }
            let key = Self.key(pid, entry.start)
            if let root = previous[pid], root.start == entry.start { found[pid] = root; continue }
            if notAgents[key] != nil { seen[key] = now; continue }
            let path = source.path(pid)
            // Arguments only for interpreters and versioned binaries: reading every process's would cost more than it tells.
            let needsArguments = AgentIdentifier.interpreter(entry.name) || path.map { AgentIdentifier.interpreter(URL(fileURLWithPath: $0).lastPathComponent) } == true
                || AgentIdentifier.commands[entry.name] != nil || path?.contains("/claude/versions/") == true
            let arguments = needsArguments ? source.arguments(pid) : nil
            if let agent = AgentIdentifier.identify(path: path, name: entry.name, arguments: arguments) {
                found[pid] = Root(pid: pid, start: entry.start, agent: agent, path: path, cwd: source.cwd(pid))
            } else { seen[key] = now }
        }
        notAgents = seen
        lock.withLock {
            if Set(found.keys) != Set(roots.keys) { outside = [] }
            roots = found; scanned = true
        }
    }

    /// Every live descendant of each agent, not entering another agent's own tree. Members whose parent is gone
    /// (reparented to launchd) keep their agent, and so do their own children.
    public func walk(now: Date = Date()) {
        let roots = lock.withLock { self.roots }
        let previous = lock.withLock { members }
        var next: [Int32: (member: Member, seen: Date)] = [:]
        func visit(_ seeds: [(Int32, String)]) {
            var queue = seeds
            while let (pid, root) = queue.popLast() {
                for child in source.children(pid) where next[child] == nil && roots[child] == nil {
                    guard let entry = source.entry(child) else { continue }
                    next[child] = (Member(root: root, pid: child, start: entry.start, process: entry.name), now)
                    queue.append((child, root))
                }
            }
        }
        for root in roots.values {
            next[root.pid] = (Member(root: root.key, pid: root.pid, start: root.start, process: source.entry(root.pid)?.name ?? root.agent.id), now)
        }
        visit(roots.values.map { ($0.pid, $0.key) })
        // Still running with the same start but no longer under its agent: reparented. Gone: kept a little while.
        for (pid, old) in previous where next[pid] == nil && roots[pid] == nil {
            let entry = source.entry(pid)
            if let entry, entry.start == old.member.start {
                next[pid] = (old.member, now)
                visit([(pid, old.member.root)])
            } else if entry == nil, now.timeIntervalSince(old.seen) < Self.keepExited {
                next[pid] = old
            }
        }
        let active = Set(next.values.filter { $0.seen == now }.map(\.member.root))
        // Children the fork watcher placed since this walk began are kept.
        lock.withLock {
            for (pid, value) in members where next[pid] == nil && value.seen > now { next[pid] = value }
            members = next; self.active = active
        }
        forks?.watch(next.filter { $0.value.seen >= now }.map(\.key))
    }

    /// The agent a process belongs to, or nil. A process too new for the last walk is placed by walking up its parents.
    public func owner(pid: Int32) -> Member? {
        let (known, roots, skip) = lock.withLock { (members[pid]?.member, self.roots, outside) }
        let entry = source.entry(pid)
        if let known, entry == nil || entry?.start == known.start { return known }
        guard let entry else { return nil }
        let key = Self.key(pid, entry.start)
        if skip.contains(key) { return nil }
        var current = entry, depth = 0
        while depth < 32 {
            if let root = roots[current.pid], root.start == current.start {
                let member = Member(root: root.key, pid: pid, start: entry.start, process: entry.name)
                lock.withLock { members[pid] = (member, Date()) }
                return member
            }
            if let parent = lock.withLock({ members[current.pid]?.member }), parent.start == current.start, current.pid != pid {
                let member = Member(root: parent.root, pid: pid, start: entry.start, process: entry.name)
                lock.withLock { members[pid] = (member, Date()) }
                return member
            }
            guard current.ppid > 1, let parent = source.entry(current.ppid) else { break }
            current = parent; depth += 1
        }
        lock.withLock { _ = outside.insert(key) }
        return nil
    }

    /// Whether the agent, or something it started that outlived it, still runs.
    public func running(_ key: String) -> Bool { lock.withLock { active.contains(key) || roots.values.contains { $0.key == key } } }
}

/// Fork, exec and exit events for chosen processes, from one kqueue read on a background queue.
final class ForkWatcher: @unchecked Sendable {
    enum Event { case fork, exec }
    private typealias KernelEvent = Darwin.kevent
    private let queue = DispatchQueue(label: "co.seifi.kilobat.agent-forks", qos: .utility)
    private let kq: Int32
    private var source: DispatchSourceRead?
    private let lock = NSLock()
    private var watched: Set<Int32> = []
    private static let notes = UInt32(NOTE_FORK) | UInt32(NOTE_EXEC) | UInt32(NOTE_EXIT)

    init(_ handler: @escaping @Sendable (Int32, Event) -> Void) {
        kq = kqueue()
        guard kq >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: kq, queue: queue)
        let kq = kq
        source.setEventHandler { [weak self] in
            var events = Array(repeating: KernelEvent(), count: 64), zero = timespec()
            let count = kevent(kq, nil, 0, &events, 64, &zero)
            guard count > 0 else { return }
            for event in events.prefix(Int(count)) {
                let pid = Int32(truncatingIfNeeded: event.ident)
                if event.fflags & UInt32(NOTE_EXIT) != 0 { self?.forget(pid) }
                if event.fflags & UInt32(NOTE_FORK) != 0 { handler(pid, .fork) }
                if event.fflags & UInt32(NOTE_EXEC) != 0 { handler(pid, .exec) }
            }
        }
        source.resume(); self.source = source
    }

    private func forget(_ pid: Int32) { lock.withLock { _ = watched.remove(pid) } }

    /// Starts watching pids not watched yet. A process of another user, or one already gone, is refused by the kernel.
    func watch(_ pids: [Int32]) {
        guard kq >= 0 else { return }
        let new = lock.withLock { pids.filter { watched.insert($0).inserted } }
        guard !new.isEmpty else { return }
        var changes: [KernelEvent] = new.map { pid in
            var change = KernelEvent()
            change.ident = UInt(pid); change.filter = Int16(EVFILT_PROC)
            change.flags = UInt16(EV_ADD) | UInt16(EV_CLEAR) | UInt16(EV_RECEIPT); change.fflags = Self.notes
            return change
        }
        var receipts = Array(repeating: KernelEvent(), count: changes.count)
        _ = kevent(kq, &changes, Int32(changes.count), &receipts, Int32(receipts.count), nil)
        // A failed registration (the process exited first) can be tried again by the next walk.
        let failed = receipts.filter { $0.flags & UInt16(EV_ERROR) != 0 && $0.data != 0 }.map { Int32(truncatingIfNeeded: $0.ident) }
        if !failed.isEmpty { lock.withLock { for pid in failed { watched.remove(pid) } } }
    }

    deinit { source?.cancel(); if kq >= 0 { close(kq) } }
}
