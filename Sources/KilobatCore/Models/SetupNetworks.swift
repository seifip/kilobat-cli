import Foundation

/// What kind of device made the Wi-Fi the Mac is on.
public enum SetupDeviceKind: String, Codable, Sendable, CaseIterable {
    case printer, camera, actionCamera, camera360, drone, smartHome
    /// A Wi-Fi Direct group whose maker the name doesn't say: a printer, TV, camera or phone.
    case directLink
    /// A robot dog or other robot with its own access point (Unitree).
    case robot
    /// Smart plugs (Kasa, Tapo), lights (WiZ), cameras (Tapo) and relays or switches (Shelly, Tasmota, Sonoff), each
    /// in setup mode. `smartHome` stays for a smart device of no particular kind.
    case smartPlug, smartLight, smartCamera, smartSwitch
    /// A development board, such as an ESP32, chosen by the person for a saved device; no Wi-Fi name says it.
    case devBoard

    /// The icon key for `Image(symbol:)`: Phosphor glyphs from Assets/Symbols.xcassets.
    public var symbol: String {
        switch self {
        case .printer: "printer"
        case .camera: "camera"
        case .actionCamera: "video"
        case .camera360: "camera.aperture"
        case .drone: "drone"
        case .robot: "robot"
        case .smartHome: "house"
        case .smartPlug: "powerplug"
        case .smartLight: "lightbulb"
        case .smartCamera: "web.camera"
        case .smartSwitch: "switch.2"
        case .devBoard: "cpu"
        case .directLink: "devices"
        }
    }
    /// Kinds whose own Wi-Fi is a setup network: the device leaves it once it's on the home Wi-Fi.
    public var setupMode: Bool { [.smartHome, .smartPlug, .smartLight, .smartCamera, .smartSwitch].contains(self) }
    /// The kind's name on its own, for a saved device's picker.
    public var name: String {
        switch self {
        case .printer: String(localized: "Printer", comment: "Device kind")
        case .camera: String(localized: "Camera", comment: "Device kind")
        case .actionCamera: String(localized: "Action camera", comment: "Device kind")
        case .camera360: String(localized: "360° camera", comment: "Device kind")
        case .drone: String(localized: "Drone", comment: "Device kind")
        case .robot: String(localized: "Robot", comment: "Device kind")
        case .smartHome: String(localized: "Smart device", comment: "Device kind")
        case .smartPlug: String(localized: "Smart plug", comment: "Device kind")
        case .smartLight: String(localized: "Smart light", comment: "Device kind")
        case .smartCamera: String(localized: "Home camera", comment: "Device kind: a Wi-Fi security or indoor camera")
        case .smartSwitch: String(localized: "Smart switch or relay", comment: "Device kind")
        case .devBoard: String(localized: "Development board", comment: "Device kind: an ESP32 or similar")
        case .directLink: String(localized: "Other device", comment: "Device kind")
        }
    }
}

/// The Mac joined a device's own Wi-Fi: a printer's Wi-Fi Direct or setup network, a camera's or drone's, a smart
/// plug's setup access point. There is no internet there by design, so it's said plainly and never counted as an outage.
public struct SetupNetworkMatch: Codable, Sendable, Equatable {
    public let kind: SetupDeviceKind
    public let maker: String?
    /// The table row that matched, for tests and the CLI.
    public let rule: String
    /// The person's own name for it, when the network is one of their saved devices ("Rover").
    public var name: String?
    public init(kind: SetupDeviceKind, maker: String?, rule: String, name: String? = nil) { self.kind = kind; self.maker = maker; self.rule = rule; self.name = name }

    /// "your printer", "your HP printer", "a smart device", or a saved device's own name.
    public var device: String {
        if let name { return name }
        return switch kind {
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
        case .robot: maker.map { String(localized: "your \($0) robot", comment: "Device Wi-Fi: the argument is a maker such as Unitree") }
            ?? String(localized: "your robot", comment: "Device Wi-Fi")
        case .smartPlug: maker.map { String(localized: "a \($0) smart plug", comment: "Device Wi-Fi: the argument is a maker such as Kasa") }
            ?? String(localized: "a smart plug", comment: "Device Wi-Fi")
        case .smartLight: maker.map { String(localized: "a \($0) smart light", comment: "Device Wi-Fi: the argument is a maker such as WiZ") }
            ?? String(localized: "a smart light", comment: "Device Wi-Fi")
        case .smartCamera: maker.map { String(localized: "a \($0) home camera", comment: "Device Wi-Fi: the argument is a maker such as Tapo") }
            ?? String(localized: "a home camera", comment: "Device Wi-Fi")
        case .smartSwitch: maker.map { String(localized: "a \($0) smart switch", comment: "Device Wi-Fi: the argument is a maker such as Shelly") }
            ?? String(localized: "a smart switch", comment: "Device Wi-Fi")
        case .devBoard: String(localized: "your development board", comment: "Device Wi-Fi")
        }
    }
    /// The icon key for the device.
    public var symbol: String { kind.symbol }

