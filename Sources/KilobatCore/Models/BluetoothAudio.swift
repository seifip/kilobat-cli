import Foundation

/// Bluetooth headphones or a speaker as macOS's sound output, read from Core Audio.
public struct BluetoothAudioOutput: Codable, Sendable, Equatable {
    public enum Transport: String, Codable, Sendable { case classic, le }
    public let name: String
    public let transport: Transport
    /// Some app is sending sound to it now (`kAudioDevicePropertyDeviceIsRunningSomewhere`).
    public var playing: Bool
    /// Its microphone is recording too. macOS then switches the headset to the hands-free profile (HFP): call-quality
    /// sound with less room for retries, so it breaks up sooner.
    public var microphone: Bool
    /// The output's sample rate; 24 kHz or less is the hands-free profile.
    public var sampleRate: Double?
    public init(name: String, transport: Transport, playing: Bool, microphone: Bool = false, sampleRate: Double? = nil) {
        self.name = name; self.transport = transport; self.playing = playing; self.microphone = microphone; self.sampleRate = sampleRate
    }
    /// Core Audio's transport type for a device: 'blue' for Bluetooth Classic (A2DP and HFP), 'blea' for Bluetooth LE audio.
    public static func transport(_ type: UInt32) -> Transport? {
        switch type {
        case 0x626C_7565: .classic // 'blue', kAudioDeviceTransportTypeBluetooth
        case 0x626C_6561: .le // 'blea', kAudioDeviceTransportTypeBluetoothLE
        default: nil
        }
    }
    /// What the output device is, from Core Audio's properties: nil unless it is Bluetooth. The microphone counts when
    /// the default input is Bluetooth and recording, or the output runs at a hands-free rate.
    public static func reading(name: String, outputTransport: UInt32, running: Bool, sampleRate: Double?,
                               inputTransport: UInt32?, inputRunning: Bool) -> BluetoothAudioOutput? {
        guard let transport = transport(outputTransport) else { return nil }
        let inputOn = inputTransport.flatMap(Self.transport) != nil && inputRunning
        let handsFree = sampleRate.map { $0 > 0 && $0 <= 24_000 } ?? false
        return BluetoothAudioOutput(name: name, transport: transport, playing: running, microphone: running && (inputOn || handsFree), sampleRate: sampleRate)
    }
}

/// What on the Mac's side can make Bluetooth audio crackle, in the order the advice comes.
public enum BluetoothAudioRisk: String, Codable, Sendable, CaseIterable, Comparable {
    /// The Mac's Wi-Fi is on 2.4 GHz, the band Bluetooth hops across; the shared radio takes turns between them.
    case wifi24 = "wifi24GHz"
    /// That 2.4 GHz channel is crowded by neighbours' networks.
    case crowdedChannel
    /// AirDrop's link (AWDL) is up and busy: it hops channels several times a second.
    case airDrop
    /// A big transfer on Wi-Fi is taking airtime the radio would give Bluetooth.
    case heavyTraffic
    /// The headphones' own Bluetooth signal is weak.
    case weakBluetooth
    /// Several other Bluetooth devices are connected at once.
    case busyBluetooth

    /// How much each adds to the score: the shared band and AirDrop's hopping matter most.
    public var weight: Int {
        switch self {
        case .wifi24: 3
        case .airDrop, .heavyTraffic, .weakBluetooth: 2
        case .crowdedChannel, .busyBluetooth: 1
        }
    }
    public static func < (a: Self, b: Self) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
    /// Reads on from "while": "your Wi-Fi was on 2.4 GHz".
    public var phrase: String {
        switch self {
        case .wifi24: String(localized: "the Wi-Fi was on 2.4 GHz", comment: "Bluetooth audio: one of the conditions while it played; follows “while”")
        case .crowdedChannel: String(localized: "the 2.4 GHz channel was crowded", comment: "Bluetooth audio: one of the conditions while it played; follows “while”")
        case .airDrop: String(localized: "AirDrop was scanning", comment: "Bluetooth audio: one of the conditions while it played; follows “while”")
        case .heavyTraffic: String(localized: "a big transfer was using the Wi-Fi", comment: "Bluetooth audio: one of the conditions while it played; follows “while”")
        case .weakBluetooth: String(localized: "the Bluetooth signal was weak", comment: "Bluetooth audio: one of the conditions while it played; follows “while”")
        case .busyBluetooth: String(localized: "several other Bluetooth devices were connected", comment: "Bluetooth audio: one of the conditions while it played; follows “while”")
        }
    }
}

