import Foundation

/// What kind of device made the Wi-Fi the Mac is on.
public enum SetupDeviceKind: String, Codable, Sendable, CaseIterable {
    case printer, camera, actionCamera, camera360, drone, smartHome
    /// A Wi-Fi Direct group whose maker the name doesn't say: a printer, TV, camera or phone.
    case directLink
}

/// The Mac joined a device's own Wi-Fi: a printer's Wi-Fi Direct or setup network, a camera's or drone's, a smart
/// plug's setup access point. There is no internet there by design, so it's said plainly and never counted as an outage.
public struct SetupNetworkMatch: Codable, Sendable, Equatable {
    public let kind: SetupDeviceKind
    public let maker: String?
    /// The table row that matched, for tests and the CLI.
    public let rule: String
    public init(kind: SetupDeviceKind, maker: String?, rule: String) { self.kind = kind; self.maker = maker; self.rule = rule }

    /// "your printer", "your HP printer", "a smart device".
    public var device: String {
        switch kind {
        case .printer: maker.map { String(localized: "your \($0) printer", comment: "Device Wi-Fi: the argument is a maker such as HP; reads on from “You’re on”") }
            ?? String(localized: "your printer", comment: "Device Wi-Fi; reads on from “You’re on”")
        case .camera: maker.map { String(localized: "your \($0) camera", comment: "Device Wi-Fi: the argument is a maker such as Sony") }
            ?? String(localized: "your camera", comment: "Device Wi-Fi")
        case .actionCamera: maker.map { String(localized: "your \($0)", comment: "Device Wi-Fi: the argument is an action camera such as GoPro") }
            ?? String(localized: "your action camera", comment: "Device Wi-Fi")
        case .camera360: maker.map { String(localized: "your \($0) 360° camera", comment: "Device Wi-Fi: the argument is a maker such as Insta360") }
            ?? String(localized: "your 360° camera", comment: "Device Wi-Fi")
        case .drone: maker.map { String(localized: "your \($0) drone", comment: "Device Wi-Fi: the argument is a maker such as DJI") }
            ?? String(localized: "your drone", comment: "Device Wi-Fi")
        case .smartHome: maker.map { String(localized: "a \($0) smart device", comment: "Device Wi-Fi: the argument is a maker such as Shelly") }
            ?? String(localized: "a smart device", comment: "Device Wi-Fi")
        case .directLink: String(localized: "a device", comment: "Device Wi-Fi: a Wi-Fi Direct network of unknown kind")
        }
    }

    /// "You’re on your printer’s own Wi-Fi; there’s no internet here, by design."
    public var headline: String {
        switch kind {
        case .smartHome:
            String(localized: "You’re on \(device)’s setup Wi-Fi; there’s no internet here, by design.", comment: "Device Wi-Fi headline; the argument is a phrase such as “a Shelly smart device”")
        case .directLink:
            String(localized: "You’re on a device’s own Wi-Fi Direct network, often a printer’s or a TV’s; there’s no internet here, by design.", comment: "Device Wi-Fi headline for an unknown Wi-Fi Direct network")
        default:
            String(localized: "You’re on \(device)’s own Wi-Fi; there’s no internet here, by design.", comment: "Device Wi-Fi headline; the argument is a phrase such as “your HP printer”")
        }
    }
    /// What to do: finish with the device, then go back.
    public func detail(previous: String?) -> String {
        let task: String
        switch kind {
        case .printer: task = String(localized: "Print or set it up from here.", comment: "Device Wi-Fi: what the network is for")
        case .camera, .actionCamera, .camera360, .drone: task = String(localized: "Copy your photos and videos from here.", comment: "Device Wi-Fi: what the network is for")
        case .smartHome: task = String(localized: "Finish the setup in its app.", comment: "Device Wi-Fi: what the network is for")
        case .directLink: task = String(localized: "Use the device from here.", comment: "Device Wi-Fi: what the network is for")
        }
        let back = previous.map { String(localized: "Go back to \($0) when you’re done.", comment: "Device Wi-Fi; the argument is the Wi-Fi the Mac was on before") }
            ?? String(localized: "Go back to your usual Wi-Fi when you’re done.", comment: "Device Wi-Fi")
        return [task, back, String(localized: "Kilobat doesn’t count this as an outage.", comment: "Device Wi-Fi")].joined(separator: " ")
    }
}

/// A small curated table of the names devices give their own Wi-Fi, from the makers' documentation. Each row's
/// `source` is the page the pattern comes from. Names are only
/// half the signal: `judge` also needs the internet to be unreachable (or no router at all), because anyone can name a
/// home network DIRECT-…, and a phone or laptop running Wi-Fi Direct can share its internet.
public enum SetupNetworks {
    public struct Rule: Sendable {
        public let id: String
        public let pattern: String
        public let kind: SetupDeviceKind
        public let maker: String?
        public let source: String
        let caseInsensitive: Bool
        init(_ id: String, _ pattern: String, _ kind: SetupDeviceKind, _ maker: String?, _ source: String, caseInsensitive: Bool = false) {
            self.id = id; self.pattern = pattern; self.kind = kind; self.maker = maker; self.source = source; self.caseInsensitive = caseInsensitive
        }
        func matches(_ ssid: String) -> Bool {
            ssid.range(of: pattern, options: caseInsensitive ? [.regularExpression, .caseInsensitive] : .regularExpression) != nil
        }
    }

