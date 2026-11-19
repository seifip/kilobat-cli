import Foundation
import CryptoKit
import CommonCrypto

// The server name a QUIC (HTTP/3) connection asks for, read from the client's first Initial packets. Compiled into
// the filter too, so Foundation, CryptoKit and CommonCrypto only.
//
// Initial packets are protected with keys anyone can derive from the packet's own Destination Connection ID and a
// public, version-specific salt (RFC 9001 section 5.2; RFC 9369 section 3.3 for version 2), so the ClientHello inside
// is readable by design. This reads it the way a server would, and nothing more: no state is kept, nothing is stored.
// Every input byte is untrusted: lengths are checked before use, loops are bounded, and anything that doesn't parse is
// `.notInitial` or `.unreadable`, both of which mean "allow" to the filter.

public enum QuicInitial {
    public enum Result: Equatable, Sendable {
        case name(String)
        /// Not a QUIC client's first Initial packet (another protocol, another packet type, an unknown version, or an
        /// Initial whose protection doesn't check out).
        case notInitial
        /// A QUIC Initial whose ClientHello isn't complete yet: more datagrams are needed.
        case needMore
        /// QUIC, but no name can be read within the bounds: no visible server name, an IP literal, a hello too
        /// large, or too many datagrams.
        case unreadable
    }

    /// At most this many datagrams are considered; a hello not complete by then is `.unreadable`.
    static let maximumDatagrams = 8
    /// At most this many input bytes in all, and at most this many reassembled CRYPTO bytes.
    static let maximumInput = 16_384
    static let maximumHello = 16_384
    /// CRYPTO frames kept and packets read, in all.
    static let maximumFragments = 64
    static let maximumPackets = 32

    struct Version: Sendable {
        let number: UInt32
        let salt: [UInt8]
        let keyLabel: String, ivLabel: String, hpLabel: String
        /// The long header's two type bits for an Initial and a Retry packet.
        let initialType: UInt8, retryType: UInt8
    }
    /// RFC 9001 section 5.2 and RFC 9369 sections 3.1 to 3.3.
    static let versions: [Version] = [
        Version(number: 0x0000_0001,
                salt: [0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17, 0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a],
                keyLabel: "quic key", ivLabel: "quic iv", hpLabel: "quic hp", initialType: 0, retryType: 3),
        Version(number: 0x6b33_43cf,
                salt: [0x0d, 0xed, 0xe3, 0xde, 0xf7, 0x00, 0xa6, 0xdb, 0x81, 0x93, 0x81, 0xbe, 0x6e, 0x26, 0x9d, 0xcb, 0xf9, 0xbd, 0x2e, 0xd9],
                keyLabel: "quicv2 key", ivLabel: "quicv2 iv", hpLabel: "quicv2 hp", initialType: 1, retryType: 0),
    ]

    struct Keys: Equatable {
        let key: [UInt8], iv: [UInt8], hp: [UInt8]
    }

