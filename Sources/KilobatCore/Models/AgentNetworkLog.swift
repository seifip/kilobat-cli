import Foundation

/// One remote endpoint a process in an agent's tree talked to during one session, as nettop counted it.
public struct AgentHostRecord: Codable, Equatable, Sendable {
    /// The process that made the connections: npm, curl, git-remote-https, node, the agent itself.
    public var process: String
    public var address: String
    public var port: String
    /// TCP or UDP.
    public var transport: String
    /// The name the address answered for, when Kilobat knows it; see `nameSource`.
    public var host: String?
    /// filter (the name the app asked the Kilobat network filter for), lookup (a well-known or command-line host that
    /// resolves to this address on this Mac) or reverse (the address's reverse DNS name).
    public var nameSource: String?
    public var first: Date
    public var last: Date
    public var sent: UInt64 = 0
    public var received: UInt64 = 0
    /// Sockets opened to it.
    public var connections: Int = 0
    /// Set when Kilobat's Protection blocked it: malware, phishing, scam, threat, tracker or agentGuard (`ProtectionDetail.Kind`).
    public var blocked: String? = nil
    /// The list or agent-guard rule that blocked it.
    public var blockedBy: String? = nil

    public init(process: String, address: String, port: String, transport: String, host: String? = nil, nameSource: String? = nil,
                first: Date, last: Date, sent: UInt64 = 0, received: UInt64 = 0, connections: Int = 0, blocked: String? = nil, blockedBy: String? = nil) {
        self.process = process; self.address = address; self.port = port; self.transport = transport; self.host = host; self.nameSource = nameSource
        self.first = first; self.last = last; self.sent = sent; self.received = received; self.connections = connections
        self.blocked = blocked; self.blockedBy = blockedBy
    }
    var key: String { process + "|" + address + "|" + port + "|" + transport }
}

/// One run of one agent process: from when Kilobat first saw it until it, and everything it started, exited.
public struct AgentNetworkSession: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    /// The agent's process, `pid@start`, so a session survives the app restarting while the agent runs.
    public var key: String
    public var agent: String
    public var agentID: String
    public var pid: Int32
    public var start: Date
    public var end: Date?
    /// The agent's working directory when Kilobat first saw it, and its last component.
    public var cwd: String?
    public var project: String?
    public var executable: String?
    public var hosts: [AgentHostRecord] = []
    /// Bytes from sockets that opened and closed between two samples: counted for the process, but with no endpoint.
    public var unmatchedSent: UInt64 = 0
    public var unmatchedReceived: UInt64 = 0

    public init(key: String, agent: AgentIdentity, pid: Int32, start: Date, cwd: String? = nil, executable: String? = nil) {
        self.key = key; self.agent = agent.name; agentID = agent.id; self.pid = pid; self.start = start; self.cwd = cwd; self.executable = executable
        project = cwd.flatMap { path in
            let name = URL(fileURLWithPath: path).lastPathComponent
            return name.isEmpty || name == "/" || path == NSHomeDirectory() ? nil : name
        }
    }

    public var sent: UInt64 { hosts.reduce(unmatchedSent) { $0 + $1.sent } }
    public var received: UInt64 { hosts.reduce(unmatchedReceived) { $0 + $1.received } }
    public var lastActive: Date { hosts.map(\.last).max() ?? start }
}

/// What deserves a second look, said plainly. None of these means something is wrong.
public enum AgentHostFlag: String, Codable, CaseIterable, Sendable {
    /// No agent had contacted this host before (well-known package registries and the agent's own service excepted).
    case newHost
    /// Plain HTTP on port 80: what was sent could be read or changed on the way.
    case plainHTTP
    /// More than `AgentHostRules.largeUpload` sent to one host that isn't the agent's own service.
    case largeUpload
    /// No name: Kilobat saw only the address, or only its reverse DNS name.
    case addressOnly
    /// A paste site, file-sharing service, tunnel or request catcher.
    case shareOrTunnel
    /// Kilobat's Protection blocked it: a known threat, or the agent guard.
    case blocked

