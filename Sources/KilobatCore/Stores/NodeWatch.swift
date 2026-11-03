import Foundation
import Observation

/// Notices the Mac clinging to a far mesh node or access point while a much closer one is in range, and moves it
/// when asked. It reads the radio with each health check and, while the signal is weak, scans for the same network
/// at most every two minutes, never during a call. Node names and past episodes stay in wifi-nodes.json.
@MainActor @Observable public final class NodeWatch {
    public private(set) var report: NodeReport?
    public private(set) var reconnecting = false
    /// The last reconnect, shown until the next one or until the network changes.
    public private(set) var outcome: NodeReconnect?
    /// A stuck episode has lasted five minutes; the app decides whether to notify (the setting).
    @ObservationIgnored public var onStuck: ((NodeReport) -> Void)?
    /// A call is on: no scans then, since a scan takes the radio off its channel for a moment.
    @ObservationIgnored public var callLive: () -> Bool = { false }
    @ObservationIgnored private var detector = StickyDetector()
    @ObservationIgnored private var places: [String: NodePlace] = [:]
    @ObservationIgnored private var lastScan = Date.distantPast
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private let probe = DiagnosticProbe()

    nonisolated public static let fileName = "wifi-nodes.json"
    /// Settings › Monitoring: tell me when the Mac stays on a far node. On unless turned off.
    nonisolated public static let alertsKey = "farNodeAlerts"
    nonisolated public static func alertsEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: alertsKey) as? Bool ?? true }
    /// How long an episode lasts before a notification, and how often one network may get one.
    public static let notifyAfter: TimeInterval = 300
    public static let notifyEvery: TimeInterval = 6 * 3600
    /// A scan while the signal is weak, at most this often.
    public static let scanEvery: TimeInterval = 120

    /// One network's node names, by BSSID, and its stuck episodes.
    public struct NodePlace: Codable, Sendable, Equatable {
        public var ssid: String?
        public var names: [String: String] = [:]
        public var episodes: [Episode] = []
        public var notified: Date?
    }
    public struct Episode: Codable, Sendable, Equatable {
        public let start: Date
        public var end: Date?
        public let node: String
        public let better: String
        public var notified = false
    }

    /// `directory` nil keeps everything in memory, as screenshot runs and tests need.
    public init(directory: URL?) {
        file = directory?.appendingPathComponent(Self.fileName)
        if let file, let saved: [String: NodePlace] = StoredJSON.read(file) { places = saved }
    }
    /// Kilobat's own folder; in a screenshot run (KILOBAT_SNAPSHOT) nothing is read or written.
    public convenience init() {
        let snapshot = ProcessInfo.processInfo.environment["KILOBAT_SNAPSHOT"] != nil
        self.init(directory: snapshot ? nil : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat"))
    }
    public func place(_ network: String) -> NodePlace? { places[network] }
    private static let snapshotRun = ProcessInfo.processInfo.environment["KILOBAT_SNAPSHOT"] != nil

    private func interruptEpisode() {
        defer { detector.reset() }
        guard let report, let key = report.network, var place = places[key],
              let last = place.episodes.indices.last, place.episodes[last].end == nil else { return }
        place.episodes[last].end = max(report.date, place.episodes[last].start)
        places[key] = place
        save()
    }

    private var observation = UUID()

    /// One health check.
    public func observe(_ snapshot: DiagnosticSnapshot, locationAllowed: Bool) async {
        // A screenshot run shows sample nodes and never scans.
        guard !Self.snapshotRun else { return }
        let token = UUID()
        observation = token
        let network = snapshot.networkKey
        guard snapshot.wiredInterface == nil, snapshot.radio.interface != nil, let rssi = snapshot.radio.rssi else {
            interruptEpisode(); report = NodeReport(date: snapshot.date, ssid: nil, network: nil, state: .notWiFi); return
        }
        guard locationAllowed else { interruptEpisode(); report = NodeReport(date: snapshot.date, ssid: snapshot.radio.ssid, network: network, state: .noLocation); return }
        let now = Date()
        let scan = rssi < MeshNodes.weakAbove && !callLive() && !reconnecting && now.timeIntervalSince(lastScan) >= Self.scanEvery
        if scan { lastScan = now }
        let reading = await probe.nodeReading(activeScan: scan)
        guard !reconnecting, observation == token else { return }
        ingest(reading, network: network)
    }

    /// One reading on `network`, for `observe` and tests.
    public func ingest(_ reading: NodeReading, network: String) {
        if report?.network != network { interruptEpisode(); outcome = nil }
        var place = places[network] ?? NodePlace()
        if let ssid = reading.ssid { place.ssid = ssid }
        detector.observe(reading, names: place.names)
        let nodes = MeshNodes.nodes(reading.radios, current: reading.current?.bssid, names: place.names)
        // A named node's radios that weren't seen before take its name, so the name follows the box.
        for node in nodes { if let name = node.name { for radio in node.radios where place.names[radio.bssid] == nil { place.names[radio.bssid] = name } } }
        let stuck = detector.stuck
        if let stuck {
            if place.episodes.last.map({ $0.end != nil }) ?? true {
                place.episodes.append(Episode(start: stuck.since, node: stuck.node.id, better: stuck.better.id))
            }
        } else if let last = place.episodes.indices.last, place.episodes[last].end == nil {
            place.episodes[last].end = reading.date
        }
        place.episodes = Array(place.episodes.filter { reading.date.timeIntervalSince($0.end ?? reading.date) < 30 * 86_400 }.suffix(100))
        let repeats = place.episodes.filter { reading.date.timeIntervalSince($0.start) < 14 * 86_400 }.count
        let state: NodeReport.State
        switch detector.state {
        case _ where reading.current == nil: state = .notJoined
        case .stuck: state = .stuck
        case .settling: state = .settling
        case .watching: state = .watching
        case .fine, .notJoined: state = nodes.count < 2 ? .singleNode : .fine
        }
        let report = NodeReport(date: reading.date, ssid: reading.ssid, network: network, state: state, nodes: nodes, stuck: stuck, repeats: repeats)
        self.report = report
        // One notification an episode, five minutes in, and at most one every six hours per network.
        if let stuck, reading.date.timeIntervalSince(stuck.since) >= Self.notifyAfter, let last = place.episodes.indices.last, !place.episodes[last].notified,
           place.notified.map({ reading.date.timeIntervalSince($0) >= Self.notifyEvery }) ?? true {
            place.episodes[last].notified = true; place.notified = reading.date
            places[network] = place; save()
            onStuck?(report)
            return
        }
        if places[network] != place { places[network] = place; save() }
    }

    /// Names a node on the current network, found by its id, any of its BSSIDs or its current name; an empty or
    /// nil name clears it. Returns the node as now named, or nil when no such node is in the latest reading.
    @discardableResult
    public func name(_ reference: String, as name: String?) -> MeshNode? {
        guard let report, let network = report.network, let node = Self.find(reference, in: report.nodes) else { return nil }
        var place = places[network] ?? NodePlace()
        let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40).description
        for radio in node.radios { place.names[radio.bssid] = clean?.isEmpty == false ? clean : nil }
        // Other BSSIDs that carried the old name belong to the same box.
        if let old = node.name { for (bssid, value) in place.names where value == old && MeshNodes.sameBox(bssid, node.id) { place.names[bssid] = clean?.isEmpty == false ? clean : nil } }
        places[network] = place; save()
        let renamed = report.nodes.map { candidate -> MeshNode in
            var candidate = candidate
            if candidate.id == node.id { candidate.name = clean?.isEmpty == false ? clean : nil }
            return candidate
        }
        let stuck = report.stuck.map { stuck in
            StuckNode(since: stuck.since, node: renamed.first { $0.id == stuck.node.id } ?? stuck.node, better: renamed.first { $0.id == stuck.better.id } ?? stuck.better,
                      rssi: stuck.rssi, betterRSSI: stuck.betterRSSI, betterBand: stuck.betterBand, currentMbps: stuck.currentMbps, betterMbps: stuck.betterMbps)
        }
        self.report = NodeReport(date: report.date, ssid: report.ssid, network: network, state: report.state, nodes: renamed, stuck: stuck, repeats: report.repeats)
        return renamed.first { $0.id == node.id }
    }
    /// A node by its id, any of its BSSIDs, its name (any case) or `current`.
    public static func find(_ reference: String, in nodes: [MeshNode]) -> MeshNode? {
        let wanted = reference.trimmingCharacters(in: .whitespaces)
        if wanted.lowercased() == "current" { return nodes.first(where: \.current) }
        if let bssid = MeshNodes.normalize(wanted) { return nodes.first { $0.radios.contains { $0.bssid == bssid } } }
        return nodes.first { $0.name?.localizedCaseInsensitiveCompare(wanted) == .orderedSame }
    }

    /// Moves the Mac to the better node: joins it directly, or turns Wi-Fi off and on. Without a stuck episode it
    /// aims at the strongest other node, so the CLI's reconnect also works on a hunch.
    public func reconnect() async -> Result<NodeReconnect, DiagnosticError> {
        guard !reconnecting else { return .failure(DiagnosticError(String(localized: "Already reconnecting.", comment: "Reconnecting to a closer mesh node"))) }
        guard let report, let ssid = report.ssid, let network = report.network else {
            return .failure(DiagnosticError(String(localized: "Kilobat doesn’t see a Wi-Fi network with more than one node yet.", comment: "Reconnecting to a closer mesh node")))
        }
        let target = report.stuck?.better ?? report.nodes.first { !$0.current }
        reconnecting = true
        defer { reconnecting = false }
        do {
            let move = try await WiFiConnection().moveToNode(Set(target?.radios.map(\.bssid) ?? []), ssid: ssid)
            detector.reset(); lastScan = .distantPast
            let reading = await probe.nodeReading(activeScan: false)
            let names = places[network]?.names ?? [:]
            let nodes = MeshNodes.nodes(reading.radios, current: move.bssid ?? reading.current?.bssid, names: names)
            let node = move.bssid.flatMap { bssid in nodes.first { $0.radios.contains { $0.bssid == bssid } } }
                ?? move.bssid.map { MeshNode(id: $0, name: names[$0], radios: [NodeRadio(bssid: $0, rssi: move.rssi ?? 0, channel: 0, band: "", widthMHz: 20)], current: true) }
            let better = node.map { node in target?.radios.contains { radio in node.radios.contains { $0.bssid == radio.bssid } } ?? false } ?? false
            let result = NodeReconnect(method: move.method, node: node, rssi: move.rssi, better: better)
            outcome = result
            self.report = NodeReport(date: Date(), ssid: ssid, network: network, state: .settling, nodes: nodes, stuck: nil, repeats: report.repeats)
            return .success(result)
        } catch {
            return .failure(error as? DiagnosticError ?? DiagnosticError(error.localizedDescription))
        }
    }

    #if DEBUG
    /// Made-up nodes for screenshots; debug builds only.
    public func preview(_ report: NodeReport?, outcome: NodeReconnect? = nil) { self.report = report; self.outcome = outcome }
    #endif

    private func save() {
        guard let file else { return }
        try? JSONEncoder().encode(places).write(to: file, options: .atomic)
    }
}