    /// "You’re on your printer’s own Wi-Fi; there’s no internet here, by design."
    public var headline: String {
        if name != nil {
            return String(localized: "You’re on \(device)’s own Wi-Fi; there’s no internet here, by design.", comment: "Device Wi-Fi headline; the argument is a phrase such as “your HP printer”")
        }
        return switch kind {
        case _ where kind.setupMode:
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
        case .smartHome, .smartPlug, .smartLight, .smartCamera, .smartSwitch: task = String(localized: "Finish the setup in its app.", comment: "Device Wi-Fi: what the network is for")
        case .directLink, .devBoard: task = String(localized: "Use the device from here.", comment: "Device Wi-Fi: what the network is for")
        case .robot: task = String(localized: "Control it from its app or a browser.", comment: "Device Wi-Fi: what a robot's own network is for")
        }
        let back = previous.map { String(localized: "Go back to \($0) when you’re done.", comment: "Device Wi-Fi; the argument is the Wi-Fi the Mac was on before") }
            ?? String(localized: "Go back to your usual Wi-Fi when you’re done.", comment: "Device Wi-Fi")
        return [task, back, String(localized: "Kilobat doesn’t count this as an outage.", comment: "Device Wi-Fi")].joined(separator: " ")
    }
}

/// A small curated table of the names devices give their own Wi-Fi, from the makers' documentation. Each row's
/// `source` is the page the pattern comes from; Release/RESEARCH-DECISIONS.md keeps the reasoning. Names are only
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
        Rule("unitree-go2", #"^GO2-[A-Za-z0-9]{4,8}$"#, .robot, "Unitree", "https://fccid.io/m/c598e1a60c42ecfa012618489f32cac9302e91be34413843dcf3865c9ace84bb.pdf", caseInsensitive: true),
        Rule("shelly", #"^shelly[a-z0-9-]+-[0-9a-f]{6,12}$"#, .smartSwitch, "Shelly", "https://shelly-api-docs.shelly.cloud/gen1/", caseInsensitive: true),
        Rule("tasmota", #"^tasmota[_-][0-9A-F]{6}-\d{4}$"#, .smartSwitch, "Tasmota", "https://tasmota.github.io/docs/Getting-Started/", caseInsensitive: true),
        Rule("sonoff", #"^ITEAD-[0-9A-Za-z]{6,12}$"#, .smartSwitch, "Sonoff", "https://sonoff.tech/product-review/tutorial/how-to-pair-sonoff-smart-devices-with-ewelink-app/"),
        Rule("kasa", #"^TP-LINK_Smart Plug_[0-9A-Fa-f]{4}$"#, .smartPlug, "Kasa", "https://www.tp-link.com/us/support/faq/946/"),
        Rule("tapo-plug", #"^Tapo_Plug_"#, .smartPlug, "Tapo", "https://www.tapo.com/faq/581/"),
        Rule("tapo-cam", #"^Tapo_Cam_"#, .smartCamera, "Tapo", "https://www.tapo.com/faq/581/"),
        Rule("wiz", #"^WiZConfig_"#, .smartLight, "WiZ", "https://faq.wizconnected.com/hc/en/7-wiz-v2/faq/467-manual-pairing-troubleshooting"),
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
    /// `saved` are the person's own devices by Wi-Fi name: their kind and name win over the table, so a renamed GoPro
    /// or a robot the table doesn't know is still a device's network, never an outage.
    public static func judge(ssid: String?, gateway: String?, internetReachable: Bool, saved: [String: (kind: SetupDeviceKind, name: String)] = [:]) -> SetupNetworkMatch? {
        guard !internetReachable else { return nil }
        if let ssid, let own = saved[ssid] { return SetupNetworkMatch(kind: own.kind, maker: nil, rule: "saved", name: own.name) }
        return match(ssid: ssid)
    }
}
