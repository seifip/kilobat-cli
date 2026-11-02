import Foundation
import Observation

/// When to ask a status page, and when an answer is worth a word. Pure, so the decisions can be tested.
public enum ServiceTriggers {
    /// This Mac's own line checked out: no login page, and Health isn't poor or still unknown. Only then may Kilobat say "not you".
    public static func lineFine(_ snapshot: DiagnosticSnapshot?) -> Bool {
        guard let snapshot, snapshot.captivePortal != true else { return false }
        return snapshot.health == .good || snapshot.health == .degraded
    }

    /// The services of the apps in front or moving data now, at most `limit`, for Health's check.
    public static func services(active apps: [AppTraffic], frontmost: String?, limit: Int = 6) -> [StatusService] {
        let candidates = (frontmost.map(ServiceCatalog.services(forApp:)) ?? [])
            + apps.filter { !$0.carrier && $0.rate > 0 }.sorted { $0.rate > $1.rate }.flatMap(ServiceCatalog.services(for:))
        var found: [StatusService] = []
        for service in candidates where !found.contains(service) { found.append(service) }
        return Array(found.prefix(limit))
    }

    /// The services a connection check is about: its host, the hosts it was redirected to, and the app named.
    public static func services(for report: DoctorReport) -> [StatusService] {
        var found: [StatusService] = []
        for service in [report.host].flatMap(ServiceCatalog.services(forHost:)) + report.hops.map(\.host).flatMap(ServiceCatalog.services(forHost:))
            + (report.app.map(ServiceCatalog.services(forApp:)) ?? []) where !found.contains(service) { found.append(service) }
        return Array(found.prefix(3))
    }

    /// Layers that are this Mac's or its network's own: when one of them failed, an outage elsewhere is a side note, not the answer.
    static let localLayers: Set<String> = ["Network", "Interface", "Proxy", "App proxy", "Proxy app", "Kilobat rules", "Direct path", "App setting", "Provider", "Context", "Wi-Fi sign-in"]

    /// Whether the connection check points past this Mac: nothing failed, or what failed is the server's side of the path.
    public static func pointsBeyondThisMac(_ report: DoctorReport) -> Bool {
        guard let failed = report.steps.first(where: { $0.status == .failed }) else { return true }
        if localLayers.contains(failed.layer) { return false }
        if failed.layer == "DNS", failed.says(.privateResolver, "private resolver") || failed.says(.publicResolves, "1.1.1.1 resolves") { return false }
        return true
    }

    /// A call is worth a status check when it froze beyond the router, which is where the calling service's own servers are.
    public static func callNeedsCheck(_ report: CallReport) -> Bool {
        !report.browser && report.causes.contains { $0.cause.kind == .beyondRouter || $0.cause.unconfirmed == true } && !ServiceCatalog.services(forCallApp: report.app).isEmpty
    }

    /// What the watch follows, by key, with the connections each has stuck opening: every app or agent with a known service
    /// (by its ID, or the agent it is), and any app's stuck connections to a provider's API host, as "app id|service id".
    public struct Watched: Sendable, Equatable {
        public let count: Int
        public let services: [StatusService]
        /// The app or agent as an alert names it.
        public let app: String
    }

    /// `opening`: stuck remote addresses by app id. `endpoints`: service ids by address of their API hosts.
    public static func watched(apps: [AppTraffic], opening: [String: [String]], endpoints: [String: [String]]) -> [String: Watched] {
        var watched: [String: Watched] = [:]
        for app in apps {
            let own = ServiceCatalog.services(for: app), name = ServiceCatalog.displayName(app), stuck = opening[app.id] ?? []
            if !own.isEmpty { watched[app.id] = Watched(count: stuck.count, services: own, app: name) }
            var byService: [String: Int] = [:]
            for address in stuck { for id in endpoints[address] ?? [] where !own.contains(where: { $0.id == id }) { byService[id, default: 0] += 1 } }
            for (id, count) in byService {
                guard let service = ServiceCatalog.services.first(where: { $0.id == id }) else { continue }
                watched[app.id + "|" + id] = Watched(count: count, services: [service], app: name)
            }
        }
        return watched
    }

    /// An incident that started after the call ended didn't freeze it.
    public static func relevant(_ status: ServiceStatus, toCallEnding end: Date) -> Bool {
        status.started.map { $0 <= end.addingTimeInterval(300) } ?? true
    }
}

