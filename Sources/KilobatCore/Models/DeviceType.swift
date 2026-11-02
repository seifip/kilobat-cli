import Foundation

/// What kind of thing a device on the network is, as far as Kilobat can tell. `unknown` until a signal says otherwise.
public enum DeviceType: String, Codable, Sendable, CaseIterable {
    case camera, doorbell, tv, casting, speaker, printer, plug, hub, console, phone, computer, drone, router, nas, unknown

    /// "Camera", "TV or streaming stick": a list's or a picker's label.
    public var name: String {
        switch self {
        case .camera: String(localized: "Camera", comment: "Device type")
        case .doorbell: String(localized: "Doorbell", comment: "Device type: a video doorbell")
        case .tv: String(localized: "TV or streaming stick", comment: "Device type")
        case .casting: String(localized: "Casting device", comment: "Device type: a Chromecast or another device you cast to")
        case .speaker: String(localized: "Speaker", comment: "Device type: a smart or network speaker")
        case .printer: String(localized: "Printer", comment: "Device type")
        case .plug: String(localized: "Smart plug or switch", comment: "Device type")
        case .hub: String(localized: "Hub or bridge", comment: "Device type: a smart-home hub or bridge, such as a Hue Bridge")
        case .console: String(localized: "Game console", comment: "Device type")
        case .phone: String(localized: "Phone or tablet", comment: "Device type")
        case .computer: String(localized: "Computer", comment: "Device type")
        case .drone: String(localized: "Drone or action camera", comment: "Device type: DJI, GoPro or Insta360")
        case .router: String(localized: "Router or mesh node", comment: "Device type")
        case .nas: String(localized: "NAS", comment: "Device type: network storage, such as a Synology")
        case .unknown: String(localized: "Unknown type", comment: "Device type: Kilobat can't tell what it is")
        }
    }
    /// "a camera": reads on from "Probably" or "Maybe".
    var withArticle: String {
        switch self {
        case .camera: String(localized: "a camera", comment: "Device type after “Probably” or “Maybe”")
        case .doorbell: String(localized: "a doorbell", comment: "Device type after “Probably” or “Maybe”")
        case .tv: String(localized: "a TV or streaming stick", comment: "Device type after “Probably” or “Maybe”")
        case .casting: String(localized: "a casting device", comment: "Device type after “Probably” or “Maybe”")
        case .speaker: String(localized: "a speaker", comment: "Device type after “Probably” or “Maybe”")
        case .printer: String(localized: "a printer", comment: "Device type after “Probably” or “Maybe”")
        case .plug: String(localized: "a smart plug or switch", comment: "Device type after “Probably” or “Maybe”")
        case .hub: String(localized: "a hub or bridge", comment: "Device type after “Probably” or “Maybe”")
        case .console: String(localized: "a game console", comment: "Device type after “Probably” or “Maybe”")
        case .phone: String(localized: "a phone or tablet", comment: "Device type after “Probably” or “Maybe”")
        case .computer: String(localized: "a computer", comment: "Device type after “Probably” or “Maybe”")
        case .drone: String(localized: "a drone or action camera", comment: "Device type after “Probably” or “Maybe”")
        case .router: String(localized: "a router or mesh node", comment: "Device type after “Probably” or “Maybe”")
        case .nas: String(localized: "a NAS", comment: "Device type after “Probably” or “Maybe”")
        case .unknown: String(localized: "an unknown device", comment: "Device type after “Probably” or “Maybe”")
        }
    }
    /// "camera": after a maker in a sentence, as in "A new Wyze camera joined".
    var noun: String {
        switch self {
        case .camera: String(localized: "camera", comment: "Device type in a sentence, after a maker: “a new Wyze camera”")
        case .doorbell: String(localized: "doorbell", comment: "Device type in a sentence, after a maker: “a new Ring doorbell”")
        case .tv: String(localized: "TV or streaming stick", comment: "Device type in a sentence, after a maker: “a new Roku TV or streaming stick”")
        case .casting: String(localized: "casting device", comment: "Device type in a sentence, after a maker")
        case .speaker: String(localized: "speaker", comment: "Device type in a sentence, after a maker: “a new Sonos speaker”")
        case .printer: String(localized: "printer", comment: "Device type in a sentence, after a maker: “a new Brother printer”")
        case .plug: String(localized: "smart plug or switch", comment: "Device type in a sentence, after a maker")
        case .hub: String(localized: "hub", comment: "Device type in a sentence, after a maker: “a new Philips Hue hub”")
        case .console: String(localized: "game console", comment: "Device type in a sentence, after a maker")
        case .phone: String(localized: "phone or tablet", comment: "Device type in a sentence, after a maker")
        case .computer: String(localized: "computer", comment: "Device type in a sentence, after a maker")
        case .drone: String(localized: "drone or action camera", comment: "Device type in a sentence, after a maker: “a new DJI drone or action camera”")
        case .router: String(localized: "router or mesh node", comment: "Device type in a sentence, after a maker")
        case .nas: String(localized: "NAS", comment: "Device type in a sentence, after a maker: “a new Synology NAS”")
        case .unknown: String(localized: "device", comment: "Device type in a sentence, after a maker: “a new Samsung device”")
        }
    }
    /// The SF Symbol for the list and the detail.
    public var symbol: String {
        switch self {
        case .camera: "video"
        case .doorbell: "bell"
        case .tv: "tv"
        case .casting: "tv.and.mediabox"
        case .speaker: "hifispeaker"
        case .printer: "printer"
        case .plug: "powerplug"
        case .hub: "point.3.connected.trianglepath.dotted"
        case .console: "gamecontroller"
        case .phone: "iphone"
        case .computer: "laptopcomputer"
        case .drone: "camera.aperture"
        case .router: "wifi.router"
        case .nas: "externaldrive.connected.to.line.below"
        case .unknown: "questionmark.square.dashed"
        }
    }
    /// Cameras and doorbells: what streams video to a cloud.
    public var films: Bool { self == .camera || self == .doorbell }
    /// The words `kilobat devices type` takes, beside the raw values: "camera", "tv", "smart-plug"…
    public static func parse(_ word: String) -> DeviceType? {
        let word = word.lowercased().replacingOccurrences(of: "_", with: "-")
        if let type = DeviceType(rawValue: word) { return type }
        let aliases: [String: DeviceType] = ["streaming-stick": .tv, "cast": .casting, "chromecast": .casting, "smart-plug": .plug, "switch": .plug,
                                             "bridge": .hub, "game-console": .console, "tablet": .phone, "laptop": .computer, "mac": .computer,
                                             "action-camera": .drone, "mesh": .router, "mesh-node": .router, "storage": .nas]
        return aliases[word]
    }
}

