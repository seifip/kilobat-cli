import Foundation

/// What a device on the local network offers, from the Bonjour service type it advertises.
public enum LocalServiceKind: String, Codable, Sendable, CaseIterable, Comparable {
    /// Chromecast, Google TV and TVs with Chromecast built in (`_googlecast._tcp`).
    case cast
    /// Apple TV, AirPlay TVs and speakers, and Macs with AirPlay Receiver on (`_airplay._tcp`, `_raop._tcp`).
    case airPlay
    /// AirPrint and other IPP printers (`_ipp._tcp`, `_ipps._tcp`), and LPD ones (`_printer._tcp`).
    case printer
    /// iPhones, iPads, Macs and Apple TVs talking Continuity (`_companion-link._tcp`): not something to cast to,
    /// but proof that devices here can hear each other.
    case companion

    public static func < (a: Self, b: Self) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
    public var casting: Bool { self == .cast || self == .airPlay }
}

/// One device advertising a service, as Bonjour named it.
public struct LocalService: Codable, Sendable, Equatable, Hashable {
    public let kind: LocalServiceKind
    /// The friendly name: Chromecast's `fn`, the AirPlay or printer instance name.
    public let name: String
    /// The model when the record says, such as "Chromecast", "AppleTV14,1" or "HP LaserJet Pro M404-M405".
    public var model: String?
    public init(kind: LocalServiceKind, name: String, model: String? = nil) { self.kind = kind; self.name = name; self.model = model }
    /// A Mac with AirPlay Receiver on: it counts, but a TV reads better first.
    var mac: Bool { kind == .airPlay && (model?.hasPrefix("Mac") == true || model?.hasPrefix("iMac") == true) }
}

/// The Bonjour types the check browses, and how their records name a device.
public enum LocalServiceCatalog {
    public static let types: [(type: String, kind: LocalServiceKind)] = [
        ("_googlecast._tcp", .cast), ("_airplay._tcp", .airPlay), ("_raop._tcp", .airPlay),
        ("_ipp._tcp", .printer), ("_ipps._tcp", .printer), ("_printer._tcp", .printer), ("_companion-link._tcp", .companion),
    ]

