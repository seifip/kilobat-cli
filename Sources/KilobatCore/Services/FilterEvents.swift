import Foundation

/// Metadata only: no packet payloads, URLs, or DNS query contents.
public struct FilterEvent: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let date: Date
    public let app: String
    public let endpoint: String
    public let direction: String
    public let reason: String
    /// The system service that made the connection for `app`, such as com.apple.nsurlsessiond. Nil when the app made it.
    public let via: String?
    /// Set when Protection blocked it: what kind of destination, which list, and the agent behind it.
    public let protection: ProtectionDetail?
    /// Every rule that matched as the filter blocked it, and the one that decided (`FilterPolicy.trace`). Nil in
    /// records from filters before the rule inspector, and when the filter blocked without its rules (no app identity).
    public let trace: DecisionTrace?
    public init(id: UUID = UUID(), date: Date = Date(), app: String, endpoint: String, direction: String, reason: String, via: String? = nil,
                protection: ProtectionDetail? = nil, trace: DecisionTrace? = nil) {
        self.id = id; self.date = date; self.app = app; self.endpoint = endpoint; self.direction = direction; self.reason = reason; self.via = via
        self.protection = protection; self.trace = trace
    }

    /// Every destination that may identify this event in local history. The endpoint can be an IP even when a
    /// matched rule retains a hostname; forgetting a site must consider those nondeciding rules too.
    public var historyHosts: [String] {
        var hosts: [String] = [], seen = Set<String>()
        func add(_ value: String?) {
            guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty,
                  value != "unknown endpoint" else { return }
            if value.hasPrefix("*.") { value.removeFirst(2) }
            guard !value.isEmpty, seen.insert(value).inserted else { return }
            hosts.append(value)
        }
        if endpoint.hasPrefix("["), let close = endpoint.firstIndex(of: "]") {
            add(String(endpoint[endpoint.index(after: endpoint.startIndex)..<close]))
        } else if endpoint.filter({ $0 == ":" }).count == 1, let colon = endpoint.lastIndex(of: ":"),
                  endpoint[endpoint.index(after: colon)...].allSatisfy(\.isNumber) {
            add(String(endpoint[..<colon]))
        } else {
            add(endpoint)
        }
        add(protection?.host)
        // Older filters recorded only a text reason. Preserve those host names during history clearing too.
        if reason.hasPrefix("Blocklist: ") { add(String(reason.dropFirst("Blocklist: ".count))) }
        if reason.hasPrefix("Destination rule: ") {
            let target = String(reason.dropFirst("Destination rule: ".count).components(separatedBy: " · ")[0])
            if target.filter({ $0 == ":" }).count == 1, let colon = target.lastIndex(of: ":"),
               target[target.index(after: colon)...].allSatisfy(\.isNumber) {
                add(String(target[..<colon]))
            } else { add(target) }
        }
        for match in trace?.matches ?? [] {
            switch match.reason {
            case .connectionRule(let rule): add(rule.host)
            case .protection(let detail): add(detail.host)
            case .siteAllowed(let host), .blocklist(let host), .subscribedList(let host, _): add(host)
            default: break
            }
        }
        return hosts
    }
}