/// A 5 GHz (or 6 GHz) network the Mac could move to, from the last Wi-Fi scan.
public struct FasterBand: Codable, Sendable, Equatable {
    public let name: String
    public let band: String
    public let rssi: Int
    /// The same network name as now: the router offers both bands under one name.
    public let sameName: Bool
    /// macOS remembers it, so Kilobat can join it without asking for a password.
    public let known: Bool
    public init(name: String, band: String, rssi: Int, sameName: Bool, known: Bool) {
        self.name = name; self.band = band; self.rssi = rssi; self.sameName = sameName; self.known = known
    }
}

/// Everything measured at the moment of a check, so the verdict can be recomputed and tested.
public struct BluetoothAudioConditions: Codable, Sendable, Equatable {
    public var wifiBand: String?
    public var wifiChannel: Int?
    public var wifiName: String?
    /// Kilobat's crowding estimate for the Mac's channel from a recent scan, the Mac's own network left out; nil without one.
    public var channelCrowding: Double?
    /// The least crowded of channels 1, 6 and 11, when it is clearly quieter than the current one.
    public var quieterChannel: Int?
    /// Whether AirDrop's link was up and busy; nil when it wasn't checked.
    public var airDropActive: Bool?
    /// The features holding the link: AirDrop, Universal Control, Sidecar.
    public var airDropUsers: [String] = []
    /// Bytes a second over the Wi-Fi interface, both ways.
    public var wifiBytesPerSecond: Double?
    /// The busiest app on the network at the time, and whether it was mostly uploading.
    public var busiestApp: String?
    public var busiestUploading: Bool?
    /// The headphones' Bluetooth signal in dBm, when macOS gives it.
    public var bluetoothRSSI: Int?
    /// Other Bluetooth devices connected at the same time; nil when Kilobat can't see them.
    public var otherBluetoothDevices: Int?
    public var fasterBand: FasterBand?
    public init() {}
}

/// One thing to change, in the order to try them, with the button Kilobat can offer for it.
public struct BluetoothAudioAdvice: Codable, Sendable, Equatable, Identifiable {
    public enum Action: String, Codable, Sendable { case joinFasterBand, pauseAirDrop }
    public let risk: BluetoothAudioRisk?
    public let text: String
    public let action: Action?
    public var id: String { (risk?.rawValue ?? "general") + (action?.rawValue ?? "") + text }
    public init(risk: BluetoothAudioRisk?, text: String, action: Action? = nil) { self.risk = risk; self.text = text; self.action = action }
}

/// Bluetooth audio playing and what may be making it crackle: the verdict and what to change, from conditions alone.
public struct BluetoothAudioCheck: Codable, Sendable, Equatable {
    public static let heavyBytesPerSecond = 2_500_000.0
    public static let weakRSSI = -72
    public static let crowded = 150.0
    public static let busyDevices = 4

    public let date: Date
    public let output: BluetoothAudioOutput
    public let conditions: BluetoothAudioConditions
    public let risks: [BluetoothAudioRisk]
    /// The person said the audio was crackling during this listening session.
    public var reported: Bool

    public init(date: Date = Date(), output: BluetoothAudioOutput, conditions: BluetoothAudioConditions, reported: Bool = false) {
        self.date = date; self.output = output; self.conditions = conditions; self.reported = reported
        risks = Self.risks(conditions)
    }

