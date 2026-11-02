import AppKit
import Foundation
import Observation

/// Notices SSH, Mosh and remote desktop sessions and writes a report for each, with the call report engine: while one is
/// open it pings the internet, the router and the host once a second, reads the connection's own TCP round trip every
/// few seconds, and notes the busiest other app and the Mac's load. Nothing in the session is read.
@MainActor @Observable public final class RemoteSessionStore {
    /// A session being measured.
    public struct Live: Equatable, Sendable, Identifiable {
        public let kind: RemoteSessionReport.Kind
        public let host: String?
        public let start: Date
        public init(kind: RemoteSessionReport.Kind, host: String?, start: Date) { self.kind = kind; self.host = host; self.start = start }
        public var id: String { kind.rawValue }
        public var title: String { String(localized: "\(kind.name) to \(host ?? "…")", comment: "A remote session in progress, such as “SSH to build.example.com”") }
    }

    public private(set) var reports: [RemoteSessionReport] = []
    public private(set) var live: [Live] = []
    public var enabled = UserDefaults.standard.object(forKey: "remoteSessionReports") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "remoteSessionReports"); if !enabled { Task { await endAll(report: false) } } }
    }
    /// Notify after a session that lagged or froze; clean ones only get their row.
    public var notify = UserDefaults.standard.object(forKey: "remoteSessionNotices") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notify, forKey: "remoteSessionNotices") }
    }
    /// Called with each finished report.
    @ObservationIgnored public var onReport: ((RemoteSessionReport) -> Void)?
    @ObservationIgnored public var starlink: StarlinkStore?
    /// Paired Macs' fresh summaries, as for call reports; set by the app when it has Kilobat Pro.
    @ObservationIgnored public var peers: () -> [HouseholdLive] = { [] }

    private let file: URL
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var tracked: [Tracker] = []
    @ObservationIgnored private var lastScan = Date.distantPast
    /// Processes that went quiet and ended a session, with the processes carrying their traffic; one starts again only with new input.
    @ObservationIgnored private var idle: [Int32: Set<Int32>] = [:]
    /// Processes whose connection couldn't be found, with the attempts so far.
    @ObservationIgnored private var unresolved: [Int32: Int] = [:]
    @ObservationIgnored private var scanning = false

    /// A terminal session ends after this long without a keystroke, a viewer after less; the report stops at the last input.
    static let terminalIdle: TimeInterval = 600, viewerIdle: TimeInterval = 180
    /// A session this long gets its report and starts over.
    static let longest: TimeInterval = 8 * 3600
    /// A viewer moving this much is showing a screen.
    static let viewerLoad = 10_000.0

    public init(directory: URL? = nil) {
        let folder = directory ?? Self.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("remote-sessions.json")
        reports = StoredJSON.read(file) ?? []
    }
    nonisolated static var folder: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat") }
    nonisolated public static func load(directory: URL? = nil) -> [RemoteSessionReport] {
        StoredJSON.read((directory ?? folder).appendingPathComponent("remote-sessions.json")) ?? []
    }

    #if DEBUG
    /// Made-up sessions for screenshots and layout checks; debug builds only.
    public func preview(_ reports: [RemoteSessionReport], live: [Live] = []) { self.reports = reports; self.live = live }
    #endif

    public func start(traffic: TrafficStore, diagnostics: DiagnosticStore) {
        guard loop == nil else { return }
        loop = Task { [weak self, weak traffic, weak diagnostics] in
            while !Task.isCancelled {
                guard let self, let traffic, let diagnostics else { return }
                await self.tick(traffic: traffic, diagnostics: diagnostics)
                try? await Task.sleep(for: .seconds(self.tracked.isEmpty ? 5 : 1))
            }
        }
    }

    private func tick(traffic: TrafficStore, diagnostics: DiagnosticStore) async {
        guard enabled else { return }
        let now = Date()
        var rates: [Int32: ProcessRate] = [:]
        for app in traffic.apps { for (pid, rate) in app.rates { rates[pid] = rate } }
        let front = NSWorkspace.shared.frontmostApplication
        for tracker in tracked {
            tracker.record(traffic: traffic, diagnostics: diagnostics, rates: rates, front: front, now: now)
            if let end = tracker.ending(now: now) { await finish(tracker, end: end, diagnostics: diagnostics, report: true) }
        }
        if now.timeIntervalSince(lastScan) >= 5, !scanning {
            lastScan = now; scanning = true
            await scan(traffic: traffic, diagnostics: diagnostics, rates: rates, front: front, now: now)
            scanning = false
        }
    }

    /// Finds new sessions: one measured at a time for each kind.
    private func scan(traffic: TrafficStore, diagnostics: DiagnosticStore, rates: [Int32: ProcessRate], front: NSRunningApplication?, now: Date) async {
        let processes = await Task.detached(priority: .utility) { RemoteSessionDetector.terminalProcesses() }.value
        let alive = Set(processes.map(\.pid))
        unresolved = unresolved.filter { alive.contains($0.key) }
        idle = idle.filter { pid, carriers in
            guard alive.contains(pid) || NSRunningApplication(processIdentifier: pid) != nil else { return false }
            // Anything sent again, from the terminal or viewer in front, wakes it.
            let typed = carriers.contains { (rates[$0]?.up ?? 0) > 0 }
            let inFront = front.map { RemoteSessionDetector.isTerminal($0.bundleIdentifier) || carriers.contains($0.processIdentifier) || $0.processIdentifier == pid } ?? false
            return !(typed && inFront)
        }
        for process in processes where idle[process.pid] == nil && !tracked.contains(where: { $0.pid == process.pid }) {
            let kind: RemoteSessionReport.Kind
            if process.name == "mosh-client" {
                guard process.tty || RemoteSessionDetector.isTerminal(process.app) else { continue }
                kind = .mosh
            } else {
                guard RemoteSessionDetector.classify(ssh: process) == .interactive else { continue }
                kind = .ssh
            }
            guard !tracked.contains(where: { $0.kind == kind }), (unresolved[process.pid] ?? 0) < 3 else { continue }
            guard let (carrier, peer) = await connection(kind: kind, process: process, among: processes) else { unresolved[process.pid, default: 0] += 1; continue }
            let typed = kind == .ssh ? RemoteSessionDetector.destination(ssh: process.args) : RemoteSessionDetector.mosh(process.args).host
            await begin(Tracker(kind: kind, pid: process.pid, carriers: [carrier], socket: carrier, app: process.app, host: typed ?? peer.address, peer: peer,
                                start: now, starlink: starlink, peers: peers), diagnostics: diagnostics)
        }
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            guard let kind = RemoteSessionDetector.viewer(bundleID: app.bundleIdentifier, process: app.executableURL?.lastPathComponent),
                  !tracked.contains(where: { $0.kind == kind }), idle[app.processIdentifier] == nil else { continue }
            let pid = app.processIdentifier
            let group = traffic.apps.first { $0.processIDs.contains(pid) }
            let pids = Set(group?.processIDs ?? [pid])
            guard pids.reduce(0, { $0 + (rates[$1]?.down ?? 0) }) >= Self.viewerLoad else { continue }
            var sockets: [RemoteSessionDetector.Socket] = []
            for each in pids.prefix(4) { sockets += await RemoteSessionDetector.sockets(pid: each) }
            guard let peer = RemoteSessionDetector.peer(kind, sockets: sockets) else { continue }
            await begin(Tracker(kind: kind, pid: pid, carriers: pids, socket: peer.pid, app: app.bundleIdentifier, host: peer.address, peer: peer,
                                start: now, starlink: starlink, peers: peers), diagnostics: diagnostics)
        }
    }

    /// The process holding the session's connection and the connection itself: ssh's own; under ProxyJump, the ssh
    /// child that dials the jump host; with ControlMaster, the one master. A session to this Mac is skipped, and so is
    /// one through a ProxyCommand that isn't ssh (cloudflared, an SSM plugin), whose bytes Kilobat can't tie to it.
    private func connection(kind: RemoteSessionReport.Kind, process: RemoteSessionDetector.Process,
                            among processes: [RemoteSessionDetector.Process]) async -> (Int32, RemoteSessionDetector.Socket)? {
        if let peer = RemoteSessionDetector.peer(kind, sockets: await RemoteSessionDetector.sockets(pid: process.pid)) { return (process.pid, peer) }
        guard kind == .ssh else { return nil }
        for child in processes where child.ppid == process.pid {
            if let peer = RemoteSessionDetector.peer(kind, sockets: await RemoteSessionDetector.sockets(pid: child.pid)) { return (child.pid, peer) }
        }
        let masters = processes.filter { RemoteSessionDetector.classify(ssh: $0) == .multiplexMaster }
        guard masters.count == 1, let peer = RemoteSessionDetector.peer(kind, sockets: await RemoteSessionDetector.sockets(pid: masters[0].pid)) else { return nil }
        return (masters[0].pid, peer)
    }

    private func begin(_ tracker: Tracker, diagnostics: DiagnosticStore) async {
        tracked.append(tracker)
        live = tracked.map { Live(kind: $0.kind, host: $0.host, start: $0.start) }
        await tracker.begin(diagnostics: diagnostics)
    }

    private func finish(_ tracker: Tracker, end: Date, diagnostics: DiagnosticStore?, report: Bool) async {
        tracked.removeAll { $0 === tracker }
        live = tracked.map { Live(kind: $0.kind, host: $0.host, start: $0.start) }
        if tracker.alive { idle[tracker.pid] = tracker.carriers }
        let worth = report && RemoteSessionDetector.counts(tracker.kind, start: tracker.start, end: end, seconds: tracker.seconds)
        var samples = await tracker.finish(report: worth, end: end, diagnostics: diagnostics)
        guard worth, !samples.line.internet.isEmpty || !samples.remote.isEmpty else { return }
        let network = diagnostics?.snapshot.map { ($0.networkKey, $0.networkName) }
        func analyse() -> RemoteSessionReport {
            RemoteAnalysis.report(kind: tracker.kind, host: tracker.host, address: tracker.peer.address, port: tracker.peer.port,
                                  start: tracker.start, end: end, network: network, samples: samples)
        }
        var card = analyse()
        // As for calls: a lag past the router may be the service's own, and its status page says whether it knew of trouble.
        let services = RemoteAnalysis.services(host: tracker.host, app: tracker.kind.terminal ? nil : tracker.app)
        if card.needsStatusCheck, !services.isEmpty, let status = await ServiceWatch.shared.check(services).first,
           status.state != .unknown, ServiceTriggers.relevant(status, toCallEnding: end) {
            // The service owning up to an outage beats a paired Mac that only its own report blamed.
            if status.outage, card.causes.contains(where: { $0.cause.unconfirmed == true }) { samples.line.peersWithoutRouter = false; card = analyse() }
            card.service = status
        }
        reports.append(card); reports = Array(reports.suffix(200))
        try? JSONEncoder().encode(reports).write(to: file, options: .atomic)
        onReport?(card)
    }

    private func endAll(report: Bool) async {
        for tracker in tracked { await finish(tracker, end: Date(), diagnostics: nil, report: report) }
    }

    /// Ends every session and writes what was measured; the app calls this when it quits.
    public func stop() async { await endAll(report: true) }
}

