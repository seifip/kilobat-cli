import Foundation

// The smart-home check: Thread networks and their border routers, Matter and HomeKit devices, and whether the
// network is ready for Matter. Everything here is read from Bonjour advertisements and this Mac's own network
// state; nothing is commissioned, paired or controlled. Pure, so it can be tested with made-up TXT records.

/// One DNS-SD service instance as the browse resolved it.
public struct BonjourInstance: Sendable, Equatable {
    /// `_meshcop._udp`, `_matter._tcp` and so on.
    public let type: String
    public let name: String
    /// The target host, such as `AABBCCDDEEFF.local.`.
    public var host: String?
    public var port: UInt16?
    public var txt: [String: Data]
    public var addresses: [String]
    public init(type: String, name: String, host: String? = nil, port: UInt16? = nil, txt: [String: Data] = [:], addresses: [String] = []) {
        self.type = type; self.name = name; self.host = host; self.port = port; self.txt = txt; self.addresses = addresses
    }
    public var hostKey: String? { host.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) } }
}

/// DNS-SD TXT records (RFC 6763 §6): length-prefixed `key=value` strings.
public enum TXTRecord {
    /// Keys are case-insensitive and lowercased here; the first of a repeated key wins; a key without `=` has empty data.
    public static func parse(_ data: Data) -> [String: Data] {
        let bytes = [UInt8](data)
        var entries: [String: Data] = [:], offset = 0
        while offset < bytes.count {
            let length = Int(bytes[offset]); offset += 1
            guard length > 0 else { continue }
            guard offset + length <= bytes.count else { break }
            let entry = bytes[offset..<offset + length]; offset += length
            let equals = entry.firstIndex(of: UInt8(ascii: "="))
            let keyBytes = equals.map { entry[entry.startIndex..<$0] } ?? entry
            guard !keyBytes.isEmpty, let key = String(bytes: keyBytes, encoding: .ascii)?.lowercased(), entries[key] == nil else { continue }
            entries[key] = equals.map { Data(entry[entry.index(after: $0)...]) } ?? Data()
        }
        return entries
    }

    /// The wire form, for tests and fixtures.
    public static func encode(_ entries: [(String, Data)]) -> Data {
        var data = Data()
        for (key, value) in entries {
            let entry = Data(key.utf8) + Data("=".utf8) + value
            guard entry.count <= 255 else { continue }
            data.append(UInt8(entry.count)); data.append(entry)
        }
        return data
    }

    static func text(_ data: Data?) -> String? {
        guard let data, !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return trimmed.isEmpty ? nil : trimmed
    }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

// MARK: Ecosystems

/// Who runs a Thread network or border router, from the border router's own vendor and model names.
public enum SmartHomeEcosystem: String, Codable, Sendable, CaseIterable {
    case apple, google, amazon, samsung, homeAssistant, other

    public var name: String {
        switch self {
        case .apple: "Apple"
        case .google: "Google"
        case .amazon: "Amazon"
        case .samsung: "SmartThings"
        case .homeAssistant: "Home Assistant"
        case .other: String(localized: "Other", comment: "Smart home: a Thread border router from a maker Kilobat doesn't group")
        }
    }

    /// From the `vn` (vendor) and `mn` (model) TXT keys, then the instance name.
    public static func identify(vendor: String?, model: String?, instance: String = "") -> SmartHomeEcosystem {
        let text = [vendor, model, instance].compactMap { $0?.lowercased() }.joined(separator: " ")
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        if has("apple", "homepod", "appletv", "apple tv", "audioaccessory") { return .apple }
        if has("google", "nest") { return .google }
        if has("amazon", "echo", "eero") { return .amazon }
        if has("samsung", "smartthings", "aeotec") { return .samsung }
        if has("home assistant", "homeassistant", "home-assistant") { return .homeAssistant }
        return .other
    }
}

// MARK: Thread

/// The border agent's state bitmap (`sb`), as OpenThread encodes it (`border_agent_txt_data.hpp`).
public struct MeshCoPState: Codable, Sendable, Equatable {
    public enum Interface: String, Codable, Sendable { case notInitialized, initialized, active }
    public enum Role: String, Codable, Sendable { case detached, child, router, leader }
    public let bitmap: UInt32
    /// Bits 0–2: 0 no commissioner connections, 1 PSKc, 2 PSKd, 3 vendor, 4 X.509.
    public var connectionMode: Int { Int(bitmap & 0x7) }
    /// Bits 3–4: whether the Thread interface is up and attached to a network.
    public var interface: Interface { [.notInitialized, .initialized, .active][min(2, Int((bitmap >> 3) & 0x3))] }
    /// Bits 5–6: 1 for a border router that is always on, 0 for one that is only sometimes available.
    public var highAvailability: Bool { (bitmap >> 5) & 0x3 == 1 }
    /// Bit 7 and 8: Thread 1.2 backbone border router, and whether it is the primary one.
    public var backboneActive: Bool { bitmap & (1 << 7) != 0 }
    public var backbonePrimary: Bool { bitmap & (1 << 8) != 0 }
    /// Bits 9–10.
    public var role: Role { [.detached, .child, .router, .leader][Int((bitmap >> 9) & 0x3)] }
    /// Bit 11: ephemeral PSKc, which Thread 1.4 credential sharing uses.
    public var credentialSharing: Bool { bitmap & (1 << 11) != 0 }
    public init(bitmap: UInt32) { self.bitmap = bitmap }
    public init?(_ data: Data?) {
        guard let data, data.count == 4 else { return nil }
        self.init(bitmap: data.reduce(0) { $0 << 8 | UInt32($1) })
    }

    enum CodingKeys: String, CodingKey { case bitmap, interface, role, credentialSharing, highAvailability }
    public init(from decoder: Decoder) throws { bitmap = try decoder.container(keyedBy: CodingKeys.self).decode(UInt32.self, forKey: .bitmap) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bitmap, forKey: .bitmap); try container.encode(interface, forKey: .interface); try container.encode(role, forKey: .role)
        try container.encode(credentialSharing, forKey: .credentialSharing); try container.encode(highAvailability, forKey: .highAvailability)
    }
}