    public var title: String {
        switch self {
        case .newHost: String(localized: "first time", comment: "Agent network log: no agent contacted this host before")
        case .plainHTTP: String(localized: "plain HTTP", comment: "Agent network log: unencrypted HTTP")
        case .largeUpload: String(localized: "large upload", comment: "Agent network log: many megabytes sent to one host")
        case .addressOnly: String(localized: "address only", comment: "Agent network log: no hostname, only an IP address")
        case .shareOrTunnel: String(localized: "share or tunnel", comment: "Agent network log: a paste site, file-sharing service, tunnel or request catcher")
        case .blocked: String(localized: "Blocked", comment: "Agent network log: Kilobat's Protection blocked this host")
        }
    }
    public var explanation: String {
        switch self {
        case .newHost: String(localized: "No agent on this Mac contacted this host before.")
        case .plainHTTP: String(localized: "Unencrypted HTTP: anyone on the path could read or change it.")
        case .largeUpload: String(localized: "More than 10 MB went to a host that isn’t the agent’s own service.")
        case .addressOnly: String(localized: "Kilobat saw only the address, so it can’t say which site this was.")
        case .shareOrTunnel: String(localized: "A paste site, file-sharing service, tunnel or request catcher: a common way for data to leave.")
        case .blocked: String(localized: "Kilobat’s Protection blocked it: a known malicious destination, or the agent guard.")
        }
    }
}

/// The endpoints of one process in a session, grouped by name rather than address: registry.npmjs.org over
/// four Cloudflare addresses is one row.
public struct AgentHostSummary: Codable, Equatable, Identifiable, Sendable {
    public var process: String
    /// The name, or the address when there is none.
    public var host: String
    public var nameSource: String?
    public var addresses: [String]
    public var port: String
    public var transport: String
    public var first: Date
    public var last: Date
    public var sent: UInt64
    public var received: UInt64
    public var connections: Int
    public var flags: [AgentHostFlag]
    /// For `shareOrTunnel`: paste site, file share, tunnel or request catcher.
    public var category: String?
    /// For `blocked`: what Protection called it (malware, phishing, scam, threat, tracker, agentGuard) and the list or rule.
    public var blocked: String? = nil
    public var blockedBy: String? = nil
    public var id: String { process + "|" + host + "|" + port + "|" + transport }
    public var flagged: Bool { !flags.isEmpty }
    public var needsReview: Bool {
        flags.contains(.blocked) || flags.contains(.largeUpload)
            || (sent > 0 && flags.contains(.shareOrTunnel))
    }
    public var notes: String {
        flags.map { flag in
            switch flag {
            case .shareOrTunnel: category ?? flag.title
            case .blocked: [flag.title, blockedBy].compactMap { $0 }.joined(separator: ": ")
            default: flag.title
            }
        }.joined(separator: ", ")
    }
}

/// One session as reported: the app's panel, `kilobat agent-log` and the MCP tool all read this.
public struct AgentLogEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var agent: String
    public var agentID: String
    public var pid: Int32
    public var start: Date
    public var end: Date?
    public var running: Bool
    public var cwd: String?
    public var project: String?
    public var executable: String?
    public var sent: UInt64
    public var received: UInt64
    /// Bytes counted for the agent's processes whose endpoints closed between samples.
    public var unmatchedSent: UInt64
    public var unmatchedReceived: UInt64
    /// Distinct hosts, however many processes talked to each.
    public var hostCount: Int
    public var flaggedCount: Int
    /// By process, then by bytes sent.
    public var hosts: [AgentHostSummary]

    public var reviewCount: Int { Set(hosts.filter(\.needsReview).map { $0.host.lowercased() }).count }

    public var title: String { agent + (project.map { " · " + $0 } ?? "") }
    /// "Claude Code · 14 hosts · 2.1 MB up".
    public var line: String {
        let count = hostCount == 1 ? String(localized: "1 host") : String(localized: "\(hostCount) hosts")
        return [agent, count, String(localized: "\(TrafficFormat.bytes(sent)) up", comment: "Bytes sent, e.g. 2.1 MB up")].joined(separator: " · ")
    }
    /// Processes in the order the table shows them: the one that sent most first.
    public var processes: [(process: String, hosts: [AgentHostSummary])] {
        let groups = Dictionary(grouping: hosts, by: \.process)
        return groups.map { ($0.key, $0.value) }.sorted { lhs, rhs in
            let a = lhs.hosts.reduce(0) { $0 + $1.sent }, b = rhs.hosts.reduce(0) { $0 + $1.sent }
            return a == b ? lhs.process < rhs.process : a > b
        }
    }
}

