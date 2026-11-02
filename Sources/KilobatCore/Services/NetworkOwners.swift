import Foundation

/// Which network an address belongs to, for the networks that carry most big downloads: GitHub, Apple, Valve, Dropbox,
/// the big CDNs (Akamai, Fastly, Cloudflare, Amazon CloudFront) and clouds. From their own published lists and the
/// routing registry, packed by `script/build_networks.py` into networks.deflate and looked up on this Mac; no address is
/// sent anywhere. An address outside every list has no owner, which is most of the internet.
public final class NetworkOwners: @unchecked Sendable {
    public static let shared = NetworkOwners()
    private let lock = NSLock()
    private var loaded = false
    private var source: Data?
    private var names: [String] = []
    private var v4: [UInt32] = [], v4Owners: [UInt16] = []
    private var v6: [UInt64] = [], v6Owners: [UInt16] = []

    /// The bundled table, or the installed app's when the CLI runs on its own.
    public init() {}
    /// A table from its packed bytes, for tests.
    public init(packed: Data) { source = packed }

    public var available: Bool { load(); return !v4.isEmpty }

    /// The owner's id (github, akamai, cloudfront…), or nil.
    public func owner(_ address: String) -> String? {
        guard let bytes = AddressRange.parse(address), !GeoIP.isPrivate(bytes) else { return nil }
        load()
        let index: UInt16?
        if bytes.count == 4 {
            index = GeoIP.lookup(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }, in: v4, codes: v4Owners)
        } else {
            index = GeoIP.lookup(bytes.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }, in: v6, codes: v6Owners)
        }
        guard let index, Int(index) < names.count else { return nil }
        return names[Int(index)]
    }

    private func load() {
        lock.lock(); defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        let packed = source ?? GeoIP.resources.lazy.compactMap { try? Data(contentsOf: $0.appendingPathComponent("networks.deflate")) }.first
        guard let packed, let data = try? (packed as NSData).decompressed(using: .zlib) as Data,
              data.count > 7, data.prefix(6) == Data("KBNET1".utf8) else { return }
        let bytes = [UInt8](data)
        var offset = 6
        let count = Int(bytes[offset]); offset += 1
        var names: [String] = []
        for _ in 0..<count {
            guard offset < bytes.count else { return }
            let length = Int(bytes[offset]); offset += 1
            guard offset + length <= bytes.count else { return }
            names.append(String(decoding: bytes[offset..<offset + length], as: UTF8.self)); offset += length
        }
        guard offset + 8 <= bytes.count else { return }
        func u32(_ at: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[at + $1]) << (8 * $1) } }
        func u64(_ at: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[at + $1]) << (8 * $1) } }
        let count4 = Int(u32(offset)), count6 = Int(u32(offset + 4)); offset += 8
        guard bytes.count == offset + count4 * 5 + count6 * 9 else { return }
        v4.reserveCapacity(count4); v4Owners.reserveCapacity(count4)
        for _ in 0..<count4 { v4.append(u32(offset)); v4Owners.append(UInt16(bytes[offset + 4])); offset += 5 }
        v6.reserveCapacity(count6); v6Owners.reserveCapacity(count6)
        for _ in 0..<count6 { v6.append(u64(offset)); v6Owners.append(UInt16(bytes[offset + 8])); offset += 9 }
        self.names = names
    }
}
