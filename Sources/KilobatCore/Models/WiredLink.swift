import Foundation

/// One interface as `ifconfig -v -m` prints it: the media it negotiated, what it supports, and its addresses.
public struct IfconfigReading: Equatable, Sendable {
    public var name: String
    /// "status: active": a cable is in and the other end answered.
    public var active = false
    /// The negotiated media subtype, such as "1000baseT"; nil for "none" or a bare "autoselect".
    public var media: String?
    /// The media options, such as ["full-duplex", "flow-control"].
    public var options: [String] = []
    /// Every subtype in "supported media", such as ["10baseT/UTP", "100baseTX", "1000baseT"].
    public var supported: [String] = []
    /// "link rate: 1.00 Gbps", in Mbps.
    public var linkRateMbps: Double?
    /// "type: USB Ethernet"
    public var type: String?
    public var ipv4: [String] = []
    /// Addresses other than link-local (fe80::).
    public var ipv6: [String] = []

    public init(name: String) { self.name = name }

    /// The negotiated speed: from the media subtype, else the link rate.
    public var speedMbps: Double? { media.flatMap(WiredLink.mbps) ?? (active ? linkRateMbps : nil) }
    /// The fastest the adapter offers.
    public var bestMbps: Double? { supported.compactMap(WiredLink.mbps).max() }
    public var duplex: WiredLink.Duplex? {
        if options.contains("full-duplex") { return .full }
        if options.contains("half-duplex") { return .half }
        return nil
    }
    /// An address someone on the cable gave it, or one set by hand: anything but a 169.254 self-assigned one.
    public var hasAddress: Bool { ipv4.contains { !$0.hasPrefix("169.254.") } || !ipv6.isEmpty }
}

public enum WiredLink {
    public enum Duplex: String, Codable, Sendable { case full, half }

    /// Every interface block in `ifconfig -v -m -a`, by name.
    public static func parseIfconfig(_ text: String) -> [String: IfconfigReading] {
        var readings: [String: IfconfigReading] = [:], current: IfconfigReading?, inSupported = false
        func finish() { if let current { readings[current.name] = current } }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let first = line.first, !first.isWhitespace, let colon = line.firstIndex(of: ":"), line.contains("flags=") {
                finish(); current = IfconfigReading(name: String(line[..<colon])); inSupported = false
                continue
            }
            guard current != nil else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "supported media:" { inSupported = true; continue }
            if inSupported {
                if trimmed.hasPrefix("media ") {
                    let subtype = trimmed.dropFirst(6).split(separator: " ").first.map(String.init)
                    if let subtype, mbps(subtype) != nil, !current!.supported.contains(subtype) { current!.supported.append(subtype) }
                    continue
                }
                inSupported = false
            }
            if trimmed.hasPrefix("media:") {
                let (media, options) = parseMedia(String(trimmed.dropFirst(6)))
                current!.media = media; current!.options = options
            } else if trimmed.hasPrefix("status:") {
                current!.active = trimmed.dropFirst(7).trimmingCharacters(in: .whitespaces) == "active"
            } else if trimmed.hasPrefix("link rate:") {
                current!.linkRateMbps = rate(String(trimmed.dropFirst(10)))
            } else if trimmed.hasPrefix("type:") {
                current!.type = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("inet ") {
                if let address = trimmed.split(separator: " ").dropFirst().first { current!.ipv4.append(String(address)) }
            } else if trimmed.hasPrefix("inet6 ") {
                if let address = trimmed.split(separator: " ").dropFirst().first.map(String.init), !address.lowercased().hasPrefix("fe80") {
                    current!.ipv6.append(address)
                }
            }
        }
        finish()
        return readings
    }

    /// " autoselect (1000baseT <full-duplex,flow-control>)", " 100baseTX <full-duplex>", " autoselect (none)", " none".
    static func parseMedia(_ value: String) -> (String?, [String]) {
        var text = value.trimmingCharacters(in: .whitespaces)
        if let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close {
            text = String(text[text.index(after: open)..<close])
        }
        var options: [String] = []
        if let open = text.firstIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            options = text[text.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            text = String(text[..<open])
        }
        let subtype = text.trimmingCharacters(in: .whitespaces)
        return (mbps(subtype) == nil ? nil : subtype, options)
    }

