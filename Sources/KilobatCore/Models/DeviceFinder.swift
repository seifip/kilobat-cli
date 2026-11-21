import Foundation

/// One device found on a device's own Wi-Fi: usually the device itself is the network's router.
public struct FoundDevice: Codable, Equatable, Sendable, Identifiable {
    public var id: String { address }
    public var address: String
    public var mac: String?
    /// Its host name: the router's DHCP name, mDNS or reverse DNS ("GO2-8A2C1F.local").
    public var hostname: String?
    /// The names it announces over Bonjour, such as "Shelly Plug S" or a camera's.
    public var names: [String] = []
    /// Bonjour service types it announces, such as `_rtsp._tcp`.
    public var services: [String] = []
    /// The common ports that answered.
    public var ports: [PortScan.Service] = []
    /// It's the network's router: on a device's own Wi-Fi, almost always the device.
    public var gateway: Bool = false
    /// The ports were checked and nothing at all came back.
    public var silent: Bool = false
    public var maker: String?

    public init(address: String, mac: String? = nil, hostname: String? = nil, names: [String] = [], services: [String] = [], ports: [PortScan.Service] = [],
                gateway: Bool = false, silent: Bool = false, maker: String? = nil) {
        self.address = address; self.mac = mac; self.hostname = hostname; self.names = names; self.services = services; self.ports = ports
        self.gateway = gateway; self.silent = silent; self.maker = maker
    }

    /// What to call it: what it announces, its host name, its maker, or its address.
    public var title: String { names.first ?? hostname ?? maker ?? address }
    /// The web page to open, by DeviceFinder's preference.
    public var webURL: URL? { DeviceFinder.webURL(address: address, ports: ports) }
    /// A live video stream, such as a camera's.
    public var rtsp: Bool { ports.contains { $0.port == 554 } || services.contains("_rtsp._tcp") }
}

/// The finder's answer for one network.
public struct DeviceFinding: Codable, Equatable, Sendable {
    public var date: Date
    public var network: String?
    public var devices: [FoundDevice]
    public init(date: Date = Date(), network: String?, devices: [FoundDevice]) { self.date = date; self.network = network; self.devices = devices }
    /// The device to lead with: the router when it answers, else whatever has a web page, else the first.
    public var main: FoundDevice? {
        devices.first { $0.gateway && !$0.silent } ?? devices.first { $0.webURL != nil } ?? devices.first
    }
}

/// "Where's my device?": on a device's own Wi-Fi, the device's address, its names and the ports that answer, from the
/// same discovery the Devices tab uses (the neighbour cache after a light sweep, Bonjour, and the open-ports check).
/// Only on this Mac's own subnet; nothing is sent beyond one connection attempt per port.
public enum DeviceFinder {
    /// The ports devices' own networks use: web pages, video (RTSP), remote login, smart-home messages (MQTT), FTP.
    public static let ports: [UInt16] = [80, 443, 8080, 8443, 8000, 5000, 554, 22, 23, 21, 1883]
    public static var services: [PortScan.Service] { PortScan.common.filter { ports.contains($0.port) } }
    /// At most this many devices besides the router get their ports checked.
    public static let checkedPeers = 3

    /// The web page a browser should open first: https before http, standard ports before others.
    public static func webURL(address: String, ports: [PortScan.Service]) -> URL? {
        let preference: [UInt16] = [443, 80, 8443, 8080, 8000, 5000]
        guard let best = preference.compactMap({ port in ports.first { $0.port == port && $0.web != nil } }).first else { return nil }
        let standard = (best.web == "http" && best.port == 80) || (best.web == "https" && best.port == 443)
        return URL(string: "\(best.web ?? "http")://\(address)" + (standard ? "" : ":\(best.port)"))
    }

    /// One row per address: the neighbour cache's devices and the router, with what Bonjour and the port check said.
    /// The router first, then devices with something open, then the rest by address.
    public static func merge(gateway: String?, neighbours: [(address: String, mac: String?, hostname: String?)], bonjour: [BonjourService],
                             reports: [String: PortReport], makers: [String: String] = [:]) -> [FoundDevice] {
        var rows: [String: FoundDevice] = [:]
        if let gateway { rows[gateway] = FoundDevice(address: gateway, gateway: true) }
        for neighbour in neighbours {
            var row = rows[neighbour.address] ?? FoundDevice(address: neighbour.address)
            row.mac = row.mac ?? neighbour.mac
            row.hostname = row.hostname ?? neighbour.hostname.map(clean)
            rows[neighbour.address] = row
        }
        for service in bonjour {
            for address in Set(service.addresses) where rows[address] != nil || address == gateway {
                var row = rows[address] ?? FoundDevice(address: address, gateway: address == gateway)
                let name = service.name.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !row.names.contains(name) { row.names.append(name) }
                if !row.services.contains(service.type) { row.services.append(service.type) }
                if row.hostname == nil, let host = service.host { row.hostname = clean(host) }
                rows[address] = row
            }
        }
        for (address, report) in reports {
            guard var row = rows[address] else { continue }
            row.ports = report.open; row.silent = report.silentDevice || report.unreachableDevice
            rows[address] = row
        }
        for (address, maker) in makers { rows[address]?.maker = maker }
        return rows.values.sorted { a, b in
            if a.gateway != b.gateway { return a.gateway }
            if a.ports.isEmpty != b.ports.isEmpty { return !a.ports.isEmpty }
            return (PortScan.ipv4(a.address) ?? 0) < (PortScan.ipv4(b.address) ?? 0)
        }
    }

    /// "GO2-8A2C1F.local." as "GO2-8A2C1F.local".
    static func clean(_ host: String) -> String {
        var host = host.trimmingCharacters(in: .whitespaces)
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    /// Runs the whole look: about four seconds (the sweep, Bonjour and the ports run side by side).
    public static func run(network: String?, gateway: String?, interface: String?) async -> DeviceFinding {
        guard let interface else { return DeviceFinding(network: network, devices: []) }
        async let scan = LANScan.run(gateway: gateway, interface: interface, sweep: true, known: [])
        async let announced = BonjourBrowse.run(seconds: 3, limit: 40)
        let found = await scan
        let neighbours = found.sightings.map { (address: $0.address, mac: Optional($0.mac), hostname: $0.hostname) }
        let subnets = [LANScan.subnet(interface: interface)].compactMap { $0 }
        let targets = ([gateway].compactMap { $0 } + neighbours.map(\.address).filter { $0 != gateway }.prefix(checkedPeers))
        var reports: [String: PortReport] = [:]
        await withTaskGroup(of: (String, PortReport?).self) { group in
            for address in targets {
                group.addTask { (address, try? await PortScan.check(address, subnets: subnets, services: services)) }
            }
            for await (address, report) in group { if let report { reports[address] = report } }
        }
        var makers: [String: String] = [:]
        for sighting in found.sightings { if let maker = DeviceVendors.shared.vendor(for: sighting.mac) { makers[sighting.address] = maker } }
        if let gateway, let router = found.router, let maker = DeviceVendors.shared.vendor(for: router) { makers[gateway] = maker }
        let bonjour = await announced
        return DeviceFinding(network: network, devices: merge(gateway: gateway, neighbours: neighbours, bonjour: bonjour, reports: reports, makers: makers))
    }
}
