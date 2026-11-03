import AppKit
import Foundation
import Observation

/// Stream reports for OBS: while OBS streams, Kilobat reads its frame counters over its local WebSocket once a second
/// beside the call engine's line, and when the stream ends says when frames dropped and whether the network, the
/// encoder or the GPU lost them. It also runs the check before going live, and Call mode for streams.
@MainActor @Observable public final class StreamStore {
    public enum Connection: Equatable, Sendable {
        case off, connecting
        case connected(version: String?)
        /// Not reachable, or turned down: the message says what to fix.
        case failed(OBSError)
        public var connected: Bool { if case .connected = self { true } else { false } }
    }

    /// The stream being measured, with OBS's latest counters.
    public struct Live: Equatable, Sendable {
        public let start: Date
        public var status: OBSStreamStatus
        public var stats: OBSStats?
        public var bitrate: Int?
        /// The counters when Kilobat started measuring, so the live share counts this stream only.
        public var first: OBSStreamStatus
        public init(start: Date, status: OBSStreamStatus, stats: OBSStats? = nil, bitrate: Int? = nil, first: OBSStreamStatus) {
            self.start = start; self.status = status; self.stats = stats; self.bitrate = bitrate; self.first = first
        }
        public var dropped: Int { max(0, status.skippedFrames - first.skippedFrames) }
        public var frames: Int { max(0, status.totalFrames - first.totalFrames) }
        public var percent: Double { StreamReport.share(dropped, of: frames) }
    }

    public private(set) var reports: [StreamReport] = []
    public private(set) var connection: Connection = .off
    public private(set) var live: Live?
    /// The latest check before going live, and whether one is running.
    public private(set) var check: StreamReadiness?
    public private(set) var checking = false
    /// The apps Call mode for streams holds right now.
    public private(set) var holding: [String] = []

