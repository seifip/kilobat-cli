import Foundation
import SystemConfiguration

/// The connections up right now, read from System Configuration's dynamic store (no command runs): each network service
/// with an IPv4 address, its router, and which one holds the default route. Read-only.
public enum InternetRoutes {
    public static func read() -> [ConnectionRoute] {
        guard let store = SCDynamicStoreCreate(nil, "Kilobat" as CFString, nil, nil) else { return [] }
        let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let primaryService = global?["PrimaryService"] as? String, primaryInterface = global?["PrimaryInterface"] as? String
        let states = SCDynamicStoreCopyMultiple(store, nil, [#"State:/Network/Service/[^/]+/IPv4"#] as CFArray) as? [String: [String: Any]] ?? [:]
        let names = serviceNames()
        var routes: [ConnectionRoute] = []
        for (key, state) in states {
            let parts = key.components(separatedBy: "/")
            guard parts.count >= 4 else { continue }
            let id = parts[3]
            guard let interface = state["InterfaceName"] as? String, interface.hasPrefix("en") || interface.hasPrefix("bridge"),
                  let addresses = state["Addresses"] as? [String], addresses.contains(where: { !$0.hasPrefix("169.254.") }),
                  let service = names[id] else { continue }
            let router = (state["Router"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let primary = primaryService.map { $0 == id } ?? (primaryInterface == interface)
            routes.append(ConnectionRoute(service: service.name, interface: interface, router: router,
                                          kind: ConnectionRoute.kind(service: service.name, hardwarePort: service.port, wifi: service.wifi), primary: primary))
        }
        return routes.sorted { $0.primary != $1.primary ? $0.primary : $0.service.localizedStandardCompare($1.service) == .orderedAscending }
    }

    /// The current location's services by ID: name, hardware port and whether it's Wi-Fi.
    private static func serviceNames() -> [String: (name: String, port: String?, wifi: Bool)] {
        guard let preferences = SCPreferencesCreate(nil, "Kilobat" as CFString, nil), let set = SCNetworkSetCopyCurrent(preferences),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else { return [:] }
        var result: [String: (name: String, port: String?, wifi: Bool)] = [:]
        for service in services {
            guard let id = SCNetworkServiceGetServiceID(service) as String?, let name = SCNetworkServiceGetName(service) as String? else { continue }
            let interface = SCNetworkServiceGetInterface(service)
            let type = interface.flatMap { SCNetworkInterfaceGetInterfaceType($0) as String? }
            let port = interface.flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? }
            result[id] = (name, port, type == (kSCNetworkInterfaceTypeIEEE80211 as String))
        }
        return result
    }

    /// Whether the internet answers through `interface` alone: two pings to 1.1.1.1 bound to it (`ping -b`), so the
    /// answer doesn't depend on which connection holds the default route.
    public static func internet(through interface: String) async -> Bool {
        guard interface.range(of: #"^(en|bridge)[0-9]+$"#, options: .regularExpression) != nil else { return false }
        let result = await CommandRunner.run("/sbin/ping", ["-n", "-c", "2", "-i", "0.3", "-t", "3", "-b", interface, "1.1.1.1"], timeout: 5)
        return DiagnosticProbe.parsePing(result.output, host: "1.1.1.1").average != nil
    }

    /// The network service order now, as names.
    public static func order() async -> [NetworkServiceEntry]? {
        let result = await CommandRunner.run("/usr/sbin/networksetup", ["-listnetworkserviceorder"], timeout: 5)
        guard result.status == 0 else { return nil }
        let entries = ServiceOrder.parse(result.output)
        return entries.isEmpty ? nil : entries
    }
}
