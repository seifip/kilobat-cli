import Foundation

/// What a Wi-Fi link negotiated besides its signal: the standard, the security and the transmit power, in words.
/// Works from CoreWLAN's raw values (CWPHYMode, CWSecurity, milliwatts), so it can be tested without a radio.
public enum WiFiLink {
    /// The 802.11 mode, such as "802.11ax", and the Wi-Fi Alliance's name for it, such as "Wi-Fi 6E" on 6 GHz.
    /// Modes older than 802.11n have no Wi-Fi number and keep their 802.11 name. Nil when not associated.
    public static func standard(phyMode: Int?, band: String?) -> (name: String, phy: String)? {
        switch phyMode {
        case 1: ("802.11a", "802.11a")
        case 2: ("802.11b", "802.11b")
        case 3: ("802.11g", "802.11g")
        case 4: ("Wi-Fi 4", "802.11n")
        case 5: ("Wi-Fi 5", "802.11ac")
        case 6: (band == "6 GHz" ? "Wi-Fi 6E" : "Wi-Fi 6", "802.11ax")
        case 7: ("Wi-Fi 7", "802.11be")
        default: nil
        }
    }

    public enum SecurityLevel: String, Codable, Sendable {
        /// WPA3, or Enhanced Open's encryption.
        case strong
        /// WPA2, alone or alongside WPA3.
        case good
        /// WEP or the first WPA: broken or outdated.
        case weak
        /// No encryption on the Wi-Fi itself.
        case open
    }
    public struct Security: Equatable, Sendable {
        public let name: String
        public let level: SecurityLevel
        /// What it means for someone on this network, when there is something to say.
        public let note: String?
    }

    /// CoreWLAN's CWSecurity raw value in words; nil for unknown.
    public static func security(_ raw: Int?) -> Security? {
        switch raw {
        case 0: Security(name: "Open", level: .open, note: String(localized: "This Wi-Fi has no password and no encryption: anyone nearby can see traffic that isn’t encrypted by the site or app itself, such as plain HTTP. Most sites and apps use HTTPS."))
        case 1: Security(name: "WEP", level: .weak, note: String(localized: "WEP can be broken in minutes. If this is your router, switch it to WPA2 or WPA3 in its settings."))
        case 6: Security(name: "Dynamic WEP", level: .weak, note: String(localized: "WEP can be broken in minutes. If this is your router, switch it to WPA2 or WPA3 in its settings."))
        case 2: Security(name: "WPA Personal", level: .weak, note: String(localized: "The first WPA is outdated and slows Wi-Fi down. If this is your router, switch it to WPA2 or WPA3 in its settings."))
        case 7: Security(name: "WPA Enterprise", level: .weak, note: String(localized: "The first WPA is outdated and slows Wi-Fi down. If this is your router, switch it to WPA2 or WPA3 in its settings."))
        case 3: Security(name: "WPA/WPA2 Personal", level: .weak, note: String(localized: "The first WPA is outdated and slows Wi-Fi down. If this is your router, switch it to WPA2 or WPA3 in its settings."))
        case 8: Security(name: "WPA/WPA2 Enterprise", level: .weak, note: String(localized: "The first WPA is outdated and slows Wi-Fi down. If this is your router, switch it to WPA2 or WPA3 in its settings."))
        case 4: Security(name: "WPA2 Personal", level: .good, note: nil)
        case 5: Security(name: "Personal", level: .good, note: nil)
        case 9: Security(name: "WPA2 Enterprise", level: .good, note: nil)
        case 10: Security(name: "Enterprise", level: .good, note: nil)
        case 11: Security(name: "WPA3 Personal", level: .strong, note: nil)
        case 12: Security(name: "WPA3 Enterprise", level: .strong, note: nil)
        case 13: Security(name: "WPA2/WPA3 Personal", level: .good, note: nil)
        case 14: Security(name: "Enhanced Open", level: .strong, note: String(localized: "Encrypted without a password: others nearby can’t read your traffic, but anyone can join."))
        case 15: Security(name: "Enhanced Open (transition)", level: .strong, note: String(localized: "Encrypted without a password: others nearby can’t read your traffic, but anyone can join."))
        default: nil
        }
    }

    /// The security `security(_:)` named, for a name saved or sent as text.
    public static func security(named name: String) -> Security? {
        securityValues.lazy.compactMap { security($0) }.first { $0.name == name }
    }

    /// The strongest security a nearby network offers, from the CWSecurity raw values it supports. A network that
    /// takes both WPA3 and WPA2 Personal is in WPA3's transition mode.
    public static func strongest(supported: Set<Int>) -> Int? {
        if supported.contains(11) && supported.contains(4) { return 13 }
        return [12, 11, 13, 9, 4, 8, 3, 10, 5, 7, 2, 14, 15, 6, 1, 0].first(where: supported.contains)
    }
    /// The CWSecurity raw values `strongest` looks at, for asking a network which it supports.
    public static let securityValues = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

    /// Transmit power in dBm from CoreWLAN's milliwatts; nil when macOS reports none.
    public static func dBm(milliwatts: Int?) -> Int? {
        guard let milliwatts, milliwatts > 0 else { return nil }
        return Int((10 * log10(Double(milliwatts))).rounded())
    }
}