    public static func risks(_ c: BluetoothAudioConditions) -> [BluetoothAudioRisk] {
        var found: [BluetoothAudioRisk] = []
        let on24 = c.wifiBand == "2.4 GHz"
        if on24 { found.append(.wifi24) }
        if on24, let crowding = c.channelCrowding, crowding >= crowded { found.append(.crowdedChannel) }
        if c.airDropActive == true { found.append(.airDrop) }
        if c.wifiBand != nil, let rate = c.wifiBytesPerSecond, rate >= heavyBytesPerSecond { found.append(.heavyTraffic) }
        if let rssi = c.bluetoothRSSI, rssi <= weakRSSI { found.append(.weakBluetooth) }
        if let others = c.otherBluetoothDevices, others >= busyDevices { found.append(.busyBluetooth) }
        return found.sorted()
    }
    public var score: Int { risks.reduce(0) { $0 + $1.weight } + (output.microphone && !risks.isEmpty ? 1 : 0) }
    public enum Level: String, Codable, Sendable { case clear, some, high }
    /// High from 4: the shared band plus anything else, or AirDrop with a big transfer.
    public var level: Level { risks.isEmpty ? .clear : score >= 4 ? .high : .some }
    /// Worth one notification: two or more causes at once.
    public var lineUp: Bool { risks.count >= 2 }
    /// Worth a line in Health: anything in the way, or the person said it crackles.
    public var shows: Bool { output.playing && (!risks.isEmpty || reported) }

    public var headline: String {
        if risks.isEmpty {
            return String(localized: "\(output.name): nothing on the Wi-Fi side in the way", comment: "Bluetooth audio headline when no Wi-Fi cause is present; the argument is a device such as AirPods Pro")
        }
        return String(localized: "\(output.name) may crackle", comment: "Bluetooth audio headline when Wi-Fi conditions can make it break up; the argument is a device such as AirPods Pro")
    }
    /// "Playing over Bluetooth while the Wi-Fi is on 2.4 GHz and AirDrop is scanning."
    public var detail: String {
        let mode = output.microphone ? String(localized: "On a call over Bluetooth", comment: "Bluetooth audio: the headset's microphone is in use")
                                     : String(localized: "Playing over Bluetooth", comment: "Bluetooth audio: music or video playing to headphones")
        guard !risks.isEmpty else {
            return reported ? String(localized: "\(mode), with no 2.4 GHz Wi-Fi, AirDrop scanning or big transfer in the way. Distance or the headphones’ own link is the likelier cause.", comment: "Bluetooth audio after the person said it crackles but no Wi-Fi cause is present; the argument is a phrase such as “Playing over Bluetooth”")
                : mode + "."
        }
        return String(localized: "\(mode) while \(risks.map(\.present).formatted(.list(type: .and))).", comment: "Bluetooth audio: what is in the way; the arguments are a phrase such as “Playing over Bluetooth” and a list of conditions")
    }
    /// macOS doesn't tell other apps when Bluetooth audio drops out, so this is said every time.
    public static var basis: String {
        String(localized: "Kilobat can’t hear the audio itself: macOS doesn’t tell other apps when Bluetooth sound breaks up. This is from what shares the radio right now.", comment: "Bluetooth audio: how the advice is reached")
    }

