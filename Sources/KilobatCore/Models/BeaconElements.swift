import Foundation

/// The Wi-Fi generation an access point advertises, read from its beacon's capability elements.
public enum WiFiGeneration: String, Codable, Sendable, Comparable, CaseIterable {
    case b = "802.11b", a = "802.11a", g = "802.11g"
    case wifi4 = "Wi-Fi 4", wifi5 = "Wi-Fi 5", wifi6 = "Wi-Fi 6", wifi6E = "Wi-Fi 6E", wifi7 = "Wi-Fi 7"
    /// "Wi-Fi 6" for the badge; the 802.11 name alone before Wi-Fi 4.
    public var name: String { rawValue }
    /// The amendment, such as 802.11ax.
    public var standard: String {
        switch self {
        case .b, .a, .g: rawValue
        case .wifi4: "802.11n"
        case .wifi5: "802.11ac"
        case .wifi6, .wifi6E: "802.11ax"
        case .wifi7: "802.11be"
        }
    }
    /// A short badge for a list row: "6E", "7"; nil before Wi-Fi 4.
    public var badge: String? {
        switch self {
        case .b, .a, .g: nil
        case .wifi4: "4"
        case .wifi5: "5"
        case .wifi6: "6"
        case .wifi6E: "6E"
        case .wifi7: "7"
        }
    }
    private var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: WiFiGeneration, rhs: WiFiGeneration) -> Bool { lhs.order < rhs.order }
}

/// What an access point says about itself in its beacon: the information elements CoreWLAN hands over raw
/// (`CWNetwork.informationElementData`), plus the few fields CoreWLAN reads for us. Everything here is what the access
/// point advertises, not what it delivers: a rate is the most its radio could reach at that width, not a speed.
public struct AccessPointDetails: Codable, Sendable, Equatable {
    public var generation: WiFiGeneration?
    /// Spatial streams the access point can receive, from its highest-generation capability element.
    public var streams: Int?
    /// The top PHY rate at the operating width and the advertised streams, in Mbit/s.
    public var maxRateMbps: Double?
    /// The width the access point runs on now, from its operation elements (320 MHz included).
    public var widthMHz: Int?
    /// The widest channel its capabilities allow, which can be more than it uses.
    public var supportedWidthMHz: Int?
    /// The channel at the middle of a bonded 40, 80, 160 or 320 MHz channel.
    public var centerChannel: Int?
    /// Legacy rates it advertises, in Mbit/s, and the ones every client must support (basic).
    public var rates: [Double] = []
    public var basicRates: [Double] = []
    /// 802.11k: it answers neighbour-report requests, so clients find other access points without a full scan.
    public var radioMeasurement = false
    public var neighborReport = false
    /// 802.11v: it can suggest a better access point to a client (BSS transition management).
    public var bssTransition = false
    /// 802.11r: fast roaming between access points that share this mobility domain.
    public var fastRoaming = false
    public var mobilityDomain: String?
    /// The country its regulatory element names, such as "DE".
    public var country: String?
    /// Beacon interval in time units (1 TU = 1.024 ms) and how many beacons apart it sends buffered traffic (DTIM).
    public var beaconInterval: Int?
    public var dtimPeriod: Int?
    /// Clients the access point says it has, and how busy it says the channel is (0–1), from its BSS Load element.
    public var stations: Int?
    public var channelUtilization: Double?
    public var security: SecurityDetails?
    /// Wi-Fi 7 multi-link (MLO): the AP is one link of a multi-link device.
    public var multiLink: MultiLink?
    /// The maker of the access point's radio address, from the IEEE registry; nil for a private (locally administered) one.
    public var vendor: String?
    /// Makers named in vendor-specific elements, usually the Wi-Fi chip's (Broadcom, Qualcomm, MediaTek).
    public var vendorElements: [String] = []
    /// A name the access point broadcasts for itself (Cisco's element), when it does.
    public var apName: String?
    public var wps = false
    /// Hotspot 2.0 (Passpoint): the network can sign in with a carrier or provider profile.
    public var passpoint = false
    /// The power the access point says it transmits at, in dBm (its TPC report), when it says.
    public var transmitPowerDBm: Int?