/// A Thread border router, from its `_meshcop._udp` advertisement.
public struct ThreadBorderRouter: Codable, Sendable, Equatable, Identifiable {
    public var id: String { instance }
    /// The advertised instance name, which many border routers set to their own name.
    public let instance: String
    /// `vn`, such as "Apple Inc." or "Google Inc.".
    public let vendor: String?
    /// `mn`, such as "HomePod" or "Google Nest Hub".
    public let model: String?
    /// `nn`.
    public let networkName: String?
    /// `xp`, the network's extended PAN ID, as 16 hex digits.
    public let extendedPANID: String?
    /// `tv`, such as "1.3.0".
    public let threadVersion: String?
    public let state: MeshCoPState?
    public let ecosystem: SmartHomeEcosystem
    public let addresses: [String]

    public init(instance: String, vendor: String?, model: String?, networkName: String?, extendedPANID: String?, threadVersion: String?,
                state: MeshCoPState?, addresses: [String] = []) {
        self.instance = instance; self.vendor = vendor; self.model = model; self.networkName = networkName
        self.extendedPANID = extendedPANID; self.threadVersion = threadVersion; self.state = state
        self.ecosystem = SmartHomeEcosystem.identify(vendor: vendor, model: model, instance: instance); self.addresses = addresses
    }

    public static func parse(_ record: BonjourInstance) -> ThreadBorderRouter {
        let xp: String? = record.txt["xp"].flatMap { data in
            if data.count == 8 { return TXTRecord.hex(data) }
            // A few older border agents wrote it as text.
            if let text = TXTRecord.text(data)?.lowercased(), text.count == 16, text.allSatisfy(\.isHexDigit) { return text }
            return nil
        }
        return ThreadBorderRouter(instance: record.name, vendor: TXTRecord.text(record.txt["vn"]), model: TXTRecord.text(record.txt["mn"]),
                                  networkName: TXTRecord.text(record.txt["nn"]), extendedPANID: xp, threadVersion: TXTRecord.text(record.txt["tv"]),
                                  state: MeshCoPState(record.txt["sb"]), addresses: record.addresses)
    }

    /// On a Thread network now: the interface is active, or the bitmap is missing and it names a network.
    public var onNetwork: Bool { state.map { $0.interface == .active } ?? (networkName != nil || extendedPANID != nil) }
    /// "HomePod mini (Living Room)"-style, without repeating a name that already says it.
    public var label: String {
        guard let model, !model.isEmpty, !instance.isEmpty else { return instance.isEmpty ? (model ?? "") : instance }
        return instance.lowercased().contains(model.lowercased()) ? instance : "\(model) (\(instance))"
    }
    /// The maker to show: the ecosystem's name, else the advertised vendor.
    public var maker: String { ecosystem == .other ? (vendor ?? ecosystem.name) : ecosystem.name }
}

/// Border routers that share one extended PAN ID (or, without one, one network name) are one Thread network.
public struct ThreadNetwork: Codable, Sendable, Equatable, Identifiable {
    public var id: String { extendedPANID ?? name ?? "" }
    public let name: String?
    public let extendedPANID: String?
    public let borderRouters: [ThreadBorderRouter]
    /// The ecosystems or makers whose border routers are on it, most border routers first.
    public var makers: [String] {
        let counts = Dictionary(grouping: borderRouters, by: \.maker).mapValues(\.count)
        return counts.keys.sorted { counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : $0 < $1 }
    }
    public var credentialSharing: Bool { borderRouters.contains { $0.state?.credentialSharing == true } }

    public static func group(_ routers: [ThreadBorderRouter]) -> [ThreadNetwork] {
        let active = routers.filter(\.onNetwork)
        let groups = Dictionary(grouping: active) { $0.extendedPANID ?? "name:" + ($0.networkName ?? "") }
        return groups.values.map { members in
            let sorted = members.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            let name = Dictionary(grouping: sorted.compactMap(\.networkName), by: { $0 }).max { $0.value.count < $1.value.count }?.key
            return ThreadNetwork(name: name, extendedPANID: sorted.first?.extendedPANID, borderRouters: sorted)
        }.sorted { $0.borderRouters.count != $1.borderRouters.count ? $0.borderRouters.count > $1.borderRouters.count : ($0.name ?? "") < ($1.name ?? "") }
    }
}

// MARK: Matter

/// A Matter node waiting to be set up, or open to another app's pairing code (`_matterc._udp`).
public struct CommissionableMatterDevice: Codable, Sendable, Equatable {
    /// `DN`, when the device sends one.
    public let name: String?
    /// `DT`, as a Matter device type name such as "Dimmable light".
    public let deviceType: String?
    /// `VP`: vendor and product IDs.
    public let vendorID: Int?
    public let productID: Int?
    /// `CM` 1 or 2: its commissioning window is open now.
    public let pairingMode: Bool
    public var label: String { name ?? deviceType ?? String(localized: "Matter device", comment: "Smart home: a Matter device that doesn't send a name") }

    public static func parse(_ record: BonjourInstance) -> CommissionableMatterDevice {
        let vp = TXTRecord.text(record.txt["vp"])?.split(separator: "+").map { Int($0) }
        let type = TXTRecord.text(record.txt["dt"]).flatMap { Int($0) }.flatMap(MatterDeviceTypes.name)
        return CommissionableMatterDevice(name: TXTRecord.text(record.txt["dn"]), deviceType: type, vendorID: vp?.first ?? nil,
                                          productID: (vp?.count ?? 0) > 1 ? vp?[1] : nil, pairingMode: ["1", "2"].contains(TXTRecord.text(record.txt["cm"]) ?? ""))
    }
}

