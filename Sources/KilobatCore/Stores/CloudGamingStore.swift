import AppKit
import Foundation
import Observation

/// Cloud gaming sessions: GeForce NOW, Boosteroid or Shadow in their Mac apps, or GeForce NOW, Xbox Cloud Gaming, Luna,
/// Boosteroid or Shadow in a browser. A session starts when a client's one-way stream (`CloudGamingFlows`) carries a
/// game's worth of video; a browser's counts only once its hosts say which service it is. While it plays, the call
/// engine's line runs beside the stream's own bitrate and data, and the usual culprits are flagged as they happen; one
/// click pauses AirDrop and holds sync apps until the session ends. Afterwards, a report says when it stuttered and why.
@MainActor @Observable public final class CloudGamingStore {
    /// The session being measured, as the live card and `kilobat cloud-gaming status` show it.
    public struct Live: Equatable, Sendable {
        public let service: String
        public let name: String
        public let browser: String?
        public let start: Date
        public var pingMs: Double? = nil
        public var jitterMs: Double? = nil
        public var lossPercent: Double? = nil
        public var measured: CloudGamingReport.Measured = .internet
        /// The stream's bitrate over the last five seconds, in Mbps.
        public var mbps: Double? = nil
        /// Bytes the stream brought in so far, and its rate over the last minute in bytes a second.
        public var bytes: Double = 0
        public var rate: Double = 0
        public var issues: [CloudGamingIssue] = []
        public var metered = false
        /// How long sessions of this service usually last here, for the projection.
        public var typical: TimeInterval = 3600
        /// Bytes left in this network's budget, on a metered network with one.
        public var budgetLeft: Double? = nil
        public init(service: String, name: String, browser: String?, start: Date) { self.service = service; self.name = name; self.browser = browser; self.start = start }

        public var title: String {
            browser.map { String(localized: "\(name) in \($0)", comment: "Cloud gaming report title in a browser; the arguments are a service and a browser, such as “Xbox Cloud Gaming in Chrome”") } ?? name
        }
        public var perHour: Double { rate * 3600 }
        public func projection(now: Date = Date()) -> (seconds: TimeInterval, bytes: Double) {
            CloudGamingData.projection(used: bytes, rate: rate, elapsed: now.timeIntervalSince(start), typical: typical)
        }
        /// Seconds until the budget runs out at this rate.
        public var runsOut: TimeInterval? { budgetLeft.flatMap { CloudGamingData.runsOut(left: $0, rate: rate) } }

        /// "At this rate: 7.2 GB an hour, about 11 GB by 1 h 30 min." on a metered network; nil elsewhere.
        public func dataLine(now: Date = Date()) -> String? {
            guard metered, rate > 0 else { return nil }
            let projected = projection(now: now)
            let length = Duration.seconds(projected.seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
            var line = String(localized: "\(CloudGamingData.format(perHour)) an hour at this rate: about \(CloudGamingData.format(projected.bytes)) for a \(length) session.",
                              comment: "Cloud gaming on a hotspot: data an hour, then the projected total and the session length it assumes, such as “7.2 GB an hour at this rate: about 11 GB for a 1 h 30 min session.”")
            if let runsOut {
                line += " " + String(localized: "Your budget here runs out in \(Duration.seconds(max(60, runsOut)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))).",
                                     comment: "Cloud gaming on a hotspot; the argument is a duration such as 45 min")
            }
            return line
        }

        /// What `kilobat cloud-gaming status --json` and MCP give for the session.
        public func json(now: Date = Date()) -> [String: Any] {
            func round(_ value: Double?) -> Any { value.map { ($0 * 10).rounded() / 10 } ?? NSNull() }
            let projected = projection(now: now)
            var value: [String: Any] = ["service": service, "name": name, "browser": browser ?? NSNull(), "title": title,
                                        "since": ISO8601DateFormatter().string(from: start), "minutes": Int(now.timeIntervalSince(start) / 60),
                                        "measured": measured.rawValue, "pingMs": round(pingMs), "jitterMs": round(jitterMs), "lossPercent": round(lossPercent),
                                        "mbps": round(mbps), "gigabytes": round(bytes / 1e9), "gigabytesPerHour": round(perHour / 1e9), "metered": metered,
                                        "issues": issues.map { ["kind": $0.kind.rawValue, "app": $0.app ?? NSNull(), "uploading": $0.uploading ?? NSNull(),
                                                                "pausable": $0.pausable ?? false, "phrase": $0.phrase, "advice": $0.advice] as [String: Any] }]
            if metered {
                value["projectedGigabytes"] = round(projected.bytes / 1e9); value["projectedMinutes"] = Int(projected.seconds / 60)
                value["budgetLeftGigabytes"] = round(budgetLeft.map { $0 / 1e9 }); value["budgetRunsOutMinutes"] = runsOut.map { Int($0 / 60) } ?? NSNull()
                value["data"] = dataLine(now: now) ?? NSNull()
            }
            return value
        }
    }

