import Foundation

/// Whether this Mac uses a private (randomised) Wi-Fi address on the network it's on, from comparing the address the
/// router saw with the interface's hardware address (`networksetup -listallhardwareports`).
///
/// The address the router saw comes from the DHCP answer macOS kept (`ipconfig getpacket`, its `chaddr`). On macOS 27,
/// `ifconfig` and `getifaddrs` show third-party apps `02:00:00:00:00:00` instead of the interface's current address,
/// so `ifconfig` is only the fallback, and that placeholder counts as unknown. Both readings need no password.
/// The per-network setting (Fixed, Rotating, Off) is not readable: macOS keeps it in
/// /Library/Preferences/com.apple.wifi.known-networks.plist, readable only by root, so Kilobat never claims it.
public struct WiFiAddressState: Codable, Equatable, Sendable {
    public let interface: String
    /// What the router sees now.
    public let current: String
    /// The address the Wi-Fi chip was made with; nil when macOS didn't say.
    public let hardware: String?
    public init(interface: String, current: String, hardware: String?) {
        self.interface = interface
        self.current = MeshNodes.normalize(current) ?? current.lowercased()
        self.hardware = hardware.flatMap { MeshNodes.normalize($0) ?? $0.lowercased() }
    }
    /// True when the router sees a made-up address, false when it sees the hardware one; nil when that can't be told.
    /// Without the hardware address, a locally administered address (the second bit of the first byte) is private,
    /// since chips are made with universal ones.
    public var isPrivate: Bool? {
        if let hardware { return hardware != current }
        return PrivateWiFiAddress.locallyAdministered(current) ? true : nil
    }
}

public enum PrivateWiFiAddress {
    public static func locallyAdministered(_ mac: String) -> Bool {
        guard let first = MeshNodes.bytes(MeshNodes.normalize(mac) ?? mac)?.first else { return false }
        return first & 0x02 != 0
    }
    /// What macOS shows an app it won't tell the address.
    public static let redacted = "02:00:00:00:00:00"
    /// The `ether` line of `ifconfig <interface>`; nil for the redacted placeholder.
    public static func parseEther(_ ifconfig: String) -> String? {
        for line in ifconfig.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.first == "ether", parts.count >= 2, let mac = MeshNodes.normalize(String(parts[1])) { return mac == redacted ? nil : mac }
        }
        return nil
    }
    /// The client address in the DHCP answer from `ipconfig getpacket <interface>`: an Ethernet-style (htype 1,
    /// hlen 6) `chaddr`. Nil when there's no lease, such as a fixed IP address.
    public static func parseChaddr(_ packet: String) -> String? {
        var htype: String?, hlen: String?, chaddr: String?
        for raw in packet.split(separator: "\n") {
            let parts = raw.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] { case "htype": htype = parts[1]; case "hlen": hlen = parts[1]; case "chaddr": chaddr = parts[1]; default: break }
        }
        guard htype.map({ $0 == "1" }) ?? true, hlen.map({ $0 == "6" }) ?? true, let chaddr, let mac = MeshNodes.normalize(chaddr), mac != redacted, mac != "00:00:00:00:00:00" else { return nil }
        return mac
    }
    /// Device to hardware address, from `networksetup -listallhardwareports`.
    public static func parseHardwarePorts(_ output: String) -> [String: String] {
        var result: [String: String] = [:], device: String?
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port:") { device = nil }
            if line.hasPrefix("Device:") { device = line.dropFirst("Device:".count).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("Ethernet Address:"), let device, let mac = MeshNodes.normalize(line.dropFirst("Ethernet Address:".count).trimmingCharacters(in: .whitespaces)) {
                result[device] = mac
            }
        }
        return result
    }

    /// Reads both addresses. The hardware one doesn't change, so it's read once a run.
    public static func read(interface: String) async -> WiFiAddressState? {
        guard interface.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        async let packet = CommandRunner.run("/usr/sbin/ipconfig", ["getpacket", interface])
        async let ether = CommandRunner.run("/sbin/ifconfig", [interface])
        let hardware = await hardwareAddress(interface)
        let (dhcp, interfaceOutput) = (await packet.output, await ether.output)
        guard let current = parseChaddr(dhcp) ?? parseEther(interfaceOutput) else { return nil }
        return WiFiAddressState(interface: interface, current: current, hardware: hardware)
    }
    @MainActor private static var hardwareCache: [String: String] = [:]
    @MainActor private static func hardwareAddress(_ interface: String) async -> String? {
        if let cached = hardwareCache[interface] { return cached }
        let ports = parseHardwarePorts(await CommandRunner.run("/usr/sbin/networksetup", ["-listallhardwareports"]).output)
        for (device, mac) in ports { hardwareCache[device] = mac }
        return ports[interface]
    }

    /// The row's value: whether the router sees a private address, and the address it sees, as a reservation needs it.
    public static func value(_ state: WiFiAddressState) -> String {
        switch state.isPrivate {
        case true?: String(localized: "On · \(state.current)", comment: "Health: this Mac uses a private Wi-Fi address on this network; the argument is the address the router sees")
        case false?: String(localized: "Off · \(state.current)", comment: "Health: this Mac uses its hardware Wi-Fi address on this network; the argument is that address")
        case nil: state.current
        }
    }

    /// What it means for drops and the router, or nil when nothing needs saying. `drops` is how many times this network
    /// lost the router in the past week.
    public static func advice(_ state: WiFiAddressState, drops: Int) -> String? {
        guard state.isPrivate == true else { return nil }
        if drops >= 2 {
            return String(localized: "This network dropped \(drops) times this week while the Mac used a private address. Setting Private Wi-Fi address to Fixed for this network has stopped drops for some people: Wi-Fi settings › Details.",
                          comment: "Health: private Wi-Fi address and drops; the argument is a count")
        }
        return nil
    }
    /// For the tooltip: what a router reservation or block rule needs.
    public static func routerNote(_ state: WiFiAddressState) -> String {
        guard state.isPrivate == true else {
            return String(localized: "Your router sees this Mac’s own address, \(state.current).", comment: "Health tooltip: private Wi-Fi address off; the argument is a MAC address")
        }
        return String(localized: "Your router sees \(state.current), not this Mac’s own address. A reserved IP address, a parental control or a block on the router must use the address it sees. If the setting is Rotating, that address can change and the reservation stops matching.",
                      comment: "Health tooltip: private Wi-Fi address; the argument is a MAC address")
    }

    /// How many times this network lost the router in the past week: outages the router didn't answer during.
    public static func drops(_ events: [NetworkEvent], network: String?, now: Date = Date()) -> Int {
        guard let network else { return 0 }
        return events.filter { event in
            event.networkKey == network && event.kind == "Unreachable" && now.timeIntervalSince(event.start) <= 7 * 86_400
                && event.routerAnswered == 0 && (event.routerChecks ?? 0) > 0
        }.count
    }
}