/// Common device types from the CSA's Matter Device Library, by ID.
public enum MatterDeviceTypes {
    static let names: [Int: String] = [
        0x000A: String(localized: "Door lock", comment: "Smart home: accessory category or Matter device type"), 0x000E: String(localized: "Bridge", comment: "Smart home: accessory category or Matter device type"), 0x000F: String(localized: "Switch", comment: "Smart home: accessory category or Matter device type"), 0x0015: String(localized: "Contact sensor", comment: "Smart home: accessory category or Matter device type"), 0x0022: String(localized: "Speaker", comment: "Smart home: accessory category or Matter device type"), 0x0023: String(localized: "TV streaming player", comment: "Smart home: accessory category or Matter device type"),
        0x0028: String(localized: "TV", comment: "Smart home: accessory category or Matter device type"), 0x002B: String(localized: "Fan", comment: "Smart home: accessory category or Matter device type"), 0x002D: String(localized: "Air purifier", comment: "Smart home: accessory category or Matter device type"), 0x0072: String(localized: "Air conditioner", comment: "Smart home: accessory category or Matter device type"), 0x0074: String(localized: "Robot vacuum", comment: "Smart home: accessory category or Matter device type"), 0x0076: String(localized: "Smoke and CO alarm", comment: "Smart home: accessory category or Matter device type"),
        0x0100: String(localized: "smart-home.light", defaultValue: "Light", comment: "A smart-home lamp or light accessory, not a lightweight speed test"), 0x0101: String(localized: "Dimmable light", comment: "Smart home: accessory category or Matter device type"), 0x010A: String(localized: "Plug", comment: "Smart home: accessory category or Matter device type"), 0x010B: String(localized: "Dimmable plug", comment: "Smart home: accessory category or Matter device type"), 0x010C: String(localized: "Tunable white light", comment: "Smart home: accessory category or Matter device type"), 0x010D: String(localized: "Colour light", comment: "Smart home: accessory category or Matter device type"),
        0x0103: String(localized: "Light switch", comment: "Smart home: accessory category or Matter device type"), 0x0104: String(localized: "Dimmer switch", comment: "Smart home: accessory category or Matter device type"), 0x0106: String(localized: "Light sensor", comment: "Smart home: accessory category or Matter device type"), 0x0107: String(localized: "Occupancy sensor", comment: "Smart home: accessory category or Matter device type"), 0x0202: String(localized: "Window covering", comment: "Smart home: accessory category or Matter device type"),
        0x0301: String(localized: "Thermostat", comment: "Smart home: accessory category or Matter device type"), 0x0302: String(localized: "Temperature sensor", comment: "Smart home: accessory category or Matter device type"), 0x0307: String(localized: "Humidity sensor", comment: "Smart home: accessory category or Matter device type"), 0x0850: String(localized: "Water leak sensor", comment: "Smart home: accessory category or Matter device type"),
    ]
    public static func name(_ id: Int) -> String? { names[id] }
}

/// What `_matter._tcp` and `_matterc._udp` say about the Matter devices here.
public struct MatterSummary: Codable, Sendable, Equatable {
    /// Distinct devices, by host: a device added to several apps advertises once for each.
    public let devices: Int
    /// Devices whose host name is a 64-bit Thread address (16 hex digits), and ones with a 48-bit Wi-Fi or Ethernet address.
    public let overThread: Int
    public let overWiFi: Int
    /// Distinct fabrics (each app or hub that a device was added to).
    public let fabrics: Int
    /// Operational advertisements, one per device per fabric.
    public let advertisements: Int
    public let commissionable: [CommissionableMatterDevice]
    /// Extended-discovery advertisements can remain after the commissioning window closes.
    public var readyToSetUp: [CommissionableMatterDevice] { commissionable.filter(\.pairingMode) }

    public static func build(operational: [BonjourInstance], commissionable: [BonjourInstance]) -> MatterSummary {
        var hosts: [String: BonjourInstance] = [:], fabrics: Set<String> = []
        for record in operational {
            let parts = record.name.split(separator: "-")
            if parts.count == 2, parts.allSatisfy({ $0.count == 16 && $0.allSatisfy(\.isHexDigit) }) { fabrics.insert(parts[0].uppercased()) }
            hosts[record.hostKey ?? record.name.lowercased()] = record
        }
        func link(_ host: String) -> Int? {
            let label = host.split(separator: ".").first.map(String.init) ?? host
            guard label.allSatisfy(\.isHexDigit) else { return nil }
            return label.count
        }
        let kinds = hosts.keys.compactMap(link)
        let waiting = Dictionary(grouping: commissionable) { $0.hostKey ?? $0.name.lowercased() }.values.compactMap(\.first).map(CommissionableMatterDevice.parse)
        return MatterSummary(devices: hosts.count, overThread: kinds.filter { $0 == 16 }.count, overWiFi: kinds.filter { $0 == 12 }.count,
                             fabrics: fabrics.count, advertisements: operational.count,
                             commissionable: waiting.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending })
    }
}

// MARK: HomeKit

/// HomeKit accessories from `_hap._tcp` (Wi-Fi and Ethernet) and `_hap._udp` (Thread), per Apple's HomeKit Accessory Protocol.
public struct HomeKitSummary: Codable, Sendable, Equatable {
    public let accessories: Int
    /// Category 2: a bridge that brings other accessories into HomeKit.
    public let bridges: Int
    /// Status flag bit 0: not paired with a home yet.
    public let unpaired: Int
    public let overThread: Int
    /// Category name to count.
    public let categories: [String: Int]

