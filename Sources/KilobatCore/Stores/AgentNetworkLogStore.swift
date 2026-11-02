import Foundation
import Observation
import Darwin

/// How the log names addresses: forward lookups of a few hosts and reverse DNS, both through this Mac's resolver.
public struct HostLookup: Sendable {
    public var forward: @Sendable (String) async -> [String]
    public var reverse: @Sendable (String) async -> String?
    public init(forward: @escaping @Sendable (String) async -> [String], reverse: @escaping @Sendable (String) async -> String?) {
        self.forward = forward; self.reverse = reverse
    }

    public static let live = HostLookup(
        forward: { host in
            await Task.detached(priority: .utility) { () -> [String] in
                var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
                var info: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &info) == 0, let first = info else { return [] }
                defer { freeaddrinfo(info) }
                var addresses: [String] = [], current: UnsafeMutablePointer<addrinfo>? = first
                while let entry = current {
                    var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let address = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        if !addresses.contains(address) { addresses.append(address) }
                    }
                    current = entry.pointee.ai_next
                }
                return addresses
            }.value
        },
        reverse: { address in
            await Task.detached(priority: .utility) { () -> String? in
                var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: 0, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
                var info: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(address, nil, &hints, &info) == 0, let first = info else { return nil }
                defer { freeaddrinfo(info) }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0 else { return nil }
                return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }.value
        })
}

/// Records every host each AI agent's process tree contacts, with bytes, from the per-connection rows nettop already
/// reports every second. Local only: saved in Application Support for 30 days, never sent anywhere.
@MainActor @Observable public final class AgentNetworkLogStore {
    public private(set) var sessions: [AgentNetworkSession] = []
    /// Hosts from sessions past the 30 days, so they stay known.
    public private(set) var pastHosts: Set<String> = []
    /// Whether it records: the app records with Pro. Checked every sample.
    @ObservationIgnored public var allowed: () -> Bool = { true }
    /// Names the Kilobat filter saw apps ask for, by address. Empty without the filter.
    @ObservationIgnored public var filterNames: () -> [String: String] = { [:] }
    @ObservationIgnored public let tree: AgentProcessTree
    @ObservationIgnored private let lookup: HostLookup
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private var live: [String: UUID] = [:]
    /// Each process's last counters, by `pid@start`: its totals and each connection's.
    @ObservationIgnored private var previous: [String: (received: UInt64, sent: UInt64, connections: [String: (UInt64, UInt64)], at: Date)] = [:]
    @ObservationIgnored private var lastSample: Date?
    /// When recording began: a process started since then moved nothing Kilobat didn't see, so all its bytes count.
    @ObservationIgnored private var firstSample: Date?
    @ObservationIgnored private var names: [String: (host: String, source: String)] = [:]
    @ObservationIgnored private var reverseTried: Set<String> = []
    @ObservationIgnored private var forwardChecked: [String: Date] = [:]
    /// Hosts the agents' own commands named (curl, git), to resolve and match.
    @ObservationIgnored private var commandHosts: Set<String> = []
    @ObservationIgnored private var argumentsRead: Set<String> = []
    @ObservationIgnored private var resolving = false
    @ObservationIgnored private var lastResolve = Date.distantPast
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var lastPersist = Date.distantPast
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private let polling = PollingFlag()
    /// Showing sample sessions: nothing is recorded or saved.
    @ObservationIgnored private var previewing = false
    /// Records per session, so a scan of every port on a network can't grow the file without end.
    static let maxRecords = 3_000
    static let maxSessions = 1_000
    static let fetchers: Set<String> = ["curl", "wget", "git-remote-https", "git-remote-http", "xh", "http", "aria2c"]

