import Foundation
import Observation

/// Service speed: how fast this Mac's own big downloads from GitHub, iCloud, Steam and the rest actually ran, per network,
/// and when one service is slow while the rest is fast, the finding. Fed by the traffic monitor's per-connection rows
/// (nothing extra on the network); names come from the filter's hostnames, reverse DNS through this Mac's resolver and
/// the bundled network table. Kept in service-speed.json, on this Mac.
@MainActor @Observable public final class ServiceSpeedWatch {
    public static let shared = ServiceSpeedWatch()
    public private(set) var log = ServiceSpeedLog()
    /// The current network's report, refreshed when a transfer ends, a trace finishes or a test runs.
    public private(set) var report: ServiceSpeedReport?
    /// The target being tested, and the last test's error.
    public private(set) var testing: String?
    public private(set) var testError: String?
    /// Off in Lite: nothing is kept.
    public var enabled = true

    /// Names apps asked for by address, from the network filter while it runs.
    @ObservationIgnored public var hostnames: () -> [String: String] = { [:] }
    /// The app a process belongs to (a bundle ID or process:<name>), from the traffic store.
    @ObservationIgnored public var appID: (ProcessTraffic) -> String? = { _ in nil }
    /// Proxy cores and VPN clients carry other apps' traffic; theirs is never a service's.
    @ObservationIgnored public var isCarrier: (Int32) -> Bool = { _ in false }
    @ObservationIgnored public var speedTests: () -> [SavedSpeedTest] = { [] }
    @ObservationIgnored public var statuses: () -> [String: ServiceStatus] = { [:] }
    /// Asks the service's status page; the app routes it through `ServiceWatch`, which caches answers.
    @ObservationIgnored public var checkStatus: ([StatusService]) async -> Void = { _ in }
    /// Traces the route to an address (three probes a hop) and returns traceroute's output; nil leaves it untraced.
    @ObservationIgnored public var trace: ((String) async -> String?)? = nil
    @ObservationIgnored public var lookup = HostLookup.live
    @ObservationIgnored private var tracker = ServiceFlowTracker()
    @ObservationIgnored private var reverse: [String: String?] = [:]
    @ObservationIgnored private var resolving: Set<String> = []
    @ObservationIgnored private var network: (key: String, name: String)?
    @ObservationIgnored private var lastFinding: String?
    @ObservationIgnored private var refreshed = Date.distantPast
    @ObservationIgnored private var tracing: Set<String> = []
    @ObservationIgnored private let file: URL?

    nonisolated public static let fileName = "service-speed.json"