/// What is saved: Application Support/Kilobat/agent-network-log.json. Local only, kept 30 days.
public struct AgentLogFile: Codable, Equatable, Sendable {
    public var version = 1
    /// Whether the app was recording when it last wrote (it records with Pro).
    public var recording: Bool
    public var updated: Date
    public var sessions: [AgentNetworkSession]
    /// Hosts from sessions older than the 30 days kept, so a host stays known after its session is gone.
    public var pastHosts: [String] = []

    public init(recording: Bool, updated: Date, sessions: [AgentNetworkSession], pastHosts: [String] = []) {
        self.recording = recording; self.updated = updated; self.sessions = sessions; self.pastHosts = pastHosts
    }

    public static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat/agent-network-log.json")
    }
    /// Clears a period or forgets a site in the saved log, for the command line while the app isn't running.
    @discardableResult public static func erase(_ action: HistoryAction, at url: URL = AgentLogFile.url, now: Date = Date()) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var file = try decoder.decode(AgentLogFile.self, from: Data(contentsOf: url))
        var past = Set(file.pastHosts)
        let removed = HistoryEraser.apply(action, to: &file.sessions, pastHosts: &past, now: now)
        guard removed > 0 else { return 0 }
        file.pastHosts = past.sorted()
        try file.data().write(to: url, options: [.atomic])
        return removed
    }
    public static func load(_ url: URL = AgentLogFile.url) -> AgentLogFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AgentLogFile.self, from: data)
    }
    public func data() throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

public enum AgentNetworkLog {
    public static let retention: TimeInterval = 30 * 86_400

    /// Sessions as reported, newest first, with flags. A host is new in the session where an agent first contacted it.
    public static func report(_ sessions: [AgentNetworkSession], pastHosts: Set<String> = [], running: Set<String> = []) -> [AgentLogEntry] {
        var known = pastHosts
        var entries: [AgentLogEntry] = []
        for session in sessions.sorted(by: { $0.start < $1.start }) where !session.hosts.isEmpty {
            let summaries = summarize(session, known: known)
            for summary in summaries { known.insert(summary.host.lowercased()) }
            let named = Set(summaries.map { $0.host.lowercased() })
            entries.append(AgentLogEntry(id: session.id, agent: session.agent, agentID: session.agentID, pid: session.pid, start: session.start, end: session.end,
                                         running: session.end == nil && running.contains(session.key), cwd: session.cwd, project: session.project,
                                         executable: session.executable, sent: session.sent, received: session.received,
                                         unmatchedSent: session.unmatchedSent, unmatchedReceived: session.unmatchedReceived, hostCount: named.count,
                                         flaggedCount: Set(summaries.filter(\.flagged).map { $0.host.lowercased() }).count, hosts: summaries))
        }
        return entries.reversed()
    }

