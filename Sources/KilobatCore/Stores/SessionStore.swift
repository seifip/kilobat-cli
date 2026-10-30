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
        case .timer(let until): String(localized: "Until \(until.formatted(date: .omitted, time: .shortened))")
        case .untilQuiet(nil, _): String(localized: "Until downloads finish")
        case .untilQuiet(_, let name): String(localized: "Until \(name) finishes")
        case .indefinite: String(localized: "Until you turn it off")
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
    /// Agent runs: the session id and folder the agent's hooks reported; nil for runs seen only in traffic.
    public var session: String?
    public var cwd: String?
    /// The folder's name, e.g. kilobat for ~/GitHub/kilobat.
    public var project: String?
    /// While running, what the run is doing; once ended, what it was doing last (`ended` says how it ended).
    public var state: AgentState?
    /// The agent's own hooks report this run, so its state is known rather than guessed from traffic.
    public var hooks: Bool?
    /// Its bytes may include other runs of the same agent: they share processes, and traffic is counted per process.
    public var sharedTraffic: Bool?
    /// The last hook event. `lastActive` is the last traffic and `lastCPU` the last CPU work; none of them alone means done.
    public var lastEvent: Date?
    /// When its processes last used more than 5% of a core.
    public var lastCPU: Date?
    /// What the state leaves out: "Rate-limited until 3pm", "2 background tasks still running".
    public var note: String?
    /// The agent's executable, where it was installed from and its version, read from its path.
    public var executable: String?
    public var origin: String?
    public var version: String?
    /// Other installs of the same agent in the usual places.
    public var otherInstalls: [String]?

    public var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }
    /// "codex 0.52.0 from npm (node 22.3.0) · /opt/homebrew/bin/codex is another install".
    public var install: String? {
        guard let executable else { return nil }
        let name = URL(fileURLWithPath: executable).lastPathComponent + (version.map { " " + $0 } ?? "")
        var text = origin.map { String(localized: "\(name) from \($0)", comment: "An agent's executable and where it was installed from, e.g. “codex 0.52.0 from npm”") } ?? String(localized: "\(name) at \(executable)")
        if let others = otherInstalls, !others.isEmpty {
            let list = others.joined(separator: ", ")
            text += " · " + (others.count == 1 ? String(localized: "\(list) is another install") : String(localized: "\(list) are other installs"))
        }
        return text
    }
    mutating func describe(_ install: AgentInstall) {
        executable = install.executable; origin = install.origin; version = install.version
        otherInstalls = install.others.isEmpty ? nil : install.others
    }
    public var total: UInt64 { received + sent }
    /// Agents poll and sync in the background. A real turn uploads its context, so a run that moved under
    /// 256 KB, or worked under a minute and moved under a megabyte, isn't worth keeping or announcing.
    /// A run its hooks report is real whatever it moved, so only a short, light one is dropped.
    public var isBlip: Bool {
        guard kind == .agent else { return false }
        let worked = (hooks == true ? end ?? lastActive : lastActive).timeIntervalSince(start)
        return (hooks != true && total < 256_000) || (worked < 60 && total < 1_000_000)
    }
    public var summary: String {
        let length = duration < 60 ? String(localized: "under a minute") : Duration.seconds(duration.rounded()).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
        var parts = [length,
                     "↓ " + TrafficFormat.bytes(received) + "  ↑ " + TrafficFormat.bytes(sent)]
        if !events.isEmpty { parts.append(events.count == 1 ? String(localized: "1 network change") : String(localized: "\(events.count) network changes")) }
        if let start = batteryStart, let end = batteryEnd, start > end { parts.append(String(localized: "battery −\(start - end)%")) }
        return parts.joined(separator: " · ")
    }
}

/// What an agent run is doing.
public enum AgentState: String, Codable, Sendable {
    case working, waitingForYou, done, stalled, networkFailed, failed
    public var title: String {
        switch self {
        case .working: String(localized: "working", comment: "An AI agent's state")
        case .waitingForYou: String(localized: "waiting for you", comment: "An AI agent's state")
        case .done: String(localized: "done", comment: "An AI agent's state")
        case .stalled: String(localized: "stalled", comment: "An AI agent's state")
        case .networkFailed: String(localized: "network failed", comment: "An AI agent's state")
        case .failed: String(localized: "failed", comment: "An AI agent's state")
        }
    }
}

/// AI coding agents, recognised by process or app name.
public enum AgentCatalog {
    static let names = ["claude": "Claude Code", "claude code": "Claude Code", "codex": "Codex", "cursor-agent": "Cursor Agent",
                        "gemini": "Gemini CLI", "aider": "Aider", "opencode": "OpenCode", "goose": "Goose", "amp": "Amp",
                        "droid": "Factory Droid", "qwen": "Qwen Code", "copilot": "Copilot CLI", "crush": "Crush", "cline": "Cline"]
    public static func agent(for app: AppTraffic) -> String? {
        let process = app.id.hasPrefix("process:") ? String(app.id.dropFirst(8)).lowercased() : ""
        return names[process] ?? names[app.name.lowercased()]
    }
    /// The name Kilobat shows for an agent named by a hook or a process: claude → Claude Code.
    public static func name(_ raw: String) -> String? { names[raw.lowercased()] }
}

