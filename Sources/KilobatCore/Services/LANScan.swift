import Foundation
import Darwin

/// A light look at who is on the local network. macOS's neighbour cache only holds devices this Mac talked to, so a
/// sweep first sends one empty UDP datagram to the discard port of each address in the Mac's own subnet (254 at
/// most, a few milliseconds apart): the Mac's ARP request for each address is what fills the cache, and nothing is
/// expected back. Names come from the router's DNS and Bonjour, asked only about devices not seen before. What each
/// device is comes from the Bonjour services it announces and its UPnP description (`signals`). Nothing leaves the
/// local network.
public enum LANScan {
    public struct Result: Sendable {
        public let rows: [LANDevice]
        public let sightings: [DeviceSighting]
        /// The router's MAC address, when the cache has it.
        public let router: String?
    }

    /// Sweeps when asked, reads the neighbour cache on the router's interface (`interface` when the cache doesn't have
    /// the router yet), and names the devices `known` doesn't contain. With `described`, it also browses Bonjour and
    /// asks UPnP who is there, fetching the UPnP descriptions of devices not in `described` (eight at most).
    /// `widest` is the widest block swept around this Mac, as a prefix length: 24 for the usual look, down to
    /// `widestSweep` when the person asks for the whole network.
    public static func run(gateway: String?, interface fallback: String?, sweep: Bool, widest: Int = 24, known: Set<String>, described: Set<String>? = nil) async -> Result {
        var rows = await ExpertTools.devices()
        guard let interface = gateway.flatMap({ gateway in rows.first { $0.address == gateway }?.interface }) ?? fallback else { return Result(rows: rows, sightings: [], router: nil) }
        if sweep, let subnet = subnet(interface: interface) {
            await touch(hosts(address: subnet.address, mask: subnet.mask, widest: widest))
            try? await Task.sleep(for: .milliseconds(1500))
            rows = await ExpertTools.devices()
        }
        var sightings = sightings(rows, interface: interface, own: ownMACs())
        let router = gateway.flatMap { gateway in rows.first { $0.address == gateway }.flatMap { MACAddress.normalized($0.mac) } }
        let unnamed = sightings.indices.filter { !known.contains(sightings[$0].mac) }.prefix(12)
        async let announced: [BonjourService] = described == nil ? [] : BonjourBrowse.run()
        async let replies: [SSDPDiscovery.Reply] = described == nil ? [] : SSDPDiscovery.search()
        await withTaskGroup(of: (Int, String?).self) { group in
            for (offset, index) in unnamed.enumerated() {
                let address = sightings[index].address
                group.addTask {
                    // A few at a time, so a new router's whole household doesn't start dozens of lookups at once.
                    try? await Task.sleep(for: .milliseconds(250 * (offset / 4)))
                    return (index, await hostname(for: address, router: gateway))
                }
            }
            for await (index, name) in group { sightings[index].hostname = name }
        }
        if let described {
            let services = BonjourBrowse.byAddress(await announced), ssdp = await replies
            let descriptions = await describe(ssdp, sightings: sightings, skip: described)
            for index in sightings.indices {
                let address = sightings[index].address
                let targets = ssdp.filter { $0.address == address }.compactMap(\.target)
                sightings[index].signals = DeviceSignals.from(services: services[address] ?? [], upnp: descriptions[address], targets: targets)
            }
        }
        return Result(rows: rows, sightings: sightings, router: router)
    }

    /// The UPnP descriptions of the devices that replied, by address, apart from those whose MAC is in `skip`.
    static func describe(_ replies: [SSDPDiscovery.Reply], sightings: [DeviceSighting], skip: Set<String>) async -> [String: UPnPDescription] {
        var locations: [String: String] = [:]
        for sighting in sightings where !skip.contains(sighting.mac) {
            if let location = replies.first(where: { $0.address == sighting.address && $0.location != nil })?.location { locations[sighting.address] = location }
        }
        return await withTaskGroup(of: (String, UPnPDescription?).self) { group in
            for (address, location) in locations.sorted(by: { $0.key < $1.key }).prefix(8) {
                group.addTask { (address, await SSDPDiscovery.describe(location, address: address)) }
            }
            var out: [String: UPnPDescription] = [:]
            for await (address, description) in group { if let description { out[address] = description } }
            return out
        }
    }

    /// The cache's entries on `interface`, without this Mac's own addresses, broadcast and multicast.
    public static func sightings(_ rows: [LANDevice], interface: String, own: Set<String>) -> [DeviceSighting] {
        var seen: Set<String> = []
        return rows.compactMap { row in
            guard row.interface == interface, let mac = MACAddress.normalized(row.mac), MACAddress.unicast(mac), !own.contains(mac),
                  seen.insert(mac).inserted else { return nil }
            return DeviceSighting(mac: mac, address: row.address)
        }
    }

