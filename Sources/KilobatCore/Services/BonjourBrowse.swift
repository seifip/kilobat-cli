import Foundation
import dnssd

/// One Bonjour service instance on the local network: its type, instance name, host, IPv4 addresses and TXT record.
/// Other features read these too (a Thread border router's network name, a printer's model), so the TXT values stay
/// as the device sent them: some, like a Thread router's extended PAN ID, are binary.
public struct BonjourService: Codable, Sendable, Equatable, Hashable {
    /// Lowercased, without the domain: `_googlecast._tcp`.
    public let type: String
    public let name: String
    public var host: String?
    public var port: UInt16?
    public var addresses: [String]
    /// Keys lowercased; values as sent.
    public var txt: [String: Data]
    public init(type: String, name: String, host: String? = nil, port: UInt16? = nil, addresses: [String] = [], txt: [String: Data] = [:]) {
        self.type = BonjourBrowse.normalized(type); self.name = name; self.host = host; self.port = port; self.addresses = addresses
        self.txt = Dictionary(txt.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }
    /// A TXT value as UTF-8 text; nil when it's missing or isn't text.
    public func text(_ key: String) -> String? {
        guard let data = txt[key.lowercased()], let text = String(data: data, encoding: .utf8) else { return nil }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return clean.isEmpty ? nil : clean
    }
    /// A TXT value's bytes as lowercase hex, for binary values such as a Thread router's `xp`.
    public func hex(_ key: String) -> String? {
        guard let data = txt[key.lowercased()], !data.isEmpty else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }
}

/// RFC 6763 TXT records: length-prefixed `key=value` strings.
public enum BonjourTXT {
    /// Keys lowercased, the first of a repeated key kept, a key without `=` given an empty value.
    public static func parse(_ data: Data) -> [String: Data] {
        let bytes = [UInt8](data)
        var out: [String: Data] = [:], index = 0
        while index < bytes.count {
            let length = Int(bytes[index]); index += 1
            guard length > 0 else { continue }
            guard index + length <= bytes.count else { break }
            let entry = bytes[index..<index + length]; index += length
            let split = entry.firstIndex(of: UInt8(ascii: "=")) ?? entry.endIndex
            guard split > entry.startIndex, let key = String(bytes: entry[entry.startIndex..<split], encoding: .utf8)?.lowercased(), out[key] == nil else { continue }
            out[key] = split < entry.endIndex ? Data(entry[(split + 1)...]) : Data()
        }
        return out
    }
    /// The wire form, for tests and fixtures.
    public static func encode(_ pairs: [(String, Data)]) -> Data {
        var data = Data()
        for (key, value) in pairs {
            let entry = Data(key.utf8) + Data("=".utf8) + value
            guard entry.count <= 255 else { continue }
            data.append(UInt8(entry.count)); data.append(entry)
        }
        return data
    }
}

/// A Thread border router's `_meshcop._udp` announcement: which Thread network it bridges to Wi-Fi. HomePod mini,
/// Apple TV, Nest hubs, Echo and eero announce it. Two routers with different extended PAN IDs run separate Thread
/// networks.
public struct ThreadBorderAgent: Sendable, Equatable {
    /// `nn`: the Thread network's name.
    public let networkName: String?
    /// `xp`: the extended PAN ID, eight bytes as hex.
    public let extendedPANID: String?
    /// `vn` and `mn`: the router's maker and model, such as Apple Inc. and HomePod.
    public let vendor: String?
    public let model: String?
    /// `tv`: the Thread version, such as 1.3.0.
    public let threadVersion: String?
    public let addresses: [String]
    public init?(_ service: BonjourService) {
        guard service.type == "_meshcop._udp" else { return nil }
        networkName = service.text("nn"); extendedPANID = service.hex("xp"); vendor = service.text("vn"); model = service.text("mn")
        threadVersion = service.text("tv"); addresses = service.addresses
    }
}

/// Looks for devices' Bonjour services on the local network for a few seconds, resolving each instance to its host,
/// TXT record and IPv4 address. Multicast DNS only: nothing leaves the local network. Needs Local Network access.
public enum BonjourBrowse {
    /// Types that say what a device is, or which smart-home standard it speaks.
    public static let deviceTypes = [
        "_googlecast._tcp", "_airplay._tcp", "_raop._tcp", "_companion-link._tcp", "_device-info._tcp", "_ipp._tcp", "_ipps._tcp", "_printer._tcp",
        "_pdl-datastream._tcp", "_uscan._tcp", "_hap._tcp", "_hap._udp", "_matter._tcp", "_matterc._udp", "_meshcop._udp", "_sonos._tcp",
        "_amzn-wplay._tcp", "_androidtvremote2._tcp", "_mediaremotetv._tcp", "_airport._tcp", "_hue._tcp", "_home-assistant._tcp",
        "_axis-video._tcp", "_rtsp._tcp", "_ewelink._tcp", "_shelly._tcp", "_apple-mobdev2._tcp", "_rfb._tcp", "_workstation._tcp",
        "_ssh._tcp", "_adisk._tcp", "_octoprint._tcp",
    ]