    static let categoryNames: [Int: String] = [
        1: String(localized: "Other", comment: "Smart home: accessory category or Matter device type"), 2: String(localized: "Bridge", comment: "Smart home: accessory category or Matter device type"), 3: String(localized: "Fan", comment: "Smart home: accessory category or Matter device type"), 4: String(localized: "Garage door opener", comment: "Smart home: accessory category or Matter device type"), 5: String(localized: "smart-home.light", defaultValue: "Light", comment: "A smart-home lamp or light accessory, not a lightweight speed test"), 6: String(localized: "Door lock", comment: "Smart home: accessory category or Matter device type"), 7: String(localized: "Outlet", comment: "Smart home: accessory category or Matter device type"), 8: String(localized: "Switch", comment: "Smart home: accessory category or Matter device type"), 9: String(localized: "Thermostat", comment: "Smart home: accessory category or Matter device type"),
        10: String(localized: "Sensor", comment: "Smart home: accessory category or Matter device type"), 11: String(localized: "Security system", comment: "Smart home: accessory category or Matter device type"), 12: String(localized: "Door", comment: "Smart home: accessory category or Matter device type"), 13: String(localized: "Window", comment: "Smart home: accessory category or Matter device type"), 14: String(localized: "Window covering", comment: "Smart home: accessory category or Matter device type"), 15: String(localized: "Programmable switch", comment: "Smart home: accessory category or Matter device type"), 16: String(localized: "Range extender", comment: "Smart home: accessory category or Matter device type"),
        17: String(localized: "Camera", comment: "Smart home: accessory category or Matter device type"), 18: String(localized: "Video doorbell", comment: "Smart home: accessory category or Matter device type"), 19: String(localized: "Air purifier", comment: "Smart home: accessory category or Matter device type"), 20: String(localized: "Heater", comment: "Smart home: accessory category or Matter device type"), 21: String(localized: "Air conditioner", comment: "Smart home: accessory category or Matter device type"), 22: String(localized: "Humidifier", comment: "Smart home: accessory category or Matter device type"), 23: String(localized: "Dehumidifier", comment: "Smart home: accessory category or Matter device type"),
        28: String(localized: "Sprinkler", comment: "Smart home: accessory category or Matter device type"), 29: String(localized: "Faucet", comment: "Smart home: accessory category or Matter device type"), 30: String(localized: "Shower", comment: "Smart home: accessory category or Matter device type"), 31: String(localized: "TV", comment: "Smart home: accessory category or Matter device type"), 32: String(localized: "Remote", comment: "Smart home: accessory category or Matter device type"),
    ]

    public static func build(_ records: [BonjourInstance]) -> HomeKitSummary {
        // The `id` key is the accessory's own identifier; one accessory can be seen on more than one interface.
        let unique = Dictionary(grouping: records) { TXTRecord.text($0.txt["id"])?.lowercased() ?? $0.type + "/" + $0.name.lowercased() }.values.compactMap(\.first)
        var categories: [String: Int] = [:], bridges = 0, unpaired = 0
        for record in unique {
            let category = TXTRecord.text(record.txt["ci"]).flatMap { Int($0) } ?? 1
            if category == 2 { bridges += 1 }
            if let flags = TXTRecord.text(record.txt["sf"]).flatMap({ Int($0) }), flags & 1 != 0 { unpaired += 1 }
            categories[categoryNames[category] ?? "Other", default: 0] += 1
        }
        return HomeKitSummary(accessories: unique.count, bridges: bridges, unpaired: unpaired, overThread: unique.filter { $0.type == SmartHomeServices.hapThread }.count, categories: categories)
    }
}

public enum SmartHomeServices {
    public static let meshcop = "_meshcop._udp", matter = "_matter._tcp", matterCommissionable = "_matterc._udp", hap = "_hap._tcp", hapThread = "_hap._udp"
    public static let all = [meshcop, matter, matterCommissionable, hap, hapThread]
    /// Common services that answer on most home networks, to tell multicast that works from a network with nothing on it.
    public static let peers = ["_airplay._tcp", "_googlecast._tcp", "_raop._tcp", "_ipp._tcp", "_companion-link._tcp", "_spotify-connect._tcp", "_sonos._tcp", "_smb._tcp"]
}

// MARK: The network

/// A non-link-local IPv6 prefix a router advertises on this Mac's interface (`ndp -p`).
public struct IPv6Prefix: Codable, Sendable, Equatable {
    public let prefix: String
    public let length: Int
    /// Link-local addresses of the routers advertising it.
    public let routers: [String]
    public var unique: Bool { IPv6Facts.kind(prefix) == .unique }
    public init(prefix: String, length: Int, routers: [String]) { self.prefix = prefix; self.length = length; self.routers = routers }
}

/// What this Mac sees of IPv6 on its network interface.
public struct IPv6Facts: Codable, Sendable, Equatable {
    public var linkLocal = false
    /// This Mac has a unique local (fc00::/7) or global (2000::/3) address on the interface.
    public var uniqueLocal = false
    public var global = false
    public var prefixes: [IPv6Prefix] = []
    /// Routers announcing themselves as a default route (`ndp -rn`).
    public var defaultRouters: [String] = []
    /// The IPv6 neighbour cache on the interface: link-local or other address to MAC address.
    public var neighbours: [String: String] = [:]
    public init() {}

    public enum Kind { case linkLocal, unique, global, other }
    public static func kind(_ address: String) -> Kind {
        let text = address.lowercased().split(separator: "%").first.map(String.init) ?? ""
        let first = UInt16(text.split(separator: ":", omittingEmptySubsequences: false).first ?? "", radix: 16) ?? 0
        if first & 0xffc0 == 0xfe80 { return .linkLocal }
        if first & 0xfe00 == 0xfc00 { return .unique }
        if first & 0xe000 == 0x2000 { return .global }
        return .other
    }