/// Why Protection blocked a connection. Compiled into the filter, so Foundation only.
public struct ProtectionDetail: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A known malware, phishing or scam destination; `threat` when the list doesn't say which.
        case malware, phishing, scam, threat
        /// A tracker or ad host, with the optional tracker lists.
        case tracker
        /// The stricter agent guard: a paste site, file share, tunnel or request catcher, a raw IP address, or a large upload to a new host.
        case agentGuard
        public var isThreat: Bool { self == .malware || self == .phishing || self == .scam || self == .threat }
    }
    public var kind: Kind
    /// The list that has it (HaGeZi Threat Intelligence Feeds) or, for the agent guard, the rule (paste site, raw IP address).
    public var list: String
    /// The host name or address that matched.
    public var host: String
    /// The agent whose process tree made the connection: Claude Code, Codex, Cursor.
    public var agent: String?
    /// The agent's own process id, to find its session in the agent network log.
    public var agentPID: Int32?
    /// The process that connected: npm, curl, node.
    public var process: String?
    /// The desktop app the agent runs in, such as T3 Code; nil in a terminal or before Kilobat recorded hosts.
    public var agentHostApp: String?
    public init(kind: Kind, list: String, host: String, agent: String? = nil, agentPID: Int32? = nil, process: String? = nil, agentHostApp: String? = nil) {
        self.kind = kind; self.list = list; self.host = host; self.agent = agent; self.agentPID = agentPID; self.process = process; self.agentHostApp = agentHostApp
    }
    /// The agent as shown: "Claude Code in T3 Code".
    public var agentLabel: String? { agent.map { AgentHost.label($0, host: agentHostApp) } }

    /// For the blocked-connection journal and the CLI: "Protection: malware · URLhaus · malware.example".
    public var summary: String { "Protection: \(kind == .agentGuard ? "agent guard" : kind.rawValue) · \(list) · \(host)" }
}

/// Connections one process made for another app, as the filter saw them: com.apple.nsurlsessiond for com.apple.Music.
/// The filter sees a connection when it opens, not the bytes after it, so these are counts.
public struct DelegatedFlows: Codable, Sendable, Equatable, Identifiable {
    /// Signing identifiers of the process that connected and the app it connected for.
    public let process: String
    public let app: String
    public var allowed: Int
    public var blocked: Int
    public var last: Date
    public var id: String { process + "|" + app }
    public init(process: String, app: String, allowed: Int = 0, blocked: Int = 0, last: Date = Date()) {
        self.process = process; self.app = app; self.allowed = allowed; self.blocked = blocked; self.last = last
    }
}

/// An app with no rule whose connections the filter is holding until the user allows or blocks it.
public struct PendingApproval: Codable, Identifiable, Sendable, Equatable {
    public struct Destination: Codable, Sendable, Equatable, Hashable {
        public let host: String?
        public let address: String?
        public let port: String?
        public init(host: String?, address: String?, port: String?) { self.host = host; self.address = address; self.port = port }
        public var label: String { (host ?? address ?? String(localized: "Unknown", comment: "An unknown connection destination")) + (port.map { ":" + $0 } ?? "") }
    }
    /// The rule key: a bundle or signing identifier.
    public let app: String
    public let process: String
    public let path: String?
    public let signer: String?
    public let signatureValid: Bool
    public let pid: Int32
    public let uid: UInt32
    public var requests: Int
    public var waiting: Int
    public var destinations: [Destination]
    public let first: Date
    public var last: Date
    /// The Team ID the signature names, for a rule covering everything from the same developer; nil without one.
    public var team: String?
    /// Nil when the app itself is new. Otherwise the app asks about new destinations and this prompt is about one site
    /// (`PendingApproval.site(for:)`): a burst to the same domain waits as one prompt.
    public var site: String?
    /// Changes whenever what the prompt shows changes, such as a destination joining it. An answer names the id it
    /// was given for, and the filter refuses one for a prompt that has changed since (RESEARCH-DECISIONS area 12).
    public var approvalID: UUID?
    public var id: String { site.map { app + "|" + $0 } ?? app }
    public init(app: String, process: String, path: String?, signer: String?, signatureValid: Bool, pid: Int32, uid: UInt32,
                requests: Int = 1, waiting: Int = 1, destinations: [Destination], first: Date = Date(), last: Date = Date(),
                team: String? = nil, site: String? = nil, approvalID: UUID? = UUID()) {
        self.app = app; self.process = process; self.path = path; self.signer = signer; self.signatureValid = signatureValid
        self.pid = pid; self.uid = uid; self.requests = requests; self.waiting = waiting; self.destinations = destinations; self.first = first; self.last = last
        self.team = team; self.site = site; self.approvalID = approvalID
    }