    /// Records grouped by process, name, port and transport, sorted by process (most sent first) then bytes sent.
    static func summarize(_ session: AgentNetworkSession, known: Set<String>) -> [AgentHostSummary] {
        var groups: [String: AgentHostSummary] = [:], order: [String] = []
        for record in session.hosts {
            let host = record.host ?? record.address
            let key = record.process + "|" + host.lowercased() + "|" + record.port + "|" + record.transport
            if var summary = groups[key] {
                if !summary.addresses.contains(record.address) { summary.addresses.append(record.address) }
                summary.first = min(summary.first, record.first); summary.last = max(summary.last, record.last)
                summary.sent += record.sent; summary.received += record.received; summary.connections += record.connections
                if summary.nameSource == nil || (record.nameSource == "filter" && summary.nameSource != "filter") { summary.nameSource = record.nameSource }
                if let blocked = record.blocked { summary.blocked = blocked; summary.blockedBy = record.blockedBy }
                groups[key] = summary
            } else {
                groups[key] = AgentHostSummary(process: record.process, host: host, nameSource: record.host == nil ? nil : record.nameSource, addresses: [record.address],
                                               port: record.port, transport: record.transport, first: record.first, last: record.last, sent: record.sent,
                                               received: record.received, connections: record.connections, flags: [], category: nil,
                                               blocked: record.blocked, blockedBy: record.blockedBy)
                order.append(key)
            }
        }
        // Upload size counts per host across the session's processes: npm and node splitting one upload still add up.
        var sentByHost: [String: UInt64] = [:]
        for summary in groups.values { sentByHost[summary.host.lowercased(), default: 0] += summary.sent }
        var summaries = order.compactMap { groups[$0] }
        for index in summaries.indices {
            let summary = summaries[index], host = summary.host.lowercased()
            let named = summary.nameSource == "filter" || summary.nameSource == "lookup"
            var flags: [AgentHostFlag] = summary.blocked == nil ? [] : [.blocked]
            let own = named && AgentHostRules.ownService(host, agent: session.agentID)
            if !known.contains(host) && !(named && AgentHostRules.isWellKnown(host)) && !own { flags.append(.newHost) }
            if summary.transport == "TCP" && summary.port == "80" { flags.append(.plainHTTP) }
            if (sentByHost[host] ?? 0) > AgentHostRules.largeUpload && !own { flags.append(.largeUpload) }
            if !named { flags.append(.addressOnly) }
            if named, let kind = AgentHostRules.share(host) { flags.append(.shareOrTunnel); summaries[index].category = kind }
            // A blocked host carried nothing: Blocked says all there is.
            summaries[index].flags = summary.blocked == nil ? flags : [.blocked]
        }
        let totals = Dictionary(grouping: summaries, by: \.process).mapValues { $0.reduce(0) { $0 + $1.sent } }
        return summaries.sorted { a, b in
            if a.process != b.process {
                let x = totals[a.process] ?? 0, y = totals[b.process] ?? 0
                return x == y ? a.process < b.process : x > y
            }
            return a.sent == b.sent ? (a.received == b.received ? a.host < b.host : a.received > b.received) : a.sent > b.sent
        }
    }

    /// The session as a Markdown table, for an issue, a review or a chat.
    public static func markdown(_ entry: AgentLogEntry, onlyFlagged: Bool = false, onlyReview: Bool = false) -> String {
        let hosts = entry.hosts.filter { onlyReview ? $0.needsReview : !onlyFlagged || $0.flagged }
        let when = entry.start.formatted(date: .abbreviated, time: .shortened) + " – " + (entry.end.map { $0.formatted(date: .omitted, time: .shortened) } ?? String(localized: "running"))
        var lines = ["## " + entry.title, "",
                     "\(when) · \(entry.hostCount == 1 ? String(localized: "1 host") : String(localized: "\(entry.hostCount) hosts")) · ↑ \(TrafficFormat.bytes(entry.sent)) ↓ \(TrafficFormat.bytes(entry.received))", ""]
        if hosts.isEmpty {
            if onlyReview { lines.append(String(localized: "Nothing to review in this session.")) }
            else { lines.append(onlyFlagged ? String(localized: "Nothing flagged.") : String(localized: "No connections recorded.")) }
        }
        else {
            lines += ["| " + [String(localized: "Process"), String(localized: "Host"), String(localized: "Port"), String(localized: "Sent"), String(localized: "Received"), String(localized: "Connections"), String(localized: "Notes")].joined(separator: " | ") + " |",
                      "|---|---|---|--:|--:|--:|---|"]
            for host in hosts {
                let name = host.host + (host.nameSource == "reverse" ? " (reverse DNS)" : "")
                lines.append("| " + [cell(host.process), cell(name), "\(host.port)/\(host.transport)", TrafficFormat.bytes(host.sent), TrafficFormat.bytes(host.received), "\(host.connections)", cell(host.notes)].joined(separator: " | ") + " |")
            }
        }
        if entry.unmatchedSent + entry.unmatchedReceived > 0 {
            lines += ["", String(localized: "Also ↑ \(TrafficFormat.bytes(entry.unmatchedSent)) ↓ \(TrafficFormat.bytes(entry.unmatchedReceived)) on connections that closed before Kilobat saw where they went.")]
        }
        lines += ["", String(localized: "Recorded by Kilobat from this Mac’s own network statistics. Hosts are named from the Kilobat filter, local lookups of well-known hosts, or reverse DNS.")]
        return lines.joined(separator: "\n")
    }
    private static func cell(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "\\|") }
}