/// How sure Kilobat is of a device's type: `set` when the person chose it, else how strong the best signal was.
public enum DeviceTypeConfidence: String, Codable, Sendable, Comparable {
    case low, medium, high, set
    var rank: Int { switch self { case .low: 1; case .medium: 2; case .high: 3; case .set: 4 } }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    var lower: Self { switch self { case .set, .high: .medium; case .medium, .low: .low } }
}

/// Smart-home standards a device announces, whatever its type.
public enum DeviceTag: String, Codable, Sendable, CaseIterable {
    case homeKit = "HomeKit", matter = "Matter", threadBorderRouter = "Thread border router"
    public var name: String {
        switch self {
        case .homeKit: "HomeKit"
        case .matter: "Matter"
        case .threadBorderRouter: String(localized: "Thread border router", comment: "Tag on a device that connects a Thread smart-home network to Wi-Fi, such as a HomePod mini")
        }
    }
}

/// What a device says about itself on the network, kept with it in devices.json: its Bonjour service types, the
/// model and maker names in their TXT records and its UPnP description. Never its friendly name or IDs.
public struct DeviceSignals: Codable, Sendable, Equatable {
    /// Bonjour service types, such as `_googlecast._tcp`.
    public var services: [String] = []
    /// Model names it gives: a Chromecast's `md`, AirPlay's `model`, a printer's `ty`, a Thread router's `mn`, UPnP's modelName.
    public var models: [String] = []
    /// Maker names it gives: a Thread router's `vn`, AirPlay's `manufacturer`, UPnP's manufacturer.
    public var makers: [String] = []
    /// The HomeKit accessory category (`ci`), such as 17 for an IP camera.
    public var homeKitCategory: Int? = nil
    /// The Matter device type (`DT`) while it was open for pairing, such as 266 for a plug.
    public var matterType: Int? = nil
    /// A Google Cast receiver's capability bits (`ca`): 1 video out, 4 audio out.
    public var castCapabilities: Int? = nil
    /// UPnP device types and SSDP search targets, such as `MediaRenderer` or `roku:ecp`.
    public var upnp: [String] = []
    public init(services: [String] = [], models: [String] = [], makers: [String] = [], homeKitCategory: Int? = nil, matterType: Int? = nil,
                castCapabilities: Int? = nil, upnp: [String] = []) {
        self.services = services; self.models = models; self.makers = makers; self.homeKitCategory = homeKitCategory
        self.matterType = matterType; self.castCapabilities = castCapabilities; self.upnp = upnp
    }
    public var isEmpty: Bool { services.isEmpty && models.isEmpty && makers.isEmpty && homeKitCategory == nil && matterType == nil && castCapabilities == nil && upnp.isEmpty }

    /// What one scan heard from a device, combined with what earlier scans did: a device doesn't answer every browse.
    public static func merge(_ old: DeviceSignals?, _ new: DeviceSignals?) -> DeviceSignals? {
        guard let new, !new.isEmpty else { return old }
        guard let old else { return new }
        func union(_ a: [String], _ b: [String]) -> [String] { Array((b + a.filter { !b.contains($0) }).prefix(12)) }
        return DeviceSignals(services: union(old.services, new.services).sorted(), models: union(old.models, new.models), makers: union(old.makers, new.makers),
                             homeKitCategory: new.homeKitCategory ?? old.homeKitCategory, matterType: new.matterType ?? old.matterType,
                             castCapabilities: new.castCapabilities ?? old.castCapabilities, upnp: union(old.upnp, new.upnp).sorted())
    }

