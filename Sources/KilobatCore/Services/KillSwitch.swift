import Foundation
import Darwin

/// The VPN kill switch as the filter enforces it: while it is armed and the VPN is down, new connections are refused
/// except what the VPN needs to come back (its own app, helpers and network extension, Apple's networking services,
/// the captive-portal login), Kilobat, and, when allowed, the local network. Compiled into the filter as well, so it
/// uses nothing beyond Foundation and the policy evaluator.
public struct KillSwitchPolicy: Sendable, Equatable {
    /// The VPN has carried all traffic since this boot with the setting on, so it is safe to hold the Mac to it.
    public var armed = false
    /// The app saw the VPN down: the default route doesn't go through a tunnel.
    public var vpnDown = false
    /// The tunnel interface the app last saw carrying the default route, such as utun4. The filter blocks on its own
    /// when that interface goes away, before the app reacts and while it is closed.
    public var tunnel: String?
    /// "Allow for 5 minutes": until then nothing is blocked for the VPN. The filter checks the time itself.
    public var allowedUntil: Date?
    /// The local network (printers, file shares, AirPlay) stays reachable while the VPN is down.
    public var allowLAN = true
    /// Signing identifiers of the VPN apps macOS has configurations for (`scutil --nc list`), beyond the known ones.
    public var vpnApps: [String] = []

    public init(armed: Bool = false, vpnDown: Bool = false, tunnel: String? = nil, allowedUntil: Date? = nil, allowLAN: Bool = true, vpnApps: [String] = []) {
        self.armed = armed; self.vpnDown = vpnDown; self.tunnel = tunnel; self.allowedUntil = allowedUntil; self.allowLAN = allowLAN; self.vpnApps = vpnApps
    }

