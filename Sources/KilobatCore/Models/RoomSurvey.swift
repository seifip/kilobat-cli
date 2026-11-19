import Foundation

/// One access point a scan saw, for a room's fingerprint.
public struct SeenRadio: Codable, Sendable, Equatable {
    public let bssid: String
    public let ssid: String
    public let rssi: Int
    public init(bssid: String, ssid: String, rssi: Int) {
        self.bssid = MeshNodes.normalize(bssid) ?? bssid.lowercased(); self.ssid = ssid; self.rssi = rssi
    }
    /// The scan's networks that carry a BSSID; macOS hides it without Location access.
    public static func from(_ networks: [NearbyNetwork]) -> [SeenRadio] {
        networks.compactMap { network in MeshNodes.normalize(network.id).map { SeenRadio(bssid: $0, ssid: network.ssid, rssi: network.rssi) } }
    }
}

/// Rooms from Radar's saved spots: the signal and access point in each, which room this Mac is probably in now, and
/// advice only where the readings support it. A Mac sees signal strength, not direction or distance, so nothing here
/// says how far or which way to move anything.
public enum RoomSurvey {
    /// At or below this the room is weak: calls and video start to suffer.
    public static let weak = -72
    /// At or above this the room is good.
    public static let good = -65
    /// Another access point of the same network this much stronger than the joined one means the Mac stayed on a far one.
    public static let closerBy = 10

    public enum Grade: Sendable { case good, fair, weak }
    /// "−76 dBm" with a true minus and a space that never breaks, for prose.
    public static func dBm(_ value: Int) -> String { (value < 0 ? "\u{2212}\(-value)" : "\(value)") + "\u{00A0}dBm" }
    public static func grade(_ rssi: Int) -> Grade { rssi >= good ? .good : rssi > weak ? .fair : .weak }