    /// The device's Bonjour services and UPnP description as signals.
    public static func from(services: [BonjourService], upnp: UPnPDescription? = nil, targets: [String] = []) -> DeviceSignals? {
        var signals = DeviceSignals()
        func add(_ value: String?, to list: inout [String]) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, value.count <= 80, !list.contains(value) else { return }
            list.append(value)
        }
        for service in services {
            let type = service.type.lowercased()
            // A virtual Cast speaker group is hosted by a member, not another physical device.
            if type == "_googlecast._tcp", let capabilities = service.text("ca").flatMap({ Int($0) }), capabilities & 0x20 != 0 { continue }
            if !signals.services.contains(type) { signals.services.append(type) }
            switch type {
            case "_googlecast._tcp":
                let capabilities = service.text("ca").flatMap { Int($0) }
                signals.castCapabilities = capabilities ?? signals.castCapabilities
                add(service.text("md"), to: &signals.models)
            case "_airplay._tcp": add(service.text("model"), to: &signals.models); add(service.text("manufacturer"), to: &signals.makers)
            case "_raop._tcp": add(service.text("am"), to: &signals.models)
            case "_companion-link._tcp": add(service.text("rpmd"), to: &signals.models)
            case "_device-info._tcp": add(service.text("model"), to: &signals.models)
            case "_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_pdl-datastream._tcp": add(service.text("ty"), to: &signals.models); add(service.text("usb_mfg"), to: &signals.makers)
            case "_hap._tcp", "_hap._udp": signals.homeKitCategory = service.text("ci").flatMap { Int($0) } ?? signals.homeKitCategory; add(service.text("md"), to: &signals.models)
            case "_matterc._udp": signals.matterType = service.text("dt").flatMap { Int($0) } ?? signals.matterType
            case "_meshcop._udp": add(service.text("mn"), to: &signals.models); add(service.text("vn"), to: &signals.makers)
            default: break
            }
        }
        if let upnp {
            if let type = upnp.shortType { add(type, to: &signals.upnp) }
            add(upnp.modelName, to: &signals.models); add(upnp.manufacturer, to: &signals.makers)
        }
        for target in targets {
            let lower = target.lowercased()
            if lower == "roku:ecp" { add("roku:ecp", to: &signals.upnp) }
            if lower.contains("dial-multiscreen-org") { add("dial", to: &signals.upnp) }
        }
        signals.services.sort(); signals.upnp.sort()
        return signals.isEmpty ? nil : signals
    }

    /// HomeKit, Matter and Thread border router, from the services announced.
    public var tags: [DeviceTag] {
        var tags: [DeviceTag] = []
        if services.contains(where: { $0.hasPrefix("_hap.") }) || homeKitCategory != nil { tags.append(.homeKit) }
        if services.contains(where: { $0 == "_matter._tcp" || $0 == "_matterc._udp" }) || matterType != nil { tags.append(.matter) }
        if services.contains("_meshcop._udp") { tags.append(.threadBorderRouter) }
        return tags
    }
}

/// Kilobat's best reading of a device's type, with how sure it is and the maker to name: "Probably a camera (Wyze)".
public struct DeviceGuess: Sendable, Equatable {
    public let type: DeviceType
    public let confidence: DeviceTypeConfidence?
    /// The maker to name beside it, such as Wyze.
    public let brand: String?
    /// What gave it away, for the detail view and agents: "Bonjour _googlecast._tcp", "maker (OUI)".
    public let evidence: String?
    public init(type: DeviceType, confidence: DeviceTypeConfidence?, brand: String? = nil, evidence: String? = nil) {
        self.type = type; self.confidence = type == .unknown && confidence != .set ? nil : confidence; self.brand = brand; self.evidence = evidence
    }
    public static let unknown = DeviceGuess(type: .unknown, confidence: nil)

    /// "Camera (Wyze)", "Probably a camera (Wyze)", "Maybe a smart plug or switch", "Unknown type".
    public var label: String {
        let phrase: String = switch confidence {
        case .set?, .high?: type.name
        case .medium?: String(localized: "Probably \(type.withArticle)", comment: "Device type Kilobat is fairly sure of; the argument is a type such as “a camera”")
        case .low?: String(localized: "Maybe \(type.withArticle)", comment: "Device type Kilobat has only a weak hint of; the argument is a type such as “a smart plug or switch”")
        case nil: type.name
        }
        guard let brand, type != .unknown else { return phrase }
        return String(localized: "\(phrase) (\(brand))", comment: "A device type and its maker, such as “Probably a camera (Wyze)”")
    }
    /// Without the maker, for a list that shows it in its own column: "Camera", "Probably a camera".
    public var short: String {
        switch confidence {
        case .medium?: String(localized: "Probably \(type.withArticle)", comment: "Device type Kilobat is fairly sure of; the argument is a type such as “a camera”")
        case .low?: String(localized: "Maybe \(type.withArticle)", comment: "Device type Kilobat has only a weak hint of; the argument is a type such as “a smart plug or switch”")
        default: type.name
        }
    }
    /// Sure enough to say in a notification's title: "A new Wyze camera joined".
    public var sure: Bool { type != .unknown && (confidence == .high || confidence == .set) }
    /// "Wyze camera", "camera".
    public var named: String {
        brand.map { String(localized: "\($0) \(type.noun)", comment: "A maker and a device type, such as “Wyze camera”") } ?? type.noun
    }
}