    /// The site a destination prompt groups by: the registrable-looking domain (the last two labels, three under a
    /// two-letter country code with a short second level such as co.uk or com.au), or the address when there's no name.
    public static func site(for destination: Destination) -> String {
        guard let host = destination.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")), !host.isEmpty,
              AddressRange.parse(host) == nil else { return destination.address ?? destination.host ?? "" }
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        let tld = labels[labels.count - 1], second = labels[labels.count - 2]
        let take = tld.count == 2 && second.count <= 3 ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }
}

/// An answer to a prompt, as the app sends it to the filter.
public struct ApprovalAnswer: Codable, Sendable, Equatable {
    /// How far an answer about a new destination reaches.
    public enum Scope: String, Codable, Sendable, CaseIterable {
        /// The host names shown, exactly.
        case host
        /// The whole site and its subdomains.
        case domain
        /// Anywhere: the app no longer asks about destinations.
        case anywhere
    }
    public var app: String
    public var site: String?
    /// The id of the prompt as it was shown; nil only from an app that predates approval ids.
    public var approvalID: UUID?
    public var allowed: Bool
    /// What the prompt showed when it was answered.
    public var destinations: [PendingApproval.Destination]
    public var scope: Scope?
    public init(app: String, site: String? = nil, approvalID: UUID?, allowed: Bool, destinations: [PendingApproval.Destination], scope: Scope? = nil) {
        self.app = app; self.site = site; self.approvalID = approvalID; self.allowed = allowed; self.destinations = destinations; self.scope = scope
    }
    public init(_ approval: PendingApproval, allowed: Bool, scope: Scope? = nil) {
        self.init(app: approval.app, site: approval.site, approvalID: approval.approvalID, allowed: allowed, destinations: approval.destinations, scope: scope)
    }
    /// Whether this answer covers a destination: the host names shown for `host`, the site and its subdomains for
    /// `domain`, everything for `anywhere` and for an answer about the app itself.
    public func covers(_ destination: PendingApproval.Destination) -> Bool {
        guard let site, let scope, scope != .anywhere else { return true }
        let host = destination.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        switch scope {
        case .host: return destinations.contains { ($0.host?.lowercased() ?? $0.address) == (host ?? destination.address) }
        case .domain: return host.map { $0 == site || $0.hasSuffix("." + site) } ?? (destination.address == site)
        case .anywhere: return true
        }
    }
}

@objc public protocol FilterEventService {
    func recentEvents(reply: @escaping (Data) -> Void)
    /// Apps waiting for a decision. Asking also tells the filter someone is there to answer.
    func pendingApprovals(reply: @escaping (Data) -> Void)
    /// Releases an app's held connections, letting them through or dropping them.
    func decide(_ app: String, allowed: Bool, reply: @escaping (Bool) -> Void)
    /// Recently seen hostnames by remote address, so open connections can be named.
    func hostnames(reply: @escaping (Data) -> Void)
    /// Connections system services made for other apps, as encoded `[DelegatedFlows]`.
    func delegatedFlows(reply: @escaping (Data) -> Void)
    /// The digest of the Protection index the filter uses, empty when it has none.
    func protectionDigest(reply: @escaping (String) -> Void)
    /// Hands the filter a new Protection index (`ProtectionIndex`); it checks the file, keeps it on its own disk and maps it.
    func installProtection(_ index: Data, reply: @escaping (Bool) -> Void)
    /// Answers a prompt with an encoded `ApprovalAnswer`. False when the prompt has changed since it was shown (its
    /// approval id is no longer current) or is gone; nothing is released then.
    func decideApproval(_ answer: Data, reply: @escaping (Bool) -> Void)
    /// Apps alert mode let through, as encoded `[NewAppSighting]`.
    func newApps(reply: @escaping (Data) -> Void)
    /// The connection log's last hour and the rule-hit counts since the last ask, as an encoded `ConnectionLogSnapshot`.
    /// With `record` the log keeps recording for another minute; without, it stops and empties. `browsers` includes them.
    func connectionLog(record: Bool, browsers: Bool, reply: @escaping (Data) -> Void)
}