    /// From the filter's vendor configuration; a missing entry is a kill switch that is off.
    public init(_ configuration: [String: Any]?) {
        guard let configuration else { return }
        armed = configuration["armed"] as? Bool == true
        vpnDown = configuration["vpnDown"] as? Bool == true
        tunnel = (configuration["tunnel"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        allowedUntil = (configuration["allowedUntil"] as? Double).map { Date(timeIntervalSince1970: $0) }
        allowLAN = configuration["allowLAN"] as? Bool ?? true
        vpnApps = configuration["vpnApps"] as? [String] ?? []
    }

    /// What `FilterController` saves for the filter. Only an armed kill switch carries anything.
    public var configuration: [String: Any] {
        guard armed else { return ["armed": false] }
        var value: [String: Any] = ["armed": true, "vpnDown": vpnDown, "allowLAN": allowLAN, "vpnApps": vpnApps.sorted()]
        if let tunnel { value["tunnel"] = tunnel }
        if let allowedUntil { value["allowedUntil"] = allowedUntil.timeIntervalSince1970 }
        return value
    }

    /// Whether new connections are refused now. `tunnelUp` asks whether an interface still exists and is up; the
    /// filter passes a real check, everything else trusts the app's reading.
    public func blocks(now: Date = Date(), tunnelUp: (String) -> Bool = { _ in true }) -> Bool {
        guard armed else { return false }
        if let allowedUntil, allowedUntil > now { return false }
        if vpnDown { return true }
        if let tunnel, !tunnelUp(tunnel) { return true }
        return false
    }

    /// Why a connection still goes through while the kill switch blocks.
    public enum Exemption: Sendable, Equatable {
        case kilobat
        /// The VPN app, a helper or its network extension; carries the name that matched.
        case vpnApp(String)
        /// An Apple service networking needs: DNS, DHCP, certificate checks, the captive-portal login, built-in VPNs.
        case appleNetworking(String)
        /// A device on the local network, or DHCP.
        case localNetwork
    }

    /// The exemption for a flow, if any. Apple services count only when `appleSigned` confirms the signature, so
    /// another binary can't borrow their names. A third-party identifier can be copied by any app; the kill switch
    /// stops leaks from ordinary apps, it isn't a wall against malware.
    public func exemption(_ flow: FilterPolicy.Flow, appleSigned: () -> Bool = { false }) -> Exemption? {
        let names = [flow.app, flow.via].compactMap { $0 }
        if names.contains(where: Self.kilobat.contains) { return .kilobat }
        if let name = names.first(where: { Self.vpnApp($0, configured: vpnApps) }) { return .vpnApp(name) }
        if Self.vpnProcesses.contains(flow.process) { return .vpnApp(flow.process) }
        if let name = names.first(where: Self.appleNetworking), appleSigned() { return .appleNetworking(name) }
        // DHCP keeps the Mac on the Wi-Fi so the VPN has something to connect over.
        if flow.port == "67" || flow.port == "68" { return .localNetwork }
        if allowLAN, Self.isLocal(host: flow.host, address: flow.address) { return .localNetwork }
        return nil
    }

    // MARK: Who may connect

    static let kilobat: Set<String> = ["co.seifi.kilobat", "co.seifi.kilobat.cli", "kilobat", "co.seifi.kilobat.lite"]

    /// Signing identifier prefixes of VPN apps, their helpers and network extensions, as their developers ship them.
    public static let vpnIdentifiers = [
        "com.wireguard.", "io.tailscale.", "net.mullvad.", "com.nordvpn.", "ch.protonvpn.", "ch.protonmail.vpn",
        "com.expressvpn.", "com.surfshark.", "com.cisco.anyconnect", "com.cisco.secureclient", "com.cisco.Cisco-AnyConnect",
        "com.paloaltonetworks.", "org.openvpn.", "net.openvpn.", "net.tunnelblick.", "com.privateinternetaccess.",
        "com.windscribe.", "com.cloudflare.1dot1dot1dot1", "net.ivpn.", "com.fortinet.", "net.pulsesecure.", "com.zscaler.",
        "com.sparklabs.", "com.astrill.", "com.cyberghost", "com.anchorfree.", "com.tunnelbear.", "org.outline.", "com.zerotier.",
    ]
    /// Executables VPNs run under names of their own, often signed without a developer identifier.
    public static let vpnProcesses: Set<String> = [
        "wireguard-go", "openvpn", "openconnect", "tailscaled", "mullvad-daemon", "vpnagentd", "PanGPS", "PanGPA",
        "nordvpnd", "expressvpnd", "pia-daemon", "charon",
    ]
    /// Apple's own services networking depends on, matched only when Apple signed them.
    static let appleServices: Set<String> = [
        "com.apple.mDNSResponder", "com.apple.trustd", "com.apple.configd", "com.apple.captiveagent", "com.apple.CaptiveNetworkAssistant",
        "com.apple.nesessionmanager", "com.apple.neagent", "com.apple.nehelper", "com.apple.racoon", "com.apple.pppd",
    ]

    static func vpnApp(_ identifier: String, configured: [String]) -> Bool {
        vpnIdentifiers.contains { identifier.hasPrefix($0) || identifier == $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            || configured.contains { identifier == $0 || identifier.hasPrefix($0 + ".") }
    }
    static func appleNetworking(_ identifier: String) -> Bool {
        appleServices.contains(identifier) || identifier.hasPrefix("com.apple.NetworkExtension.")
    }

    /// The local network: private and link-local addresses, multicast and broadcast, and .local names. Carrier-grade
    /// NAT space (100.64/10) isn't local: Tailscale and some carriers use it for addresses beyond this network.
    public static func isLocal(host: String?, address: String?) -> Bool {
        if let bytes = address.flatMap(AddressRange.parse) { return isLocal(bytes) }
        guard let host = host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")), !host.isEmpty else { return false }
        if let bytes = AddressRange.parse(host) { return isLocal(bytes) }
        return host.hasSuffix(".local")
    }
    static func isLocal(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 4 {
            return bytes[0] == 10 || (bytes[0] == 172 && bytes[1] & 0xF0 == 16) || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 169 && bytes[1] == 254) || bytes[0] >= 224
        }
        return (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80) || bytes[0] & 0xFE == 0xFC || bytes[0] == 0xFF
    }

    /// Configured VPN apps from `scutil --nc list`: `* (Disconnected) 3B… VPN (io.tailscale.ipn.macsys) "Tailscale" [VPN:…]`.
    /// Apple's own VPN types (IKEv2, L2TP) have no app of their own and are left out.
    public static func configuredApps(_ output: String) -> [String] {
        var apps: [String] = []
        for line in output.split(separator: "\n") {
            guard let match = line.range(of: #"VPN \(([A-Za-z0-9.\-]+)\)"#, options: .regularExpression) else { continue }
            let id = line[match].dropFirst(5).dropLast()
            if !id.hasPrefix("com.apple."), !apps.contains(String(id)) { apps.append(String(id)) }
        }
        return apps
    }

    /// Whether an interface exists and is up, from the kernel's interface list.
    public static func interfaceUp(_ name: String) -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        var entry: UnsafeMutablePointer<ifaddrs>? = first
        while let current = entry {
            if String(cString: current.pointee.ifa_name) == name, current.pointee.ifa_flags & UInt32(IFF_UP) != 0 { return true }
            entry = current.pointee.ifa_next
        }
        return false
    }
}