    /// Specific rows first: the first match wins, and the generic Wi-Fi Direct prefix comes last.
    public static let rules: [Rule] = [
        Rule("hp-direct", #"^DIRECT-[A-Za-z0-9]{2}-HP[ -]"#, .printer, "HP", "https://support.hp.com/us-en/document/ish_1841315-1637332-16"),
        Rule("hp-print", #"^HP-Print-[A-Za-z0-9]{2}-"#, .printer, "HP", "https://support.hp.com/ca-en/document/c03353355"),
        Rule("hp-setup", #"^HP[-=]Setup"#, .printer, "HP", "https://support.hp.com/sg-en/document/ish_3967769-3956733-16"),
        Rule("brother-direct", #"^DIRECT-.*_BR[A-Za-z0-9]{4}$"#, .printer, "Brother", "https://support.brother.com/g/s/id/htmldoc/mfc/cv_dcp1200w/uke/html/GUID-9FC0EE27-12EE-49A7-9D42-E4F8DFF11D46_1.html"),
        Rule("canon-direct", #"^DIRECT-[A-Za-z0-9]{4}-[A-Za-z0-9-]*series$"#, .printer, "Canon", "https://ij.manual.canon/ij/webmanual/Manual/All/GX6500%20series/EN/NTR/ntr_n_01_01.html"),
        Rule("canon-ap", #"^[0-9A-Fa-f]{6}-[A-Za-z0-9-]+series$"#, .printer, "Canon", "https://ij.manual.canon/ij/webmanual/Manual/S/iB4000%20series/EN/UG/ug_apmode0100.html"),
        Rule("sony-camera", #"^DIRECT-[A-Za-z0-9]{4}:"#, .camera, "Sony", "https://helpguide.sony.net/ilc/1540/v1/en/contents/TP0000818615.html"),
        Rule("canon-camera", #"_Canon0A$"#, .camera, "Canon", "https://cam.start.canon/en/A001/manual/html/UG-01_NWBasicSettings_0100.html"),
        Rule("gopro", #"^GP\d{8}$"#, .actionCamera, "GoPro", "https://github.com/gopro/OpenGoPro/blob/main/demos/python/sdk_wireless_camera_control/README.md"),
        Rule("insta360", #"^(ONE X2?|ONE RS|ONE R|X[2-6]|X4 Air|GO \S+|Ace( Pro)?) [A-Z0-9]{6}(\.OSC)?$"#, .camera360, "Insta360", "https://onlinemanual.insta360.com/x3/en-us/camera/connect/phone"),
        Rule("theta", #"^THETA[A-Z]{2}\d{8}\.OSC$"#, .camera360, "Ricoh Theta", "https://support.ricoh360.com/manual/z1-prepare-06"),
        // Google's Open Spherical Camera convention, which 360° cameras put at the end of their Wi-Fi name.
        Rule("osc", #"\.OSC$"#, .camera360, nil, "https://developers.google.com/streetview/open-spherical-camera"),
        Rule("tello", #"^(TELLO|RMTT)-[0-9A-F]{6}$"#, .drone, "DJI Tello", "https://dl-cdn.ryzerobotics.com/downloads/Tello/20180404/Tello_User_Manual_V1.2_EN.pdf", caseInsensitive: true),
        Rule("dji-spark", #"^Spark-[A-Za-z0-9]{4,8}$"#, .drone, "DJI", "https://dl.djicdn.com/downloads/Spark/20180209/Spark_Quick_Start_Guide_V1.6_EN.pdf"),
        Rule("shelly", #"^shelly[a-z0-9-]+-[0-9a-f]{6,12}$"#, .smartHome, "Shelly", "https://shelly-api-docs.shelly.cloud/gen1/", caseInsensitive: true),
        Rule("tasmota", #"^tasmota[_-][0-9A-F]{6}-\d{4}$"#, .smartHome, "Tasmota", "https://tasmota.github.io/docs/Getting-Started/", caseInsensitive: true),
        Rule("kasa", #"^TP-LINK_Smart Plug_[0-9A-Fa-f]{4}$"#, .smartHome, "Kasa", "https://www.tp-link.com/us/support/faq/946/"),
        Rule("tapo", #"^Tapo_(Plug|Cam)_"#, .smartHome, "Tapo", "https://www.tapo.com/faq/581/"),
        Rule("wiz", #"^WiZConfig_"#, .smartHome, "WiZ", "https://faq.wizconnected.com/hc/en/7-wiz-v2/faq/467-manual-pairing-troubleshooting"),
        // The Wi-Fi P2P specification's group name: "DIRECT-" and two random characters. Printers (Epson's among them),
        // TVs, cameras and phones all use it, so it doesn't say which.
        Rule("wifi-direct", #"^DIRECT-[A-Za-z0-9]{2}"#, .directLink, nil, "https://itecspec.com/spec/3gpp-23-303-a-2-wi-fi-peer-to-peer"),
    ]

    /// The row a Wi-Fi name matches, whatever the internet does.
    public static func match(ssid: String?) -> SetupNetworkMatch? {
        guard let ssid = ssid?.trimmingCharacters(in: .whitespaces), !ssid.isEmpty, ssid.count <= 32 else { return nil }
        return rules.first { $0.matches(ssid) }.map { SetupNetworkMatch(kind: $0.kind, maker: $0.maker, rule: $0.id) }
    }

    /// A device's own network: the name matches and the internet isn't reachable. A missing gateway supports that
    /// reading, but never overrides a successful internet check (for example through another route or a VPN).
    public static func judge(ssid: String?, gateway: String?, internetReachable: Bool) -> SetupNetworkMatch? {
        guard let found = match(ssid: ssid) else { return nil }
        return !internetReachable ? found : nil
    }
}