    public init() {}

    public struct SecurityDetails: Codable, Sendable, Equatable {
        /// "WPA3 Personal", "WPA2/WPA3 Personal", "Enhanced Open (OWE)", "Open", …
        public var summary: String
        /// Key management suites, such as "SAE", "PSK", "FT-SAE", "802.1X".
        public var keyManagement: [String] = []
        /// Ciphers for unicast and group traffic, such as "CCMP-128" and "GCMP-256".
        public var pairwiseCiphers: [String] = []
        public var groupCipher: String?
        /// Protected management frames: required, optional or off.
        public var pmf: PMF = .off
        /// WPA2 and WPA3 (or WPA and WPA2) offered side by side, so older clients can join.
        public var transition = false
        /// An open network paired with a hidden Enhanced Open one (OWE transition mode).
        public var oweTransition = false
        /// SAE accepts only the hash-to-element method (H2E), as 6 GHz requires.
        public var h2eOnly = false
        /// Legacy WPA (TKIP) is offered.
        public var legacyWPA = false
        public enum PMF: String, Codable, Sendable { case required, optional, off }
        public init(summary: String) { self.summary = summary }
    }
    public struct MultiLink: Codable, Sendable, Equatable {
        /// The multi-link device's own address, shared by all its links.
        public var mldAddress: String?
        /// The other links this AP reports for the same device, from its Reduced Neighbor Report.
        public var links: [Link] = []
        public struct Link: Codable, Sendable, Equatable {
            public var channel: Int
            public var band: String
            public var bssid: String?
            public init(channel: Int, band: String, bssid: String?) { self.channel = channel; self.band = band; self.bssid = bssid }
        }
        public init() {}
    }
}

/// Reads a beacon's information elements: a run of (id, length, body) triples.
public enum BeaconParser {
    /// One element. `ext` is set for element 255, whose first body byte names the extension.
    public struct Element: Sendable, Equatable {
        public let id: UInt8
        public let ext: UInt8?
        public let body: [UInt8]
    }

    /// Every complete element; a truncated last one is dropped, not guessed at.
    public static func elements(_ data: [UInt8]) -> [Element] {
        var result: [Element] = [], offset = 0
        while offset + 2 <= data.count {
            let id = data[offset], length = Int(data[offset + 1])
            guard offset + 2 + length <= data.count else { break }
            let body = Array(data[(offset + 2)..<(offset + 2 + length)])
            if id == 255 {
                if let first = body.first { result.append(Element(id: id, ext: first, body: Array(body.dropFirst()))) }
            } else { result.append(Element(id: id, ext: nil, body: body)) }
            offset += 2 + length
        }
        return result
    }

    /// The details a beacon carries. `band` ("2.4 GHz", "5 GHz", "6 GHz") and `channel` come from CoreWLAN and decide the
    /// generation's name (Wi-Fi 6E is Wi-Fi 6 on 6 GHz) and widths. `vendorName` names an OUI (the IEEE table), for
    /// vendor-specific elements outside the few well-known chip makers.
    public static func parse(_ data: Data, band: String?, channel: Int?, vendorName: (String) -> String? = { _ in nil }) -> AccessPointDetails {
        parse(elements([UInt8](data)), band: band, channel: channel, vendorName: vendorName)
    }

