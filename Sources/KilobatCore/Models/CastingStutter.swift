import Foundation

/// The Mac sending its screen or a tab to a TV, as far as macOS lets another app see it.
public struct CastingActivity: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// AirPlay: the sound output is an AirPlay device, or macOS's AirPlay sender is streaming on the local network.
        case airPlay
        /// A Chromium browser streaming on the local network: casting a tab to a Chromecast, most likely.
        case browserTab
    }
    public let kind: Kind
    /// The AirPlay receiver's name when the sound output names it; the browser for a tab.
    public let target: String?
    /// The app sending it, so its own stream isn't counted as competing traffic.
    public let sender: String
    /// What it sends on the local network, in bytes a second; nil when only the sound output says so.
    public var bytesPerSecond: Double?
    public init(kind: Kind, target: String?, sender: String, bytesPerSecond: Double? = nil) {
        self.kind = kind; self.target = target; self.sender = sender; self.bytesPerSecond = bytesPerSecond
    }

    /// Core Audio's transport type for an AirPlay output, 'airp' (`kAudioDeviceTransportTypeAirPlay`).
    public static let airPlayTransport: UInt32 = 0x6169_7270
    /// A cast or mirror sends at least this much: a quiet screen mirror is around 1–2 Mbit/s, a video several times that.
    public static let streamingBytesPerSecond = 125_000.0
    /// Browsers that cast tabs the way Chrome does (the Cast sender built into Chromium).
    public static let browsers = ["Google Chrome", "Chromium", "Microsoft Edge", "Brave Browser", "Arc", "Vivaldi", "Opera", "Dia"]

    /// What the Mac is casting, if anything: AirPlay from the sound output or the AirPlay sender's local traffic,
    /// else a Chromium browser streaming on the local network. `local` is each app's local-network rate, in bytes a second.
    public static func detect(outputTransport: UInt32?, outputName: String?, local: [String: Double]) -> CastingActivity? {
        let airPlaySender = local.filter { $0.key.lowercased().hasPrefix("airplay") && $0.value >= streamingBytesPerSecond }.max { $0.value < $1.value }
        if outputTransport == airPlayTransport || airPlaySender != nil {
            return CastingActivity(kind: .airPlay, target: outputTransport == airPlayTransport ? outputName : nil,
                                   sender: airPlaySender?.key ?? "AirPlay", bytesPerSecond: airPlaySender?.value)
        }
        if let browser = local.filter({ browsers.contains($0.key) && $0.value >= streamingBytesPerSecond * 1.5 }).max(by: { $0.value < $1.value }) {
            return CastingActivity(kind: .browserTab, target: nil, sender: browser.key, bytesPerSecond: browser.value)
        }
        return nil
    }

    /// "Mirroring to Living Room over AirPlay", "Casting a tab from Google Chrome".
    public var summary: String {
        switch kind {
        case .airPlay: target.map { String(localized: "AirPlay to \($0)", comment: "Casting: the Mac streams to an AirPlay receiver; the argument is its name") }
            ?? String(localized: "AirPlay mirroring or streaming", comment: "Casting: the Mac streams over AirPlay to a receiver it doesn’t name")
        case .browserTab: String(localized: "Possible cast from \(sender)", comment: "Casting: a browser streams on the local network, likely to a Chromecast; the argument is the browser")
        }
    }
}

/// What on the Mac's side can make a cast or AirPlay mirror stutter, in the order to fix them.
public enum CastingRisk: String, Codable, Sendable, CaseIterable, Comparable {
    /// The Mac on 2.4 GHz: slower and shared with Bluetooth and neighbours, and a mirror needs steady airtime.
    case wifi24 = "wifi24GHz"
    /// The Mac's Wi-Fi signal is weak, so the stream crawls at a low rate and retries.
    case weakSignal
    /// AirDrop's link hops channels several times a second, taking the radio away from the stream.
    case airDrop
    /// Another app is moving a lot of data over the same Wi-Fi.
    case heavyTraffic
    public static func < (a: Self, b: Self) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
    public var present: String {
        switch self {
        case .wifi24: String(localized: "the Mac’s Wi-Fi is on 2.4 GHz", comment: "Casting stutter: a condition now; follows “while”")
        case .weakSignal: String(localized: "the Wi-Fi signal is weak", comment: "Casting stutter: a condition now; follows “while”")
        case .airDrop: String(localized: "AirDrop is scanning", comment: "Casting stutter: a condition now; follows “while”")
        case .heavyTraffic: String(localized: "a big transfer is using the Wi-Fi", comment: "Casting stutter: a condition now; follows “while”")
        }
    }
}

public struct CastingConditions: Codable, Sendable, Equatable {
    public var wifiBand: String?
    public var wifiName: String?
    public var rssi: Int?
    /// Nil when it wasn't checked.
    public var airDropActive: Bool?
    public var airDropUsers: [String] = []
    /// The busiest app besides the one casting, in bytes a second.
    public var busiestApp: String?
    public var busiestBytesPerSecond: Double?
    public var busiestUploading: Bool?
    /// Whether that app is one Kilobat can pause (a sync, backup or download client).
    public var busiestPausable: Bool?
    public var fasterBand: FasterBand?
    public init() {}
}

