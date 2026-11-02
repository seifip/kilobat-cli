import Foundation
import Observation

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
    public init(file: URL? = nil) {
        self.file = file ?? Self.fileURL
        do {
            if FileManager.default.fileExists(atPath: self.file.path) {
                events = try JSONDecoder().decode([FilterEvent].self, from: Data(contentsOf: self.file))
            }
            if FileManager.default.fileExists(atPath: removedFile.path) {
                removed = try JSONDecoder().decode([UUID].self, from: Data(contentsOf: removedFile))
            }
        } catch { loadFailure = error; self.error = error.localizedDescription }
        removedSet = Set(removed)
    }
    public func ingest(_ observed: [FilterEvent], now: Date = Date()) throws {
        if let loadFailure { throw loadFailure }
        var merged = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for event in observed where !removedSet.contains(event.id) { merged[event.id] = event }
        try save(Array(merged.values.filter { now.timeIntervalSince($0.date) < 7 * 86400 }.sorted { $0.date > $1.date }.prefix(1000)))
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
