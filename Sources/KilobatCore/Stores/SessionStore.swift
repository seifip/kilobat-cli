import Foundation
import Observation
import Darwin
import UserNotifications

/// What keeps the Mac awake: a timer, a transfer that is still moving, or nothing until stopped.
public enum AwakeMode: Codable, Equatable, Sendable {
    case timer(until: Date)
    /// Until the app (or the whole Mac when `app` is nil) has been quiet for a few minutes.
    case untilQuiet(app: String?, name: String)
    case indefinite

    public var title: String {
        switch self {
        case .timer(let until): "Until " + until.formatted(date: .omitted, time: .shortened)
        case .untilQuiet(nil, _): "Until downloads finish"
        case .untilQuiet(_, let name): "Until \(name) finishes"
        case .indefinite: "Until you turn it off"
        }
    }
}

/// One unattended stretch of work: an awake session or an AI agent's run, with what it moved and what went wrong.
public struct WorkSession: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case awake, agent }
    public var id = UUID()
    public let kind: Kind
    public var title: String
    public let start: Date
    public var end: Date?
    /// Why it ended, in a few words.
    public var ended: String?
    public var received: UInt64 = 0
    public var sent: UInt64 = 0
    /// Bytes by app or process name.
    public var apps: [String: UInt64] = [:]
    /// Remote hosts in the order they first appeared, capped.
    public var destinations: [String] = []
    /// Network changes and drops while it ran.
    public var events: [String] = []
    public var batteryStart: Int?
    public var batteryEnd: Int?
    public var peakThermal = "nominal"
    public var lastActive: Date

    public var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }
    public var total: UInt64 { received + sent }
    public var summary: String {
        let length = duration < 60 ? "under a minute" : Duration.seconds(duration.rounded()).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
        var parts = [length,
                     "↓ " + TrafficFormat.bytes(received) + "  ↑ " + TrafficFormat.bytes(sent)]
        if !events.isEmpty { parts.append(events.count == 1 ? "1 network change" : "\(events.count) network changes") }
        if let start = batteryStart, let end = batteryEnd, start > end { parts.append("battery −\(start - end)%") }
        return parts.joined(separator: " · ")
    }
}

/// AI coding agents, recognised by process or app name.
public enum AgentCatalog {
    static let names = ["claude": "Claude Code", "claude code": "Claude Code", "codex": "Codex", "cursor-agent": "Cursor Agent",
                        "gemini": "Gemini CLI", "aider": "Aider", "opencode": "OpenCode", "goose": "Goose", "amp": "Amp",
                        "droid": "Factory Droid", "qwen": "Qwen Code", "copilot": "Copilot CLI", "crush": "Crush"]
    public static func agent(for app: AppTraffic) -> String? {
        let process = app.id.hasPrefix("process:") ? String(app.id.dropFirst(8)).lowercased() : ""
        return names[process] ?? names[app.name.lowercased()]
    }
}

/// Keeps the Mac awake on purpose and watches AI agents, turning both into sessions with a summary at the end.
/// Fed every couple of seconds with per-app rates by whoever owns a TrafficStore (the app, or the CLI).
@MainActor @Observable public final class SessionStore {
    public private(set) var mode: AwakeMode?
    public private(set) var awake: WorkSession?
    /// Agents currently working, by agent name.
    public private(set) var agents: [String: WorkSession] = [:]
    public private(set) var history: [WorkSession] = []
    /// Bytes per second the awake session watches, smoothed over the last half minute.
    public private(set) var watchedRate: Double = 0
    /// How long the watched traffic has stayed below the quiet threshold.
    public private(set) var quietSince: Date?
    public var keepAwakeForAgents: Bool { didSet { defaults.set(keepAwakeForAgents, forKey: "awake.agents") } }
    public var notify: Bool { didSet { defaults.set(notify, forKey: "awake.notify") } }
    public var quietMinutes: Int { didSet { defaults.set(quietMinutes, forKey: "awake.quietMinutes") } }
    public var keepDisplayOn: Bool { didSet { defaults.set(keepDisplayOn, forKey: "awake.display"); assertion = nil; updateAssertion() } }
    /// An ntfy topic or any webhook that receives a summary when a session ends.
    public var webhook: String { didSet { defaults.set(webhook, forKey: "awake.webhook") } }
    public var onEnd: ((WorkSession) -> Void)?

    /// Below this a download or an agent counts as quiet.
    public static let quietRate: Double = 16_000
    static let agentActiveRate: Double = 1_500
    private let defaults: UserDefaults
    private let directory: URL?
    private var assertion: SleepAssertion?
    private var samples: [Double] = []
    private var lastDestinationSample = Date.distantPast
    private var hostNames: [String: String] = [:]

