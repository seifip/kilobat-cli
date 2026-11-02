import Foundation

// Connect your router: per-device usage for every device at home, read from the router's own local
// interface. Nothing is installed or changed on the router; Kilobat only reads.
//
// What each router really tells, per device or for the whole home (see RESEARCH-DECISIONS, "Connect your router"):
// - FRITZ!Box (TR-064): the device list (names, addresses, MACs, online or not), the internet line's totals and live
//   rate, and the box's uptime. No per-device traffic: TR-064 documents none. Kilobat names what it can (this Mac,
//   paired Macs) and shows the rest as "other devices".
// - UniFi Network: the official Integrations API lists clients without traffic; the controller's older API
//   (stat/sta) has each client's bytes and rates.
// - MikroTik RouterOS 7: leases and interface counters always; per-device bytes once Kid Control has a profile, or
//   from simple queues with one address each.
// - OpenWrt: host names and interface counters over ubus; per-device bytes when nlbwmon is installed.
// - Anything else: the UPnP whole-router counters, whole home only.

/// The routers Kilobat can read.
public enum RouterKind: String, Codable, Sendable, CaseIterable {
    case fritzbox, unifi, mikrotik, openwrt
    /// UPnP IGD counters: any router that shares them, whole home only.
    case upnp

    public var name: String {
        switch self {
        case .fritzbox: "FRITZ!Box"
        case .unifi: "UniFi"
        case .mikrotik: "MikroTik"
        case .openwrt: "OpenWrt"
        case .upnp: String(localized: "Other router (UPnP)", comment: "Router kind: any router that shares UPnP traffic counters")
        }
    }
    /// The four Kilobat signs in to; UPnP needs no account.
    public static let connectable: [RouterKind] = [.fritzbox, .unifi, .mikrotik, .openwrt]

    /// Where to reach it first, from the router's address.
    public func defaultURL(gateway: String) -> String {
        switch self {
        case .fritzbox: "http://\(gateway):49000"
        case .unifi: "https://\(gateway)"
        case .mikrotik: "https://\(gateway)"
        case .openwrt: "http://\(gateway)"
        case .upnp: "http://\(gateway)"
        }
    }
    /// UniFi signs in with an API key; the others with a user and password.
    public var usesUser: Bool { self != .unifi && self != .upnp }
}

/// One device as the router lists it, with its counters when the router keeps them.
public struct RouterClient: Codable, Sendable, Equatable {
    /// Normalised, `aa:bb:cc:dd:ee:ff`.
    public var mac: String
    public var address: String?
    /// The name the router knows it by: its DHCP host name, or a name given on the router.
    public var name: String?
    /// Connected now, as the router sees it.
    public var active: Bool
    /// Bytes to and from the device since the router began counting (a connection, a boot or an accounting period).
    public var down: UInt64?
    public var up: UInt64?
    /// Bytes a second, when the router reports a rate itself.
    public var downRate: Double?
    public var upRate: Double?
    public init(mac: String, address: String? = nil, name: String? = nil, active: Bool = true, down: UInt64? = nil, up: UInt64? = nil,
                downRate: Double? = nil, upRate: Double? = nil) {
        self.mac = mac; self.address = address; self.name = name; self.active = active; self.down = down; self.up = up; self.downRate = downRate; self.upRate = upRate
    }
    public var counted: Bool { (down != nil && up != nil) || (downRate != nil && upRate != nil) }
}

/// The internet line as the router counts it: the whole home.
public struct RouterWAN: Codable, Sendable, Equatable {
    public var down: UInt64?
    public var up: UInt64?
    public var downRate: Double?
    public var upRate: Double?
    /// 32 for TR-064's and UPnP's counters, which wrap at 4 GiB; 64 otherwise.
    public var bits = 64
    public init(down: UInt64? = nil, up: UInt64? = nil, downRate: Double? = nil, upRate: Double? = nil, bits: Int = 64) {
        self.down = down; self.up = up; self.downRate = downRate; self.upRate = upRate; self.bits = bits
    }
}

