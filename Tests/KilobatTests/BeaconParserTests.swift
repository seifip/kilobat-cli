import Foundation
import Testing
@testable import KilobatCore

/// Beacons built byte by byte to 802.11-2020 and 802.11be's element layouts, the way an access point sends them.
enum BeaconFixture {
    static func element(_ id: UInt8, _ body: [UInt8]) -> [UInt8] { [id, UInt8(body.count)] + body }
    static func ext(_ id: UInt8, _ body: [UInt8]) -> [UInt8] { element(255, [id] + body) }
    static func ssid(_ name: String) -> [UInt8] { element(0, Array(name.utf8)) }
    /// Rates in Mbit/s; a negative one is basic.
    static func rates(_ values: [Double], selectors: [UInt8] = []) -> [UInt8] {
        element(1, values.map { value in UInt8(abs(value) * 2) | (value < 0 ? 0x80 : 0) } + selectors.map { $0 | 0x80 })
    }
    static func rsn(akms: [UInt8], pairwise: [UInt8] = [4], group: UInt8 = 4, capabilities: UInt16 = 0) -> [UInt8] {
        var body: [UInt8] = [1, 0, 0x00, 0x0F, 0xAC, group, UInt8(pairwise.count), 0]
        for cipher in pairwise { body += [0x00, 0x0F, 0xAC, cipher] }
        body += [UInt8(akms.count), 0]
        for akm in akms { body += [0x00, 0x0F, 0xAC, akm] }
        body += [UInt8(capabilities & 0xFF), UInt8(capabilities >> 8)]
        return element(48, body)
    }
    static func wpa(akm: UInt8 = 2, pairwise: UInt8 = 2) -> [UInt8] {
        element(221, [0x00, 0x50, 0xF2, 0x01, 1, 0, 0x00, 0x50, 0xF2, 2, 1, 0, 0x00, 0x50, 0xF2, pairwise, 1, 0, 0x00, 0x50, 0xF2, akm])
    }
    /// HT capabilities: 40 MHz support and one MCS byte per stream.
    static func ht(streams: Int, forty: Bool) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: 26)
        body[0] = forty ? 0x62 : 0x20
        for stream in 0..<streams { body[3 + stream] = 0xFF }
        return element(45, body)
    }
    static func htOperation(primary: UInt8, offset: UInt8) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: 22)
        body[0] = primary; body[1] = offset | (offset == 0 ? 0 : 0x04)
        return element(61, body)
    }
    /// A VHT or HE MCS map: `streams` streams at `value` (2 = MCS 0–9 or 0–11), the rest unsupported.
    static func map(streams: Int, value: UInt16 = 2) -> [UInt8] {
        var map: UInt16 = 0xFFFF
        for stream in 0..<streams { map &= ~(0x3 << (stream * 2)); map |= value << (stream * 2) }
        return [UInt8(map & 0xFF), UInt8(map >> 8)]
    }
    static func vht(streams: Int, wide: Bool) -> [UInt8] {
        element(191, [wide ? 0x04 : 0x00, 0, 0, 0] + map(streams: streams) + [0, 0] + map(streams: streams) + [0, 0])
    }
    static func vhtOperation(width: UInt8, seg0: UInt8, seg1: UInt8) -> [UInt8] { element(192, [width, seg0, seg1, 0xFC, 0xFF]) }
    /// HE capabilities: PHY byte 0 carries the channel-width set.
    static func he(streams: Int, widthSet: UInt8) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: 6 + 11)
        body[6] = widthSet
        return ext(35, body + map(streams: streams) + map(streams: streams))
    }
    /// HE operation; `sixGHz` adds the 6 GHz operation information (primary, control width, CCFS0, CCFS1, min rate).
    static func heOperation(sixGHz: (primary: UInt8, width: UInt8, seg0: UInt8, seg1: UInt8)? = nil) -> [UInt8] {
        var body: [UInt8] = [0x04, 0x00, sixGHz == nil ? 0x00 : 0x02, 0x01, 0xFC, 0xFF]
        if let six = sixGHz { body += [six.primary, six.width, six.seg0, six.seg1, 6] }
        return ext(36, body)
    }
    static func eht(streams: UInt8, has320: Bool) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: 2 + 9)
        body[2] = has320 ? 0x02 : 0x00
        let nss = streams | streams << 4
        body += [nss, nss, nss]
        if has320 { body += [nss, nss, nss, nss, nss, nss] }
        return ext(108, body)
    }
    static func ehtOperation(width: UInt8, ccfs0: UInt8, ccfs1: UInt8) -> [UInt8] { ext(106, [0x01, 0, 0, 0, 0, width, ccfs0, ccfs1]) }
    static func multiLink(mld: [UInt8]) -> [UInt8] { ext(107, [0x00, 0x00, 7] + mld) }
    /// A Reduced Neighbor Report entry with 16-byte TBTT information (MLD parameters included).
    static func rnr(opClass: UInt8, channel: UInt8, bssid: [UInt8], mldID: UInt8) -> [UInt8] {
        let header: UInt16 = 16 << 8
        return element(201, [UInt8(header & 0xFF), UInt8(header >> 8), opClass, channel, 0xFF] + bssid + [0x12, 0x34, 0x56, 0x78, 0x00, 0x00, mldID, 0x01, 0x00])
    }
}