    /// What to change, most effective first: 5 GHz, AirDrop, the transfer, distance.
    public var advice: [BluetoothAudioAdvice] {
        let device = output.name
        var steps: [BluetoothAudioAdvice] = []
        for risk in risks {
            switch risk {
            case .wifi24:
                let start = String(localized: "Your Mac’s Wi-Fi is on 2.4 GHz, which shares the radio with \(device).", comment: "Bluetooth audio advice; the argument is a device such as AirPods Pro")
                if let faster = conditions.fasterBand {
                    if faster.sameName {
                        steps.append(.init(risk: risk, text: start + " " + String(localized: "Your router also offers \(faster.band) under the same name: switch to it here.", comment: "Bluetooth audio advice; the argument is a band such as 5 GHz"), action: faster.known ? .joinFasterBand : nil))
                    } else if faster.known {
                        steps.append(.init(risk: risk, text: start + " " + String(localized: "Join \(faster.name), your router’s \(faster.band) network.", comment: "Bluetooth audio advice; the arguments are a Wi-Fi name such as Home-5G and a band such as 5 GHz"), action: .joinFasterBand))
                    } else {
                        steps.append(.init(risk: risk, text: start + " " + String(localized: "Join \(faster.name) (\(faster.band)) if it’s your router’s; macOS asks for its password the first time.", comment: "Bluetooth audio advice; the arguments are a Wi-Fi name such as Home-5G and a band such as 5 GHz")))
                    }
                } else {
                    let name = conditions.wifiName.map { "\($0)-5G" } ?? "…-5G"
                    steps.append(.init(risk: risk, text: start + " " + String(localized: "Join the 5 GHz network (\(name)) if your router has one.", comment: "Bluetooth audio advice; the argument is a likely Wi-Fi name such as Home-5G")))
                }
            case .crowdedChannel:
                let channel = conditions.wifiChannel.map(String.init) ?? "—"
                steps.append(.init(risk: risk, text: conditions.quieterChannel.map { String(localized: "Channel \(channel) is crowded with neighbours’ networks. If you stay on 2.4 GHz, set your router to channel \($0), the quietest here.", comment: "Bluetooth audio advice; the arguments are Wi-Fi channels") }
                    ?? String(localized: "Channel \(channel) is crowded with neighbours’ networks, and 1, 6 and 11 are all busy here: 5 GHz is the way out.", comment: "Bluetooth audio advice; the argument is a Wi-Fi channel")))
            case .airDrop:
                let others = conditions.airDropUsers.filter { $0 != "AirDrop" }
                steps.append(.init(risk: risk, text: others.isEmpty ? String(localized: "AirDrop is scanning: pause it while you listen.", comment: "Bluetooth audio advice")
                    : String(localized: "\(NearbyRadios.list(others)) keeps AirDrop’s radio busy: pause it while you listen.", comment: "Bluetooth audio advice; the argument lists features such as Universal Control"), action: .pauseAirDrop))
            case .heavyTraffic:
                let up = conditions.busiestUploading == true
                steps.append(.init(risk: risk, text: conditions.busiestApp.map {
                    up ? String(localized: "\($0) is uploading a lot on Wi-Fi and competing: pause it while you listen.", comment: "Bluetooth audio advice; the argument is an app")
                       : String(localized: "\($0) is downloading a lot on Wi-Fi and competing: pause it while you listen.", comment: "Bluetooth audio advice; the argument is an app")
                } ?? String(localized: "A big download on Wi-Fi is competing: pause it while you listen.", comment: "Bluetooth audio advice")))
            case .weakBluetooth:
                steps.append(.init(risk: risk, text: Self.closer(device)))
            case .busyBluetooth:
                steps.append(.init(risk: risk, text: String(localized: "\(conditions.otherBluetoothDevices ?? 0) other Bluetooth devices are connected: disconnect the ones you aren’t using.", comment: "Bluetooth audio advice; the argument is a number")))
            }
        }
        // Nothing on the Wi-Fi side, but it crackles: distance and the bag are what's left.
        if risks.isEmpty, reported { steps.append(.init(risk: nil, text: Self.closer(device))) }
        if output.microphone {
            steps.append(.init(risk: nil, text: String(localized: "On calls, pick the Mac’s microphone as input in the call app: \(device) then stays in its high-quality mode.", comment: "Bluetooth audio advice; the argument is a device such as AirPods Pro")))
        }
        return steps
    }
    static func closer(_ device: String) -> String {
        String(localized: "Move closer, and keep the Mac out of your bag: \(device) needs a clear line to it.", comment: "Bluetooth audio advice; the argument is a device such as AirPods Pro")
    }

    // MARK: Measuring

