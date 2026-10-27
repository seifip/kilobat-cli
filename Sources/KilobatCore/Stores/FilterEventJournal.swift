import Foundation
import Observation

@MainActor @Observable public final class FilterEventJournal {
    public private(set) var events: [FilterEvent] = []
    public private(set) var error: String?
    private var connection: NSXPCConnection?
    private var requestID: UUID?
    private let file: URL
    public static var fileURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat/filter-events.json") }
    public init(file: URL? = nil) {
        self.file = file ?? Self.fileURL
        events = (try? JSONDecoder().decode([FilterEvent].self, from: Data(contentsOf: self.file))) ?? []
    }
    public func ingest(_ observed: [FilterEvent], now: Date = Date()) throws {
        var merged = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for event in observed { merged[event.id] = event }
        let next = Array(merged.values.filter { now.timeIntervalSince($0.date) < 7 * 86400 }.sorted { $0.date > $1.date }.prefix(1000))
        let data = try JSONEncoder().encode(next)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Create private metadata before writing; atomic replacement inherits private mode.
        let temporary = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        if FileManager.default.fileExists(atPath: file.path) { _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: file) }
        events = next
    }
    public func refresh() {
        guard connection == nil, let team = FilterSigning.team() else { return }
        let id = UUID(); requestID = id
        let client = NSXPCConnection(machServiceName: team + ".co.seifi.kilobat.filter", options: .privileged)
        client.remoteObjectInterface = NSXPCInterface(with: FilterEventService.self)
        client.setCodeSigningRequirement(FilterSigning.requirement(team: team, bundle: "co.seifi.kilobat.filter"))
        connection = client; client.resume()
        let proxy = client.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in self?.finish(id, error: error.localizedDescription) }
        } as? FilterEventService
        proxy?.recentEvents { [weak self] data in
            Task { @MainActor in
                guard let self, self.requestID == id else { return }
                do {
                    guard data.count <= 2_000_000 else { throw CocoaError(.coderReadCorrupt) }
                    try self.ingest(JSONDecoder().decode([FilterEvent].self, from: data))
                    self.finish(id, error: nil)
                } catch { self.finish(id, error: error.localizedDescription) }
            }
        }
        Task { [weak self] in try? await Task.sleep(for: .seconds(4)); self?.finish(id, error: "Filter event connection timed out.") }
    }
    private func finish(_ id: UUID, error: String?) {
        guard requestID == id else { return }
        self.error = error; requestID = nil; connection?.invalidate(); connection = nil
    }
}