/// Keeps the Mac awake on purpose and watches AI agents, turning both into sessions with a summary at the end.
/// Fed every couple of seconds with per-app rates by whoever owns a TrafficStore (the app, or the CLI).
@MainActor @Observable public final class SessionStore {
    public private(set) var mode: AwakeMode?
    public private(set) var awake: WorkSession?
    /// Agent runs in progress, by agent name, or by agent and session (or folder) once the agent's hooks report them.
    public private(set) var agents: [String: WorkSession] = [:]
    public private(set) var history: [WorkSession] = []
    /// Bytes per second the awake session watches, smoothed over the last half minute.
    public private(set) var watchedRate: Double = 0
    /// How long the watched traffic has stayed below the quiet threshold.
    public private(set) var quietSince: Date?
    public var keepAwakeForAgents: Bool { didSet { defaults.set(keepAwakeForAgents, forKey: "awake.agents") } }
    /// Off by default: an agent waiting for an answer can wait with the Mac asleep.
    public var keepAwakeWhileWaiting: Bool { didSet { defaults.set(keepAwakeWhileWaiting, forKey: "awake.waiting"); updateAssertion() } }
    /// Off by default: with it on, working agent runs and lid-closed awake sessions keep going with the lid shut, through Kilobat's power helper.
    public var allowLidClosed: Bool { didSet { defaults.set(allowLidClosed, forKey: "awake.lidClosed"); updateAssertion() } }
    /// Awake sessions started in the app hold the lid too.
    public var lidClosedForAwake: Bool { didSet { defaults.set(lidClosedForAwake, forKey: "awake.lidForAwake"); updateAssertion() } }
    public var lidBatteryFloor: Int { didSet { defaults.set(lidBatteryFloor, forKey: "awake.lidFloor"); updateAssertion() } }
    public var lidOnlyOnAC: Bool { didSet { defaults.set(lidOnlyOnAC, forKey: "awake.lidAC"); updateAssertion() } }
    /// The longest one stretch with the lid closed may last, up to the helper's own 8 hours.
    public var lidMaxHours: Int { didSet { defaults.set(lidMaxHours, forKey: "awake.lidHours"); updateAssertion() } }
    /// Whoever places lid holds: the app's power helper. Nil in the CLI and in tests that don't need one.
    public var lid: (any LidHolding)? { didSet { lid?.request(lidRequest) } }
    public var notify: Bool { didSet { defaults.set(notify, forKey: "awake.notify") } }
    public var quietMinutes: Int { didSet { defaults.set(quietMinutes, forKey: "awake.quietMinutes") } }
    /// One screen choice for everything the app holds awake: timers, downloads, agents, the app in front and plugged in.
    public var keepDisplayOn: Bool {
        didSet {
            defaults.set(keepDisplayOn, forKey: "awake.display")
            updateAssertion()
            if let condition = frontmost, condition.display != keepDisplayOn {
                watchFrontmost(FrontmostCondition(app: condition.app, name: condition.name, display: keepDisplayOn, until: condition.until), current: frontmostActive ? condition.app : nil)
            }
        }
    }
    /// An ntfy topic or any webhook that receives a summary when a session ends.
    public var webhook: String { didSet { defaults.set(webhook, forKey: "awake.webhook") } }
    public var onEnd: ((WorkSession) -> Void)?
    /// The lid hold wanted right now, nil when the Mac may sleep with the lid closed.
    public private(set) var lidRequest: LidLease?
    /// Keeps the Mac awake while one app is in front; nil when none is set. Never asks for a lid hold.
    public private(set) var frontmost: FrontmostCondition?
    /// The condition's app is in front now, so its assertion is held.
    public private(set) var frontmostActive = false
    /// How the last condition ended: "Keynote quit", "Battery at 18%".
    public private(set) var frontmostEnded: String?

    /// Off by default: plugging in the power adapter starts an indefinite awake session, and unplugging ends it.
    /// Only a session it started: one the person started, a transfer, a frontmost condition or an agent run is left alone.
    public var awakeOnPower: Bool {
        didSet {
            defaults.set(awakeOnPower, forKey: "awake.power")
            guard awakeOnPower != oldValue else { return }
            // Once watching, the watcher stays: a plug-in while the setting is off still clears an earlier Turn Off.
            if awakeOnPower { watchPower() } else if awakeByPower { finish(reason: "Turned off", now: Date()) }
        }
    }
    /// The awake session was started by plugging in, not by the person, so unplugging ends it.
    public private(set) var awakeByPower = false
    /// The person turned the plugged-in session off; it starts again at the next plug-in, not before. Kept across
    /// relaunches until the Mac restarts, since Kilobat can't see a plug-in while it isn't running.
    public private(set) var powerSuppressed: Bool { didSet { defaults.set(powerSuppressed ? Date() : nil, forKey: "awake.powerOff") } }
    public static let pluggedInTitle = String(localized: "While plugged in")
    /// The awake session's title: "While plugged in" for one the power adapter started, else its mode's.
    public var awakeTitle: String? { awakeByPower ? Self.pluggedInTitle : mode?.title }