    /// Crowding on the Mac's own channel without its own network, and a clearly quieter channel among 1, 6 and 11.
    public static func crowding(channel: Int?, band: String?, ownName: String?, networks: [NearbyNetwork]) -> (crowding: Double, quieter: Int?)? {
        guard band == "2.4 GHz", let channel, !networks.isEmpty else { return nil }
        let others = networks.filter { $0.ssid != ownName }
        let now = DiagnosticProbe.congestion(channel: channel, band: "2.4 GHz", networks: others)
        let best = [1, 6, 11].map { ($0, DiagnosticProbe.congestion(channel: $0, band: "2.4 GHz", networks: others)) }.min { $0.1 < $1.1 }
        let quieter = best.flatMap { $0.0 != channel && now > 0 && $0.1 <= now / 2 ? $0.0 : nil }
        return (now, quieter)
    }
    /// A 5 or 6 GHz network to move to: the same name on another band first, then a remembered network whose name
    /// starts like this one (Home and Home-5G), then any remembered one, then one named like it. Only with a usable signal.
    public static func fasterBand(current: String?, band: String?, networks: [NearbyNetwork], known: Set<String>) -> FasterBand? {
        guard band == "2.4 GHz", let current, !current.isEmpty else { return nil }
        let candidates = networks.filter { $0.band != "2.4 GHz" && $0.band != "Unknown" && $0.rssi >= -75 && !$0.ssid.isEmpty && $0.ssid != "Hidden network" }
        func strongest(_ list: [NearbyNetwork]) -> NearbyNetwork? { list.max { $0.rssi < $1.rssi } }
        let stem = current.lowercased().replacingOccurrences(of: "2.4ghz", with: "").replacingOccurrences(of: "2.4g", with: "").replacingOccurrences(of: "-2g", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_."))
        let alike = candidates.filter { $0.ssid != current && !stem.isEmpty && $0.ssid.lowercased().hasPrefix(stem) }
        if let same = strongest(candidates.filter { $0.ssid == current }) {
            return FasterBand(name: same.ssid, band: same.band, rssi: same.rssi, sameName: true, known: known.contains(current))
        }
        if let pick = strongest(alike.filter { known.contains($0.ssid) }) ?? strongest(candidates.filter { known.contains($0.ssid) }) ?? strongest(alike) {
            return FasterBand(name: pick.ssid, band: pick.band, rssi: pick.rssi, sameName: false, known: known.contains(pick.ssid))
        }
        return nil
    }
}

extension BluetoothAudioRisk {
    /// Reads on from "while", in the present: "the Wi-Fi is on 2.4 GHz".
    public var present: String {
        switch self {
        case .wifi24: String(localized: "the Wi-Fi is on 2.4 GHz", comment: "Bluetooth audio: a condition now; follows “while”")
        case .crowdedChannel: String(localized: "its channel is crowded", comment: "Bluetooth audio: a condition now; follows “while”; “its” is the Wi-Fi")
        case .airDrop: String(localized: "AirDrop is scanning", comment: "Bluetooth audio: a condition now; follows “while”")
        case .heavyTraffic: String(localized: "a big transfer is using the Wi-Fi", comment: "Bluetooth audio: a condition now; follows “while”")
        case .weakBluetooth: String(localized: "the Bluetooth signal is weak", comment: "Bluetooth audio: a condition now; follows “while”")
        case .busyBluetooth: String(localized: "several other Bluetooth devices are connected", comment: "Bluetooth audio: a condition now; follows “while”")
        }
    }
}

/// One notification per listening session, only when two or more causes have lined up for two checks in a row, and
/// never more than one every few hours.
public struct BluetoothAudioNotifier: Codable, Sendable, Equatable {
    /// Silence this long ends a listening session.
    public static let gap: TimeInterval = 5 * 60
    /// Causes must hold this long, so a moment's download or an AirDrop blip doesn't count.
    public static let settle: TimeInterval = 20
    /// The shortest time between two notifications, across sessions.
    public static let spacing: TimeInterval = 4 * 3600

    public struct Session: Codable, Sendable, Equatable {
        public var started: Date
        public var lastPlaying: Date
        public var notified = false
        public var lineUpSince: Date?
        public var reported = false
    }
    public var session: Session?
    public var lastNotified: Date?
    public init(lastNotified: Date? = nil) { self.lastNotified = lastNotified }

    /// A session ended (the audio stopped long enough), so a pause Kilobat started can end with it.
    public private(set) var ended = false

    /// One check. True when this is the moment to notify.
    public mutating func observe(playing: Bool, lineUp: Bool, now: Date) -> Bool {
        ended = false
        if let current = session, now.timeIntervalSince(current.lastPlaying) > Self.gap { session = nil; ended = true }
        guard playing else { return false }
        if session == nil { session = Session(started: now, lastPlaying: now) }
        session!.lastPlaying = now
        guard lineUp else { session!.lineUpSince = nil; return false }
        let since = session!.lineUpSince ?? now
        session!.lineUpSince = since
        guard !session!.notified, now.timeIntervalSince(since) >= Self.settle else { return false }
        if let last = lastNotified, now.timeIntervalSince(last) < Self.spacing { return false }
        session!.notified = true; lastNotified = now
        return true
    }
}

/// When the person said their Bluetooth audio crackled, and what was in the way at the time.
public struct BluetoothAudioReport: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public let date: Date
    public let device: String
    public let microphone: Bool
    public let risks: [BluetoothAudioRisk]
    public init(date: Date, device: String, microphone: Bool, risks: [BluetoothAudioRisk]) {
        self.date = date; self.device = device; self.microphone = microphone; self.risks = risks
    }
}