/// The router's firmware as its own API reports it, and whether a newer one is out. Kilobat only reads this and
/// links to the update screen or the maker's page; it never starts an update.
public struct RouterFirmware: Codable, Sendable, Equatable {
    /// FRITZ!OS, RouterOS, OpenWrt or UniFi firmware.
    public var product: String
    public var installed: String?
    public var available: String?
    public var updateAvailable: Bool
    /// The router's own update screen, or the maker's page.
    public var url: String?
    /// router: the router said so; openwrt.org: OpenWrt's published release list.
    public var source: String
    public init(product: String, installed: String?, available: String?, updateAvailable: Bool, url: String?, source: String = "router") {
        self.product = product; self.installed = installed; self.available = available; self.updateAvailable = updateAvailable; self.url = url; self.source = source
    }

    /// "FRITZ!OS 8.10 is available; you’re on 8.02." Nil when there's nothing to say.
    public var line: String? {
        guard updateAvailable else { return nil }
        switch (available, installed) {
        case let (available?, installed?): return String(localized: "\(product) \(available) is available; you’re on \(installed).", comment: "Router firmware reminder; the arguments are a firmware name such as FRITZ!OS and two versions")
        case let (available?, nil): return String(localized: "\(product) \(available) is available.", comment: "Router firmware reminder; the arguments are a firmware name and a version")
        default: return String(localized: "A \(product) update is available.", comment: "Router firmware reminder; the argument is a firmware name such as RouterOS")
        }
    }

    /// "7.16.2" against "7.16.1" (or "7.16"), number by number; false when either isn't dotted numbers.
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        func numbers(_ text: String) -> [Int]? {
            let parts = text.split(separator: " ").first.map { $0.split(separator: ".").map { Int($0) } } ?? []
            guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
            return parts.compactMap { $0 }
        }
        guard var a = numbers(candidate), var b = numbers(installed) else { return false }
        while a.count < b.count { a.append(0) }
        while b.count < a.count { b.append(0) }
        return b.lexicographicallyPrecedes(a)
    }

    /// FRITZ!OS's "154.08.10" as the box shows it, "8.10"; other versions as they are.
    public static func fritzVersion(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ".")
        guard parts.count == 3, let first = Int(parts[0]), first > 99, let major = Int(parts[1]) else { return raw }
        return "\(major).\(parts[2])"
    }
}

/// OpenWrt's own list of releases (downloads.openwrt.org/.versions.json, as its firmware selector reads it): the
/// newest release in the installed series, else the current stable one.
public struct OpenWrtReleases: Codable, Sendable, Equatable {
    public var stable: String
    public var oldstable: String?
    public var versions: [String]
    public static let url = URL(string: "https://downloads.openwrt.org/.versions.json")!
    public init(stable: String, oldstable: String? = nil, versions: [String] = []) { self.stable = stable; self.oldstable = oldstable; self.versions = versions }