    /// `directory` nil keeps the log in memory only, as the tests do.
    public init(directory: URL? = nil, tree: AgentProcessTree = AgentProcessTree(watchForks: true), lookup: HostLookup = .live) {
        self.tree = tree; self.lookup = lookup
        file = directory?.appendingPathComponent("agent-network-log.json")
        if let file, let saved = AgentLogFile.load(file) {
            sessions = saved.sessions; pastHosts = Set(saved.pastHosts)
            // A session the app was recording when it quit picks up again if its agent still runs; the first poll ends the rest.
            for session in sessions where session.end == nil { live[session.key] = session.id }
            for session in sessions { for record in session.hosts { if let host = record.host, let source = record.nameSource { names[record.address] = (host, source) } } }
        }
        prune(now: Date())
    }

    /// Polls the process tree every half second on a background queue while recording.
    public func startPolling() {
        guard timer == nil else { return }
        timer = Self.pollTimer(tree: tree, polling: polling)
    }
    /// Nonisolated, so its handler isn't a main-actor closure: it runs on the timer's own queue.
    private nonisolated static func pollTimer(tree: AgentProcessTree, polling: PollingFlag) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "co.seifi.kilobat.agent-tree", qos: .utility))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(150))
        timer.setEventHandler { if polling.on { tree.poll() } }
        timer.resume()
        return timer
    }

    public var recording: Bool { allowed() }

    private var runningKeys: Set<String> {
        #if DEBUG
        if let previewRunning { return previewRunning }
        #endif
        return Set(live.keys.filter { tree.running($0) })
    }

    /// Every session with at least one host, newest first, flagged.
    public var report: [AgentLogEntry] {
        AgentNetworkLog.report(sessions, pastHosts: pastHosts, running: runningKeys)
    }
    /// Agents running now that have contacted something, most recently active first.
    public var running: [AgentLogEntry] {
        report.filter(\.running).sorted { a, b in
            (sessions.first { $0.id == a.id }?.lastActive ?? a.start) > (sessions.first { $0.id == b.id }?.lastActive ?? b.start)
        }
    }

    public func clear() {
        // Running agents keep their sessions; only what they recorded so far goes.
        for index in sessions.indices { sessions[index].hosts = []; sessions[index].unmatchedSent = 0; sessions[index].unmatchedReceived = 0 }
        sessions.removeAll { $0.end != nil }
        pastHosts = []
        dirty = true; persist(now: Date(), force: true)
    }

    /// One nettop sample. Its first sighting of a process only sets the baseline, unless the process started after the last sample.
    public func consume(_ snapshot: TrafficSnapshot) {
        let now = snapshot.timestamp
        guard allowed(), !previewing else {
            polling.on = false
            if lastSample != nil { previous = [:]; lastSample = nil; firstSample = nil }
            return
        }
        polling.on = true
        // Without the background timer (tests, the command line), the tree is polled with each sample.
        if timer == nil { tree.poll(now: now) }
        for root in tree.liveRoots where live[root.key] == nil {
            let session = AgentNetworkSession(key: root.key, agent: root.agent, pid: root.pid, start: root.start ?? now, cwd: root.cwd, executable: root.path)
            sessions.append(session); live[root.key] = session.id
        }
        let index = Dictionary(uniqueKeysWithValues: sessions.enumerated().map { ($0.element.id, $0.offset) })
        let names = filterNames()
        var seen: [String: (received: UInt64, sent: UInt64, connections: [String: (UInt64, UInt64)], at: Date)] = [:]
        for process in snapshot.processes {
            guard var member = tree.owner(pid: process.pid), let id = live[member.root], let position = index[id] else { continue }
            // A child placed at its fork may carry its parent's name until it exec'd; nettop names it after the exec (up to 15 characters).
            if !member.process.hasPrefix(process.process) { member.process = process.process }
            let key = AgentProcessTree.key(process.pid, member.start)
            let before = previous[key]
            var connections: [String: (UInt64, UInt64)] = [:]
            for connection in process.connections {
                let old = connections[connection.id] ?? (0, 0)
                connections[connection.id] = (old.0 + connection.received, old.1 + connection.sent)
            }
            seen[key] = (process.received, process.sent, connections, now)
            // Seen first now: everything counts if it started after recording began (or is already gone), else this sets its baseline.
            // Not "after the last sample": nettop reports a new socket a sample late, so a process can start just before one.
            let fresh = before == nil
            guard lastSample != nil, let firstSample, !fresh || (member.start.map { $0 >= firstSample } ?? true) else { continue }
            // What curl or the like was asked to fetch names the addresses it then connects to; only the URLs' hosts are kept.
            if Self.fetchers.contains(member.process), argumentsRead.insert(key).inserted, let arguments = tree.arguments(process.pid) {
                commandHosts.formUnion(AgentHostRules.hosts(inArguments: arguments))
            }
            let totalReceived = before.map { process.received >= $0.received ? process.received - $0.received : process.received } ?? process.received
            let totalSent = before.map { process.sent >= $0.sent ? process.sent - $0.sent : process.sent } ?? process.sent
            var matchedReceived: UInt64 = 0, matchedSent: UInt64 = 0
            for (id, bytes) in connections {
                let old = before?.connections[id]
                let isNew = old == nil
                let received = old.map { bytes.0 >= $0.0 ? bytes.0 - $0.0 : bytes.0 } ?? bytes.0
                let sent = old.map { bytes.1 >= $0.1 ? bytes.1 - $0.1 : bytes.1 } ?? bytes.1
                matchedReceived += received; matchedSent += sent
                guard let endpoint = Self.endpoint(id), isNew || received + sent > 0 else { continue }
                record(endpoint, process: member.process, received: received, sent: sent, opened: isNew, at: now, in: position, filterNames: names)
            }
            sessions[position].unmatchedReceived += totalReceived > matchedReceived ? totalReceived - matchedReceived : 0
            sessions[position].unmatchedSent += totalSent > matchedSent ? totalSent - matchedSent : 0
            if totalReceived + totalSent > 0 { dirty = true }
        }
        // A process keeps its counters while it runs, even through samples without it, so it is never counted again from scratch.
        previous = previous.filter { now.timeIntervalSince($0.value.at) < 30 || tree.alive($0.key) }.merging(seen) { $1 }
        argumentsRead = argumentsRead.filter { previous[$0] != nil }
        if firstSample == nil { firstSample = now }
        lastSample = now
        endFinished(now: now)
        resolveIfNeeded(now: now)
        prune(now: now)
        persist(now: now)
    }

    private func record(_ endpoint: (address: String, port: String, transport: String), process: String, received: UInt64, sent: UInt64, opened: Bool,
                        at now: Date, in position: Int, filterNames: [String: String]) {
        let key = process + "|" + endpoint.address + "|" + endpoint.port + "|" + endpoint.transport
        if names[endpoint.address]?.source != "filter", let host = filterNames[endpoint.address] { names[endpoint.address] = (host, "filter") }
        let name = names[endpoint.address]
        if let at = sessions[position].hosts.firstIndex(where: { $0.key == key }) {
            sessions[position].hosts[at].received += received; sessions[position].hosts[at].sent += sent
            sessions[position].hosts[at].last = now
            if opened { sessions[position].hosts[at].connections += 1 }
            if let name, sessions[position].hosts[at].nameSource != name.source { sessions[position].hosts[at].host = name.host; sessions[position].hosts[at].nameSource = name.source }
        } else if sessions[position].hosts.count < Self.maxRecords {
            sessions[position].hosts.append(AgentHostRecord(process: process, address: endpoint.address, port: endpoint.port, transport: endpoint.transport,
                                                            host: name?.host, nameSource: name?.source, first: now, last: now,
                                                            sent: sent, received: received, connections: opened ? 1 : 0))
        } else {
            sessions[position].unmatchedReceived += received; sessions[position].unmatchedSent += sent
        }
        dirty = true
    }

    /// A connection Protection blocked for a running agent: a row marked Blocked in its session. Blocked
    /// connections never carry bytes, so nettop alone wouldn't show them.
    @discardableResult public func recordBlocked(_ event: FilterEvent) -> Bool {
        guard allowed(), !previewing, let detail = event.protection, let pid = detail.agentPID,
              let position = sessions.lastIndex(where: { $0.pid == pid && $0.end == nil && live[$0.key] != nil }) else { return false }
        let process = detail.process ?? detail.agent ?? event.app
        var port = ""
        if let colon = event.endpoint.lastIndex(of: ":"), event.endpoint[event.endpoint.index(after: colon)...].allSatisfy(\.isNumber) { port = String(event.endpoint[event.endpoint.index(after: colon)...]) }
        let address = HostName.isAddress(detail.host) ? detail.host : ""
        let key = process + "|" + (address.isEmpty ? detail.host : address) + "|" + port + "|TCP"
        if let at = sessions[position].hosts.firstIndex(where: { $0.key == key }) {
            sessions[position].hosts[at].connections += 1; sessions[position].hosts[at].last = event.date
            sessions[position].hosts[at].blocked = detail.kind.rawValue; sessions[position].hosts[at].blockedBy = detail.list
        } else if sessions[position].hosts.count < Self.maxRecords {
            sessions[position].hosts.append(AgentHostRecord(process: process, address: address.isEmpty ? detail.host : address, port: port, transport: "TCP",
                                                            host: address.isEmpty ? detail.host : nil, nameSource: address.isEmpty ? "filter" : nil,
                                                            first: event.date, last: event.date, connections: 1, blocked: detail.kind.rawValue, blockedBy: detail.list))
        }
        dirty = true
        persist(now: event.date, force: true)
        return true
    }

    /// Hosts agents on this Mac used and weren't blocked from: the agent guard doesn't call them new.
    public var knownHosts: [String] { Self.knownHosts(sessions, pastHosts: pastHosts) }
    public nonisolated static func knownHosts(_ sessions: [AgentNetworkSession], pastHosts: Set<String>) -> [String] {
        var hosts = pastHosts
        for session in sessions { for record in session.hosts where record.blocked == nil && record.nameSource != "reverse" { if let host = record.host { hosts.insert(host.lowercased()) } } }
        return hosts.sorted()
    }

    /// `tcp4 192.168.1.20:5000<->104.16.5.34:443` → its remote end. Listening sockets, loopback and link-local are not contacts.
    static func endpoint(_ connection: String) -> (address: String, port: String, transport: String)? {
        guard let arrow = connection.range(of: "<->"), let space = connection.firstIndex(of: " ") else { return nil }
        let proto = connection[..<space]
        let remote = TrafficRoute.endpoint(connection[arrow.upperBound...], v6: proto.hasSuffix("6"))
        guard remote.address != "*", !remote.port.isEmpty, remote.port != "*", !TrafficRoute.isLinkLocalOrLoopback(remote.address) else { return nil }
        return (remote.address, remote.port, proto.hasPrefix("udp") ? "UDP" : "TCP")
    }

    private func endFinished(now: Date) {
        // Until the tree has looked once, after a relaunch, nothing is known to have ended.
        guard tree.discovered else { return }
        for (key, id) in live where !tree.running(key) {
            live[key] = nil
            guard let position = sessions.firstIndex(where: { $0.id == id }) else { continue }
            if sessions[position].hosts.isEmpty && sessions[position].unmatchedSent + sessions[position].unmatchedReceived == 0 { sessions.remove(at: position) }
            else { sessions[position].end = max(sessions[position].lastActive, sessions[position].start); dirty = true }
        }
    }

    /// Names for addresses that have none: well-known hosts and hosts in the agents' commands resolved on this Mac (their
    /// addresses then carry the name), and reverse DNS for the rest. At most every half minute, one pass at a time.
    private func resolveIfNeeded(now: Date) {
        guard !resolving, now.timeIntervalSince(lastResolve) >= 30 else { return }
        let unnamed = Set(sessions.filter { $0.end == nil || now.timeIntervalSince($0.end ?? now) < 3_600 }.flatMap(\.hosts).filter { $0.host == nil || $0.nameSource == "reverse" }.map(\.address))
        guard !unnamed.isEmpty else { return }
        resolving = true; lastResolve = now
        let candidates = (AgentHostRules.wellKnown + commandHosts.sorted()).filter { forwardChecked[$0].map { now.timeIntervalSince($0) >= 600 } ?? true }
        let tryReverse = unnamed.subtracting(reverseTried)
        let lookup = lookup
        Task { [weak self] in
            // All at once: forward answers usually come from the cache; a reverse lookup with no answer can take seconds.
            let found = await withTaskGroup(of: (String, [String]).self) { group in
                for host in candidates { group.addTask { (host, await lookup.forward(host)) } }
                var forward: [String: String] = [:]
                for await (host, addresses) in group { for address in addresses where forward[address] == nil { forward[address] = host } }
                return forward
            }
            self?.resolved(forward: found, reverse: [:], checked: candidates, tried: [], now: now)
            let reverse = await withTaskGroup(of: (String, String?).self) { group in
                for address in tryReverse.subtracting(found.keys).prefix(64) { group.addTask { (address, await lookup.reverse(address)) } }
                var names: [String: String] = [:]
                for await (address, name) in group { if let name { names[address] = name } }
                return names
            }
            self?.resolved(forward: [:], reverse: reverse, checked: [], tried: tryReverse, now: now)
            self?.resolving = false
        }
    }

    private func resolved(forward: [String: String], reverse: [String: String], checked: [String], tried: Set<String>, now: Date) {
        for host in checked { forwardChecked[host] = now }
        reverseTried.formUnion(tried)
        for (address, host) in forward where names[address]?.source != "filter" { names[address] = (host, "lookup") }
        for (address, host) in reverse where names[address] == nil { names[address] = (host, "reverse") }
        for position in sessions.indices where sessions[position].end == nil || now.timeIntervalSince(sessions[position].end ?? now) < 3_600 {
            for at in sessions[position].hosts.indices {
                let address = sessions[position].hosts[at].address
                guard let name = names[address], sessions[position].hosts[at].nameSource != name.source, sessions[position].hosts[at].nameSource != "filter" else { continue }
                sessions[position].hosts[at].host = name.host; sessions[position].hosts[at].nameSource = name.source; dirty = true
            }
        }
    }

    /// Drops sessions that ended more than 30 days ago, remembering their hosts.
    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-AgentNetworkLog.retention)
        let old = sessions.filter { ($0.end ?? now) < cutoff }
        guard !old.isEmpty || sessions.count > Self.maxSessions else { return }
        let gone = old + (sessions.count - old.count > Self.maxSessions ? Array(sessions.filter { ($0.end ?? now) >= cutoff }.sorted { $0.start < $1.start }.prefix(sessions.count - old.count - Self.maxSessions)) : [])
        let ids = Set(gone.map(\.id))
        for summary in AgentNetworkLog.report(gone).flatMap(\.hosts) where pastHosts.count < 10_000 { pastHosts.insert(summary.host.lowercased()) }
        sessions.removeAll { ids.contains($0.id) && $0.end != nil }
        dirty = true
    }

    /// Every ten seconds while something changed, so `kilobat agent-log` sees a running session.
    public func persist(now: Date = Date(), force: Bool = false) {
        guard let file, dirty, !previewing, force || now.timeIntervalSince(lastPersist) >= 10 else { return }
        dirty = false; lastPersist = now
        let saved = AgentLogFile(recording: allowed(), updated: now, sessions: sessions.filter { !$0.hosts.isEmpty || $0.end == nil }, pastHosts: pastHosts.sorted())
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? saved.data().write(to: file, options: [.atomic])
    }

    #if DEBUG
    /// Sample sessions for screenshots and the debug snapshot; nothing from this Mac.
    public func preview(_ sessions: [AgentNetworkSession], running: [String] = []) {
        previewing = true
        self.sessions = sessions
        for key in running { if let session = sessions.first(where: { $0.key == key }) { live[key] = session.id } }
        previewRunning = Set(running)
    }
    @ObservationIgnored private var previewRunning: Set<String>?
    #endif
}

/// Set on the main actor, read by the tree's timer queue.
private final class PollingFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var on: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}