/// Apps whose TCP connections keep failing to open: a connection still waiting for the server's answer (SynSent) in two
/// samples in a row, or three at once. Apps that stop showing up are forgotten.
public struct FailingApps: Sendable, Equatable {
    var streak: [String: Int] = [:]
    public init() {}
    public mutating func update(_ connecting: [String: Int]) -> Set<String> {
        var failing = Set<String>(), next: [String: Int] = [:]
        for (app, count) in connecting {
            next[app] = count > 0 ? (streak[app] ?? 0) + 1 : 0
            if count >= 3 || next[app]! >= 2 { failing.insert(app) }
        }
        streak = next
        return failing
    }
}

/// One notification per incident, at most one per service in half an hour and three an hour in all. Kept in
/// preferences so a restart doesn't repeat one.
public struct ServiceAlertPolicy: Codable, Sendable, Equatable {
    var sent: [String: Date] = [:]
    public init() {}
    public static func key(_ status: ServiceStatus) -> String { status.id + "|" + (status.incident ?? status.state.rawValue) }

    /// Outages, and degraded service with a named incident; never maintenance or a plain colour change.
    public static func worthTelling(_ status: ServiceStatus) -> Bool { status.outage || (status.state == .degraded && status.incident != nil) }

    public mutating func shouldAlert(_ status: ServiceStatus, now: Date = Date()) -> Bool {
        sent = sent.filter { now.timeIntervalSince($0.value) < 86_400 }
        guard Self.worthTelling(status), sent[Self.key(status)] == nil else { return false }
        guard !sent.contains(where: { $0.key.hasPrefix(status.id + "|") && now.timeIntervalSince($0.value) < 1800 }) else { return false }
        guard sent.values.filter({ now.timeIntervalSince($0) < 3600 }).count < 3 else { return false }
        sent[Self.key(status)] = now
        return true
    }
}

/// Connection states from one nettop sample: the only way to see an app's connections fail without capturing packets.
public enum ConnectionStates {
    /// The remote addresses of TCP connections each process is still opening, for these processes.
    public static func connecting(pids: Set<Int32>) async -> [Int32: [String]] {
        guard !pids.isEmpty else { return [:] }
        return await Task.detached(priority: .utility) {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
            process.arguments = ["-L", "1", "-n", "-x", "-m", "tcp", "-J", "state"] + pids.sorted().prefix(64).flatMap { ["-p", String($0)] }
            process.standardOutput = output; process.standardError = Pipe(); process.standardInput = Pipe()
            guard (try? process.run()) != nil else { return [:] }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return parse(String(decoding: data, as: UTF8.self), pids: pids)
        }.value
    }

    /// Process rows (`name.pid,,`) come before their connections (`tcp4 local<->remote,SynSent,`).
    static func parse(_ text: String, pids: Set<Int32>) -> [Int32: [String]] {
        var current: Int32?, remotes: [Int32: [String]] = [:]
        for line in text.split(separator: "\n") {
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.count >= 2 else { continue }
            let head = columns[0]
            guard let arrow = head.range(of: "<->"), let space = head.firstIndex(of: " ") else {
                if let dot = head.lastIndex(of: "."), let pid = Int32(head[head.index(after: dot)...]) { current = pid; if pids.contains(pid) { remotes[pid] = remotes[pid] ?? [] } }
                continue
            }
            guard let pid = current, pids.contains(pid), columns[1] == "SynSent" else { continue }
            let (address, _) = TrafficRoute.endpoint(head[arrow.upperBound...], v6: head[..<space].hasSuffix("6"))
            if address == "*" || OpenConnections.isLoopback(address) { continue }
            remotes[pid, default: []].append(address)
        }
        return remotes
    }
}

