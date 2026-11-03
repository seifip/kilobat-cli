import AppKit
import Foundation
import Observation

/// Notices calls and writes a report card for each. While an app holds the microphone it pings the internet and the
/// router once a second and notes the busiest other app; when the call ends, `CallAnalysis` names each freeze's cause.
@MainActor @Observable public final class CallStore {
    public private(set) var reports: [CallReport] = []
    /// The call in progress and when it started.
    public private(set) var live: (call: CallDetector.Call, start: Date)?
    public var enabled = UserDefaults.standard.object(forKey: "callReports") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "callReports"); if !enabled { Task { await stop(report: false) } } }
    }
    /// Called with each finished report, for the notification.
    public var onReport: ((CallReport) -> Void)?
    /// Call mode (Pro): hold the apps in `CallMode.known` while a call is on.
    public var callMode = UserDefaults.standard.bool(forKey: "callMode") {
        didSet { UserDefaults.standard.set(callMode, forKey: "callMode"); if !callMode { release() } }
    }
    /// Known apps the person told call mode to leave alone.
    public var callModeSkipped = Set(UserDefaults.standard.stringArray(forKey: "callModeSkipped") ?? []) {
        didSet { UserDefaults.standard.set(callModeSkipped.sorted(), forKey: "callModeSkipped"); for name in callModeSkipped where holding.contains(name) { resume(name) } }
    }
    /// Also pause AirDrop's link during calls; macOS asks for an administrator password at the start of each one.
    public var callModeAirDrop = UserDefaults.standard.bool(forKey: "callModeAirDrop") { didSet { UserDefaults.standard.set(callModeAirDrop, forKey: "callModeAirDrop") } }
    /// Whether call mode may act: the app answers with the license.
    @ObservationIgnored public var allowed: () -> Bool = { false }
    /// The apps call mode holds right now.
    public private(set) var holding: [String] = []
    @ObservationIgnored private var heldSince: [String: Date] = [:]
    @ObservationIgnored private var blocked: [String: TrafficStore.OwnedTemporary] = [:]
    /// App IDs this call holds with a timed block, for the rule inspector.
    public var heldBlocks: [String] { blocked.values.map(\.id).sorted() }
    @ObservationIgnored private var released: Set<String> = []
    @ObservationIgnored private var airDropHeld = false
    @ObservationIgnored private weak var traffic: TrafficStore?
    @ObservationIgnored private weak var diagnostics: DiagnosticStore?
    @ObservationIgnored private var holdDeadline: Task<Void, Never>?
    @ObservationIgnored private var lastHoldScan = Date.distantPast
    private let file: URL
    private let ledger: URL
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var candidate: (call: CallDetector.Call, since: Date)?
    @ObservationIgnored private var silentSince: Date?
    @ObservationIgnored private var sampler: LineSampler?
    /// A call this short isn't worth a card; mic tests and voice messages are.
    static let shortest: TimeInterval = 60

    public init(directory: URL? = nil, ledger: URL = CallMode.ledgerURL) {
        self.ledger = ledger
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("calls.json")
        reports = StoredJSON.read(file) ?? []
        // A previous run that quit or crashed mid-call never leaves anything suspended.
        if ledger == CallMode.ledgerURL { CallMode.recoverAtLaunch() }
    }

    #if DEBUG
    /// Made-up calls for screenshots and layout checks; debug builds only.
    public func preview(_ reports: [CallReport]) { self.reports = reports }
    #endif

    nonisolated public static func load(directory: URL? = nil) -> [CallReport] {
        StoredJSON.read((directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")).appendingPathComponent("calls.json")) ?? []
    }

    /// The dish while one answers, for freezes it explains; set by the app.
    @ObservationIgnored public var starlink: StarlinkStore?
    /// Paired Macs' fresh summaries, from Household Macs; set by the app when it has Kilobat Pro.
    @ObservationIgnored public var peers: () -> [HouseholdLive] = { [] }

    public func start(traffic: TrafficStore, diagnostics: DiagnosticStore, polling: Bool = true) {
        guard loop == nil else { return }
        self.traffic = traffic; self.diagnostics = diagnostics
        guard polling else { return }
        loop = Task { [weak self, weak traffic, weak diagnostics] in
            while !Task.isCancelled {
                guard let self, let traffic, let diagnostics else { return }
                await self.tick(traffic: traffic, diagnostics: diagnostics)
                try? await Task.sleep(for: .seconds(self.live == nil ? 3 : 1))
            }
        }
    }

    private func tick(traffic: TrafficStore, diagnostics: DiagnosticStore) async {
        guard enabled else { return }
        if !allowed(), !holding.isEmpty || airDropHeld { release() }
        let call = CallDetector.microphoneUsers().flatMap { CallDetector.call(microphone: $0) }
        let now = Date()
        if let live {
            if call?.app == live.call.app { silentSince = nil; record(traffic: traffic, diagnostics: diagnostics, call: live.call, now: now); hold(traffic: traffic, now: now, start: live.start) }
            else if let since = silentSince, now.timeIntervalSince(since) >= 10 { await stop(report: true, end: since, diagnostics: diagnostics) }
            else if silentSince == nil { silentSince = now }
            return
        }
        // Ten seconds on the microphone before it counts, so a quick dictation or mic check doesn't start one.
        guard let call else { candidate = nil; return }
        if candidate?.call != call { candidate = (call, now); return }
        guard let since = candidate?.since, now.timeIntervalSince(since) >= 10 else { return }
        live = (call, since); candidate = nil; silentSince = nil; released = []
        holdDeadline?.cancel()
        holdDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, since.addingTimeInterval(CallMode.limit).timeIntervalSinceNow))) }
            catch { return }
            guard let self, self.live?.start == since else { return }
            self.release()
        }
        let sampler = LineSampler(start: since, starlink: starlink, peers: peers)
        self.sampler = sampler
        await sampler.begin(diagnostics: diagnostics)
        guard live?.start == since else { return }
        hold(traffic: traffic, now: Date(), start: since)
        if callModeAirDrop, callMode, allowed(), !diagnostics.lowLatency.active, !diagnostics.lowLatency.busy {
            let remaining = CallMode.limit - Date().timeIntervalSince(since)
            guard remaining > 0 else { return }
            await diagnostics.lowLatency.enable(seconds: remaining)
            guard live?.start == since, callMode, allowed(), Date().timeIntervalSince(since) < CallMode.limit else {
                if diagnostics.lowLatency.active { diagnostics.lowLatency.release() }
                return
            }
            airDropHeld = diagnostics.lowLatency.active
        }
    }

    /// Holds every known app that's running and moving data, and lets go of one the person brings to the front.
    func hold(traffic: TrafficStore, now: Date, start: Date) {
        if !allowed() || now.timeIntervalSince(start) >= CallMode.limit {
            if !holding.isEmpty || airDropHeld { release() }
            return
        }
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, let name = CallMode.name(of: front), holding.contains(name) {
            released.insert(name); resume(name)
        }
        guard callMode, now.timeIntervalSince(lastHoldScan) >= 10 else { return }
        lastHoldScan = now
        let front = NSWorkspace.shared.frontmostApplication
        let gaming = CallMode.gameInFront(bundleURL: front?.bundleURL, executable: front?.executableURL?.lastPathComponent)
        for app in traffic.apps {
            guard let name = CallMode.name(of: app.id), !callModeSkipped.contains(name), !released.contains(name) else { continue }
            if CallMode.launchers.contains(name), gaming || app.downloadRate < CallAnalysis.downloadLoad / 2 { continue }
            hold(app, name: name, traffic: traffic, now: now)
        }
    }

    private func hold(_ app: AppTraffic, name: String, traffic: TrafficStore, now: Date) {
        guard !CallMode.hold(app.processIDs, app: name, ledger: ledger).isEmpty, !holding.contains(name) else { return }
        holding.append(name); heldSince[name] = now
        // New connections are refused too, for whatever the suspended processes hand off to a helper.
        if traffic.temporaryRule(app.id) == nil { blocked[name] = traffic.holdTemporary(app.id, minutes: Int(CallMode.limit / 60)) }
    }

    /// Holds these apps now, from the check before a meeting, until the call ends, or for half an hour if none starts.
    public func holdBeforeCall(_ names: [String]) {
        guard allowed(), let traffic else { return }
        let now = Date()
        for app in traffic.apps { if let name = CallMode.name(of: app.id), names.contains(name) { hold(app, name: name, traffic: traffic, now: now) } }
        Task { try? await Task.sleep(for: .seconds(1800)); if self.live == nil { self.release() } }
    }

    /// The router's WAN counters for this network, found once and remembered; a router without UPnP is asked again a day later.
    static func routerCounters(network: String, gateway: String) async -> String? {
        let key = "routerCounters." + network
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let missed = "routerCountersMissed." + network
        if let date = UserDefaults.standard.object(forKey: missed) as? Date, Date().timeIntervalSince(date) < 86_400 { return nil }
        guard let control = await RouterCounters.discover(gateway: gateway) else { UserDefaults.standard.set(Date(), forKey: missed); return nil }
        UserDefaults.standard.set(control, forKey: key)
        return control
    }

    func resume(_ name: String) {
        CallMode.resume(app: name, owner: CallMode.call, ledger: ledger)
        if let rule = blocked.removeValue(forKey: name) { traffic?.clearTemporary(rule) }
        holding.removeAll { $0 == name }; heldSince[name] = nil
    }

    /// Resumes everything call mode holds, but not what a Focus filter holds too; the app also calls this when it quits.
    public func release() {
        CallMode.resume(owner: CallMode.call, ledger: ledger)
        for rule in blocked.values { traffic?.clearTemporary(rule) }
        blocked = [:]; holding = []; heldSince = [:]
        if airDropHeld { diagnostics?.lowLatency.release(); airDropHeld = false }
    }

    private func record(traffic: TrafficStore, diagnostics: DiagnosticStore, call: CallDetector.Call, now: Date) {
        sampler?.record(traffic: traffic, diagnostics: diagnostics, own: { app in call.own.contains { app.id.hasPrefix($0) || app.name == $0 } }, now: now)
    }

    private func stop(report: Bool, end: Date = Date(), diagnostics: DiagnosticStore? = nil) async {
        holdDeadline?.cancel(); holdDeadline = nil
        guard let live, let sampler else { return }
        self.live = nil; self.sampler = nil; silentSince = nil
        let held = holding
        release()
        let worth = report && end.timeIntervalSince(live.start) >= Self.shortest
        var samples = await sampler.finish(report: worth, end: end, diagnostics: diagnostics)
        guard worth, !samples.internet.isEmpty else { return }
        let network = sampler.reportNetwork
        var card = CallAnalysis.report(app: live.call.app, browser: live.call.browser, start: live.start, end: end, network: network, samples: samples)
        card.held = held.isEmpty ? nil : held
        // Freezes past the router may be the calling service's own; its status page says whether it knew of trouble.
        // An incident that began after the call ended says nothing about it either way, so the card leaves it out.
        if ServiceTriggers.callNeedsCheck(card), let status = await ServiceWatch.shared.check(ServiceCatalog.services(forCallApp: card.app)).first,
           status.state != .unknown, ServiceTriggers.relevant(status, toCallEnding: end) {
            // The service owning up to an outage beats a paired Mac that only its own report blamed.
            if status.outage, card.causes.contains(where: { $0.cause.unconfirmed == true }) {
                samples.peersWithoutRouter = false
                card = CallAnalysis.report(app: live.call.app, browser: live.call.browser, start: live.start, end: end, network: network, samples: samples)
                card.held = held.isEmpty ? nil : held
            }
            card.service = status
        }
        reports.append(card); reports = Array(reports.suffix(200))
        try? JSONEncoder().encode(reports).write(to: file, options: .atomic)
        onReport?(card)
    }
}

