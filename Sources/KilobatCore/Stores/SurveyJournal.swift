import Foundation
import Observation

public struct SavedSpot: Codable, Identifiable, Sendable {
    public var id = UUID()
    public let name: String
    public let date: Date
    public let radio: RadioSample
}
public struct SavedScan: Codable, Identifiable, Sendable {
    public var id = UUID()
    public let date: Date
    public let networks: [NearbyNetwork]
}
public struct SavedRoute: Codable, Identifiable, Sendable {
    public var id = UUID()
    public let date: Date
    public let host: String
    public let output: String
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
    public private(set) var error: String?
    private let directory: URL
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")
        devices = read("device-observations.json") ?? []
        spots = read("spots.json") ?? []; scans = read("scans.json") ?? []; routes = read("routes.json") ?? []
    }
    public func saveDevices(_ rows: [LANDevice], network: String) {
        devices.append(DeviceObservation(date: Date(), network: network, devices: rows)); devices = Array(devices.suffix(50)); write(devices, "device-observations.json")
    }
    public func saveSpot(name: String, radio: RadioSample) {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !clean.isEmpty, radio.rssi != nil else { return }
        spots.append(SavedSpot(name: clean, date: Date(), radio: radio)); spots = Array(spots.suffix(100)); write(spots, "spots.json")
    }
    public func removeSpot(_ id: UUID) { spots.removeAll { $0.id == id }; write(spots, "spots.json") }
    public func saveScan(_ networks: [NearbyNetwork]) { scans.append(SavedScan(date: Date(), networks: networks)); scans = Array(scans.suffix(30)); write(scans, "scans.json") }
    public func saveRoute(host: String, output: String) { routes.append(SavedRoute(date: Date(), host: host, output: output)); routes = Array(routes.suffix(200)); write(routes, "routes.json") }
    private func read<T: Decodable>(_ name: String) -> T? { guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }; return try? JSONDecoder().decode(T.self, from: data) }
    private func write<T: Encodable>(_ value: T, _ name: String) {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(name), options: .atomic); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
