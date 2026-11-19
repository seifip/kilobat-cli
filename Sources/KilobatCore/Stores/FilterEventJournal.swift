import Foundation
import Observation

/// Daily counts from the retained Protection events, in the Mac's current calendar.
public struct ProtectionActivity {
    public enum Group: CaseIterable, Hashable, Sendable {
        case threats, trackers, agentGuard

        fileprivate init(_ kind: ProtectionDetail.Kind) {
            switch kind {
            case .malware, .phishing, .scam, .threat: self = .threats
            case .tracker: self = .trackers
            case .agentGuard: self = .agentGuard
            }
        }
    }

    public struct Day: Identifiable, Sendable {
        public let date: Date
        public let counts: [Group: Int]
        public var id: Date { date }
        public var total: Int { counts.values.reduce(0, +) }
    }

    public let days: [Day]
    public var total: Int { days.reduce(0) { $0 + $1.total } }
    public func count(_ group: Group) -> Int { days.reduce(0) { $0 + ($1.counts[group] ?? 0) } }

    public init(events: [FilterEvent], interval: DateInterval? = nil, now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let starts = (-6...0).compactMap {
            calendar.date(byAdding: .day, value: $0, to: today).map { calendar.startOfDay(for: $0) }
        }
        let start = starts.first ?? today
        var counts: [Date: [Group: Int]] = [:]
        for event in events {
            guard let kind = event.protection?.kind, event.date >= start, event.date <= now,
                  interval.map({ event.date >= $0.start && event.date < $0.end }) ?? true else { continue }
            counts[calendar.startOfDay(for: event.date), default: [:]][Group(kind), default: 0] += 1
        }
        days = starts.compactMap { date in
            if let interval, let day = calendar.dateInterval(of: .day, for: date),
               day.end <= interval.start || day.start >= interval.end { return nil }
            return Day(date: date, counts: counts[date] ?? [:])
        }
    }
}

@MainActor @Observable public final class FilterEventJournal {
    public private(set) var events: [FilterEvent] = []
    public private(set) var error: String?
    private var connection: NSXPCConnection?
    private var requestID: UUID?
    private let file: URL
    public static var fileURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat/filter-events.json") }
    /// Events cleared or forgotten: the filter keeps its latest 1,000 in memory and sends them again on every read.
    private var removed: [UUID] = []
    private var removedSet: Set<UUID> = []
    private var loadFailure: (any Error)?
    private var removedFile: URL { file.deletingLastPathComponent().appendingPathComponent("filter-events-removed.json") }
    /// `recover` is for the app, which owns these files: an unreadable one is moved aside as `.corrupt` and the journal
    /// starts empty, so blocks keep being recorded and erasing keeps working. Readers that don't own the files (the
    /// command line) leave them where they are and refuse to write.
    public init(file: URL? = nil, recover: Bool = false) {
        self.file = file ?? Self.fileURL
        func fail(_ error: any Error, _ url: URL) {
            if recover {
                let aside = url.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: url, to: aside)
            } else {
                loadFailure = loadFailure ?? error
                self.error = self.error ?? error.localizedDescription
            }
        }
        if FileManager.default.fileExists(atPath: self.file.path) {
            do { events = try JSONDecoder().decode([FilterEvent].self, from: Data(contentsOf: self.file)) } catch { fail(error, self.file) }
        }
        if FileManager.default.fileExists(atPath: removedFile.path) {
            do { removed = try JSONDecoder().decode([UUID].self, from: Data(contentsOf: removedFile)) } catch { fail(error, removedFile) }
        }
        removedSet = Set(removed)
    }
    public func ingest(_ observed: [FilterEvent], now: Date = Date()) throws {
        if let loadFailure { throw loadFailure }
        var merged = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for event in observed where !removedSet.contains(event.id) { merged[event.id] = event }
        let next = Array(merged.values.filter { now.timeIntervalSince($0.date) < 7 * 86400 }.sorted { $0.date > $1.date }.prefix(1000))
        // Asked every five seconds; the file is only rewritten when something changed.
        guard Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }) != Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }) else { return }
        try save(next)
    }
    /// Clears a period or forgets a site, and keeps the filter from handing those events back.
    @discardableResult public func erase(_ action: HistoryAction, now: Date = Date()) throws -> Int {
        if let loadFailure { throw loadFailure }
        var next = events
        let gone = HistoryEraser.apply(action, to: &next, now: now)
        guard !gone.isEmpty else { return 0 }
        // The filter holds at most 1,000; twice that covers what it can still send.
        removed = Array((removed + gone.filter { !removedSet.contains($0) }).suffix(2_000))
        removedSet = Set(removed)
        try write(JSONEncoder().encode(removed), to: removedFile)
        try save(next)
        return gone.count
    }
    private func save(_ next: [FilterEvent]) throws {
        try write(JSONEncoder().encode(next), to: file)
        events = next
    }
    private func write(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep the new private mode even when replacing a file from an older build.
        let temporary = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        if FileManager.default.fileExists(atPath: file.path) { _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary, options: .usingNewMetadataOnly) }
        else { try FileManager.default.moveItem(at: temporary, to: file) }
    }
    public func refresh() {
        guard connection == nil, let team = FilterSigning.team() else { return }
        let id = UUID(); requestID = id
        let client = NSXPCConnection(machServiceName: team + ".co.seifi.kilobat.filter", options: .privileged)
        client.remoteObjectInterface = NSXPCInterface(with: FilterEventService.self)
        client.setCodeSigningRequirement(FilterSigning.requirement(team: team, bundle: "co.seifi.kilobat.filter"))
        connection = client; client.resume()
        let proxy = client.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
            Task { @MainActor in self?.finish(id, error: error.localizedDescription) }
        } as? FilterEventService
        proxy?.recentEvents { @Sendable [weak self] data in
            Task { @MainActor in
                guard let self, self.requestID == id else { return }
                do {
                    guard data.count <= 2_000_000 else { throw CocoaError(.coderReadCorrupt) }
                    try self.ingest(JSONDecoder().decode([FilterEvent].self, from: data))
                    self.finish(id, error: nil)
                } catch { self.finish(id, error: error.localizedDescription) }
            }
        }
        Task { [weak self] in try? await Task.sleep(for: .seconds(4)); self?.finish(id, error: String(localized: "Filter event connection timed out.")) }
    }
    private func finish(_ id: UUID, error: String?) {
        guard requestID == id else { return }
        self.error = error; requestID = nil; connection?.invalidate(); connection = nil
    }
}
