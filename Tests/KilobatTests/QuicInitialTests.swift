import Foundation
import Testing
import CryptoKit
import CommonCrypto
@testable import KilobatCore

/// Sample hosts only (.example and the RFC's example.com): no real site's traffic appears in these tests.
struct QuicInitialTests {
    static func hex(_ lines: [String]) -> [UInt8] {
        let text = Array(lines.joined().utf8)
        return stride(from: 0, to: text.count - 1, by: 2).compactMap { UInt8(String(decoding: text[$0...($0 + 1)], as: UTF8.self), radix: 16) }
    }

    // RFC 9001 Appendix A (A.1 keys, A.2 client Initial) and RFC 9369 Appendix A (the same for QUIC version 2), copied
    // from the RFC text published by the RFC Editor. Both use the Destination Connection ID 0x8394c8f03e515708 and
    // the same CRYPTO frame, whose ClientHello names example.com; the packet is padded to 1200 bytes.
    static let dcid = hex(["8394c8f03e515708"])
    static let cryptoFrame = hex([
        "060040f1010000ed0303ebf8fa56f12939b9584a3896472ec40bb863cfd3e86804fe3a47f06a2b69484c000004130113",
        "02010000c000000010000e00000b6578616d706c652e636f6dff01000100000a00080006001d00170018001000070005",
        "04616c706e000500050100000000003300260024001d00209370b2c9caa47fbabaf4559fedba753de171fa71f50f1ce1",
        "5d43e994ec74d748002b0003020304000d0010000e0403050306030203080408050806002d00020101001c0002400100",
        "3900320408ffffffffffffffff05048000ffff07048000ffff0801100104800075300901100f088394c8f03e51570806",
        "048000ffff",
    ])
    /// RFC 9001 section A.2, "The resulting protected packet".
    static let v1Packet = hex([
        "c000000001088394c8f03e5157080000449e7b9aec34d1b1c98dd7689fb8ec11d242b123dc9bd8bab936b47d92ec356c",
        "0bab7df5976d27cd449f63300099f3991c260ec4c60d17b31f8429157bb35a1282a643a8d2262cad67500cadb8e7378c",
        "8eb7539ec4d4905fed1bee1fc8aafba17c750e2c7ace01e6005f80fcb7df621230c83711b39343fa028cea7f7fb5ff89",
        "eac2308249a02252155e2347b63d58c5457afd84d05dfffdb20392844ae812154682e9cf012f9021a6f0be17ddd0c208",
        "4dce25ff9b06cde535d0f920a2db1bf362c23e596d11a4f5a6cf3948838a3aec4e15daf8500a6ef69ec4e3feb6b1d98e",
        "610ac8b7ec3faf6ad760b7bad1db4ba3485e8a94dc250ae3fdb41ed15fb6a8e5eba0fc3dd60bc8e30c5c4287e53805db",
        "059ae0648db2f64264ed5e39be2e20d82df566da8dd5998ccabdae053060ae6c7b4378e846d29f37ed7b4ea9ec5d82e7",
        "961b7f25a9323851f681d582363aa5f89937f5a67258bf63ad6f1a0b1d96dbd4faddfcefc5266ba6611722395c906556",
        "be52afe3f565636ad1b17d508b73d8743eeb524be22b3dcbc2c7468d54119c7468449a13d8e3b95811a198f3491de3e7",
        "fe942b330407abf82a4ed7c1b311663ac69890f4157015853d91e923037c227a33cdd5ec281ca3f79c44546b9d90ca00",
        "f064c99e3dd97911d39fe9c5d0b23a229a234cb36186c4819e8b9c5927726632291d6a418211cc2962e20fe47feb3edf",
        "330f2c603a9d48c0fcb5699dbfe5896425c5bac4aee82e57a85aaf4e2513e4f05796b07ba2ee47d80506f8d2c25e50fd",
        "14de71e6c418559302f939b0e1abd576f279c4b2e0feb85c1f28ff18f58891ffef132eef2fa09346aee33c28eb130ff2",
        "8f5b766953334113211996d20011a198e3fc433f9f2541010ae17c1bf202580f6047472fb36857fe843b19f5984009dd",
        "c324044e847a4f4a0ab34f719595de37252d6235365e9b84392b061085349d73203a4a13e96f5432ec0fd4a1ee65accd",
        "d5e3904df54c1da510b0ff20dcc0c77fcb2c0e0eb605cb0504db87632cf3d8b4dae6e705769d1de354270123cb11450e",
        "fc60ac47683d7b8d0f811365565fd98c4c8eb936bcab8d069fc33bd801b03adea2e1fbc5aa463d08ca19896d2bf59a07",
        "1b851e6c239052172f296bfb5e72404790a2181014f3b94a4e97d117b438130368cc39dbb2d198065ae3986547926cd2",
        "162f40a29f0c3c8745c0f50fba3852e566d44575c29d39a03f0cda721984b6f440591f355e12d439ff150aab7613499d",
        "bd49adabc8676eef023b15b65bfc5ca06948109f23f350db82123535eb8a7433bdabcb909271a6ecbcb58b936a88cd4e",
        "8f2e6ff5800175f113253d8fa9ca8885c2f552e657dc603f252e1a8e308f76f0be79e2fb8f5d5fbbe2e30ecadd220723",
        "c8c0aea8078cdfcb3868263ff8f0940054da48781893a7e49ad5aff4af300cd804a6b6279ab3ff3afb64491c85194aab",
        "760d58a606654f9f4400e8b38591356fbf6425aca26dc85244259ff2b19c41b9f96f3ca9ec1dde434da7d2d392b905dd",
        "f3d1f9af93d1af5950bd493f5aa731b4056df31bd267b6b90a079831aaf579be0a39013137aac6d404f518cfd4684064",
        "7e78bfe706ca4cf5e9c5453e9f7cfd2b8b4c8d169a44e55c88d4a9a7f9474241e221af44860018ab0856972e194cd934",
    ])
    /// RFC 9369 section A.2, "The resulting protected packet".
    static let v2Packet = hex([
        "d76b3343cf088394c8f03e5157080000449ea0c95e82ffe67b6abcdb4298b485dd04de806071bf03dceebfa162e75d6c",
        "96058bdbfb127cdfcbf903388e99ad049f9a3dd4425ae4d0992cfff18ecf0fdb5a842d09747052f17ac2053d21f57c5d",
        "250f2c4f0e0202b70785b7946e992e58a59ac52dea6774d4f03b55545243cf1a12834e3f249a78d395e0d18f4d766004",
        "f1a2674802a747eaa901c3f10cda5500cb9122faa9f1df66c392079a1b40f0de1c6054196a11cbea40afb6ef5253cd68",
        "18f6625efce3b6def6ba7e4b37a40f7732e093daa7d52190935b8da58976ff3312ae50b187c1433c0f028edcc4c2838b",
        "6a9bfc226ca4b4530e7a4ccee1bfa2a3d396ae5a3fb512384b2fdd851f784a65e03f2c4fbe11a53c7777c023462239dd",
        "6f7521a3f6c7d5dd3ec9b3f233773d4b46d23cc375eb198c63301c21801f6520bcfb7966fc49b393f0061d974a2706df",
        "8c4a9449f11d7f3d2dcbb90c6b877045636e7c0c0fe4eb0f697545460c806910d2c355f1d253bc9d2452aaa549e27a1f",
        "ac7cf4ed77f322e8fa894b6a83810a34b361901751a6f5eb65a0326e07de7c1216ccce2d0193f958bb3850a833f7ae43",
        "2b65bc5a53975c155aa4bcb4f7b2c4e54df16efaf6ddea94e2c50b4cd1dfe06017e0e9d02900cffe1935e0491d77ffb4",
        "fdf85290fdd893d577b1131a610ef6a5c32b2ee0293617a37cbb08b847741c3b8017c25ca9052ca1079d8b78aebd4787",
        "6d330a30f6a8c6d61dd1ab5589329de714d19d61370f8149748c72f132f0fc99f34d766c6938597040d8f9e2bb522ff9",
        "9c63a344d6a2ae8aa8e51b7b90a4a806105fcbca31506c446151adfeceb51b91abfe43960977c87471cf9ad4074d30e1",
        "0d6a7f03c63bd5d4317f68ff325ba3bd80bf4dc8b52a0ba031758022eb025cdd770b44d6d6cf0670f4e990b22347a7db",
        "848265e3e5eb72dfe8299ad7481a408322cac55786e52f633b2fb6b614eaed18d703dd84045a274ae8bfa73379661388",
        "d6991fe39b0d93debb41700b41f90a15c4d526250235ddcd6776fc77bc97e7a417ebcb31600d01e57f32162a8560cacc",
        "7e27a096d37a1a86952ec71bd89a3e9a30a2a26162984d7740f81193e8238e61f6b5b984d4d3dfa033c1bb7e4f0037fe",
        "bf406d91c0dccf32acf423cfa1e7071010d3f270121b493ce85054ef58bada42310138fe081adb04e2bd901f2f13458b",
        "3d6758158197107c14ebb193230cd1157380aa79cae1374a7c1e5bbcb80ee23e06ebfde206bfb0fcbc0edc4ebec30966",
        "1bdd908d532eb0c6adc38b7ca7331dce8dfce39ab71e7c32d318d136b6100671a1ae6a6600e3899f31f0eed19e3417d1",
        "34b90c9058f8632c798d4490da4987307cba922d61c39805d072b589bd52fdf1e86215c2d54e6670e07383a27bbffb5a",
        "ddf47d66aa85a0c6f9f32e59d85a44dd5d3b22dc2be80919b490437ae4f36a0ae55edf1d0b5cb4e9a3ecabee93dfc6e3",
        "8d209d0fa6536d27a5d6fbb17641cde27525d61093f1b28072d111b2b4ae5f89d5974ee12e5cf7d5da4d6a31123041f3",
        "3e61407e76cffcdcfd7e19ba58cf4b536f4c4938ae79324dc402894b44faf8afbab35282ab659d13c93f70412e85cb19",
        "9a37ddec600545473cfb5a05e08d0b209973b2172b4d21fb69745a262ccde96ba18b2faa745b6fe189cf772a9f84cbfc",
    ])

