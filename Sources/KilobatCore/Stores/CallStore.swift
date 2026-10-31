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
    @ObservationIgnored private var blocked: [String] = []
    @ObservationIgnored private var released: Set<String> = []
    @ObservationIgnored private var airDropHeld = false
    @ObservationIgnored private weak var traffic: TrafficStore?
    @ObservationIgnored private weak var diagnostics: DiagnosticStore?
    @ObservationIgnored private var lastHoldScan = Date.distantPast
    @ObservationIgnored private var routerControl: String?
    @ObservationIgnored private var routerLast: RouterReading?
    @ObservationIgnored private var lastRouterRead = Date.distantPast
    private let file: URL
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var candidate: (call: CallDetector.Call, since: Date)?
    @ObservationIgnored private var silentSince: Date?
    @ObservationIgnored private var samples = CallSamples()
    @ObservationIgnored private var internet: PingStream?
    @ObservationIgnored private var router: PingStream?
    @ObservationIgnored private var lastAirDropCheck = Date.distantPast
    @ObservationIgnored private var ticks: MacLoad.Ticks?
    @ObservationIgnored private var lastLoad = Date.distantPast
    /// A call this short isn't worth a card; mic tests and voice messages are.
    static let shortest: TimeInterval = 60

    public init(directory: URL? = nil) {
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("calls.json")
        reports = StoredJSON.read(file) ?? []
        // A previous run that quit or crashed mid-call never leaves anything suspended.
        CallMode.resume()
    }

    #if DEBUG
    /// Made-up calls for screenshots and layout checks; debug builds only.
    public func preview(_ reports: [CallReport]) { self.reports = reports }
    #endif

    nonisolated public static func load(directory: URL? = nil) -> [CallReport] {
        StoredJSON.read((directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")).appendingPathComponent("calls.json")) ?? []
    }

    public func start(traffic: TrafficStore, diagnostics: DiagnosticStore) {
        guard loop == nil else { return }
        self.traffic = traffic; self.diagnostics = diagnostics
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
        let call = CallDetector.microphoneUsers().flatMap { CallDetector.call(microphone: $0) }
        let now = Date()
        if let live {
            if call?.app == live.call.app { silentSince = nil; record(traffic: traffic, diagnostics: diagnostics, call: live.call, now: now); await hold(traffic: traffic, now: now, start: live.start) }
            else if let since = silentSince, now.timeIntervalSince(since) >= 10 { await stop(report: true, end: since, diagnostics: diagnostics) }
            else if silentSince == nil { silentSince = now }
            return
        }
        // Ten seconds on the microphone before it counts, so a quick dictation or mic check doesn't start one.
        guard let call else { candidate = nil; return }
        if candidate?.call != call { candidate = (call, now); return }
        guard let since = candidate?.since, now.timeIntervalSince(since) >= 10 else { return }
        live = (call, since); candidate = nil; samples = CallSamples(); silentSince = nil; ticks = nil; lastLoad = .distantPast
        internet = PingStream(target: "internet", start: since); router = PingStream(target: "router", start: since)
        await internet?.start(); await router?.start()
        released = []; routerControl = nil; routerLast = nil
        if let snapshot = diagnostics.snapshot, let gateway = snapshot.gateway {
            let key = snapshot.networkKey
            Task { if let control = await Self.routerCounters(network: key, gateway: gateway) { self.routerControl = control; self.samples.household = [] } }
        }
        await hold(traffic: traffic, now: now, start: since)
        if callModeAirDrop, callMode, allowed(), !diagnostics.lowLatency.active {
            await diagnostics.lowLatency.enable(seconds: CallMode.limit)
            airDropHeld = diagnostics.lowLatency.active
        }
    }

    /// Holds every known app that's running and moving data, and lets go of one the person brings to the front.
    private func hold(traffic: TrafficStore, now: Date, start: Date) async {
        guard callMode, allowed() else { return }
        if now.timeIntervalSince(start) > CallMode.limit { release(); return }
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, let name = CallMode.name(of: front), holding.contains(name) {
            released.insert(name); resume(name)
        }
        guard now.timeIntervalSince(lastHoldScan) >= 10 else { return }
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
        guard !holding.contains(name), !CallMode.hold(app.processIDs, app: name).isEmpty else { return }
        holding.append(name); heldSince[name] = now
        // New connections are refused too, for whatever the suspended processes hand off to a helper.
        if traffic.temporaryRule(app.id) == nil { traffic.setTemporary(app.id, allowed: false, minutes: Int(CallMode.limit / 60)); blocked.append(app.id) }
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

    private func resume(_ name: String) {
        CallMode.resume(app: name)
        holding.removeAll { $0 == name }; heldSince[name] = nil
    }

    /// Resumes everything call mode holds; the app also calls this when it quits.
    public func release() {
        CallMode.resume()
        for id in blocked { traffic?.clearTemporary(id) }
        blocked = []; holding = []; heldSince = [:]
        if airDropHeld { diagnostics?.lowLatency.release(); airDropHeld = false }
    }

    private func record(traffic: TrafficStore, diagnostics: DiagnosticStore, call: CallDetector.Call, now: Date) {
        guard let start = live?.start else { return }
        let at = now.timeIntervalSince(start)
        let others = traffic.apps.filter { app in !app.carrier && !call.own.contains { app.id.hasPrefix($0) || app.name == $0 } }
        if let top = others.max(by: { $0.rate < $1.rate }), top.rate > 0 {
            samples.traffic.append(.init(at: at, app: top.name, upload: top.uploadRate, download: top.downloadRate))
        }
        if diagnostics.snapshot?.radio.health == .poor { samples.weakSignal.append(at) }
        if now.timeIntervalSince(lastLoad) >= 5 {
            lastLoad = now
            if let previous = ticks { Task { if let (load, next) = await MacLoad.sample(since: previous) { self.ticks = next; self.samples.load.append(.init(at: at, load: load)) } } }
            else { ticks = MacLoad.ticks() }
        }
        if let control = routerControl, now.timeIntervalSince(lastRouterRead) >= 5 {
            lastRouterRead = now
            let mac = traffic.apps.filter { !$0.carrier }.reduce((up: 0.0, down: 0.0)) { ($0.up + $1.uploadRate, $0.down + $1.downloadRate) }
            Task {
                guard let reading = try? await RouterCounters.read(controlURL: control) else { return }
                defer { self.routerLast = reading }
                guard let last = self.routerLast, reading.date > last.date, reading.received >= last.received, reading.sent >= last.sent else { return }
                let seconds = reading.date.timeIntervalSince(last.date)
                let down = Double(reading.received - last.received) / seconds, up = Double(reading.sent - last.sent) / seconds
                self.samples.household?.append(.init(at: at, upload: max(0, up - mac.up), download: max(0, down - mac.down)))
            }
        }
        if now.timeIntervalSince(lastAirDropCheck) >= 30 {
            lastAirDropCheck = now
            Task { if await NearbyRadios.awdlStatus().active { self.samples.airDrop = true } }
        }
    }

    private func stop(report: Bool, end: Date = Date(), diagnostics: DiagnosticStore? = nil) async {
        guard let live else { return }
        samples.internet = await internet?.stop() ?? []; samples.router = await router?.stop() ?? []
        internet = nil; router = nil; self.live = nil; silentSince = nil
        let held = holding
        release()
        guard report, end.timeIntervalSince(live.start) >= Self.shortest, !samples.internet.isEmpty else { return }
        let network = diagnostics?.snapshot.map { ($0.networkKey, $0.networkName) }
        var card = CallAnalysis.report(app: live.call.app, browser: live.call.browser, start: live.start, end: end, network: network, samples: samples)
        card.held = held.isEmpty ? nil : held
        reports.append(card); reports = Array(reports.suffix(200))
        try? JSONEncoder().encode(reports).write(to: file, options: .atomic)
        onReport?(card)
    }
}

/// `ping` once a second for as long as a call lasts; a reply later than a second counts as lost, as the call feels it.
actor PingStream {
    private let target: String, start: Date
    private var process: Process?
    private var pings: [CallSamples.Ping] = []
    /// Seconds from the call's start to the first ping; each ping's time comes from its sequence number, since a lost one is only reported later.
    private var offset = 0.0
    init(target: String, start: Date) { self.target = target; self.start = start }

    func start() async {
        guard let host = try? await StutterTest.host(for: target) else { return }
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

    func stop() -> [CallSamples.Ping] {
        process?.terminate(); process = nil
        return pings.sorted { $0.at < $1.at }
    }

    private func ingest(_ text: String) {
        for line in text.split(separator: "\n").map(String.init) {
            guard let seq = DiagnosticProbe.matches("icmp_seq[= ]([0-9]+)", in: line).first.flatMap(Double.init) else { continue }
            if line.contains("Request timeout") { pings.append(.init(at: offset + seq, ms: nil)) }
            else if let time = DiagnosticProbe.matches("time=([0-9.]+) ms", in: line).first.flatMap(Double.init) { pings.append(.init(at: offset + seq, ms: time)) }
        }
    }
}