/// One session being measured.
@MainActor private final class Tracker {
    let kind: RemoteSessionReport.Kind
    let pid: Int32
    let carriers: Set<Int32>
    let socket: Int32
    /// The terminal or viewer it lives in, by bundle ID.
    let app: String?
    let host: String
    let peer: RemoteSessionDetector.Socket
    let start: Date
    private let sampler: LineSampler
    private var remote: PingStream?
    private(set) var seconds: [RemoteSessionDetector.Second] = []
    private var connection: [CallSamples.Ping] = []
    private var lastInput: Date
    private var lastRTT = Date.distantPast
    private(set) var alive = true

    init(kind: RemoteSessionReport.Kind, pid: Int32, carriers: Set<Int32>, socket: Int32, app: String?, host: String, peer: RemoteSessionDetector.Socket, start: Date,
         starlink: StarlinkStore?, peers: @escaping () -> [HouseholdLive]) {
        self.kind = kind; self.pid = pid; self.carriers = carriers; self.socket = socket; self.app = app; self.host = host; self.peer = peer; self.start = start
        sampler = LineSampler(start: start, starlink: starlink, peers: peers); lastInput = start
    }

    func begin(diagnostics: DiagnosticStore) async {
        await sampler.begin(diagnostics: diagnostics)
        // ICMP to the host; ping6 has no per-reply timeout, so an IPv6 host is measured by its TCP round trip instead.
        if !peer.address.contains(":") { remote = PingStream(target: peer.address, start: start); await remote?.start() }
    }