    /// One browse result as a service. Chromecasts name themselves in `fn` (the instance is a model and an id), AirPlay
    /// audio as `<MAC>@<name>`, printers sometimes end in a bracketed id such as "[5A1B2C]".
    public static func service(type: String, instance: String, txt: [String: String]) -> LocalService? {
        guard let kind = types.first(where: { $0.type == type })?.kind else { return nil }
        var name = instance.trimmingCharacters(in: .whitespaces)
        var model: String?
        switch type {
        case "_googlecast._tcp":
            if let friendly = txt["fn"]?.trimmingCharacters(in: .whitespaces), !friendly.isEmpty { name = friendly }
            model = txt["md"]
        case "_raop._tcp":
            if let at = name.firstIndex(of: "@") { name = String(name[name.index(after: at)...]) }
            model = txt["am"]
        case "_airplay._tcp":
            model = txt["model"]
        case "_ipp._tcp", "_ipps._tcp", "_printer._tcp":
            name = name.replacingOccurrences(of: #"\s*[\[(][0-9A-Fa-f]{4,12}[\])]$"#, with: "", options: .regularExpression)
            model = txt["ty"] ?? txt["product"].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "()")) }
        default: break
        }
        guard !name.isEmpty else { return nil }
        let known = model.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty || $0.caseInsensitiveCompare("Unknown") == .orderedSame ? nil : $0 }
        return LocalService(kind: kind, name: name, model: known)
    }

    /// One row per device and kind, without this Mac's own (`own` is its computer name, which macOS uses for its
    /// AirPlay Receiver and Continuity records): AirPlay video and audio, and IPP and IPPS, collapse into one.
    public static func merge(_ services: [LocalService], own: String?) -> [LocalService] {
        let mine = own?.trimmingCharacters(in: .whitespaces).lowercased()
        var seen: [String: LocalService] = [:], order: [String] = []
        for service in services where service.name.lowercased() != mine {
            let key = service.kind.rawValue + "|" + service.name.lowercased()
            if let earlier = seen[key] { if earlier.model == nil, service.model != nil { seen[key] = service }; continue }
            seen[key] = service; order.append(key)
        }
        return order.compactMap { seen[$0] }.sorted { a, b in
            if a.kind != b.kind { return a.kind < b.kind }
            if a.mac != b.mac { return !a.mac }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// Whether other devices on the network answer at all: the neighbour cache after a light sweep, a ping to a few of
/// them, and any other device's Bonjour record.
public struct LocalPeers: Codable, Sendable, Equatable {
    /// Other devices the neighbour cache holds on the Mac's interface with their own hardware address (the router and
    /// this Mac left out).
    public var neighbours: Int = 0
    /// Other addresses that answered with the router's hardware address: proxy ARP, which client isolation uses.
    public var routerAliases: Int = 0
    /// The sweep ran over the Mac's subnet before the cache was read.
    public var swept = false
    /// Addresses in the subnet, from its mask; nil when the interface has no IPv4 address.
    public var subnetHosts: Int?
    public var pinged = 0
    public var answered = 0
    /// Distinct other devices in any Bonjour record the check browsed, Continuity's included.
    public var bonjourDevices = 0
    public init() {}

    /// Proxy ARP: two or more other addresses answer with the router's own hardware address.
    public var proxyARP: Bool { routerAliases >= 2 }
    public var heard: Bool { bonjourDevices > 0 || answered > 0 }

    /// The neighbour cache's rows on `interface`: devices with their own address, and the addresses that answered as the router.
    public static func from(rows: [LANDevice], interface: String, gateway: String?, own: Set<String>) -> (neighbours: [String], routerAliases: Int) {
        let routerMAC = gateway.flatMap { gateway in rows.first { $0.address == gateway && $0.interface == interface } }.flatMap { MACAddress.normalized($0.mac) }
        var neighbours: [String] = [], macs: Set<String> = [], aliases = 0
        for row in rows where row.interface == interface && row.address != gateway && !row.address.hasSuffix(".255") {
            guard let mac = MACAddress.normalized(row.mac), MACAddress.unicast(mac), !own.contains(mac) else { continue }
            if mac == routerMAC { aliases += 1; continue }
            if macs.insert(mac).inserted { neighbours.append(row.address) }
        }
        return (neighbours, aliases)
    }

    /// Addresses in a subnet with this many prefix bits, the network and broadcast addresses left out.
    public static func hosts(prefix: Int) -> Int { prefix >= 31 ? 0 : (1 << (32 - max(0, prefix))) - 2 }
}

/// "Can I cast or print here?": what Bonjour found, whether other devices answer, and the verdict from both.
public struct LocalReachCheck: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable {
        /// A TV, speaker or printer advertised itself: casting or printing should work.
        case works
        /// Signs of client isolation, never proof that connections are blocked.
        case isolated
        /// Nothing to cast or print to, and no proof either way about isolation.
        case noneSeen
        /// macOS refused Kilobat Bonjour: Local Network access is off for it.
        case noAccess
        /// Not on a network.
        case offline
    }
    /// What the isolation verdict rests on.
    public enum Evidence: String, Codable, Sendable {
        /// Other addresses answer with the router's own hardware address.
        case proxyARP
        /// Legacy decoded value. Silence alone is no longer treated as isolation evidence.
        case nobodyHome
    }
    /// Legacy threshold retained for API compatibility; subnet size no longer establishes isolation.
    public static let largeSubnet = 510

    public let date: Date
    public var network: String?
    public var services: [LocalService]
    public var peers: LocalPeers
    public var access: LocalNetworkAccess
    /// A Wi-Fi sign-in page was seen on this network: a hotel, café or guest network.
    public var portal: Bool
    public var connected: Bool

    public init(date: Date = Date(), network: String?, services: [LocalService], peers: LocalPeers, access: LocalNetworkAccess = .allowed,
                portal: Bool = false, connected: Bool = true) {
        self.date = date; self.network = network; self.services = services; self.peers = peers; self.access = access; self.portal = portal; self.connected = connected
    }

    public var targets: [LocalService] { services.filter { $0.kind != .companion } }
    public var casting: [LocalService] { services.filter(\.kind.casting) }
    public var printers: [LocalService] { services.filter { $0.kind == .printer } }

    /// Proxy ARP can accompany client isolation, but also ordinary routing. An empty sweep, a large subnet or a
    /// sign-in page cannot establish isolation: devices may sleep or ignore discovery and ping.
    public var evidence: Evidence? {
        guard connected, access != .denied, targets.isEmpty, peers.bonjourDevices == 0, peers.answered == 0 else { return nil }
        if peers.proxyARP { return .proxyARP }
        return nil
    }

    public var verdict: Verdict {
        if !connected { return .offline }
        if !targets.isEmpty { return .works }
        if access == .denied { return .noAccess }
        return evidence == nil ? .noneSeen : .isolated
    }

    /// "Casting and printing should work: found Living Room TV, HP LaserJet".
    public var headline: String {
        switch verdict {
        case .works:
            let names = Self.list(targets.map(\.name))
            if !casting.isEmpty && !printers.isEmpty {
                return String(localized: "Casting and printing should work: found \(names)", comment: "Local network check; the argument lists devices such as “Living Room TV, HP LaserJet”")
            }
            return casting.isEmpty ? String(localized: "Printing should work: found \(names)", comment: "Local network check; the argument lists printers")
                                   : String(localized: "Casting should work: found \(names)", comment: "Local network check; the argument lists TVs and speakers")
        case .isolated:
            return String(localized: "This network may keep devices apart. Casting and AirPrint might not work here.", comment: "Local network check: possible client isolation")
        case .noneSeen:
            return String(localized: "No casting devices seen", comment: "Local network check: no TV, speaker or printer advertised itself")
        case .noAccess:
            return String(localized: "Kilobat needs Local Network access to look for TVs and printers", comment: "Local network check")
        case .offline:
            return String(localized: "Not on a network", comment: "Local network check")
        }
    }

    /// The reason, in a sentence or two.
    public var detail: String {
        switch verdict {
        case .works:
            let missing = casting.isEmpty ? String(localized: "No TV or speaker to cast to showed up.", comment: "Local network check, after printers were found")
                : printers.isEmpty ? String(localized: "No printer showed up.", comment: "Local network check, after TVs were found") : nil
            return [String(localized: "They advertise themselves on this network, so devices here can see each other.", comment: "Local network check"), missing].compactMap { $0 }.joined(separator: " ")
        case .isolated:
            switch evidence {
            case .proxyARP:
                return String(localized: "Other addresses answer with the router’s hardware address (proxy ARP). This can accompany client isolation, but it also supports ordinary routing; it does not prove that casting or printing is blocked.", comment: "Local network check: why isolation is claimed")
            default:
                return String(localized: "No other device answered. Devices may be asleep or discovery may be filtered; this does not establish client isolation.", comment: "Local network check: why isolation is claimed")
            }
        case .noneSeen:
            if peers.heard {
                return String(localized: "Other devices answer here, so the network lets devices talk. Check the TV or printer is on and joined to this Wi-Fi.", comment: "Local network check")
            }
            if peers.neighbours >= 3 {
                return String(localized: "\(peers.neighbours) devices are on this network but none answered, so it may keep devices apart. Kilobat can’t be sure.", comment: "Local network check; the argument is a number")
            }
            return String(localized: "No other device answered either, so Kilobat can’t tell whether this network keeps devices apart.", comment: "Local network check")
        case .noAccess:
            return String(localized: "Turn on Kilobat in System Settings › Privacy & Security › Local Network, then check again.", comment: "Local network check")
        case .offline:
            return String(localized: "Join a network, then check again.", comment: "Local network check")
        }
    }

    /// What to do next, when there's something to do.
    public var advice: String? {
        switch verdict {
        case .isolated:
            return String(localized: "Turn on your phone’s hotspot and join it with the Mac and the TV, use the TV’s own Wi-Fi Direct or screen-mirroring network, or plug in an HDMI cable.", comment: "Local network check advice when the network keeps devices apart")
        case .noneSeen where !peers.heard:
            return String(localized: "If the TV is on this Wi-Fi and still doesn’t show, the network may keep devices apart. Try a phone hotspot, the TV’s Wi-Fi Direct or an HDMI cable.", comment: "Local network check advice")
        default: return nil
        }
    }

    /// A short line for the Wi-Fi menu.
    public var short: String {
        switch verdict {
        case .works:
            let count = targets.count
            if !casting.isEmpty && !printers.isEmpty { return String(localized: "Casting and printing should work · \(count) devices", comment: "Wi-Fi menu: local network check; the argument is a number") }
            return casting.isEmpty ? String(localized: "Printing should work · \(Self.list(printers.map(\.name), limit: 1))", comment: "Wi-Fi menu: local network check; the argument names a printer")
                                   : String(localized: "Casting should work · \(Self.list(casting.map(\.name), limit: 1))", comment: "Wi-Fi menu: local network check; the argument names a TV")
        case .isolated: return String(localized: "May keep devices apart · casting uncertain", comment: "Wi-Fi menu: local network check")
        case .noneSeen: return String(localized: "No casting devices seen", comment: "Wi-Fi menu: local network check")
        case .noAccess: return String(localized: "Needs Local Network access", comment: "Wi-Fi menu: local network check")
        case .offline: return String(localized: "Not on a network", comment: "Wi-Fi menu: local network check")
        }
    }

    /// "Living Room TV, HP LaserJet and 2 more".
    static func list(_ names: [String], limit: Int = 3) -> String {
        guard names.count > limit else { return names.joined(separator: ", ") }
        return names.prefix(limit).joined(separator: ", ") + " " + String(localized: "and \(names.count - limit) more", comment: "After a list of device names; the argument is a number")
    }
}

/// The app's answer to the CLI: its latest check on this network, nil before one ran.
public struct LocalReachRelay: Codable, Sendable {
    public var check: LocalReachCheck?
    public var setup: SetupNetworkMatch?
    public var previous: String?
    public init(check: LocalReachCheck?, setup: SetupNetworkMatch? = nil, previous: String? = nil) { self.check = check; self.setup = setup; self.previous = previous }
}

/// `kilobat local [check] [--json]`.
public enum LocalCommand: Equatable, Sendable {
    case check(json: Bool, quick: Bool)
    public static let usage = "Use local [check] [--quick] [--json]."
    /// `args` starts with "local". A piped run appends --json.
    public static func parse(_ args: [String]) throws -> LocalCommand {
        let rest = Array(args.dropFirst()), words = rest.filter { $0 != "--json" && $0 != "--quick" }
        guard words == [] || words == ["check"] else { throw DiagnosticError(usage) }
        return .check(json: rest.contains("--json"), quick: rest.contains("--quick"))
    }
}
