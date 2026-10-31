import Foundation
import Darwin

/// One click to see whether DNS, IPv6 or UDP (what a browser's WebRTC uses) goes around the VPN, each with the setting
/// that fixes it. Reads the resolvers and routes on this Mac, then asks outside services what they saw: bash.ws for
/// which resolvers answered unique lookups, Cloudflare for the exit address, api6.ipify.org for the IPv6 address when
/// IPv6 leaves outside the tunnel, and a public STUN server over the default route and over the Wi-Fi or Ethernet
/// interface directly. Nothing is changed.
public struct LeakTest: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case pass, fail, warning, skipped }

    public struct Check: Codable, Sendable, Equatable, Identifiable {
        /// dns, ipv6 or udp.
        public let id: String
        public let status: Status
        public let title: String
        public let detail: String
        /// What to change, in words, when the check didn't pass.
        public let fix: String?
        public init(id: String, status: Status, title: String, detail: String, fix: String? = nil) {
            self.id = id; self.status = status; self.title = title; self.detail = detail; self.fix = fix
        }
    }

    /// A resolver or address as an outside service saw it.
    public struct Seen: Codable, Sendable, Equatable {
        public let address: String
        /// Such as AS13335.
        public let asn: String?
        public let org: String?
        /// ISO code.
        public let country: String?
        public init(address: String, asn: String? = nil, org: String? = nil, country: String? = nil) {
            self.address = address; self.asn = asn; self.org = org; self.country = country
        }
        var label: String { [address, org, asn, country?.uppercased()].compactMap { $0 }.joined(separator: " · ") }
    }

    /// One resolver from `scutil --dns`.
    public struct Resolver: Codable, Sendable, Equatable {
        public let servers: [String]
        /// Set for split DNS (a company domain, `local`); nil for the resolver every other lookup uses.
        public let domain: String?
        public let interface: String?
        public init(servers: [String], domain: String? = nil, interface: String? = nil) { self.servers = servers; self.domain = domain; self.interface = interface }
    }

    /// Everything the checks look at, gathered by `run` or given by tests.
    public struct Observations: Sendable {
        public var exit: ExitPath
        public var resolvers: [Resolver] = []
        /// The interface each default resolver's address is routed through (`route -n get`).
        public var resolverRoutes: [String: String] = [:]
        /// What bash.ws saw: the resolvers that asked, and the address the request came from. Nil when it didn't answer.
        public var dnsSeen: [Seen]?
        public var exitSeen: Seen?
        /// The IPv4 exit address, from Cloudflare.
        public var exitAddress: String?
        /// Where IPv6 leaves: the interface of the IPv6 default route, nil without one.
        public var ipv6Interface: String?
        /// The public IPv6 address from api6.ipify.org, asked only when IPv6 leaves outside the tunnel.
        public var ipv6Address: String?
        /// Wi-Fi or Ethernet, such as en0, and its port name.
        public var physical: String?
        public var physicalPort: String?
        /// STUN mapped addresses: over the default route, and bound to the physical interface. Nil is no answer.
        public var udpDefault: String?
        public var udpPhysical: String?
        public var udpAsked = false
        public init(exit: ExitPath) { self.exit = exit }
    }

    public let date: Date
    /// full, partial or off.
    public let vpnState: String
    public let vpn: String?
    public let tunnel: String?
    public let exitAddress: String?
    public let checks: [Check]
    /// The outside services this run asked, as hosts.
    public let services: [String]
    public var passed: Bool { !checks.contains { $0.status == .fail } }

    public var summary: String {
        let failed = checks.filter { $0.status == .fail }.map(\.title)
        if checks.allSatisfy({ $0.status == .skipped }) { return checks.first?.detail ?? "" }
        return failed.isEmpty ? String(localized: "No leaks found: DNS, IPv6 and UDP stay in the VPN.") : String(localized: "Leaks: \(failed.formatted(.list(type: .and))).", comment: "Leak test summary; the argument lists check names such as DNS and IPv6")
    }

    /// What WebRTC in a browser can still do, worded the same everywhere.
    public static let browserNote = String(localized: "A browser’s WebRTC can also tell a page your local addresses; Safari hides them, Firefox stops it with media.peerconnection.enabled set to false in about:config, Brave with Settings › Privacy and security › WebRTC IP handling policy › Disable non-proxied UDP, and Chrome with Google’s WebRTC Network Limiter extension.")
    public static let servicesNote = String(localized: "Asks bash.ws which DNS servers answered a few made-up names, Cloudflare for your exit address, a public STUN server (Google’s or Cloudflare’s) over UDP and, when IPv6 skips the VPN, api6.ipify.org. Each sees your address, as any site would.")

    // MARK: Deciding

    /// Public DNS operators whose resolvers are fine to see when lookups reach them through the tunnel.
    static let publicDNS: Set<String> = ["AS13335", "AS15169", "AS19281", "AS36692"]

    public static func evaluate(_ seen: Observations, date: Date = Date()) -> LeakTest {
        let exit = seen.exit, app = VPNApp(exit.vpnName ?? exit.connected.first)
        var services: [String] = []
        if seen.dnsSeen != nil { services.append("bash.ws") }
        if seen.exitAddress != nil { services.append("www.cloudflare.com") }
        if seen.ipv6Address != nil { services.append("api6.ipify.org") }
        if seen.udpAsked { services.append(contentsOf: stunServers.map(\.host)) }
        guard exit.vpn == .full else {
            let detail = exit.vpn == .partial ? String(localized: "The VPN is connected but the default route doesn’t use it, so most traffic already goes around it. Set it to carry all traffic, then check again.")
                : String(localized: "No VPN carries traffic right now. Connect your VPN, then check again.")
            return LeakTest(date: date, vpnState: exit.vpn.rawValue, vpn: exit.vpnName, tunnel: nil, exitAddress: seen.exitAddress,
                            checks: ["dns", "ipv6", "udp"].map { Check(id: $0, status: .skipped, title: title($0), detail: detail) }, services: services)
        }
        return LeakTest(date: date, vpnState: exit.vpn.rawValue, vpn: exit.vpnName, tunnel: exit.interface, exitAddress: seen.exitAddress,
                        checks: [dns(seen, app: app), ipv6(seen, app: app), udp(seen, app: app)], services: services)
    }

    static func title(_ id: String) -> String {
        switch id {
        case "dns": String(localized: "DNS", comment: "Leak test check")
        case "ipv6": String(localized: "IPv6", comment: "Leak test check")
        default: String(localized: "UDP and WebRTC", comment: "Leak test check")
        }
    }

    static func physical(_ name: String?) -> Bool { name.map { $0.hasPrefix("en") || $0.hasPrefix("bridge") } ?? false }

    static func dns(_ seen: Observations, app: VPNApp) -> Check {
        let vpn = seen.exit.vpnName ?? String(localized: "the VPN", comment: "Stands in for a VPN’s name mid-sentence")
        // Lookups that don't match a split-DNS domain go to the default resolvers; any reached outside the tunnel leaks.
        let outside = seen.resolvers.filter { $0.domain == nil }.flatMap(\.servers).compactMap { server -> (String, String)? in
            guard let route = seen.resolverRoutes[server], physical(route) else { return nil }
            return (server, route)
        }
        let exitASN = seen.exitSeen?.asn
        let foreign = (seen.dnsSeen ?? []).filter { resolver in
            guard let asn = resolver.asn else { return false }
            return asn != exitASN && !publicDNS.contains(asn)
        }
        let answered = (seen.dnsSeen ?? []).map(\.label).joined(separator: "; ")
        let witness = seen.dnsSeen == nil ? String(localized: "bash.ws didn’t answer, so only this Mac’s resolver settings were checked.")
            : String(localized: "Resolvers that answered bash.ws: \(answered.isEmpty ? String(localized: "none seen") : answered).", comment: "A list of resolvers with their network and country")
        if let (server, route) = outside.first.map({ ($0.0, $0.1) }) {
            return Check(id: "dns", status: .fail, title: title("dns"),
                         detail: String(localized: "Traffic goes through \(vpn), but lookups go to \(server) over \(route), outside the tunnel, so that network sees every site you look up.", comment: "A VPN name, a DNS server address and an interface such as en0") + " " + witness,
                         fix: app.dnsFix)
        }
        if let resolver = foreign.first {
            return Check(id: "dns", status: .fail, title: title("dns"),
                         detail: String(localized: "A resolver on another network, \(resolver.label), answered lookups. It isn’t \(vpn)’s and isn’t a public DNS service, so it is likely your internet provider’s.", comment: "A resolver's address, network and country; a VPN name") + " " + witness,
                         fix: app.dnsFix)
        }
        return Check(id: "dns", status: .pass, title: title("dns"), detail: String(localized: "Lookups go through \(vpn).", comment: "A VPN name") + " " + witness)
    }

    static func ipv6(_ seen: Observations, app: VPNApp) -> Check {
        let vpn = seen.exit.vpnName ?? String(localized: "the VPN", comment: "Stands in for a VPN’s name mid-sentence")
        guard let interface = seen.ipv6Interface else {
            return Check(id: "ipv6", status: .pass, title: title("ipv6"), detail: String(localized: "This Mac has no IPv6 route, so nothing leaves over IPv6."))
        }
        guard physical(interface) else {
            return Check(id: "ipv6", status: .pass, title: title("ipv6"), detail: String(localized: "IPv6 goes through \(vpn) too (\(interface)).", comment: "A VPN name and an interface such as utun4"))
        }
        let port = seen.physicalPort ?? String(localized: "Wi-Fi")
        let fix = app.ipv6Fix + " " + String(localized: "Or turn IPv6 off for this network: System Settings › Network › \(port) › Details › TCP/IP › Configure IPv6 › Link-Local Only.", comment: "A network port such as Wi-Fi")
        guard let address = seen.ipv6Address else {
            return Check(id: "ipv6", status: .warning, title: title("ipv6"),
                         detail: String(localized: "IPv4 goes through \(vpn), but IPv6 is routed through \(interface) outside it. A test request over IPv6 didn’t get through, so nothing leaked now, but it will on a network where IPv6 works.", comment: "A VPN name and an interface such as en0"), fix: fix)
        }
        let place = GeoIP.shared.country(address).map { " (" + $0.name + ")" } ?? ""
        let exit = seen.exitAddress.map { String(localized: " instead of the VPN’s \($0)", comment: "Follows an address; the argument is the VPN's exit address") } ?? ""
        return Check(id: "ipv6", status: .fail, title: title("ipv6"),
                     detail: String(localized: "IPv4 goes through \(vpn), but IPv6 leaves through \(interface) directly: sites reached over IPv6 see \(address)\(place)\(exit).", comment: "A VPN name, an interface, an IPv6 address with its country, and the VPN's exit"), fix: fix)
    }

    static func udp(_ seen: Observations, app: VPNApp) -> Check {
        let vpn = seen.exit.vpnName ?? String(localized: "the VPN", comment: "Stands in for a VPN’s name mid-sentence")
        let fix = app.udpFix + " " + browserNote
        if let bare = seen.udpPhysical, let interface = seen.physical {
            return Check(id: "udp", status: .fail, title: title("udp"),
                         detail: String(localized: "UDP sent straight out of \(interface) reaches the internet as \(host(bare)), around \(vpn). A browser’s WebRTC uses that path, so a page can learn your real address.", comment: "An interface, a public address, a VPN name"), fix: fix)
        }
        guard let mapped = seen.udpDefault else {
            return Check(id: "udp", status: .skipped, title: title("udp"), detail: String(localized: "The STUN server didn’t answer, so UDP couldn’t be checked. Some networks block it."))
        }
        if let exit = seen.exitAddress, !sameNetwork(host(mapped), exit) {
            return Check(id: "udp", status: .fail, title: title("udp"),
                         detail: String(localized: "UDP leaves as \(host(mapped)), not as \(vpn)’s exit \(exit), so calls and WebRTC take a different way out.", comment: "A public address, a VPN name and its exit address"), fix: fix)
        }
        return Check(id: "udp", status: .pass, title: title("udp"),
                     detail: String(localized: "UDP goes out through \(vpn), and can’t leave around it.", comment: "A VPN name") + " " + browserNote)
    }

    /// An address without its port.
    static func host(_ mapped: String) -> String { mapped.split(separator: ":").first.map(String.init) ?? mapped }
    /// The same address, or the same /16: providers and carriers often send UDP and HTTPS from neighbouring addresses.
    static func sameNetwork(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = a.split(separator: "."), y = b.split(separator: ".")
        return x.count == 4 && y.count == 4 && x.prefix(2) == y.prefix(2)
    }

    // MARK: Reading

    /// `scutil --dns`, its first section only: the resolvers ordinary lookups use, not the ones for scoped queries.
    public static func resolvers(_ output: String) -> [Resolver] {
        let main = output.components(separatedBy: "DNS configuration (for scoped queries)").first ?? output
        return main.components(separatedBy: "resolver #").dropFirst().compactMap { block in
            let servers = DiagnosticProbe.matches(#"nameserver\[\d+\]\s*:\s*(\S+)"#, in: block)
            guard !servers.isEmpty else { return nil }
            return Resolver(servers: servers, domain: DiagnosticProbe.matches(#"domain\s*:\s*(\S+)"#, in: block).first,
                            interface: DiagnosticProbe.matches(#"if_index\s*:\s*\d+\s*\(([^)]+)\)"#, in: block).first)
        }
    }

    /// bash.ws's answer: `[{"ip":…,"country":"ma","asn":"AS36925 Meditelecom","org":…,"type":"ip"|"dns"|"conclusion"}]`.
    public static func bashWS(_ data: Data) -> (exit: Seen?, dns: [Seen])? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        func seen(_ row: [String: Any]) -> Seen? {
            guard let address = row["ip"] as? String, AddressRange.parse(address) != nil else { return nil }
            let asn = (row["asn"] as? String)?.split(separator: " ").first.map(String.init)
            return Seen(address: address, asn: asn?.isEmpty == false ? asn : nil, org: (row["org"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                        country: (row["country"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        return (rows.first { $0["type"] as? String == "ip" }.flatMap(seen), rows.filter { $0["type"] as? String == "dns" }.compactMap(seen))
    }

    /// A STUN Binding Request (RFC 5389) with the given transaction ID.
    public static func stunRequest(_ transaction: [UInt8]) -> [UInt8] {
        [0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42] + transaction.prefix(12)
    }

    /// The XOR-MAPPED-ADDRESS (or plain MAPPED-ADDRESS) of a Binding Success Response to `transaction`, as address:port.
    public static func stunMapped(_ response: [UInt8], transaction: [UInt8]) -> String? {
        guard response.count >= 20, response[0] == 0x01, response[1] == 0x01, Array(response[8..<20]) == Array(transaction.prefix(12)) else { return nil }
        let cookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]
        var index = 20, plain: String?
        while index + 4 <= response.count {
            let type = Int(response[index]) << 8 | Int(response[index + 1]), length = Int(response[index + 2]) << 8 | Int(response[index + 3])
            let value = index + 4
            guard value + length <= response.count else { break }
            if (type == 0x0020 || type == 0x0001), length >= 8, response[value + 1] == 0x01 {
                let xor = type == 0x0020
                let port = (Int(response[value + 2]) << 8 | Int(response[value + 3])) ^ (xor ? 0x2112 : 0)
                let address = (0..<4).map { String(response[value + 4 + $0] ^ (xor ? cookie[$0] : 0)) }.joined(separator: ".")
                if xor { return "\(address):\(port)" }
                plain = "\(address):\(port)"
            }
            index = value + length + (4 - length % 4) % 4
        }
        return plain
    }

    /// Sends one Binding Request over UDP and waits two seconds; `interface` binds it there (IP_BOUND_IF), around the VPN.
    public static func stun(host: String = "stun.l.google.com", port: UInt16 = 19302, interface: String? = nil) -> String? {
        var hints = addrinfo(), result: UnsafeMutablePointer<addrinfo>?
        hints.ai_family = AF_INET; hints.ai_socktype = SOCK_DGRAM
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard socket >= 0 else { return nil }
        defer { close(socket) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        if let interface {
            var index = if_nametoindex(interface)
            guard index != 0, setsockopt(socket, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0 else { return nil }
        }
        let transaction = (0..<12).map { _ in UInt8.random(in: 0...255) }
        let request = stunRequest(transaction)
        guard request.withUnsafeBytes({ sendto(socket, $0.baseAddress, request.count, 0, info.pointee.ai_addr, info.pointee.ai_addrlen) }) == request.count else { return nil }
        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = recv(socket, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        return stunMapped(Array(buffer.prefix(count)), transaction: transaction)
    }

    /// Two public STUN servers, the second asked when the first doesn't answer (Google's drops some requests).
    public static let stunServers: [(host: String, port: UInt16)] = [("stun.l.google.com", 19302), ("stun.cloudflare.com", 3478)]
    static func stunAny(interface: String? = nil) -> String? {
        stunServers.lazy.compactMap { stun(host: $0.host, port: $0.port, interface: interface) }.first
    }

    /// The Wi-Fi or Ethernet interface with an IPv4 address that isn't link-local: what the VPN runs over.
    public static func physicalInterface() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var names: [String] = [], entry: UnsafeMutablePointer<ifaddrs>? = first
        while let current = entry {
            let name = String(cString: current.pointee.ifa_name)
            if name.hasPrefix("en"), current.pointee.ifa_flags & UInt32(IFF_UP) != 0, let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr.bigEndian }
                if ipv4 >> 16 != 0xA9FE { names.append(name) }
            }
            entry = current.pointee.ifa_next
        }
        return names.sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }.first
    }

    /// Runs every check: about ten seconds, most of it waiting on bash.ws.
    public static func run() async -> LeakTest {
        let (exit, _) = await ExitPath.read()
        var seen = Observations(exit: exit)
        guard exit.vpn == .full else { return evaluate(seen) }
        async let dnsOutput = CommandRunner.run("/usr/sbin/scutil", ["--dns"], timeout: 3)
        async let v6 = CommandRunner.run("/sbin/route", ["-n", "get", "-inet6", "default"], timeout: 3)
        async let exitAddress = try? ExitPath.publicAddress()
        async let service = dnsService()
        async let ports = CommandRunner.run("/usr/sbin/networksetup", ["-listallhardwareports"], timeout: 3)
        seen.resolvers = resolvers(await dnsOutput.output)
        for server in Set(seen.resolvers.filter { $0.domain == nil }.flatMap(\.servers)) where AddressRange.parse(server)?.count == 4 {
            if let route = DiagnosticProbe.matches(#"interface:\s+(\S+)"#, in: await CommandRunner.run("/sbin/route", ["-n", "get", server], timeout: 3).output).first {
                seen.resolverRoutes[server] = route
            }
        }
        let v6Output = await v6.output
        seen.ipv6Interface = v6Output.contains("interface:") ? DiagnosticProbe.matches(#"interface:\s+(\S+)"#, in: v6Output).first : nil
        seen.physical = physicalInterface()
        let hardware = ExitPath.hardwarePorts(await ports.output)
        seen.physicalPort = seen.physical.flatMap { hardware[$0] }
        if physical(seen.ipv6Interface) { seen.ipv6Address = await ipv6Address() }
        let interface = seen.physical
        let udp = await Task.detached { (stunAny(), interface.flatMap { stunAny(interface: $0) }) }.value
        seen.udpAsked = true; seen.udpDefault = udp.0; seen.udpPhysical = udp.1
        seen.exitAddress = await exitAddress?.address
        if let answer = await service { seen.exitSeen = answer.0; seen.dnsSeen = answer.1 }
        return evaluate(seen)
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6; configuration.timeoutIntervalForResource = 8
        configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    /// bash.ws's DNS leak test: an ID, ten lookups of made-up names under it through the system resolver, then which
    /// resolvers asked bash.ws's name servers for them. Nil when it doesn't answer.
    static func dnsService() async -> (Seen?, [Seen])? {
        let session = session()
        defer { session.invalidateAndCancel() }
        guard let (data, _) = try? await session.data(from: URL(string: "https://bash.ws/id")!),
              case let id = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty, id.allSatisfy({ $0.isHexDigit }) else { return nil }
        await withTaskGroup(of: Void.self) { group in
            for index in 1...10 {
                group.addTask { _ = await CommandRunner.run("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", "\(index).\(id).bash.ws"], timeout: 4) }
            }
        }
        guard let (result, _) = try? await session.data(from: URL(string: "https://bash.ws/dnsleak/test/\(id)?json")!) else { return nil }
        return bashWS(result).map { ($0.exit, $0.dns) }
    }

    static func ipv6Address() async -> String? {
        let session = session()
        defer { session.invalidateAndCancel() }
        guard let (data, _) = try? await session.data(from: URL(string: "https://api6.ipify.org")!) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.contains(":") && AddressRange.parse(text) != nil ? text : nil
    }
}

/// The VPN apps whose leak settings are named; anything else gets the general wording.
public enum VPNApp: Sendable {
    case mullvad, nordvpn, proton, expressvpn, tailscale, wireguard, work, other

    public init(_ name: String?) {
        let name = (name ?? "").lowercased()
        if name.contains("mullvad") { self = .mullvad }
        else if name.contains("nord") { self = .nordvpn }
        else if name.contains("proton") { self = .proton }
        else if name.contains("express") { self = .expressvpn }
        else if name.contains("tailscale") { self = .tailscale }
        else if name.contains("wireguard") { self = .wireguard }
        else if ["cisco", "anyconnect", "secure client", "globalprotect", "forti", "zscaler", "pulse", "ivanti"].contains(where: name.contains) { self = .work }
        else { self = .other }
    }

    var dnsFix: String {
        switch self {
        case .mullvad: String(localized: "In Mullvad, open Settings › VPN settings and remove any custom DNS server, so lookups use Mullvad’s DNS inside the tunnel; Lockdown mode also stops lookups outside it.")
        case .nordvpn: String(localized: "In NordVPN’s settings, turn Custom DNS off, so lookups use NordVPN’s DNS inside the tunnel.")
        case .proton: String(localized: "Proton VPN’s app keeps DNS in the tunnel itself. With a Proton configuration in the WireGuard app or Tunnelblick, set its DNS to Proton’s, 10.2.0.1.")
        case .expressvpn: String(localized: "Turn off DNS or web filtering in antivirus and security apps, so ExpressVPN’s own DNS servers answer, as ExpressVPN advises.")
        case .tailscale: String(localized: "In Tailscale’s menu, turn on Use Tailscale DNS settings, and set the tailnet’s DNS in the admin console so lookups go through the exit node.")
        case .wireguard: String(localized: "Add a DNS line to the tunnel’s [Interface] section with a resolver inside the tunnel, such as the one your provider gives.")
        case .work: String(localized: "This is your organisation’s VPN, set up by its profile: ask your IT team to send DNS through the tunnel.")
        case .other: String(localized: "Turn on your VPN app’s DNS leak protection, or set its DNS to the provider’s own servers.")
        }
    }

    var ipv6Fix: String {
        switch self {
        case .mullvad: String(localized: "In Mullvad, open Settings › VPN settings and turn on In-tunnel IPv6, so IPv6 goes through the tunnel too.")
        case .proton: String(localized: "Proton VPN’s app blocks IPv6 leaks itself; with the WireGuard app or Tunnelblick it can’t.")
        case .expressvpn: String(localized: "Where ExpressVPN’s Advanced settings have it, turn on Prevent IPv6 address detection while connected.")
        case .wireguard: String(localized: "Add ::/0 to the peer’s AllowedIPs, with an IPv6 Address for the interface, so IPv6 goes through the tunnel.")
        case .work: String(localized: "Ask your IT team to tunnel or block IPv6 in the VPN profile.")
        case .nordvpn, .tailscale, .other: String(localized: "Turn on your VPN app’s IPv6 leak protection or Block IPv6 option, if it has one.")
        }
    }

    var udpFix: String {
        switch self {
        case .mullvad: String(localized: "In Mullvad, turn on Lockdown mode, which stops traffic outside the tunnel.")
        case .work: String(localized: "Ask your IT team whether the VPN profile can block traffic outside the tunnel.")
        default: String(localized: "Turn on your VPN app’s kill switch or option to block connections outside the VPN, if it has one.")
        }
    }
}
