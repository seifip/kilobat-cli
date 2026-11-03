import Foundation
import Darwin

// Threat and tracker blocking as the filter enforces it. Compiled into the filter too, so Foundation and the policy
// evaluator only. The lists themselves never travel in the filter's configuration: the app compiles them into one
// `ProtectionIndex` file and hands it to the filter over its XPC connection; the configuration carries only the
// switches, the sites the person allowed and the index's digest.

/// Host names the way the lists keep them: lowercase ASCII, no trailing dot, internationalised names in punycode.
public enum HostName {
    /// Nil for anything that isn't a host name or an IP address.
    public static func normalize(_ raw: String) -> String? {
        if canonical(raw) { return raw }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[") && text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        while text.hasSuffix(".") { text.removeLast() }
        while text.hasPrefix(".") { text.removeFirst() }
        guard !text.isEmpty, text.utf8.count <= 1_000 else { return nil }
        if mayBeAddress(text), let bytes = AddressRange.parse(text) { return AddressRange(bytes: bytes).description }
        let lowered = text.lowercased()
        var labels: [String] = []
        for label in lowered.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty else { return nil }
            if label.utf8.allSatisfy({ $0 < 128 }) { labels.append(String(label)); continue }
            guard let encoded = punycode(String(label).precomposedStringWithCanonicalMapping) else { return nil }
            labels.append("xn--" + encoded)
        }
        let host = labels.joined(separator: ".")
        guard host.utf8.count <= 253, labels.allSatisfy({ $0.utf8.count <= 63 }),
              host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }) else { return nil }
        return host
    }

    /// Already lowercase ASCII labels of 1 to 63 characters, no outer dots, not an address: the usual case, kept as it is.
    @inline(__always) static func canonical(_ text: String) -> Bool {
        var label = 0, total = 0, letter = false
        for byte in text.utf8 {
            total += 1
            if byte == 46 { guard label > 0 else { return false }; label = 0; continue }
            guard (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95 else { return false }
            if (97...122).contains(byte) || byte == 45 || byte == 95 { letter = true }
            label += 1
            guard label <= 63 else { return false }
        }
        return label > 0 && total <= 253 && letter
    }

    /// An IP address literal, IPv4 or IPv6.
    public static func isAddress(_ host: String) -> Bool { mayBeAddress(host) && AddressRange.parse(host) != nil }

    /// Cheap first look: IPv4 is digits and dots, IPv6 has a colon. Names skip the parser and its allocations.
    @inline(__always) static func mayBeAddress(_ text: String) -> Bool {
        var colon = false, other = false
        for byte in text.utf8 {
            if byte == 58 { colon = true } else if !(48...57).contains(byte) && byte != 46 { other = true }
        }
        return colon || !other
    }

    /// RFC 3492 punycode for one label, without the xn-- prefix.
    static func punycode(_ label: String) -> String? {
        let input = label.unicodeScalars.map(\.value)
        let base: UInt32 = 36, tMin: UInt32 = 1, tMax: UInt32 = 26
        func digit(_ d: UInt32) -> Character { Character(Unicode.Scalar(d < 26 ? d + 97 : d + 22)!) }
        func adapt(_ delta: UInt32, _ points: UInt32, _ first: Bool) -> UInt32 {
            var delta = first ? delta / 700 : delta / 2
            delta += delta / points
            var k: UInt32 = 0
            while delta > ((base - tMin) * tMax) / 2 { delta /= base - tMin; k += base }
            return k + (base - tMin + 1) * delta / (delta + 38)
        }
        var output = String(input.filter { $0 < 128 }.compactMap { Unicode.Scalar($0).map(Character.init) })
        let basic = UInt32(output.count)
        var handled = basic
        if basic > 0 { output.append("-") }
        var n: UInt32 = 128, delta: UInt32 = 0, bias: UInt32 = 72
        while handled < UInt32(input.count) {
            guard let m = input.filter({ $0 >= n }).min() else { return nil }
            let (product, overflow) = (m - n).multipliedReportingOverflow(by: handled + 1)
            guard !overflow else { return nil }
            delta += product; n = m
            for c in input {
                if c < n { delta += 1 }
                if c == n {
                    var q = delta, k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t); k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, handled + 1, handled == basic)
                    delta = 0; handled += 1
                }
            }
            delta += 1; n += 1
        }
        return output
    }

    /// The local network, which Protection never blocks: private, link-local, loopback and unique-local addresses,
    /// carrier-grade NAT space (Tailscale and the like), multicast, and .local, .lan, .home.arpa and single-label names.
    public static func isLocal(_ host: String?, address: String?) -> Bool {
        for candidate in [address, host].compactMap({ $0 }) where mayBeAddress(candidate) {
            if let bytes = AddressRange.parse(candidate) { return isPrivate(bytes) }
        }
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        if !host.contains(".") { return true }
        return [".local", ".lan", ".home.arpa", ".internal", ".localhost"].contains { host.hasSuffix($0) } || host == "localhost"
    }

    static func isPrivate(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 4 {
            return bytes[0] == 10 || bytes[0] == 127 || bytes[0] == 0 || (bytes[0] == 172 && bytes[1] & 0xF0 == 16) || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 169 && bytes[1] == 254) || (bytes[0] == 100 && bytes[1] & 0xC0 == 64) || bytes[0] >= 224
        }
        let loopback = bytes.dropLast().allSatisfy { $0 == 0 } && (bytes.last == 1 || bytes.last == 0)
        return loopback || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80) || bytes[0] & 0xFE == 0xFC || bytes[0] == 0xFF
    }
}