/// Reads a device's type from what it says about itself (Bonjour, UPnP), the name it goes by and its address's maker.
/// Pure, so every rule can be tested. Each signal gives a candidate with a confidence: a type a device declares
/// (a HomeKit category, a Cast receiver, a printer's IPP) is high; a product name in its model or hostname is high
/// or medium; its maker alone is medium at most, low when the maker makes many kinds of things. The strongest
/// candidate wins; two equally strong ones that disagree lower it a step.
public enum DeviceClassifier {
    struct Candidate { let type: DeviceType; let confidence: DeviceTypeConfidence; let brand: String?; let evidence: String }

    public static func classify(signals: DeviceSignals?, vendor: String?, hostname: String?, router: Bool = false) -> DeviceGuess {
        var candidates: [Candidate] = []
        if router { candidates.append(Candidate(type: .router, confidence: .high, brand: nil, evidence: String(localized: "the network’s gateway", comment: "Why Kilobat thinks a device is a router"))) }
        if let signals { candidates += fromSignals(signals) }
        if let hostname = DeviceNames.readable(hostname), let match = product(in: hostname) {
            candidates.append(Candidate(type: match.type, confidence: match.generic ? .low : .medium, brand: match.brand, evidence: String(localized: "its name", comment: "Why Kilobat thinks a device is of a type: the hostname it goes by")))
        }
        if let vendor, let maker = maker(vendor) {
            candidates.append(Candidate(type: maker.type, confidence: maker.confidence, brand: maker.brand, evidence: String(localized: "its maker", comment: "Why Kilobat thinks a device is of a type: the maker registered for its address")))
        }
        guard let best = candidates.max(by: { $0.confidence < $1.confidence }) else { return .unknown }
        var confidence = best.confidence
        let rivals = candidates.filter { $0.confidence == best.confidence && !related($0.type, best.type) }
        if !rivals.isEmpty { confidence = confidence.lower }
        let brand = best.brand ?? candidates.first { $0.brand != nil && related($0.type, best.type) }?.brand ?? vendor.flatMap { maker($0)?.brand ?? consumerBrand($0) }
        return DeviceGuess(type: best.type, confidence: confidence, brand: brand, evidence: best.evidence)
    }

    /// A maker of many kinds of things whose name is still worth showing beside a type found another way: a TV found
    /// by its Cast service whose address is Samsung's is a Samsung TV. Chip and contract makers (Intel, Hon Hai,
    /// Espressif) aren't brands people know their devices by.
    static func consumerBrand(_ vendor: String) -> String? {
        let brands = ["Apple", "Samsung", "Google", "Amazon", "Sony", "LG", "Xiaomi", "Huawei", "Lenovo", "Dell", "HP", "Microsoft", "Philips", "Panasonic", "Sharp", "TCL", "Hisense", "Nokia"]
        let lower = vendor.lowercased()
        return brands.first { lower == $0.lowercased() || lower.hasPrefix($0.lowercased() + " ") || lower.hasPrefix($0.lowercased() + ",") || lower.hasPrefix($0.lowercased() + ".") }
    }

    /// Types close enough that two signals pointing at them don't contradict each other.
    static func related(_ a: DeviceType, _ b: DeviceType) -> Bool {
        a == b || Set([a, b]) == [.camera, .doorbell] || Set([a, b]) == [.tv, .casting] || Set([a, b]) == [.speaker, .casting]
    }