    /// Below this a download or an agent counts as quiet.
    public static let quietRate: Double = 16_000
    static let agentActiveRate: Double = 1_500
    /// Above this share of one core, an agent's processes are working even with little traffic.
    static let busyCores = 0.05
    var probe = ProcessProbe.live
    var readPower: () -> PowerState = { PowerState.read() }
    /// Off in tests, which report activations and power changes themselves.
    var observesWorkspace = true
    /// Whether the shared assertion keeps the screen on too.
    private(set) var displayHeld = false
    private let defaults: UserDefaults
    private let directory: URL?
    private var assertion: SleepAssertion?
    /// The frontmost condition's own assertion, so focus changes never touch the one sessions and agents share.
    private var frontmostAssertion: SleepAssertion?
    private var frontmostWatcher: FrontmostWatcher?
    private var powerWatcher: PowerSourceWatcher?
    /// On the power adapter at the last reading; nil until awake-on-power is first on.
    private var onAC: Bool?
    private var samples: [Double] = []
    private var lastDestinationSample = Date.distantPast
    private var hostNames: [String: String] = [:]
    /// Each hooked run's agent process, when the hook found it.
    private var pids: [String: Int32] = [:]
    /// Each hooked run's last event, which tells a session nobody has prompted yet from a stalled one.
    private var lastKinds: [String: AgentEvent.Kind] = [:]
    /// Agents whose hooks report their runs; their traffic no longer starts runs of its own.
    private var hooked: Set<String> = []
    /// Each process's CPU time at the last tick, and each run's CPU seconds per tick over the quiet window.
    private var cpuTimes: [Int32: UInt64] = [:]
    private var cpuWindows: [String: [(Date, Double)]] = [:]
    /// Each hooked run's children still at work, and when runs that reported done last had any.
    private var busyTasks: [String: Int] = [:]
    private var finishing: [String: Date] = [:]
    /// When the current stretch of wanting a lid hold began; the time limit counts from here.
    private var lidSince: Date?
    /// When each run began waiting for the person.
    private var waitingSince: [String: Date] = [:]
    /// Lid holds the CLI and the MCP server asked for, by their process.
    private var lidOwners: [Int32: (until: Date, reason: String)] = [:]