/// What a list holds. Stored in the index's slot table.
public enum ProtectionCategory: String, Codable, Sendable, CaseIterable {
    case malware, phishing, scam, threat, tracker
    /// Hosts agents on this Mac already used, from the agent network log: the agent guard's large-upload rule leaves them alone.
    case known

    public var kind: ProtectionDetail.Kind? {
        switch self {
        case .malware: .malware
        case .phishing: .phishing
        case .scam: .scam
        case .threat: .threat
        case .tracker: .tracker
        case .known: nil
        }
    }
    public static let threats: Set<ProtectionCategory> = [.malware, .phishing, .scam, .threat]
}

/// Every list's domains and addresses as one sorted array of 64-bit values: a 56-bit hash of the name followed by the
/// 8-bit slot of the list that has it. A host matches when it, or any parent domain of it, is in the array, so
/// `evil.example` covers `a.evil.example`; a bare top-level domain never matches. The file is memory-mapped, so the
/// filter's resident memory grows only by the pages its lookups touch: 8 bytes per entry at most.
public final class ProtectionIndex: @unchecked Sendable {
    public struct Slot: Codable, Sendable, Equatable {
        public var slot: UInt8
        public var id: String
        public var name: String
        public var category: ProtectionCategory
        public var entries: Int
        public var updated: Date?
        public init(slot: UInt8, id: String, name: String, category: ProtectionCategory, entries: Int, updated: Date? = nil) {
            self.slot = slot; self.id = id; self.name = name; self.category = category; self.entries = entries; self.updated = updated
        }
    }
    struct Meta: Codable { var built: Date; var slots: [Slot] }

    public struct Match: Sendable, Equatable {
        /// The host, parent domain or address that is on a list.
        public let entry: String
        public let lists: [Slot]
        public var categories: Set<ProtectionCategory> { Set(lists.map(\.category)) }
    }

    static let magic: UInt32 = 0x5850_424B   // "KBPX"
    static let version: UInt32 = 1
    public static let maximumSize = 64 << 20

    public let slots: [Slot]
    public let built: Date
    /// Unique entries across every list.
    public let count: Int
    /// SHA-free and cheap: FNV over the whole file, as hex. Tells the app whether the filter has the same index.
    public let digest: String
    private let base: UnsafeRawPointer
    private let length: Int
    private let entriesOffset: Int
    private let release: () -> Void
    private let bySlot: [UInt8: Slot]

    deinit { release() }

    /// Reads an index from bytes in memory (the app, the tests).
    public convenience init?(data: Data) {
        guard data.count >= 16, data.count <= Self.maximumSize else { return nil }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 16)
        data.withUnsafeBytes { memory.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
        self.init(base: UnsafeRawPointer(memory), length: data.count) { memory.deallocate() }
    }

    /// Maps an index file (the filter); nil when it's missing or doesn't check out.
    public convenience init?(contentsOf url: URL) {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size >= 16, info.st_size <= Self.maximumSize else { return nil }
        let length = Int(info.st_size)
        guard let mapped = mmap(nil, length, PROT_READ, MAP_PRIVATE, descriptor, 0), mapped != MAP_FAILED else { return nil }
        self.init(base: UnsafeRawPointer(mapped), length: length) { munmap(mapped, length) }
    }