    /// Off by default: it only means something to someone who streams with OBS.
    public var enabled = UserDefaults.standard.bool(forKey: "obs.enabled") {
        didSet { guard !previewing else { return }; UserDefaults.standard.set(enabled, forKey: "obs.enabled"); scheduleReconnect() }
    }
    public var port = UInt16(clamping: UserDefaults.standard.object(forKey: "obs.port") as? Int ?? Int(OBSProtocol.defaultPort)) {
        didSet { guard port != oldValue else { return }; UserDefaults.standard.set(Int(port), forKey: "obs.port"); scheduleReconnect() }
    }
    /// Notify after a stream that dropped frames meaningfully; clean ones only get their row.
    public var notify = UserDefaults.standard.object(forKey: "streamNotices") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notify, forKey: "streamNotices") }
    }
    /// Call mode for streams (Pro): hold sync and download apps while OBS streams.
    public var holdApps = UserDefaults.standard.bool(forKey: "streamCallMode") {
        didSet { UserDefaults.standard.set(holdApps, forKey: "streamCallMode"); if !holdApps { release() } }
    }
    public var hasPassword: Bool { passwordSaved }
    private var passwordSaved = false

    @ObservationIgnored public var onReport: ((StreamReport) -> Void)?
    @ObservationIgnored public var starlink: StarlinkStore?
    @ObservationIgnored public var peers: () -> [HouseholdLive] = { [] }
    /// Whether Call mode for streams may act: the app answers with the license.
    @ObservationIgnored public var allowed: () -> Bool = { false }
    /// The last speed test's upload on a network, in Mbps, and when.
    @ObservationIgnored public var uplink: (String) -> (mbps: Double, date: Date)? = { _ in nil }
    /// Whether the network is metered; the check never measures on one unless asked.
    @ObservationIgnored public var metered: () -> Bool = { true }
    @ObservationIgnored var runReadiness = StreamCheck.run
    /// Reads the password; the app reads the Keychain, tests and screenshots don't.
    @ObservationIgnored public var password: (UInt16) -> String? = { OBSPassword.read(port: $0) }

    private let file: URL
    @ObservationIgnored private var client: OBSClient?
    @ObservationIgnored private var pendingClient: OBSClient?
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var sampler: LineSampler?
    @ObservationIgnored private var seconds: [StreamSamples.Second] = []
    @ObservationIgnored private var lastAttempt = Date.distantPast
    @ObservationIgnored private var lastPoll = Date.distantPast
    @ObservationIgnored private var stateChanged = false
    @ObservationIgnored private var blocked: [String: TrafficStore.OwnedTemporary] = [:]
    /// App IDs held with a timed block while going live, for the rule inspector.
    public var heldBlocks: [String] { blocked.values.map(\.id).sorted() }
    @ObservationIgnored private var released: Set<String> = []
    @ObservationIgnored private var holdDeadline: Task<Void, Never>?
    @ObservationIgnored private var lastHoldScan = Date.distantPast
    @ObservationIgnored private weak var traffic: TrafficStore?
    @ObservationIgnored private weak var diagnostics: DiagnosticStore?

    /// A stream this short isn't worth a report: a test start, or a stream stopped at once.
    static let shortest: TimeInterval = 60
    /// While OBS isn't there, Kilobat looks for it this often; connecting to a closed local port costs nothing.
    static let retry: TimeInterval = 15
    /// OBS's own process, never blamed for its own upload.
    static let obsBundle = "com.obsproject.obs-studio"

    public init(directory: URL? = nil) {
        let folder = directory ?? Self.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("streams.json")
        reports = StoredJSON.read(file) ?? []
    }
    nonisolated static var folder: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat") }
    nonisolated public static func load(directory: URL? = nil) -> [StreamReport] {
        StoredJSON.read((directory ?? folder).appendingPathComponent("streams.json")) ?? []
    }

    #if DEBUG
    /// Made-up streams for screenshots and layout checks; debug builds only.
    /// Shown as turned on and connected, without ever connecting.
    public func preview(_ reports: [StreamReport], live: Live? = nil, check: StreamReadiness? = nil, connection: Connection = .connected(version: "5.5.0")) {
        previewing = true
        enabled = true
        self.reports = reports; self.live = live; self.check = check; self.connection = connection
    }
    @ObservationIgnored private var previewing = false
    #else
    private let previewing = false
    #endif

    public func start(traffic: TrafficStore, diagnostics: DiagnosticStore, polling: Bool = true) {
        guard loop == nil else { return }
        self.traffic = traffic; self.diagnostics = diagnostics
        guard polling else { return }
        passwordSaved = password(port) != nil
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: .seconds(self.live == nil ? 2 : 1))
            }
        }
    }

    /// Saves the password in the Keychain (or removes it, empty) and connects again with it.
    public func setPassword(_ value: String) {
        OBSPassword.save(value, port: port)
        passwordSaved = !value.isEmpty
        scheduleReconnect()
    }

    /// Settings' Test connection: connects now and says what went wrong. Nil when it connected.
    @discardableResult public func testConnection() async -> OBSError? {
        await reconnect()
        await connect()
        if case .failed(let error) = connection { return error }
        return nil
    }

    private func scheduleReconnect() {
        let generation = UUID()
        connectionGeneration = generation
        Task { if connectionGeneration == generation { await reconnect() } }
    }

    private func reconnect() async {
        connectionGeneration = UUID()
        let previous = client, pending = pendingClient
        client = nil; pendingClient = nil
        connection = enabled ? .connecting : .off
        lastAttempt = .distantPast
        async let disconnectPending: Void? = pending?.disconnect()
        async let disconnectPrevious: Void? = previous?.disconnect()
        if live != nil { await finish(report: true) }
        _ = await (disconnectPending, disconnectPrevious)
    }

    private func connect() async {
        guard enabled, client == nil, pendingClient == nil else { return }
        lastAttempt = Date()
        let generation = connectionGeneration
        let client = OBSClient(port: port, password: password(port))
        pendingClient = client
        defer { if pendingClient === client { pendingClient = nil } }
        do {
            try await client.connect()
            await client.observe(streamState: { _ in Task { @MainActor [weak self] in
                if self?.client === client { self?.stateChanged = true }
            } }, closed: { Task { @MainActor [weak self] in self?.dropped(client) } })
            let version = await client.version
            let connected = await client.connected
            guard enabled, generation == connectionGeneration, pendingClient === client else { await client.disconnect(); return }
            guard connected else { connection = .failed(OBSError(.closed)); return }
            self.client = client
            connection = .connected(version: version)
            stateChanged = true
        } catch {
            guard generation == connectionGeneration else { return }
            connection = .failed(error as? OBSError ?? OBSError(.notRunning))
        }
    }

    /// OBS quit or closed the connection: a stream in progress ends there.
    private func dropped(_ closed: OBSClient) {
        guard client === closed else { return }
        client = nil
        connection = .failed(OBSError(.notRunning))
        lastAttempt = Date()
        if live != nil { Task { await finish(report: true) } }
    }

    private func tick() async {
        guard !previewing else { return }
        guard enabled else { if client != nil || live != nil { await reconnect() }; return }
        let now = Date()
        if client == nil {
            if now.timeIntervalSince(lastAttempt) >= Self.retry { await connect() }
            return
        }
        guard let client else { return }
        if live != nil {
            await sample(client, now: now)
        } else if stateChanged || now.timeIntervalSince(lastPoll) >= 10 {
            stateChanged = false; lastPoll = now
            if let status = try? await client.streamStatus(), status.active { await begin(client, status: status, now: now) }
        }
    }

    private func begin(_ client: OBSClient, status: OBSStreamStatus, now: Date) async {
        guard enabled, self.client === client, let traffic, let diagnostics else { return }
        let generation = connectionGeneration
        // OBS counts from the stream's start; Kilobat measures from now, when it may have joined late.
        let start = now.addingTimeInterval(-min(status.duration / 1000, 5))
        live = Live(start: start, status: status, first: status)
        holdDeadline?.cancel()
        holdDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, start.addingTimeInterval(CallMode.limit).timeIntervalSinceNow))) }
            catch { return }
            guard let self, self.live?.start == start else { return }
            self.release()
        }
        seconds = []; released = []
        let sampler = LineSampler(start: start, starlink: starlink, peers: peers)
        self.sampler = sampler
        await sampler.begin(diagnostics: diagnostics)
        let bitrate = await client.bitrate()
        guard connectionGeneration == generation, live?.start == start else { return }
        live?.bitrate = bitrate
        hold(traffic: traffic, now: now)
    }

    private func sample(_ client: OBSClient, now: Date) async {
        guard enabled, self.client === client, let live, let traffic, let diagnostics else { return }
        let generation = connectionGeneration
        guard let status = try? await client.streamStatus(), connectionGeneration == generation, self.live?.start == live.start else { return }
        guard status.active else { await finish(report: true); return }
        let stats = try? await client.stats()
        guard connectionGeneration == generation, self.live?.start == live.start else { return }
        self.live?.status = status; self.live?.stats = stats
        seconds.append(.init(at: now.timeIntervalSince(live.start), status: status, stats: stats))
        sampler?.record(traffic: traffic, diagnostics: diagnostics, own: { $0.id.hasPrefix(Self.obsBundle) || $0.name == "OBS" }, now: now)
        hold(traffic: traffic, now: now)
    }

    /// Ends the stream being measured and writes its report.
    private func finish(report: Bool) async {
        holdDeadline?.cancel(); holdDeadline = nil
        guard let live, let sampler else { self.live = nil; return }
        self.live = nil; self.sampler = nil
        let held = holding
        release()
        let end = Date()
        let finishedSeconds = seconds
        seconds = []
        let worth = report && end.timeIntervalSince(live.start) >= Self.shortest && finishedSeconds.count >= 10
        var samples = StreamSamples()
        samples.line = await sampler.finish(report: worth, end: end, diagnostics: diagnostics)
        guard worth else { return }
        samples.obs = finishedSeconds
        samples.bitrate = live.bitrate
        let network = sampler.reportNetwork
        if let key = network?.0, let uplink = uplink(key) { samples.uplink = uplink.mbps; samples.uplinkDate = uplink.date }
        var card = StreamAnalysis.report(start: live.start, end: end, network: network, samples: samples)
        card.held = held.isEmpty ? nil : held
        reports.append(card); reports = Array(reports.suffix(200))
        try? JSONEncoder().encode(reports).write(to: file, options: .atomic)
        onReport?(card)
    }

    /// Ends a stream in progress and writes what was measured; the app calls this when it quits.
    public func stop() async {
        loop?.cancel(); loop = nil
        await reconnect()
    }

    // MARK: Call mode for streams

    /// Holds the known sync and download apps that are moving data, as call mode does during a call, and lets go of one
    /// the person brings to the front. A launcher is left alone while a game is in front: it runs the game being streamed.
    private func hold(traffic: TrafficStore, now: Date) {
        guard holdApps, allowed(), let live else { return }
        if Date().timeIntervalSince(live.start) >= CallMode.limit { release(); return }
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, let name = CallMode.name(of: front), holding.contains(name) {
            released.insert(name); CallMode.resume(app: name, owner: CallMode.stream); holding.removeAll { $0 == name }
            if let rule = blocked.removeValue(forKey: name) { traffic.clearTemporary(rule) }
        }
        guard now.timeIntervalSince(lastHoldScan) >= 10 else { return }
        lastHoldScan = now
        let front = NSWorkspace.shared.frontmostApplication
        let gaming = CallMode.gameInFront(bundleURL: front?.bundleURL, executable: front?.executableURL?.lastPathComponent)
        let skipped = Set(UserDefaults.standard.stringArray(forKey: "callModeSkipped") ?? [])
        for app in traffic.apps {
            guard let name = CallMode.name(of: app.id), !skipped.contains(name), !released.contains(name) else { continue }
            if CallMode.launchers.contains(name), gaming || app.downloadRate < CallAnalysis.downloadLoad / 2 { continue }
            guard !CallMode.hold(app.processIDs, app: name, owner: CallMode.stream).isEmpty, !holding.contains(name) else { continue }
            holding.append(name)
            if traffic.temporaryRule(app.id) == nil { blocked[name] = traffic.holdTemporary(app.id, minutes: Int(CallMode.limit / 60)) }
        }
    }

    /// Resumes what Call mode for streams holds, but not what a call or a Focus filter holds too.
    public func release() {
        CallMode.resume(owner: CallMode.stream)
        for rule in blocked.values { traffic?.clearTemporary(rule) }
        blocked = [:]; holding = []
    }

    // MARK: Go live

    /// The check before going live. `measure` nil measures unless the network is metered; true measures anyway.
    public func runCheck(measure: Bool? = nil, bitrate given: Int? = nil) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        var bitrate = given, source: String? = given == nil ? nil : "given"
        if bitrate == nil, let live = live?.bitrate { bitrate = live; source = "obs" }
        if bitrate == nil, let client, let value = await client.bitrate() { bitrate = value; source = "obs" }
        if bitrate == nil, let last = reports.last(where: { $0.bitrate != nil })?.bitrate { bitrate = last; source = "lastStream" }
        let busy = await busyApps()
        let key = traffic?.networkKey ?? diagnostics?.snapshot?.networkKey
        let revision = traffic?.networkRevision ?? diagnostics?.networkRevision
        let metered = metered()
        guard !Task.isCancelled else { return }
        let result = await runReadiness(bitrate, source, measure ?? !metered, key.flatMap(uplink), metered, busy)
        guard !Task.isCancelled, revision == (traffic?.networkRevision ?? diagnostics?.networkRevision),
              key == (traffic?.networkKey ?? diagnostics?.snapshot?.networkKey) else { return }
        check = result
    }

    /// Apps other than OBS moving enough to drop frames, seen in two of three looks a second apart.
    public func busyApps() async -> [Preflight.Issue] {
        guard let traffic else { return [] }
        var busy: [String: (hits: Int, up: Double, down: Double)] = [:]
        for round in 0..<3 {
            if round > 0 { try? await Task.sleep(for: .seconds(1)) }
            for app in traffic.apps where !app.carrier && !app.id.hasPrefix(Self.obsBundle) && !app.id.hasPrefix(AppRelay.appBundleID)
                && (app.uploadRate >= CallAnalysis.uploadLoad || app.downloadRate >= CallAnalysis.downloadLoad) {
                let entry = busy[app.name] ?? (0, 0, 0)
                busy[app.name] = (entry.hits + 1, max(entry.up, app.uploadRate), max(entry.down, app.downloadRate))
            }
        }
        return busy.filter { $0.value.hits >= 2 }.sorted { $0.value.up + $0.value.down > $1.value.up + $1.value.down }.prefix(3)
            .map { Preflight.Issue(kind: .app, app: $0.key, uploading: $0.value.up / CallAnalysis.uploadLoad >= $0.value.down / CallAnalysis.downloadLoad) }
    }

    /// What `kilobat stream status` shows, through the app relay.
    public var json: [String: Any] {
        var value: [String: Any] = ["enabled": enabled, "port": Int(port), "passwordSaved": hasPassword, "streaming": live != nil,
                                    "callModeForStreams": holdApps, "holding": holding, "reports": reports.count]
        switch connection {
        case .off: value["connection"] = "off"
        case .connecting: value["connection"] = "connecting"
        case .connected(let version): value["connection"] = "connected"; value["obsWebSocketVersion"] = version ?? NSNull()
        case .failed(let error): value["connection"] = "failed"; value["error"] = error.message; value["errorKind"] = error.kind.rawValue
        }
        if let live {
            value["since"] = ISO8601DateFormatter().string(from: live.start)
            value["bitrateKbps"] = live.bitrate ?? NSNull()
            value["live"] = ["droppedFrames": live.dropped, "totalFrames": live.frames, "droppedPercent": live.percent, "congestion": live.status.congestion,
                             "reconnecting": live.status.reconnecting, "encoderSkippedFrames": live.stats?.encoderSkipped ?? NSNull(),
                             "renderSkippedFrames": live.stats?.renderSkipped ?? NSNull(), "cpuUsage": live.stats?.cpuUsage ?? NSNull()] as [String: Any]
        } else if let bitrate = reports.last(where: { $0.bitrate != nil })?.bitrate {
            value["lastBitrateKbps"] = bitrate
        }
        if let key = diagnostics?.snapshot?.networkKey, let up = uplink(key) {
            value["uplinkMbps"] = up.mbps; value["uplinkDate"] = ISO8601DateFormatter().string(from: up.date)
        }
        value["metered"] = metered()
        return value
    }

    /// The bitrate for `kilobat stream check`: live, or OBS's profile when connected.
    public func currentBitrate() async -> Int? {
        if let bitrate = live?.bitrate { return bitrate }
        guard let client else { return nil }
        return await client.bitrate()
    }
}