    static func version(_ number: UInt32) -> QuicInitial.Version {
        QuicInitial.versions.first { $0.number == number }!
    }

    // MARK: Building protected packets, for the tests that need hellos the RFCs don't publish

    static func varint(_ value: Int) -> [UInt8] {
        switch value {
        case ..<64: return [UInt8(value)]
        case ..<16_384: return [UInt8(0x40 | value >> 8), UInt8(value & 0xFF)]
        default: return [0x80 | UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }
    }

    static func crypto(_ offset: Int, _ data: ArraySlice<UInt8>) -> [UInt8] {
        [0x06] + varint(offset) + varint(data.count) + data
    }

    /// A client Initial (or, with `type`, another long-header packet) protected as RFC 9001 section 5 says, with a
    /// 4-byte packet number. `padTo` pads the payload with PADDING frames so the packet is that long.
    static func packet(_ frames: [UInt8], number: UInt32 = 0, version: UInt32 = 1, dcid: [UInt8] = Self.dcid, type: UInt8? = nil,
                       padTo: Int? = nil) -> [UInt8] {
        let info = Self.version(version)
        let keys = QuicInitial.clientKeys(dcid: dcid, version: info)
        let packetType = type ?? info.initialType
        var header: [UInt8] = [0xC0 | packetType << 4 | 3]
        header += [UInt8(version >> 24), UInt8(version >> 16 & 0xFF), UInt8(version >> 8 & 0xFF), UInt8(version & 0xFF)]
        header += [UInt8(dcid.count)] + dcid + [0]
        if packetType == info.initialType { header += [0] }                                  // no token
        var payload = frames
        if let padTo {
            let fixed = header.count + 2 + 4 + 16
            if fixed + payload.count < padTo { payload += [UInt8](repeating: 0, count: padTo - fixed - payload.count) }
        }
        let length = 4 + payload.count + 16
        header += [UInt8(0x40 | length >> 8), UInt8(length & 0xFF)]
        let pnOffset = header.count
        let pn: [UInt8] = [UInt8(number >> 24), UInt8(number >> 16 & 0xFF), UInt8(number >> 8 & 0xFF), UInt8(number & 0xFF)]
        header += pn
        var nonce = keys.iv
        for i in 0..<4 { nonce[8 + i] ^= pn[i] }
        let sealed = try! AES.GCM.seal(payload, using: SymmetricKey(data: keys.key), nonce: AES.GCM.Nonce(data: nonce), authenticating: header)
        let body = [UInt8](sealed.ciphertext) + [UInt8](sealed.tag)
        let mask = QuicInitial.mask(hp: keys.hp, sample: body[0..<16])!
        header[0] ^= mask[0] & 0x0F
        for i in 0..<4 { header[pnOffset + i] ^= mask[1 + i] }
        return header + body
    }

    /// A ClientHello handshake message (no TLS record), naming `host`, with `padding` bytes of padding extension.
    static func hello(_ host: String?, padding: Int = 0, ech: Bool = false) -> [UInt8] {
        func extensionBlock(_ type: UInt16, _ body: [UInt8]) -> [UInt8] {
            [UInt8(type >> 8), UInt8(type & 0xFF), UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body
        }
        // Padding first, so the name is far into the hello, as Chrome's shuffled extensions and big key shares put it.
        var extensions = extensionBlock(0x0015, [UInt8](repeating: 0, count: padding))
        if ech { extensions += extensionBlock(0xFE0D, [0, 0, 1, 0, 1, 7, 0, 0, 0, 0]) }
        if let host {
            let name = Array(host.utf8)
            let list: [UInt8] = [0, UInt8(name.count >> 8), UInt8(name.count & 0xFF)] + name
            extensions += extensionBlock(0x0000, [UInt8(list.count >> 8), UInt8(list.count & 0xFF)] + list)
        }
        var body: [UInt8] = [0x03, 0x03] + [UInt8](repeating: 7, count: 32) + [0] + [0x00, 0x02, 0x13, 0x01] + [0x01, 0x00]
        body += [UInt8(extensions.count >> 8), UInt8(extensions.count & 0xFF)] + extensions
        return [0x01, UInt8(body.count >> 16), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)] + body
    }

    // MARK: The published vectors

    @Test func derivesTheRFC9001ClientKeys() {
        // RFC 9001 section A.1.
        let keys = QuicInitial.clientKeys(dcid: Self.dcid, version: Self.version(1))
        #expect(keys.key == Self.hex(["1f369613dd76d5467730efcbe3b1a22d"]))
        #expect(keys.iv == Self.hex(["fa044b2f42a3fd3b46fb255c"]))
        #expect(keys.hp == Self.hex(["9f50449e04a0e810283a1e9933adedd2"]))
        // RFC 9001 section A.2: the header-protection mask of the published sample.
        #expect(QuicInitial.mask(hp: keys.hp, sample: Self.hex(["d1b1c98dd7689fb8ec11d242b123dc9b"])[...])?.prefix(5) == Self.hex(["437b9aec36"])[...])
    }

    @Test func derivesTheRFC9369ClientKeys() {
        // RFC 9369 section A.1.
        let keys = QuicInitial.clientKeys(dcid: Self.dcid, version: Self.version(0x6b33_43cf))
        #expect(keys.key == Self.hex(["8b1a0bc121284290a29e0971b5cd045d"]))
        #expect(keys.iv == Self.hex(["91f73e2351d8fa91660e909f"]))
        #expect(keys.hp == Self.hex(["45b95e15235d6f45a6b19cbcb0294ba9"]))
        #expect(QuicInitial.mask(hp: keys.hp, sample: Self.hex(["ffe67b6abcdb4298b485dd04de806071"])[...])?.prefix(5) == Self.hex(["94a0c95e80"])[...])
    }

    @Test func readsTheNameFromTheRFC9001ClientInitial() {
        #expect(Self.v1Packet.count == 1_200)
        #expect(QuicInitial.serverName(datagrams: [Data(Self.v1Packet)]) == .name("example.com"))
        // The published CRYPTO frame, padded and protected with packet number 2 as section A.2 says, is the published
        // packet byte for byte: the decryption above read exactly the published ClientHello.
        #expect(Self.packet(Self.cryptoFrame, number: 2, padTo: 1_200) == Self.v1Packet)
    }

    @Test func readsTheNameFromTheRFC9369ClientInitial() {
        #expect(Self.v2Packet.count == 1_200)
        #expect(QuicInitial.serverName(datagrams: [Data(Self.v2Packet)]) == .name("example.com"))
        #expect(Self.packet(Self.cryptoFrame, number: 2, version: 0x6b33_43cf, padTo: 1_200) == Self.v2Packet)
    }

    @Test func aChangedByteInTheVectorIsNotRead() {
        for at in Self.v1Packet.indices {
            var packet = Self.v1Packet
            packet[at] ^= 0x01
            #expect(QuicInitial.serverName([packet]) != .name("example.com"), "byte \(at)")
        }
    }

    @Test func everyTruncationOfTheVectorReadsNoName() {
        for count in 0..<Self.v1Packet.count {
            let result = QuicInitial.serverName([Array(Self.v1Packet.prefix(count))])
            #expect(result == .notInitial || result == .needMore, "\(count) bytes")
        }
        for count in 0..<Self.v2Packet.count {
            if case .name = QuicInitial.serverName([Array(Self.v2Packet.prefix(count))]) { Issue.record("v2, \(count) bytes") }
        }
    }

    // MARK: Hellos across packets and datagrams

    @Test func readsAHelloSplitAcrossTwoDatagramsOutOfOrder() {
        let hello = Self.hello("blocked.example", padding: 1_800)
        #expect(hello.count > 1_800)
        // Chrome's way: fragments shuffled, the first datagram carrying the end and the start but not the name.
        let a = hello[0..<300], b = hello[300..<1_100], c = hello[1_100...]
        let first = Self.packet(Self.crypto(1_100, c[1_100..<1_400]) + Self.crypto(0, a), number: 0, padTo: 1_250)
        let second = Self.packet(Self.crypto(300, b) + [0x01] + Self.crypto(1_400, c[1_400...]), number: 1, padTo: 1_250)
        #expect(QuicInitial.serverName([first]) == .needMore)
        #expect(QuicInitial.serverName([first, second]) == .name("blocked.example"))
        // Arrival order doesn't matter: CRYPTO data is placed by offset.
        #expect(QuicInitial.serverName([second, first]) == .name("blocked.example"))
        // Overlapping retransmissions are harmless.
        #expect(QuicInitial.serverName([first, first, second]) == .name("blocked.example"))
    }

    @Test func readsCoalescedPacketsInOneDatagram() {
        let hello = Self.hello("blocked.example", padding: 400)
        let half = hello.count / 2
        let one = Self.packet(Self.crypto(half, hello[half...]), number: 0)
        let two = Self.packet(Self.crypto(0, hello[..<half]), number: 1)
        let zeroRTT = Self.packet([0x01], number: 2, type: 1)                                       // v1 0-RTT
        let datagram = one + zeroRTT + two + [UInt8](repeating: 0, count: 64)
        #expect(QuicInitial.serverName([datagram]) == .name("blocked.example"))
        // As one buffer, two datagrams one after the other read the same way.
        #expect(QuicInitial.serverName([one + [UInt8](repeating: 0, count: 30) + two]) == .name("blocked.example"))
    }

    @Test func aPacketForAnotherConnectionIDIsIgnored() {
        let hello = Self.hello("blocked.example")
        let real = Self.packet(Self.crypto(0, hello[..<20]), number: 0)
        let other = Self.packet(Self.crypto(20, hello[20...]), number: 1, dcid: Array(repeating: 9, count: 8))
        #expect(QuicInitial.serverName([real, other]) == .needMore)
    }

    @Test func aHelloWithoutAReadableNameIsUnreadable() {
        #expect(QuicInitial.serverName([Self.packet(Self.crypto(0, Self.hello(nil)[...]), padTo: 1_200)]) == .unreadable)
        #expect(QuicInitial.serverName([Self.packet(Self.crypto(0, Self.hello("192.0.2.1")[...]), padTo: 1_200)]) == .unreadable)
        // A CRYPTO stream that isn't a ClientHello.
        #expect(QuicInitial.serverName([Self.packet(Self.crypto(0, [2, 0, 0, 4, 1, 2, 3, 4]), padTo: 1_200)]) == .unreadable)
    }

    @Test func givesUpAfterTheDatagramLimit() {
        let hello = Self.hello("blocked.example", padding: 4_000)
        // Only the first 40 bytes ever arrive, in eight retransmissions: no name, and no more waiting.
        let partial = Self.packet(Self.crypto(0, hello[..<40]), padTo: 1_200)
        #expect(QuicInitial.serverName(Array(repeating: partial, count: 7)) == .needMore)
        #expect(QuicInitial.serverName(Array(repeating: partial, count: 8)) == .unreadable)
        #expect(QuicInitial.serverName(Array(repeating: partial, count: 50)) == .unreadable)
        // A hello larger than the reassembly buffer.
        let huge = Self.hello("blocked.example", padding: 17_000)
        #expect(QuicInitial.serverName([Self.packet(Self.crypto(0, huge[..<1_000]))]) == .unreadable)
        // Far more CRYPTO frames than are kept.
        var tiny: [UInt8] = []
        for offset in stride(from: 0, to: 200, by: 2) { tiny += Self.crypto(offset, hello[offset..<(offset + 2)]) }
        #expect(QuicInitial.serverName([Self.packet(tiny)]) == .unreadable)
    }

    // MARK: Not QUIC Initials

    @Test func otherPacketsAreNotInitials() {
        let hello = Self.crypto(0, Self.hello("blocked.example")[...])
        #expect(QuicInitial.serverName([Self.packet(hello, type: 2, padTo: 1_200)]) == .notInitial)        // v1 Handshake
        #expect(QuicInitial.serverName([Self.packet(hello, type: 1, padTo: 1_200)]) == .notInitial)        // v1 0-RTT
        // Short header: the fixed bit without the long-header bit.
        #expect(QuicInitial.serverName([[0x40] + Self.dcid + [UInt8](repeating: 0x55, count: 1_100)]) == .notInitial)
        // Version negotiation (version 0) and unknown versions, such as draft 29 and a grease version.
        var negotiation = Self.v1Packet; negotiation[1...4] = [0, 0, 0, 0]
        #expect(QuicInitial.serverName([negotiation]) == .notInitial)
        var draft = Self.v1Packet; draft[1...4] = [0xFF, 0, 0, 0x1D]
        #expect(QuicInitial.serverName([draft]) == .notInitial)
        var grease = Self.v1Packet; grease[1...4] = [0x1A, 0x2A, 0x3A, 0x4A]
        #expect(QuicInitial.serverName([grease]) == .notInitial)
        // A TLS record, DNS and nothing at all.
        #expect(QuicInitial.serverName([[0x16, 3, 1, 0, 5, 1, 0, 0, 1, 0]]) == .notInitial)
        #expect(QuicInitial.serverName([[0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]]) == .notInitial)
        #expect(QuicInitial.serverName([]) == .needMore)
        #expect(QuicInitial.serverName([[]]) == .needMore)
    }

    @Test func hostileFramesEndReadingWithoutAName() {
        let cases: [[UInt8]] = [
            [0x06] + Self.varint(16_000) + Self.varint(100) + [UInt8](repeating: 1, count: 100),    // past the buffer
            [0x06, 0x00, 0x80, 0xFF, 0xFF, 0xFF, 0x01],                                           // length past the payload
            [0x06, 0xC0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x01],                   // 8-byte offset
            [0x02, 0x00, 0x00, 0xBF, 0xFF, 0x00],                                                 // ACK claiming many ranges
            [0x03, 0x00, 0x00, 0x00, 0x00, 0x01],                                                 // ACK_ECN cut short
            [0x1C, 0x00, 0x00, 0x00],                                                             // CONNECTION_CLOSE
            [0x08, 0x00, 0x00],                                                                   // STREAM, not allowed
            [0xFF],                                                                               // a cut varint
        ]
        for frames in cases {
            let result = QuicInitial.serverName([Self.packet(frames, padTo: 1_200)])
            #expect(result == .needMore || result == .unreadable, "\(frames.prefix(4))")
        }
    }

    @Test func randomBytesNeverCrashOrName() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        for round in 0..<3_000 {
            let count = Int(next() % 1_500)
            var bytes = (0..<count).map { _ in UInt8(truncatingIfNeeded: next()) }
            // Half the rounds look like a v1 or v2 Initial, so parsing gets past the first checks.
            if round % 2 == 0, bytes.count > 6 {
                bytes[0] = round % 4 == 0 ? 0xC3 : 0xD3
                bytes[1...4] = round % 4 == 0 ? [0, 0, 0, 1] : [0x6B, 0x33, 0x43, 0xCF]
                bytes[5] = UInt8(next() % 21)
            }
            if case .name = QuicInitial.serverName([bytes, bytes.reversed()]) { Issue.record("round \(round)") }
        }
    }

