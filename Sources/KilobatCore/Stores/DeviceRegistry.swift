import Foundation
import Observation

/// What the person said about a device on their network. No verdict yet means it was learned or is new.
public enum DeviceVerdict: String, Codable, Sendable, CaseIterable { case mine, unknown, ignored }

/// A device Kilobat has seen on one network, keyed by its hardware (MAC) address.
///
/// Phones, tablets and laptops join Wi-Fi with a private address (the locally administered bit set), which
/// usually stays fixed per network but can rotate. Such a device is also recognised by the name it gives itself
/// (Bonjour or the router's DHCP name) when that name is specific, such as Ritas-iPad; its old addresses are kept
/// in `aliases`. The maker (from the address's OUI) is never used to tell devices apart: every iPhone is Apple,
/// and a private address has no maker at all.
public struct KnownDevice: Codable, Identifiable, Sendable, Equatable {
    public var id: String { mac }
    /// Lowercase and zero-padded, `aa:bb:cc:dd:ee:ff`.
    public var mac: String
    /// Earlier private addresses of the same device.
    public var aliases: [String]? = nil
    /// The name the person gave it.
    public var name: String? = nil
    /// The name it gives itself on the network, as Bonjour or the router's DNS reports it.
    public var hostname: String? = nil
    /// The maker registered for the address, from the bundled IEEE table; nil for private addresses.
    public var vendor: String? = nil
    /// Its IPv4 address when last seen.
    public var address: String? = nil
    public var verdict: DeviceVerdict? = nil
    public var firstSeen: Date
    public var lastSeen: Date
    /// When it joined, or came back after an hour or more away: what a call report compares with a freeze.
    public var arrived: Date
    /// Seen before Kilobat watched this network (its first scan, or a network that isn't marked home), so never alerted.
    public var learned: Bool? = nil
    /// When the new-device notification went out.
    public var alerted: Date? = nil

    public init(mac: String, name: String? = nil, hostname: String? = nil, vendor: String? = nil, address: String? = nil, verdict: DeviceVerdict? = nil,
                firstSeen: Date, lastSeen: Date? = nil, arrived: Date? = nil, learned: Bool? = nil) {
        self.mac = mac; self.name = name; self.hostname = hostname; self.vendor = vendor; self.address = address; self.verdict = verdict
        self.firstSeen = firstSeen; self.lastSeen = lastSeen ?? firstSeen; self.arrived = arrived ?? firstSeen; self.learned = learned
    }

    public enum Status: String, Codable, Sendable { case new, known, unknown, ignored }
    /// New until answered, unless it was learned; yours or learned is known.
    public var status: Status {
        switch verdict {
        case .mine: .known
        case .unknown: .unknown
        case .ignored: .ignored
        case nil: learned == true ? .known : .new
        }
    }
    public var privateAddress: Bool { MACAddress.locallyAdministered(mac) }
    public var macs: [String] { [mac] + (aliases ?? []) }
    /// The name to show: the person's, else the device's own, else its maker's.
    public var label: String {
        if let name, !name.isEmpty { return name }
        if let own = DeviceNames.readable(hostname) { return own }
        if let vendor { return String(localized: "\(vendor) device", comment: "A device on the network named by its maker, such as “Samsung device”") }
        return privateAddress ? String(localized: "Device with a private address", comment: "A device on the network that hides its maker behind a private Wi-Fi address")
                              : String(localized: "Unnamed device", comment: "A device on the network with no name or maker")
    }
    /// How a call report names it: the person's or the device's own name, else "a new Samsung device"; nil when nothing specific is known.
    public var callName: String? {
        if let name, !name.isEmpty { return name }
        if let own = DeviceNames.readable(hostname) { return own }
        return vendor.map { String(localized: "a new \($0) device", comment: "Call report: an unnamed device that just joined the network, named by its maker, such as “a new Samsung device”") }
    }
}

/// One network's devices and whether Kilobat watches it for new ones.
public struct DeviceNetwork: Codable, Sendable, Equatable {
    public var name: String
    /// Marked as the person's home network: Kilobat scans it and says when a new device joins.
    public var home = false
    /// The first scan while it was home, which learns every device present without alerting.
    public var baseline: Date? = nil
    /// The router's MAC address, so the CLI can tell which network it is on without the app.
    public var router: String? = nil
    public var devices: [KnownDevice] = []
    public init(name: String) { self.name = name }
    public func index(of mac: String) -> Int? {
        guard let mac = MACAddress.normalized(mac) else { return nil }
        return devices.firstIndex { $0.macs.contains(mac) }
    }
}

/// A device in the neighbour cache during one scan.
public struct DeviceSighting: Sendable, Equatable {
    public let mac: String
    public let address: String
    public var hostname: String?
    public init(mac: String, address: String, hostname: String? = nil) { self.mac = mac; self.address = address; self.hostname = hostname }
}

