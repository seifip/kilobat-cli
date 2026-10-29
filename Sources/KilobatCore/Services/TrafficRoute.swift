import Foundation

/// Where a connection's bytes go. Only Internet bytes count against a budget: local ones stay on this network
/// (LAN, AirDrop, other nearby devices), and tunnel ones are counted where the tunnel leaves the Mac.
public enum TrafficRoute: String, Codable, Sendable {
    case internet, local, tunnel

    /// Discovery and address services that only ever talk to the local network: mDNS, LLMNR, SSDP, NetBIOS, DHCP, WS-Discovery.
    static let localPorts: Set<String> = ["5353", "5355", "1900", "137", "138", "67", "68", "546", "547", "3702"]

    /// A connection from nettop's per-connection rows, such as `tcp4 192.168.1.20:5000<->17.1.2.3:443` on en0.
    public static func classify(_ connection: Substring, interface: Substring) -> TrafficRoute {
        guard let arrow = connection.range(of: "<->"), let space = connection.firstIndex(of: " ") else { return .internet }
        let v6 = connection[..<space].hasSuffix("6")
        let local = endpoint(connection[connection.index(after: space)..<arrow.lowerBound], v6: v6)
        let remote = endpoint(connection[arrow.upperBound...], v6: v6)
        return route(address: remote.address, port: remote.port, localPort: local.port, interface: interface)
    }

    static func route(address: String, port: String, localPort: String, interface: Substring) -> TrafficRoute {
        if interface.hasPrefix("lo") || interface.hasPrefix("awdl") || interface.hasPrefix("llw") { return .local }
        if address == "*" { return localPorts.contains(localPort) ? .local : tunnelInterface(interface) ? .tunnel : .internet }
        if isLinkLocalOrLoopback(address) { return .local }
        if tunnelInterface(interface) { return .tunnel }
        // A resolver on the network, such as a phone hotspot's, forwards DNS to the Internet.
        return isPrivate(address) && port != "53" ? .local : .internet
    }

    /// utun (WireGuard, Tailscale, most VPN apps and TUN-mode proxies), ipsec (built-in IKEv2 and IPsec), ppp (L2TP).
    static func tunnelInterface(_ name: Substring) -> Bool {
        name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") || name.hasPrefix("tun") || name.hasPrefix("tap")
    }

    /// nettop writes IPv4 endpoints as address:port and IPv6 ones as address.port, with an optional %zone.
    static func endpoint(_ text: Substring, v6: Bool) -> (address: String, port: String) {
        guard let split = v6 ? text.lastIndex(of: ".") : text.lastIndex(of: ":") else { return (String(text), "") }
        var address = String(text[..<split])
        if let zone = address.firstIndex(of: "%") { address = String(address[..<zone]) }
        if address.hasPrefix("::ffff:") { address = String(address.dropFirst(7)) }
        return (address, String(text[text.index(after: split)...]))
    }

    /// Loopback, link-local, multicast and broadcast: never routed past this network.
    public static func isLinkLocalOrLoopback(_ address: String) -> Bool {
        if let v4 = octets(address) {
            return v4[0] == 127 || (v4[0] == 169 && v4[1] == 254) || v4[0] >= 224 || v4 == [0, 0, 0, 0]
        }
        let lower = address.lowercased()
        return lower == "::1" || lower == "::" || lower.hasPrefix("fe8") || lower.hasPrefix("fe9") || lower.hasPrefix("fea") || lower.hasPrefix("feb") || lower.hasPrefix("ff")
    }

    /// Private ranges (RFC 1918, IPv6 unique local) and everything `isLinkLocalOrLoopback` covers.
    public static func isPrivate(_ address: String) -> Bool {
        if isLinkLocalOrLoopback(address) { return true }
        if let v4 = octets(address) { return v4[0] == 10 || (v4[0] == 172 && (16...31).contains(v4[1])) || (v4[0] == 192 && v4[1] == 168) }
        let lower = address.lowercased()
        return lower.hasPrefix("fc") || lower.hasPrefix("fd")
    }

    static func octets(_ address: String) -> [Int]? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let values = parts.compactMap { Int($0) }
        return values.count == 4 && values.allSatisfy { (0...255).contains($0) } ? values : nil
    }
}