    /// "10baseT/UTP" 10, "100baseTX" 100, "1000baseT" 1000, "2500Base-T" 2500, "10Gbase-T" 10 000. Nil for autoselect and none.
    public static func mbps(_ subtype: String) -> Double? {
        guard let match = subtype.firstMatch(of: /^(\d+(?:\.\d+)?)(G?)base/.ignoresCase()), let number = Double(match.1) else { return nil }
        return match.2.isEmpty ? number : number * 1000
    }

    /// "100.00 Mbps", "1.00 Gbps", "10.00 Gbps"
    static func rate(_ value: String) -> Double? {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard parts.count >= 2, let number = Double(parts[0]) else { return nil }
        switch parts[1].lowercased() {
        case "gbps": return number * 1000
        case "mbps": return number
        case "kbps": return number / 1000
        default: return nil
        }
    }

    /// "100 Mbps", "1 Gbps", "2.5 Gbps", "10 Gbps"
    public static func speed(_ mbps: Double) -> String {
        if mbps >= 1000 {
            let gbps = mbps / 1000
            return (gbps.rounded() == gbps ? String(format: "%.0f", gbps) : String(format: "%.1f", gbps)) + " Gbps"
        }
        return String(format: "%.0f", mbps) + " Mbps"
    }

    /// USB Ethernet chips Kilobat can name from the USB maker and product numbers, with the fastest each can do.
    /// Only the common ones whose numbers are well known; anything else shows the maker's own name for it.
    public static let chips: [UInt32: (name: String, mbps: Double)] = [
        0x0BDA_8152: ("Realtek RTL8152", 100),
        0x0BDA_8153: ("Realtek RTL8153", 1000),
        0x0BDA_8156: ("Realtek RTL8156", 2500),
        0x0BDA_8157: ("Realtek RTL8157", 5000),
        0x0B95_1790: ("ASIX AX88179", 1000),
        0x0B95_178A: ("ASIX AX88178A", 1000),
        0x0B95_772B: ("ASIX AX88772B", 100),
        0x0B95_7720: ("ASIX AX88772", 100),
        0x05AC_1402: ("Apple USB Ethernet Adapter", 100),
        0x2357_0601: ("TP-Link UE300 (Realtek RTL8153)", 1000),
    ]
    public static func chip(vendor: Int?, product: Int?) -> (name: String, mbps: Double)? {
        guard let vendor, let product, (0...0xFFFF).contains(vendor), (0...0xFFFF).contains(product) else { return nil }
        return chips[UInt32(vendor) << 16 | UInt32(product)]
    }
}

/// One node in the IORegistry, from an Ethernet interface up through its parents, as plain values so the reading
/// can be tested without the hardware.
public struct RegistryNode: Sendable, Equatable {
    public var className: String
    public var name: String
    public var strings: [String: String]
    public var numbers: [String: Int]
    public init(className: String, name: String = "", strings: [String: String] = [:], numbers: [String: Int] = [:]) {
        self.className = className; self.name = name; self.strings = strings; self.numbers = numbers
    }
}

/// What an adapter is, read from its IORegistry path: how it's attached, who made it, its chip and its driver.
public struct WiredIdentity: Codable, Sendable, Equatable {
    public enum Attachment: String, Codable, Sendable { case usb, thunderbolt, builtIn }
    public var attachment: Attachment?
    public var vendor: String?
    public var product: String?
    public var vendorID: Int?
    public var productID: Int?
    /// "Realtek RTL8153", when Kilobat knows the chip.
    public var chip: String?
    /// The fastest the chip can do, when Kilobat knows it.
    public var chipMbps: Double?
    /// "AppleUserECM", "AX88179_178A"
    public var driver: String?
    /// Apple's own driver, rather than one the maker supplied.
    public var appleDriver: Bool?
    /// The USB link the adapter sits on, in Mbps: 480 for USB 2, 5000 for USB 3.
    public var usbMbps: Double?

    public init(attachment: Attachment? = nil, vendor: String? = nil, product: String? = nil, vendorID: Int? = nil, productID: Int? = nil,
                chip: String? = nil, chipMbps: Double? = nil, driver: String? = nil, appleDriver: Bool? = nil, usbMbps: Double? = nil) {
        self.attachment = attachment; self.vendor = vendor; self.product = product; self.vendorID = vendorID; self.productID = productID
        self.chip = chip; self.chipMbps = chipMbps; self.driver = driver; self.appleDriver = appleDriver; self.usbMbps = usbMbps
    }