    /// `ndp -p`: "2001:db8::/64 if=en0", a flags line, then "advertised by" and indented router lines, or "No advertising router".
    public static func prefixes(_ output: String, interface: String) -> [IPv6Prefix] {
        var result: [IPv6Prefix] = [], current: (prefix: String, length: Int)?, routers: [String] = []
        func flush() { if let current, kind(current.prefix) != .linkLocal { result.append(IPv6Prefix(prefix: current.prefix, length: current.length, routers: routers)) }; current = nil; routers = [] }
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let words = line.split(separator: " ")
            if let first = words.first, first.contains("/"), first.contains(":") {
                flush()
                guard words.contains(where: { $0 == "if=\(interface)" }) else { continue }
                let pieces = first.split(separator: "/")
                if pieces.count == 2, let length = Int(pieces[1]) { current = (String(pieces[0].split(separator: "%").first ?? pieces[0]), length) }
            } else if current != nil, let first = words.first, first.contains(":"), !first.contains("="), kind(String(first)) == .linkLocal {
                routers.append(String(first.split(separator: "%").first ?? first).lowercased())
            }
        }
        flush()
        return result
    }

    /// `ndp -rn`: "fe80::1%en0 if=en0, flags=, pref=medium, expire=…".
    public static func defaultRouters(_ output: String, interface: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let words = line.split(separator: " ")
            guard let first = words.first, words.contains(where: { $0.hasPrefix("if=\(interface)") }) else { return nil }
            return String(first.split(separator: "%").first ?? first).lowercased()
        }
    }

    /// `ndp -an`: "fe80::1%en0  aa:bb:cc:dd:ee:ff  en0 …"; incomplete entries have no MAC address.
    public static func neighbours(_ output: String, interface: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let words = line.split(separator: " ")
            guard words.count >= 3, words[2] == interface, let mac = MACAddress.normalized(String(words[1])) else { continue }
            result[String(words[0].split(separator: "%").first ?? words[0]).lowercased()] = mac
        }
        return result
    }
}

/// What the checks read about this Mac's network, gathered by `SmartHomeProbe` (or made up in tests).
public struct SmartHomeFacts: Sendable {
    /// The interface of the default route, such as en0.
    public var interface: String?
    public var onWiFi = false
    /// This Mac's IPv4 address and netmask, host byte order.
    public var subnet: (address: UInt32, mask: UInt32)?
    public var gateway: String?
    public var gatewayMAC: String?
    public var routerVendor: String?
    public var ipv6 = IPv6Facts()
    /// Devices other than the router in the IPv4 neighbour cache on the interface.
    public var neighbours = 0
    /// Distinct other hosts that answered Bonjour for common services.
    public var bonjourPeers = 0
    public var localNetwork: LocalNetworkAccess = .unknown
    /// This Mac's own Bonjour host names, lowercased without the trailing dot.
    public var ownHosts: Set<String> = []
    public var ssid: String?
    public var band: String?
    /// Nearby networks from a Wi-Fi scan; nil when there was none.
    public var scan: [NearbyNetwork]?
    public init() {}
}

// MARK: The report

public enum SmartHomeState: String, Codable, Sendable { case ok, warning, problem, unknown }

/// One readiness check: IPv6, Bonjour, client isolation, the subnet and 2.4 GHz.
public struct SmartHomeCheck: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case ipv6, bonjour, isolation, subnet, wifi24 }
    public var id: Kind { kind }
    public let kind: Kind
    public let state: SmartHomeState
    public let summary: String
    public var fix: String? = nil
    /// The router's guide page, when Kilobat knows the router and the fix is made in its settings.
    public var guide: String? = nil
    public var title: String {
        switch kind {
        case .ipv6: "IPv6"
        case .bonjour: String(localized: "Bonjour (mDNS)", comment: "Smart home check: multicast DNS works")
        case .isolation: String(localized: "Client isolation", comment: "Smart home check: devices on the Wi-Fi can reach each other")
        case .subnet: String(localized: "Same network", comment: "Smart home check: the Mac and the devices are on one subnet")
        case .wifi24: "2.4 GHz"
        }
    }
}

/// A finding worth acting on, with its sources.
public struct SmartHomeFinding: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let state: SmartHomeState
    public let title: String
    public let detail: String
    public let fix: String
    public var guide: String? = nil
    public let sources: [String]
}

public struct SmartHomeReport: Codable, Sendable, Equatable {
    public let date: Date
    public let headline: String
    public let threadNetworks: [ThreadNetwork]
    /// Border routers not attached to a Thread network now.
    public let idleBorderRouters: [ThreadBorderRouter]
    public let matter: MatterSummary
    public let homeKit: HomeKitSummary
    public let checks: [SmartHomeCheck]
    public let findings: [SmartHomeFinding]
    /// allowed, denied (macOS's Local Network permission is off, so nothing could be browsed) or unknown.
    public let localNetwork: String
    public let routerGuide: String?

    /// Anything smart-home here at all.
    public var devicesFound: Bool { !threadNetworks.isEmpty || !idleBorderRouters.isEmpty || matter.devices > 0 || !matter.commissionable.isEmpty || homeKit.accessories > 0 }
    /// What the Health tab shows: the first finding, or the first failed check, only when there are smart-home devices.
    public var healthIssue: (title: String, detail: String)? {
        guard devicesFound else { return nil }
        if let finding = findings.first(where: { $0.state != .ok && $0.state != .unknown }) { return (finding.title, finding.fix) }
        if let check = checks.first(where: { $0.state == .problem || $0.state == .warning }) { return (check.summary, check.fix ?? "") }
        return nil
    }
}

public enum SmartHomeSources {
    public static let thread14 = "https://www.threadgroup.org/Portals/0/Documents/Thread_1.4_Features_White_Paper_September_2024.pdf"
    public static let openThreadTXT = "https://github.com/openthread/openthread/blob/main/src/core/meshcop/border_agent_txt_data.hpp"
    public static let openThreadRouting = "https://openthread.io/reference/group/api-border-routing"
    public static let googleThread = "https://developers.home.google.com/matter/thread"
    public static let googleMatter = "https://support.google.com/googlehome/answer/12391458"
    public static let appleMatter = "https://support.apple.com/en-us/HT213441"
    public static let amazonMatter = "https://www.amazon.com/gp/help/customer/display.html?nodeId=TSWevY1sX8ADH2LC20"
    public static let matterDiscovery = "https://developers.home.google.com/matter/primer/commissionable-and-operational-discovery"
}