/// Browsers by bundle ID prefix, of the process or the app that owns it: what they reach is browsing history, so the
/// connection log and alert mode's list leave their destinations out.
public enum BrowserApps {
    public static let prefixes = ["com.apple.Safari", "com.apple.WebKit", "com.google.Chrome", "org.chromium.", "company.thebrowser.", "com.microsoft.edgemac",
                                  "org.mozilla.", "com.brave.Browser", "com.operasoftware.", "com.vivaldi.", "app.zen-browser.", "com.kagi.kagimacOS",
                                  "com.duckduckgo.macos.browser", "ai.perplexity.comet", "com.openai.atlas"]
    public static func contains(_ id: String) -> Bool { prefixes.contains { id.hasPrefix($0) } }
}

/// An app with no rule that alert mode let through, as the filter saw it: for the quiet list to review later.
public struct NewAppSighting: Codable, Sendable, Equatable, Identifiable {
    public let app: String
    public var process: String
    public var first: Date
    public var last: Date
    public var connections: Int
    /// The first few destinations ("api.example.com:443"); none for a browser.
    public var destinations: [String]
    public var id: String { app }
    public init(app: String, process: String, first: Date = Date(), last: Date = Date(), connections: Int = 1, destinations: [String] = []) {
        self.app = app; self.process = process; self.first = first; self.last = last; self.connections = connections; self.destinations = destinations
    }
    public static let maximumDestinations = 5
}

/// Alert mode's sightings, per user: one dictionary update per connection from an app without a rule, bounded.
final class NewAppRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var sightings: [UInt32: [String: NewAppSighting]] = [:]
    /// Apps not to list: Apple's own software, checked once per app.
    private var ignored: Set<String> = []
    static let capacity = 200

    /// `isApple` is asked only the first time an app is seen.
    func record(uid: UInt32, app: String, process: String, destination: String?, now: Date = Date(), isApple: () -> Bool) {
        let known = lock.withLock { () -> Bool? in
            if ignored.contains(app) { return nil }
            guard var sighting = sightings[uid]?[app] else { return false }
            sighting.connections += 1; sighting.last = now
            if let destination, !BrowserApps.contains(app), sighting.destinations.count < NewAppSighting.maximumDestinations, !sighting.destinations.contains(destination) {
                sighting.destinations.append(destination)
            }
            sightings[uid]?[app] = sighting
            return true
        }
        guard known == false else { return }
        if isApple() { lock.withLock { if ignored.count > 2_000 { ignored = [] }; ignored.insert(app) }; return }
        lock.withLock {
            var table = sightings[uid] ?? [:]
            if table.count >= Self.capacity, let oldest = table.min(by: { $0.value.last < $1.value.last })?.key { table[oldest] = nil }
            table[app] = NewAppSighting(app: app, process: process, first: now, last: now,
                                        destinations: destination.map { BrowserApps.contains(app) ? [] : [$0] } ?? [])
            sightings[uid] = table
        }
    }
    func encoded(for uid: UInt32) -> Data {
        let rows = lock.withLock { Array((sightings[uid] ?? [:]).values).sorted { $0.first > $1.first } }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(rows)) ?? Data("[]".utf8)
    }
}

/// One row of the connection log: one app's connections to one destination with one verdict, folded together.
public struct ConnectionLogEntry: Codable, Sendable, Equatable, Identifiable {
    public let app: String
    public let process: String
    /// The host name, or the address when there was none.
    public let destination: String
    public let port: String?
    /// "tcp" or "udp".
    public let transport: String?
    public let direction: String
    /// "allow", "block" or "ask".
    public let verdict: String
    /// The rule that decided the first of them, as the blocked-connection journal words it.
    public var reason: String
    public var count: Int
    public var first: Date
    public var last: Date
    public var id: String { [app, destination, port ?? "", transport ?? "", direction, verdict].joined(separator: "|") }
    public init(app: String, process: String, destination: String, port: String?, transport: String?, direction: String, verdict: String, reason: String,
                count: Int = 1, first: Date = Date(), last: Date = Date()) {
        self.app = app; self.process = process; self.destination = destination; self.port = port; self.transport = transport; self.direction = direction
        self.verdict = verdict; self.reason = reason; self.count = count; self.first = first; self.last = last
    }
}

