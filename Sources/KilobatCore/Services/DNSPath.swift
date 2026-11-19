import Foundation
import Darwin

/// Who actually answers this Mac's lookups: the default resolvers, the per-domain resolvers a VPN, Tailscale or a
/// company profile adds (`scutil --dns`), any app's encrypted DNS setting or DNS proxy, and whether iCloud Private
/// Relay traffic is seen on this Mac right now. Relay is reported only as what was observed, connections to Apple's
/// Relay entry servers, never as a guess about its setting or where traffic leaves.
public struct DNSPath: Codable, Sendable, Equatable {
    /// A resolver for some names only: lookups under `domain` go to `servers`, not to the default ones.
    public struct Scoped: Codable, Sendable, Equatable, Identifiable {
        public let domain: String
        public let servers: [String]
        public let interface: String?
        public var id: String { domain }
        public init(domain: String, servers: [String], interface: String? = nil) { self.domain = domain; self.servers = servers; self.interface = interface }
    }

    public enum Relay: String, Codable, Sendable {
        /// Connections to Apple's Relay entry servers are open now.
        case seen
        /// None open now. Says nothing about the setting: Relay carries only some traffic, such as Safari's.
        case notSeen
        /// The DNS this Mac uses gives no address for Relay's entry servers while other names resolve. Apple uses that as
        /// a network's way of saying Relay isn't available there.
        case blockedByDNS
        /// Couldn't look.
        case unknown
    }

    public var defaultServers: [String]
    public var scoped: [Scoped]
    /// Apps' encrypted DNS settings and DNS proxies, from `PathSoftware`.
    public var encrypted: [PathItem]
    public var proxies: [PathItem]
    public var relay: Relay
    /// The processes holding Relay connections when `relay` is seen, such as Safari.
    public var relayProcesses: [String]
    public var date: Date

    public init(defaultServers: [String], scoped: [Scoped] = [], encrypted: [PathItem] = [], proxies: [PathItem] = [], relay: Relay = .unknown,
                relayProcesses: [String] = [], date: Date = Date()) {
        self.defaultServers = defaultServers; self.scoped = scoped; self.encrypted = encrypted; self.proxies = proxies
        self.relay = relay; self.relayProcesses = relayProcesses; self.date = date
    }

    /// Apple's Relay entry hosts, from Apple's guide to preparing a network for Private Relay.
    public static let relayHosts = ["mask.icloud.com", "mask-h2.icloud.com"]

    /// The resolvers from `scutil --dns`: the first default one's servers, and every per-domain resolver that names a
    /// server. Reverse-lookup zones and multicast DNS (`local`) are left out; they aren't where names are looked up.
    public static func resolvers(_ scutil: String) -> (defaults: [String], scoped: [Scoped]) {
        let all = LeakTest.resolvers(scutil)
        let defaults = all.first { $0.domain == nil }?.servers ?? []
        var scoped: [Scoped] = []
        for resolver in all {
            guard let domain = resolver.domain?.lowercased(), !domain.hasSuffix(".arpa"), domain != "local", !scoped.contains(where: { $0.domain == domain }) else { continue }
            scoped.append(Scoped(domain: domain, servers: resolver.servers, interface: resolver.interface))
        }
        return (defaults, scoped)
    }

    /// Whether Relay traffic shows in one nettop snapshot: a connection whose remote is one of `relayAddresses`.
    /// `addressesResolved` is false when the entry hosts gave no address; with `dnsWorks`, that's a block by DNS.
    public static func relay(nettop: String, relayAddresses: Set<String>, dnsWorks: Bool) -> (Relay, [String]) {
        guard !relayAddresses.isEmpty else { return (dnsWorks ? .blockedByDNS : .unknown, []) }
        // Compared as bytes: nettop and the resolver can write the same IPv6 address differently.
        let wanted = Set(relayAddresses.compactMap(AddressRange.parse))
        var process: String?, seen: [String] = []
        for line in nettop.split(separator: "\n") {
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard let head = columns.first else { continue }
            guard let arrow = head.range(of: "<->") else {
                process = NettopMonitor.parseRow(String(line)).map(\.process)
                continue
            }
            guard let space = head.firstIndex(of: " ") else { continue }
            let (address, _) = TrafficRoute.endpoint(head[arrow.upperBound...], v6: head[..<space].hasSuffix("6"))
            if let bytes = AddressRange.parse(address), wanted.contains(bytes), let process, !seen.contains(process) { seen.append(process) }
        }
        return seen.isEmpty ? (.notSeen, []) : (.seen, seen)
    }