    public private(set) var reports: [CloudGamingReport] = []
    public private(set) var live: Live?
    /// The apps held for this session, and whether AirDrop is paused for it.
    public private(set) var holding: [String] = []
    public private(set) var airDropPaused = false
    public private(set) var pausing = false
    public var error: String?

    public var enabled = UserDefaults.standard.object(forKey: "cloudGamingReports") as? Bool ?? true {
        didSet { guard !previewing else { return }; UserDefaults.standard.set(enabled, forKey: "cloudGamingReports"); if !enabled { Task { await finish(report: false) } } }
    }
    /// Notify after a session that stuttered; smooth ones only get their row.
    public var notify = UserDefaults.standard.object(forKey: "cloudGamingNotices") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notify, forKey: "cloudGamingNotices") }
    }

    /// Say so once a session when something on this Mac gets in the way while it plays.
    public var alerts = UserDefaults.standard.object(forKey: "cloudGamingAlerts") as? Bool ?? true {
        didSet { UserDefaults.standard.set(alerts, forKey: "cloudGamingAlerts") }
    }

    @ObservationIgnored public var onReport: ((CloudGamingReport) -> Void)?
    /// Called once a session, half a minute in or later, the first time something is in the way.
    @ObservationIgnored public var onIssues: ((Live) -> Void)?
    @ObservationIgnored public var starlink: StarlinkStore?
    @ObservationIgnored public var peers: () -> [HouseholdLive] = { [] }
    /// Whether holding apps may act (Pro): the app answers with the license. Pausing AirDrop is free.
    @ObservationIgnored public var allowed: () -> Bool = { false }
    /// Names apps asked for by address, from the network filter while it runs.
    @ObservationIgnored public var hostnames: () -> [String: String] = { [:] }
    @ObservationIgnored public var lookup = HostLookup.live
    /// Whether the network is metered, and the bytes left in its budget (nil without one).
    @ObservationIgnored public var metered: () -> Bool = { false }
    @ObservationIgnored public var budgetLeft: () -> Double? = { nil }

    private let file: URL
    @ObservationIgnored private weak var traffic: TrafficStore?
    @ObservationIgnored private weak var diagnostics: DiagnosticStore?
    @ObservationIgnored private var flows = CloudGamingFlows()
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var beginning = false
    @ObservationIgnored private var ending = false
    @ObservationIgnored private var reverse: [String: String?] = [:]
    @ObservationIgnored private var resolving: Set<String> = []
    @ObservationIgnored private var heldBlocks: [String] = []
    @ObservationIgnored private var released: Set<String> = []
    @ObservationIgnored private var observing = false

    /// A session this short isn't worth a report: a queue, a menu, a quick look.
    static let shortest: TimeInterval = 120
    /// A session this long gets its report; one that seems never to end is closed here.
    static let longest: TimeInterval = 8 * 3600

    private final class Session {
        let client: CloudGamingFlows.Client
        let service: CloudGamingService
        let browser: String?
        let start: Date
        let sampler: LineSampler
        var server: PingStream?
        var serverAddress: String?
        var samples = CloudGamingSamples()
        var own: Set<String> = []
        var lastAWDL = Date.distantPast, awdlActive = false
        var lastStats = Date.distantPast, lastIssues = Date.distantPast
        var alerted = false
        var recent: [Double] = []
        init(client: CloudGamingFlows.Client, service: CloudGamingService, browser: String?, start: Date, sampler: LineSampler) {
            self.client = client; self.service = service; self.browser = browser; self.start = start; self.sampler = sampler
        }
    }

    public init(directory: URL? = nil) {
        let folder = directory ?? Self.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("cloud-gaming.json")
        reports = StoredJSON.read(file) ?? []
    }
    nonisolated static var folder: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat") }
    nonisolated public static func load(directory: URL? = nil) -> [CloudGamingReport] {
        StoredJSON.read((directory ?? folder).appendingPathComponent("cloud-gaming.json")) ?? []
    }

    #if DEBUG
    /// Made-up sessions for screenshots and layout checks; debug builds only.
    public func preview(_ reports: [CloudGamingReport], live: Live? = nil, holding: [String] = [], airDropPaused: Bool = false) {
        previewing = true
        self.reports = reports; self.live = live; self.holding = holding; self.airDropPaused = airDropPaused
    }
    @ObservationIgnored private var previewing = false
    #else
    private let previewing = false
    #endif

    /// Follows the traffic monitor's samples, once a second.
    public func start(traffic: TrafficStore, diagnostics: DiagnosticStore) {
        self.traffic = traffic; self.diagnostics = diagnostics
        guard !observing else { return }
        observing = true
        traffic.observeSnapshots { [weak self] snapshot in
            MainActor.assumeIsolated { self?.consume(snapshot) }
        }
    }

    /// Which client each process belongs to: a service's Mac app, or a browser.
    nonisolated static func clients(_ apps: [AppTraffic]) -> [Int32: (client: CloudGamingFlows.Client, id: String)] {
        var clients: [Int32: (CloudGamingFlows.Client, String)] = [:]
        for app in apps where !app.carrier {
            let path = app.ownerPath ?? app.bundlePath
            let client: CloudGamingFlows.Client? = CloudGamingService.app(id: app.id, name: app.name, path: path).map { .app($0.id) }
                ?? CloudGamingService.browser(id: app.id, path: path).map { .browser($0) }
            guard let client else { continue }
            for pid in app.processIDs { clients[pid] = (client, app.id) }
        }
        return clients
    }

    func consume(_ snapshot: TrafficSnapshot) {
        guard enabled, !previewing, let traffic, let diagnostics else { return }
        let clients = Self.clients(traffic.apps)
        let seconds = flows.ingest(snapshot) { clients[$0.pid]?.client }
        let now = snapshot.timestamp
        if let session {
            if flows.ended(session.client, now: now) || now.timeIntervalSince(session.start) >= Self.longest {
                guard !ending else { return }
                ending = true
                let end = min(now, flows.lastActive(session.client).map { $0.addingTimeInterval(1) } ?? now)
                Task { await finish(report: true, end: end); ending = false }
                return
            }
            session.own.formUnion(clients.values.filter { $0.client == session.client }.map(\.id))
            record(session, second: seconds[session.client], traffic: traffic, diagnostics: diagnostics, now: now)
            return
        }
        guard !beginning else { return }
        for media in flows.media {
            switch media.client {
            case .app(let id):
                guard let service = CloudGamingService.service(id) else { continue }
                begin(media, service: service, browser: nil, clients: clients, diagnostics: diagnostics, now: now); return
            case .browser(let name):
                guard let service = identify(media, snapshot: snapshot, clients: clients) else { continue }
                begin(media, service: service, browser: name, clients: clients, diagnostics: diagnostics, now: now); return
            }
        }
    }

    /// The service a browser streams, from the hosts behind its open connections: the filter's names for them, else
    /// reverse DNS (looked up once each, in the background). No host, no session: a stream Kilobat can't name is left alone.
    private func identify(_ media: CloudGamingFlows.Media, snapshot: TrafficSnapshot, clients: [Int32: (client: CloudGamingFlows.Client, id: String)]) -> CloudGamingService? {
        let connections = snapshot.processes.filter { clients[$0.pid]?.client == media.client }.flatMap(\.connections).filter { $0.route != .local }
        let peers = connections.sorted { $0.received + $0.sent > $1.received + $1.sent }.compactMap { ServiceFlowTracker.endpoint($0.id)?.address }
        var addresses: [String] = []
        for address in [media.server].compactMap({ $0 }) + peers where !addresses.contains(address) { addresses.append(address) }
        let names = hostnames()
        let hosts = addresses.compactMap { names[$0] } + addresses.compactMap { reverse[$0] ?? nil }
        if let service = CloudGamingService.service(hosts: hosts) { return service }
        for address in addresses.prefix(8) where reverse[address] == nil && !resolving.contains(address) {
            resolving.insert(address)
            let lookup = lookup
            Task { let name = await lookup.reverse(address); self.reverse[address] = .some(name); self.resolving.remove(address) }
        }
        return nil
    }

    private func begin(_ media: CloudGamingFlows.Media, service: CloudGamingService, browser: String?,
                       clients: [Int32: (client: CloudGamingFlows.Client, id: String)], diagnostics: DiagnosticStore, now: Date) {
        beginning = true
        // The stream was already running for the ten seconds that qualified it.
        let start = now.addingTimeInterval(-Double(CloudGamingFlows.window))
        let session = Session(client: media.client, service: service, browser: browser, start: start,
                              sampler: LineSampler(start: start, starlink: starlink, peers: peers))
        session.own = Set(clients.values.filter { $0.client == media.client }.map(\.id))
        var live = Live(service: service.id, name: service.name, browser: browser, start: start)
        live.metered = metered(); live.budgetLeft = live.metered ? budgetLeft() : nil
        live.typical = CloudGamingData.typical(reports, service: service.id)
        self.live = live; released = []
        self.session = session
        Task {
            defer { self.beginning = false }
            await session.sampler.begin(diagnostics: diagnostics)
            // The stream's own server, when the socket names it: pinged like a remote session's host. IPv4 only.
            if let server = media.server, !server.contains(":"), !CurrentMatch.isPrivate(server) {
                session.serverAddress = server
                let stream = PingStream(target: server, start: start)
                await stream.start()
                session.server = stream
            }
        }
    }

    private func record(_ session: Session, second: CloudGamingFlows.Second?, traffic: TrafficStore, diagnostics: DiagnosticStore, now: Date) {
        let at = now.timeIntervalSince(session.start)
        let down = second?.down ?? 0
        session.samples.seconds.append(.init(at: at, down: down, up: second?.up ?? 0))
        session.recent.append(down); if session.recent.count > 60 { session.recent.removeFirst() }
        let own = session.own
        session.sampler.record(traffic: traffic, diagnostics: diagnostics, own: { own.contains($0.id) }, now: now)
        let band = diagnostics.radio?.band
        if band == "2.4 GHz" { session.samples.band24.append(at) }
        // lsof runs for this, so every 30 seconds.
        if now.timeIntervalSince(session.lastAWDL) >= 30 {
            session.lastAWDL = now
            Task { let status = await NearbyRadios.awdlStatus(); session.awdlActive = status.up && status.active; if session.awdlActive { session.samples.airDrop.append(at) } }
        }
        releaseFront()
        guard var live else { return }
        live.bytes += down
        live.rate = session.recent.reduce(0, +) / Double(max(1, session.recent.count))
        live.mbps = session.recent.suffix(5).reduce(0, +) / Double(max(1, min(5, session.recent.count))) * 8 / 1_000_000
        if now.timeIntervalSince(session.lastIssues) >= 5 {
            session.lastIssues = now
            live.metered = metered(); live.budgetLeft = live.metered ? budgetLeft().map { max(0, $0) } : nil
            let apps = traffic.apps.filter { !$0.carrier && !own.contains($0.id) && !$0.id.hasPrefix(AppRelay.appBundleID) }
                .map { (id: $0.id, name: $0.name, up: $0.uploadRate, down: $0.downloadRate) }
            live.issues = CloudGamingAnalysis.issues(airDrop: session.awdlActive && !airDropPaused, band: band,
                                                     weak: diagnostics.snapshot?.radio.health == .poor, apps: apps.filter { app in !holding.contains(CallMode.name(of: app.id) ?? "") })
        }
        self.live = live
        if alerts, !session.alerted, !live.issues.isEmpty, now.timeIntervalSince(session.start) >= 30 { session.alerted = true; onIssues?(live) }
        if now.timeIntervalSince(session.lastStats) >= 2 {
            session.lastStats = now
            Task {
                let server = await session.server?.current() ?? []
                let internet = await session.sampler.recentInternet()
                let replies = server.compactMap(\.ms)
                let useServer = server.count >= 10 && replies.count * 2 >= server.count
                let pings = Array((useServer ? server : internet).suffix(30))
                let values = pings.compactMap(\.ms)
                guard self.session === session, var live = self.live else { return }
                live.measured = useServer ? .server : .internet
                live.pingMs = StutterTest.percentile(values.sorted(), 50)
                live.jitterMs = CallAnalysis.jitter(values)
                live.lossPercent = pings.isEmpty ? nil : Double(pings.count - values.count) / Double(pings.count) * 100
                self.live = live
            }
        }
    }

    /// Ends the session being measured and writes its report.
    private func finish(report: Bool, end: Date = Date()) async {
        guard let session else { live = nil; return }
        self.session = nil; live = nil
        let held = holding, paused = airDropPaused
        release()
        let worth = report && end.timeIntervalSince(session.start) >= Self.shortest && session.samples.seconds.count >= 60
        var samples = session.samples
        samples.line = await session.sampler.finish(report: worth, end: end, diagnostics: diagnostics)
        samples.server = await session.server?.stop() ?? []
        guard worth else { return }
        let length = end.timeIntervalSince(session.start)
        samples.seconds = samples.seconds.filter { $0.at <= length }
        let network = session.sampler.reportNetwork
        var card = CloudGamingAnalysis.report(service: session.service, browser: session.browser, start: session.start, end: end, network: network,
                                              metered: metered(), samples: samples)
        card.held = held.isEmpty ? nil : held
        card.airDropPaused = paused ? true : nil
        reports.append(card); reports = Array(reports.suffix(200))
        try? JSONEncoder().encode(reports).write(to: file, options: .atomic)
        onReport?(card)
    }

    /// Ends a session in progress and writes what was measured; the app calls this when it quits.
    public func stop() async { await finish(report: true) }

    // MARK: Pause the culprits

    /// One click while a session plays: pauses AirDrop's link (free; macOS asks for an administrator password) when it's
    /// busy, and with Pro holds the sync, backup and download apps that are moving data, as Call mode for streams does.
    /// Everything comes back when the session ends, when you switch to a held app, or after three hours at most.
    public func pause() async {
        guard let traffic, let diagnostics, let session, !pausing else { return }
        pausing = true; error = nil
        defer { pausing = false }
        if !airDropPaused, !diagnostics.lowLatency.active, !diagnostics.lowLatency.busy, session.awdlActive || live?.issues.contains(where: { $0.kind == .airDrop }) == true {
            let app: (pid: Int32, name: String)? = session.browser == nil
                ? NSWorkspace.shared.runningApplications.first { CloudGamingService.app(id: $0.bundleIdentifier ?? "", name: $0.localizedName ?? "", path: $0.bundleURL?.path)?.id == session.service.id }
                    .map { ($0.processIdentifier, $0.localizedName ?? session.service.name) } : nil
            await diagnostics.lowLatency.enable(seconds: CallMode.limit, app: app)
            guard self.session === session else {
                if diagnostics.lowLatency.active { diagnostics.lowLatency.release() }
                return
            }
            airDropPaused = diagnostics.lowLatency.active
            if !airDropPaused { error = diagnostics.lowLatency.error }
            if airDropPaused { session.awdlActive = false }
        }
        guard self.session === session else { return }
        let movers = traffic.apps.filter { CallMode.name(of: $0.id) != nil && ($0.uploadRate >= CallAnalysis.uploadLoad / 4 || $0.downloadRate >= CallAnalysis.downloadLoad / 4) }
        if !movers.isEmpty {
            if allowed() { hold(movers, traffic: traffic) }
            else if error == nil { error = String(localized: "Holding apps during a session is part of Kilobat Pro.", comment: "Cloud gaming: the pause button without Pro") }
        }
        if var live { live.issues.removeAll { $0.kind == .airDrop && airDropPaused || ($0.app.map(holding.contains) ?? false) }; self.live = live }
    }

    /// Whether the pause button has anything to do now.
    public var pausable: Bool {
        guard let live else { return false }
        return live.issues.contains { $0.kind == .airDrop || $0.pausable == true }
    }

    private func hold(_ apps: [AppTraffic], traffic: TrafficStore) {
        let skipped = Set(UserDefaults.standard.stringArray(forKey: "callModeSkipped") ?? [])
        for app in apps {
            guard let name = CallMode.name(of: app.id), !skipped.contains(name), !released.contains(name), !holding.contains(name) else { continue }
            // A launcher is held only while it downloads: nothing runs a local game during a cloud session.
            if CallMode.launchers.contains(name), app.downloadRate < CallAnalysis.downloadLoad / 2 { continue }
            guard !CallMode.hold(app.processIDs, app: name, owner: CallMode.cloudGaming).isEmpty else { continue }
            holding.append(name)
            if traffic.temporaryRule(app.id) == nil { traffic.setTemporary(app.id, allowed: false, minutes: Int(CallMode.limit / 60)); heldBlocks.append(app.id) }
        }
    }

    /// An app the person brings to the front goes again, and stays out of this session's holds.
    private func releaseFront() {
        guard !holding.isEmpty, let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, let name = CallMode.name(of: front), holding.contains(name) else { return }
        released.insert(name); CallMode.resume(app: name, owner: CallMode.cloudGaming); holding.removeAll { $0 == name }
    }

    /// Resumes what this session holds (not what a call, a stream or a Focus filter holds too) and brings AirDrop back.
    public func release() {
        CallMode.resume(owner: CallMode.cloudGaming)
        for id in heldBlocks { traffic?.clearTemporary(id) }
        heldBlocks = []; holding = []
        if airDropPaused { diagnostics?.lowLatency.release(); airDropPaused = false }
    }

    /// What `kilobat cloud-gaming status` shows, through the app relay.
    public var json: [String: Any] {
        ["enabled": enabled, "notify": notify, "playing": live != nil, "live": live?.json() ?? NSNull(), "holding": holding,
         "airDropPaused": airDropPaused, "reports": reports.count]
    }
}