/// Every network's devices, as saved in devices.json. Pure, so learning and matching can be tested.
public struct DeviceBook: Codable, Sendable, Equatable {
    public var networks: [String: DeviceNetwork] = [:]
    /// A device away this long counts as arriving again when it reappears.
    public static let away: TimeInterval = 3600
    /// Devices kept per network; the oldest unnamed, unanswered ones go first.
    public static let limit = 400
    public init() {}

    /// Records what a scan saw on `key` and returns the devices that joined since Kilobat began watching it. The
    /// first scan of a home network, and any scan of a network that isn't home, learns devices silently.
    @discardableResult
    public mutating func observe(_ sightings: [DeviceSighting], network key: String, name: String, router: String? = nil,
                                 vendor: (String) -> String? = { _ in nil }, names: [String: String] = [:], now: Date = Date()) -> [KnownDevice] {
        var net = networks[key] ?? DeviceNetwork(name: name)
        net.name = name
        if let router = router.flatMap(MACAddress.normalized) { net.router = router }
        let watching = net.home && net.baseline != nil
        var seen: [String: DeviceSighting] = [:]
        for sighting in sightings {
            guard let mac = MACAddress.normalized(sighting.mac), MACAddress.unicast(mac) else { continue }
            seen[mac] = DeviceSighting(mac: mac, address: sighting.address, hostname: sighting.hostname ?? seen[mac]?.hostname)
        }
        var touched: Set<Int> = [], newcomers: [KnownDevice] = []
        for sighting in seen.values.sorted(by: { $0.mac < $1.mac }) {
            if let index = net.index(of: sighting.mac) {
                update(&net.devices[index], with: sighting, now: now); touched.insert(index); continue
            }
            // A private address the same specific name used before: the device rotated its address, unless the old one is here too.
            if MACAddress.locallyAdministered(sighting.mac), let key = DeviceNames.stable(sighting.hostname),
               let index = net.devices.indices.first(where: { index in
                   let device = net.devices[index]
                   return !touched.contains(index) && device.privateAddress && DeviceNames.stable(device.hostname) == key && !device.macs.contains { seen[$0] != nil }
               }) {
                var device = net.devices[index]
                device.aliases = Array(([device.mac] + (device.aliases ?? [])).prefix(8))
                device.mac = sighting.mac
                update(&device, with: sighting, now: now)
                net.devices[index] = device; touched.insert(index); continue
            }
            var device = KnownDevice(mac: sighting.mac, name: names[sighting.mac], hostname: sighting.hostname,
                                     vendor: MACAddress.locallyAdministered(sighting.mac) ? nil : vendor(sighting.mac), address: sighting.address,
                                     firstSeen: now, learned: watching ? nil : true)
            if device.name?.isEmpty == true { device.name = nil }
            net.devices.append(device); touched.insert(net.devices.count - 1)
            if watching { newcomers.append(device) }
        }
        if net.home && net.baseline == nil { net.baseline = now }
        if net.devices.count > Self.limit {
            let keep = net.devices.enumerated().sorted { a, b in
                let ka = a.element.name != nil || a.element.verdict != nil, kb = b.element.name != nil || b.element.verdict != nil
                return ka != kb ? ka : a.element.lastSeen > b.element.lastSeen
            }.prefix(Self.limit).map(\.offset)
            net.devices = Set(keep).sorted().map { net.devices[$0] }
        }
        networks[key] = net
        return newcomers
    }

    private func update(_ device: inout KnownDevice, with sighting: DeviceSighting, now: Date) {
        if now.timeIntervalSince(device.lastSeen) >= Self.away { device.arrived = now }
        device.lastSeen = max(device.lastSeen, now)
        device.address = sighting.address
        if let hostname = sighting.hostname { device.hostname = hostname }
    }

    public mutating func setHome(_ home: Bool, network key: String, name: String) {
        var net = networks[key] ?? DeviceNetwork(name: name)
        net.home = home
        networks[key] = net
    }

    /// Sets the verdict for the device with this address on `network`, or on every network that has it. False when none has.
    @discardableResult
    public mutating func setVerdict(_ verdict: DeviceVerdict?, mac: String, network: String? = nil) -> Bool {
        edit(mac: mac, network: network) { $0.verdict = verdict }
    }

    /// Names the device; an empty name removes it.
    @discardableResult
    public mutating func rename(mac: String, to name: String, network: String? = nil) -> Bool {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        return edit(mac: mac, network: network) { $0.name = clean.isEmpty ? nil : clean }
    }

    public mutating func markAlerted(mac: String, network: String, at date: Date = Date()) {
        edit(mac: mac, network: network) { $0.alerted = date }
    }