/// What the filter hands over when asked: the log's last hour and the rule-hit counts since the last ask.
public struct ConnectionLogSnapshot: Codable, Sendable, Equatable {
    public var entries: [ConnectionLogEntry]
    /// By `RuleHitKey`; counted whether or not the log records.
    public var hits: [String: Int]
    /// When this session's log began.
    public var since: Date?
    public init(entries: [ConnectionLogEntry] = [], hits: [String: Int] = [:], since: Date? = nil) { self.entries = entries; self.hits = hits; self.since = since }
    /// The log keeps the last hour.
    public static let window: TimeInterval = 3_600
}

/// The keys rule-hit counts are kept under, shared by the filter and the Rules list.
public enum RuleHitKey {
    public static let timedPrefix = "timed:"
    public static func app(profile: String, key: String) -> String { "app:" + profile + "|" + key }
    public static func destination(_ id: UUID) -> String { "destination:" + id.uuidString }
    public static func blocked(_ entry: String) -> String { "blocked:" + entry }
    public static func subscription(_ list: String) -> String { "subscription:" + list }
}

/// The connection log and rule-hit counts in the filter, per user. Recording costs one lock and one dictionary update
/// per connection, and happens only while the app asked in the last minute; a minute without asking empties it, so
/// nothing outlives Kilobat quitting. At most 2,000 rows per user over the last hour; browsers only when asked for.
final class ConnectionLogRecorder: @unchecked Sendable {
    private struct Key: Hashable { let app: String; let destination: String; let port: String?; let transport: String?; let direction: String; let verdict: String }
    private struct Asked { var at: TimeInterval; var browsers: Bool; var since: Date }
    private let lock = NSLock()
    private var rows: [UInt32: [Key: ConnectionLogEntry]] = [:]
    private var asked: [UInt32: Asked] = [:]
    private var hits: [UInt32: [String: Int]] = [:]
    static let capacity = 2_000
    static let idle: TimeInterval = 60

    /// A rule decided a connection.
    func hit(_ key: String, uid: UInt32) {
        lock.withLock {
            var table = hits[uid] ?? [:]
            guard table[key] != nil || table.count < 5_000 else { return }
            table[key, default: 0] += 1
            hits[uid] = table
        }
    }

    /// `uptime` is awake time, so a change of the clock doesn't stop or keep the log. `reason` is worded only for a new row.
    func record(uid: UInt32, app: String, process: String, host: String?, address: String?, port: String?, transport: String?, direction: String,
                verdict: String, reason: () -> String, now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard let ask = asked[uid], uptime - ask.at < Self.idle else {
            if asked[uid] != nil { asked[uid] = nil; rows[uid] = nil }
            return
        }
        guard ask.browsers || !BrowserApps.contains(app), let destination = host ?? address else { return }
        let key = Key(app: app, destination: destination, port: port, transport: transport, direction: direction, verdict: verdict)
        var table = rows[uid] ?? [:]
        if var row = table[key] {
            row.count += 1; row.last = now
            table[key] = row
        } else {
            if table.count >= Self.capacity { table = table.filter { now.timeIntervalSince($0.value.last) < ConnectionLogSnapshot.window } }
            if table.count >= Self.capacity, let oldest = table.min(by: { $0.value.last < $1.value.last })?.key { table[oldest] = nil }
            table[key] = ConnectionLogEntry(app: app, process: process, destination: destination, port: port, transport: transport, direction: direction,
                                            verdict: verdict, reason: reason(), first: now, last: now)
        }
        rows[uid] = table
    }