struct BeaconParserTests {
    typealias F = BeaconFixture

    @Test func wifi7On6GHzWith320MHzAndMultiLink() {
        let mld: [UInt8] = [0x02, 0x00, 0x5E, 0x00, 0x53, 0x01]
        let beacon = F.ssid("Example 7") + F.rates([-6, 9, -12, 18, -24, 36, 48, 54], selectors: [123])
            + F.element(5, [0, 1, 0, 0]) + F.element(7, Array("US".utf8) + [0x04, 1, 233, 23])
            + F.rsn(akms: [8, 24], pairwise: [9], group: 9, capabilities: 0xC0)
            + F.he(streams: 2, widthSet: 0x0C) + F.heOperation(sixGHz: (37, 3, 39, 47))
            + F.eht(streams: 2, has320: true) + F.ehtOperation(width: 4, ccfs0: 47, ccfs1: 31)
            + F.multiLink(mld: mld) + F.rnr(opClass: 128, channel: 36, bssid: [0x00, 0x00, 0x5E, 0x00, 0x53, 0x02], mldID: 0)
        let details = BeaconParser.parse(Data(beacon), band: "6 GHz", channel: 37)
        #expect(details.generation == .wifi7)
        #expect(details.widthMHz == 320)
        #expect(details.centerChannel == 31)
        #expect(details.supportedWidthMHz == 320)
        #expect(details.streams == 2)
        #expect(details.maxRateMbps == 5764.7)
        #expect(details.country == "US")
        #expect(details.dtimPeriod == 1)
        #expect(details.rates == [6, 9, 12, 18, 24, 36, 48, 54])
        #expect(details.basicRates == [6, 12, 24])
        #expect(details.security?.summary == "WPA3 Personal")
        #expect(details.security?.keyManagement == ["SAE", "SAE-EXT-KEY"])
        #expect(details.security?.pairwiseCiphers == ["GCMP-256"])
        #expect(details.security?.pmf == .required)
        #expect(details.security?.h2eOnly == true)
        #expect(details.multiLink?.mldAddress == "02:00:5e:00:53:01")
        #expect(details.multiLink?.links == [.init(channel: 36, band: "5 GHz", bssid: "00:00:5e:00:53:02")])
    }

