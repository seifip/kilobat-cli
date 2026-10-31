import Foundation

/// Where this Mac's traffic leaves: the default route's interface, whether that is a tunnel, the VPN services macOS
/// lists as connected and, only when asked, the public address one outside service sees. Reading the route and the
/// VPN list stays on this Mac; the public address needs one request to Cloudflare, so it is never looked up unasked.
/// None of this says a connection is private or anonymous: it says which way packets go and what one server saw.
public struct ExitPath: Codable, Sendable, Equatable {
    public enum VPN: String, Codable, Sendable {
        /// The default route leaves through a tunnel.
        case full
        /// A VPN is connected but the default route doesn't use it, so only some destinations go through it.
        case partial
        /// No tunnel on the default route and no VPN service connected.
        case off
    }

    public struct PublicAddress: Codable, Sendable, Equatable {
        public var address: String
        /// The ISO country the address is registered to, from the bundled DB-IP data; nil when it has none.
        public var country: String?
        public var date: Date
        public init(address: String, country: String?, date: Date = Date()) { self.address = address; self.country = country; self.date = date }
        public var countryName: String? { country.map { GeoIP.Country(code: $0).name } }
    }

    public var date: Date
    /// The default route's interface, such as en0 or utun3.
    public var interface: String?
    /// The default route's interface is a tunnel (utun, ipsec, ppp, tun, tap).
    public var tunnel: Bool
    /// VPN configurations macOS lists as connected (`scutil --nc list`), by the names they were given.
    public var connected: [String]
    public var publicAddress: PublicAddress?
    /// macOS's name for the interface's hardware port, such as Wi-Fi or Thunderbolt Ethernet; nil for tunnels.
    public var port: String?

    public init(date: Date = Date(), interface: String?, tunnel: Bool? = nil, connected: [String] = [], publicAddress: PublicAddress? = nil, port: String? = nil) {
        self.date = date; self.interface = interface; self.port = port
        self.tunnel = tunnel ?? interface.map { TrafficRoute.tunnelInterface(Substring($0)) } ?? false
        self.connected = connected; self.publicAddress = publicAddress
    }

    public var vpn: VPN { tunnel ? .full : connected.isEmpty ? .off : .partial }
    /// The VPN's name when macOS lists exactly one connected; with several, which one carries the route isn't known.
    public var vpnName: String? { connected.count == 1 ? connected[0] : nil }

    /// "utun3 (Tailscale)", "Wi-Fi (en0)", or the interface alone.
    public var interfaceLabel: String {
        guard let interface else { return String(localized: "no default route") }
        if tunnel { return vpnName.map { "\(interface) (\($0))" } ?? String(localized: "\(interface) (a VPN or tunnel)") }
        // Some ports already carry the device: "Ethernet Adapter (en3)".
        return port.map { $0.contains("(\(interface))") ? $0 : "\($0) (\(interface))" } ?? interface
    }

    /// One line, saying only what was measured: "Traffic leaves through utun3 (Tailscale) · exit IP in Germany (registry data)".
    public var summary: String {
        guard interface != nil else { return String(localized: "No default route: this Mac isn't sending traffic to the internet.") }
        var parts = [String(localized: "Traffic leaves through \(interfaceLabel)")]
        if vpn == .partial {
            parts.append(vpnName.map { String(localized: "\($0) is connected but the default route doesn't use it, so only some destinations go through it") }
                         ?? String(localized: "a VPN is connected but the default route doesn't use it, so only some destinations go through it"))
        }
        if let address = publicAddress {
            parts.append(address.countryName.map { String(localized: "exit IP in \($0) (registry data)") } ?? String(localized: "exit IP \(address.address), no registry country"))
        }
        return parts.joined(separator: " · ")
    }

    /// The menu bar's short form: "On", "Split" or "Off", with the registry country code when the address was looked up.
    public var badge: String {
        let state = switch vpn {
        case .full: String(localized: "On", comment: "VPN state in the menu bar")
        case .partial: String(localized: "Split", comment: "VPN state in the menu bar: only some traffic goes through it")
        case .off: String(localized: "Off", comment: "VPN state in the menu bar")
        }
        return state + (publicAddress?.country.map { " " + $0 } ?? "")
    }

    /// What the registry country means, worded the same everywhere it's shown.
    public static let registryNote = String(localized: "The country is where the address is registered (DB-IP data, looked up on this Mac), not where you or the server are, and neither it nor a VPN shows that a connection is private or anonymous.")
    public static let lookupNote = String(localized: "Asks Cloudflare (www.cloudflare.com/cdn-cgi/trace) which address your traffic comes from. Cloudflare sees that request, as any website you visit would.")

    // MARK: Reading