    /// The client's Initial keys for a Destination Connection ID (RFC 9001 section 5.2).
    static func clientKeys(dcid: [UInt8], version: Version) -> Keys {
        let initial = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: dcid), salt: version.salt)
        let client = expandLabel(SymmetricKey(data: Data(initial)), "client in", 32)
        let secret = SymmetricKey(data: client)
        return Keys(key: expandLabel(secret, version.keyLabel, 16), iv: expandLabel(secret, version.ivLabel, 12), hp: expandLabel(secret, version.hpLabel, 16))
    }

    /// HKDF-Expand-Label with an empty context (RFC 8446 section 7.1).
    static func expandLabel(_ secret: SymmetricKey, _ label: String, _ length: Int) -> [UInt8] {
        let full = Array(("tls13 " + label).utf8)
        let info = [UInt8(length >> 8), UInt8(length & 0xFF), UInt8(full.count)] + full + [0]
        return HKDF<SHA256>.expand(pseudoRandomKey: secret, info: info, outputByteCount: length).withUnsafeBytes { Array($0) }
    }

    /// One AES-128 block in ECB mode: the header-protection mask (RFC 9001 section 5.4.3).
    static func mask(hp: [UInt8], sample: ArraySlice<UInt8>) -> [UInt8]? {
        guard hp.count == 16, sample.count == 16 else { return nil }
        let input = Array(sample)
        var output = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                             hp, 16, nil, input, 16, &output, 16, &moved)
        return status == kCCSuccess && moved == 16 ? output : nil
    }

    /// A bounds-checked reader over one buffer.
    struct Reader {
        let bytes: [UInt8]
        var at: Int
        let end: Int
        init(_ bytes: [UInt8], from start: Int = 0, to end: Int? = nil) {
            self.bytes = bytes; at = start; self.end = min(end ?? bytes.count, bytes.count)
        }
        var remaining: Int { max(0, end - at) }
        mutating func byte() -> UInt8? { guard at < end else { return nil }; defer { at += 1 }; return bytes[at] }
        mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
            guard count >= 0, count <= remaining else { return nil }
            defer { at += count }
            return bytes[at..<(at + count)]
        }
        mutating func skip(_ count: Int) -> Bool { take(count) != nil }
        mutating func uint32() -> UInt32? {
            guard let four = take(4) else { return nil }
            return four.reduce(0) { $0 << 8 | UInt32($1) }
        }
        /// A QUIC variable-length integer (RFC 9000 section 16).
        mutating func varint() -> Int? {
            guard let first = byte() else { return nil }
            let length = 1 << Int(first >> 6)
            var value = UInt64(first & 0x3F)
            var read = 1
            while read < length {
                guard let next = byte() else { return nil }
                value = value << 8 | UInt64(next)
                read += 1
            }
            // 2^62 - 1 at most, which fits an Int on 64-bit platforms; anything this code uses is far smaller.
            return value <= UInt64(Int.max) ? Int(value) : nil
        }
    }

    /// CRYPTO bytes at their offsets in a fixed buffer, with the covered ranges.
    struct Assembly {
        var buffer = [UInt8](repeating: 0, count: QuicInitial.maximumHello)
        var ranges: [Range<Int>] = []
        var overflow = false

        mutating func add(offset: Int, data: ArraySlice<UInt8>) -> Bool {
            guard ranges.count < QuicInitial.maximumFragments else { return false }
            guard !data.isEmpty else { return true }
            guard offset < buffer.count else { overflow = true; return true }
            let kept = min(data.count, buffer.count - offset)
            if kept < data.count { overflow = true }
            var at = offset
            for value in data.prefix(kept) { buffer[at] = value; at += 1 }
            ranges.append(offset..<(offset + kept))
            return true
        }

        /// How many bytes from offset 0 are present without a gap.
        var contiguous: Int {
            var end = 0
            for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if range.lowerBound > end { break }
                end = max(end, range.upperBound)
            }
            return end
        }
    }

    /// The server name in the first Initial packets of a QUIC connection, given its first UDP datagrams in order.
    public static func serverName(datagrams: [Data]) -> Result {
        serverName(datagrams.map { [UInt8]($0) })
    }

    static func serverName(_ datagrams: [[UInt8]]) -> Result {
        guard let first = datagrams.first, let firstByte = first.first else { return .needMore }
        // Long header, fixed bit set (RFC 9000 section 17.2); anything else isn't a client's first packet.
        guard firstByte & 0xC0 == 0xC0, first.count >= 5 else { return .notInitial }
        let number = first[1...4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard let version = versions.first(where: { $0.number == number }) else { return .notInitial }
        guard (firstByte >> 4) & 3 == version.initialType else { return .notInitial }

        var assembly = Assembly()
        var keys: (dcid: ArraySlice<UInt8>, keys: Keys)?
        var packets = 0, input = 0, decrypted = 0
        for (index, datagram) in datagrams.enumerated() {
            guard index < maximumDatagrams else { return .unreadable }
            input += datagram.count
            guard input <= maximumInput else { return .unreadable }
            var start = 0
            while start < datagram.count, packets < maximumPackets {
                // Zero bytes can't start a QUIC packet; some clients pad a datagram with them after its last packet.
                if datagram[start] == 0 { start += 1; continue }
                packets += 1
                guard let packet = readPacket(datagram, at: start, version: version, keys: &keys) else { break }
                start = packet.end
                guard let payload = packet.payload else { continue }
                decrypted += 1
                if !frames(payload, into: &assembly) { break }
            }
        }
        // The first packet must have been a valid, decryptable Initial; otherwise it was never QUIC to begin with.
        guard decrypted > 0 else { return .notInitial }
        return hello(assembly, datagrams: datagrams.count, input: input)
    }

    private static func hello(_ assembly: Assembly, datagrams: Int, input: Int) -> Result {
        let available = assembly.contiguous
        let gaveUp = datagrams >= maximumDatagrams || input >= maximumInput || assembly.ranges.count >= maximumFragments
        guard available >= 4 else { return gaveUp ? .unreadable : .needMore }
        let bytes = assembly.buffer
        guard bytes[0] == 1 else { return .unreadable }                               // ClientHello
        let size = Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard size > 0, size + 4 <= bytes.count else { return .unreadable }
        guard available >= size + 4 else { return gaveUp ? .unreadable : .needMore }
        // Chrome sends the Encrypted Client Hello extension as GREASE even when the visible server name is
        // the requested site. Use that visible name, as on TCP. An encrypted inner name is unavailable.
        if case .name(let name) = FlowSniffer.clientHello(bytes, end: size + 4) { return .name(name) }
        return .unreadable
    }

    /// The packet at `start`, its end, and its decrypted frames when it is an Initial for the first connection ID.
    /// Nil ends the datagram: a short header, a Retry, another version, or a length that doesn't fit.
    private static func readPacket(_ datagram: [UInt8], at start: Int, version: Version,
                                   keys: inout (dcid: ArraySlice<UInt8>, keys: Keys)?) -> (end: Int, payload: [UInt8]?)? {
        var reader = Reader(datagram, from: start)
        guard let first = reader.byte(), first & 0xC0 == 0xC0, reader.uint32() == version.number else { return nil }
        let type = (first >> 4) & 3
        guard type != version.retryType,
              let dcidLength = reader.byte(), dcidLength <= 20, let dcid = reader.take(Int(dcidLength)),
              let scidLength = reader.byte(), scidLength <= 20, reader.skip(Int(scidLength)) else { return nil }
        if type == version.initialType {
            guard let tokenLength = reader.varint(), reader.skip(tokenLength) else { return nil }
        }
        guard let length = reader.varint(), length <= reader.remaining else { return nil }
        let pnOffset = reader.at, end = pnOffset + length
        guard type == version.initialType else { return (end, nil) }                 // 0-RTT or Handshake: skipped
        // A client's Destination Connection ID is at least 8 bytes in its first Initial (RFC 9000 section 7.2).
        if keys == nil {
            guard dcid.count >= 8 else { return nil }
            keys = (dcid, clientKeys(dcid: Array(dcid), version: version))
        }
        guard let current = keys, current.dcid.elementsEqual(dcid) else { return (end, nil) }
        return (end, unprotect(datagram, first: start, pnOffset: pnOffset, end: end, keys: current.keys))
    }

    /// Removes header protection and decrypts the payload (RFC 9001 sections 5.3 and 5.4). Nil if it doesn't check out.
    private static func unprotect(_ datagram: [UInt8], first start: Int, pnOffset: Int, end: Int, keys: Keys) -> [UInt8]? {
        // The sample starts 4 bytes after the packet number's start, as if it were 4 bytes long.
        guard pnOffset + 4 + 16 <= end, let mask = mask(hp: keys.hp, sample: datagram[(pnOffset + 4)..<(pnOffset + 20)]) else { return nil }
        var header = Array(datagram[start..<pnOffset])
        header[0] ^= mask[0] & 0x0F
        let pnLength = Int(header[0] & 3) + 1
        var nonce = keys.iv
        for i in 0..<pnLength {
            let value = datagram[pnOffset + i] ^ mask[1 + i]
            header.append(value)
            nonce[12 - pnLength + i] ^= value
        }
        let body = pnOffset + pnLength
        guard end - body >= 16,
              let sealed = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: datagram[body..<(end - 16)], tag: datagram[(end - 16)..<end]),
              let plain = try? AES.GCM.open(sealed, using: SymmetricKey(data: keys.key), authenticating: header) else { return nil }
        return [UInt8](plain)
    }

    /// Walks the frames an Initial may carry (RFC 9000 section 17.2.2), keeping CRYPTO data. False stops reading:
    /// a frame an Initial may not carry, a malformed one, or too many fragments.
    private static func frames(_ payload: [UInt8], into assembly: inout Assembly) -> Bool {
        var reader = Reader(payload)
        while reader.remaining > 0 {
            guard let type = reader.varint() else { return false }
            switch type {
            case 0x00, 0x01: continue                                                   // PADDING, PING
            case 0x02, 0x03:                                                            // ACK
                guard reader.varint() != nil, reader.varint() != nil, let count = reader.varint(), reader.varint() != nil,
                      count <= reader.remaining / 2 else { return false }
                for _ in 0..<count { guard reader.varint() != nil, reader.varint() != nil else { return false } }
                if type == 0x03 { for _ in 0..<3 { guard reader.varint() != nil else { return false } } }
            case 0x06:                                                                  // CRYPTO
                guard let offset = reader.varint(), let length = reader.varint(), let data = reader.take(length),
                      assembly.add(offset: offset, data: data) else { return false }
            case 0x1C:                                                                  // CONNECTION_CLOSE
                return false
            default:
                return false
            }
        }
        return true
    }

}