extension SmartHomeReport {
    /// Builds the report from what the browse found and the network facts.
    public static func build(_ records: [BonjourInstance], facts: SmartHomeFacts, now: Date = Date()) -> SmartHomeReport {
        let records = records.filter { record in record.hostKey.map { !facts.ownHosts.contains($0) } ?? true }
        let routers = records.filter { $0.type == SmartHomeServices.meshcop }.map(ThreadBorderRouter.parse)
        let networks = ThreadNetwork.group(routers)
        let idle = routers.filter { !$0.onNetwork }
        let matter = MatterSummary.build(operational: records.filter { $0.type == SmartHomeServices.matter }, commissionable: records.filter { $0.type == SmartHomeServices.matterCommissionable })
        let homeKit = HomeKitSummary.build(records.filter { $0.type == SmartHomeServices.hap || $0.type == SmartHomeServices.hapThread })
        let guide = RouterGuides.url(vendor: facts.routerVendor)
        let checks = [ipv6Check(facts, guide: guide), bonjourCheck(facts), isolationCheck(facts, guide: guide),
                      subnetCheck(records, facts: facts), wifiCheck(facts, guide: guide)]
        var findings: [SmartHomeFinding] = []
        if networks.count > 1 { findings.append(separateNetworks(networks)) }
        if facts.localNetwork == .denied {
            findings.append(SmartHomeFinding(id: "localNetworkDenied", state: .unknown,
                                             title: String(localized: "Kilobat can’t look for smart-home devices", comment: "Smart home: Local Network permission is off"),
                                             detail: String(localized: "macOS’s Local Network permission is off for Kilobat, so Bonjour answers nothing.", comment: "Smart home"),
                                             fix: String(localized: "Turn on Kilobat in System Settings › Privacy & Security › Local Network.", comment: "Smart home"), sources: []))
        }
        return SmartHomeReport(date: now, headline: headline(networks: networks, idle: idle, matter: matter, homeKit: homeKit, denied: facts.localNetwork == .denied),
                               threadNetworks: networks, idleBorderRouters: idle, matter: matter, homeKit: homeKit, checks: checks, findings: findings,
                               localNetwork: facts.localNetwork.rawValue, routerGuide: guide)
    }

    static func headline(networks: [ThreadNetwork], idle: [ThreadBorderRouter], matter: MatterSummary, homeKit: HomeKitSummary, denied: Bool) -> String {
        if denied { return String(localized: "Local Network access is off for Kilobat, so it can’t see smart-home devices.", comment: "Smart home headline") }
        var parts: [String] = []
        if networks.count > 1 {
            parts.append(String(localized: "Thread: \(networks.count) separate networks", comment: "Smart home headline: more than one Thread network"))
        } else if let network = networks.first {
            let count = network.borderRouters.count
            let routers = count == 1 ? String(localized: "1 border router", comment: "Smart home headline") : String(localized: "\(count) border routers", comment: "Smart home headline")
            parts.append(network.name.map { String(localized: "Thread: one network (\($0)) with \(routers)", comment: "Smart home headline; the arguments are the Thread network's name and a count of border routers") }
                         ?? String(localized: "Thread: one network with \(routers)", comment: "Smart home headline"))
        } else if !idle.isEmpty {
            parts.append(String(localized: "Thread: border routers, but none on a network", comment: "Smart home headline"))
        }
        let waiting = matter.readyToSetUp.count
        if matter.devices == 0 && waiting == 0 && !matter.commissionable.isEmpty {
            parts.append(String(localized: "Matter devices advertised, but no setup window is open.", comment: "Smart home: extended discovery without commissioning mode"))
        }
        if matter.devices > 0 || waiting > 0 {
            var text = matter.devices == 1 ? String(localized: "Matter: 1 device", comment: "Smart home headline") : String(localized: "Matter: \(matter.devices) devices", comment: "Smart home headline")
            if waiting > 0 { text += " " + (waiting == 1 ? String(localized: "(1 ready to set up)", comment: "Smart home headline") : String(localized: "(\(waiting) ready to set up)", comment: "Smart home headline")) }
            parts.append(text)
        }
        if homeKit.accessories > 0 {
            var text = homeKit.accessories == 1 ? String(localized: "HomeKit: 1 accessory", comment: "Smart home headline") : String(localized: "HomeKit: \(homeKit.accessories) accessories", comment: "Smart home headline")
            if homeKit.bridges > 0 { text += homeKit.bridges == 1 ? String(localized: ", 1 bridge", comment: "Smart home headline") : String(localized: ", \(homeKit.bridges) bridges", comment: "Smart home headline") }
            parts.append(text)
        }
        guard !parts.isEmpty else { return String(localized: "No Matter, Thread or HomeKit devices answered on this network.", comment: "Smart home headline") }
        return parts.joined(separator: " · ")
    }

    static func separateNetworks(_ networks: [ThreadNetwork]) -> SmartHomeFinding {
        let owners = networks.map { $0.makers.first ?? SmartHomeEcosystem.other.name }
        let distinct = Set(owners).count == owners.count
        let names = ListFormatter.localizedString(byJoining: owners.map { String(localized: "\($0)’s", comment: "Smart home: possessive of an ecosystem, as in “Apple’s”") })
        let title = distinct
            ? String(localized: "You have \(networks.count) separate Thread networks (\(names))", comment: "Smart home finding; the arguments are a count and a list such as “Apple’s and Google’s”")
            : String(localized: "You have \(networks.count) separate Thread networks", comment: "Smart home finding")
        let sharing = networks.flatMap(\.borderRouters).filter { $0.state?.credentialSharing == true }
        var fix = String(localized: "Pick one network to keep. Add new Thread devices with the app whose network you keep, then share them to your other apps with Matter’s pairing code, so they all join the same mesh.", comment: "Smart home fix for separate Thread networks")
        if !sharing.isEmpty {
            fix += " " + String(localized: "Some of your border routers support Thread 1.4 credential sharing, which lets a border router join an existing network; check its app for a way to join your main network.", comment: "Smart home fix: Thread 1.4")
        }
        return SmartHomeFinding(id: "separateThreadNetworks", state: .warning, title: title,
                                detail: String(localized: "Devices on one can’t use the other’s border routers, so each network has fewer routers to relay through and fewer to fall back on.", comment: "Smart home finding detail"),
                                fix: fix, sources: [SmartHomeSources.thread14, SmartHomeSources.googleThread, SmartHomeSources.appleMatter])
    }