    /// `_GoogleCast._tcp.local.` as `_googlecast._tcp`.
    public static func normalized(_ type: String) -> String {
        var type = type.lowercased()
        while type.hasSuffix(".") { type.removeLast() }
        if type.hasSuffix(".local") { type.removeLast(6) }
        return type
    }

    /// The services by IPv4 address, for matching to the neighbour cache.
    public static func byAddress(_ services: [BonjourService]) -> [String: [BonjourService]] {
        var out: [String: [BonjourService]] = [:]
        for service in services { for address in Set(service.addresses) { out[address, default: []].append(service) } }
        return out
    }

    /// Browses `types` for `seconds`, resolving at most `limit` instances.
    public static func run(types: [String] = deviceTypes, seconds: Double = 3, limit: Int = 120) async -> [BonjourService] {
        let session = Session(limit: limit)
        session.start(types: types)
        try? await Task.sleep(for: .seconds(seconds))
        return session.finish()
    }

    /// Owns every DNSServiceRef; all callbacks arrive on `queue`, and `finish` tears down there too.
    final class Session: @unchecked Sendable {
        let queue = DispatchQueue(label: "co.seifi.kilobat.bonjour")
        let limit: Int
        private var refs: [DNSServiceRef] = []
        private var contexts: [Unmanaged<Context>] = []
        private var services: [String: BonjourService] = [:]
        private var finished = false
        init(limit: Int) { self.limit = limit }

        /// What a callback needs: its session, and for a resolve or address lookup, the instance it is for.
        final class Context {
            unowned let session: Session
            let key: String?
            init(session: Session, key: String?) { self.session = session; self.key = key }
        }

        private func context(_ key: String?) -> UnsafeMutableRawPointer {
            let context = Unmanaged.passRetained(Context(session: self, key: key))
            contexts.append(context)
            return context.toOpaque()
        }
        private func keep(_ ref: DNSServiceRef?, _ error: DNSServiceErrorType) {
            guard error == kDNSServiceErr_NoError, let ref else { return }
            if DNSServiceSetDispatchQueue(ref, queue) == kDNSServiceErr_NoError { refs.append(ref) } else { DNSServiceRefDeallocate(ref) }
        }

        func start(types: [String]) {
            queue.async { [self] in
                for type in types {
                    var ref: DNSServiceRef?
                    let error = DNSServiceBrowse(&ref, 0, 0, type, "local.", { _, flags, interface, error, name, type, domain, context in
                        guard error == kDNSServiceErr_NoError, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let context, let name, let type, let domain else { return }
                        let box = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
                        box.session.found(name: String(cString: name), type: String(cString: type), domain: String(cString: domain), interface: interface)
                    }, context(nil))
                    keep(ref, error)
                }
            }
        }

        private func found(name: String, type: String, domain: String, interface: UInt32) {
            let key = BonjourBrowse.normalized(type) + "|" + name
            guard !finished, services[key] == nil, services.count < limit else { return }
            services[key] = BonjourService(type: type, name: name)
            var ref: DNSServiceRef?
            let error = DNSServiceResolve(&ref, 0, interface, name, type, domain, { _, _, interface, error, _, host, port, length, record, context in
                guard error == kDNSServiceErr_NoError, let context, let host else { return }
                let box = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
                let txt = record.map { Data(bytes: $0, count: Int(length)) } ?? Data()
                box.session.resolved(key: box.key ?? "", host: String(cString: host), port: UInt16(bigEndian: port), txt: txt, interface: interface)
            }, context(key))
            keep(ref, error)
        }

        private func resolved(key: String, host: String, port: UInt16, txt: Data, interface: UInt32) {
            guard !finished, var service = services[key] else { return }
            let first = service.host == nil
            service.host = host; service.port = port; service.txt = BonjourTXT.parse(txt)
            services[key] = service
            guard first else { return }
            var ref: DNSServiceRef?
            let error = DNSServiceGetAddrInfo(&ref, 0, interface, DNSServiceProtocol(kDNSServiceProtocol_IPv4), host, { _, _, _, error, _, address, _, context in
                guard error == kDNSServiceErr_NoError, let context, let address, address.pointee.sa_family == sa_family_t(AF_INET) else { return }
                let box = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
                let text = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer -> String? in
                    var addr = pointer.pointee.sin_addr
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                    return String(cString: buffer)
                }
                if let text { box.session.addressed(key: box.key ?? "", address: text) }
            }, context(key))
            keep(ref, error)
        }

        private func addressed(key: String, address: String) {
            guard !finished, var service = services[key], !service.addresses.contains(address) else { return }
            service.addresses.append(address)
            services[key] = service
        }

        /// Stops every query and returns what was found, resolved or not.
        func finish() -> [BonjourService] {
            queue.sync {
                finished = true
                for ref in refs { DNSServiceRefDeallocate(ref) }
                refs = []
                for context in contexts { context.release() }
                contexts = []
                return services.values.sorted { ($0.type, $0.name) < ($1.type, $1.name) }
            }
        }
    }
}