    /// The log and the counts since the last ask. With `record` the log goes on recording for another minute.
    func snapshot(uid: UInt32, record: Bool, browsers: Bool, now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Data {
        let snapshot: ConnectionLogSnapshot = lock.withLock {
            if record {
                let since = asked[uid].map { uptime - $0.at < Self.idle ? $0.since : now } ?? now
                asked[uid] = Asked(at: uptime, browsers: browsers, since: since)
            } else { asked[uid] = nil; rows[uid] = nil }
            var table = rows[uid] ?? [:]
            table = table.filter { now.timeIntervalSince($0.value.last) < ConnectionLogSnapshot.window && (browsers || !BrowserApps.contains($0.key.app)) }
            rows[uid] = table.isEmpty ? nil : table
            // System services run as root for every user; the person at the Mac sees their rule hits too.
            var counted = hits.removeValue(forKey: uid) ?? [:]
            if uid != 0, let root = hits.removeValue(forKey: 0) { counted.merge(root, uniquingKeysWith: +) }
            return ConnectionLogSnapshot(entries: Array(table.values), hits: counted, since: record ? asked[uid]?.since : nil)
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(snapshot)) ?? Data("{}".utf8)
    }
}

/// Connections held while the user decides: from apps without a rule, and from apps that ask about new destinations
/// (one prompt per app and site, so a burst to one domain asks once). Held connections give up after a minute so
/// nothing hangs forever; the prompt stays until someone answers. Every change to what a prompt shows gives it a new
/// approval id, and an answer for an id that is no longer current is refused (RESEARCH-DECISIONS area 12).
final class ApprovalQueue<Flow>: @unchecked Sendable {
    private struct Held { let flow: Flow; let destination: PendingApproval.Destination; let at: Date }
    private struct Entry { var approval: PendingApproval; var flows: [Held] }
    private let lock = NSLock()
    private struct Key: Hashable { let uid: UInt32; let app: String; let site: String? }
    private var entries: [Key: Entry] = [:]
    private var decided: [Key: (Bool, Date)] = [:]
    /// Answers about destinations from the last half-minute, newest last, until the rule the app saves arrives.
    private var answers: [(uid: UInt32, answer: ApprovalAnswer, at: Date)] = []
    private var lastAsked: [UInt32: Date] = [:]
    private var timer: DispatchSourceTimer?
    var resume: (Flow, Bool) -> Void = { _, _ in }
    /// Prompts one user can have waiting; past it, a new destination prompt isn't held (the flow goes on, as when nobody is there).
    static var capacity: Int { 50 }
    static var destinationsShown: Int { 20 }

    /// Someone polled recently, so there is a person to ask.
    func listening(for uid: UInt32) -> Bool { lock.withLock { Date().timeIntervalSince(lastAsked[uid] ?? .distantPast) < 15 } }

    /// Whether another prompt fits, or this one is already waiting.
    func canHold(app: String, site: String?, uid: UInt32) -> Bool {
        lock.withLock { entries[Key(uid: uid, app: app, site: site)] != nil || entries.keys.filter { $0.uid == uid }.count < Self.capacity }
    }

    /// A decision about the app made moments ago, before the saved rule reaches the filter.
    func recentDecision(_ app: String, uid: UInt32) -> Bool? {
        lock.withLock { decided[Key(uid: uid, app: app, site: nil)].flatMap { Date().timeIntervalSince($0.1) < 30 ? $0.0 : nil } }
    }

    /// An answer about this destination made moments ago; the newest that covers it.
    func recentDestination(_ app: String, destination: PendingApproval.Destination, uid: UInt32, now: Date = Date()) -> Bool? {
        lock.withLock {
            guard !answers.isEmpty else { return nil }
            return answers.last { $0.uid == uid && $0.answer.app == app && now.timeIntervalSince($0.at) < 30 && $0.answer.covers(destination) }?.answer.allowed
        }
    }