    /// Addresses a lookup gave, without the null answers a blocking resolver sends (0.0.0.0, ::).
    static func usable(_ addresses: [String]) -> [String] {
        addresses.filter { !["0.0.0.0", "::", "127.0.0.1", "::1"].contains($0) }.map { $0.lowercased() }
    }

    /// Reads this Mac's DNS path: about a second. The only lookups are the two Relay entry names, through this Mac's own
    /// resolver, the way macOS itself asks before it uses Relay.
    public static func current(software: PathSoftware? = nil, dnsWorks: Bool = true) async -> DNSPath {
        async let scutil = CommandRunner.run("/usr/sbin/scutil", ["--dns"], timeout: 3)
        async let first = ConnectionDoctor.resolve(relayHosts[0])
        async let second = ConnectionDoctor.resolve(relayHosts[1])
        async let flows = CommandRunner.run("/usr/bin/nettop", ["-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"], timeout: 5)
        let found = resolvers(await scutil.output)
        let addresses = Set(usable(await first + second))
        let snapshot = await flows
        let (relay, processes) = snapshot.status == 0 ? Self.relay(nettop: snapshot.output, relayAddresses: addresses, dnsWorks: dnsWorks) : (.unknown, [])
        return DNSPath(defaultServers: found.defaults, scoped: found.scoped, encrypted: software?.encryptedDNS ?? [], proxies: software?.dnsProxies ?? [],
                       relay: relay, relayProcesses: processes)
    }

    // MARK: Words

    public var relayValue: String {
        switch relay {
        case .seen: String(localized: "Traffic seen", comment: "Health › DNS: iCloud Private Relay connections are open on this Mac now")
        case .notSeen: String(localized: "None seen now", comment: "Health › DNS: no iCloud Private Relay connections are open on this Mac now")
        case .blockedByDNS: String(localized: "Not answered by this DNS", comment: "Health › DNS: the DNS in use gives no address for Private Relay")
        case .unknown: "—"
        }
    }

    public var relayNote: String {
        switch relay {
        case .seen:
            let who = relayProcesses.isEmpty ? "" : " " + String(localized: "Open from \(relayProcesses.spokenList()).", comment: "Private Relay; the argument lists apps such as Safari")
            return String(localized: "This Mac has connections open to Apple’s Private Relay servers. Traffic Relay carries, such as Safari’s, looks up names through Relay, not the resolvers above.", comment: "Health › DNS tooltip") + who
        case .notSeen:
            return String(localized: "No connections to Apple’s Private Relay servers are open right now. That shows what’s happening, not whether Relay is turned on.", comment: "Health › DNS tooltip")
        case .blockedByDNS:
            return String(localized: "The DNS this Mac uses gives no address for Private Relay’s servers. Apple treats that as the network turning Relay off, so Relay isn’t used here.", comment: "Health › DNS tooltip")
        case .unknown:
            return String(localized: "Kilobat couldn’t read this Mac’s connections.", comment: "Health › DNS tooltip")
        }
    }

    public static func scopedNote(_ scoped: Scoped) -> String {
        String(localized: "Lookups for names under \(scoped.domain) go to \(scoped.servers.joined(separator: ", ")), not to the resolvers above.", comment: "Health › DNS tooltip: a per-domain resolver; the arguments are a domain such as ts.net and DNS servers")
    }

    /// "NextDNS · on", one line per encrypted DNS setting or DNS proxy.
    public static func itemValue(_ item: PathItem) -> String {
        let state = item.on == false ? String(localized: "off", comment: "A DNS setting is switched off") : String(localized: "on", comment: "A DNS setting is switched on")
        // The server's host is enough for a row; the full address can carry an account ID.
        let server = item.server.map { URL(string: $0)?.host ?? $0 }
        return [item.name, server, state].compactMap { $0 }.joined(separator: " · ")
    }
}