    /// Device to port name from `networksetup -listallhardwareports`: en0 → Wi-Fi.
    public static func hardwarePorts(_ output: String) -> [String: String] {
        var ports: [String: String] = [:], name: String?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("Hardware Port: ") { name = String(line.dropFirst("Hardware Port: ".count)) }
            else if line.hasPrefix("Device: "), let current = name { ports[String(line.dropFirst("Device: ".count))] = current; name = nil }
        }
        return ports
    }

    /// The route and VPN list, read on this Mac; `lookup` adds the public address from Cloudflare.
    public static func current(lookup: Bool = false) async -> ExitPath { await read(lookup: lookup).path }

    /// The path with `scutil --nc list` as it came, for the kill switch, which also wants the VPN apps configured.
    /// `ports` names the hardware port, which costs a third command.
    public static func read(lookup: Bool = false, ports: Bool = true) async -> (path: ExitPath, services: String) {
        async let route = CommandRunner.run("/sbin/route", ["-n", "get", "default"], timeout: 3)
        async let services = CommandRunner.run("/usr/sbin/scutil", ["--nc", "list"], timeout: 3)
        async let hardware = ports ? CommandRunner.run("/usr/sbin/networksetup", ["-listallhardwareports"], timeout: 3).output : ""
        let list = await services.output
        var path = ExitPath(interface: DiagnosticProbe.matches(#"interface:\s+(\S+)"#, in: await route.output).first, connected: connectedVPNs(list))
        if ports, !path.tunnel, let interface = path.interface { path.port = hardwarePorts(await hardware)[interface] }
        if lookup, path.interface != nil { path.publicAddress = try? await publicAddress() }
        return (path, list)
    }

    /// Names of the services `scutil --nc list` reports as Connected, e.g. `* (Connected) 1F… VPN (io.tailscale.ipn.macsys) "Tailscale" [VPN:…]`.
    public static func connectedVPNs(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            guard line.contains("(Connected)"), let name = DiagnosticProbe.matches(#""([^"]+)""#, in: String(line)).first else { return nil }
            return name
        }
    }

    public static let traceURL = URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!

    /// The address Cloudflare sees for this Mac, through the system's own path (a system proxy's address when one is set).
    public static func publicAddress() async throws -> PublicAddress {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 6
        configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: traceURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let address = traceAddress(String(decoding: data, as: UTF8.self)) else {
            throw DiagnosticError(String(localized: "Cloudflare didn't say which address it saw. Try again later."))
        }
        return PublicAddress(address: address, country: GeoIP.shared.country(address)?.code)
    }

    /// The `ip=` line of a Cloudflare trace, when it holds an address.
    public static func traceAddress(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("ip=") {
            let value = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            return AddressRange.parse(value) == nil ? nil : value
        }
        return nil
    }

    // MARK: Changes

    /// What changed since `previous`, for the event log: the VPN going on or off, and a different public address.
    public func changes(since previous: ExitPath?) -> [(kind: String, detail: String)] {
        guard let previous else { return [] }
        var changes: [(kind: String, detail: String)] = []
        if previous.vpn != vpn {
            switch vpn {
            case .full: changes.append(("VPN on", String(localized: "Traffic now leaves through \(interfaceLabel).")))
            case .partial:
                let route = interface ?? String(localized: "the network")
                changes.append(("VPN on", vpnName.map { String(localized: "\($0) connected; the default route still leaves through \(route), so only some destinations use it.") }
                                ?? String(localized: "A VPN connected; the default route still leaves through \(route), so only some destinations use it.")))
            case .off: changes.append(("VPN off", previous.vpnName.map { String(localized: "Traffic now leaves through \(interfaceLabel); \($0) is no longer connected.") }
                                       ?? String(localized: "Traffic now leaves through \(interfaceLabel).")))
            }
        }
        if let before = previous.publicAddress, let after = publicAddress, before.address != after.address {
            func place(_ address: PublicAddress) -> String { address.countryName.map { String(localized: "\(address.address) (\($0), registry data)") } ?? address.address }
            changes.append(("Public IP changed", String(localized: "From \(place(before)) to \(place(after)).")))
        }
        return changes
    }

    /// Whether to ask Cloudflare again: never unasked, on a new route or VPN state, and otherwise every `interval`.
    public static func lookupDue(enabled: Bool, previous: ExitPath?, current: ExitPath, network: String?, previousNetwork: String?, interval: TimeInterval = 1800, now: Date = Date()) -> Bool {
        guard enabled, current.interface != nil else { return false }
        guard let previous, let address = previous.publicAddress else { return true }
        if previous.interface != current.interface || previous.vpn != current.vpn || network != previousNetwork { return true }
        return now.timeIntervalSince(address.date) >= interval
    }
}
