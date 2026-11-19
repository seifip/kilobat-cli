import Foundation
import Observation

/// Alert mode's quiet list: apps without a rule that connected, to turn into rules when convenient. Nothing notifies;
/// the list waits in Connections › Rules. Kept on this Mac for 30 days, at most 200 apps, a browser's destinations never.
@MainActor @Observable public final class NewAppReview {
    public private(set) var items: [NewAppSighting] = []
    @ObservationIgnored private var dismissed: [String: Date] = [:]
    @ObservationIgnored private let file: URL
    public static let keepDays = 30
    public static let capacity = 200

    private struct Saved: Codable { var items: [NewAppSighting]; var dismissed: [String: Date] }

    public nonisolated static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat/new-apps.json")
    }

    public init(file: URL? = nil) {
        self.file = file ?? Self.fileURL
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: self.file), let saved = try? decoder.decode(Saved.self, from: data) {
            items = saved.items; dismissed = saved.dismissed
        }
    }

    /// What the filter reported, folded in: an app keeps its first sighting, gains later ones and new destinations
    /// (up to five), and one already reviewed stays off the list.
    public func merge(_ observed: [NewAppSighting], now: Date = Date()) {
        var byApp = Dictionary(items.map { ($0.app, $0) }, uniquingKeysWith: { first, _ in first })
        for sighting in observed where dismissed[sighting.app] == nil {
            guard var known = byApp[sighting.app] else { byApp[sighting.app] = Self.trimmed(sighting); continue }
            known.first = min(known.first, sighting.first); known.last = max(known.last, sighting.last)
            known.connections = max(known.connections, sighting.connections)
            for destination in sighting.destinations where !known.destinations.contains(destination) && known.destinations.count < NewAppSighting.maximumDestinations {
                known.destinations.append(destination)
            }
            byApp[sighting.app] = known
        }
        let cutoff = now.addingTimeInterval(-Double(Self.keepDays) * 86_400)
        let next = Array(byApp.values.filter { $0.last >= cutoff }.sorted { $0.first > $1.first }.prefix(Self.capacity))
        guard next != items else { return }
        items = next
        save()
    }

    private static func trimmed(_ sighting: NewAppSighting) -> NewAppSighting {
        var sighting = sighting
        sighting.destinations = BrowserApps.contains(sighting.app) ? [] : Array(sighting.destinations.prefix(NewAppSighting.maximumDestinations))
        return sighting
    }

    /// Reviewed: off the list, and not listed again.
    public func dismiss(_ app: String, now: Date = Date()) {
        items.removeAll { $0.app == app }
        dismissed[app] = now
        if dismissed.count > 500, let oldest = dismissed.min(by: { $0.value < $1.value })?.key { dismissed[oldest] = nil }
        save()
    }

    /// Empties the list; apps that connect again are listed again.
    public func clear() {
        items = []; dismissed = [:]
        save()
    }

    /// The apps still to review in this profile: those that have no rule of their own yet.
    public func pending(_ preferences: SavedPreferences) -> [NewAppSighting] {
        let rules = preferences.rules[preferences.profile.rawValue] ?? [:]
        return items.filter { item in ProcessRuleKey.keys(item.app).allSatisfy { rules[$0] == nil } }
    }

    private func save() {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Saved(items: items, dismissed: dismissed)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic])
    }

    #if DEBUG
    /// Made-up apps for screenshots; nothing is saved.
    public func preview(_ sightings: [NewAppSighting]) { items = sightings }
    #endif
}