    @Test func timesTheRFCVector() {
        let datagrams = [Data(Self.v1Packet)]
        var named = 0
        let rounds = 2_000
        let start = ContinuousClock.now
        for _ in 0..<rounds where QuicInitial.serverName(datagrams: datagrams) == .name("example.com") { named += 1 }
        let elapsed = ContinuousClock.now - start
        #expect(named == rounds)
        let micros = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
        print("QuicInitial: RFC 9001 client Initial parsed in \(String(format: "%.1f", micros / Double(rounds))) µs per call, \(rounds) calls")
    }
}

/// What the filter does with a QUIC flow's bytes, and how a name read there is judged.
struct QuicFlowSniffTests {
    typealias Q = QuicInitialTests

    @Test func readsOnlyNamelessUDPTo443() {
        #expect(QuicFlowSniff.applies(port: "443", host: nil))
        #expect(!QuicFlowSniff.applies(port: "443", host: "named.example"))
        #expect(!QuicFlowSniff.applies(port: "3478", host: nil))                                // a call's STUN/TURN
        #expect(!QuicFlowSniff.applies(port: nil, host: nil))                                   // an unconnected socket
    }

    @Test func readsTheNameFromChunksAsTheyArrive() {
        var sniff = QuicFlowSniff()
        #expect(sniff.add(Data(Q.v1Packet)) == .name("example.com"))

        let hello = Q.hello("blocked.example", padding: 1_800)
        let first = Q.packet(Q.crypto(1_100, hello[1_100...]) + Q.crypto(0, hello[..<300]), number: 0, padTo: 1_250)
        let second = Q.packet(Q.crypto(300, hello[300..<1_100]), number: 1, padTo: 1_250)
        var split = QuicFlowSniff()
        #expect(split.add(Data(first)) == .more)
        #expect(split.add(Data(second)) == .name("blocked.example"))
        // A datagram cut across two callbacks reads the same.
        var cut = QuicFlowSniff()
        #expect(cut.add(Data(first + second.prefix(500))) == .more)
        #expect(cut.add(Data(second.dropFirst(500))) == .name("blocked.example"))
    }

