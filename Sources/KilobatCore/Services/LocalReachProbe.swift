import Foundation
import Network
import SystemConfiguration

/// Runs "Can I cast or print here?": a few seconds of Bonjour browsing for TVs, speakers and printers, then, only when
/// none showed up, a light look at whether other devices answer at all (the same sweep as the Devices tab: one empty
/// datagram to each address of the /24 around the Mac, then the neighbour cache, then one ping to a few neighbours).
/// Nothing leaves the local network, and nothing is sent to the devices beyond that.
public enum LocalReachProbe {
    public struct Found: Sendable { public let type: String; public let instance: String; public let txt: [String: String] }

    /// Every result of the catalog's types within `seconds`, and whether macOS let Kilobat browse.
    public static func browse(seconds: Double = 3) async -> (found: [Found], access: LocalNetworkAccess) {
        let collector = Collector()
        let browsers = LocalServiceCatalog.types.map { entry -> NWBrowser in
            let parameters = NWParameters()
            // AirDrop's peer-to-peer link would show an Apple TV across the room on any network; only this one counts.
            parameters.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: entry.type, domain: "local."), using: parameters)
            browser.stateUpdateHandler = { state in
                switch state {
                case .ready: collector.note(.allowed)
                case .waiting(let error), .failed(let error): if HouseholdLink.denied(error) { collector.note(.denied) }
                default: break
                }
            }
            browser.browseResultsChangedHandler = { results, _ in collector.add(type: entry.type, results) }
            return browser
        }
        let queue = DispatchQueue(label: "co.seifi.kilobat.local-reach")
        for browser in browsers { browser.start(queue: queue) }
        try? await Task.sleep(for: .seconds(seconds))
        for browser in browsers { browser.cancel() }
        return collector.snapshot()
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var found: [String: Found] = [:]
        private var access: LocalNetworkAccess = .unknown
        func note(_ state: LocalNetworkAccess) { lock.withLock { if access != .allowed { access = state } } }
        func add(type: String, _ results: Set<NWBrowser.Result>) {
            lock.withLock {
                for result in results {
                    guard case .service(let name, _, _, _) = result.endpoint else { continue }
                    var txt: [String: String] = [:]
                    if case .bonjour(let record) = result.metadata { txt = record.dictionary }
                    found[type + "|" + name] = Found(type: type, instance: name, txt: txt)
                }
            }
        }
        func snapshot() -> ([Found], LocalNetworkAccess) { lock.withLock { (Array(found.values), access) } }
    }

    /// The Mac's computer name, which its own AirPlay Receiver and Continuity records carry.
    public static func computerName() -> String? { SCDynamicStoreCopyComputerName(nil, nil) as String? }

    /// Who answers: the neighbour cache on `interface`, after a sweep when `sweep` is true, and one ping to up to six neighbours.
    public static func peers(gateway: String?, interface: String, sweep: Bool) async -> LocalPeers {
        var peers = LocalPeers()
        let subnet = LANScan.subnet(interface: interface)
        if let subnet { peers.subnetHosts = LocalPeers.hosts(prefix: subnet.mask.nonzeroBitCount) }
        if sweep, let subnet {
            let hosts = LANScan.hosts(address: subnet.address, mask: subnet.mask)
            if !hosts.isEmpty {
                await LANScan.touch(hosts)
                try? await Task.sleep(for: .milliseconds(1500))
                peers.swept = true
            }
        }
        let rows = await ExpertTools.devices()
        let seen = LocalPeers.from(rows: rows, interface: interface, gateway: gateway, own: LANScan.ownMACs())
        peers.neighbours = seen.neighbours.count; peers.routerAliases = seen.routerAliases
        // Quick checks only browse and inspect the existing cache; no sweep or ping.
        let targets = sweep ? Array(seen.neighbours.prefix(6)) : []
        peers.pinged = targets.count
        peers.answered = await withTaskGroup(of: Bool.self) { group in
            for address in targets { group.addTask { await DiagnosticProbe.ping(address, count: 1).average != nil } }
            var count = 0
            for await answered in group where answered { count += 1 }
            return count
        }
        return peers
    }

    /// The whole check. `sweep` false keeps it to Bonjour and the cache as it is (`--quick`).
    public static func run(network: String?, gateway: String?, interface: String?, portal: Bool = false, sweep: Bool = true, seconds: Double = 3) async -> LocalReachCheck {
        guard let interface, gateway != nil || LANScan.subnet(interface: interface) != nil else {
            return LocalReachCheck(network: network, services: [], peers: LocalPeers(), access: .unknown, portal: portal, connected: false)
        }
        let (found, access) = await browse(seconds: seconds)
        let own = computerName()
        let all = found.compactMap { LocalServiceCatalog.service(type: $0.type, instance: $0.instance, txt: $0.txt) }
        let services = LocalServiceCatalog.merge(all, own: own)
        var peers = LocalPeers()
        if services.allSatisfy({ $0.kind == .companion }) {
            peers = await self.peers(gateway: gateway, interface: interface, sweep: sweep && access != .denied)
        }
        peers.bonjourDevices = Set(services.map { $0.name.lowercased() }).count
        return LocalReachCheck(network: network, services: services, peers: peers, access: access, portal: portal)
    }
}