    private init?(base: UnsafeRawPointer, length: Int, release: @escaping () -> Void) {
        func word(_ offset: Int) -> UInt32 { base.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
        let metaLength = Int(word(8)), count = Int(word(12))
        let entriesOffset = (16 + metaLength + 7) & ~7
        guard word(0) == Self.magic, word(4) == Self.version, metaLength > 0, 16 + metaLength <= length,
              entriesOffset + count * 8 == length,
              let meta = try? Self.decoder.decode(Meta.self, from: Data(bytes: base + 16, count: metaLength)) else { release(); return nil }
        self.base = base; self.length = length; self.entriesOffset = entriesOffset; self.count = count; self.release = release
        slots = meta.slots; built = meta.built
        bySlot = Dictionary(meta.slots.map { ($0.slot, $0) }, uniquingKeysWith: { first, _ in first })
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for offset in stride(from: 0, to: length, by: 1) { hash = (hash ^ UInt64(base.load(fromByteOffset: offset, as: UInt8.self))) &* 0x100_0000_01b3 }
        digest = String(hash, radix: 16)
    }

    static let decoder: JSONDecoder = { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970; return decoder }()

    /// The 56-bit key of a name, in the high bits. Stable across processes and releases: FNV-1a with a final mix.
    static func key<C: Collection>(_ bytes: C) -> UInt64 where C.Element == UInt8 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        hash ^= hash >> 33; hash = hash &* 0xff51_afd7_ed55_8ccd; hash ^= hash >> 33; hash = hash &* 0xc4ce_b9fe_1a85_ec53; hash ^= hash >> 33
        return hash & ~0xFF
    }

    /// Whether any slot lists exactly this key, calling `body` with each slot; no allocation.
    @inline(__always) private func each(_ key: UInt64, _ body: (UInt8) -> Void) {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) >> 1
            if entry(middle) < key { low = middle + 1 } else { high = middle }
        }
        while low < count {
            let value = entry(low)
            guard value & ~0xFF == key else { break }
            body(UInt8(truncatingIfNeeded: value)); low += 1
        }
    }
    @inline(__always) private func entry(_ index: Int) -> UInt64 {
        base.loadUnaligned(fromByteOffset: entriesOffset + index &* 8, as: UInt64.self).littleEndian
    }

    /// The most specific listed name for a host, or the address, in lists of these categories. `host` and `address`
    /// should already be normalised (`HostName.normalize`); an IP literal as the host is looked up as an address.
    public func match(host: String?, address: String? = nil, in categories: Set<ProtectionCategory> = Set(ProtectionCategory.allCases)) -> Match? {
        func lists(_ key: UInt64) -> [Slot]? {
            var found: [Slot]?
            each(key) { slot in
                guard let info = bySlot[slot], categories.contains(info.category) else { return }
                if found == nil { found = [info] } else if !found!.contains(info) { found!.append(info) }
            }
            return found
        }
        if let host, !host.isEmpty {
            let bytes = Array(host.utf8)
            if HostName.isAddress(host) {
                if let found = lists(Self.key(bytes)) { return Match(entry: host, lists: found) }
            } else {
                // Each suffix with at least one dot: a.evil.example, evil.example; never example alone.
                var start = 0
                while let dot = bytes[start...].firstIndex(of: 46) {
                    if let found = lists(Self.key(bytes[start...])) { return Match(entry: String(decoding: bytes[start...], as: UTF8.self), lists: found) }
                    start = dot + 1
                }
            }
        }
        if let address, !address.isEmpty, address != host, let found = lists(Self.key(address.utf8)) { return Match(entry: address, lists: found) }
        return nil
    }

    /// Writes an index for these lists. Entries should be normalised; lists beyond 255 are left out.
    public static func build(_ lists: [(slot: Slot, entries: [String])], built: Date = Date()) -> Data {
        var values: [UInt64] = []
        values.reserveCapacity(lists.reduce(0) { $0 + $1.entries.count })
        var slots: [Slot] = []
        for (slot, entries) in lists.prefix(255) {
            slots.append(slot)
            for entry in entries { values.append(key(entry.utf8) | UInt64(slot.slot)) }
        }
        values.sort()
        var unique: [UInt64] = []
        unique.reserveCapacity(values.count)
        for value in values where unique.last != value { unique.append(value) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970; encoder.outputFormatting = .sortedKeys
        let meta = (try? encoder.encode(Meta(built: built, slots: slots))) ?? Data("{}".utf8)
        var data = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append(magic); append(version); append(UInt32(meta.count)); append(UInt32(unique.count))
        data.append(meta)
        while data.count % 8 != 0 { data.append(0) }
        unique.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: UInt8.self) { bytes in
                // Little-endian on every Mac Kilobat runs on; the reader converts anyway.
                data.append(bytes.baseAddress!, count: bytes.count)
            }
        }
        return data
    }

    /// Unique entries in lists of these categories, counted per slot (an entry in two lists counts twice).
    public func entries(in categories: Set<ProtectionCategory>) -> Int { slots.filter { categories.contains($0.category) }.reduce(0) { $0 + $1.entries } }
}

