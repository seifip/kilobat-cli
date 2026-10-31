import Foundation

/// The maker registered for a MAC address's first three bytes (its OUI), from the IEEE's public MA-L registry packed
/// into `oui.deflate` by script/build_oui.py. Looked up on this Mac. A private (locally administered) address has no
/// maker, and without the table every lookup is nil.
public final class DeviceVendors: @unchecked Sendable {
    public static let shared = DeviceVendors()
    private let lock = NSLock()
    private var loaded = false
    private var packed: Data?
    private var prefixes: [UInt32] = []
    private var indexes: [UInt16] = []
    private var names: [String] = []

    init(packed: Data? = nil) { self.packed = packed }

    public var available: Bool { load(); return !prefixes.isEmpty }

    public func vendor(for mac: String) -> String? {
        guard !MACAddress.locallyAdministered(mac), let oui = MACAddress.oui(mac) else { return nil }
        load()
        var low = 0, high = prefixes.count
        while low < high {
            let middle = (low + high) / 2
            if prefixes[middle] < oui { low = middle + 1 } else { high = middle }
        }
        guard low < prefixes.count, prefixes[low] == oui, Int(indexes[low]) < names.count else { return nil }
        return names[Int(indexes[low])]
    }

    /// Raw deflate of, little-endian: b"KBOUI1", u32 name count, u32 row count, names (u8 length, UTF-8),
    /// rows (3-byte big-endian OUI, u16 name index), sorted by OUI.
    static func unpack(_ data: Data) -> (prefixes: [UInt32], indexes: [UInt16], names: [String])? {
        let bytes = [UInt8](data)
        guard bytes.count >= 14, bytes.prefix(6).elementsEqual("KBOUI1".utf8) else { return nil }
        func u32(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
        let nameCount = u32(6), rowCount = u32(10)
        var offset = 14, names: [String] = []
        names.reserveCapacity(nameCount)
        for _ in 0..<nameCount {
            guard offset < bytes.count else { return nil }
            let length = Int(bytes[offset]); offset += 1
            guard offset + length <= bytes.count else { return nil }
            names.append(String(decoding: bytes[offset..<offset + length], as: UTF8.self)); offset += length
        }
        guard bytes.count == offset + rowCount * 5 else { return nil }
        var prefixes: [UInt32] = [], indexes: [UInt16] = []
        prefixes.reserveCapacity(rowCount); indexes.reserveCapacity(rowCount)
        for _ in 0..<rowCount {
            prefixes.append(UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]))
            indexes.append(UInt16(bytes[offset + 3]) | UInt16(bytes[offset + 4]) << 8)
            offset += 5
        }
        return (prefixes, indexes, names)
    }

    private func load() {
        lock.lock(); defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        let source = packed ?? GeoIP.resources.lazy.compactMap { try? Data(contentsOf: $0.appendingPathComponent("oui.deflate")) }.first
        guard let source, let data = try? (source as NSData).decompressed(using: .zlib) as Data, let table = Self.unpack(data) else { return }
        prefixes = table.prefixes; indexes = table.indexes; names = table.names
    }
}