    public static func parse(_ elements: [Element], band: String?, channel: Int?, vendorName: (String) -> String? = { _ in nil }) -> AccessPointDetails {
        var details = AccessPointDetails()
        func first(_ id: UInt8, ext: UInt8? = nil) -> [UInt8]? { elements.first { $0.id == id && $0.ext == ext }?.body }
        let low = band == "2.4 GHz", six = band == "6 GHz"

        // Legacy rates (1 and 50). Values above 54 Mbit/s are BSS membership selectors (HT, VHT, HE, SAE H2E), not rates.
        var selectors: Set<UInt8> = []
        for body in [first(1), first(50)].compactMap({ $0 }) {
            for byte in body {
                let value = byte & 0x7F
                if value > 108 { selectors.insert(value); continue }
                let rate = Double(value) / 2
                details.rates.append(rate)
                if byte & 0x80 != 0 { details.basicRates.append(rate) }
            }
        }
        details.rates = Array(Set(details.rates)).sorted(); details.basicRates = Array(Set(details.basicRates)).sorted()

        if let tim = first(5), tim.count >= 2, tim[1] > 0 { details.dtimPeriod = Int(tim[1]) }
        if let country = first(7), country.count >= 2 {
            let code = String(decoding: country.prefix(2), as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if code.count == 2, code.allSatisfy({ $0.isLetter }) { details.country = code.uppercased() }
        }
        if let load = first(11), load.count >= 3 {
            details.stations = Int(load[0]) | Int(load[1]) << 8
            details.channelUtilization = Double(load[2]) / 255
        }
        if let tpc = first(35), tpc.count >= 1 { details.transmitPowerDBm = Int(Int8(bitPattern: tpc[0])) }
        if let mobility = first(54), mobility.count >= 2 {
            details.fastRoaming = true
            details.mobilityDomain = String(format: "%02x%02x", mobility[0], mobility[1])
        }
        if let rm = first(70), !rm.isEmpty {
            details.radioMeasurement = true
            details.neighborReport = rm[0] & 0x02 != 0
        }
        if let extended = first(127), extended.count >= 3 { details.bssTransition = extended[2] & 0x08 != 0 }
        if let cisco = first(133), cisco.count >= 26 {
            let name = String(decoding: cisco[10..<26].prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, name.allSatisfy({ $0.isASCII && !$0.isNewline }) { details.apName = name }
        }

        // Capabilities: streams and the widest supported channel, per generation.
        let ht = first(45), vht = first(191), he = first(255, ext: 35), eht = first(255, ext: 108)
        var htStreams: Int?, vhtStreams: Int?, heStreams: Int?, ehtStreams: Int?
        var vhtTopMCS = 9, heTopMCS = 11
        var htWidth = 20, vhtWidth = 80, heWidth = 20
        if let ht, ht.count >= 7 {
            htStreams = max(1, ht[3..<7].filter { $0 != 0 }.count)
            if ht[0] & 0x02 != 0 { htWidth = 40 }
        }
        if let vht, vht.count >= 6 {
            let info = UInt32(vht[0]) | UInt32(vht[1]) << 8
            if (info >> 2) & 0x3 != 0 { vhtWidth = 160 }
            let map = UInt16(vht[4]) | UInt16(vht[5]) << 8
            (vhtStreams, vhtTopMCS) = streams(map, top: [7, 8, 9])
        }
        if let he, he.count >= 6 + 11 + 2 {
            let phy0 = he[6]
            if low { heWidth = phy0 & 0x02 != 0 ? 40 : 20 }
            else { heWidth = phy0 & 0x08 != 0 || phy0 & 0x10 != 0 ? 160 : phy0 & 0x04 != 0 ? 80 : 20 }
            let map = UInt16(he[17]) | UInt16(he[18]) << 8
            (heStreams, heTopMCS) = streams(map, top: [7, 9, 11])
        }
        var eht320 = false, ehtTopMCS = 13
        if let eht, eht.count >= 2 + 9 {
            eht320 = eht[2] & 0x02 != 0
            // Supported EHT-MCS and NSS set: for an AP the ≤80 MHz map, three bytes (MCS 0–9, 10–11, 12–13), Rx NSS in the low nibble.
            let nss = eht.dropFirst(11).prefix(3).map { Int($0 & 0x0F) }
            if let top = nss.max(), top > 0 {
                ehtStreams = top
                ehtTopMCS = nss.count > 2 && nss[2] > 0 ? 13 : nss.count > 1 && nss[1] > 0 ? 11 : 9
            }
        }

        // Operation: the width it runs now, and the centre of a bonded channel.
        var width = 20, center = channel
        if let op = first(61), op.count >= 2, let primary = Optional(Int(op[0])), primary > 0 {
            // A secondary channel counts only while the AP allows any width (bit 2).
            switch (op[1] & 0x03, op[1] & 0x04 != 0) {
            case (1, true): width = 40; center = primary + 2
            case (3, true): width = 40; center = primary - 2
            default: break
            }
        }
        // VHT operation, or the same three bytes inside HE operation on an AP that sends no VHT element.
        var vhtOperation = first(192)
        if vhtOperation == nil, let op = first(255, ext: 36), op.count >= 9, op[1] & 0x40 != 0 { vhtOperation = Array(op[6..<9]) }
        if !low, let op = vhtOperation, op.count >= 3, op[0] == 1 || op[0] == 2 || op[0] == 3 {
            let seg0 = Int(op[1]), seg1 = Int(op[2])
            if op[0] == 2 { width = 160; center = seg0 }
            else if op[0] == 3 { width = 160; center = seg0 }
            else if seg1 != 0 && abs(seg1 - seg0) == 8 { width = 160; center = seg1 }
            else if seg1 != 0 && abs(seg1 - seg0) > 16 { width = 160; center = seg0 } // 80+80: drawn as its first segment, counted as 160
            else if seg0 != 0 { width = 80; center = seg0 }
        }
        if let op = first(255, ext: 36), op.count >= 6 {
            let params = UInt32(op[0]) | UInt32(op[1]) << 8 | UInt32(op[2]) << 16
            var offset = 3 + 1 + 2
            if params & (1 << 14) != 0 { offset += 3 }
            if params & (1 << 15) != 0 { offset += 1 }
            if params & (1 << 17) != 0, op.count >= offset + 5 {
                let control = op[offset + 1] & 0x03, seg0 = Int(op[offset + 2]), seg1 = Int(op[offset + 3])
                switch control {
                case 3: width = 160; center = seg1 != 0 ? seg1 : seg0
                case 2: width = 80; center = seg0
                case 1: width = 40; center = seg0
                default: width = 20; center = seg0 != 0 ? seg0 : channel
                }
            }
        }
        if let op = first(255, ext: 106), op.count >= 5, op[0] & 0x01 != 0, op.count >= 8 {
            let control = op[5] & 0x07, ccfs0 = Int(op[6]), ccfs1 = Int(op[7])
            switch control {
            case 4: width = 320; center = ccfs1 != 0 ? ccfs1 : ccfs0
            case 3: width = 160; center = ccfs1 != 0 ? ccfs1 : ccfs0
            case 2: width = 80; center = ccfs0
            case 1: width = 40; center = ccfs0
            default: break
            }
        }
        details.widthMHz = width
        details.centerChannel = width > 20 ? center : channel

        // Generation, from the newest capability present. VHT on 2.4 GHz is a vendor extra (256-QAM), still Wi-Fi 4.
        let ofdm = details.rates.contains { [6, 9, 12, 18, 24, 36, 48, 54].contains($0) }
        if eht != nil { details.generation = .wifi7 }
        else if he != nil { details.generation = six ? .wifi6E : .wifi6 }
        else if vht != nil && !low { details.generation = .wifi5 }
        else if ht != nil { details.generation = .wifi4 }
        else if band == "5 GHz" { details.generation = .a }
        else if !details.rates.isEmpty { details.generation = ofdm ? .g : .b }

        switch details.generation {
        case .wifi7?:
            details.streams = ehtStreams ?? heStreams
            details.supportedWidthMHz = six && eht320 ? 320 : max(heWidth, width)
            details.maxRateMbps = PHYRate.eht(width: width, streams: details.streams ?? 1, mcs: ehtStreams == nil ? heTopMCS : ehtTopMCS)
        case .wifi6?, .wifi6E?:
            details.streams = heStreams
            details.supportedWidthMHz = max(heWidth, width)
            details.maxRateMbps = PHYRate.he(width: width, streams: details.streams ?? 1, mcs: heTopMCS)
        case .wifi5?:
            details.streams = vhtStreams ?? htStreams
            details.supportedWidthMHz = max(vhtWidth, width)
            details.maxRateMbps = PHYRate.vht(width: width, streams: details.streams ?? 1, mcs: vhtTopMCS)
        case .wifi4?:
            details.streams = htStreams
            details.supportedWidthMHz = max(htWidth, width)
            details.maxRateMbps = PHYRate.ht(width: min(width, 40), streams: details.streams ?? 1)
        default:
            details.maxRateMbps = details.rates.max()
        }

        details.security = security(elements, selectors: selectors)
        var makers: [String] = []
        for element in elements where element.id == 221 && element.body.count >= 3 {
            let oui = element.body.prefix(3).map { String(format: "%02X", $0) }.joined(separator: ":")
            let type = element.body.count > 3 ? element.body[3] : 0
            if oui == "00:50:F2" && type == 4 { details.wps = true }
            if oui == "50:6F:9A" && type == 0x10 { details.passpoint = true }
            if let name = knownVendors[oui] ?? (ignoredOUIs.contains(oui) ? nil : vendorName(oui)), !makers.contains(name) { makers.append(name) }
        }
        details.vendorElements = makers
        details.multiLink = multiLink(elements)
        return details
    }

    /// Streams and the highest MCS from a VHT or HE map: two bits per stream, 3 meaning unsupported.
    static func streams(_ map: UInt16, top: [Int]) -> (Int?, Int) {
        var count = 0, best = 0
        for stream in 0..<8 {
            let value = Int((map >> (stream * 2)) & 0x3)
            guard value != 3 else { continue }
            count = stream + 1; best = max(best, value)
        }
        return (count == 0 ? nil : count, top[min(best, top.count - 1)])
    }

    /// Vendor-specific element OUIs that name the Wi-Fi chip or the AP maker. Microsoft's (WMM, WPS), the Wi-Fi
    /// Alliance's and the IEEE's are protocol elements, not makers.
    static let knownVendors: [String: String] = [
        "00:10:18": "Broadcom", "00:90:4C": "Broadcom", "00:03:7F": "Qualcomm", "8C:FD:F0": "Qualcomm",
        "00:0C:E7": "MediaTek", "00:0C:43": "MediaTek", "00:E0:4C": "Realtek", "00:17:F2": "Apple",
        "00:40:96": "Cisco", "00:0B:86": "Aruba", "00:13:92": "Ruckus", "00:18:0A": "Cisco Meraki",
    ]
    static let ignoredOUIs: Set<String> = ["00:50:F2", "50:6F:9A", "00:0F:AC", "00:00:00"]

    // MARK: Security

    static let akmNames: [UInt8: String] = [1: "802.1X", 2: "PSK", 3: "FT-802.1X", 4: "FT-PSK", 5: "802.1X-SHA256", 6: "PSK-SHA256",
                                            8: "SAE", 9: "FT-SAE", 11: "802.1X Suite B", 12: "802.1X Suite B 192", 13: "FT-802.1X-SHA384",
                                            18: "OWE", 24: "SAE-EXT-KEY", 25: "FT-SAE-EXT-KEY"]
    static let cipherNames: [UInt8: String] = [1: "WEP-40", 2: "TKIP", 4: "CCMP-128", 5: "WEP-104", 6: "BIP-CMAC-128", 8: "GCMP-128", 9: "GCMP-256",
                                               10: "CCMP-256", 11: "BIP-GMAC-128", 12: "BIP-GMAC-256", 13: "BIP-CMAC-256"]

    static func security(_ elements: [Element], selectors: Set<UInt8>) -> AccessPointDetails.SecurityDetails? {
        let rsn = elements.first { $0.id == 48 && $0.body.count >= 6 }?.body
        let wpa = elements.first { $0.id == 221 && $0.body.count >= 10 && $0.body.starts(with: [0x00, 0x50, 0xF2, 0x01]) }?.body
        let oweTransition = elements.contains { $0.id == 221 && $0.body.starts(with: [0x50, 0x6F, 0x9A, 0x1C]) }
        var akms: [UInt8] = [], pairwise: [String] = [], group: String?, pmf = AccessPointDetails.SecurityDetails.PMF.off
        func suites(_ body: [UInt8], from offset: inout Int) -> [UInt8] {
            guard offset + 2 <= body.count else { return [] }
            let count = Int(body[offset]) | Int(body[offset + 1]) << 8
            offset += 2
            var values: [UInt8] = []
            for _ in 0..<count where offset + 4 <= body.count { values.append(body[offset + 3]); offset += 4 }
            return values
        }
        if let rsn, rsn.count >= 6 {
            var offset = 2
            group = cipherNames[rsn[offset + 3]]; offset += 4
            pairwise = suites(rsn, from: &offset).compactMap { cipherNames[$0] }
            akms = suites(rsn, from: &offset)
            if offset + 2 <= rsn.count {
                let capabilities = UInt16(rsn[offset]) | UInt16(rsn[offset + 1]) << 8
                pmf = capabilities & 0x40 != 0 ? .required : capabilities & 0x80 != 0 ? .optional : .off
            }
        }
        var legacy = false
        if let wpa, wpa.count >= 10 {
            legacy = true
            if rsn == nil {
                var offset = 6
                group = cipherNames[wpa[offset + 3]]; offset += 4
                pairwise = suites(wpa, from: &offset).compactMap { cipherNames[$0] }
                akms = suites(wpa, from: &offset)
            }
        }
        guard rsn != nil || wpa != nil || oweTransition else { return nil }
        let set = Set(akms)
        let sae = !set.isDisjoint(with: [8, 9, 24, 25]), psk = !set.isDisjoint(with: [2, 4, 6])
        let suiteB = !set.isDisjoint(with: [12, 13]), dot1x = !set.isDisjoint(with: [1, 3, 5, 11])
        let owe = set.contains(18)
        let summary: String
        var transition = false
        if rsn == nil && legacy { summary = psk ? "WPA Personal" : "WPA Enterprise" }
        else if owe { summary = "Enhanced Open (OWE)" }
        else if suiteB { summary = "WPA3 Enterprise 192-bit" }
        else if dot1x { summary = pmf == .required && set.isDisjoint(with: [1, 3]) ? "WPA3 Enterprise" : legacy ? "WPA/WPA2 Enterprise" : "WPA2 Enterprise"; transition = legacy }
        else if sae && psk { summary = "WPA2/WPA3 Personal"; transition = true }
        else if sae { summary = "WPA3 Personal" }
        else if psk { summary = legacy ? "WPA/WPA2 Personal" : "WPA2 Personal"; transition = legacy }
        else if oweTransition { summary = "Open (OWE transition)" }
        else { summary = "Unknown" }
        var details = AccessPointDetails.SecurityDetails(summary: summary)
        details.keyManagement = akms.compactMap { akmNames[$0] }
        details.pairwiseCiphers = pairwise
        details.groupCipher = group
        details.pmf = pmf
        details.transition = transition
        details.oweTransition = oweTransition
        details.h2eOnly = selectors.contains(123)
        details.legacyWPA = legacy || pairwise.contains("TKIP")
        return details
    }

    // MARK: Multi-link

    /// A Basic Multi-Link element (Wi-Fi 7 MLO) and the device's other links from the Reduced Neighbor Report.
    static func multiLink(_ elements: [Element]) -> AccessPointDetails.MultiLink? {
        guard let mle = elements.first(where: { $0.id == 255 && $0.ext == 107 })?.body, mle.count >= 2, mle[0] & 0x07 == 0 else { return nil }
        var link = AccessPointDetails.MultiLink()
        // Multi-link control (2 bytes), then common info: its length (1) and the MLD address (6).
        if mle.count >= 3 + 6 { link.mldAddress = mle[3..<9].map { String(format: "%02x", $0) }.joined(separator: ":") }
        for rnr in elements where rnr.id == 201 {
            let body = rnr.body
            var offset = 0
            while offset + 4 <= body.count {
                let header = UInt16(body[offset]) | UInt16(body[offset + 1]) << 8
                let count = Int((header >> 4) & 0x0F) + 1, length = Int(header >> 8)
                let opClass = body[offset + 2], channel = Int(body[offset + 3])
                offset += 4
                for _ in 0..<count {
                    guard length > 0, offset + length <= body.count else { offset = body.count; break }
                    let info = Array(body[offset..<(offset + length)])
                    offset += length
                    // TBTT info of 16 bytes ends with MLD parameters: AP MLD ID 0 is the reporting AP's own device.
                    guard length >= 16, info[13] == 0 else { continue }
                    let bssid = info[1..<7].map { String(format: "%02x", $0) }.joined(separator: ":")
                    if let band = band(operatingClass: opClass) { link.links.append(.init(channel: channel, band: band, bssid: bssid)) }
                }
            }
        }
        return link
    }

    /// The band of a global operating class (802.11 Annex E).
    public static func band(operatingClass: UInt8) -> String? {
        switch operatingClass {
        case 81...84: "2.4 GHz"
        case 115...130: "5 GHz"
        case 131...137: "6 GHz"
        default: nil
        }
    }
}

/// Top PHY rates: data subcarriers × bits per symbol × coding rate ÷ symbol time, times the streams.
public enum PHYRate {
    /// Bits per subcarrier and coding rate for MCS 0–13.
    static let modulation: [(bits: Double, rate: Double)] = [(1, 1.0 / 2), (2, 1.0 / 2), (2, 3.0 / 4), (4, 1.0 / 2), (4, 3.0 / 4), (6, 2.0 / 3), (6, 3.0 / 4), (6, 5.0 / 6),
                                                             (8, 3.0 / 4), (8, 5.0 / 6), (10, 3.0 / 4), (10, 5.0 / 6), (12, 3.0 / 4), (12, 5.0 / 6)]
    static func rate(subcarriers: Double, mcs: Int, symbolMicroseconds: Double, streams: Int) -> Double {
        let m = modulation[max(0, min(mcs, modulation.count - 1))]
        return (subcarriers * m.bits * m.rate / symbolMicroseconds * Double(max(1, streams)) * 10).rounded() / 10
    }
    /// 802.11n, short guard interval, MCS 7 per stream.
    public static func ht(width: Int, streams: Int) -> Double {
        rate(subcarriers: width >= 40 ? 108 : 52, mcs: 7, symbolMicroseconds: 3.6, streams: streams)
    }
    /// 802.11ac, short guard interval. MCS 9 isn't defined for one or two streams at 20 MHz, so 20 MHz tops out at MCS 8.
    public static func vht(width: Int, streams: Int, mcs: Int = 9) -> Double {
        let subcarriers: Double = switch width { case 160...: 468; case 80: 234; case 40: 108; default: 52 }
        return rate(subcarriers: subcarriers, mcs: width <= 20 ? min(mcs, 8) : mcs, symbolMicroseconds: 3.6, streams: streams)
    }
    /// 802.11ax, 0.8 µs guard interval (13.6 µs symbols).
    public static func he(width: Int, streams: Int, mcs: Int = 11) -> Double {
        rate(subcarriers: heSubcarriers(width), mcs: mcs, symbolMicroseconds: 13.6, streams: streams)
    }
    /// 802.11be, 0.8 µs guard interval, up to 4096-QAM (MCS 13) and 320 MHz.
    public static func eht(width: Int, streams: Int, mcs: Int = 13) -> Double {
        rate(subcarriers: heSubcarriers(width), mcs: mcs, symbolMicroseconds: 13.6, streams: streams)
    }
    static func heSubcarriers(_ width: Int) -> Double {
        switch width { case 320...: 3920; case 160..<320: 1960; case 80..<160: 980; case 40..<80: 468; default: 234 }
    }
}
