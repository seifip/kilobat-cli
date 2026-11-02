import Foundation
import Darwin
import dnssd
import SystemConfiguration

/// Browses Bonjour for a few seconds and resolves what answers: each instance's host, port, TXT record and addresses.
/// Uses mDNSResponder directly (dns_sd), so TXT values arrive as the raw bytes Thread's binary keys need. It only
/// listens and asks; nothing is registered or sent to the devices themselves.
public enum SmartHomeBrowser {
    /// `window` seconds of browsing, then up to `settle` more for the last resolves. `denied` is true when macOS
    /// refused for lack of Local Network permission.
    public static func browse(types: [String], interface: UInt32 = 0, window: Double = 2.5, settle: Double = 1.5) async -> (records: [BonjourInstance], denied: Bool) {
        await withCheckedContinuation { continuation in
            let session = Session(interface: interface, window: window, settle: settle) { continuation.resume(returning: $0) }
            session.start(types)
        }
    }

    /// One browse: every callback runs on `queue`, which owns the state.
    final class Session: @unchecked Sendable {
        let queue = DispatchQueue(label: "co.seifi.kilobat.smarthome")
        private var refs: [DNSServiceRef] = []
        private var contexts: [Context] = []
        private var records: [String: BonjourInstance] = [:]
        private var order: [String] = []
        private var denied = false
        private var open = true
        private let interface: UInt32
        private let window: Double, settle: Double
        private var finish: ((records: [BonjourInstance], denied: Bool)) -> Void
        static let limit = 120

        final class Context {
            weak var session: Session?
            let key: String
            init(_ session: Session, key: String) { self.session = session; self.key = key }
        }

        init(interface: UInt32, window: Double, settle: Double, finish: @escaping ((records: [BonjourInstance], denied: Bool)) -> Void) {
            self.interface = interface; self.window = window; self.settle = settle; self.finish = finish
        }

        func start(_ types: [String]) {
            queue.async { [self] in
                for type in types { browse(type) }
                queue.asyncAfter(deadline: .now() + window) { [self] in
                    open = false
                    queue.asyncAfter(deadline: .now() + settle) { [self] in end() }
                }
            }
        }

        private func context(_ key: String) -> UnsafeMutableRawPointer {
            let context = Context(self, key: key); contexts.append(context)
            return Unmanaged.passUnretained(context).toOpaque()
        }
        private func keep(_ ref: DNSServiceRef?, _ error: DNSServiceErrorType) {
            if error == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) { denied = true }
            guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else { return }
            DNSServiceSetDispatchQueue(ref, queue)
            refs.append(ref)
        }

        private func browse(_ type: String) {
            var ref: DNSServiceRef?
            let error = DNSServiceBrowse(&ref, 0, interface, type, "local.", { _, flags, interface, error, name, type, domain, context in
                guard let context else { return }
                let box = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
                box.session?.found(flags: flags, interface: interface, error: error, name: name, type: type, domain: domain)
            }, context(type))
            keep(ref, error)
        }

        fileprivate func found(flags: DNSServiceFlags, interface: UInt32, error: DNSServiceErrorType, name: UnsafePointer<CChar>?, type: UnsafePointer<CChar>?, domain: UnsafePointer<CChar>?) {
            if error == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) { denied = true; return }
            guard open, error == DNSServiceErrorType(kDNSServiceErr_NoError), flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
                  let name, let type, let domain, records.count < Self.limit else { return }
            let service = String(cString: name), kind = String(cString: type).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let key = kind + "|" + service
            guard records[key] == nil else { return }
            records[key] = BonjourInstance(type: kind, name: service); order.append(key)
            var ref: DNSServiceRef?
            let status = DNSServiceResolve(&ref, 0, interface, name, type, domain, { _, _, interface, error, _, host, port, length, txt, context in
                guard let context else { return }
                let box = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
                let data = txt.map { Data(bytes: $0, count: Int(length)) } ?? Data()
                box.session?.resolved(box.key, interface: interface, error: error, host: host.map { String(cString: $0) }, port: UInt16(bigEndian: port), txt: data)
            }, context(key))
            keep(ref, status)
        }

        fileprivate func resolved(_ key: String, interface: UInt32, error: DNSServiceErrorType, host: String?, port: UInt16, txt: Data) {
            guard error == DNSServiceErrorType(kDNSServiceErr_NoError), var record = records[key], record.host == nil else { return }
            record.host = host; record.port = port; record.txt = TXTRecord.parse(txt)
            records[key] = record
            guard let host else { return }
            var ref: DNSServiceRef?
            let status = DNSServiceGetAddrInfo(&ref, 0, interface, DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6), host, { _, _, _, error, _, address, _, context in
                guard let context, error == DNSServiceErrorType(kDNSServiceErr_NoError), let address else { return }
                let box = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
                if let text = SmartHomeBrowser.text(address) { box.session?.addressed(box.key, text) }
            }, context(key))
            keep(ref, status)
        }

        fileprivate func addressed(_ key: String, _ address: String) {
            guard var record = records[key], !record.addresses.contains(address) else { return }
            record.addresses.append(address); records[key] = record
        }

        private func end() {
            for ref in refs { DNSServiceRefDeallocate(ref) }
            refs = []; contexts = []
            let result = order.compactMap { records[$0] }
            let done = finish; finish = { _ in }
            done((result, denied))
        }
    }

    static func text(_ address: UnsafePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                var value = pointer.pointee.sin_addr
                return inet_ntop(AF_INET, &value, &buffer, socklen_t(buffer.count)).map { String(cString: $0) }
            }
        case AF_INET6:
            return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                var value = pointer.pointee.sin6_addr
                return inet_ntop(AF_INET6, &value, &buffer, socklen_t(buffer.count)).map { String(cString: $0) }
            }
        default: return nil
        }
    }
}