    static func ipv6Check(_ facts: SmartHomeFacts, guide: String?) -> SmartHomeCheck {
        guard facts.interface != nil else {
            return SmartHomeCheck(kind: .ipv6, state: .unknown, summary: String(localized: "Not connected to a network.", comment: "Smart home check"))
        }
        let ipv6 = facts.ipv6
        guard ipv6.linkLocal else {
            return SmartHomeCheck(kind: .ipv6, state: .problem, summary: String(localized: "IPv6 is off on this Mac, so Kilobat can’t check the network’s IPv6.", comment: "Smart home check"),
                                  fix: String(localized: "In System Settings › Network, choose the connection, then Details › TCP/IP and set Configure IPv6 to Automatically.", comment: "Smart home fix"))
        }
        // Whether the router itself advertises a prefix: an advertiser's MAC address, from the IPv6 neighbour cache, is the IPv4 gateway's.
        let advertisers = Set(ipv6.prefixes.flatMap(\.routers).compactMap { ipv6.neighbours[$0] })
        let fromRouter: Bool? = advertisers.isEmpty ? nil : facts.gatewayMAC.map { advertisers.contains($0) }
        if ipv6.prefixes.isEmpty && !ipv6.uniqueLocal && !ipv6.global {
            return SmartHomeCheck(kind: .ipv6, state: .unknown,
                                  summary: String(localized: "Only link-local IPv6 was observed; routed Matter connectivity is unverified.", comment: "Smart home check: nothing hands out IPv6 addresses"),
                                  fix: guide == nil ? String(localized: "Check that IPv6 is enabled in the router’s settings. This Mac has no observed ULA or global address; that does not prove IPv6 is off on the router.", comment: "Smart home fix")
                                                    : String(localized: "Check that IPv6 is enabled in the router’s settings (see your router guide). This Mac has no observed ULA or global address; that does not prove IPv6 is off on the router.", comment: "Smart home fix"),
                                  guide: guide)
        }
        let kind = ipv6.global || ipv6.prefixes.contains { !$0.unique } ? String(localized: "global", comment: "Smart home: kind of IPv6 address") : String(localized: "local (ULA)", comment: "Smart home: kind of IPv6 address")
        if fromRouter == false {
            return SmartHomeCheck(kind: .ipv6, state: .ok, summary: String(localized: "IPv6 addresses are available: an observed advertiser differs from the IPv4 gateway, possibly a Thread border router (\(kind)).", comment: "Smart home check; the argument is “global” or “local (ULA)”"))
        }
        return SmartHomeCheck(kind: .ipv6, state: .ok, summary: String(localized: "IPv6 is on: this network hands out \(kind) addresses.", comment: "Smart home check; the argument is “global” or “local (ULA)”"))
    }

    static func bonjourCheck(_ facts: SmartHomeFacts) -> SmartHomeCheck {
        switch facts.localNetwork {
        case .denied:
            return SmartHomeCheck(kind: .bonjour, state: .unknown, summary: String(localized: "Can’t tell: Local Network access is off for Kilobat.", comment: "Smart home check"),
                                  fix: String(localized: "Turn on Kilobat in System Settings › Privacy & Security › Local Network.", comment: "Smart home"))
        default:
            if facts.bonjourPeers > 0 {
                let text = facts.bonjourPeers == 1 ? String(localized: "Working: 1 other device answered.", comment: "Smart home check: Bonjour")
                                                   : String(localized: "Working: \(facts.bonjourPeers) other devices answered.", comment: "Smart home check: Bonjour")
                return SmartHomeCheck(kind: .bonjour, state: .ok, summary: text)
            }
            return SmartHomeCheck(kind: .bonjour, state: .warning, summary: String(localized: "No other device answered Bonjour.", comment: "Smart home check"),
                                  fix: String(localized: "Matter and HomeKit find devices with Bonjour (multicast DNS). If you have smart-home devices here, the router may block multicast: look for “multicast”, “IGMP snooping” or “mDNS” settings.", comment: "Smart home fix"))
        }
    }

    static func isolationCheck(_ facts: SmartHomeFacts, guide: String?) -> SmartHomeCheck {
        guard facts.localNetwork != .denied else {
            return SmartHomeCheck(kind: .isolation, state: .unknown, summary: String(localized: "Can’t tell: Local Network access is off for Kilobat.", comment: "Smart home check"))
        }
        guard facts.interface != nil else { return SmartHomeCheck(kind: .isolation, state: .unknown, summary: String(localized: "Not connected to a network.", comment: "Smart home check")) }
        if facts.neighbours == 0 && facts.bonjourPeers == 0 {
            return SmartHomeCheck(kind: .isolation, state: .unknown,
                                  summary: String(localized: "Can’t tell: no peers answered; a quiet network can look the same as client isolation.", comment: "Smart home check"),
                                  fix: String(localized: "On a guest network, join the main one for setup. Otherwise turn off “AP isolation” or “client isolation” in the router’s Wi-Fi settings.", comment: "Smart home fix"),
                                  guide: guide)
        }
        return SmartHomeCheck(kind: .isolation, state: .ok, summary: String(localized: "Some peers are visible; this does not rule out isolation between other devices.", comment: "Smart home check"))
    }