/// `ping` once a second for as long as a call lasts; a reply later than a second counts as lost, as the call feels it.
actor PingStream {
    private let target: String, start: Date
    private let resolve: @Sendable (String) async throws -> String
    private var process: Process?
    private var started = false
    private var stopped = false
    var isRunning: Bool { process?.isRunning == true }
    private var pings: [CallSamples.Ping] = []
    /// Seconds from the call's start to the first ping; each ping's time comes from its sequence number, since a lost one is only reported later.
    private var offset = 0.0
    init(target: String, start: Date, resolve: @escaping @Sendable (String) async throws -> String = StutterTest.host(for:)) {
        self.target = target; self.start = start; self.resolve = resolve
    }

    func start() async {
        guard !started, !stopped else { return }
        started = true
        guard let host = try? await resolve(target), !stopped else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-n", "-i", "1", "-W", "1000", host]
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard let self, !text.isEmpty else { return }
            Task { await self.ingest(text) }
        }
        offset = Date().timeIntervalSince(start)
        do { try process.run(); self.process = process } catch { self.process = nil }
    }

    /// The pings so far, for a live readout; the stream keeps going.
    func current() -> [CallSamples.Ping] { pings.sorted { $0.at < $1.at } }

    func stop() -> [CallSamples.Ping] {
        stopped = true
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if isRunning { process?.terminate() }
        process = nil
        return pings.sorted { $0.at < $1.at }
    }

    private func ingest(_ text: String) {
        guard !stopped else { return }
        for line in text.split(separator: "\n").map(String.init) {
            guard let seq = DiagnosticProbe.matches("icmp_seq[= ]([0-9]+)", in: line).first.flatMap(Double.init) else { continue }
            if line.contains("Request timeout") { pings.append(.init(at: offset + seq, ms: nil)) }
            else if let time = DiagnosticProbe.matches("time=([0-9.]+) ms", in: line).first.flatMap(Double.init) { pings.append(.init(at: offset + seq, ms: time)) }
        }
    }
}