    @discardableResult
    private mutating func edit(mac: String, network: String?, _ change: (inout KnownDevice) -> Void) -> Bool {
        var found = false
        for key in network.map({ [$0] }) ?? Array(networks.keys) {
            guard var net = networks[key], let index = net.index(of: mac) else { continue }
            change(&net.devices[index]); networks[key] = net; found = true
        }
        return found
    }

    public func device(mac: String, network: String) -> KnownDevice? {
        guard let net = networks[network], let index = net.index(of: mac) else { return nil }
        return net.devices[index]
    }

    /// The network whose router has this MAC address.
    public func network(router mac: String) -> String? {
        guard let mac = MACAddress.normalized(mac) else { return nil }
        return networks.filter { $0.value.router == mac }.max { ($0.value.devices.map(\.lastSeen).max() ?? .distantPast) < ($1.value.devices.map(\.lastSeen).max() ?? .distantPast) }?.key
    }

    /// Devices that joined or came back on `network` between the two dates, apart from its router and ones learned at the first scan.
    public func arrivals(network: String, from start: Date, to end: Date) -> [KnownDevice] {
        guard let net = networks[network] else { return [] }
        return net.devices.filter { device in
            device.arrived >= start && device.arrived <= end && device.mac != net.router && !(device.learned == true && device.arrived == device.firstSeen)
        }
    }
}

/// What to tell the person about the devices a scan found new.
public enum DeviceAlert: Equatable, Sendable {
    /// One device, with its answers.
    case one(KnownDevice)
    /// Several at once, as after the router restarts: one notification that opens the list.
    case several(Int)

    /// Nil when there is nothing to say, or alerts aren't allowed (Kilobat Pro and notification permission).
    public static func decide(_ newcomers: [KnownDevice], allowed: Bool) -> DeviceAlert? {
        let fresh = newcomers.filter { $0.verdict == nil && $0.alerted == nil && $0.learned != true }
        guard allowed, let first = fresh.first else { return nil }
        return fresh.count == 1 ? .one(first) : .several(fresh.count)
    }

    /// "A new device joined The Batcave"; the name stays on this Mac.
    public static func title(network: String, count: Int = 1) -> String {
        count == 1 ? String(localized: "A new device joined \(network)", comment: "Notification title; the argument is the home network's Wi-Fi name")
                   : String(localized: "\(count) new devices joined \(network)", comment: "Notification title; the arguments are a count and the home network's Wi-Fi name")
    }
    /// What is known: the device's name or maker, its address and when it joined.
    public static func body(_ device: KnownDevice) -> String {
        var parts = [device.label]
        if let address = device.address { parts.append(address) }
        parts.append(String(localized: "first seen \(device.firstSeen.formatted(date: .omitted, time: .shortened))", comment: "Notification detail; the argument is a time"))
        return parts.joined(separator: " · ")
    }
    public static func body(count: Int) -> String {
        String(localized: "Open Kilobat to say which are yours.", comment: "Notification body when several new devices joined at once")
    }
    /// What to do about a device the person doesn't recognise.
    public static let advice = String(localized: "Check your router’s list of connected devices for it, and if you still don’t know it, change your Wi-Fi password. Everything you haven’t given the new password to drops off. Give visitors a guest network.", comment: "Advice for a device on the home network the user doesn't recognise")
}

/// MAC address helpers: normalising `arp`'s unpadded form and reading the address's flag bits.
public enum MACAddress {
    /// `0:1a:2b:3:4:5` or `00-1A-2B-03-04-05` as `00:1a:2b:03:04:05`; nil when it isn't six bytes.
    public static func normalized(_ text: String) -> String? {
        let parts = text.lowercased().split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6, parts.allSatisfy({ (1...2).contains($0.count) && UInt8($0, radix: 16) != nil }) else { return nil }
        return parts.map { $0.count == 1 ? "0" + $0 : String($0) }.joined(separator: ":")
    }
    static func firstOctet(_ mac: String) -> UInt8? { normalized(mac).flatMap { UInt8($0.prefix(2), radix: 16) } }
    /// The locally administered bit: a private (random) Wi-Fi address rather than one the maker assigned.
    public static func locallyAdministered(_ mac: String) -> Bool { (firstOctet(mac) ?? 0) & 0x02 != 0 }
    /// A single device, not broadcast or multicast, and not all zeros.
    public static func unicast(_ mac: String) -> Bool {
        guard let first = firstOctet(mac) else { return false }
        return first & 0x01 == 0 && normalized(mac) != "00:00:00:00:00:00"
    }
    /// The first three bytes, for the maker table.
    public static func oui(_ mac: String) -> UInt32? {
        guard let mac = normalized(mac) else { return nil }
        return UInt32(mac.prefix(8).replacingOccurrences(of: ":", with: ""), radix: 16)
    }
}