    /// The IPv4 address and netmask of `interface`, in host byte order.
    public static func subnet(interface: String) -> (address: UInt32, mask: UInt32)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            let item = pointer.pointee; cursor = item.ifa_next
            guard String(cString: item.ifa_name) == interface, item.ifa_addr?.pointee.sa_family == UInt8(AF_INET), let mask = item.ifa_netmask else { continue }
            let address = item.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            return (address, netmask)
        }
        return nil
    }

    /// The widest block a sweep covers when the person asks for the whole network: a /22, 1,022 addresses, about four
    /// seconds of datagrams. A /16 would be 65,534 and take over four minutes.
    public static let widestSweep = 22
    /// One datagram this far apart, and the wait after for the neighbour cache to fill.
    static let spacing: TimeInterval = 0.004, settle: TimeInterval = 1.5

    /// How big a sweep of this network is, for offering the whole of one wider than a /24. Nil when there is nothing
    /// to choose: a /24 or smaller, or not a private network.
    public struct SweepSize: Equatable, Sendable {
        /// Addresses in the usual /24 sweep, and in the widest one offered.
        public let nearby: Int, whole: Int
        /// The block the whole sweep covers, such as 22, and whether the network is wider still.
        public let prefix: Int, capped: Bool
        /// About how long the whole sweep's datagrams and wait take, rounded up.
        public var seconds: Int { Int((Double(whole) * LANScan.spacing + LANScan.settle).rounded(.up)) }
    }
    public static func sweepSize(address: UInt32, mask: UInt32) -> SweepSize? {
        guard isPrivate(address), mask < 0xFFFF_FF00 else { return nil }
        let prefix = max(mask.nonzeroBitCount, widestSweep)
        return SweepSize(nearby: hosts(address: address, mask: mask).count, whole: hosts(address: address, mask: mask, widest: prefix).count,
                         prefix: prefix, capped: mask.nonzeroBitCount < widestSweep)
    }
    static func isPrivate(_ address: UInt32) -> Bool { address >> 24 == 10 || address >> 20 == 0xAC1 || address >> 16 == 0xC0A8 }

    /// The other addresses in the subnet: 254 at most by default, as a wider network is swept only in the /24 around
    /// this Mac; with `widest`, in that block around it instead, never wider than `widestSweep`. Nothing outside the
    /// private ranges.
    public static func hosts(address: UInt32, mask: UInt32, widest: Int = 24) -> [String] {
        guard isPrivate(address) else { return [] }
        let prefix = min(max(widest, widestSweep), 24)
        let mask = max(mask, UInt32.max << UInt32(32 - prefix))
        guard mask < 0xFFFF_FFFE else { return [] }
        let network = address & mask, broadcast = network | ~mask
        return (network + 1..<broadcast).filter { $0 != address }.map { value in
            [24, 16, 8, 0].map { String((value >> UInt32($0)) & 0xFF) }.joined(separator: ".")
        }
    }

    /// One empty datagram to each address's discard port, about 4 ms apart.
    static func touch(_ hosts: [String]) async {
        await Task.detached(priority: .utility) {
            let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            for host in hosts {
                var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(9).bigEndian
                guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { continue }
                _ = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(descriptor, nil, 0, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                usleep(4000)
            }
        }.value
    }

    /// This Mac's own hardware addresses, which the cache lists as permanent entries.
    public static func ownMACs() -> Set<String> {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var macs: Set<String> = [], cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            let item = pointer.pointee; cursor = item.ifa_next
            guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let mac: String? = address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link in
                guard link.pointee.sdl_alen == 6, let offset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data) else { return nil }
                let bytes = UnsafeRawPointer(link) + offset + Int(link.pointee.sdl_nlen)
                return (0..<6).map { String(format: "%02x", bytes.load(fromByteOffset: $0, as: UInt8.self)) }.joined(separator: ":")
            }
            if let mac { macs.insert(mac) }
        }
        return macs
    }

    /// The name a device goes by: the router's DNS name for its lease, else its Bonjour name. Asks the router and
    /// the local network's multicast DNS only, never the DNS servers beyond them.
    public static func hostname(for address: String, router: String?) async -> String? {
        guard ExpertTools.validHost(address) else { return nil }
        if let router, ExpertTools.validHost(router),
           let name = DeviceNames.readable(await dig(["-x", address, "@" + router, "+short", "+time=1", "+tries=1"])) { return name }
        return DeviceNames.readable(await dig(["-x", address, "-p", "5353", "@224.0.0.251", "+short", "+time=1", "+tries=1"]))
    }

    private static func dig(_ arguments: [String]) async -> String? {
        let result = await CommandRunner.run("/usr/bin/dig", arguments, timeout: 3)
        guard result.status == 0 else { return nil }
        return result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty && !$0.hasPrefix(";") }
    }
}