    public static func parse(_ data: Data) -> OpenWrtReleases? {
        guard let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let stable = value["stable_version"] as? String, number(stable) != nil else { return nil }
        return OpenWrtReleases(stable: stable, oldstable: (value["oldstable_version"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                               versions: (value["versions_list"] as? [String]) ?? [])
    }

    /// "24.10.0" as numbers; nil for anything else (a snapshot, a release candidate, a vendor's own build).
    static func number(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".").map { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    /// The release to suggest over `installed`: a newer point release of its own series first; the stable release
    /// only once the installed series is neither stable nor oldstable (no longer supported). Nil when it's current,
    /// or when `installed` isn't a plain release Kilobat can compare.
    public func newer(than installed: String) -> String? {
        guard let mine = Self.number(installed) else { return nil }
        func sameSeries(_ other: [Int]) -> Bool { other[0] == mine[0] && other[1] == mine[1] }
        let series = (versions + [stable] + [oldstable].compactMap { $0 }).compactMap { version in Self.number(version).map { (version, $0) } }.filter { sameSeries($0.1) }
        if let latest = series.max(by: { $0.1.lexicographicallyPrecedes($1.1) }), mine.lexicographicallyPrecedes(latest.1) { return latest.0 }
        let supported = [stable, oldstable].compactMap { $0.flatMap(Self.number) }.contains(where: sameSeries)
        if !supported, let top = Self.number(stable), mine.lexicographicallyPrecedes(top) { return stable }
        return nil
    }
}

/// What one read of the router returned.
public struct RouterPoll: Sendable, Equatable {
    public var date: Date
    public var clients: [RouterClient]
    public var wan: RouterWAN?
    /// Seconds since the router booted, when it says.
    public var uptime: TimeInterval?
    public var model: String?
    public var firmware: String?
    /// The router counts traffic per device.
    public var perDevice: Bool
    /// Why something is missing, as codes the report explains: rights, nlbwmon, kidControl, legacyAPI.
    public var missing: [String] = []
    /// The firmware and whether the router says an update is out; nil when its API doesn't say.
    public var update: RouterFirmware? = nil
    /// OpenWrt's distribution and release version, compared with OpenWrt's release list by the store.
    public var release: (distribution: String, version: String)? = nil
    public static func == (a: RouterPoll, b: RouterPoll) -> Bool {
        a.date == b.date && a.clients == b.clients && a.wan == b.wan && a.uptime == b.uptime && a.model == b.model && a.firmware == b.firmware
            && a.perDevice == b.perDevice && a.missing == b.missing && a.update == b.update && a.release?.distribution == b.release?.distribution && a.release?.version == b.release?.version
    }
    public init(date: Date = Date(), clients: [RouterClient], wan: RouterWAN? = nil, uptime: TimeInterval? = nil, model: String? = nil, firmware: String? = nil,
                perDevice: Bool, missing: [String] = []) {
        self.date = date; self.clients = clients; self.wan = wan; self.uptime = uptime; self.model = model; self.firmware = firmware
        self.perDevice = perDevice; self.missing = missing
    }
}

/// A connected router, saved per network in router.json. The password or API key is in the Keychain, never here.
public struct RouterConnection: Codable, Sendable, Equatable, Identifiable {
    public enum Auth: String, Codable, Sendable { case password, apiKey, account }
    public var id: String
    public var kind: RouterKind
    /// The network key it belongs to, and that network's name.
    public var network: String
    public var networkName: String
    /// Where requests go: scheme, a local IPv4 address and port, resolved once when connecting.
    public var url: String
    /// What the person typed, to show it back.
    public var entered: String
    public var user: String?
    public var auth: Auth
    /// The router's own certificate, confirmed by the person (SHA-256, lowercase hex).
    public var pin: String?
    /// UniFi: the site's id for the official API and its short name for the older one.
    public var site: String?
    public var siteName: String?
    public var model: String?
    public var firmware: String?
    public var connected: Date
    public init(id: String = UUID().uuidString, kind: RouterKind, network: String, networkName: String, url: String, entered: String, user: String? = nil,
                auth: Auth = .password, pin: String? = nil, connected: Date = Date()) {
        self.id = id; self.kind = kind; self.network = network; self.networkName = networkName; self.url = url; self.entered = entered; self.user = user
        self.auth = auth; self.pin = pin; self.connected = connected
    }
    public var base: URL? { URL(string: url) }
}

/// Byte counters into amounts and rates: the change since the last read, with a counter that went back counted as
/// a reset (a reconnect, a reboot, a new accounting period) and a 32-bit one near its top as a wrap.
public struct RouterMeter: Sendable, Equatable {
    struct Mark: Sendable, Equatable { var date: Date; var down: UInt64; var up: UInt64 }
    var marks: [String: Mark] = [:]
    /// No home line moves more than this; a bigger jump is a counter that changed meaning, not traffic.
    public static let ceiling: Double = 1_250_000_000
    public init() {}

    public static func delta(from old: UInt64, to new: UInt64, bits: Int = 64) -> UInt64 {
        if new >= old { return new - old }
        if bits == 32, old <= UInt64(UInt32.max), new <= UInt64(UInt32.max), old > UInt64(UInt32.max) / 2 { return (UInt64(UInt32.max) - old) + new + 1 }
        return new
    }

    /// The bytes moved since the last read of `key` and the rate over that time; nil for the first read, or a gap
    /// too long or a jump too big to trust.
    public mutating func step(_ key: String, down: UInt64, up: UInt64, at date: Date, bits: Int = 64, longest: TimeInterval = 3600)
        -> (down: UInt64, up: UInt64, downRate: Double, upRate: Double)? {
        defer { marks[key] = Mark(date: date, down: down, up: up) }
        guard let last = marks[key], date > last.date else { return nil }
        let seconds = date.timeIntervalSince(last.date)
        guard seconds <= longest else { return nil }
        let d = Self.delta(from: last.down, to: down, bits: bits), u = Self.delta(from: last.up, to: up, bits: bits)
        guard Double(d) / seconds <= Self.ceiling, Double(u) / seconds <= Self.ceiling else { return nil }
        return (d, u, Double(d) / seconds, Double(u) / seconds)
    }

    /// Forgets devices not read for a day.
    public mutating func prune(now: Date) { marks = marks.filter { now.timeIntervalSince($0.value.date) < 86_400 } }
}

/// Each device's bytes per day, and the whole home's, for 30 days: home-usage.json on this Mac.
public struct HomeUsageLedger: Codable, Sendable, Equatable {
    public struct Total: Codable, Sendable, Equatable {
        public var down: UInt64
        public var up: UInt64
        public init(down: UInt64 = 0, up: UInt64 = 0) { self.down = down; self.up = up }
        public var bytes: UInt64 { down + up }
    }
    /// The whole home's line, beside the MAC addresses.
    public static let home = "home"
    public static let keepDays = 30
    /// "2026-11-01" in the Mac's calendar → MAC (or `home`) → bytes.
    public var days: [String: [String: Total]] = [:]
    public init() {}

    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public mutating func add(_ key: String, down: UInt64, up: UInt64, at date: Date, calendar: Calendar = .current, network: String? = nil) {
        let key = network.map { "network:\($0):\(key)" } ?? key
        guard down > 0 || up > 0 else { return }
        let day = Self.day(date, calendar: calendar)
        var total = days[day]?[key] ?? Total()
        total.down += down; total.up += up
        days[day, default: [:]][key] = total
    }

    public func total(_ key: String, on date: Date, calendar: Calendar = .current) -> Total? { days[Self.day(date, calendar: calendar)]?[key] }
    public func today(now: Date = Date(), calendar: Calendar = .current, network: String? = nil) -> [String: Total] {
        let totals = days[Self.day(now, calendar: calendar)] ?? [:]
        guard let network else { return totals }
        let prefix = "network:\(network):"
        return Dictionary(uniqueKeysWithValues: totals.compactMap { key, value in
            key.hasPrefix(prefix) ? (String(key.dropFirst(prefix.count)), value) : nil
        })
    }

    /// Days older than 30 go.
    public mutating func prune(now: Date = Date(), calendar: Calendar = .current) {
        guard let cutoff = calendar.date(byAdding: .day, value: -(Self.keepDays - 1), to: calendar.startOfDay(for: now)) else { return }
        let oldest = Self.day(cutoff, calendar: calendar)
        days = days.filter { $0.key >= oldest }
    }
}

/// What `kilobat router devices --json`, MCP get_home_usage and the Devices tab show: each device's rates now and
/// today's bytes, with what was measured and how.
public struct HomeUsageReport: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// No router connected for this network.
        case notConnected
        /// The network isn't marked as home, so Kilobat doesn't read the router here.
        case notHome
        /// Reading the router is part of Kilobat Pro.
        case needsPro
        case connecting, ok
        /// The router turned the saved password down, or the certificate changed: it needs the person.
        case needsAttention
        case error
    }
    public struct Router: Codable, Sendable, Equatable {
        public var kind: RouterKind
        public var name: String
        public var model: String?
        public var firmware: String?
        public var address: String
        /// perDevice: the router counts each device; wholeHome: only the line.
        public var measures: String
        public var uptimeSeconds: Double?
        public var missing: [String]
        /// The installed firmware and whether an update is out, when the router's API says; Kilobat never installs one.
        public var update: RouterFirmware?
        public init(kind: RouterKind, name: String, model: String?, firmware: String?, address: String, measures: String, uptimeSeconds: Double?, missing: [String],
                    firmware update: RouterFirmware? = nil) {
            self.kind = kind; self.name = name; self.model = model; self.firmware = firmware; self.address = address; self.measures = measures
            self.uptimeSeconds = uptimeSeconds; self.missing = missing; self.update = update
        }
    }
    public struct Device: Codable, Sendable, Equatable {
        public var mac: String
        public var name: String
        public var address: String?
        public var active: Bool
        /// Bytes a second now; nil when nothing measured this device.
        public var down: Double?
        public var up: Double?
        public var todayDown: UInt64?
        public var todayUp: UInt64?
        /// router, thisMac or pairedMac: where the numbers came from.
        public var source: String?
        public var thisMac: Bool
        public var pairedMac: Bool
        /// A paired Mac's busiest apps, as it reported them.
        public var apps: [String]?
        public init(mac: String, name: String, address: String?, active: Bool, down: Double? = nil, up: Double? = nil, todayDown: UInt64? = nil, todayUp: UInt64? = nil,
                    source: String? = nil, thisMac: Bool = false, pairedMac: Bool = false, apps: [String]? = nil) {
            self.mac = mac; self.name = name; self.address = address; self.active = active; self.down = down; self.up = up; self.todayDown = todayDown; self.todayUp = todayUp
            self.source = source; self.thisMac = thisMac; self.pairedMac = pairedMac; self.apps = apps
        }
        public var rate: Double { (down ?? 0) + (up ?? 0) }
    }
    public struct Line: Codable, Sendable, Equatable {
        public var down: Double?
        public var up: Double?
        public var todayDown: UInt64?
        public var todayUp: UInt64?
        public init(down: Double? = nil, up: Double? = nil, todayDown: UInt64? = nil, todayUp: UInt64? = nil) { self.down = down; self.up = up; self.todayDown = todayDown; self.todayUp = todayUp }
    }
    public var state: State
    public var network: String?
    public var router: Router?
    public var updated: Date?
    public var error: String?
    /// The whole home's line now and today.
    public var home: Line?
    public var devices: [Device]
    /// Without per-device counters: the line minus what Kilobat could name.
    public var others: Line?
    /// One or two sentences on what was measured and what wasn't.
    public var note: String
    public var pro: Bool
    public var appRunning: Bool? = nil
    public init(state: State, network: String? = nil, router: Router? = nil, updated: Date? = nil, error: String? = nil, home: Line? = nil, devices: [Device] = [],
                others: Line? = nil, note: String, pro: Bool) {
        self.state = state; self.network = network; self.router = router; self.updated = updated; self.error = error; self.home = home; self.devices = devices
        self.others = others; self.note = note; self.pro = pro
    }

    /// What the numbers mean for this router.
    public static func note(kind: RouterKind?, perDevice: Bool, missing: [String]) -> String {
        guard let kind else { return String(localized: "Connect your router in Kilobat › Devices to see every device’s usage, not just this Mac’s.", comment: "Home usage note when no router is connected") }
        if perDevice {
            switch kind {
            case .openwrt: return String(localized: "Each device’s traffic comes from nlbwmon on the router, which counts in steps of about 30 seconds.", comment: "Home usage note")
            case .unifi: return String(localized: "UniFi’s device counters can include local-network transfers; they don’t isolate each device’s internet usage.", comment: "Home usage note: client counters are not WAN-only")
            case .mikrotik: return missing.contains("queues") ? String(localized: "Only devices with their own simple queue are counted. Queue traffic can include local transfers and omit traffic that bypasses queues; it isn’t an internet-only total.", comment: "Home usage note: RouterOS queue limitations")
                : String(localized: "Each device’s traffic comes from the router’s Kid Control list. These counters aren’t verified as internet-only totals.", comment: "Home usage note: RouterOS counter scope")
            default: return String(localized: "Each device’s traffic comes from the router’s own counters.", comment: "Home usage note")
            }
        }
        var parts: [String] = []
        switch kind {
        case .fritzbox: parts.append(String(localized: "A FRITZ!Box tells which devices are online and the whole line’s traffic, not each device’s. Kilobat names this Mac and paired Macs; the rest is other devices.", comment: "Home usage note"))
        case .unifi: parts.append(String(localized: "UniFi’s official API lists clients without their traffic, and its older API didn’t answer, so this is the whole line only.", comment: "Home usage note"))
        case .mikrotik: parts.append(String(localized: "RouterOS counts each device once Kid Control has a profile (IP › Kid Control). Until then this is the whole line.", comment: "Home usage note"))
        case .openwrt: parts.append(String(localized: "Per-device traffic needs nlbwmon on the router (luci-app-nlbwmon). Until then this is the whole line.", comment: "Home usage note"))
        case .upnp: parts.append(String(localized: "UPnP counters cover the whole home only.", comment: "Home usage note"))
        }
        if missing.contains("rights") { parts.append(String(localized: "This router user can’t read everything; give it more rights for the line’s totals and uptime.", comment: "Home usage note")) }
        return parts.joined(separator: " ")
    }
}

/// Router devices beside what Kilobat already knows: the person's names from devices.json (keyed by MAC), paired
/// Macs' own reports (matched by address) and this Mac. Pure, so the merge can be tested.
public enum HomeUsageMerge {
    public struct Rate: Sendable, Equatable { public var down: Double; public var up: Double; public init(down: Double, up: Double) { self.down = down; self.up = up } }
    public struct ThisMac: Sendable, Equatable {
        public var mac: String?; public var address: String?; public var down: Double; public var up: Double
        public init(mac: String?, address: String?, down: Double, up: Double) { self.mac = mac; self.address = address; self.down = down; self.up = up }
    }