/// One cast or mirror and what may make it stutter, from conditions alone: Kilobat can't see the frames drop.
public struct CastingCheck: Codable, Sendable, Equatable {
    public static let weakRSSI = -70
    /// Another app moving this much (or uploading half of it) competes for the Wi-Fi's airtime.
    public static let heavyBytesPerSecond = 2_500_000.0

    public let date: Date
    public let activity: CastingActivity
    public let conditions: CastingConditions
    public let risks: [CastingRisk]

    public init(date: Date = Date(), activity: CastingActivity, conditions: CastingConditions) {
        self.date = date; self.activity = activity; self.conditions = conditions
        risks = Self.risks(conditions)
    }

    public static func risks(_ c: CastingConditions) -> [CastingRisk] {
        var found: [CastingRisk] = []
        if c.wifiBand == "2.4 GHz" { found.append(.wifi24) }
        if let rssi = c.rssi, rssi <= weakRSSI { found.append(.weakSignal) }
        // AirPlay can itself ride AirDrop's peer-to-peer link: then pausing it would cut the stream, so it isn't a cause.
        if c.airDropActive == true, !c.airDropUsers.contains("AirPlay") { found.append(.airDrop) }
        if let rate = c.busiestBytesPerSecond, rate >= (c.busiestUploading == true ? heavyBytesPerSecond / 2 : heavyBytesPerSecond) { found.append(.heavyTraffic) }
        return found.sorted()
    }

    public var shows: Bool { !risks.isEmpty }
    public var headline: String {
        risks.isEmpty ? String(localized: "\(activity.summary): nothing on the Mac’s side in the way", comment: "Casting stutter headline; the argument is a phrase such as “AirPlay to Living Room”")
                      : String(localized: "\(activity.summary) may stutter", comment: "Casting stutter headline; the argument is a phrase such as “AirPlay to Living Room”")
    }
    public var detail: String {
        guard !risks.isEmpty else { return activity.summary + "." }
        return String(localized: "\(activity.summary) while \(risks.map(\.present).formatted(.list(type: .and))).", comment: "Casting stutter: the arguments are a phrase such as “AirPlay to Living Room” and a list of conditions")
    }
    public static var basis: String {
        String(localized: "Kilobat can’t see dropped frames on the TV. This is from what shares the Mac’s Wi-Fi right now; the TV’s own signal matters as much.", comment: "Casting stutter: how the advice is reached")
    }

    /// What to change, most effective first, with Kilobat's buttons where it can act.
    public var advice: [BluetoothAudioAdvice] {
        risks.map { risk in
            switch risk {
            case .wifi24:
                if let faster = conditions.fasterBand, faster.known {
                    return BluetoothAudioAdvice(risk: nil, text: String(localized: "The Mac is on 2.4 GHz. Move it to \(faster.name) on \(faster.band), and keep the TV on the same band if you can.", comment: "Casting stutter advice; the arguments are a Wi-Fi name and a band such as 5 GHz"), action: .joinFasterBand)
                }
                return BluetoothAudioAdvice(risk: nil, text: String(localized: "The Mac is on 2.4 GHz. Join your router’s 5 GHz network, and keep the TV on the same band if you can.", comment: "Casting stutter advice"))
            case .weakSignal:
                return BluetoothAudioAdvice(risk: nil, text: String(localized: "The Mac’s Wi-Fi signal is weak (\(conditions.rssi ?? 0) dBm). Move closer to the router, or cast from somewhere nearer it.", comment: "Casting stutter advice; the argument is a signal strength in dBm"))
            case .airDrop:
                return BluetoothAudioAdvice(risk: nil, text: String(localized: "AirDrop is scanning and pulls the radio off the stream: pause it while you cast.", comment: "Casting stutter advice"), action: .pauseAirDrop)
            case .heavyTraffic:
                let name = conditions.busiestApp ?? String(localized: "Another app", comment: "Casting stutter advice: an unnamed app")
                let text = conditions.busiestUploading == true
                    ? String(localized: "\(name) is uploading a lot over the same Wi-Fi: pause it while you cast.", comment: "Casting stutter advice; the argument is an app")
                    : String(localized: "\(name) is downloading a lot over the same Wi-Fi: pause it while you cast.", comment: "Casting stutter advice; the argument is an app")
                return BluetoothAudioAdvice(risk: nil, text: text, action: conditions.busiestPausable == true ? .pauseBackground : nil)
            }
        }
    }
}

/// The app's answer to the CLI about casting.
public struct CastingRelay: Codable, Sendable {
    public var check: CastingCheck?
    public init(check: CastingCheck?) { self.check = check }
}
