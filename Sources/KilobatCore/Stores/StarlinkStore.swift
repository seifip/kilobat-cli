import Foundation
import Observation

/// The dish's outage log kept on this Mac, since the dish itself forgets after a while. Written by the app, read by
/// the provider report and `kilobat starlink`.
public struct StarlinkJournal: Codable, Sendable {
    public var outages: [StarlinkOutage] = []
    /// When a dish last answered, and on which network, so the report adds its log only for that network.
    public var lastSeen: Date?
    public var network: String?
    public init() {}

    static func file(_ directory: URL?) -> URL {
        (directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")).appendingPathComponent("starlink.json")
    }
    public static func load(directory: URL? = nil) -> StarlinkJournal { StoredJSON.read(file(directory)) ?? StarlinkJournal() }
    func save(directory: URL?) {
        try? FileManager.default.createDirectory(at: Self.file(directory).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Self.file(directory), options: .atomic)
    }

    /// Adds outages not seen before (the same start within two seconds and the same cause), keeps 30 days.
    /// Returns whether anything changed.
    @discardableResult public mutating func merge(_ fresh: [StarlinkOutage], now: Date = Date()) -> Bool {
        let before = outages.count
        for outage in fresh where !outages.contains(where: { $0.cause == outage.cause && abs($0.start.timeIntervalSince(outage.start)) < 2 }) {
            outages.append(outage)
        }
        // A logged outage that was still running grows: keep the longest reading of it.
        for outage in fresh {
            if let index = outages.firstIndex(where: { $0.cause == outage.cause && abs($0.start.timeIntervalSince(outage.start)) < 2 }), outage.seconds > outages[index].seconds {
                outages[index].seconds = outage.seconds
            }
        }
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        outages = outages.filter { $0.start >= cutoff }.sorted { $0.start < $1.start }.suffix(2_000)
        return outages.count != before
    }

    /// The log for a report on `network` over `hours`; nil unless a dish answered on that network in that time.
    public func evidence(network: String?, status: StarlinkStatus? = nil, hours: Int, now: Date = Date()) -> StarlinkEvidence? {
        let since = now.addingTimeInterval(-Double(hours) * 3600)
        guard let lastSeen, lastSeen >= since, network != nil, self.network == network else { return nil }
        return StarlinkEvidence.make(outages: outages, status: status, since: since, now: now)
    }
}

/// Watches for a Starlink dish and, when one answers, keeps its status, recent history and sky map current.
/// It looks for a dish when the network changes and every few minutes otherwise, a single local request that fails
/// within a second and a half when there is none; nothing about it is shown until a dish answers.
@MainActor @Observable public final class StarlinkStore {
    public private(set) var status: StarlinkStatus?
    public private(set) var history: StarlinkHistory?
    public private(set) var map: StarlinkSkyMap?
    public private(set) var journal: StarlinkJournal
    /// A call or the Health tab wants a reading every couple of seconds.
    public var watching = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var lastProbe = Date.distantPast
    @ObservationIgnored private var lastHistory = Date.distantPast
    @ObservationIgnored private var lastMap = Date.distantPast
    @ObservationIgnored private var lastNetwork: String?
    @ObservationIgnored private var lastSaved = Date.distantPast
    private let directory: URL?

    public init(directory: URL? = nil) {
        self.directory = directory
        journal = StarlinkJournal.load(directory: directory)
    }

    /// A dish answered in the last two minutes.
    public var present: Bool { status.map { Date().timeIntervalSince($0.date) < 120 } ?? false }

    #if DEBUG
    /// Made-up readings for screenshots; debug builds only.
    public func preview(status: StarlinkStatus?, history: StarlinkHistory?, map: StarlinkSkyMap?, outages: [StarlinkOutage]) {
        self.status = status; self.history = history; self.map = map; journal.outages = outages; journal.lastSeen = Date()
    }
    #endif

    /// `visible` says whether Health is on screen; `network` names the current network.
    public func start(visible: @escaping @MainActor () -> Bool, network: @escaping @MainActor () -> String?) {
        guard task == nil, ProcessInfo.processInfo.environment["KILOBAT_SNAPSHOT"] == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let fast = visible() || self.watching
                await self.tick(fast: fast, network: network())
                let delay: Double = self.status == nil ? 5 : fast ? 2 : 30
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }
    public func stop() { task?.cancel(); task = nil }

    private func tick(fast: Bool, network: String?) async {
        let now = Date()
        if status == nil {
            // Without a dish: look again on a new network, otherwise every five minutes.
            guard network != lastNetwork || now.timeIntervalSince(lastProbe) >= 300 else { return }
            lastProbe = now; lastNetwork = network
        }
        guard let fresh = await Starlink.status(timeout: status == nil ? 1.5 : 3) else {
            failures += 1
            if failures >= 3 || status == nil { status = nil; history = nil; map = nil }
            return
        }
        failures = 0; status = fresh; lastNetwork = network
        journal.lastSeen = now; journal.network = network
        if let outage = fresh.outage { journal.merge([outage]) }
        if now.timeIntervalSince(lastHistory) >= (fast ? 10 : 300), let history = await Starlink.history() {
            lastHistory = now; self.history = history
            journal.merge(history.outages)
        }
        if now.timeIntervalSince(lastMap) >= (fast ? 120 : 1800), let map = await Starlink.obstructionMap() { lastMap = now; self.map = map }
        if now.timeIntervalSince(lastSaved) >= 60 { lastSaved = now; journal.save(directory: directory) }
    }

    /// Outages from the dish's log in the last `hours`, newest first.
    public func outages(hours: Double, now: Date = Date()) -> [StarlinkOutage] {
        journal.outages.filter { $0.end >= now.addingTimeInterval(-hours * 3600) }.reversed()
    }
}