/// The names devices give themselves: shown when readable, and used to recognise a private address that rotated
/// only when specific enough that two devices are unlikely to share it.
public enum DeviceNames {
    static let suffixes = [".local", ".lan", ".home", ".home.arpa", ".localdomain", ".domain", ".router", ".gateway", ".fritz.box", ".station", ".internal", ".box"]
    /// Names many devices share out of the box.
    static let generic: Set<String> = ["iphone", "ipad", "ipod", "android", "localhost", "unknown", "espressif", "esp", "galaxy", "pixel", "macbook", "macbook-pro",
                                       "macbook-air", "imac", "mac", "mac-mini", "watch", "apple-watch", "appletv", "apple-tv", "homepod", "chromecast", "amazon", "echo",
                                       "kindle", "fire-tv", "firetv", "roku", "tv", "printer", "laptop", "desktop", "pc", "phone", "tablet", "dhcp", "host", "device",
                                       "client", "wlan0", "station", "raspberrypi", "linux", "windows", "nintendo", "playstation", "xbox", "sonos", "router", "gateway"]

    /// "Ritas-iPad.local." as "Ritas-iPad"; nil for an empty name or an address.
    public static func readable(_ hostname: String?) -> String? {
        guard var name = hostname?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        while name.hasSuffix(".") { name.removeLast() }
        for suffix in suffixes where name.lowercased().hasSuffix(suffix) && name.count > suffix.count { name = String(name.dropLast(suffix.count)) }
        guard !name.isEmpty, name.contains(where: \.isLetter), !name.allSatisfy({ $0.isHexDigit || ".:-".contains($0) }) || name.count < 7 else { return nil }
        return name
    }

    /// The name lowercased, without a domain or the "-2" macOS and iOS add on a clash; nil when it's generic.
    public static func stable(_ hostname: String?) -> String? {
        guard let readable = readable(hostname) else { return nil }
        var name = readable.lowercased().split(separator: ".").first.map(String.init) ?? ""
        if let range = name.range(of: #"(-|\s\()\d{1,2}\)?$"#, options: .regularExpression) { name.removeSubrange(range) }
        name = name.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
        guard name.count >= 3, name.contains(where: \.isLetter), !generic.contains(name) else { return nil }
        return name
    }
}

/// devices.json in Kilobat's Application Support folder: every network's devices with the person's names and answers.
/// Never sent anywhere. The CLI writes the same file, so each change rereads it first.
@MainActor @Observable public final class DeviceRegistry {
    public private(set) var book = DeviceBook()
    public private(set) var persistenceError: String?
    private let file: URL
    @ObservationIgnored private var stamp: Date?

    public init(directory: URL? = nil) {
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("devices.json")
        reload()
    }

    /// Reads the file again when something else, such as the CLI, changed it.
    public func reload() {
        let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        guard modified != stamp || modified == nil else { return }
        stamp = modified
        book = StoredJSON.read(file) ?? DeviceBook()
    }

    private func change(_ edit: (inout DeviceBook) -> Void) {
        reload()
        var next = book
        edit(&next)
        guard next != book else { return }
        book = next
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(book).write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            stamp = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
            persistenceError = nil
        } catch { persistenceError = error.localizedDescription }
    }

    @discardableResult
    public func observe(_ sightings: [DeviceSighting], network key: String, name: String, router: String? = nil,
                        vendor: (String) -> String? = { DeviceVendors.shared.vendor(for: $0) }, names: [String: String] = [:], now: Date = Date()) -> [KnownDevice] {
        var newcomers: [KnownDevice] = []
        change { newcomers = $0.observe(sightings, network: key, name: name, router: router, vendor: vendor, names: names, now: now) }
        return newcomers
    }
    public func isHome(_ network: String) -> Bool { book.networks[network]?.home == true }
    public func setHome(_ home: Bool, network: String, name: String) { change { $0.setHome(home, network: network, name: name) } }
    @discardableResult
    public func setVerdict(_ verdict: DeviceVerdict?, mac: String, network: String? = nil) -> Bool {
        var found = false; change { found = $0.setVerdict(verdict, mac: mac, network: network) }; return found
    }
    @discardableResult
    public func rename(mac: String, to name: String, network: String? = nil) -> Bool {
        var found = false; change { found = $0.rename(mac: mac, to: name, network: network) }; return found
    }
    public func markAlerted(mac: String, network: String, at date: Date = Date()) { change { $0.markAlerted(mac: mac, network: network, at: date) } }
    public func devices(on network: String) -> [KnownDevice] { book.networks[network]?.devices ?? [] }
    public func device(mac: String, network: String) -> KnownDevice? { book.device(mac: mac, network: network) }
}
