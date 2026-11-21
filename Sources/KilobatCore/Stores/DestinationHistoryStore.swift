import Foundation
import Observation

/// Records destination history (see `DestinationHistory`) from the per-connection rows nettop already reports every
/// second, for the apps the person chose. Nothing is recorded while it's off or without Pro, and nothing leaves the Mac.
@MainActor @Observable public final class DestinationHistoryStore {
    public private(set) var records: [DestinationRecord] = []
    /// Which apps to keep; nil is off. The app reads it from preferences.
    @ObservationIgnored public var settings: () -> DestinationHistorySettings? = { nil }
    /// Whether it may record: the app records with Pro.
    @ObservationIgnored public var allowed: () -> Bool = { false }
    /// Names the Kilobat filter saw apps ask for, by address. Empty without the filter.
    @ObservationIgnored public var names: () -> [String: String] = { [:] }
    /// The app a process belongs to, as usage history names it.
    @ObservationIgnored public var resolve: (ProcessTraffic) -> DestinationApp? = { _ in nil }
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private var index: [String: Int] = [:]
    /// Each process's connections at the last sample, by pid and name, so only new bytes count.
    @ObservationIgnored private var previous: [String: (connections: [String: (UInt64, UInt64)], at: Date)] = [:]
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var lastPersist = Date.distantPast
    @ObservationIgnored private var lastPrune = Date.distantPast
    @ObservationIgnored private var previewing = false
    @ObservationIgnored public var calendar = Calendar.current

    /// `directory` nil keeps everything in memory, as the tests do.
    public init(directory: URL? = nil, now: Date = Date()) {
        file = directory?.appendingPathComponent(DestinationHistory.fileName)
        if let file, let saved = DestinationHistoryFile.load(file) { records = saved.records }
        if DestinationHistory.prune(&records, now: now, calendar: calendar) { dirty = true; persist(now: now, force: true) }
        lastPrune = now
    }

    public var recording: Bool { allowed() && settings()?.isOn == true }

    /// One nettop sample. A process seen for the first time only sets its baseline, as in usage history.
    public func consume(_ snapshot: TrafficSnapshot) {
        let now = snapshot.timestamp
        guard !previewing else { return }
        if now.timeIntervalSince(lastPrune) >= 3_600 {
            lastPrune = now
            if DestinationHistory.prune(&records, now: now, calendar: calendar) { index = [:]; dirty = true }
        }
        guard allowed(), let settings = settings(), settings.isOn else {
            previous = [:]
            persist(now: now)
            return
        }
        let names = names()
        var seen: [String: (connections: [String: (UInt64, UInt64)], at: Date)] = [:]
        var changed = false
        for process in snapshot.processes where !process.connections.isEmpty {
            let key = "\(process.pid)|\(process.process)"
            var connections: [String: (UInt64, UInt64)] = [:]
            for connection in process.connections where connection.route != .local {
                let old = connections[connection.id] ?? (0, 0)
                connections[connection.id] = (old.0 + connection.received, old.1 + connection.sent)
            }
            seen[key] = (connections, now)
            guard let before = previous[key], let app = resolve(process), settings.keeps(app) else { continue }
            for (id, bytes) in connections {
                let old = before.connections[id]
                let received = old.map { bytes.0 >= $0.0 ? bytes.0 - $0.0 : bytes.0 } ?? bytes.0
                let sent = old.map { bytes.1 >= $0.1 ? bytes.1 - $0.1 : bytes.1 } ?? bytes.1
                guard received + sent > 0, let endpoint = AgentNetworkLogStore.endpoint(id) else { continue }
                let host = names[endpoint.address].flatMap(HostName.normalize) ?? endpoint.address
                DestinationHistory.add(app: app.name, host: host, address: endpoint.address, received: received, sent: sent, at: now,
                                       to: &_records, index: &index, calendar: calendar)
                changed = true
            }
        }
        previous = previous.filter { now.timeIntervalSince($0.value.at) < 30 }.merging(seen) { $1 }
        if changed { dirty = true; withMutation(keyPath: \.records) {} }
        persist(now: now)
    }

    /// An app's sites over the last 30 days, most data first.
    public func totals(app: String, now: Date = Date()) -> [DestinationTotal] { DestinationHistory.totals(records, app: app, now: now, calendar: calendar) }

    /// Clears a period or forgets a site (see `HistoryEraser`), and saves at once. Returns how many rows went.
    @discardableResult public func erase(_ action: HistoryAction, now: Date = Date()) throws -> Int {
        let removed = HistoryEraser.apply(action, to: &records, now: now, calendar: calendar)
        index = [:]
        if removed > 0 || action == .clear(.all) { try save(now: now) }
        return removed
    }

    /// Removes everything kept for one app.
    @discardableResult public func forget(app: String, now: Date = Date()) throws -> Int {
        let removed = DestinationHistory.forget(app: app, in: &records)
        index = [:]
        if removed > 0 { try save(now: now) }
        return removed
    }

    private func save(now: Date) throws {
        dirty = false; lastPersist = now
        guard let file, !previewing else { return }
        // A save waiting on the writer would put the erased rows back.
        Self.writer.sync {}
        if records.isEmpty { try? FileManager.default.removeItem(at: file); return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DestinationHistoryFile(records: records).data().write(to: file, options: .atomic)
    }

    /// Every minute while something changed; encoding happens off the main thread, in order.
    public func persist(now: Date = Date(), force: Bool = false) {
        guard let file, dirty, !previewing, force || now.timeIntervalSince(lastPersist) >= 60 else { return }
        dirty = false; lastPersist = now
        let saved = DestinationHistoryFile(records: records)
        let write: @Sendable () -> Void = {
            if saved.records.isEmpty { try? FileManager.default.removeItem(at: file); return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? saved.data().write(to: file, options: [.atomic])
        }
        if force { Self.writer.sync(execute: write) } else { Self.writer.async(execute: write) }
    }
    public func shutdown() {
        persist(force: true)
        Self.writer.sync {}
    }

    private nonisolated static let writer = DispatchQueue(label: "co.seifi.kilobat.destination-history-write", qos: .utility)

    #if DEBUG
    /// Sample rows for the debug snapshot; nothing from this Mac is recorded or saved while they show.
    public func preview(_ records: [DestinationRecord]) {
        previewing = true
        self.records = records
    }
    #endif
}