    /// `directory` nil keeps history in memory only, for the CLI.
    public init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.directory = directory; self.defaults = defaults
        keepAwakeForAgents = defaults.object(forKey: "awake.agents") as? Bool ?? true
        keepAwakeWhileWaiting = defaults.bool(forKey: "awake.waiting")
        allowLidClosed = defaults.bool(forKey: "awake.lidClosed")
        lidClosedForAwake = defaults.bool(forKey: "awake.lidForAwake")
        lidBatteryFloor = defaults.object(forKey: "awake.lidFloor") as? Int ?? 20
        lidOnlyOnAC = defaults.bool(forKey: "awake.lidAC")
        lidMaxHours = defaults.object(forKey: "awake.lidHours") as? Int ?? 4
        notify = defaults.object(forKey: "awake.notify") as? Bool ?? true
        quietMinutes = defaults.object(forKey: "awake.quietMinutes") as? Int ?? 3
        keepDisplayOn = defaults.bool(forKey: "awake.display")
        awakeOnPower = defaults.bool(forKey: "awake.power")
        powerSuppressed = (defaults.object(forKey: "awake.powerOff") as? Date).map { $0 > Date() - ProcessInfo.processInfo.systemUptime } ?? false
        webhook = defaults.string(forKey: "awake.webhook") ?? ""
        if let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("sessions.json")) {
            history = ((try? JSONDecoder().decode([WorkSession].self, from: data)) ?? []).filter { !$0.isBlip }
        }
    }

    public var holdingAwake: Bool { assertion != nil || frontmostAssertion != nil }
    public var holdingFrontmost: Bool { frontmostAssertion != nil }
    public var busyAgents: [WorkSession] { agents.values.sorted { $0.start < $1.start } }

    public func start(_ mode: AwakeMode, now: Date = Date()) { begin(mode, byPower: false, now: now) }
    private func begin(_ mode: AwakeMode, byPower: Bool, now: Date) {
        if awake != nil { finish(reason: "Replaced", now: now) }
        self.mode = mode; awakeByPower = byPower
        samples = []; quietSince = nil
        awake = WorkSession(kind: .awake, title: byPower ? Self.pluggedInTitle : mode.title, start: now, batteryStart: PowerState.read().batteryPercent, lastActive: now)
        updateAssertion(now: now); requestAlertsIfNeeded()
    }
    /// Turning it off ends the awake session and the frontmost condition; agent runs keep their own setting.
    /// A plugged-in session turned off stays off until the adapter is plugged in again.
    public func stop(now: Date = Date()) {
        if awakeByPower { powerSuppressed = true }
        finish(reason: "Turned off", now: now); endFrontmost("Turned off")
    }

    /// Starts following the power adapter, when awake-on-power is on: the app calls this at launch, and turning the
    /// setting on calls it too. Already plugged in, it starts the session now, unless the person turned it off during this plug-in.
    public func watchPower(now: Date = Date()) {
        guard awakeOnPower else { return }
        if observesWorkspace && powerWatcher == nil { powerWatcher = PowerSourceWatcher { [weak self] in self?.powerChanged() } }
        if onAC == nil { onAC = readPower().onAC }
        if onAC == false { powerSuppressed = false }
        startForPower(now: now)
    }
    /// The Mac switched between the adapter and its battery. Plugging in starts the session and clears an earlier
    /// Turn Off; unplugging ends only a session it started.
    public func powerChanged(now: Date = Date()) {
        let plugged = readPower().onAC
        guard plugged != onAC else { return }
        onAC = plugged; powerSuppressed = false
        if plugged { startForPower(now: now) } else if awakeByPower { finish(reason: "Unplugged", now: now) }
    }
    /// A session the person started, or a transfer, is never replaced.
    private func startForPower(now: Date) {
        guard awakeOnPower, onAC == true, !powerSuppressed, awake == nil else { return }
        begin(.indefinite, byPower: true, now: now)
    }

    /// Keeps the Mac awake whenever the condition's app is in front, until it quits, its time is up, the battery
    /// reaches the floor or it's turned off. Replaces an earlier condition; awake sessions and agent runs go on as they were.
    public func watchFrontmost(_ condition: FrontmostCondition, current: String? = FrontmostWatcher.current, now: Date = Date()) {
        frontmost = condition; frontmostEnded = nil
        frontmostActive = current == condition.app
        // The display choice may differ from the last condition's.
        frontmostAssertion?.release(); frontmostAssertion = nil
        if observesWorkspace && frontmostWatcher == nil {
            frontmostWatcher = FrontmostWatcher(activated: { [weak self] in self?.activated($0) }, terminated: { [weak self] in self?.terminated($0) })
        }
        updateFrontmost(now: now)
    }
    public func stopFrontmost() { endFrontmost("Turned off") }
    /// An app came to the front: the condition holds while it's its own app and lets go otherwise.
    public func activated(_ app: String?, now: Date = Date()) {
        guard let frontmost else { return }
        frontmostActive = app == frontmost.app
        updateFrontmost(now: now)
    }
    /// An app quit; the condition ends with its own app and nothing else does.
    public func terminated(_ app: String?) {
        guard let frontmost, app == frontmost.app else { return }
        endFrontmost(frontmost.name + " quit")
    }

    /// A lid hold for another process, the CLI's `awake --lid-closed` or MCP `keep_awake`: kept until `until` while it runs.
    /// Returns the hold as it stands, or nil when running with the lid closed isn't allowed.
    @discardableResult public func holdLid(owner: Int32, until: Date, reason: String, now: Date = Date()) -> LidLease? {
        guard allowLidClosed, owner > 0, until > now else { return nil }
        lidOwners[owner] = (until, String(reason.prefix(80)))
        updateAssertion(now: now)
        return lidRequest
    }
    public func releaseLid(owner: Int32, now: Date = Date()) {
        guard lidOwners.removeValue(forKey: owner) != nil else { return }
        updateAssertion(now: now)
    }

    /// Called every couple of seconds with the latest per-app traffic.
    public func tick(apps: [AppTraffic], interval: TimeInterval, now: Date = Date()) {
        let power = readPower()
        updateFrontmost(now: now, power: power)
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
        updateAssertion(now: now)
        if now.timeIntervalSince(lastDestinationSample) >= 30, !agents.isEmpty {
            lastDestinationSample = now
            Task { await sampleDestinations(apps: apps) }
        }
    }

    /// Notes a network change or drop against everything running, and warns about agents that may need a restart.
    public func record(event: String, now: Date = Date()) {
        if awake != nil { awake?.events.append(event) }
        let outage = event == "Lost the network" || event == "Internet unreachable"
        for key in Array(agents.keys) {
            agents[key]?.events.append(event)
            guard let run = agents[key] else { continue }
            if !outage { alert(String(localized: "Network changed while \(run.title) was working"), String(localized: "\(event). If it stops responding, it may need a nudge or a restart.")) }
            // An agent waiting for an answer isn't using the network.
            else if run.state != .waitingForYou { change(key, to: .networkFailed, detail: event, now: now) }
        }
    }
    /// An agent's hook reported its run. Hooks know what traffic can only guess, so they win:
    /// waiting keeps the run going, done ends it once its background tasks have.
    public func receive(_ event: AgentEvent) {
        guard event.valid else { return }
        let agent = AgentCatalog.name(event.agent) ?? event.agent, now = event.time
        let key = Self.key(agent, session: event.session, cwd: event.cwd)
        hooked.insert(agent)
        // A run first seen in traffic becomes the hooked one.
        if agents[key] == nil, key != agent, let run = agents[agent], run.hooks != true { agents[agent] = nil; agents[key] = run }
        // Only a start or a new turn begins a run; waiting or done after it ended changes nothing.
        if agents[key] == nil, event.kind == .start || event.kind == .working {
            agents[key] = WorkSession(kind: .agent, title: agent, start: now, batteryStart: PowerState.read().batteryPercent, lastActive: now, state: .working)
            requestAlertsIfNeeded()
        }
        guard var run = agents[key] else { return }
        if let pid = event.pid {
            pids[key] = pid
            if run.executable == nil, let path = probe.path(pid) { run.describe(AgentInstall.describe(path)) }
        }
        run.session = event.session ?? run.session
        run.cwd = event.cwd ?? run.cwd
        run.project = run.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }
        run.hooks = true; run.lastEvent = now
        if event.kind != .done { run.note = nil; finishing[key] = nil }
        agents[key] = run
        switch event.kind {
        case .start, .working: agents[key]?.state = .working
        case .waiting:
            // Only a rate limit is worth keeping beside the state; a permission prompt is in the notification.
            if let message = event.message, message.hasPrefix("Rate-limited") { agents[key]?.note = message }
            change(key, to: .waitingForYou, detail: event.message, now: now)
        case .done:
            // The turn is over, but subagents or background shells it started may still be at work.
            if let busy = busyTasks[key], busy > 0 {
                finishing[key] = now
                agents[key]?.state = .working
                agents[key]?.note = Self.background(busy)
            } else { finishAgent(key, reason: "Finished", now: now) }
        case .failed: finishAgent(key, reason: "Failed" + (event.message.map { ": " + $0 } ?? ""), now: now)
        }
        if agents[key] != nil { lastKinds[key] = event.kind }
        updateAssertion(now: now)
    }

    public func clearHistory() { history = []; persist() }

    private func trackAgents(_ apps: [AppTraffic], interval: TimeInterval, power: PowerState, now: Date) {
        var byAgent: [String: [AppTraffic]] = [:]
        for app in apps { if let agent = AgentCatalog.agent(for: app) { byAgent[agent, default: []].append(app) } }
        // Helpers an agent launches (npm, git, curl, python) count towards its run: only its own, not every curl on the Mac.
        for (agent, roots) in byAgent {
            let family = probe.family(roots.flatMap(\.processIDs))
            let helpers = apps.filter { AgentCatalog.agent(for: $0) == nil && $0.processIDs.contains(where: family.contains) }.map { $0.only(family) }
            byAgent[agent] = roots + helpers
        }
        let quiet = Double(quietMinutes * 60)
        var members: [String: [AppTraffic]] = [:], started: Set<String> = []
        for (agent, entries) in byAgent {
            let runs = agents.filter { $0.value.title == agent }.map(\.key)
            if runs.isEmpty {
                // Without hooks, the agent's traffic is the run.
                let alive = entries.contains { $0.processIDs.contains(where: probe.alive) }
                if !hooked.contains(agent), alive, entries.reduce(0, { $0 + $1.rate }) >= Self.agentActiveRate {
                    var run = WorkSession(kind: .agent, title: agent, start: now, batteryStart: power.batteryPercent, peakThermal: power.thermal, lastActive: now, state: .working)
                    if let pid = entries.first(where: { $0.id.hasPrefix("process:") })?.processIDs.first, let path = probe.path(pid) { run.describe(AgentInstall.describe(path)) }
                    agents[agent] = run; started.insert(agent)
                    requestAlertsIfNeeded()
                }
                continue
            }
            let families = Dictionary(uniqueKeysWithValues: runs.compactMap { key in pids[key].map { (key, probe.family([$0])) } })
            for entry in entries {
                // Each process counts toward the run whose process tree it is in.
                var shares: [String: Set<Int32>] = [:]
                for pid in entry.processIDs {
                    let owners = runs.filter { families[$0]?.contains(pid) ?? false }
                    let candidates = owners.isEmpty ? runs : owners
                    // A process no run's tree claims, or several do, can't be told apart: the likeliest gets it, marked shared.
                    guard let target = candidates.max(by: { rank($0) < rank($1) }) else { continue }
                    if candidates.count > 1 && (entry.rates[pid].map { $0.down + $0.up } ?? entry.rate) > 0 { agents[target]?.sharedTraffic = true }
                    shares[target, default: []].insert(pid)
                }
                for (target, pids) in shares { members[target, default: []].append(entry.only(pids)) }
            }
        }
        var times: [Int32: UInt64] = [:]
        for key in Array(agents.keys) where !started.contains(key) {
            guard var run = agents[key] else { continue }
            let entries = members[key] ?? [], rate = entries.reduce(0) { $0 + $1.rate }
            add(entries, to: &run, interval: interval, power: power)
            if rate >= Self.agentActiveRate { run.lastActive = now }
            // CPU counts as work too, so a long local build or test run isn't called quiet. Only a hooked run's own
            // process tree, or a command-line agent's: an app's process also draws its window.
            let roots = run.hooks == true ? pids[key].map { [$0] } ?? [] : entries.filter { $0.id.hasPrefix("process:") && AgentCatalog.agent(for: $0) != nil }.flatMap(\.processIDs)
            let usage = cpu(probe.family(roots), interval: interval, into: &times)
            let cpuNow = usage.values.reduce(0, +) >= Self.busyCores
            if cpuNow { run.lastCPU = now }
            let window = ((cpuWindows[key] ?? []) + [(now, usage.values.reduce(0, +) * interval)]).filter { now.timeIntervalSince($0.0) < quiet }
            cpuWindows[key] = window
            let cpuBusy = window.reduce(0) { $0 + $1.1 } / quiet >= Self.busyCores
            if let root = pids[key] {
                // A child of the agent that is using the CPU or the network is a subagent or a background shell at work.
                busyTasks[key] = probe.children(root).filter { child in
                    let family = probe.family([child])
                    return family.contains { (usage[$0] ?? 0) >= Self.busyCores } || entries.contains { $0.rate >= Self.agentActiveRate && $0.processIDs.contains(where: family.contains) }
                }.count
            }
            // Activity picks a run back up: an answered prompt sends the agent's next request, a recovered network its retries.
            switch run.state {
            case .waitingForYou? where rate >= Self.quietRate, .stalled? where rate >= Self.agentActiveRate || cpuNow, .networkFailed? where rate >= Self.agentActiveRate:
                run.state = .working
            default: break
            }
            agents[key] = run
            guard run.hooks == true else {
                if !entries.contains(where: { $0.processIDs.contains(where: probe.alive) }) { finishAgent(key, reason: "Exited", now: now) }
                else if now.timeIntervalSince(run.lastActive) >= quiet && !cpuBusy { finishAgent(key, reason: "Went quiet", now: now) }
                continue
            }
            if let since = finishing[key] {
                let busy = busyTasks[key] ?? 0
                if busy > 0 { finishing[key] = now; agents[key]?.note = Self.background(busy) }
                // A few quiet seconds, so a task pausing between steps doesn't end the run.
                else if now.timeIntervalSince(since) >= 10 || pids[key].map(probe.alive) == false { finishAgent(key, reason: "Finished", now: since) }
                continue
            }
            let silent = now.timeIntervalSince(max(run.lastActive, run.lastEvent ?? run.start)), idle = silent >= quiet && !cpuBusy
            // Without the agent's process from its hook, it counts as gone only once its processes seen in traffic are.
            let seen = byAgent[run.title] ?? []
            let gone = pids[key].map { !probe.alive($0) } ?? (idle && !seen.isEmpty && !seen.contains { $0.processIDs.contains(where: probe.alive) })
            if gone { finishAgent(key, reason: "Exited", now: now) }
            else if idle && silent >= 12 * 3600 { finishAgent(key, reason: "Went quiet", now: now) }
            else if idle, run.state == .working || run.state == .networkFailed {
                // A session nobody has prompted yet is waiting, not stuck; no need to say so.
                if lastKinds[key] == .start { agents[key]?.state = .waitingForYou; waitingSince[key] = now } else { change(key, to: .stalled, now: now) }
            }
        }
        cpuTimes = times
    }

    /// Cores each process used since the last tick. A process seen for the first time only sets its baseline.
    private func cpu(_ family: Set<Int32>, interval: TimeInterval, into times: inout [Int32: UInt64]) -> [Int32: Double] {
        var usage: [Int32: Double] = [:]
        for pid in family {
            guard let time = times[pid] ?? probe.cpuTime(pid) else { continue }
            times[pid] = time
            if let previous = cpuTimes[pid], time >= previous { usage[pid] = Double(time - previous) / 1e9 / max(interval, 0.5) }
        }
        return usage
    }

    static func background(_ count: Int) -> String { count == 1 ? String(localized: "1 background task still running") : String(localized: "\(count) background tasks still running") }

    /// Of runs that share processes, the one working, else the one heard from last.
    private func rank(_ key: String) -> (Int, Date) {
        guard let run = agents[key] else { return (0, .distantPast) }
        return (run.state == .working ? 2 : run.state == .networkFailed ? 1 : 0, max(run.lastEvent ?? run.start, run.lastActive))
    }

    /// Agent and session, or agent and folder; the agent alone when the hook named neither, as for a run seen in traffic.
    static func key(_ agent: String, session: String?, cwd: String?) -> String {
        (session ?? cwd).map { agent + "|" + $0 } ?? agent
    }

    /// Moves a run to a new state, telling the person once per change when it needs them or lost the network.
    private func change(_ key: String, to state: AgentState, detail: String? = nil, now: Date) {
        guard let run = agents[key], run.state != state else { return }
        agents[key]?.state = state
        if state == .waitingForYou { waitingSince[key] = now }
        switch state {
        case .waitingForYou where detail?.hasPrefix("Rate-limited") == true:
            alert(Self.headline(run, .rateLimited), String(localized: "\(detail ?? ""). Continue it once the limit resets."), session: agents[key])
        case .waitingForYou: alert(Self.headline(run, .waiting), detail ?? String(localized: "It needs your answer to go on."), session: agents[key])
        case .networkFailed:
            alert(Self.headline(run, .lostNetwork), detail.map { String(localized: "\($0). If it stops responding, it may need a nudge or a restart.") }
                  ?? String(localized: "The network dropped. If it stops responding, it may need a nudge or a restart."), session: agents[key])
        default: break
        }
        updateAssertion(now: now)
    }

    enum Headline { case rateLimited, waiting, lostNetwork, wentQuiet, finished, failed, stopped }
    /// "Claude Code is waiting for you in kilobat".
    static func headline(_ run: WorkSession, _ what: Headline) -> String {
        let agent = run.title
        guard let project = run.project else {
            switch what {
            case .rateLimited: return String(localized: "\(agent) is rate-limited")
            case .waiting: return String(localized: "\(agent) is waiting for you")
            case .lostNetwork: return String(localized: "\(agent) lost the network")
            case .wentQuiet: return String(localized: "\(agent) went quiet")
            case .finished: return String(localized: "\(agent) finished")
            case .failed: return String(localized: "\(agent) stopped with an error")
            case .stopped: return String(localized: "\(agent) stopped")
            }
        }
        switch what {
        case .rateLimited: return String(localized: "\(agent) is rate-limited in \(project)")
        case .waiting: return String(localized: "\(agent) is waiting for you in \(project)")
        case .lostNetwork: return String(localized: "\(agent) lost the network in \(project)")
        case .wentQuiet: return String(localized: "\(agent) went quiet in \(project)")
        case .finished: return String(localized: "\(agent) finished in \(project)")
        case .failed: return String(localized: "\(agent) stopped with an error in \(project)")
        case .stopped: return String(localized: "\(agent) stopped in \(project)")
        }
    }

    private func add(_ apps: [AppTraffic], to session: inout WorkSession, interval: TimeInterval, power: PowerState) {
        for app in apps where app.rate > 0 {
            let down = UInt64(app.downloadRate * interval), up = UInt64(app.uploadRate * interval)
            session.received += down; session.sent += up
            session.apps[app.name, default: 0] += down + up
        }
        if PowerState.heat(power.thermal) > PowerState.heat(session.peakThermal) { session.peakThermal = power.thermal }
    }

    private func finishAgent(_ key: String, reason: String, now: Date) {
        guard var session = agents.removeValue(forKey: key) else { return }
        pids[key] = nil; lastKinds[key] = nil; finishing[key] = nil; busyTasks[key] = nil; cpuWindows[key] = nil; waitingSince[key] = nil
        // Quiet time after the last traffic or CPU work isn't work; end the run when it actually went quiet.
        session.end = reason == "Went quiet" ? max(session.lastActive, session.lastCPU ?? session.lastActive) : max(now, session.start)
        session.ended = reason
        if reason == "Finished" { session.state = .done; session.note = nil } else if reason.hasPrefix("Failed") { session.state = .failed }
        updateAssertion(now: now)
        guard !session.isBlip else { return }
        session.batteryEnd = PowerState.read().batteryPercent
        archive(session)
        switch reason {
        // Quiet is never called finished: without hooks, Kilobat can't tell done from waiting.
        case "Went quiet": alert(Self.headline(session, .wentQuiet), String(localized: "Its traffic and CPU went quiet: it may be done or waiting for you. \(session.summary)"), session: session)
        case "Finished": alert(Self.headline(session, .finished), session.summary, session: session)
        case _ where reason.hasPrefix("Failed"):
            alert(Self.headline(session, .failed), reason == "Failed" ? session.summary : String(localized: "\(String(reason.dropFirst(8))). \(session.summary)"), session: session)
        default: alert(Self.headline(session, .stopped), session.summary, session: session)
        }
    }

    private func finish(reason: String, now: Date) {
        guard var session = awake else { return }
        session.end = now; session.ended = reason
        session.batteryEnd = PowerState.read().batteryPercent
        awake = nil; mode = nil; awakeByPower = false; samples = []; watchedRate = 0; quietSince = nil
        updateAssertion(now: now)
        archive(session)
        if !["Turned off", "Replaced", "Unplugged"].contains(reason) {
            alert(reason == "Went quiet" ? String(localized: "Done. Your Mac can sleep again") : String(localized: "Awake timer ended"), String(localized: "Stayed awake \(session.summary)"), session: session)
        }
    }

    private func archive(_ session: WorkSession) {
        history = Array(([session] + history).prefix(200))
        persist()
        onEnd?(session)
    }

    private func updateAssertion(now: Date = Date()) {
        let working = busyAgents.filter {
            switch $0.state { case .waitingForYou?: keepAwakeWhileWaiting; case .stalled?: false; default: true }
        }
        let agentsWant = keepAwakeForAgents && !working.isEmpty, wanted = mode != nil || agentsWant
        let display = keepDisplayOn
        if wanted && (assertion == nil || displayHeld != display) {
            let reason = awakeTitle.map { "Kilobat: " + $0 } ?? "Kilobat: " + Array(Set(working.map(\.title))).sorted().joined(separator: ", ") + " working"
            assertion?.release()
            assertion = SleepAssertion(reason: reason, display: display); displayHeld = assertion != nil && display
        } else if !wanted { assertion?.release(); assertion = nil; displayHeld = false }
        updateLid(now: now)
    }

    /// Holds the frontmost condition's assertion while its app is in front. Its timer and the battery floor end it
    /// first, as they end a lid hold; a closed lid still sleeps the Mac, since nothing is in front then.
    private func updateFrontmost(now: Date, power: PowerState? = nil) {
        guard let condition = frontmost else { return }
        if let until = condition.until, now >= until { endFrontmost("Timer ended"); return }
        let power = power ?? readPower()
        if !power.onAC, let percent = power.batteryPercent, percent <= lidBatteryFloor {
            endFrontmost("Battery at \(percent)%")
            alert(String(localized: "Let the Mac sleep: battery at \(percent)%"), String(localized: "Kilobat stopped keeping it awake while \(condition.name) is in front."))
            return
        }
        if !frontmostActive { frontmostAssertion?.release(); frontmostAssertion = nil }
        else if frontmostAssertion == nil { frontmostAssertion = SleepAssertion(reason: "Kilobat: " + condition.title, display: condition.display) }
    }
    private func endFrontmost(_ reason: String) {
        guard frontmost != nil else { return }
        frontmost = nil; frontmostActive = false; frontmostEnded = reason; frontmostWatcher = nil
        frontmostAssertion?.release(); frontmostAssertion = nil
    }

    /// Asks for a lid hold while a run works or a lid-closed session or command runs. An agent waiting for you counts
    /// only with "while an agent waits" on, for 30 minutes at most; the whole stretch ends at the time limit.
    private func updateLid(now: Date) {
        waitingSince = waitingSince.filter { agents[$0.key]?.state == .waitingForYou }
        lidOwners = lidOwners.filter { probe.alive($0.key) && $0.value.until > now }
        var ends: [Date] = [], reasons: [String] = []
        if allowLidClosed {
            // The plugged-in session never holds the lid.
            if let mode, lidClosedForAwake, !awakeByPower {
                if case .timer(let until) = mode { ends.append(until) } else { ends.append(.distantFuture) }
                reasons.append("Awake " + mode.title.prefix(1).lowercased() + mode.title.dropFirst())
            }
            if keepAwakeForAgents {
                for (key, run) in agents.sorted(by: { $0.value.start < $1.value.start }) {
                    switch run.state {
                    case .stalled?: continue
                    case .waitingForYou?:
                        guard keepAwakeWhileWaiting, let since = waitingSince[key], now < since + LidPolicy.waiting else { continue }
                        ends.append(since + LidPolicy.waiting)
                    default: ends.append(.distantFuture)
                    }
                    if !reasons.contains(run.title + " working") { reasons.append(run.title + " working") }
                }
            }
            for owner in lidOwners.values.sorted(by: { $0.until < $1.until }) { ends.append(owner.until); reasons.append(owner.reason) }
        }
        var request: LidLease?
        if let end = ends.max() {
            let since = lidSince ?? now
            lidSince = since
            let until = min(end, since + Double(min(lidMaxHours, 8)) * 3600)
            if until > now { request = LidLease(until: until, reason: reasons.joined(separator: ", "), batteryFloor: lidBatteryFloor, onlyOnAC: lidOnlyOnAC) }
        } else { lidSince = nil }
        guard request != lidRequest else { return }
        lidRequest = request
        lid?.request(request)
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
        for (key, run) in agents {
            // A run's own processes, or the agent's when it is the agent's only run.
            let roots = pids[key].map { [$0] } ?? (agents.values.filter { $0.title == run.title }.count == 1 ? apps.filter { AgentCatalog.agent(for: $0) == run.title }.flatMap(\.processIDs) : [])
            var hosts: [String] = []
            for pid in probe.family(roots) {
                for socket in (try? await ExpertTools.destinations(pid: pid)) ?? [] {
                    guard let (host, port) = socket.remoteHostAndPort else { continue }
                    hosts.append((await name(for: host)) + ":" + port)
                }
            }
            guard var session = agents[key] else { continue }
            for host in hosts where !session.destinations.contains(host) && session.destinations.count < 60 { session.destinations.append(host) }
            agents[key] = session
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
}