/// `kilobat agent-log` and the MCP tool's options: the latest session by default.
public struct AgentLogQuery: Equatable, Sendable {
    public var all = false
    public var since: Date?
    public var agent: String?
    public var flagged = false
    public var json = false
    public init(all: Bool = false, since: Date? = nil, agent: String? = nil, flagged: Bool = false, json: Bool = false) {
        self.all = all; self.since = since; self.agent = agent; self.flagged = flagged; self.json = json
    }

    public static let usage = "Use agent-log [--all] [--since 2h|3d|2026-10-30] [--agent claude] [--flagged] [--json]."
    public struct Failure: Error, Equatable { public let message: String }

    public static func parse(_ args: [String], now: Date = Date()) throws -> AgentLogQuery {
        var query = AgentLogQuery(), index = args.first == "agent-log" ? 1 : 0
        while index < args.count {
            switch args[index] {
            case "--all": query.all = true; index += 1
            case "--json": query.json = true; index += 1
            case "--flagged": query.flagged = true; index += 1
            case "--since":
                guard index + 1 < args.count, let date = since(args[index + 1], now: now) else { throw Failure(message: "--since takes 30m, 2h, 3d, today, yesterday or a date such as 2026-10-30. " + usage) }
                query.since = date; index += 2
            case "--agent":
                guard index + 1 < args.count, !args[index + 1].hasPrefix("-"), !args[index + 1].isEmpty else { throw Failure(message: "--agent takes a name such as claude, codex, cursor or gemini. " + usage) }
                query.agent = args[index + 1]; index += 2
            default: throw Failure(message: "Unexpected '\(args[index])'. " + usage)
            }
        }
        return query
    }

    /// 30m, 2h, 3d, 1w, today, yesterday, 2026-10-30 or an ISO 8601 time.
    public static func since(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let value = text.lowercased()
        if value == "today" { return calendar.startOfDay(for: now) }
        if value == "yesterday" { return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) }
        if let unit = value.last, let amount = Double(value.dropLast()), amount > 0, amount <= 10_000 {
            let seconds: Double? = switch unit { case "m": 60; case "h": 3_600; case "d": 86_400; case "w": 604_800; default: nil }
            if let seconds { return now.addingTimeInterval(-amount * seconds) }
        }
        if let date = try? Date(value.uppercased(), strategy: .iso8601) { return date <= now ? date : nil }
        let day = DateFormatter(); day.calendar = calendar; day.locale = Locale(identifier: "en_US_POSIX"); day.timeZone = calendar.timeZone; day.dateFormat = "yyyy-MM-dd"
        if let date = day.date(from: value), date <= now { return date }
        return nil
    }

    public func matches(_ entry: AgentLogEntry) -> Bool {
        guard let agent = agent?.lowercased() else { return true }
        return entry.agentID == agent || entry.agentID.hasPrefix(agent) || entry.agent.lowercased().hasPrefix(agent)
    }

    /// The sessions asked for. Without --all or --since, one: the session of the agent this runs under when there is
    /// one (an agent auditing itself), else the latest.
    public func select(_ entries: [AgentLogEntry], within pids: [Int32] = []) -> [AgentLogEntry] {
        var chosen = entries.filter(matches)
        if let since { chosen = chosen.filter { ($0.end ?? .distantFuture) >= since } }
        else if !all {
            let own = chosen.first { $0.running && pids.contains($0.pid) }
            chosen = own.map { [$0] } ?? Array(chosen.prefix(1))
        }
        guard flagged else { return chosen }
        return chosen.map { entry in var entry = entry; entry.hosts = entry.hosts.filter(\.flagged); return entry }
    }
}