    /// Why an interface isn't an Ethernet port to report on, or nil when it is one. `chain` starts at the interface.
    public enum Skip: String, Sendable { case wifi, thunderboltBridge, macAsDevice, phone }
    public static func skip(_ chain: [RegistryNode]) -> Skip? {
        for node in chain {
            if node.className.contains("WLAN") || node.className.contains("80211") { return .wifi }
            // Thunderbolt 1, 2…: the Mac's own ports, for a cable to another Mac.
            if node.className.hasPrefix("AppleThunderboltIP") { return .thunderboltBridge }
            // The Mac's own USB-C port acting as a device (to another Mac or a display), not an adapter plugged into it.
            if node.className == "IOUSBDeviceInterface" || node.className.hasPrefix("AppleUSBDevice") { return .macAsDevice }
            if let product = node.strings["USB Product Name"] ?? node.strings["kUSBProductString"], ["iPhone", "iPad"].contains(where: product.hasPrefix) { return .phone }
        }
        return nil
    }

    public static func read(_ chain: [RegistryNode]) -> WiredIdentity {
        var identity = WiredIdentity()
        // The interface's parent is the controller its driver publishes.
        if let controller = chain.dropFirst().first {
            let name = controller.strings["IOUserClass"] ?? (controller.name.isEmpty ? controller.className : controller.name)
            identity.driver = name
            let bundle = controller.strings["CFBundleIdentifier"] ?? controller.strings["IOUserServerName"]
            identity.appleDriver = bundle.map { $0.hasPrefix("com.apple.") } ?? (name.hasPrefix("Apple") || controller.className.hasPrefix("Apple"))
            if let vendor = controller.strings["IOVendor"], let model = controller.strings["IOModel"], !vendor.isEmpty, !model.isEmpty {
                identity.chip = model.hasPrefix(vendor) ? model : "\(vendor) \(model)"
            }
        }
        let usb = chain.first { $0.numbers["idVendor"] != nil && $0.numbers["idProduct"] != nil && ($0.className.contains("USB") || $0.strings["USB Product Name"] != nil || $0.strings["kUSBProductString"] != nil) }
        if let usb {
            identity.attachment = .usb
            identity.vendorID = usb.numbers["idVendor"]; identity.productID = usb.numbers["idProduct"]
            identity.vendor = (usb.strings["USB Vendor Name"] ?? usb.strings["kUSBVendorString"]).flatMap(clean)
            identity.product = (usb.strings["USB Product Name"] ?? usb.strings["kUSBProductString"]).flatMap(clean)
            if let known = WiredLink.chip(vendor: identity.vendorID, product: identity.productID) { identity.chip = known.name; identity.chipMbps = known.mbps }
            if let bits = usb.numbers["UsbLinkSpeed"], bits > 0 { identity.usbMbps = Double(bits) / 1_000_000 }
            else if let speed = usb.numbers["USBSpeed"] ?? usb.numbers["Device Speed"] { identity.usbMbps = [0: 1.5, 1: 12, 2: 480, 3: 5000, 4: 10_000, 5: 20_000][speed] }
        }
        // A Thunderbolt adapter or dock is PCI behind a Thunderbolt switch; the Mac's own Ethernet is PCI with neither.
        if chain.contains(where: { $0.className.contains("Thunderbolt") }) { identity.attachment = identity.attachment ?? .thunderbolt }
        else if identity.attachment == nil, chain.contains(where: { $0.className == "IOPCIDevice" }) { identity.attachment = .builtIn }
        return identity
    }

    private static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// "Realtek USB 10/100/1000 LAN", without the maker twice.
    public var label: String? {
        switch (vendor, product) {
        case let (vendor?, product?): product.localizedCaseInsensitiveContains(vendor) ? product : "\(vendor) \(product)"
        case let (nil, product?): product
        case let (vendor?, nil): vendor
        case (nil, nil): nil
        }
    }
}