    @Test func wifi6TransitionWithFastRoamingAndLoad() {
        let beacon = F.ssid("Home") + F.rates([-6, 9, -12, 18, -24, 36, 48, 54])
            + F.element(5, [0, 3, 0, 0]) + F.element(7, Array("DE".utf8) + [0x20, 36, 4, 23])
            + F.element(11, [12, 0, 89, 0, 0]) + F.element(35, [20, 0])
            + F.rsn(akms: [2, 8, 4, 9], capabilities: 0x80)
            + F.element(54, [0xAB, 0xCD, 0x01]) + F.element(70, [0x73, 0, 0, 0, 0]) + F.element(127, [0, 0, 0x08, 0])
            + F.ht(streams: 4, forty: true) + F.htOperation(primary: 36, offset: 1)
            + F.vht(streams: 4, wide: false) + F.vhtOperation(width: 1, seg0: 42, seg1: 0)
            + F.he(streams: 4, widthSet: 0x04) + F.heOperation()
            + F.element(221, [0x00, 0x10, 0x18, 0x02, 0x00]) + F.element(221, [0x00, 0x50, 0xF2, 0x04, 0x10]) + F.element(221, [0x00, 0x50, 0xF2, 0x02, 0x01])
        let details = BeaconParser.parse(Data(beacon), band: "5 GHz", channel: 36)
        #expect(details.generation == .wifi6)
        #expect(details.widthMHz == 80)
        #expect(details.centerChannel == 42)
        #expect(details.streams == 4)
        #expect(details.maxRateMbps == 2402)
        #expect(details.security?.summary == "WPA2/WPA3 Personal")
        #expect(details.security?.transition == true)
        #expect(details.security?.pmf == .optional)
        #expect(details.security?.keyManagement == ["PSK", "SAE", "FT-PSK", "FT-SAE"])
        #expect(details.fastRoaming && details.mobilityDomain == "abcd")
        #expect(details.radioMeasurement && details.neighborReport)
        #expect(details.bssTransition)
        #expect(details.stations == 12)
        #expect(abs((details.channelUtilization ?? 0) - 89.0 / 255) < 0.0001)
        #expect(details.country == "DE")
        #expect(details.dtimPeriod == 3)
        #expect(details.transmitPowerDBm == 20)
        #expect(details.vendorElements == ["Broadcom"])
        #expect(details.wps)
        #expect(details.multiLink == nil)
    }

    @Test func wifi5At160MHzFromTheSecondSegment() {
        let beacon = F.ssid("Office") + F.rates([-6, 9, -12, 18, -24, 36, 48, 54]) + F.rsn(akms: [1], capabilities: 0)
            + F.ht(streams: 2, forty: true) + F.htOperation(primary: 100, offset: 1)
            + F.vht(streams: 2, wide: true) + F.vhtOperation(width: 1, seg0: 106, seg1: 114)
        let details = BeaconParser.parse(Data(beacon), band: "5 GHz", channel: 100)
        #expect(details.generation == .wifi5)
        #expect(details.widthMHz == 160)
        #expect(details.centerChannel == 114)
        #expect(details.supportedWidthMHz == 160)
        #expect(details.maxRateMbps == 1733.3)
        #expect(details.security?.summary == "WPA2 Enterprise")
    }

    @Test func wifi4On24GHzBelowWithLegacyWPA() {
        let beacon = F.ssid("Old") + F.rates([-1, -2, -5.5, -11, 6, 9, 12, 18]) + F.element(50, [24 * 2, 36 * 2, 48 * 2, 54 * 2])
            + F.wpa() + F.rsn(akms: [2], pairwise: [2, 4], group: 2)
            + F.ht(streams: 2, forty: true) + F.htOperation(primary: 11, offset: 3)
            // A Broadcom 2.4 GHz radio with 256-QAM still advertises VHT; it is not Wi-Fi 5.
            + F.vht(streams: 2, wide: false)
        let details = BeaconParser.parse(Data(beacon), band: "2.4 GHz", channel: 11)
        #expect(details.generation == .wifi4)
        #expect(details.widthMHz == 40)
        #expect(details.centerChannel == 9)
        #expect(details.maxRateMbps == 300)
        #expect(details.rates == [1, 2, 5.5, 6, 9, 11, 12, 18, 24, 36, 48, 54])
        #expect(details.basicRates == [1, 2, 5.5, 11])
        #expect(details.security?.summary == "WPA/WPA2 Personal")
        #expect(details.security?.legacyWPA == true)
        #expect(details.security?.groupCipher == "TKIP")
    }

    @Test func legacyAndOpenNetworks() {
        let b = BeaconParser.parse(Data(F.ssid("Cafe") + F.rates([-1, -2, -5.5, -11])), band: "2.4 GHz", channel: 6)
        #expect(b.generation == .b)
        #expect(b.security == nil)
        #expect(b.maxRateMbps == 11)
        let g = BeaconParser.parse(Data(F.ssid("Cafe") + F.rates([-1, -2, -5.5, -11, 6, 9, 12, 18, 24, 36, 48, 54])), band: "2.4 GHz", channel: 6)
        #expect(g.generation == .g)
        #expect(g.maxRateMbps == 54)
        let owe = BeaconParser.parse(Data(F.ssid("Free") + F.rates([-6, 12, 24]) + F.element(221, [0x50, 0x6F, 0x9A, 0x1C, 0, 0, 0x5E, 0, 0x53, 9, 0])),
                                     band: "5 GHz", channel: 44)
        #expect(owe.generation == .a)
        #expect(owe.security?.summary == "Open (OWE transition)")
        #expect(owe.security?.oweTransition == true)
        let enhanced = BeaconParser.parse(Data(F.rsn(akms: [18], capabilities: 0xC0)), band: "5 GHz", channel: 44)
        #expect(enhanced.security?.summary == "Enhanced Open (OWE)")
    }