/// The status pages of the services you use, asked only when something points their way: Health on a fine line, a
/// connection check, a call that froze beyond the router, or an app whose connections keep failing.
@MainActor @Observable public final class ServiceWatch {
    public static let shared = ServiceWatch()
    /// Notifications for outages Kilobat notices on its own. Health, connection checks and call reports show them either way.
    public var alerts = UserDefaults.standard.object(forKey: "serviceAlerts") as? Bool ?? true {
        didSet { UserDefaults.standard.set(alerts, forKey: "serviceAlerts") }
    }
    /// Notifications when a service you use looks blocked on this network, at most once per service per network a day.
    /// Connection checks and the Services list show blocks either way.
    public var blockAlerts = UserDefaults.standard.object(forKey: "blockAlerts") as? Bool ?? true {
        didSet { UserDefaults.standard.set(blockAlerts, forKey: "blockAlerts") }
    }
    /// Blocks and regional refusals measured on the current network, by service id (or host).
    public private(set) var blocks: [String: NetworkBlock] = [:]
    /// The latest answer for each service, by id.
    public private(set) var statuses: [String: ServiceStatus] = [:]
    /// Health's last check of the apps in use: what was asked and when.
    public private(set) var active: (statuses: [ServiceStatus], date: Date)?
    public private(set) var checking = false
    @ObservationIgnored public var checker = ServiceStatusChecker.shared
    /// Posts the notification, with the app or agent that was failing when there is one; set by the app.
    @ObservationIgnored public var onAlert: ((ServiceStatus, String?) -> Void)?
    @ObservationIgnored private var policy: ServiceAlertPolicy
    /// Posts the block notification, with the app that kept failing; set by the app.
    @ObservationIgnored public var onBlockAlert: ((NetworkBlock, String?) -> Void)?
    /// Whether Kilobat's own rules, Protection or kill switch stop this host; set by the app. A block of Kilobat's own is never the network's.
    @ObservationIgnored public var ownBlock: (@MainActor (_ host: String) -> Bool)?
    @ObservationIgnored private var blockPolicy: BlockAlertPolicy
    /// The network the listed blocks were measured on, and when each service was last checked there.
    @ObservationIgnored private var blockNetwork: String?
    @ObservationIgnored private var blockChecked: [String: Date] = [:]
    /// How long a block stays listed without a fresh check, and the least time between two checks of one service on one network.
    public static let blockListedFor: TimeInterval = 3600, blockSpacing: TimeInterval = 3600
    @ObservationIgnored private var failing = FailingApps()
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// How long a problem stays listed without a fresh answer.
    public static let listedFor: TimeInterval = 900

    public init() {
        policy = UserDefaults.standard.data(forKey: "serviceAlertsSent").flatMap { try? JSONDecoder().decode(ServiceAlertPolicy.self, from: $0) } ?? ServiceAlertPolicy()
        blockPolicy = UserDefaults.standard.data(forKey: "blockAlertsSent").flatMap { try? JSONDecoder().decode(BlockAlertPolicy.self, from: $0) } ?? BlockAlertPolicy()
    }

    /// A block a connection check or this watch measured, kept for the network it was measured on. Another network clears the list.
    public func record(_ block: NetworkBlock, network: String?) {
        if network != blockNetwork { blocks = [:]; blockChecked = [:]; blockNetwork = network }
        blocks[block.serviceID ?? block.host] = block
    }

    /// Blocks measured on this network lately, newest first.
    public func blocked(network: String?, now: Date = Date()) -> [NetworkBlock] {
        guard network == blockNetwork else { return [] }
        return blocks.values.filter { now.timeIntervalSince($0.date) < Self.blockListedFor }.sorted { $0.date != $1.date ? $0.date > $1.date : $0.host < $1.host }
    }

    #if DEBUG
    /// Made-up answers for screenshots; debug builds only.
    public func preview(_ statuses: [ServiceStatus], active: [ServiceStatus]? = nil, blocks: [NetworkBlock] = [], network: String? = nil) {
        for status in statuses { self.statuses[status.id] = status }
        self.active = active.map { ($0, Date()) }
        for block in blocks { record(block, network: network) }
    }
    #endif

    @discardableResult public func check(_ services: [StatusService]) async -> [ServiceStatus] {
        guard !services.isEmpty else { return [] }
        let results = await checker.check(services)
        for status in results where status.state != .unknown || statuses[status.id] == nil { statuses[status.id] = status }
        return results
    }

    /// Problems right now among what was checked, worst first. Nothing when all is fine.
    public func problems(now: Date = Date()) -> [ServiceStatus] {
        statuses.values.filter { $0.problem && now.timeIntervalSince($0.checked) < Self.listedFor }
            .sorted { $0.state != $1.state ? $0.state > $1.state : $0.service < $1.service }
    }

    /// Asks again about listed problems older than the cache, so a resolved outage drops off when it's looked at.
    public func refreshProblems(now: Date = Date()) async {
        let stale = problems(now: now).filter { now.timeIntervalSince($0.checked) >= ServiceStatusChecker.freshFor }
        let services = ServiceCatalog.services.filter { service in stale.contains { $0.id == service.id } }
        await check(services)
    }

    /// Health's check: the services of the apps in front or moving data, while this Mac's line looks fine.
    public func checkActive(apps: [AppTraffic], frontmost: String?, snapshot: DiagnosticSnapshot?) async {
        guard ServiceTriggers.lineFine(snapshot), !checking else { return }
        let services = ServiceTriggers.services(active: apps, frontmost: frontmost)
        guard !services.isEmpty else { active = nil; return }
        checking = true; defer { checking = false }
        active = (await check(services), Date())
    }