/// One Ethernet port on this Mac, built in or plugged in: its link, what it is and whether macOS has a service for it.
public struct WiredAdapter: Codable, Sendable, Equatable, Identifiable {
    public var id: String { interface }
    public var interface: String
    /// The name Network settings gives it, such as "USB 10/100/1000 LAN" or "Ethernet".
    public var name: String
    public var identity: WiredIdentity
    /// Network settings' service for it; nil when it has none.
    public var service: String?
    public var serviceEnabled: Bool?
    public var linked: Bool
    public var speedMbps: Double?
    public var duplex: WiredLink.Duplex?
    /// The fastest the adapter offers, from its supported media, or its chip when it lists none.
    public var bestMbps: Double?
    public var hasAddress: Bool

    public init(interface: String, name: String, identity: WiredIdentity = WiredIdentity(), service: String? = nil, serviceEnabled: Bool? = nil,
                linked: Bool = false, speedMbps: Double? = nil, duplex: WiredLink.Duplex? = nil, bestMbps: Double? = nil, hasAddress: Bool = false) {
        self.interface = interface; self.name = name; self.identity = identity; self.service = service; self.serviceEnabled = serviceEnabled
        self.linked = linked; self.speedMbps = speedMbps; self.duplex = duplex; self.bestMbps = bestMbps; self.hasAddress = hasAddress
    }

    public init(interface: String, name: String, identity: WiredIdentity, reading: IfconfigReading?, service: String?, serviceEnabled: Bool?) {
        let best = [reading?.bestMbps, identity.chipMbps].compactMap { $0 }.max()
        self.init(interface: interface, name: name, identity: identity, service: service, serviceEnabled: serviceEnabled,
                  linked: reading?.active ?? false, speedMbps: reading?.active == true ? reading?.speedMbps : nil, duplex: reading?.active == true ? reading?.duplex : nil,
                  bestMbps: best, hasAddress: reading?.hasAddress ?? false)
    }

    /// "1 Gbps · full duplex", "Not connected"
    public var linkLine: String {
        guard linked else { return String(localized: "No cable", comment: "Health › The wired link: nothing plugged into this Ethernet port") }
        let speed = speedMbps.map(WiredLink.speed) ?? String(localized: "Connected", comment: "Health › The wired link: linked, speed unknown")
        switch duplex {
        case .full: return String(localized: "\(speed) · full duplex", comment: "Health › The wired link: the negotiated Ethernet speed, such as 1 Gbps, sending and receiving at once")
        case .half: return String(localized: "\(speed) · half duplex", comment: "Health › The wired link: the negotiated Ethernet speed, such as 100 Mbps, taking turns to send and receive")
        case nil: return speed
        }
    }
    /// The link is slower than the adapter can go.
    public var belowBest: Bool {
        guard linked, let speedMbps, let bestMbps else { return false }
        return speedMbps < bestMbps
    }
}

/// A USB device Kilobat knows as an Ethernet adapter that has no network interface: macOS has no driver for it.
public struct WiredMissingDriver: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(vendorID):\(productID):\(location ?? 0)" }
    public var vendorID: Int
    public var productID: Int
    public var chip: String
    public var product: String?
    public var location: Int?
    public init(vendorID: Int, productID: Int, chip: String, product: String? = nil, location: Int? = nil) {
        self.vendorID = vendorID; self.productID = productID; self.chip = chip; self.product = product; self.location = location
    }
}

/// Every wired port, and what's wrong with any of them.
public struct WiredReport: Codable, Sendable, Equatable {
    public struct Finding: Codable, Sendable, Equatable, Identifiable {
        public enum Kind: String, Codable, Sendable { case slowerThanAdapter, halfDuplex, usb2, noService, serviceOff, noAddress, noDriver }
        public enum Level: String, Codable, Sendable { case caution, problem }
        public var id: String { "\(kind.rawValue):\(interface ?? "")" }
        public let kind: Kind
        public let interface: String?
        public let level: Level
        public let title: String
        public let detail: String
        /// Network settings would fix it: the finding offers to open them.
        public var opensNetworkSettings: Bool { [.noService, .serviceOff, .noAddress].contains(kind) }
    }
    public var date: Date
    public var adapters: [WiredAdapter]
    public var missingDrivers: [WiredMissingDriver]
    public var findings: [Finding]

    public init(date: Date = Date(), adapters: [WiredAdapter], missingDrivers: [WiredMissingDriver] = []) {
        self.date = date; self.adapters = adapters; self.missingDrivers = missingDrivers
        findings = Self.findings(adapters: adapters, missingDrivers: missingDrivers)
    }