/// The switches the filter reads from its configuration, under "protection".
public struct ProtectionSettings: Sendable, Equatable {
    /// Malware, phishing and scam destinations (Pro).
    public var threats = false
    /// Tracker and ad hosts in apps, from the list the person chose.
    public var trackers = false
    /// The stricter agent guard (Pro): agents and what they start also stay away from paste sites, file shares,
    /// tunnels and request catchers, raw public IP addresses, and large uploads to hosts no agent used before.
    public var agentGuard = false
    /// The large-upload limit, per connection.
    public var uploadLimit: UInt64 = 10_000_000
    /// Sites the person allowed with "Allow this site": no Protection list or rule applies to them or their subdomains.
    public var allowed: [String] = []
    /// The digest of the index the app built for these settings.
    public var digest: String?

    public init(threats: Bool = false, trackers: Bool = false, agentGuard: Bool = false, uploadLimit: UInt64 = 10_000_000, allowed: [String] = [], digest: String? = nil) {
        self.threats = threats; self.trackers = trackers; self.agentGuard = agentGuard; self.uploadLimit = uploadLimit; self.allowed = allowed; self.digest = digest
    }
    public init(_ configuration: [String: Any]?) {
        guard let configuration else { return }
        threats = configuration["threats"] as? Bool == true
        trackers = configuration["trackers"] as? Bool == true
        agentGuard = configuration["agentGuard"] as? Bool == true
        uploadLimit = (configuration["uploadLimit"] as? NSNumber)?.uint64Value ?? 10_000_000
        allowed = configuration["allowed"] as? [String] ?? []
        digest = configuration["digest"] as? String
    }
    public var configuration: [String: Any] {
        guard active else { return ["threats": false] }
        var value: [String: Any] = ["threats": threats, "trackers": trackers, "agentGuard": agentGuard, "uploadLimit": NSNumber(value: uploadLimit), "allowed": allowed.sorted()]
        if let digest { value["digest"] = digest }
        return value
    }
    public var active: Bool { threats || trackers || agentGuard }