    static func fromSignals(_ signals: DeviceSignals) -> [Candidate] {
        var out: [Candidate] = []
        let services = Set(signals.services)
        func add(_ type: DeviceType, _ confidence: DeviceTypeConfidence, _ evidence: String, brand: String? = nil) {
            out.append(Candidate(type: type, confidence: confidence, brand: brand, evidence: evidence))
        }
        // Apple's model identifiers say exactly what it is.
        var appleComputer = false
        for model in signals.models {
            guard let apple = appleModel(model) else { continue }
            if apple == .computer { appleComputer = true }
            add(apple, apple == .nas ? .medium : .high, String(localized: "its model (\(model))", comment: "Why Kilobat thinks a device is of a type; the argument is a model identifier such as AppleTV14,1"), brand: apple == .nas ? nil : "Apple")
        }
        if let category = signals.homeKitCategory, let type = homeKit(category) { add(type, .high, String(localized: "its HomeKit category", comment: "Why Kilobat thinks a device is of a type")) }
        if let matter = signals.matterType, let type = matterType(matter) { add(type, .high, String(localized: "its Matter device type", comment: "Why Kilobat thinks a device is of a type")) }
        if services.contains("_googlecast._tcp") {
            let model = signals.models.first { product(in: $0) != nil }.flatMap(product(in:))
            let capabilities = signals.castCapabilities ?? 1
            let type: DeviceType = model.map { $0.type == .tv || $0.type == .speaker ? $0.type : .casting } ?? (capabilities & 1 == 0 && capabilities & 4 != 0 ? .speaker : .casting)
            add(type, .high, "Google Cast", brand: model?.brand)
        }
        // A Mac that shares a printer announces IPP too; its own model wins.
        if !appleComputer, !services.isDisjoint(with: ["_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_pdl-datastream._tcp"]) {
            add(.printer, .high, String(localized: "its printing service", comment: "Why Kilobat thinks a device is a printer"))
        } else if !appleComputer, !services.isDisjoint(with: ["_uscan._tcp", "_scanner._tcp", "_octoprint._tcp"]) {
            add(.printer, .medium, String(localized: "its scanning or printing service", comment: "Why Kilobat thinks a device is a printer"))
        }
        let table: [(String, DeviceType, DeviceTypeConfidence, String?)] = [
            ("_sonos._tcp", .speaker, .high, "Sonos"), ("_androidtvremote2._tcp", .tv, .high, nil), ("_mediaremotetv._tcp", .tv, .high, "Apple"),
            ("_airport._tcp", .router, .high, "Apple"), ("_hue._tcp", .hub, .high, "Philips Hue"), ("_home-assistant._tcp", .hub, .high, "Home Assistant"),
            ("_axis-video._tcp", .camera, .high, "Axis"), ("_amzn-wplay._tcp", .tv, .medium, "Amazon"), ("_rtsp._tcp", .camera, .medium, nil),
            ("_ewelink._tcp", .plug, .medium, "Sonoff"), ("_shelly._tcp", .plug, .medium, "Shelly"), ("_apple-mobdev2._tcp", .phone, .medium, "Apple"),
            ("_rfb._tcp", .computer, .medium, nil), ("_workstation._tcp", .computer, .medium, nil), ("_raop._tcp", .speaker, .low, nil),
            ("_ssh._tcp", .computer, .low, nil), ("_sftp-ssh._tcp", .computer, .low, nil), ("_adisk._tcp", .nas, .low, nil),
        ]
        for (service, type, confidence, brand) in table where services.contains(service) {
            add(type, confidence, String(localized: "Bonjour \(service)", comment: "Why Kilobat thinks a device is of a type; the argument is a Bonjour service type such as _sonos._tcp"), brand: brand)
        }
        // Model and maker names it gives itself, in TXT records or its UPnP description.
        for model in signals.models where appleModel(model) == nil {
            if let match = product(in: model), !(appleComputer && match.type == .printer) {
                add(match.type, match.generic ? .medium : .high, String(localized: "its model (\(model))", comment: "Why Kilobat thinks a device is of a type; the argument is a model identifier such as AppleTV14,1"), brand: match.brand)
            }
        }
        for maker in signals.makers { if let match = self.maker(maker) { add(match.type, match.confidence, String(localized: "its maker", comment: "Why Kilobat thinks a device is of a type: the maker registered for its address"), brand: match.brand) } }
        for target in signals.upnp {
            switch target {
            case "roku:ecp": add(.tv, .high, "Roku ECP", brand: "Roku")
            case "ZonePlayer": add(.speaker, .high, "UPnP ZonePlayer", brand: "Sonos")
            case "InternetGatewayDevice", "WFADevice": add(.router, .medium, "UPnP \(target)")
            case "Printer": add(.printer, .high, "UPnP Printer")
            case "MediaRenderer", "dial": add(.tv, .low, target == "dial" ? "DIAL" : "UPnP MediaRenderer")
            case "MediaServer": add(.nas, .low, "UPnP MediaServer")
            default: break
            }
        }
        return out
    }