    @Test func allowsWhatItCannotRead() {
        var other = QuicFlowSniff()
        #expect(other.add(Data([0x16, 3, 1, 0, 5, 1, 0, 0, 1, 0])) == .allow)                 // not QUIC
        var noName = QuicFlowSniff()
        #expect(noName.add(Data(Q.packet(Q.crypto(0, Q.hello(nil)[...]), padTo: 1_200))) == .allow)
        // A hello that never completes: reading stops after eight callbacks.
        let partial = Data(Q.packet(Q.crypto(0, Q.hello("blocked.example", padding: 4_000)[..<40]), padTo: 1_200))
        var slow = QuicFlowSniff()
        for _ in 0..<7 { #expect(slow.add(partial) == .more) }
        #expect(slow.add(partial) == .allow)
        // More bytes than are kept.
        var flood = QuicFlowSniff()
        #expect(flood.add(partial) == .more)
        #expect(flood.add(Data(count: 16_000)) == .allow)
    }

    @Test func visibleServerNameStillWorksWithAnEncryptedClientHelloExtension() {
        var sniff = QuicFlowSniff()
        let hello = Q.hello("blocked.example", ech: true)
        let first = Q.packet(Q.crypto(0, hello[..<40]), padTo: 1_200)
        let second = Q.packet(Q.crypto(40, hello[40...]), number: 2, padTo: 1_200)
        #expect(sniff.add(Data(first)) == .more)
        #expect(sniff.add(Data(second)) == .name("blocked.example"))
    }

    static func policy(blocked: [String] = [], threats: Bool = false, trackers: Bool = false) -> FilterPolicy {
        var preferences = SavedPreferences(); preferences.profile = .travel; preferences.defaultAllow = true
        preferences.blockedDomains = blocked
        var policy = FilterPolicy(FilterController.policy(preferences, budgetReached: false, boot: "A", uptime: 100), boot: "A", uptime: 100)
        policy.protection = ProtectionSettings(threats: threats, trackers: trackers)
        return policy
    }
    static let chrome = FilterPolicy.Flow(app: "com.google.Chrome", process: "Google Chrome Helper", host: nil, address: "203.0.113.9", port: "443")

    @Test func aNameFromQUICIsJudgedLikeANameFromTLS() {
        var sniff = QuicFlowSniff()
        guard case .name(let name) = sniff.add(Data(Q.v1Packet)) else { Issue.record("no name"); return }
        var named = Self.chrome; named.host = name
        // The blocklist: the same block the TCP path records.
        let blocklist = Self.policy(blocked: ["example.com"])
        #expect(blocklist.inspectsHostnames)
        #expect(blocklist.sniffedBlock(named, explicit: false, index: nil, agent: { nil })?.reason == .blocklist("example.com"))
        #expect(blocklist.sniffedBlock(Self.chrome, explicit: false, index: nil, agent: { nil }) == nil)
        var other = Self.chrome; other.host = "fine.example"
        #expect(blocklist.sniffedBlock(other, explicit: false, index: nil, agent: { nil }) == nil)
        // Protection: a threat is blocked, a tracker only when the person's own rule didn't allow the connection.
        let index = ProtectionIndexTests.sample()
        let protection = Self.policy(threats: true, trackers: true)
        var evil = Self.chrome; evil.host = "a.evil.example"
        guard case .protection(let detail)? = protection.sniffedBlock(evil, explicit: false, index: index, agent: { nil })?.reason else {
            Issue.record("threat not blocked"); return
        }
        #expect(detail.host == "evil.example")                                                 // the list entry it matched
        var tracker = Self.chrome; tracker.host = "tracker.example"
        #expect(protection.sniffedBlock(tracker, explicit: false, index: index, agent: { nil }) != nil)
        #expect(protection.sniffedBlock(tracker, explicit: true, index: index, agent: { nil }) == nil)
        #expect(protection.sniffedBlock(tracker, explicit: false, guessed: true, index: index, agent: { nil }) == nil)
    }
}
