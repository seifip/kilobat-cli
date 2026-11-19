import Foundation
import Darwin
import SystemConfiguration

/// Reads whether IPv6 connects on the network in use. Routes come from the network state and the address from
/// `getifaddrs`, in this process; a connection is opened only when the Mac has a global address and an IPv6 default
/// route, so a network without IPv6 costs nothing.
public enum IPv6Probe {
    /// Opens one TCP connection on 443 to a public address; true when it connected. `ipv6` pins the family.
    typealias Connector = @Sendable (_ host: String, _ ipv6: Bool) async -> Bool

    /// What the network state says, before anything is sent.
    struct Local: Sendable, Equatable {
        var ipv4Interface: String?
        var ipv6Interface: String?
        /// False when the network state could not be opened, so the IPv6 route is unknown.
        var readable = true
        var globalAddress = false
    }

    public static func reading(connect: Bool = true) async -> IPv6Reading {
        await reading(connect: connect, local: readLocal(), connector: connect443)
    }

    /// One reading for a one-shot command, which has no history: if the first fails, the round runs again two seconds
    /// later, and the failure counts as confirmed only when both failed.
    public static func summary() async -> IPv6Summary {
        var current = await reading()
        var confirmed = false
        if IPv6Check.verdict(current) == .advertisedButBroken {
            try? await Task.sleep(for: .seconds(2))
            current = await reading()
            confirmed = IPv6Check.verdict(current) == .advertisedButBroken
        }
        return IPv6Summary(current, confirmed: confirmed)
    }

    /// Whether the Mac has an IPv4 default route now.
    public static func hasIPv4Route() -> Bool { routes(ipv4: storeValue("State:/Network/Global/IPv4", store: nil), ipv6: nil).ipv4Interface != nil }

    static func reading(connect: Bool, local: Local, connector: @escaping Connector) async -> IPv6Reading {
        let tunnelled = [local.ipv4Interface, local.ipv6Interface].contains { $0.map { TrafficRoute.tunnelInterface(Substring($0)) } ?? false }
        var reading = IPv6Reading(globalAddress: local.globalAddress, defaultRoute: local.readable ? local.ipv6Interface != nil : nil,
                                  ipv4Route: local.ipv4Interface != nil, tunneled: tunnelled, reachable: nil, ipv4Reachable: nil)
        guard connect, IPv6Check.canConnect(reading) else { return reading }
        let results = await withTaskGroup(of: (Int, Bool).self) { group -> [Int: Bool] in
            for (index, host) in IPv6Check.targets6.enumerated() { group.addTask { (index, await connector(host, true)) } }
            group.addTask { (IPv6Check.targets6.count, await connector(IPv6Check.target4, false)) }
            var found: [Int: Bool] = [:]
            for await (index, connected) in group { found[index] = connected }
            return found
        }
        reading.reachable = IPv6Check.targets6.indices.contains { results[$0] == true }
        reading.ipv4Reachable = results[IPv6Check.targets6.count] == true
        return reading
    }

    /// The interface each default route leaves through, from the two `State:/Network/Global/IPv4|IPv6` dictionaries.
    static func routes(ipv4: [String: Any]?, ipv6: [String: Any]?) -> (ipv4Interface: String?, ipv6Interface: String?) {
        func primary(_ value: [String: Any]?) -> String? { (value?["PrimaryInterface"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return (primary(ipv4), primary(ipv6))
    }

    static func readLocal() -> Local {
        guard let store = SCDynamicStoreCreate(nil, "co.seifi.kilobat.ipv6" as CFString, nil, nil) else { return Local(readable: false) }
        let found = routes(ipv4: storeValue("State:/Network/Global/IPv4", store: store), ipv6: storeValue("State:/Network/Global/IPv6", store: store))
        var local = Local(ipv4Interface: found.ipv4Interface, ipv6Interface: found.ipv6Interface)
        if let interface = found.ipv6Interface ?? found.ipv4Interface { local.globalAddress = SmartHomeProbe.ipv6(interface: interface).global }
        return local
    }

    private static func storeValue(_ key: String, store: SCDynamicStore?) -> [String: Any]? {
        SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
    }

    private static let connect443: Connector = { host, ipv6 in
        await ConnectionProbe.open(host: host, port: 443, version: ipv6 ? .v6 : .v4, timeout: IPv6Check.connectTimeout).outcome == .connected
    }
}