    /// Worst first. Each says what it is and what to try; Kilobat changes nothing itself.
    public static func findings(adapters: [WiredAdapter], missingDrivers: [WiredMissingDriver]) -> [Finding] {
        var found: [Finding] = []
        for driver in missingDrivers {
            let name = driver.product ?? driver.chip
            found.append(Finding(kind: .noDriver, interface: nil, level: .problem,
                                 title: String(localized: "\(name) has no driver", comment: "Health finding: a USB Ethernet adapter macOS sees but can't use; the adapter's name"),
                                 detail: String(localized: "macOS sees this \(driver.chip) adapter on USB but has no driver for it, so it can’t connect. Install the maker’s driver for this chip, or use an adapter that works without one.", comment: "Health finding; the chip's name, such as ASIX AX88179")))
        }
        for adapter in adapters {
            let name = adapter.name
            if adapter.service == nil {
                found.append(Finding(kind: .noService, interface: adapter.interface, level: adapter.linked ? .problem : .caution,
                                     title: String(localized: "\(name) has no network service", comment: "Health finding: an Ethernet adapter with nothing set up for it in Network settings; the adapter's name"),
                                     detail: String(localized: "macOS sees the adapter but won’t use it. In Network settings, choose Add Service from the ⋯ menu and pick it. Reinstalling macOS won’t help.", comment: "Health finding")))
                continue
            }
            if adapter.serviceEnabled == false {
                // An unused dock port someone switched off on purpose isn't worth a line.
                if adapter.linked {
                    found.append(Finding(kind: .serviceOff, interface: adapter.interface, level: .caution,
                                         title: String(localized: "\(name) is turned off in Network settings", comment: "Health finding: an Ethernet service made inactive; the adapter's name"),
                                         detail: String(localized: "A cable is plugged in, but macOS won’t use it until you make the service active again in Network settings.", comment: "Health finding")))
                }
                continue
            }
            guard adapter.linked else { continue }
            if !adapter.hasAddress {
                found.append(Finding(kind: .noAddress, interface: adapter.interface, level: .problem,
                                     title: String(localized: "\(name) is plugged in but has no address", comment: "Health finding: Ethernet linked but nothing gave the Mac an address; the adapter's name"),
                                     detail: String(localized: "Nothing on the cable gave this Mac an address. Check that it goes to your router. If it does, delete this service in Network settings and add it again; that clears a stuck adapter.", comment: "Health finding")))
            }
            if adapter.duplex == .half {
                found.append(Finding(kind: .halfDuplex, interface: adapter.interface, level: .problem,
                                     title: String(localized: "\(name) can’t send and receive at once", comment: "Health finding: Ethernet negotiated half duplex; the adapter's name"),
                                     detail: String(localized: "It’s taking turns (half duplex), which slows it and causes errors. A damaged cable or the port at the other end usually causes this: try another of each.", comment: "Health finding")))
            }
            if adapter.belowBest, let speed = adapter.speedMbps, let best = adapter.bestMbps {
                found.append(Finding(kind: .slowerThanAdapter, interface: adapter.interface, level: speed <= 100 && best >= 1000 ? .problem : .caution,
                                     title: String(localized: "Ethernet is running at \(WiredLink.speed(speed))", comment: "Health finding: the wired link is slower than the adapter can go; a speed such as 100 Mbps"),
                                     detail: String(localized: "This adapter can do \(WiredLink.speed(best)). Usually the cable, the port it’s plugged into or a dock in between holds it back: try another cable, then another port.", comment: "Health finding; the adapter's fastest speed, such as 1 Gbps")))
            } else if let usb = adapter.identity.usbMbps, usb <= 480, let best = adapter.bestMbps, best >= 1000 {
                // Only when the link isn't already explained by a slower negotiation.
                found.append(Finding(kind: .usb2, interface: adapter.interface, level: .caution,
                                     title: String(localized: "\(name) is on a USB 2 connection", comment: "Health finding: a gigabit USB Ethernet adapter on a slow USB link; the adapter's name"),
                                     detail: String(localized: "USB 2 tops out around 300 Mbps, under this adapter’s \(WiredLink.speed(best)). Plug it straight into the Mac rather than a hub, a keyboard or an older dock.", comment: "Health finding; the adapter's fastest speed, such as 1 Gbps")))
            }
        }
        return found.sorted { ($0.level == .problem ? 0 : 1) < ($1.level == .problem ? 0 : 1) }
    }
}
