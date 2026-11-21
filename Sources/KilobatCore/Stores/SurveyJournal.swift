import Foundation
import Observation

public struct SavedSpot: Codable, Identifiable, Sendable {
    public var id = UUID()
    public let name: String
    public let date: Date
    public let radio: RadioSample
    /// Every access point the scan saw here, by BSSID: the room's fingerprint. Nil for spots saved before rooms, or
    /// without Location access, when macOS hides BSSIDs.
    public var nearby: [SeenRadio]? = nil
    public init(name: String, date: Date, radio: RadioSample, nearby: [SeenRadio]? = nil) {
        self.name = name; self.date = date; self.radio = radio; self.nearby = nearby
    }
}
public struct SavedScan: Codable, Identifiable, Sendable {
    public var id = UUID()
    public let date: Date
    public let networks: [NearbyNetwork]
    /// What the person wrote about it, such as "Kitchen, microwave on".
    public var note: String? = nil
    public init(id: UUID = UUID(), date: Date, networks: [NearbyNetwork], note: String? = nil) { self.id = id; self.date = date; self.networks = networks; self.note = note }
}
public struct SavedRoute: Codable, Identifiable, Sendable {
    public var id = UUID()
    public let date: Date
    public let host: String
    public let output: String
    public init(date: Date, host: String, output: String) { self.date = date; self.host = host; self.output = output }
}
public struct DeviceObservation: Codable, Identifiable, Sendable {
    public var id = UUID()
    public let date: Date
    public let network: String
    public let devices: [LANDevice]
}
/// Bounded, local observations. Saved scans are never presented as current radio data.
@MainActor @Observable public final class SurveyJournal {
    public private(set) var devices: [DeviceObservation] = []
    public private(set) var spots: [SavedSpot] = []
    public private(set) var scans: [SavedScan] = []
    public private(set) var routes: [SavedRoute] = []
    /// Watched routes, newest last. Kept apart from `routes` so one long watch can't push every saved trace out.
    public private(set) var watches: [WatchedRoute] = []
    public static let watchLimit = 20
    public private(set) var error: String?
    private let directory: URL
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")
        devices = read("device-observations.json") ?? []
        spots = read("spots.json") ?? []; scans = read("scans.json") ?? []; routes = read("routes.json") ?? []
        // A watch still marked running was cut off when the app or command last quit.
        watches = (read("route-watches.json") as [WatchedRoute]? ?? []).map { watch in
            guard watch.running else { return watch }
            var ended = watch; ended.end = .quit; ended.ended = watch.lastDate; return ended
        }
    }
    public func saveDevices(_ rows: [LANDevice], network: String) {
        devices.append(DeviceObservation(date: Date(), network: network, devices: rows)); devices = Array(devices.suffix(50)); write(devices, "device-observations.json")
    }
    public func saveSpot(name: String, radio: RadioSample, nearby: [SeenRadio]? = nil, date: Date = Date()) {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !clean.isEmpty, radio.rssi != nil else { return }
        spots.append(SavedSpot(name: clean, date: date, radio: radio, nearby: nearby)); spots = Array(spots.suffix(200)); write(spots, "spots.json")
    }
    public func removeSpot(_ id: UUID) { spots.removeAll { $0.id == id }; write(spots, "spots.json") }
    /// Forgets every reading saved under a room's name.
    public func removeRoom(_ name: String) { spots.removeAll { RoomSurvey.key($0.name) == RoomSurvey.key(name) }; write(spots, "spots.json") }
    #if DEBUG
    public func preview(_ spots: [SavedSpot]) { self.spots = spots }
    public func previewScans(_ scans: [SavedScan]) { self.scans = scans }
    #endif
    public func saveScan(_ networks: [NearbyNetwork]) { scans.append(SavedScan(date: Date(), networks: networks)); scans = Array(scans.suffix(30)); write(scans, "scans.json") }
    /// Sets or clears (empty) a saved scan's note; 500 characters at most.
    public func setNote(_ note: String, for id: UUID) {
        guard let index = scans.firstIndex(where: { $0.id == id }) else { return }
        let clean = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        scans[index].note = clean.isEmpty ? nil : clean
        write(scans, "scans.json")
    }
    public func saveRoute(host: String, output: String) { routes.append(SavedRoute(date: Date(), host: host, output: output)); routes = Array(routes.suffix(200)); write(routes, "routes.json") }
    /// Adds or replaces a watch by its id, keeping the newest 20.
    public func saveWatch(_ watch: WatchedRoute) {
        if let index = watches.firstIndex(where: { $0.id == watch.id }) { watches[index] = watch } else { watches.append(watch) }
        watches = Array(watches.sorted { $0.started < $1.started }.suffix(Self.watchLimit)); write(watches, "route-watches.json")
    }
    public func removeWatch(_ id: UUID) { watches.removeAll { $0.id == id }; write(watches, "route-watches.json") }
    /// Re-reads watches another process (the command line) saved, keeping this one's running watches as they are.
    public func reloadWatches() {
        let stored: [WatchedRoute] = read("route-watches.json") ?? []
        let running = watches.filter { $0.running }
        watches = (stored.filter { saved in !running.contains { $0.id == saved.id } } + running).sorted { $0.started < $1.started }
    }
    private func read<T: Decodable>(_ name: String) -> T? { guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }; return try? JSONDecoder().decode(T.self, from: data) }
    private func write<T: Encodable>(_ value: T, _ name: String) {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(name), options: .atomic); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

public struct WiFiScanComparison {
    public struct Change: Identifiable {
        public let id: String
        public let before: NearbyNetwork?
        public let after: NearbyNetwork?

        public var name: String {
            let ssid = after?.ssid ?? before?.ssid ?? ""
            return ssid.isEmpty ? String(localized: "Hidden network") : ssid
        }
    }

    public let changes: [Change]
    public let unidentified: Bool

    public init(before: SavedScan, after: SavedScan) {
        func indexed(_ scan: SavedScan) -> [String: NearbyNetwork] {
            Dictionary(scan.networks.filter { !$0.id.isEmpty && !$0.id.hasPrefix("hidden-") }.map { ($0.id.lowercased(), $0) },
                       uniquingKeysWith: { $0.rssi >= $1.rssi ? $0 : $1 })
        }
        let old = indexed(before), new = indexed(after)
        unidentified = (before.networks + after.networks).contains { $0.id.isEmpty || $0.id.hasPrefix("hidden-") }
        changes = Set(old.keys).union(new.keys).compactMap { id in
            let first = old[id], second = new[id]
            if let first, let second, first.rssi == second.rssi, first.channel == second.channel,
               first.band == second.band, first.widthMHz == second.widthMHz { return nil }
            return Change(id: id, before: first, after: second)
        }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
}