    func hold(_ flow: Flow, approval: PendingApproval) {
        lock.lock(); defer { lock.unlock() }
        let key = Key(uid: approval.uid, app: approval.app, site: approval.site)
        var entry = entries[key] ?? Entry(approval: approval, flows: [])
        if entries[key] != nil {
            entry.approval.requests += 1; entry.approval.last = Date()
            for destination in approval.destinations where !entry.approval.destinations.contains(destination) && entry.approval.destinations.count < Self.destinationsShown {
                entry.approval.destinations.append(destination)
                // What the prompt shows changed, so an answer to the earlier one no longer fits it.
                entry.approval.approvalID = UUID()
            }
        }
        entry.flows.append(Held(flow: flow, destination: approval.destinations.first ?? .init(host: nil, address: nil, port: nil), at: Date()))
        entry.approval.waiting = entry.flows.count
        entries[key] = entry
        startTimer()
    }

    func encoded(for uid: UInt32) -> Data {
        lock.lock(); defer { lock.unlock() }
        lastAsked[uid] = Date()
        let visible = entries.values.map(\.approval).filter { $0.uid == uid }.sorted { $0.first < $1.first }
        return (try? JSONEncoder().encode(visible)) ?? Data("[]".utf8)
    }

    /// The answer an app before approval ids gives: about the app itself, whatever it showed.
    func decide(_ app: String, allowed: Bool, uid: UInt32) -> Bool {
        answer(ApprovalAnswer(app: app, approvalID: nil, allowed: allowed, destinations: []), uid: uid)
    }

    /// Releases what the answer covers. An answer about the app releases all its held connections; one about a
    /// destination releases those its scope covers and leaves the rest waiting under a new approval id. False, with
    /// nothing released, when the prompt is gone or has changed since it was shown.
    func answer(_ answer: ApprovalAnswer, uid: UInt32, now: Date = Date()) -> Bool {
        lock.lock()
        let key = Key(uid: uid, app: answer.app, site: answer.site)
        guard var entry = entries[key], answer.approvalID == nil || answer.approvalID == entry.approval.approvalID else { lock.unlock(); return false }
        var released: [Flow] = []
        if answer.site == nil {
            entries[key] = nil
            released = entry.flows.map(\.flow)
            decided[key] = (answer.allowed, now)
        } else {
            let covered = entry.flows.filter { answer.covers($0.destination) }, kept = entry.flows.filter { !answer.covers($0.destination) }
            released = covered.map(\.flow)
            if kept.isEmpty { entries[key] = nil } else {
                entry.flows = kept
                entry.approval.destinations = entry.approval.destinations.filter { !answer.covers($0) }
                entry.approval.waiting = kept.count
                entry.approval.approvalID = UUID()
                entries[key] = entry
            }
            answers.append((uid, answer, now))
            if answers.count > 64 { answers.removeFirst(answers.count - 64) }
        }
        lock.unlock()
        for flow in released { resume(flow, answer.allowed) }
        return true
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.expire() }
        timer.resume(); self.timer = timer
    }

    func expire(now: Date = Date()) {
        lock.lock()
        var expired: [Flow] = []
        for (key, entry) in entries {
            let old = entry.flows.filter { now.timeIntervalSince($0.at) >= 60 }, kept = entry.flows.filter { now.timeIntervalSince($0.at) < 60 }
            expired += old.map(\.flow)
            // Forget prompts nobody answered for half an hour; they are asked again on the next connection.
            if kept.isEmpty && now.timeIntervalSince(entry.approval.last) > 1_800 { entries[key] = nil; continue }
            entries[key]?.flows = kept; entries[key]?.approval.waiting = kept.count
        }
        decided = decided.filter { now.timeIntervalSince($0.value.1) < 30 }
        answers.removeAll { now.timeIntervalSince($0.at) >= 30 }
        lock.unlock()
        for flow in expired { resume(flow, false) }
    }
}