    public static func key(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// The names offered before any are saved.
    public static var presets: [String] {
        [String(localized: "Living room", comment: "Room name"), String(localized: "Bedroom", comment: "Room name"), String(localized: "Kitchen", comment: "Room name"),
         String(localized: "Office", comment: "Room name"), String(localized: "Hallway", comment: "Room name"), String(localized: "Bathroom", comment: "Room name")]
    }

    public struct Room: Identifiable, Sendable {
        public var id: String { key(name) }
        public let name: String
        /// The latest reading.
        public let latest: SavedSpot
        public let readings: Int
        public var rssi: Int { latest.radio.rssi ?? -100 }
        public var grade: Grade { RoomSurvey.grade(rssi) }
        /// A radio of the same network, on another node, at least `closerBy` stronger than the joined one in this room.
        public let closer: SeenRadio?
    }

    /// One room per name, in the order first saved, each from its latest reading.
    public static func rooms(_ spots: [SavedSpot]) -> [Room] {
        var order: [String] = [], groups: [String: [SavedSpot]] = [:]
        for spot in spots.sorted(by: { $0.date < $1.date }) {
            let id = key(spot.name)
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(spot)
        }
        return order.compactMap { id in
            guard let readings = groups[id], let latest = readings.last else { return nil }
            return Room(name: latest.name, latest: latest, readings: readings.count, closer: closer(latest))
        }
    }

    static func closer(_ spot: SavedSpot) -> SeenRadio? {
        guard let joined = spot.radio.bssid.flatMap(MeshNodes.normalize), let rssi = spot.radio.rssi, let ssid = spot.radio.ssid else { return nil }
        return (spot.nearby ?? [])
            .filter { $0.ssid == ssid && $0.bssid != joined && !MeshNodes.sameBox($0.bssid, joined) && $0.rssi >= rssi + closerBy }
            .max { $0.rssi < $1.rssi }
    }

    /// The room this Mac is probably in, from the nearest saved fingerprint; nil when no room is clearly closest.
    /// Neighbouring rooms often look alike, so it is only ever offered for the person to confirm.
    public static func suggest(nearby: [SeenRadio], spots: [SavedSpot]) -> String? {
        guard nearby.count >= 3 else { return nil }
        var best: [String: (name: String, distance: Double)] = [:]
        for spot in spots {
            guard let saved = spot.nearby, saved.count >= 3 else { continue }
            let d = distance(nearby, saved), id = key(spot.name)
            if d < best[id]?.distance ?? .infinity { best[id] = (spot.name, d) }
        }
        let ranked = best.values.sorted { $0.distance < $1.distance }
        guard let first = ranked.first, first.distance <= 8 else { return nil }
        if ranked.count > 1, ranked[1].distance - first.distance < 3 { return nil }
        return first.name
    }

    /// Mean signal difference over every access point either scan saw; one that's missing counts as −95 dBm.
    static func distance(_ a: [SeenRadio], _ b: [SeenRadio]) -> Double {
        func table(_ radios: [SeenRadio]) -> [String: Int] { Dictionary(radios.map { ($0.bssid, max($0.rssi, -95)) }, uniquingKeysWith: max) }
        let x = table(a), y = table(b), ids = Set(x.keys).union(y.keys)
        guard !ids.isEmpty else { return .infinity }
        return Double(ids.reduce(0) { $0 + abs((x[$1] ?? -95) - (y[$1] ?? -95)) }) / Double(ids.count)
    }

    /// Which node a BSSID belongs to, named by the person or else by the room where it's strongest: "Hallway access point".
    public static func nodeName(_ bssid: String?, rooms: [Room], names: [String: String] = [:]) -> String? {
        guard let bssid = bssid.flatMap(MeshNodes.normalize) else { return nil }
        if let name = names.first(where: { MeshNodes.normalize($0.key) == bssid || MeshNodes.sameBox($0.key, bssid) })?.value { return name }
        var strongest: (room: String, rssi: Int)?
        for room in rooms {
            let radios = (room.latest.nearby ?? []) + [room.latest.radio.bssid.map { SeenRadio(bssid: $0, ssid: room.latest.radio.ssid ?? "", rssi: room.rssi) }].compactMap { $0 }
            for radio in radios where radio.bssid == bssid || MeshNodes.sameBox(radio.bssid, bssid) {
                if radio.rssi > strongest?.rssi ?? -999 { strongest = (room.name, radio.rssi) }
            }
        }
        return strongest.map { String(localized: "\($0.room) access point", comment: "An access point named by the room where its signal is strongest, e.g. Hallway access point") }
    }

    /// Distinct access points (nodes) of the room's network that any reading was joined to or saw.
    static func nodeCount(_ rooms: [Room]) -> Int {
        var boxes: [String] = []
        for room in rooms {
            guard let ssid = room.latest.radio.ssid else { continue }
            let radios = (room.latest.nearby ?? []).filter { $0.ssid == ssid }.map(\.bssid) + [room.latest.radio.bssid.flatMap(MeshNodes.normalize)].compactMap { $0 }
            for bssid in radios where !boxes.contains(where: { $0 == bssid || MeshNodes.sameBox($0, bssid) }) { boxes.append(bssid) }
        }
        return boxes.count
    }

    /// What to do, only where the readings show it: a room where the Mac stayed on a far node, a room beyond reach, or
    /// that every room is fine.
    public static func advice(_ rooms: [Room]) -> [String] {
        var lines: [String] = []
        for room in rooms where room.grade == .weak {
            if let closer = room.closer {
                lines.append(String(localized: "\(room.name): this Mac stayed on a farther access point (\(dBm(room.rssi))) while another was at \(dBm(closer.rssi)). Turning Wi-Fi off and on there usually moves it.", comment: "Room survey advice: the Mac clung to a far node in a room"))
            } else if nodeCount(rooms) >= 2 {
                lines.append(String(localized: "\(room.name): at the edge of your Wi-Fi (\(dBm(room.rssi))). A node closer to it, or between it and the nearest one, would help.", comment: "Room survey advice: a weak room with a mesh"))
            } else {
                lines.append(String(localized: "\(room.name): far from your router (\(dBm(room.rssi))). Moving the router toward it, or adding a mesh node, would help.", comment: "Room survey advice: a weak room with one router"))
            }
        }
        if lines.isEmpty, rooms.count >= 2, rooms.allSatisfy({ $0.grade == .good }) {
            lines.append(String(localized: "Every room you saved has good signal.", comment: "Room survey: nothing to fix"))
        }
        return lines
    }
}