    public static func devices(clients: [RouterClient], rates: [String: Rate], today: [String: HomeUsageLedger.Total], known: DeviceNetwork?,
                               peers: [HouseholdLive], thisMac: ThisMac?, perDevice: Bool, now: Date = Date()) -> [HomeUsageReport.Device] {
        let fresh = peers.filter { $0.fresh(now: now) }
        var rows: [HomeUsageReport.Device] = []
        var seen: Set<String> = []
        for client in clients {
            guard let mac = MACAddress.normalized(client.mac), MACAddress.unicast(mac), !seen.contains(mac) else { continue }
            let rate = rates[mac], total = today[mac]
            guard client.active || rate != nil || total != nil else { continue }
            seen.insert(mac)
            let device = known?.index(of: mac).map { known!.devices[$0] }
            let peer = client.address.flatMap { address in fresh.first { $0.address == address } }
            let mine = thisMac.map { ($0.mac.flatMap(MACAddress.normalized) == mac) || ($0.address != nil && $0.address == client.address) } ?? false
            var row = HomeUsageReport.Device(mac: mac, name: name(device: device, peer: peer, client: client), address: client.address ?? device?.address, active: client.active,
                                             thisMac: mine, pairedMac: peer != nil, apps: peer.map(\.summary.apps))
            if perDevice, let rate {
                row.down = rate.down; row.up = rate.up; row.source = "router"
            } else if mine, let thisMac {
                row.down = thisMac.down; row.up = thisMac.up; row.source = "thisMac"
            } else if let peer {
                row.down = peer.summary.down; row.up = peer.summary.up; row.source = "pairedMac"
            }
            if perDevice, let total { row.todayDown = total.down; row.todayUp = total.up }
            rows.append(row)
        }
        return rows.sorted { a, b in
            if a.rate != b.rate { return a.rate > b.rate }
            let ta = (a.todayDown ?? 0) + (a.todayUp ?? 0), tb = (b.todayDown ?? 0) + (b.todayUp ?? 0)
            if ta != tb { return ta > tb }
            if a.active != b.active { return a.active }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The person's name, a paired Mac's own, the device's own, the router's, then its maker.
    static func name(device: KnownDevice?, peer: HouseholdLive?, client: RouterClient) -> String {
        if let name = device?.name, !name.isEmpty { return name }
        if let peer { return peer.summary.name }
        if let own = DeviceNames.readable(device?.hostname) { return own }
        if let routers = DeviceNames.readable(client.name) { return routers }
        if let device { return device.label }
        return client.address ?? client.mac
    }

    /// The line minus what's named, when the router has no per-device counters.
    public static func others(home: HomeUsageReport.Line?, devices: [HomeUsageReport.Device]) -> HomeUsageReport.Line? {
        guard let home, let down = home.down, let up = home.up else { return nil }
        let named = devices.reduce((0.0, 0.0)) { ($0.0 + ($1.down ?? 0), $0.1 + ($1.up ?? 0)) }
        return .init(down: max(0, down - named.0), up: max(0, up - named.1))
    }
}

/// `kilobat router`: the check-up as before, and connect (the steps only), devices and disconnect.
public enum RouterCommand: Equatable, Sendable {
    case checkup(RouterReport.Options)
    case connect(kind: RouterKind?, json: Bool)
    case devices(json: Bool)
    case disconnect(json: Bool)

    public static let usage = "Use router [--all] [--json], router connect [fritzbox|unifi|mikrotik|openwrt], router devices [--json] or router disconnect."

    /// `args` starts with "router". A piped run appends --json.
    public static func parse(_ args: [String]) throws -> RouterCommand {
        let rest = Array(args.dropFirst())
        let json = rest.contains("--json")
        let words = rest.filter { $0 != "--json" }
        switch words.first {
        case "connect":
            guard words.count <= 2 else { throw DiagnosticError(usage) }
            guard words.count == 2 else { return .connect(kind: nil, json: json) }
            guard let kind = RouterKind(rawValue: words[1].lowercased().replacingOccurrences(of: "!", with: "")), kind != .upnp else {
                throw DiagnosticError("Unknown router '\(words[1])'. " + usage)
            }
            return .connect(kind: kind, json: json)
        case "devices":
            guard words.count == 1 else { throw DiagnosticError(usage) }
            return .devices(json: json)
        case "disconnect":
            guard words.count == 1 else { throw DiagnosticError(usage) }
            return .disconnect(json: json)
        default:
            do { return .checkup(try RouterReport.Options.parse(args)) } catch { throw DiagnosticError(usage) }
        }
    }
}

/// The setup steps, for the sheet and `kilobat router connect`: a dedicated user with as few rights as will do, and
/// what each router needs turned on for per-device numbers.
public enum RouterSetup {
    public static func steps(_ kind: RouterKind) -> [String] {
        switch kind {
        case .fritzbox: [
            String(localized: "On the FRITZ!Box, open System › FRITZ!Box Users and add a user just for Kilobat, such as “kilobat”, with a password of its own.", comment: "FRITZ!Box setup step"),
            String(localized: "Give it the FRITZ!Box Settings right, and leave access from the internet off. That right is needed for the line’s totals and uptime; with only the Voice messages right Kilobat still sees the device list and the line’s speed.", comment: "FRITZ!Box setup step"),
            String(localized: "Check that Home Network › Network › Network Settings › Allow access for applications is on.", comment: "FRITZ!Box setup step"),
            String(localized: "In Kilobat › Devices, choose Connect your router, enter that user and password, and trust the box’s certificate when its fingerprint matches.", comment: "FRITZ!Box setup step"),
        ]
        case .unifi: [
            String(localized: "In UniFi Network 9.3 or later, open Settings › Control Plane › Integrations and create an API key for Kilobat.", comment: "UniFi setup step"),
            String(localized: "In Kilobat › Devices, choose Connect your router and paste the key. It reads the client list, and each client’s traffic from the controller’s own statistics.", comment: "UniFi setup step"),
            String(localized: "Older UniFi Network without Integrations: sign in with a local admin account instead (not your UI account with two-factor sign-in).", comment: "UniFi setup step"),
            String(localized: "Trust the console’s own certificate when its fingerprint matches the one in your browser’s certificate details.", comment: "UniFi setup step"),
        ]
        case .mikrotik: [
            String(localized: "RouterOS 7 serves its REST API over the www-ssl service. In IP › Services, turn on www-ssl with a certificate (System › Certificates). Use its HTTPS address to keep your sign-in encrypted.", comment: "MikroTik setup step"),
            String(localized: "Add a group with only the read and rest-api policies (System › Users › Groups), then a user in it for Kilobat.", comment: "MikroTik setup step"),
            String(localized: "For each device’s traffic, add a profile in IP › Kid Control with no limits: the Devices tab there then counts every device. Simple queues with one address each work too.", comment: "MikroTik setup step"),
            String(localized: "In Kilobat › Devices, choose Connect your router and enter the user. Compare the certificate’s fingerprint with System › Certificates before you trust it.", comment: "MikroTik setup step"),
        ]
        case .openwrt: [
            String(localized: "Kilobat reads OpenWrt through LuCI’s ubus interface, as the web interface does, and signs in as root or a user you set up in /etc/config/rpcd.", comment: "OpenWrt setup step"),
            String(localized: "For each device’s traffic, install nlbwmon: System › Software, then luci-app-nlbwmon. Without it Kilobat shows the whole line.", comment: "OpenWrt setup step"),
            String(localized: "With luci-ssl, compare the certificate’s fingerprint with /etc/uhttpd.crt before you trust it.", comment: "OpenWrt setup step"),
            String(localized: "In Kilobat › Devices, choose Connect your router and enter the user and password.", comment: "OpenWrt setup step"),
        ]
        case .upnp: [
            String(localized: "Turn on UPnP status information on the router. Kilobat reads its traffic counters without an account; they cover the whole home only.", comment: "UPnP setup step"),
        ]
        }
    }

    /// The promise the sheet and the CLI make.
    public static let privacy = String(localized: "Kilobat only reads, and installs nothing on the router. It talks to the router only on your home network, and the password stays in this Mac’s Keychain.", comment: "Router setup privacy line")
}