/// Reads this Mac's side of the smart-home check: the interface, its IPv4 subnet and router, IPv6 addresses and
/// router advertisements (`ndp`, no root needed), the neighbour caches and its own Bonjour name. Changes nothing.
public enum SmartHomeProbe {
    /// The whole check. `ssid`, `band`, `wifiInterface` and `scan` come from the caller, which may have Location
    /// permission (the app) or ask the app for them (the CLI).
    /// `scan` runs while Bonjour is browsed.
    public static func run(wifiInterface: String?, ssid: String?, band: String?, window: Double = 2.5,
                           scan: @escaping @Sendable () async -> [NearbyNetwork]?) async -> SmartHomeReport {
        var facts = await network(wifiInterface: wifiInterface)
        // Browse the same physical interface as the readiness facts. All-interface Bonjour can
        // otherwise combine a wired LAN, Wi-Fi and VPN into one misleading home report.
        guard let interface = facts.interface, if_nametoindex(interface) != 0 else {
            return SmartHomeReport.build([], facts: facts)
        }
        async let browse = SmartHomeBrowser.browse(types: SmartHomeServices.all + SmartHomeServices.peers, interface: if_nametoindex(interface), window: window)
        facts.ssid = ssid; facts.band = band; facts.scan = await scan()
        let (records, denied) = await browse
        facts.localNetwork = denied ? .denied : records.isEmpty ? .unknown : .allowed
        facts.bonjourPeers = Set(records.compactMap(\.hostKey)).subtracting(facts.ownHosts).count
        return SmartHomeReport.build(records.filter { SmartHomeServices.all.contains($0.type) }, facts: facts)
    }

    public static func network(wifiInterface: String?) async -> SmartHomeFacts {
        var facts = SmartHomeFacts()
        let routed = DiagnosticProbe.matches(#"interface:\s+(\S+)"#, in: await CommandRunner.run("/sbin/route", ["-n", "get", "default"], timeout: 3).output).first
        // Behind a VPN the default route is the tunnel; the home network is still on the Wi-Fi or Ethernet interface.
        let tunnel = routed.map { ["utun", "ipsec", "ppp", "gif", "stf"].contains(where: $0.hasPrefix) } ?? true
        guard let interface = tunnel ? wifiInterface : routed, interface.range(of: #"^[a-z]+[0-9]+$"#, options: .regularExpression) != nil else { return facts }
        facts.interface = interface
        facts.onWiFi = interface == wifiInterface
        facts.subnet = LANScan.subnet(interface: interface)
        facts.gateway = DiagnosticProbe.matches(#"gateway:\s+(\S+)"#, in: await CommandRunner.run("/sbin/route", ["-n", "get", "-ifscope", interface, "default"], timeout: 3).output).first
        let rows = await ExpertTools.devices()
        let gatewayMAC = facts.gateway.flatMap { gateway in rows.first { $0.address == gateway }.flatMap { MACAddress.normalized($0.mac) } }
        facts.gatewayMAC = gatewayMAC
        facts.routerVendor = gatewayMAC.flatMap { DeviceVendors.shared.vendor(for: $0) }
        facts.neighbours = LANScan.sightings(rows, interface: interface, own: LANScan.ownMACs()).filter { $0.mac != gatewayMAC }.count
        facts.ipv6 = ipv6(interface: interface)
        facts.ipv6.prefixes = IPv6Facts.prefixes(await CommandRunner.run("/usr/sbin/ndp", ["-p"], timeout: 3).output, interface: interface)
        facts.ipv6.defaultRouters = IPv6Facts.defaultRouters(await CommandRunner.run("/usr/sbin/ndp", ["-rn"], timeout: 3).output, interface: interface)
        facts.ipv6.neighbours = IPv6Facts.neighbours(await CommandRunner.run("/usr/sbin/ndp", ["-an"], timeout: 3).output, interface: interface)
        facts.ownHosts = ownHosts()
        return facts
    }

    /// Which kinds of IPv6 address this Mac has on `interface`.
    static func ipv6(interface: String) -> IPv6Facts {
        var facts = IPv6Facts()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return facts }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            let item = pointer.pointee; cursor = item.ifa_next
            guard String(cString: item.ifa_name) == interface, let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET6),
                  let text = SmartHomeBrowser.text(address) else { continue }
            switch IPv6Facts.kind(text) {
            case .linkLocal: facts.linkLocal = true
            case .unique: facts.uniqueLocal = true
            case .global: facts.global = true
            case .other: break
            }
        }
        return facts
    }

    /// This Mac's Bonjour host name, so its own advertisements don't count as other devices.
    static func ownHosts() -> Set<String> {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String? else { return [] }
        return [name.lowercased() + ".local"]
    }
}
