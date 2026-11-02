import Foundation
import Observation

/// Hotspot throttling: on a phone hotspot, whether the carrier caps it. Reads what Kilobat already measures (service
/// speed's big downloads, the speed tests, Health's pings) and, only on a hotspot, times video passively from the
/// traffic monitor's rows. The carrier comes from the person's pick, or from the public address's network when they
/// press Detect. Kept in hotspot.json, on this Mac.
@MainActor @Observable public final class HotspotWatch {
    public static let shared = HotspotWatch()
    public private(set) var log = HotspotLog()
    /// The current network's report; nil before the first refresh.
    public private(set) var report: HotspotThrottleReport?
    public private(set) var detecting = false
    public private(set) var detectError: String?
    /// Off in Lite: nothing is kept.
    public var enabled = true

    @ObservationIgnored public var hostnames: () -> [String: String] = { [:] }
    @ObservationIgnored public var reverse: (String) -> String? = { _ in nil }
    @ObservationIgnored public var isCarrier: (Int32) -> Bool = { _ in false }
    @ObservationIgnored public var transfers: (String) -> [String: [ServiceTransfer]] = { _ in [:] }
    @ObservationIgnored public var speedTests: () -> [SavedSpeedTest] = { [] }
    @ObservationIgnored public var samples: () -> [DiagnosticSnapshot] = { [] }
    /// The public address, from the app's exit path when it has one.
    @ObservationIgnored public var publicAddress: () async throws -> String = { try await ExitPath.publicAddress().address }
    @ObservationIgnored private var meter = HotspotVideoMeter()
    @ObservationIgnored private var network: (key: String, name: String, kind: HotspotKind)?
    @ObservationIgnored private var refreshed = Date.distantPast
    @ObservationIgnored private let file: URL?

    nonisolated public static let fileName = "hotspot.json"

    public init(directory: URL?) {
        file = directory?.appendingPathComponent(Self.fileName)
        if let file, let saved: HotspotLog = StoredJSON.read(file) { log = saved; log.prune() }
    }
    public convenience init() {
        let snapshot = ProcessInfo.processInfo.environment["KILOBAT_SNAPSHOT"] != nil
        self.init(directory: snapshot ? nil : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat"))
    }
    /// Read-only, for the CLI.
    nonisolated public static func load(directory: URL? = nil) -> HotspotLog {
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")
        var log: HotspotLog = StoredJSON.read(folder.appendingPathComponent(fileName)) ?? HotspotLog()
        log.prune()
        return log
    }

    /// One nettop sample. `kind` is nil off a hotspot: then nothing is timed. Through a VPN the carrier's path isn't
    /// the one measured, so video doesn't count then.
    public func consume(_ snapshot: TrafficSnapshot, network key: String, name: String, kind: HotspotKind?, vpn: Bool) {
        guard enabled else { return }
        let current = kind.flatMap { key == "unknown" ? nil : (key: key, name: name, kind: $0) }
        if network?.key != current?.key || network?.kind != current?.kind {
            record(meter.finish())
            network = current
            if let current { log.seen(current.key, name: current.name, kind: current.kind, now: snapshot.timestamp); save() }
            refresh(now: snapshot.timestamp)
        }
        guard network != nil else { return }
        if snapshot.timestamp.timeIntervalSince(refreshed) >= 120 { refresh(now: snapshot.timestamp) }
        guard !vpn else { record(meter.finish()); return }
        let names = hostnames()
        let ended = meter.ingest(snapshot) { process, address in
            guard !self.isCarrier(process.pid) else { return nil }
            return ServiceSpeedCatalog.video(host: names[address], reverse: self.reverse(address), owner: NetworkOwners.shared.owner(address))
        }
        record(ended)
    }

    public func pause() { record(meter.finish()) }

    private func record(_ ended: [HotspotVideoSession]) {
        guard !ended.isEmpty, let network else { return }
        for session in ended { log.add(session, network: network.key, name: network.name) }
        save(); refresh()
    }

    /// Rebuilds the report for the current network (or the last hotspot, before the first sample).
    public func refresh(now: Date = Date()) {
        refreshed = now
        let key = network?.key ?? log.current
        guard let key else { report = nil; return }
        let entry = log.networks[key]
        let kind = network?.key == key ? network?.kind : nil
        report = HotspotThrottleReport(network: key, networkName: entry?.name ?? network?.name ?? key, kind: kind, transfers: transfers(key), speedTests: speedTests(),
                                       latency: samples().filter { $0.networkKey == key }.compactMap(HotspotLatency.init), video: entry?.video ?? [],
                                       carrier: log.carrier(for: key), now: now)
    }

    /// The person's pick for the current network; nil goes back to the lookup's.
    public func choose(_ id: String?) {
        guard let key = network?.key ?? log.current else { return }
        var entry = log.networks[key] ?? HotspotLog.Network(name: network?.name ?? key)
        entry.carrier = id.flatMap { HotspotCarriers.carrier($0)?.id }
        log.networks[key] = entry
        save(); refresh()
    }

    /// Asks Cloudflare for the public address (unless the app has it) and RIPE NCC whose network it is: only when the
    /// person presses Detect, as outage credit does.
    public func detect() async {
        guard !detecting, let key = network?.key ?? log.current else { return }
        detecting = true; detectError = nil; defer { detecting = false }
        do {
            let found = try await ProviderLookup.lookup(address: try await publicAddress())
            let carrier = HotspotCarriers.match(asn: found.asn, organization: found.organization, country: found.country)
            var entry = log.networks[key] ?? HotspotLog.Network(name: network?.name ?? key)
            entry.lookup = HotspotLog.Lookup(carrier: carrier?.id, asn: found.asn, organization: found.organization, country: found.country, date: Date())
            log.networks[key] = entry
            if carrier == nil {
                detectError = String(localized: "Kilobat has no page for this network (\(found.organization ?? "AS\(found.asn.map(String.init) ?? "?")")). Pick your carrier, or see every carrier’s rules.", comment: "Hotspot throttling: the lookup found a network without a carrier page; the argument is its registered name")
            }
            save(); refresh()
        } catch {
            detectError = String(localized: "Couldn’t look it up: \(error.localizedDescription)", comment: "Hotspot throttling carrier lookup failed")
        }
    }

    private func save() {
        guard let file else { return }
        try? JSONEncoder().encode(log).write(to: file, options: .atomic)
    }

    #if DEBUG
    /// Made-up history for screenshots; debug builds only.
    public func preview(_ log: HotspotLog, report: HotspotThrottleReport) {
        self.log = log; self.report = report
    }
    #endif
}
