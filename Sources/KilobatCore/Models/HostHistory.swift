import Foundation

// Clear and "Forget this site" for every history Kilobat keeps that names hosts: Blocked attempts (filter-events.json),
// the agent network log (agent-network-log.json), the destinations of agent runs (sessions.json) and Protection's
// once-a-day notification memory (UserDefaults). The transforms here are pure; each store applies them to its own data.

/// A period to clear, ending now.
public enum HistoryRange: String, Codable, CaseIterable, Sendable {
    case hour, today, all

    /// Records from this moment on go; nil is everything.
    public func cutoff(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .hour: now.addingTimeInterval(-3_600)
        case .today: calendar.startOfDay(for: now)
        case .all: nil
        }
    }
}

/// One site to forget: a host name or an address, and optionally every subdomain of it.
public struct HostMatch: Codable, Equatable, Sendable {
    public let host: String
    public let subdomains: Bool

    /// From what a person typed: a host, an address or a URL. Nil when it is none of these.
    public init?(_ raw: String, subdomains: Bool = false) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("://") {
            guard let host = URL(string: text)?.host else { return nil }
            text = host
        }
        guard let host = Self.hostPart(text), let normal = HostName.normalize(host) else { return nil }
        self.host = normal; self.subdomains = subdomains && !HostName.isAddress(normal)
    }

    /// Whether `candidate` (a host, an address, "host:port", "[v6]:port" or an NWEndpoint's "address.port") is this site.
    public func matches(_ candidate: String?) -> Bool {
        guard let candidate, let part = Self.hostPart(candidate) else { return false }
        let name = HostName.normalize(part) ?? part.lowercased()
        return name == host || (subdomains && name.hasSuffix("." + host))
    }

    /// The host of an endpoint without its port.
    static func hostPart(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") { return String(value[value.index(after: value.startIndex)..<close]) }
        let colons = value.filter { $0 == ":" }.count
        if colons == 1, let colon = value.lastIndex(of: ":") { value = String(value[..<colon]) }
        // Network.framework writes an IPv6 endpoint as "2001:db8::1.443".
        else if colons > 1, let dot = value.lastIndex(of: "."), value[value.index(after: dot)...].allSatisfy(\.isNumber), !value[..<dot].contains(".") {
            value = String(value[..<dot])
        }
        while value.hasSuffix(".") { value.removeLast() }
        return value.isEmpty ? nil : value
    }
}

/// Clear a period or forget a site.
public enum HistoryAction: Equatable, Sendable {
    case clear(HistoryRange)
    case forget(HostMatch)
}

/// The histories that name hosts.
public enum HostHistoryKind: String, Codable, CaseIterable, Sendable {
    case blockedAttempts, agentLog, sessions, notices
}

/// What went, per history.
public struct HistoryChange: Codable, Equatable, Sendable {
    public var blockedAttempts = 0
    /// Hosts in agent network log sessions, plus remembered hosts of older sessions.
    public var agentLogHosts = 0
    /// Destinations of agent runs and awake sessions.
    public var sessionDestinations = 0
    /// Protection's memory of which notifications went out today.
    public var notices = 0
    public init() {}
    public var total: Int { blockedAttempts + agentLogHosts + sessionDestinations + notices }
    public static func + (lhs: HistoryChange, rhs: HistoryChange) -> HistoryChange {
        var sum = lhs
        sum.blockedAttempts += rhs.blockedAttempts; sum.agentLogHosts += rhs.agentLogHosts
        sum.sessionDestinations += rhs.sessionDestinations; sum.notices += rhs.notices
        return sum
    }
}

public enum HistoryEraser {
    /// Blocked attempts: by when they happened, or by the endpoint and the host Protection matched. Returns the removed ids.
    public static func apply(_ action: HistoryAction, to events: inout [FilterEvent], now: Date = Date(), calendar: Calendar = .current) -> [UUID] {
        let gone: [FilterEvent]
        switch action {
        case .clear(let range):
            let cutoff = range.cutoff(now: now, calendar: calendar)
            gone = events.filter { event in cutoff.map { event.date >= $0 } ?? true }
        case .forget(let match):
            gone = events.filter { $0.historyHosts.contains(where: match.matches) }
        }
        let ids = Set(gone.map(\.id))
        events.removeAll { ids.contains($0.id) }
        return gone.map(\.id)
    }

    /// The agent network log: host records seen in the period, or naming the site (or at its address). Sessions that
    /// ended and lost every host go; a running session stays. Older sessions' remembered hosts go on Forget and on Clear all.
    public static func apply(_ action: HistoryAction, to sessions: inout [AgentNetworkSession], pastHosts: inout Set<String>,
                             now: Date = Date(), calendar: Calendar = .current) -> Int {
        var removed = 0
        let cutoff: Date?
        if case .clear(let range) = action { cutoff = range.cutoff(now: now, calendar: calendar) } else { cutoff = nil }
        for index in sessions.indices {
            let before = sessions[index].hosts.count
            switch action {
            case .clear: sessions[index].hosts.removeAll { record in cutoff.map { record.last >= $0 } ?? true }
            case .forget(let match): sessions[index].hosts.removeAll { match.matches($0.host) || match.matches($0.address) }
            }
            removed += before - sessions[index].hosts.count
            if case .clear(.all) = action { sessions[index].unmatchedSent = 0; sessions[index].unmatchedReceived = 0 }
        }
        sessions.removeAll { $0.end != nil && $0.hosts.isEmpty }
        let past = pastHosts.count
        switch action {
        case .clear(.all): pastHosts = []
        case .clear: break
        case .forget(let match): pastHosts = pastHosts.filter { !match.matches($0) }
        }
        return removed + past - pastHosts.count
    }