    /// Every minute, for running apps with a known service: sample their connections' states, and when one keeps failing to
    /// connect on a line that's fine, ask its status page. Nothing is sent anywhere unless that happens.
    public func start(traffic: TrafficStore, diagnostics: DiagnosticStore) {
        guard loop == nil else { return }
        loop = Task { [weak self, weak traffic, weak diagnostics] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, let traffic, let diagnostics else { return }
                if !diagnostics.sleeping { await self.tick(traffic: traffic, snapshot: diagnostics.snapshot) }
            }
        }
    }

    public func stop() { loop?.cancel(); loop = nil }

    private func tick(traffic: TrafficStore, snapshot: DiagnosticSnapshot?) async {
        guard traffic.connected, ServiceTriggers.lineFine(snapshot) else { failing = FailingApps(); return }
        let apps = traffic.apps.filter { !$0.carrier && !$0.processIDs.isEmpty }
        guard !apps.isEmpty else { failing = FailingApps(); return }
        let remotes = await ConnectionStates.connecting(pids: Set(apps.flatMap(\.processIDs)))
        let opening = Dictionary(apps.map { app in (app.id, app.processIDs.flatMap { remotes[$0] ?? [] }) }, uniquingKeysWith: +)
        // Look the providers' API hosts up only when some connection is stuck, and keep the answer for ten minutes.
        let endpoints = opening.values.contains { !$0.isEmpty } ? await endpointAddresses() : [:]
        let watched = ServiceTriggers.watched(apps: apps, opening: opening, endpoints: endpoints)
        let failingKeys = failing.update(watched.mapValues(\.count))
        guard !failingKeys.isEmpty else { return }
        var asked: [(service: StatusService, app: String)] = []
        for key in failingKeys.sorted() {
            guard let entry = watched[key] else { continue }
            for service in entry.services where !asked.contains(where: { $0.service == service }) { asked.append((service, entry.app)) }
        }
        let statuses = await check(Array(asked.prefix(4).map(\.service)))
        for (status, entry) in zip(statuses, asked.prefix(4)) { alert(status, app: entry.app) }
        // A page that reports no outage: whether this network blocks the service, at most once an hour per service here.
        let network = traffic.networkKey
        for (status, entry) in zip(statuses, asked.prefix(4)) where !status.outage {
            let key = entry.service.id + "|" + network, now = Date()
            guard blockChecked[key].map({ now.timeIntervalSince($0) >= Self.blockSpacing }) ?? true,
                  let host = entry.service.endpoints.first ?? entry.service.hosts.first, ownBlock?(host) != true else { continue }
            if network != blockNetwork { blocks = [:]; blockChecked = [:]; blockNetwork = network }
            blockChecked[key] = now
            async let place = NetworkBlockCheck.place(networkKey: network)
            async let vpn = NetworkBlockCheck.vpn()
            let found = await NetworkBlockCheck.reach(entry.service, status: status, place: await place, vpn: await vpn,
                                                      resolver: TrustedResolver.chosen(traffic.preferences))
            if let block = found.block { record(block, network: network); alert(block, app: entry.app, network: network) }
            else if found.reachable == true { blocks[entry.service.id] = nil }
        }
    }

    /// The block notification, at most once per service per network a day, when it's on.
    public func alert(_ block: NetworkBlock, app: String? = nil, network: String, now: Date = Date()) {
        guard blockAlerts, blockPolicy.shouldAlert(block, network: network, now: now) else { return }
        if let data = try? JSONEncoder().encode(blockPolicy) { UserDefaults.standard.set(data, forKey: "blockAlertsSent") }
        onBlockAlert?(block, app)
    }

    @ObservationIgnored private var endpointCache: (addresses: [String: [String]], date: Date)?

    /// Addresses of the catalog's API hosts (api.anthropic.com, api.openai.com and so on), by service id.
    private func endpointAddresses(now: Date = Date()) async -> [String: [String]] {
        if let cache = endpointCache, now.timeIntervalSince(cache.date) < 600 { return cache.addresses }
        var addresses: [String: [String]] = [:]
        for service in ServiceCatalog.services { for host in service.endpoints {
            for address in await ConnectionDoctor.resolve(host) { addresses[address, default: []].append(service.id) }
        } }
        endpointCache = (addresses, now)
        return addresses
    }

    /// The notification for an outage, once per incident, when notifications are on. `app` is what was failing, such as Claude Code.
    public func alert(_ status: ServiceStatus, app: String? = nil, now: Date = Date()) {
        guard alerts, policy.shouldAlert(status, now: now) else { return }
        if let data = try? JSONEncoder().encode(policy) { UserDefaults.standard.set(data, forKey: "serviceAlertsSent") }
        onAlert?(status, app)
    }
}