    /// Whether "Allow this site" covers the host.
    public func allows(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        return allowed.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// The process tree a connection came from, as Protection needs it: which agent, if any, started it.
public struct AgentOwner: Sendable, Equatable {
    public var agent: AgentIdentity
    /// The agent's own process.
    public var pid: Int32
    /// The process that connected.
    public var process: String
    public init(agent: AgentIdentity, pid: Int32, process: String) { self.agent = agent; self.pid = pid; self.process = process }
}

/// The checks themselves, in the order `FilterPolicy.decide` runs them. Each returns why it blocks, or nil.
public enum ProtectionCheck {
    /// Apple's and Kilobat's own domains: Apple system services and Kilobat's updates never meet a list's false positive.
    static let neverBlocked = ["apple.com", "icloud.com", "icloud-content.com", "mzstatic.com", "apple-cloudkit.com", "cdn-apple.com", "aaplimg.com",
                               "apple-dns.net", "apple-dns.cn", "apple.news", "me.com", "itunes.com", "kilobat.app"]

    static func exempt(_ host: String?, address: String?, settings: ProtectionSettings) -> Bool {
        if HostName.isLocal(host, address: address) { return true }
        if settings.allows(host) || settings.allows(address) { return true }
        guard let host else { return false }
        return neverBlocked.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func names(_ flow: FilterPolicy.Flow) -> (host: String?, address: String?) {
        (flow.host.flatMap(HostName.normalize), flow.address.flatMap(HostName.normalize))
    }

    static func detail(_ match: ProtectionIndex.Match, agent: AgentOwner?) -> ProtectionDetail {
        // The most telling list first: one that says malware, phishing or scam over a general threat feed.
        let order: [ProtectionCategory] = [.malware, .phishing, .scam, .threat, .tracker]
        let list = match.lists.min { (order.firstIndex(of: $0.category) ?? 9) < (order.firstIndex(of: $1.category) ?? 9) } ?? match.lists[0]
        return ProtectionDetail(kind: list.category.kind ?? .threat, list: list.name, host: match.entry, agent: agent?.agent.name, agentPID: agent?.pid, process: agent?.process)
    }

    /// Known threats, for every app with Threats on and for agents and their children with the agent guard; then the
    /// agent guard's own rules. `agent` is asked only when the answer matters.
    public static func threat(_ flow: FilterPolicy.Flow, settings: ProtectionSettings, index: ProtectionIndex?, agent: () -> AgentOwner?) -> ProtectionDetail? {
        guard settings.threats || settings.agentGuard else { return nil }
        let (host, address) = names(flow)
        guard host != nil || address != nil, !exempt(host, address: address, settings: settings) else { return nil }
        if let index, let match = index.match(host: host, address: address, in: ProtectionCategory.threats) {
            if settings.threats { return detail(match, agent: agent()) }
            if let owner = agent() { return detail(match, agent: owner) }
        }
        guard settings.agentGuard else { return nil }
        if let host, !HostName.isAddress(host), let kind = AgentHostRules.share(host), let owner = agent() {
            return ProtectionDetail(kind: .agentGuard, list: kind, host: host, agent: owner.agent.name, agentPID: owner.pid, process: owner.process)
        }
        // Only when the destination was asked for by address: a name Kilobat couldn't see is not a raw IP.
        if let host, HostName.isAddress(host), let owner = agent() {
            return ProtectionDetail(kind: .agentGuard, list: "raw IP address", host: host, agent: owner.agent.name, agentPID: owner.pid, process: owner.process)
        }
        return nil
    }

    /// Trackers, after the person's own allow rules.
    public static func tracker(_ flow: FilterPolicy.Flow, settings: ProtectionSettings, index: ProtectionIndex?) -> ProtectionDetail? {
        guard settings.trackers, let index else { return nil }
        let (host, address) = names(flow)
        guard let host, !exempt(host, address: address, settings: settings), let match = index.match(host: host, in: [.tracker]) else { return nil }
        return detail(match, agent: nil)
    }

    /// Only for the rule inspector: the site the person allowed ("Allow this site") that keeps a host one of the lists
    /// in use has, or an agent-guard rule would stop, out of Protection's reach.
    public static func allowedSite(_ flow: FilterPolicy.Flow, settings: ProtectionSettings, index: ProtectionIndex?) -> String? {
        guard settings.active, !settings.allowed.isEmpty else { return nil }
        let (host, address) = names(flow)
        guard !HostName.isLocal(host, address: address),
              let site = settings.allowed.first(where: { site in [host, address].contains { $0.map { $0 == site || $0.hasSuffix("." + site) } == true } }) else { return nil }
        var categories: Set<ProtectionCategory> = []
        if settings.threats || settings.agentGuard { categories.formUnion(ProtectionCategory.threats) }
        if settings.trackers { categories.insert(.tracker) }
        if let index, index.match(host: host, address: address, in: categories) != nil { return site }
        if settings.agentGuard, let host, !HostName.isAddress(host), AgentHostRules.share(host) != nil { return site }
        return nil
    }

    /// The agent guard's upload limit for this connection: set when an agent's process sends to a host no agent on
    /// this Mac used before (and that isn't a package registry or the agent's own service).
    public static func uploadLimit(_ flow: FilterPolicy.Flow, settings: ProtectionSettings, index: ProtectionIndex?, agent: () -> AgentOwner?) -> (limit: UInt64, owner: AgentOwner)? {
        guard settings.agentGuard, flow.direction == "outgoing" else { return nil }
        let (host, address) = names(flow)
        guard let host, !exempt(host, address: address, settings: settings), !AgentHostRules.isWellKnown(host),
              index?.match(host: host, in: [.known]) == nil, let owner = agent(), !AgentHostRules.ownService(host, agent: owner.agent.id) else { return nil }
        return (settings.uploadLimit, owner)
    }
}

/// The server name a connection asks for, from its first bytes: the TLS ClientHello's SNI or an HTTP Host header.
/// Read only when the filter has no name for a connection, and only those first bytes.
public enum FlowSniffer {
    public enum Result: Equatable, Sendable {
        case name(String)
        /// TLS or HTTP addressed to an IP literal, or TLS without a server name.
        case address
        /// The hello isn't complete yet: wait for this many bytes in all.
        case needMore(Int)
        /// Neither TLS nor HTTP.
        case unknown
    }
    static let maximum = 16_389

    public static func sniff(_ bytes: [UInt8]) -> Result {
        guard let first = bytes.first else { return .needMore(5) }
        if first == 0x16 { return tls(bytes) }
        return http(bytes)
    }

    static func tls(_ bytes: [UInt8]) -> Result {
        guard bytes.count >= 5 else { return .needMore(5) }
        guard bytes[1] == 3 else { return .unknown }
        let record = Int(bytes[3]) << 8 | Int(bytes[4])
        let total = 5 + record
        guard total <= maximum else { return .unknown }
        guard bytes.count >= total else { return .needMore(total) }
        var index = 5
        func byte() -> Int? { guard index < total else { return nil }; defer { index += 1 }; return Int(bytes[index]) }
        func short() -> Int? { guard let a = byte(), let b = byte() else { return nil }; return a << 8 | b }
        guard byte() == 1, let a = byte(), let b = byte(), let c = byte(), (a << 16 | b << 8 | c) > 0 else { return .unknown }
        index += 2 + 32                                            // version, random
        guard let session = byte() else { return .unknown }; index += session
        guard let suites = short() else { return .unknown }; index += suites
        guard let methods = byte() else { return .unknown }; index += methods
        guard let extensionsLength = short() else { return .address }   // no extensions: no server name
        let end = min(total, index + extensionsLength)
        while index + 4 <= end {
            guard let type = short(), let length = short() else { break }
            if type == 0, index + length <= end {
                var at = index + 2                                   // the list's length
                while at + 3 <= index + length {
                    let nameType = bytes[at], nameLength = Int(bytes[at + 1]) << 8 | Int(bytes[at + 2])
                    at += 3
                    guard at + nameLength <= index + length else { return .unknown }
                    if nameType == 0 {
                        let name = String(decoding: bytes[at..<(at + nameLength)], as: UTF8.self)
                        guard let host = HostName.normalize(name) else { return .unknown }
                        return HostName.isAddress(host) ? .address : .name(host)
                    }
                    at += nameLength
                }
                return .unknown
            }
            index += length
        }
        return .address
    }

    static let methods = ["GET ", "POST ", "PUT ", "HEAD ", "DELETE ", "OPTIONS ", "PATCH ", "CONNECT "]

    static func http(_ bytes: [UInt8]) -> Result {
        let head = String(decoding: bytes.prefix(8_192), as: UTF8.self)
        guard methods.contains(where: { head.hasPrefix($0) || $0.hasPrefix(head) }) else { return .unknown }
        guard let end = head.range(of: "\r\n\r\n") else {
            return bytes.count >= 8_192 ? .unknown : .needMore(min(8_192, bytes.count + 1_024))
        }
        for line in head[..<end.lowerBound].components(separatedBy: "\r\n").dropFirst() {
            guard line.lowercased().hasPrefix("host:") else { continue }
            var value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("[") { value = String(value.dropFirst().prefix { $0 != "]" }) }
            else if let colon = value.lastIndex(of: ":"), value.filter({ $0 == ":" }).count == 1 { value = String(value[..<colon]) }
            guard let host = HostName.normalize(value) else { return .unknown }
            return HostName.isAddress(host) ? .address : .name(host)
        }
        return .address
    }
}

/// The filter's copy of the index: loaded from its own storage at start, replaced when the app sends a new one.
public final class ProtectionIndexHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ProtectionIndex?
    private let file: URL
    public init(file: URL) {
        self.file = file
        current = ProtectionIndex(contentsOf: file)
    }
    public var index: ProtectionIndex? { lock.withLock { current } }
    public var digest: String { lock.withLock { current?.digest ?? "" } }

    /// Checks the bytes are an index, saves them atomically and maps the saved file. The old index stays on failure.
    @discardableResult public func install(_ data: Data) -> Bool {
        guard ProtectionIndex(data: data) != nil else { return false }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: [.atomic])
        } catch { return false }
        guard let mapped = ProtectionIndex(contentsOf: file) else { return false }
        lock.withLock { current = mapped }
        return true
    }
}