    @Test func wifi6EUses6GHzOperationInfo() {
        let beacon = F.ssid("Six") + F.rates([-6, 12, 24]) + F.rsn(akms: [8], capabilities: 0xC0)
            + F.he(streams: 2, widthSet: 0x0C) + F.heOperation(sixGHz: (5, 3, 7, 15))
        let details = BeaconParser.parse(Data(beacon), band: "6 GHz", channel: 5)
        #expect(details.generation == .wifi6E)
        #expect(details.widthMHz == 160)
        #expect(details.centerChannel == 15)
        #expect(details.maxRateMbps == 2402)
        #expect(details.generation?.badge == "6E")
        #expect(details.generation?.standard == "802.11ax")
    }

    @Test func enterpriseVariants() {
        let wpa3 = BeaconParser.parse(Data(F.rsn(akms: [5], capabilities: 0xC0)), band: "5 GHz", channel: 36)
        #expect(wpa3.security?.summary == "WPA3 Enterprise")
        let mixed = BeaconParser.parse(Data(F.rsn(akms: [1, 5], capabilities: 0x80)), band: "5 GHz", channel: 36)
        #expect(mixed.security?.summary == "WPA2 Enterprise")
        let suiteB = BeaconParser.parse(Data(F.rsn(akms: [12], pairwise: [9], group: 9, capabilities: 0xC0)), band: "5 GHz", channel: 36)
        #expect(suiteB.security?.summary == "WPA3 Enterprise 192-bit")
    }

    @Test func malformedElementsAreDroppedNotGuessed() {
        // An HT capabilities element that claims 26 bytes and has 3, after a good SSID.
        let truncated = F.ssid("Edge") + [45, 26, 0x62, 0x00, 0x00]
        #expect(BeaconParser.elements(truncated).count == 1)
        let details = BeaconParser.parse(Data(truncated), band: "5 GHz", channel: 36)
        #expect(details.generation == .a)
        #expect(details.widthMHz == 20)
        // A too-short RSN element is no security information, not a crash.
        let short = BeaconParser.parse(Data(F.element(48, [1, 0, 0])), band: "5 GHz", channel: 36)
        #expect(short.security == nil)
        #expect(BeaconParser.parse(Data(), band: nil, channel: nil).generation == nil)
        // Random bytes never trap.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let bytes = (0..<Int.random(in: 0...300, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            _ = BeaconParser.parse(Data(bytes), band: ["2.4 GHz", "5 GHz", "6 GHz"].randomElement(), channel: 36)
        }
    }

    @Test func vendorElementsUseTheRegistryForOthers() {
        let beacon = F.element(221, [0x00, 0x0C, 0xE7, 0x01]) + F.element(221, [0xAA, 0xBB, 0xCC, 0x01]) + F.element(221, [0x50, 0x6F, 0x9A, 0x10])
        let details = BeaconParser.parse(Data(beacon), band: "5 GHz", channel: 36) { $0 == "AA:BB:CC" ? "Example Maker" : nil }
        #expect(details.vendorElements == ["MediaTek", "Example Maker"])
        #expect(details.passpoint)
    }

    @Test func phyRatesMatchPublishedTables() {
        #expect(PHYRate.ht(width: 20, streams: 1) == 72.2)
        #expect(PHYRate.ht(width: 40, streams: 3) == 450)
        #expect(PHYRate.vht(width: 80, streams: 1) == 433.3)
        #expect(PHYRate.vht(width: 80, streams: 3) == 1300)
        #expect(PHYRate.vht(width: 20, streams: 2) == 173.3)
        #expect(PHYRate.he(width: 80, streams: 2) == 1201)
        #expect(PHYRate.he(width: 160, streams: 2) == 2402)
        #expect(PHYRate.eht(width: 320, streams: 2) == 5764.7)
        #expect(PHYRate.eht(width: 160, streams: 2, mcs: 13) == 2882.4)
    }
}