    /// `directory` nil keeps everything in memory, as screenshot runs and tests need.
    public init(directory: URL?) {
        file = directory?.appendingPathComponent(Self.fileName)
        if let file, let saved: ServiceSpeedLog = StoredJSON.read(file) { log = saved; log.prune() }
    }
    /// Kilobat's own folder; in a screenshot run (KILOBAT_SNAPSHOT) nothing is read or written.
    public convenience init() {
        let snapshot = ProcessInfo.processInfo.environment["KILOBAT_SNAPSHOT"] != nil
        self.init(directory: snapshot ? nil : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat"))
    }
    /// Read-only, for the CLI: the log as the app last saved it.
    nonisolated public static func load(directory: URL? = nil) -> ServiceSpeedLog {
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")
        var log: ServiceSpeedLog = StoredJSON.read(folder.appendingPathComponent(fileName)) ?? ServiceSpeedLog()
        log.prune()
        return log
    }

    /// One nettop sample on `network`. Through a VPN the provider's route isn't the one measured, so nothing counts then.
    public func consume(_ snapshot: TrafficSnapshot, network key: String, name: String, vpn: Bool) {
        guard enabled else { return }
        if network?.key != key || vpn || key == "unknown" {
            record(tracker.finish())
            let changed = network?.key != key
            network = vpn || key == "unknown" ? nil : (key, name)
            guard network != nil else { return }
            if changed { refresh() }
        }
        // "Tonight" and "today" age, and an hour-old finding may no longer hold.
        if snapshot.timestamp.timeIntervalSince(refreshed) >= 300 { refresh(now: snapshot.timestamp) }
        let names = hostnames()
        let ended = tracker.ingest(snapshot) { process, address, _, _ in
            guard !self.isCarrier(process.pid) else { return nil }
            if self.reverse[address] == nil { self.resolve(address) }
            let host = names[address]
            return ServiceSpeedCatalog.attribute(host: host, reverse: self.reverse[address] ?? nil, app: self.appID(process), owner: NetworkOwners.shared.owner(address))
        }
        record(ended)
    }

    /// The Mac is going to sleep or the monitor stopped: transfers in progress end here.
    public func pause() { record(tracker.finish()); network = nil }

    private func record(_ ended: [(key: String, transfer: ServiceTransfer)]) {
        guard !ended.isEmpty, let network else { return }
        for (key, transfer) in ended { log.add(transfer, key: key, network: network.key, name: network.name) }
        log.current = network.key
        save()
        refresh()
    }

    /// Reverse DNS for an address a download comes from, once; a name can tell the network when the table can't.
    private func resolve(_ address: String) {
        guard !resolving.contains(address), reverse.count < 4_000 else { return }
        resolving.insert(address)
        let lookup = self.lookup
        Task { [weak self] in
            let name = await lookup.reverse(address)
            self?.reverse[address] = .some(name)
            self?.resolving.remove(address)
        }
    }

    /// Rebuilds the current network's report; a new finding asks the service's status page and traces the route once.
    public func refresh(now: Date = Date()) {
        refreshed = now
        guard let key = network?.key ?? log.current else { report = nil; return }
        let report = ServiceSpeedReport(log: log, network: key, speedTests: speedTests(), statuses: statuses(), now: now)
        self.report = report
        guard let finding = report.finding else { lastFinding = nil; return }
        let id = key + "|" + finding.key
        if lastFinding != id {
            lastFinding = id
            if let status = ServiceSpeedCatalog.service(finding.key)?.status, let service = ServiceCatalog.services.first(where: { $0.id == status }) {
                Task { [weak self] in
                    await self?.checkStatus([service])
                    self?.refresh()
                }
            }
        }
        if let address = finding.traceAddress { traceRoute(to: address, key: finding.key, network: key) }
    }

    /// One route trace per slow service a day, kept with the finding.
    private func traceRoute(to address: String, key: String, network: String) {
        let id = network + "|" + key
        guard let trace, !tracing.contains(id) else { return }
        tracing.insert(id)
        Task { [weak self] in
            guard let output = await trace(address) else { self?.tracing.remove(id); return }
            guard let self else { return }
            self.log.setTrace(ServiceRouteTrace(date: Date(), address: address, output: output), key: key, network: network)
            self.save()
            self.tracing.remove(id)
            self.refresh()
        }
    }

    /// Test this service: at most 25 MB from the target's public file. Refused on a metered network.
    public func test(_ target: ServiceSpeedTarget, metered: Bool) async {
        guard testing == nil else { return }
        testing = target.id; testError = nil
        defer { testing = nil }
        do {
            let transfer = try await ServiceSpeedTest.run(target, metered: metered)
            let saved = log.current.map { (key: $0, name: log.networks[$0]?.name ?? $0) }
            guard let network = network ?? saved else { return }
            log.add(transfer, key: target.key, network: network.key, name: network.name)
            log.current = network.key
            save(); refresh()
        } catch {
            testError = error.localizedDescription
        }
    }

    private func save() {
        guard let file else { return }
        try? JSONEncoder().encode(log).write(to: file, options: .atomic)
    }

    #if DEBUG
    /// Made-up history for screenshots; debug builds only.
    public func preview(_ log: ServiceSpeedLog, network: String, speedTests: [SavedSpeedTest], statuses: [String: ServiceStatus] = [:], now: Date = Date()) {
        self.log = log
        report = ServiceSpeedReport(log: log, network: network, speedTests: speedTests, statuses: statuses, now: now)
    }
    #endif
}