    /// Apple's model identifiers: AppleTV14,1, AudioAccessory5,1 (HomePod), iPhone15,2, MacBookPro18,3. Samba on a NAS
    /// often announces itself as Xserve or RackMac.
    static func appleModel(_ model: String) -> DeviceType? {
        let model = model.trimmingCharacters(in: .whitespaces)
        guard model.range(of: #"^[A-Za-z]+\d+,\d+$"#, options: .regularExpression) != nil || ["xserve", "rackmac"].contains(model.lowercased()) else { return nil }
        let lower = model.lowercased()
        if lower.hasPrefix("appletv") { return .tv }
        if lower.hasPrefix("audioaccessory") { return .speaker }
        if lower.hasPrefix("iphone") || lower.hasPrefix("ipad") || lower.hasPrefix("ipod") { return .phone }
        if lower.hasPrefix("mac") || lower.hasPrefix("imac") { return .computer }
        if lower.hasPrefix("xserve") || lower.hasPrefix("rackmac") { return .nas }
        return nil
    }

    /// HomeKit accessory categories (the `ci` TXT key) that name one of the types.
    static func homeKit(_ category: Int) -> DeviceType? {
        switch category {
        case 2: .hub
        case 7, 8, 15: .plug
        case 17: .camera
        case 18: .doorbell
        case 24, 31, 35, 36: .tv
        case 25, 26, 34: .speaker
        case 27, 33: .router
        default: nil
        }
    }

    /// Matter device types (the `DT` TXT key, decimal) that name one of the types.
    static func matterType(_ id: Int) -> DeviceType? {
        switch id {
        case 0x000E: .hub          // Aggregator: a bridge
        case 0x010A, 0x010B: .plug // On/Off and dimmable plug-in units
        case 0x0103, 0x0104, 0x0105: .plug // Light switches
        case 0x0022: .speaker
        case 0x0023: .casting      // Casting video player
        case 0x0028: .tv           // Basic video player
        default: nil
        }
    }

    struct Product { let type: DeviceType; let brand: String?; let generic: Bool }
    /// Product and brand words in a model or hostname, most specific first. `generic` words ("tv", "printer") say the
    /// type but not much else, so a hostname with only one counts as a weak hint.
    static let products: [(pattern: String, type: DeviceType, brand: String?, generic: Bool)] = [
        (#"ring.?(video.?)?doorbell|doorbell|video.?door"#, .doorbell, nil, false),
        (#"nest.?(doorbell|hello)"#, .doorbell, "Google Nest", false),
        (#"wyze|hl_cam|hl_pan"#, .camera, "Wyze", false),
        (#"^ring-|ring.?(stick.?up|spotlight|floodlight|indoor|outdoor)"#, .camera, "Ring", false),
        (#"arlo|^vmc\d{4}|^vmb\d{4}"#, .camera, "Arlo", false),
        (#"eufy"#, .camera, "eufy", false), (#"blink"#, .camera, "Blink", false), (#"reolink"#, .camera, "Reolink", false),
        (#"hikvision|ezviz"#, .camera, "Hikvision", false), (#"amcrest"#, .camera, "Amcrest", false), (#"foscam"#, .camera, "Foscam", false),
        (#"tapo.?c\d{3}"#, .camera, "TP-Link Tapo", false), (#"nest.?cam|dropcam"#, .camera, "Google Nest", false),
        (#"ip-?cam|ip-?camera|webcam|security.?cam|(^|[^a-z])cam([^a-z]|$)"#, .camera, nil, true),
        (#"chromecast"#, .casting, "Google", false), (#"google.?tv"#, .tv, "Google", false),
        (#"nest.?(mini|audio|hub)|google.?home|home.?mini"#, .speaker, "Google", false),
        (#"apple.?tv"#, .tv, "Apple", false), (#"homepod"#, .speaker, "Apple", false),
        (#"roku"#, .tv, "Roku", false), (#"fire.?tv|^aft[a-z]{1,4}$"#, .tv, "Amazon", false), (#"echo.?(dot|show|studio|pop)|amazon.?echo"#, .speaker, "Amazon", false),
        (#"kindle"#, .phone, "Amazon", false), (#"sonos"#, .speaker, "Sonos", false), (#"bose"#, .speaker, "Bose", false),
        (#"bravia"#, .tv, "Sony", false), (#"webos|lgwebostv"#, .tv, "LG", false), (#"samsung.?tv|\[tv\]|tizen"#, .tv, "Samsung", false),
        (#"vizio|smartcast"#, .tv, "Vizio", false), (#"hisense|vidaa"#, .tv, "Hisense", false), (#"shield.?(android.?)?tv"#, .tv, "NVIDIA", false),
        (#"(^|[^a-z])tv([^a-z]|$)|smart.?tv|television"#, .tv, nil, true),
        (#"^brn|^brw|brother|mfc-|hl-l|dcp-"#, .printer, "Brother", false), (#"epson|ecotank|workforce"#, .printer, "Epson", false),
        (#"laserjet|officejet|deskjet|^npi|^hp[0-9a-f]{6}$|hp.?(envy|smart.?tank)"#, .printer, "HP", false), (#"pixma|imageclass|canon.?(mf|lbp|g\d)"#, .printer, "Canon", false),
        (#"kyocera|lexmark|xerox|ricoh"#, .printer, nil, false), (#"bambu|prusa|creality|octoprint"#, .printer, nil, false),
        (#"printer"#, .printer, nil, true),
        (#"shelly"#, .plug, "Shelly", false), (#"tasmota|sonoff"#, .plug, nil, false), (#"kasa|^hs1\d\d|^ep\d{2}|^kp\d{3}|tapo.?p1\d\d"#, .plug, "TP-Link Kasa", false),
        (#"wemo"#, .plug, "Belkin Wemo", false), (#"meross"#, .plug, "Meross", false), (#"smart.?plug|(^|[^a-z])plug([^a-z]|$)"#, .plug, nil, true),
        (#"hue.?bridge|philips.?hue"#, .hub, "Philips Hue", false), (#"smartthings"#, .hub, "SmartThings", false), (#"homey"#, .hub, "Homey", false),
        (#"home.?assistant|homeassistant"#, .hub, "Home Assistant", false), (#"hubitat"#, .hub, "Hubitat", false), (#"aqara|lumi.?gateway"#, .hub, "Aqara", false),
        (#"dirigera|tradfri"#, .hub, "IKEA", false), (#"lutron|caseta"#, .hub, "Lutron", false), (#"(^|[^a-z])(hub|bridge)([^a-z]|$)"#, .hub, nil, true),
        (#"playstation|(^|[^a-z])ps[345]([^a-z0-9]|$)"#, .console, "PlayStation", false), (#"xbox"#, .console, "Xbox", false),
        (#"nintendo"#, .console, "Nintendo", false), (#"steam.?deck"#, .console, "Steam Deck", false), (#"oculus|meta.?quest"#, .console, "Meta Quest", false),
        (#"iphone"#, .phone, "Apple", false), (#"ipad"#, .phone, "Apple", false),
        (#"android|galaxy|pixel|oneplus|redmi|huawei|oppo|moto-"#, .phone, nil, false),
        (#"macbook|imac|mac-?mini|mac-?studio|mac-?pro|(^|[^a-z])mbp([^a-z]|$)"#, .computer, "Apple", false),
        (#"^(desktop|laptop)-[a-z0-9]{7}$"#, .computer, "Windows", false),
        (#"thinkpad|surface|raspberrypi|ubuntu|debian|fedora|(^|[^a-z])pc([^a-z]|$)|desktop|laptop|workstation"#, .computer, nil, true),
        (#"synology|diskstation|rackstation|(^|[^a-z])ds\d{3,4}"#, .nas, "Synology", false), (#"qnap|(^|[^a-z])ts-\d{3}"#, .nas, "QNAP", false),
        (#"wdmycloud|my.?cloud"#, .nas, "WD", false), (#"truenas|freenas|unraid|terramaster|asustor"#, .nas, nil, false), (#"(^|[^a-z])nas([^a-z]|$)"#, .nas, nil, true),
        (#"dji|mavic|osmo|avata"#, .drone, "DJI", false), (#"gopro"#, .drone, "GoPro", false), (#"insta360"#, .drone, "Insta360", false),
        (#"eero"#, .router, "eero", false), (#"orbi|^rb[rs]\d{2,3}"#, .router, "Netgear Orbi", false), (#"deco.?[mxpe]\d"#, .router, "TP-Link Deco", false),
        (#"velop"#, .router, "Linksys", false), (#"unifi|^u6-|^uap|^udm|ubnt"#, .router, "Ubiquiti", false), (#"fritz"#, .router, "FRITZ!", false),
        (#"airport"#, .router, "Apple", false), (#"(google|nest).?wifi"#, .router, "Google", false),
        (#"router|gateway|extender|repeater|access.?point|(^|[^a-z])mesh([^a-z]|$)"#, .router, nil, true),
    ]

    /// The Devices list reads every row's type on each redraw; the same few names and makers come back each time.
    final class Memo: @unchecked Sendable {
        private let lock = NSLock()
        private var products: [String: Product?] = [:]
        private var makers: [String: (DeviceType, DeviceTypeConfidence, String?)?] = [:]
        func product(_ text: String, _ find: () -> Product?) -> Product? {
            if let hit = lock.withLock({ products[text] }) { return hit }
            let found = find()
            lock.withLock { if products.count > 2000 { products = [:] }; products[text] = found }
            return found
        }
        func maker(_ text: String, _ find: () -> (DeviceType, DeviceTypeConfidence, String?)?) -> (DeviceType, DeviceTypeConfidence, String?)? {
            if let hit = lock.withLock({ makers[text] }) { return hit }
            let found = find()
            lock.withLock { if makers.count > 2000 { makers = [:] }; makers[text] = found }
            return found
        }
    }
    static let memo = Memo()

    static func product(in text: String) -> Product? {
        memo.product(text) {
            let lower = text.lowercased()
            for entry in products where lower.range(of: entry.pattern, options: .regularExpression) != nil {
                return Product(type: entry.type, brand: entry.brand, generic: entry.generic)
            }
            return nil
        }
    }

    /// Makers registered for an address (the IEEE's OUI names) or named in a UPnP description, and what they mostly
    /// make. A maker that makes one kind of thing is medium; one that makes several, low; makers of everything,
    /// such as Apple, Amazon, Google or Samsung, aren't listed: their address says nothing about the type.
    static let makers: [(pattern: String, type: DeviceType, confidence: DeviceTypeConfidence, brand: String)] = [
        ("^wyze", .camera, .medium, "Wyze"), ("^ring$", .camera, .medium, "Ring"), ("^arlo", .camera, .medium, "Arlo"), ("^blink", .camera, .medium, "Blink"),
        ("hikvision", .camera, .medium, "Hikvision"), ("ezviz", .camera, .medium, "EZVIZ"), ("^reolink", .camera, .medium, "Reolink"), ("^amcrest", .camera, .medium, "Amcrest"),
        ("^lorex", .camera, .medium, "Lorex"), ("dahua", .camera, .medium, "Dahua"), ("uniview", .camera, .medium, "Uniview"), ("^axis communications", .camera, .medium, "Axis"),
        ("^vivotek", .camera, .medium, "Vivotek"), ("hanwha vision|samsung techwin", .camera, .medium, "Hanwha"), ("^canary", .camera, .medium, "Canary"), ("^instar", .camera, .medium, "INSTAR"),
        ("^roku", .tv, .medium, "Roku"), ("^vizio", .tv, .medium, "Vizio"), ("hisense (electric|visual)", .tv, .medium, "Hisense"), ("tcl king", .tv, .medium, "TCL"),
        ("^sony visual", .tv, .medium, "Sony"), ("^sonos", .speaker, .medium, "Sonos"), ("^bose", .speaker, .medium, "Bose"), ("^sound united", .speaker, .medium, "Denon"),
        ("sony (interactive|computer) entertainment", .console, .medium, "PlayStation"), ("^nintendo", .console, .medium, "Nintendo"), ("^valve$", .console, .medium, "Valve"),
        ("^oculus|^meta platforms", .console, .low, "Meta"),
        ("^synology", .nas, .medium, "Synology"), ("^qnap", .nas, .medium, "QNAP"), ("^buffalo", .nas, .low, "Buffalo"), ("^western digital", .nas, .low, "WD"),
        ("^brother", .printer, .medium, "Brother"), ("^seiko epson", .printer, .medium, "Epson"), ("^kyocera document", .printer, .medium, "Kyocera"), ("^lexmark", .printer, .medium, "Lexmark"),
        ("^xerox", .printer, .medium, "Xerox"), ("^prusa", .printer, .medium, "Prusa"), ("^hp$", .printer, .medium, "HP"), ("^canon$", .printer, .low, "Canon"),
        ("dji", .drone, .medium, "DJI"), ("^gopro", .drone, .medium, "GoPro"), ("^arashi vision", .drone, .medium, "Insta360"), ("^skydio", .drone, .medium, "Skydio"), ("^parrot", .drone, .low, "Parrot"),
        ("^shelly", .plug, .medium, "Shelly"), ("meross", .plug, .medium, "Meross"), ("^tuya", .plug, .low, "Tuya"), ("^espressif", .plug, .low, "Espressif"), ("^belkin", .plug, .low, "Belkin"),
        ("^philips lighting|^signify", .hub, .medium, "Philips Hue"), ("^lumi united", .hub, .medium, "Aqara"), ("^smartthings", .hub, .medium, "SmartThings"),
        ("^athom", .hub, .medium, "Homey"), ("^ikea", .hub, .medium, "IKEA"), ("^lutron", .hub, .medium, "Lutron"),
        ("^eero", .router, .medium, "eero"), ("^plume", .router, .medium, "Plume"), ("^fritz|^avm", .router, .medium, "FRITZ!"), ("^draytek", .router, .medium, "DrayTek"),
        ("^zyxel", .router, .medium, "Zyxel"), ("linksys", .router, .medium, "Linksys"), ("^asus network", .router, .medium, "ASUS"), ("^sagemcom", .router, .medium, "Sagemcom"),
        ("^arris|^commscope", .router, .medium, "Arris"), ("^technicolor|^vantiva", .router, .medium, "Vantiva"), ("^actiontec", .router, .medium, "Actiontec"), ("^calix", .router, .medium, "Calix"),
        ("^hitron", .router, .medium, "Hitron"), ("^cisco meraki", .router, .medium, "Meraki"), ("^space exploration", .router, .medium, "Starlink"), ("^netgear", .router, .low, "Netgear"),
        ("^ubiquiti", .router, .low, "Ubiquiti"), ("^tp-link", .router, .low, "TP-Link"),
        ("^huawei device|^oneplus|^realme|^vivo mobile|^xiaomi communications|^motorola mobility", .phone, .low, ""),
        ("^raspberry pi", .computer, .low, "Raspberry Pi"), ("^intel corporate", .computer, .low, "Intel"),
    ]

    static func maker(_ vendor: String) -> (type: DeviceType, confidence: DeviceTypeConfidence, brand: String?)? {
        memo.maker(vendor) {
            let lower = vendor.lowercased()
            guard let entry = makers.first(where: { lower.range(of: $0.pattern, options: .regularExpression) != nil }) else { return nil }
            return (entry.type, entry.confidence, entry.brand.isEmpty ? shortVendor(vendor) : entry.brand)
        }.map { (type: $0.0, confidence: $0.1, brand: $0.2) }
    }

    /// "Hangzhou Hikvision Digital Technology Co.,Ltd" is too long to show beside a type; short tidy names pass.
    static func shortVendor(_ vendor: String) -> String? {
        var name = vendor
        for suffix in [" Co.,Ltd", " CO.,LTD", " Co., Ltd.", " Inc.", " Inc", " LLC", " Corporation", " Corporate", " Technologies", " Technology", " Electronics", " Communications"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        name = name.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        guard !name.isEmpty, name.count <= 18, !name.contains(",") else { return nil }
        return name == name.uppercased() && name.count > 4 ? name.capitalized : name
    }
}