    func record(traffic: TrafficStore, diagnostics: DiagnosticStore, rates: [Int32: ProcessRate], front: NSRunningApplication?, now: Date) {
        alive = kill(pid, 0) == 0 || errno != ESRCH
        guard alive else { return }
        let at = now.timeIntervalSince(start)
        let up = carriers.reduce(0) { $0 + (rates[$1]?.up ?? 0) }, down = carriers.reduce(0) { $0 + (rates[$1]?.down ?? 0) }
        let second = RemoteSessionDetector.Second(at: at, up: up, down: down, front: inFront(front))
        seconds.append(second)
        if second.input { lastInput = now }
        let carriers = carriers, bundle = app
        sampler.record(traffic: traffic, diagnostics: diagnostics, own: { app in
            app.processIDs.contains(where: carriers.contains) || (!self.kind.terminal && bundle.map { app.id == $0 } ?? false)
        }, now: now)
        if peer.transport == "TCP", now.timeIntervalSince(lastRTT) >= 3 {
            lastRTT = now
            let socket = socket, address = peer.address, port = peer.port
            Task {
                let rtt = await RemoteSessionDetector.sockets(pid: socket).first { $0.address == address && $0.port == port }?.rtt
                if let rtt { self.connection.append(.init(at: at, ms: rtt)) }
            }
        }
    }

