import Foundation

/// One connection that could carry the internet: a network service with an IPv4 address right now.
public struct ConnectionRoute: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case wifi
        /// A phone's tethering over USB (iPhone USB, an Android phone) or Bluetooth.
        case phone
        case ethernet
        case other
    }
    public var id: String { service }
    /// The network service's name, as System Settings › Network lists it: "iPhone USB", "USB 10/100/1000 LAN".
    public var service: String
    public var interface: String
    public var router: String?
    public var kind: Kind
    /// macOS sends the internet through this one now: it holds the default route.
    public var primary: Bool
    /// Whether 1.1.1.1 answered a ping sent out of this interface; nil until checked.
    public var internet: Bool?
    public init(service: String, interface: String, router: String?, kind: Kind, primary: Bool, internet: Bool? = nil) {
        self.service = service; self.interface = interface; self.router = router; self.kind = kind; self.primary = primary; self.internet = internet
    }

    /// The icon key: the system's hotspot glyph beside macOS's own, Phosphor's otherwise.
    public var symbol: String {
        switch kind {
        case .wifi: "wifi"
        case .phone: "personalhotspot"
        case .ethernet: service.lowercased().contains("usb") ? "cable.connector" : "network"
        case .other: "network"
        }
    }

    /// The kind from what System Configuration says about the service. A phone's USB tethering shows up as an Ethernet
    /// port named after the phone: Apple's "iPhone USB", Android's "Samsung Mobile USB Modem", "Pixel 8", RNDIS.
    public static func kind(service: String, hardwarePort: String?, wifi: Bool) -> Kind {
        if wifi { return .wifi }
        let names = (service + " " + (hardwarePort ?? "")).lowercased()
        if ["iphone", "ipad", "android", "pixel", "galaxy", "samsung", "mobile", "modem", "rndis", "tether", "bluetooth pan"].contains(where: names.contains) { return .phone }
        if ["thunderbolt bridge", "bridge"].contains(where: names.contains) { return .other }
        return .ethernet
    }
}

/// What Kilobat changed, kept until it's put back: the order before, the order Kilobat set, and why.
public struct PriorityHold: Codable, Equatable, Sendable {
    public var service: String
    public var interface: String
    public var previous: [String]
    public var applied: [String]
    public var since: Date
    /// The Wi-Fi the Mac kept for local devices, for the sentence.
    public var wifi: String?
    public init(service: String, interface: String, previous: [String], applied: [String], since: Date = Date(), wifi: String? = nil) {
        self.service = service; self.interface = interface; self.previous = previous; self.applied = applied; self.since = since; self.wifi = wifi
    }

    public static let key = "internetPriority.hold"
    public static func load(_ defaults: UserDefaults = .standard) -> PriorityHold? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(PriorityHold.self, from: $0) }
    }
    public func save(_ defaults: UserDefaults = .standard) { if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) } }
    public static func clear(_ defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}

/// "Use iPhone USB for internet, keep Wi-Fi for local devices": a connected service moved to the top of the network
/// service order, so it carries the default route and DNS while Wi-Fi stays joined for its own subnet.
public enum InternetPriority {
    /// How long the chosen connection may be gone before the order goes back: long enough for a phone that relocks or
    /// a cable that's reseated to come back by itself.
    public static let goneGrace: TimeInterval = 30

    /// Two or more connections are up: the moment the switch means something.
    public static func twoUp(_ routes: [ConnectionRoute]) -> Bool { routes.count >= 2 }

