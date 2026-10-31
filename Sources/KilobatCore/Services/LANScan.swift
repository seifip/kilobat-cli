import Foundation
import Darwin

/// A light look at who is on the local network. macOS's neighbour cache only holds devices this Mac talked to, so a
/// sweep first sends one empty UDP datagram to the discard port of each address in the Mac's own subnet (254 at
/// most, a few milliseconds apart): the Mac's ARP request for each address is what fills the cache, and nothing is
/// expected back. Names come from the router's DNS and Bonjour, asked only about devices not seen before. Nothing
/// leaves the local network.
public enum LANScan {
    public struct Result: Sendable {
        public let rows: [LANDevice]
        public let sightings: [DeviceSighting]
        /// The router's MAC address, when the cache has it.
        public let router: String?
    }

    /// Sweeps when asked, reads the neighbour cache on the router's interface (`interface` when the cache doesn't have
    /// the router yet), and names the devices `known` doesn't contain.
    public static func run(gateway: String?, interface fallback: String?, sweep: Bool, known: Set<String>) async -> Result {
        var rows = await ExpertTools.devices()
        guard let interface = gateway.flatMap({ gateway in rows.first { $0.address == gateway }?.interface }) ?? fallback else { return Result(rows: rows, sightings: [], router: nil) }
        if sweep, let subnet = subnet(interface: interface) {
            await touch(hosts(address: subnet.address, mask: subnet.mask))
            try? await Task.sleep(for: .milliseconds(1500))
            rows = await ExpertTools.devices()
        }
        var sightings = sightings(rows, interface: interface, own: ownMACs())
        let router = gateway.flatMap { gateway in rows.first { $0.address == gateway }.flatMap { MACAddress.normalized($0.mac) } }
        let unnamed = sightings.indices.filter { !known.contains(sightings[$0].mac) }.prefix(12)
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
        return Result(rows: rows, sightings: sightings, router: router)
    }

    /// The cache's entries on `interface`, without this Mac's own addresses, broadcast and multicast.
    public static func sightings(_ rows: [LANDevice], interface: String, own: Set<String>) -> [DeviceSighting] {
        var seen: Set<String> = []
        return rows.compactMap { row in
            guard row.interface == interface, let mac = MACAddress.normalized(row.mac), MACAddress.unicast(mac), !own.contains(mac),
                  !row.address.hasSuffix(".255"), seen.insert(mac).inserted else { return nil }
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

    /// The other addresses in the subnet, 254 at most: a wider network is swept only in the /24 around this Mac.
    /// Nothing outside the private ranges.
    public static func hosts(address: UInt32, mask: UInt32) -> [String] {
        let private10 = address >> 24 == 10, private172 = address >> 20 == 0xAC1, private192 = address >> 16 == 0xC0A8
        guard private10 || private172 || private192 else { return [] }
        let mask = max(mask, 0xFFFF_FF00)
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
