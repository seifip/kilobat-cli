import Foundation
import Observation

/// Router check-up's memory: each router's quiet checks by hour, its restarts and slowdowns, in router-checkup.json.
/// It adds nothing to the network: it reads the health check Kilobat already runs, plus the router's hardware
/// address from this Mac's ARP cache. What it keeps stays on this Mac.
@MainActor @Observable public final class RouterWatch {
    public private(set) var records: [RouterRecord] = []
    /// The router this Mac is on now, or was on last.
    public private(set) var current: String?
    /// The current router's check-up, refreshed with each hour and each event.
    public private(set) var report: RouterReport?
    /// A slowdown began; the app decides whether to notify (Pro, and the setting).
    @ObservationIgnored public var onSlowdown: ((RouterRecord, RouterReport) -> Void)?
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private var outage = OutageTracker()
    @ObservationIgnored private var macs: [String: (mac: String?, read: Date)] = [:]
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private let calendar: Calendar

    nonisolated public static let fileName = "router-checkup.json"
    /// Settings › Monitoring: one notification per slowdown. On unless turned off.
    nonisolated public static let alertsKey = "routerCheckupAlerts"
    nonisolated public static func alertsEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: alertsKey) as? Bool ?? true }
    struct Saved: Codable { var current: String?; var routers: [RouterRecord] }

    /// `directory` nil keeps everything in memory, as screenshot runs and tests need.
    public init(directory: URL?, calendar: Calendar = .current) {
        self.calendar = calendar
        file = directory?.appendingPathComponent(Self.fileName)
        if let file, let saved: Saved = StoredJSON.read(file) { records = saved.routers; current = saved.current }
        refresh(now: Date())
    }
    /// Kilobat's own folder; in a screenshot run (KILOBAT_SNAPSHOT) nothing is read or written.
    public convenience init() {
        let snapshot = ProcessInfo.processInfo.environment["KILOBAT_SNAPSHOT"] != nil
        self.init(directory: snapshot ? nil : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat"))
    }
    /// Read-only, for the CLI: the routers as the app last saved them.
    nonisolated public static func load(directory: URL? = nil) -> (current: String?, routers: [RouterRecord]) {
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")
        let saved: Saved? = StoredJSON.read(folder.appendingPathComponent(fileName))
        return (saved?.current, saved?.routers ?? [])
    }

    /// One health check. Looks up the router's hardware address when it's new or hasn't been read for six hours.
    public func observe(_ snapshot: DiagnosticSnapshot, busy: Bool, interval: TimeInterval) async {
        var mac: String?
        if let gateway = snapshot.gateway, snapshot.router?.average != nil {
            let cached = macs[gateway]
            if let cached, Date().timeIntervalSince(cached.read) < (cached.mac == nil ? 600 : 6 * 3600) { mac = cached.mac }
            else { mac = await Self.hardwareAddress(of: gateway); macs[gateway] = (mac, Date()) }
        }
        ingest(snapshot, mac: mac, busy: busy, interval: interval)
    }

    public func ingest(_ snapshot: DiagnosticSnapshot, mac: String?, busy: Bool, interval: TimeInterval, date: Date? = nil) {
        let now = date ?? snapshot.date
        let identified = snapshot.networkIdentified && snapshot.gateway != nil
        let check = identified ? RouterCheck(snapshot, busy: busy) : nil
        let index = identified ? record(network: snapshot.networkKey, mac: mac, name: snapshot.networkName, now: now) : nil
        let id = index.map { records[$0].id }
        switch outage.observe(router: id, reachable: check?.silent == false, gone: snapshot.gateway == nil, date: now, interval: interval) {
        case .drop(let router, let at): if let i = records.firstIndex(where: { $0.id == router }) { records[i].addDrop(at: at, calendar: calendar) }
        case .restart(let router, let at, let seconds): if let i = records.firstIndex(where: { $0.id == router }) { records[i].restarted(at: at, source: .outage, outageSeconds: seconds) }
        case nil: break
        }
        guard let index, let check else { return }
        current = records[index].id
        let hour = records[index].draft?.start
        records[index].add(check, calendar: calendar)
        if hour != records[index].draft?.start || now.timeIntervalSince(lastSave) >= 600 { update(now: now) }
    }

    /// You restarted the router: the day after, Kilobat compares it with the day before.
    public func restarted(at date: Date = Date()) {
        guard let current, let index = records.firstIndex(where: { $0.id == current }) else { return }
        records[index].restarted(at: date, source: .button)
        update(now: date)
    }

    /// Judges restarts and slowdowns, then saves.
    public func update(now: Date = Date()) {
        for index in records.indices {
            for event in records[index].update(now: now, calendar: calendar) {
                guard case .started(let episode) = event, !episode.notified else { continue }
                if let open = records[index].episodes.lastIndex(where: { $0.id == episode.id }) { records[index].episodes[open].notified = true }
                onSlowdown?(records[index], RouterReport(records[index], now: now, calendar: calendar))
            }
        }
        // Routers not seen for 60 days go.
        records.removeAll { now.timeIntervalSince($0.lastSeen) > 60 * 86_400 }
        refresh(now: now)
        save(now: now)
    }

    private func refresh(now: Date) {
        report = current.flatMap { id in records.first { $0.id == id } }.map { RouterReport($0, now: now, calendar: calendar) }
    }

    private func save(now: Date) {
        lastSave = now
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(Saved(current: current, routers: records)).write(to: file, options: .atomic)
    }

    /// The record for this network and router. A router first seen without its address takes the address once known;
    /// a different address on the same network is a different router, such as a replaced one.
    private func record(network: String, mac: String?, name: String, now: Date) -> Int {
        if let mac, let index = records.firstIndex(where: { $0.network == network && $0.mac == mac }) { records[index].name = name; return index }
        // Without an address (the router didn't answer), the router last seen on this network.
        let candidates = records.indices.filter { records[$0].network == network && (records[$0].mac == nil || mac == nil) }
        if let index = candidates.max(by: { records[$0].lastSeen < records[$1].lastSeen }) {
            if records[index].mac == nil, let mac { records[index].mac = mac }
            records[index].name = name
            return index
        }
        records.append(RouterRecord(network: network, mac: mac, name: name, lastSeen: now))
        return records.count - 1
    }

    /// Over 1 Mbit/s while the router was pinged, or 4 Mbit/s on average since the previous check: this Mac's own
    /// traffic queues ahead of the pings and would make the router look slow.
    nonisolated public static let busyDuringCheck: Double = 125_000
    nonisolated public static let busySinceLast: Double = 500_000
    nonisolated public static func busy(checkBytes: UInt64, checkSeconds: Double, sinceBytes: UInt64?, sinceSeconds: Double?) -> Bool {
        if checkSeconds > 0, Double(checkBytes) / checkSeconds >= busyDuringCheck { return true }
        if let sinceBytes, let sinceSeconds, sinceSeconds > 0, Double(sinceBytes) / sinceSeconds >= busySinceLast { return true }
        return false
    }

    /// The router's hardware address from the ARP cache, which the ping just filled.
    static func hardwareAddress(of gateway: String) async -> String? {
        guard ExpertTools.validHost(gateway) else { return nil }
        let result = await CommandRunner.run("/usr/sbin/arp", ["-n", gateway], timeout: 3)
        return parseARP(result.output)
    }
    nonisolated public static func parseARP(_ output: String) -> String? {
        DiagnosticProbe.matches(#" at ([0-9a-fA-F:]+) "#, in: output).first.flatMap(MACAddress.normalized).flatMap { MACAddress.unicast($0) ? $0 : nil }
    }

    #if DEBUG
    /// Sample routers for screenshots; debug builds only.
    public func preview(_ record: RouterRecord, now: Date = Date()) {
        records = [record]; current = record.id; refresh(now: now)
    }
    #endif
}

/// Tells a drop from a restart: checks where the router didn't answer, between two where it did.
/// A restart is 30 seconds to 10 minutes without the router while the Mac stayed awake (no gap between checks longer
/// than three intervals), with at least two silent checks, and then the same router (network and hardware address).
/// Anything shorter is a drop; a different network or a sleep in between is neither.
public struct OutageTracker: Sendable {
    public enum Result: Equatable, Sendable {
        case drop(router: String, at: Date)
        case restart(router: String, at: Date, seconds: Double)
    }
    var lastGood: (router: String, date: Date)?
    var silent: [Date] = []
    var gone = false
    var last: Date?
    public static let shortest: TimeInterval = 30
    public static let longest: TimeInterval = 600
    public init() {}

    /// `router` is the router answering on this network (nil when there's none), `reachable` whether it replied.
    public mutating func observe(router: String?, reachable: Bool, gone noRoute: Bool, date: Date, interval: TimeInterval) -> Result? {
        defer { last = date }
        // A sleep or a pause: whatever happened meanwhile wasn't watched.
        if let last, date.timeIntervalSince(last) > max(180, 3 * interval + 30) { reset() }
        if reachable, let router {
            defer { lastGood = (router, date); silent = []; gone = false }
            guard let previous = lastGood, !silent.isEmpty else { return nil }
            guard previous.router == router else { return nil }
            let first = silent.first ?? date, span = (silent.last ?? date).timeIntervalSince(first)
            let outage = date.timeIntervalSince(previous.date)
            if silent.count >= 2, span >= Self.shortest, outage <= Self.longest + max(60, interval) { return .restart(router: router, at: first, seconds: outage) }
            // One check without replies while the route stayed is lost pings, not a drop.
            return silent.count >= 2 || gone ? .drop(router: router, at: first) : nil
        }
        // On another router's network: not this one's outage.
        if let router, let previous = lastGood, router != previous.router { reset(); return nil }
        guard lastGood != nil else { return nil }
        silent.append(date); gone = gone || noRoute
        if let first = silent.first, date.timeIntervalSince(first) > Self.longest + max(60, interval) { reset() }
        return nil
    }
    mutating func reset() { lastGood = nil; silent = []; gone = false }
}