    /// Agent runs and awake sessions keep their destinations ("host:port") without times: a period clears the
    /// destinations of every session active in it; Forget removes the site from all.
    public static func apply(_ action: HistoryAction, to sessions: inout [WorkSession], now: Date = Date(), calendar: Calendar = .current) -> Int {
        var removed = 0
        for index in sessions.indices {
            let before = sessions[index].destinations.count
            switch action {
            case .clear(let range):
                if let cutoff = range.cutoff(now: now, calendar: calendar), (sessions[index].end ?? now) < cutoff { continue }
                sessions[index].destinations = []
            case .forget(let match): sessions[index].destinations.removeAll { match.matches($0) }
            }
            removed += before - sessions[index].destinations.count
        }
        return removed
    }

    /// Protection's notification memory: "app|host" with the time a notice went out.
    public static func apply(_ action: HistoryAction, to limiter: inout ProtectionNoticeLimiter, now: Date = Date(), calendar: Calendar = .current) -> Int {
        let before = limiter.sent.count
        switch action {
        case .clear(let range):
            let cutoff = range.cutoff(now: now, calendar: calendar)
            limiter.sent = limiter.sent.filter { entry in cutoff.map { entry.value < $0 } ?? false }
        case .forget(let match):
            limiter.sent = limiter.sent.filter { !match.matches(String($0.key.split(separator: "|", maxSplits: 1).last ?? "")) }
        }
        return before - limiter.sent.count
    }
}

/// The histories on disk, for the command line while the app isn't running (the running app keeps them in memory
/// and would write them back, so the CLI asks it through `AppRelay` instead).
@MainActor public enum HostHistoryFiles {
    public static var directory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat") }

    /// `appDefaults` is the app's preferences domain, where Protection keeps its notification memory.
    public static func erase(_ action: HistoryAction, kinds: Set<HostHistoryKind> = Set(HostHistoryKind.allCases), directory: URL = HostHistoryFiles.directory,
                             appDefaults: UserDefaults?, now: Date = Date()) throws -> HistoryChange {
        var change = HistoryChange()
        if kinds.contains(.blockedAttempts) {
            change.blockedAttempts = try FilterEventJournal(file: directory.appendingPathComponent("filter-events.json")).erase(action, now: now)
        }
        if kinds.contains(.agentLog) { change.agentLogHosts = try AgentLogFile.erase(action, at: directory.appendingPathComponent("agent-network-log.json"), now: now) }
        if kinds.contains(.sessions) { change.sessionDestinations = try SessionStore.erase(action, directory: directory, now: now) }
        if kinds.contains(.notices), let appDefaults { change.notices = try ProtectionStore.erase(action, defaults: appDefaults, now: now) }
        return change
    }
}

/// `kilobat history clear|forget`, and MCP `clear_history`.
public enum HistoryCommand: Equatable, Sendable {
    case clear(HistoryRange, json: Bool)
    case forget(HostMatch, json: Bool)

    public static let usage = "Use history forget <host> [--subdomains] [--json] or history clear --hour|--today|--all [--json]."
    public struct Failure: Error, Equatable { public let message: String }

    /// Arguments after `history`.
    public static func parse(_ args: [String]) throws -> HistoryCommand {
        let json = args.contains("--json")
        var rest = args.filter { $0 != "--json" }
        guard let verb = rest.first else { throw Failure(message: usage) }
        rest.removeFirst()
        switch verb {
        case "clear":
            let ranges: [HistoryRange] = rest.compactMap { ["--hour": .hour, "--today": .today, "--all": .all][$0] }
            guard ranges.count == 1, rest.count == 1 else { throw Failure(message: "Choose one of --hour, --today and --all. " + usage) }
            return .clear(ranges[0], json: json)
        case "forget":
            let subdomains = rest.contains("--subdomains")
            rest.removeAll { $0 == "--subdomains" }
            guard rest.count == 1, !rest[0].hasPrefix("-") else { throw Failure(message: usage) }
            guard let match = HostMatch(rest[0], subdomains: subdomains) else { throw Failure(message: "'\(rest[0])' isn't a host name, an IP address or a URL.") }
            return .forget(match, json: json)
        default: throw Failure(message: "Unknown history command '\(verb)'. " + usage)
        }
    }

    public var action: HistoryAction {
        switch self { case .clear(let range, _): .clear(range); case .forget(let match, _): .forget(match) }
    }

    /// For the relay to the running app: "history|clear|today" or "history|forget|1|example.com".
    public var relayAction: String {
        switch self {
        case .clear(let range, _): "history|clear|" + range.rawValue
        case .forget(let match, _): "history|forget|" + (match.subdomains ? "1" : "0") + "|" + match.host
        }
    }

    public static func fromRelay(_ action: String) -> HistoryAction? {
        let parts = action.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "history", parts.count >= 3 else { return nil }
        if parts[1] == "clear", parts.count == 3, let range = HistoryRange(rawValue: parts[2]) { return .clear(range) }
        if parts[1] == "forget", parts.count == 4, ["0", "1"].contains(parts[2]), let match = HostMatch(parts[3], subdomains: parts[2] == "1") { return .forget(match) }
        return nil
    }
}