    /// The connections that could take over: up, not Wi-Fi, not already carrying the internet, and not known to have
    /// none. Phones first, then Ethernet.
    public static func candidates(_ routes: [ConnectionRoute]) -> [ConnectionRoute] {
        guard twoUp(routes) else { return [] }
        let order: [ConnectionRoute.Kind] = [.phone, .ethernet, .other]
        return routes.filter { $0.kind != .wifi && !$0.primary && $0.router != nil && $0.internet != false }
            .sorted { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
    }

    /// The one to offer first.
    public static func best(_ routes: [ConnectionRoute]) -> ConnectionRoute? { candidates(routes).first }

    /// The Wi-Fi carries the internet but has none, while another connection could: the switch is the fix, not an option.
    public static func urgent(_ routes: [ConnectionRoute], wifiHasInternet: Bool?) -> ConnectionRoute? {
        guard wifiHasInternet == false, routes.contains(where: { $0.kind == .wifi && $0.primary }) else { return nil }
        return candidates(routes).first { $0.internet == true } ?? candidates(routes).first
    }

    /// The connection carrying the internet now.
    public static func carrier(_ routes: [ConnectionRoute]) -> ConnectionRoute? { routes.first(where: \.primary) }

    public enum Restore: Equatable, Sendable {
        /// Put this order back.
        case apply([String])
        /// Nothing to do: the order is already back, or was changed elsewhere and is the person's own now.
        case leave(changedElsewhere: Bool)
    }

    /// What turning the switch off does with the order there now.
    public static func restore(_ hold: PriorityHold, current: [String]) -> Restore {
        if let order = ServiceOrder.restored(saved: hold.previous, current: current, promoted: hold.service) { return .apply(order) }
        return .leave(changedElsewhere: current.first != hold.service)
    }

    /// While the switch is on: whether its connection is still there. `goneSince` is when it was first missed.
    public static func shouldRestore(_ hold: PriorityHold, routes: [ConnectionRoute], goneSince: Date?, now: Date = Date()) -> Bool {
        guard !routes.contains(where: { $0.service == hold.service }) else { return false }
        guard let goneSince else { return false }
        return now.timeIntervalSince(goneSince) >= goneGrace
    }

    // MARK: Words

    /// "Use iPhone USB for internet".
    public static func useTitle(_ route: ConnectionRoute) -> String {
        String(localized: "Use \(route.service) for internet", comment: "Button: moves a connection such as iPhone USB to the top of the network service order")
    }
    /// "Use iPhone USB for internet, keep Wi-Fi for local devices".
    public static func useSentence(_ route: ConnectionRoute) -> String {
        String(localized: "Use \(route.service) for internet, keep Wi-Fi for local devices", comment: "Internet priority: the switch's full name; the argument is a connection such as iPhone USB")
    }
    public static let backTitle = String(localized: "Put Wi-Fi first again", comment: "Button: restores the network service order Kilobat changed")
    /// "Internet goes through Wi-Fi (Home) right now."
    public static func carrierLine(_ route: ConnectionRoute, wifiName: String?) -> String {
        if route.kind == .wifi, let wifiName {
            return String(localized: "Internet goes through Wi-Fi (\(wifiName)) right now.", comment: "Internet priority: which connection carries the default route; the argument is a Wi-Fi name")
        }
        return String(localized: "Internet goes through \(route.service) right now.", comment: "Internet priority: which connection carries the default route; the argument is a connection such as iPhone USB")
    }
    /// "iPhone USB carries the internet. Wi-Fi stays on GO2-8A2C1F for local devices."
    public static func activeLine(_ hold: PriorityHold) -> String {
        if let wifi = hold.wifi {
            return String(localized: "\(hold.service) carries the internet. Wi-Fi stays on \(wifi) for local devices.", comment: "Internet priority while on; the arguments are a connection such as iPhone USB and a Wi-Fi name")
        }
        return String(localized: "\(hold.service) carries the internet. Wi-Fi stays joined for local devices.", comment: "Internet priority while on; the argument is a connection such as iPhone USB")
    }
    /// What the switch does, for its tooltip and the panel.
    public static func explanation(_ route: ConnectionRoute) -> String {
        String(localized: "Moves \(route.service) to the top of the network service order, so websites and DNS go through it while the Mac stays on this Wi-Fi to reach the device. Kilobat puts the order back when you turn it off, when \(route.service) goes away, or when Kilobat quits.", comment: "Internet priority tooltip; the argument is a connection such as iPhone USB")
    }
}