    static func subnetCheck(_ records: [BonjourInstance], facts: SmartHomeFacts) -> SmartHomeCheck {
        let addresses = Set(records.flatMap(\.addresses).filter { $0.contains(".") && !$0.hasPrefix("169.254.") })
        guard let subnet = facts.subnet else {
            return SmartHomeCheck(kind: .subnet, state: .unknown, summary: String(localized: "Can’t tell: this Mac has no IPv4 address here.", comment: "Smart home check"))
        }
        guard !addresses.isEmpty else {
            return SmartHomeCheck(kind: .subnet, state: .unknown, summary: records.isEmpty ? String(localized: "No smart-home devices to compare.", comment: "Smart home check")
                                                                                         : String(localized: "Can’t tell: the devices gave only IPv6 addresses, as Thread devices do.", comment: "Smart home check"))
        }
        let outside = addresses.filter { address in
            let parts = address.split(separator: ".").compactMap { UInt32($0) }
            guard parts.count == 4 else { return false }
            let value = parts[0] << 24 | parts[1] << 16 | parts[2] << 8 | parts[3]
            return value & subnet.mask != subnet.address & subnet.mask
        }
        if outside.isEmpty { return SmartHomeCheck(kind: .subnet, state: .ok, summary: String(localized: "The devices are on this Mac’s subnet.", comment: "Smart home check")) }
        let count = outside.count
        return SmartHomeCheck(kind: .subnet, state: .warning,
                              summary: count == 1 ? String(localized: "1 smart-home device is on another subnet, likely a separate VLAN or IoT network.", comment: "Smart home check")
                                                  : String(localized: "\(count) smart-home devices are on another subnet, likely a separate VLAN or IoT network.", comment: "Smart home check"),
                              fix: String(localized: "Setting up and controlling Matter devices works best with the phone, hubs and devices on one network. If you keep an IoT network, the router has to pass Bonjour and IPv6 between the two.", comment: "Smart home fix"))
    }

    static func wifiCheck(_ facts: SmartHomeFacts, guide: String?) -> SmartHomeCheck {
        guard facts.onWiFi else {
            return SmartHomeCheck(kind: .wifi24, state: .unknown, summary: String(localized: "Can’t tell: this Mac isn’t on Wi-Fi.", comment: "Smart home check"))
        }
        if facts.band == "2.4 GHz" { return SmartHomeCheck(kind: .wifi24, state: .ok, summary: String(localized: "This Mac is on 2.4 GHz now.", comment: "Smart home check")) }
        guard let ssid = facts.ssid else {
            return SmartHomeCheck(kind: .wifi24, state: .unknown, summary: String(localized: "Can’t tell: macOS shares the Wi-Fi name only with Location access.", comment: "Smart home check"))
        }
        // A scan without names (no Location permission) can't show the network on any band, so it can't tell either.
        guard let scan = facts.scan, scan.contains(where: { $0.ssid == ssid }) else {
            return SmartHomeCheck(kind: .wifi24, state: .unknown, summary: String(localized: "Can’t tell: no Wi-Fi scan.", comment: "Smart home check"))
        }
        if scan.contains(where: { $0.ssid == ssid && $0.band == "2.4 GHz" }) {
            return SmartHomeCheck(kind: .wifi24, state: .ok, summary: String(localized: "Your network is on 2.4 GHz too, which Wi-Fi smart-home devices need for setup.", comment: "Smart home check"))
        }
        return SmartHomeCheck(kind: .wifi24, state: .warning, summary: String(localized: "No 2.4 GHz access point with this network name was seen in the scan.", comment: "Smart home check"),
                              fix: String(localized: "Most Matter and HomeKit Wi-Fi devices join only 2.4 GHz. Turn on the router’s 2.4 GHz band with the same network name, or set the device up near a node that has it.", comment: "Smart home fix"),
                              guide: guide)
    }
}

extension SmartHomeReport {
    /// The MCP tool's shape: counts, names and verdicts, without addresses, bitmaps or IDs.
    public struct Compact: Encodable, Sendable {
        public struct Network: Encodable, Sendable {
            let name: String?, makers: [String], borderRouters: [String], threadVersions: [String], credentialSharing: Bool
        }
        public struct Matter: Encodable, Sendable { let devices, overThread, overWiFi, fabrics: Int; let readyToSetUp: [String] }
        public struct HomeKit: Encodable, Sendable { let accessories, bridges, unpaired, overThread: Int; let categories: [String: Int] }
        public struct Check: Encodable, Sendable { let check: String, state: String, summary: String, fix: String?, guide: String? }
        public struct Finding: Encodable, Sendable { let id: String, title: String, detail: String, fix: String, sources: [String] }
        let headline: String
        let localNetwork: String
        let threadNetworks: [Network]
        let idleBorderRouters: [String]
        let matter: Matter
        let homeKit: HomeKit
        let checks: [Check]
        let findings: [Finding]
        let routerGuide: String?
    }

    public var compact: Compact {
        Compact(headline: headline, localNetwork: localNetwork,
                threadNetworks: threadNetworks.map { network in
                    .init(name: network.name, makers: network.makers, borderRouters: network.borderRouters.map { "\($0.label) · \($0.maker)" },
                          threadVersions: Array(Set(network.borderRouters.compactMap(\.threadVersion))).sorted(), credentialSharing: network.credentialSharing)
                },
                idleBorderRouters: idleBorderRouters.map(\.label),
                matter: .init(devices: matter.devices, overThread: matter.overThread, overWiFi: matter.overWiFi, fabrics: matter.fabrics, readyToSetUp: matter.readyToSetUp.map(\.label)),
                homeKit: .init(accessories: homeKit.accessories, bridges: homeKit.bridges, unpaired: homeKit.unpaired, overThread: homeKit.overThread, categories: homeKit.categories),
                checks: checks.map { .init(check: $0.kind.rawValue, state: $0.state.rawValue, summary: $0.summary, fix: $0.state == .ok ? nil : $0.fix, guide: $0.state == .ok ? nil : $0.guide) },
                findings: findings.map { .init(id: $0.id, title: $0.title, detail: $0.detail, fix: $0.fix, sources: $0.sources) },
                routerGuide: routerGuide)
    }
}

/// `kilobat smarthome [--json]`.
public enum SmartHomeCommand: Equatable, Sendable {
    case report(json: Bool)
    public static let usage = "Use smarthome [--json]."
    public static func parse(_ args: [String]) throws -> SmartHomeCommand {
        let rest = Array(args.dropFirst())
        if let unexpected = rest.first(where: { $0 != "--json" }) { throw DiagnosticError("Unexpected '\(unexpected)'. " + usage) }
        return .report(json: rest.contains("--json"))
    }
}