/// A call heard through Bluetooth headphones, with what was in the way for at least a quarter of it.
public struct BluetoothCallNote: Codable, Sendable, Equatable {
    public let device: String
    public let microphone: Bool
    public let risks: [BluetoothAudioRisk]
    /// The person said the audio crackled during the call.
    public var reported: Bool
    public init(device: String, microphone: Bool, risks: [BluetoothAudioRisk], reported: Bool = false) {
        self.device = device; self.microphone = microphone; self.risks = risks; self.reported = reported
    }
    /// From the checks taken during a call. Nil when Bluetooth audio was used for less than a third of them.
    public static func from(_ samples: [CallSamples.BluetoothAudio], calledFor total: Int) -> BluetoothCallNote? {
        guard !samples.isEmpty, samples.count * 3 >= max(1, total) else { return nil }
        let device = Dictionary(grouping: samples, by: \.device).max { $0.value.count < $1.value.count }!.key
        let risks = BluetoothAudioRisk.allCases.filter { risk in samples.filter { $0.risks.contains(risk) }.count * 4 >= samples.count }
        return BluetoothCallNote(device: device, microphone: samples.contains(where: \.microphone), risks: risks, reported: samples.contains(where: \.reported))
    }
    /// "You heard this call through AirPods Pro over Bluetooth while the Wi-Fi was on 2.4 GHz and AirDrop was scanning,
    /// which can make the sound crackle even on a clean line." Nil without risks.
    public var sentence: String? {
        guard !risks.isEmpty else { return nil }
        let list = risks.map(\.phrase).formatted(.list(type: .and))
        return microphone ? String(localized: "This call went through \(device) over Bluetooth while \(list), which can break up your sound both ways even on a clean line.", comment: "Call report; the arguments are a device such as AirPods Pro and a list of conditions")
            : String(localized: "You heard this call through \(device) over Bluetooth while \(list), which can make it crackle even on a clean line.", comment: "Call report; the arguments are a device such as AirPods Pro and a list of conditions")
    }
    /// The first thing to change before the next call.
    public var advice: String? {
        guard let first = risks.first else { return nil }
        switch first {
        case .wifi24, .crowdedChannel: return String(localized: "Before the next call, join your router’s 5 GHz network.", comment: "Call report advice for Bluetooth audio")
        case .airDrop: return String(localized: "Before the next call, turn on low latency or call mode’s AirDrop pause.", comment: "Call report advice for Bluetooth audio")
        case .heavyTraffic: return String(localized: "Pause big downloads before the next call, or let call mode hold them.", comment: "Call report advice for Bluetooth audio")
        case .weakBluetooth: return String(localized: "Keep the Mac closer, and out of your bag, on the next call.", comment: "Call report advice for Bluetooth audio")
        case .busyBluetooth: return String(localized: "Disconnect Bluetooth devices you aren’t using before the next call.", comment: "Call report advice for Bluetooth audio")
        }
    }
}

/// The app's answer to the CLI: its latest check, nil when nothing plays to Bluetooth.
public struct BluetoothAudioRelay: Codable, Sendable {
    public var check: BluetoothAudioCheck?
    public init(check: BluetoothAudioCheck?) { self.check = check }
}

/// `kilobat bluetooth [devices|audio] [--json]`.
public enum BluetoothCommand: Equatable, Sendable {
    case devices(json: Bool)
    case audio(json: Bool)
    public static let usage = "Use bluetooth [--json] or bluetooth audio [--json]."
    /// `args` starts with "bluetooth". A piped run appends --json.
    public static func parse(_ args: [String]) throws -> BluetoothCommand {
        let rest = Array(args.dropFirst()), json = rest.contains("--json"), words = rest.filter { $0 != "--json" }
        switch words {
        case [], ["devices"]: return .devices(json: json)
        case ["audio"], ["--audio"]: return .audio(json: json)
        default: throw DiagnosticError(usage)
        }
    }
}
