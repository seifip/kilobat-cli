import Foundation

/// The country an IP address is registered in, from DB-IP's free database bundled with the app (CC BY 4.0).
/// Looked up on this Mac; no address is ever sent anywhere. Registration country, not where a server stands:
/// anycast and CDN addresses resolve to their owner's country.
public final class GeoIP: @unchecked Sendable {
    public struct Country: Sendable, Equatable, Hashable {
        public let code: String
        public init(code: String) { self.code = code }
        public var name: String { Locale.current.localizedString(forRegionCode: code) ?? code }
        public var flag: String { code.unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }.map(String.init).joined() }
        /// Rough middle of the country, for the map.
        public var coordinate: (latitude: Double, longitude: Double)? { GeoIP.centroids[code].map { ($0[0], $0[1]) } }
    }

    public static let shared = GeoIP()
    public static let attribution = String(localized: "IP geolocation by DB-IP (db-ip.com), CC BY 4.0")
    private let lock = NSLock()
    private var loaded = false
    private var v4: [UInt32] = [], v4Codes: [UInt16] = []
    private var v6: [UInt64] = [], v6Codes: [UInt16] = []

    /// The bundled database, or the installed app's when the CLI runs on its own.
    static var resources: [URL] {
        [Bundle.main.resourceURL, URL(fileURLWithPath: "/Applications/Kilobat.app/Contents/Resources")].compactMap { $0 }
    }
    static let centroids: [String: [Double]] = {
        for folder in resources {
            if let data = try? Data(contentsOf: folder.appendingPathComponent("centroids.json")),
               let table = try? JSONDecoder().decode([String: [Double]].self, from: data) { return table }
        }
        return [:]
    }()

    public var available: Bool { load(); return !v4.isEmpty }

    public func country(_ address: String) -> Country? {
        guard let bytes = AddressRange.parse(address), !Self.isPrivate(bytes) else { return nil }
        load()
        let code: UInt16?
        if bytes.count == 4 {
            code = Self.lookup(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }, in: v4, codes: v4Codes)
        } else {
            code = Self.lookup(bytes.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }, in: v6, codes: v6Codes)
        }
        guard let code, code != Self.unassigned else { return nil }
        return Country(code: String(bytes: [UInt8(code >> 8), UInt8(code & 0xFF)], encoding: .ascii) ?? "")
    }

    static let unassigned = UInt16(UInt8(ascii: "Z")) << 8 | UInt16(UInt8(ascii: "Z"))

    /// The last range that starts at or before `value`.
    static func lookup<T: Comparable>(_ value: T, in starts: [T], codes: [UInt16]) -> UInt16? {
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= value { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : codes[low - 1]
    }

    /// Local, link-local, loopback and carrier-grade NAT space has no country.
    static func isPrivate(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 4 {
            return bytes[0] == 10 || bytes[0] == 127 || (bytes[0] == 172 && bytes[1] & 0xF0 == 16) || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 169 && bytes[1] == 254) || (bytes[0] == 100 && bytes[1] & 0xC0 == 64) || bytes[0] == 0 || bytes[0] >= 224
        }
        return bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 || bytes[0] & 0xFE == 0xFC || bytes.dropLast().allSatisfy { $0 == 0 } || bytes[0] == 0xFF
    }

    private func load() {
        lock.lock(); defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        guard let packed = Self.resources.lazy.compactMap({ try? Data(contentsOf: $0.appendingPathComponent("countries.deflate")) }).first,
              let data = try? (packed as NSData).decompressed(using: .zlib) as Data,
              data.count > 14, data.prefix(6) == Data("KBGEO1".utf8) else { return }
        data.withUnsafeBytes { raw in
            let count4 = Int(raw.loadUnaligned(fromByteOffset: 6, as: UInt32.self).littleEndian)
            let count6 = Int(raw.loadUnaligned(fromByteOffset: 10, as: UInt32.self).littleEndian)
            guard data.count == 14 + count4 * 6 + count6 * 10 else { return }
            var offset = 14
            v4.reserveCapacity(count4); v4Codes.reserveCapacity(count4)
            for _ in 0..<count4 {
                v4.append(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian)
                v4Codes.append(UInt16(raw[offset + 4]) << 8 | UInt16(raw[offset + 5])); offset += 6
            }
            v6.reserveCapacity(count6); v6Codes.reserveCapacity(count6)
            for _ in 0..<count6 {
                v6.append(raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian)
                v6Codes.append(UInt16(raw[offset + 8]) << 8 | UInt16(raw[offset + 9])); offset += 10
            }
        }
    }
}