    /// Typing reaches only the app in front: the terminal the ssh runs in (any terminal when it runs under tmux or
    /// screen, whose parent is no app), or the viewer itself.
    private func inFront(_ front: NSRunningApplication?) -> Bool {
        guard let front else { return false }
        if kind.terminal { return app.map { front.bundleIdentifier == $0 } ?? RemoteSessionDetector.isTerminal(front.bundleIdentifier) }
        return carriers.contains(front.processIdentifier) || front.processIdentifier == pid
    }

    /// When the session ended, if it has: its process exited, it went quiet, or it ran long enough for a report.
    func ending(now: Date) -> Date? {
        if !alive { return now }
        let quiet = kind.terminal ? RemoteSessionStore.terminalIdle : RemoteSessionStore.viewerIdle
        if now.timeIntervalSince(lastInput) >= quiet { return min(now, lastInput.addingTimeInterval(30)) }
        if now.timeIntervalSince(start) >= RemoteSessionStore.longest { return now }
        return nil
    }

    func finish(report: Bool, end: Date, diagnostics: DiagnosticStore?) async -> RemoteSamples {
        var samples = RemoteSamples()
        samples.line = await sampler.finish(report: report, end: end, diagnostics: diagnostics)
        samples.remote = await remote?.stop() ?? []
        remote = nil
        samples.connection = connection
        samples.seconds = seconds
        return samples
    }
}