    /// `directory` nil keeps history in memory only, for the CLI.
    public init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.directory = directory; self.defaults = defaults
        keepAwakeForAgents = defaults.object(forKey: "awake.agents") as? Bool ?? true
        notify = defaults.object(forKey: "awake.notify") as? Bool ?? true
        quietMinutes = defaults.object(forKey: "awake.quietMinutes") as? Int ?? 3
        keepDisplayOn = defaults.bool(forKey: "awake.display")
        webhook = defaults.string(forKey: "awake.webhook") ?? ""
        if let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("sessions.json")) {
            history = (try? JSONDecoder().decode([WorkSession].self, from: data)) ?? []
        }
    }

    public var holdingAwake: Bool { assertion != nil }
    public var busyAgents: [WorkSession] { agents.values.sorted { $0.start < $1.start } }

    public func start(_ mode: AwakeMode, now: Date = Date()) {
        if awake != nil { finish(reason: "Replaced", now: now) }
        self.mode = mode
        samples = []; quietSince = nil
        awake = WorkSession(kind: .awake, title: mode.title, start: now, batteryStart: PowerState.read().batteryPercent, lastActive: now)
        updateAssertion(); requestAlertsIfNeeded()
    }
    public func stop(now: Date = Date()) { finish(reason: "Turned off", now: now) }

    /// Called every couple of seconds with the latest per-app traffic.
    public func tick(apps: [AppTraffic], interval: TimeInterval, now: Date = Date()) {
        let power = PowerState.read()
        trackAgents(apps, interval: interval, power: power, now: now)
        if var session = awake, let mode {
            let watched: [AppTraffic]
            // An app's helpers (Chrome Helper, Steam Helper) are named after it and move its data.
            if case .untilQuiet(let id?, let name) = mode { watched = apps.filter { $0.id == id || (!name.isEmpty && ($0.name == name || $0.name.hasPrefix(name + " "))) } } else { watched = apps }
            add(watched, to: &session, interval: interval, power: power)
            samples = Array((samples + [watched.reduce(0) { $0 + $1.rate }]).suffix(max(1, Int(30 / max(interval, 0.5)))))
            watchedRate = samples.reduce(0, +) / Double(samples.count)
            if watchedRate >= Self.quietRate { quietSince = nil; session.lastActive = now } else if quietSince == nil { quietSince = now }
            awake = session
            switch mode {
            case .timer(let until) where now >= until: finish(reason: "Timer ended", now: now)
            case .untilQuiet where now.timeIntervalSince(session.start) > 60 && quietSince.map({ now.timeIntervalSince($0) >= Double(quietMinutes * 60) }) == true:
                finish(reason: "Went quiet", now: now)
            default: break
            }
        }
        updateAssertion()
        if now.timeIntervalSince(lastDestinationSample) >= 30, !agents.isEmpty {
            lastDestinationSample = now
            Task { await sampleDestinations(apps: apps) }
        }
    }

    /// Notes a network change or drop against everything running, and warns about agents that may need a restart.
    public func record(event: String, now: Date = Date()) {
        if awake != nil { awake?.events.append(event) }
        for name in agents.keys {
            agents[name]?.events.append(event)
            alert("Network changed while \(name) was working", "\(event). If it stops responding, it may need a nudge or a restart.")
        }
    }

    public func clearHistory() { history = []; persist() }

    private func trackAgents(_ apps: [AppTraffic], interval: TimeInterval, power: PowerState, now: Date) {
        var byAgent: [String: [AppTraffic]] = [:]
        for app in apps { if let agent = AgentCatalog.agent(for: app) { byAgent[agent, default: []].append(app) } }
        // Helpers an agent launches (npm, git, curl, python) count towards its run.
        for (agent, roots) in byAgent {
            let family = Self.descendants(of: roots.flatMap(\.processIDs))
            let helpers = apps.filter { AgentCatalog.agent(for: $0) == nil && $0.processIDs.contains(where: family.contains) }
            byAgent[agent] = roots + helpers
        }
        for (agent, members) in byAgent {
            let alive = members.contains { $0.processIDs.contains { kill($0, 0) == 0 } }
            let rate = members.reduce(0) { $0 + $1.rate }
            if var session = agents[agent] {
                add(members, to: &session, interval: interval, power: power)
                if rate >= Self.agentActiveRate { session.lastActive = now }
                agents[agent] = session
                if !alive { finishAgent(agent, reason: "Exited", now: now) }
                else if now.timeIntervalSince(session.lastActive) >= Double(quietMinutes * 60) { finishAgent(agent, reason: "Went quiet", now: now) }
            } else if alive && rate >= Self.agentActiveRate {
                agents[agent] = WorkSession(kind: .agent, title: agent, start: now, batteryStart: power.batteryPercent, peakThermal: power.thermal, lastActive: now)
                requestAlertsIfNeeded()
            }
        }
        for agent in agents.keys where byAgent[agent] == nil { finishAgent(agent, reason: "Exited", now: now) }
    }

    private func add(_ apps: [AppTraffic], to session: inout WorkSession, interval: TimeInterval, power: PowerState) {
        for app in apps where app.rate > 0 {
            let down = UInt64(app.downloadRate * interval), up = UInt64(app.uploadRate * interval)
            session.received += down; session.sent += up
            session.apps[app.name, default: 0] += down + up
        }
        if PowerState.heat(power.thermal) > PowerState.heat(session.peakThermal) { session.peakThermal = power.thermal }
    }

    private func finishAgent(_ agent: String, reason: String, now: Date) {
        guard var session = agents.removeValue(forKey: agent) else { return }
        // Quiet time after the last traffic isn't work; end the run when it actually went quiet.
        session.end = reason == "Went quiet" ? session.lastActive : now
        session.ended = reason
        session.batteryEnd = PowerState.read().batteryPercent
        archive(session)
        let finished = reason == "Went quiet" ? "\(agent) went quiet" : "\(agent) stopped"
        alert(finished, (reason == "Went quiet" ? "Finished, or waiting for you. " : "") + session.summary, session: session)
    }

    private func finish(reason: String, now: Date) {
        guard var session = awake else { return }
        session.end = now; session.ended = reason
        session.batteryEnd = PowerState.read().batteryPercent
        awake = nil; mode = nil; samples = []; watchedRate = 0; quietSince = nil
        updateAssertion()
        archive(session)
        if reason != "Turned off" && reason != "Replaced" {
            alert(reason == "Went quiet" ? "Done. Your Mac can sleep again" : "Awake timer ended", "Stayed awake " + session.summary, session: session)
        }
    }

    private func archive(_ session: WorkSession) {
        history = Array(([session] + history).prefix(200))
        persist()
        onEnd?(session)
    }

    private func updateAssertion() {
        let wanted = mode != nil || (keepAwakeForAgents && !agents.isEmpty)
        if wanted && assertion == nil {
            let reason = mode.map { "Kilobat: " + $0.title } ?? "Kilobat: " + busyAgents.map(\.title).joined(separator: ", ") + " working"
            assertion = SleepAssertion(reason: reason, display: keepDisplayOn)
        } else if !wanted { assertion?.release(); assertion = nil }
    }

    private func persist() {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(history).write(to: directory.appendingPathComponent("sessions.json"), options: .atomic)
    }

    /// Asks for notification permission once, the first time a session could send one.
    private func requestAlertsIfNeeded() {
        guard notify, Bundle.main.bundleIdentifier != nil, !defaults.bool(forKey: "awake.askedAlerts") else { return }
        defaults.set(true, forKey: "awake.askedAlerts")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func alert(_ title: String, _ body: String, session: WorkSession? = nil) {
        // Notifications need an app bundle; the CLI has none.
        if notify, Bundle.main.bundleIdentifier != nil {
            let content = UNMutableNotificationContent(); content.title = title; content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        guard let url = URL(string: webhook.trimmingCharacters(in: .whitespaces)), url.scheme == "https", url.host != nil else { return }
        var request = URLRequest(url: url, timeoutInterval: 10); request.httpMethod = "POST"
        if url.host?.hasSuffix("ntfy.sh") == true || url.path.split(separator: "/").count == 1 {
            // ntfy: plain text with the title in a header.
            request.setValue(title, forHTTPHeaderField: "Title"); request.setValue("bat", forHTTPHeaderField: "Tags")
            request.httpBody = Data(body.utf8)
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var payload: [String: Any] = ["title": title, "body": body, "source": "Kilobat"]
            if let session, let data = try? JSONEncoder().encode(session), let json = try? JSONSerialization.jsonObject(with: data) { payload["session"] = json }
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        }
        URLSession.shared.dataTask(with: request).resume()
    }

    private func sampleDestinations(apps: [AppTraffic]) async {
        for (agent, _) in agents {
            let roots = apps.filter { AgentCatalog.agent(for: $0) == agent }.flatMap(\.processIDs)
            var hosts: [String] = []
            for pid in Self.descendants(of: roots) {
                for socket in (try? await ExpertTools.destinations(pid: pid)) ?? [] {
                    guard let (host, port) = socket.remoteHostAndPort else { continue }
                    hosts.append((await name(for: host)) + ":" + port)
                }
            }
            guard var session = agents[agent] else { continue }
            for host in hosts where !session.destinations.contains(host) && session.destinations.count < 60 { session.destinations.append(host) }
            agents[agent] = session
        }
    }

    /// Reverse DNS, cached; addresses that don't resolve stay as they are.
    private func name(for address: String) async -> String {
        if let cached = hostNames[address] { return cached }
        let resolved = await Task.detached(priority: .utility) { () -> String in
            var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: 0, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var info: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(address, nil, &hints, &info) == 0, let first = info else { return address }
            defer { freeaddrinfo(info) }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0 else { return address }
            return String(cString: host)
        }.value
        hostNames[address] = resolved
        return resolved
    }

    /// Every process descended from `roots`, roots included.
    static func descendants(of roots: [Int32]) -> Set<Int32> {
        var family = Set(roots), queue = roots
        while let pid = queue.popLast() {
            var children = [Int32](repeating: 0, count: 256)
            let count = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<Int32>.size))
            guard count > 0 else { continue }
            for child in children.prefix(Int(count)) where child > 0 && family.insert(child).inserted { queue.append(child) }
        }
        return family
    }
}