/// A UDP flow the filter reads for its QUIC server name, one data callback at a time. The filter passes every chunk
/// on as soon as it has seen it, so the handshake is never held back; only the bytes are kept here, bounded, until a
/// name is read or reading stops. Nothing is kept after that, and a name that is allowed is never stored anywhere.
public struct QuicFlowSniff: Sendable {
    public enum Step: Equatable, Sendable {
        /// The name the connection asks for: judge it as a name read from a TLS hello is judged.
        case name(String)
        /// Pass what was seen and look at the next outbound bytes.
        case more
        /// Stop reading and allow the flow, as one without a name is allowed today.
        case allow
    }

    /// How many outbound bytes the filter asks to see each time: more than any single datagram, as the TCP sniff does.
    public static let peek = 4_096
    private var bytes: [UInt8] = []
    private var calls = 0
    public init() {}

    /// Whether a new outbound UDP flow is read this way: to port 443 and without a name. The caller asks only while
    /// names matter (`FilterPolicy.inspectsHostnames`).
    public static func applies(port: String?, host: String?) -> Bool { port == "443" && host == nil }

    /// The chunks arrive in order; they are read as one buffer, so a datagram split across two callbacks or several
    /// datagrams in one read the same way (each long-header packet carries its own length).
    public mutating func add(_ chunk: Data) -> Step {
        calls += 1
        guard calls <= QuicInitial.maximumDatagrams, bytes.count + chunk.count <= QuicInitial.maximumInput else { bytes = []; return .allow }
        bytes += chunk
        switch QuicInitial.serverName([bytes]) {
        case .name(let name): bytes = []; return .name(name)
        case .needMore where calls < QuicInitial.maximumDatagrams: return .more
        case .needMore, .notInitial, .unreadable: bytes = []; return .allow
        }
    }
}
