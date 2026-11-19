import Foundation

/// What on this Mac can keep a Wi-Fi's sign-in page from showing: DNS the person set themselves, encrypted DNS from a
/// profile or an app, a VPN, and iCloud Private Relay. These are the fixes people pass around when the page never
/// appears. Kilobat can switch the first one for the sign-in and put it back; the others are the person's to turn off.
public struct PortalBlockers: Equatable, Sendable {
    /// Manual DNS servers the person set on this network service. Kilobat's own Fastest DNS switch isn't one: that
    /// already goes back by itself on a sign-in page.
    public var ownDNS: [String]
    /// A configuration profile or an app's DNS settings decide lookups: encrypted DNS or a DNS proxy.
    public var encryptedDNS: Bool
    /// A VPN carries this Mac's traffic, by name when known.
    public var vpn: Bool
    public var vpnName: String?
    /// iCloud Private Relay: on, off, or nil when Kilobat can't tell. Unknown is only ever mentioned as a maybe.
    public var privateRelay: Bool?

    public init(ownDNS: [String] = [], encryptedDNS: Bool = false, vpn: Bool = false, vpnName: String? = nil, privateRelay: Bool? = nil) {
        self.ownDNS = ownDNS; self.encryptedDNS = encryptedDNS; self.vpn = vpn; self.vpnName = vpnName; self.privateRelay = privateRelay
    }

    /// From what the Mac reports. `serviceServers` is the service's manual DNS (empty when automatic, nil when it
    /// couldn't be read); `kilobatServers` is what Fastest DNS set there itself, if anything.
    public static func read(serviceServers: [String]?, kilobatServers: [String]?, managed: Bool, vpn: ExitPath.VPN, vpnName: String?,
                            privateRelay: Bool? = nil) -> PortalBlockers {
        var own = (serviceServers ?? []).filter(DNSAddress.valid)
        if let kilobatServers, !kilobatServers.isEmpty, Set(kilobatServers) == Set(own) { own = [] }
        // A partial VPN carries only some destinations; the sign-in page isn't one of them.
        return PortalBlockers(ownDNS: own, encryptedDNS: managed, vpn: vpn == .full, vpnName: vpn == .full ? vpnName : nil, privateRelay: privateRelay)
    }

    /// Nothing on this Mac is known to be in the way.
    public var isEmpty: Bool { ownDNS.isEmpty && !encryptedDNS && !vpn && privateRelay != true }
    /// Kilobat can clear this one itself, once the person says yes.
    public var switchesDNS: Bool { !ownDNS.isEmpty }

    /// What the person has to turn off themselves, most disruptive first.
    public enum Item: Equatable, Sendable {
        case vpn(String?)
        case privateRelay(sure: Bool)
        case encryptedDNS
    }
    public var forPerson: [Item] {
        var items: [Item] = []
        if vpn { items.append(.vpn(vpnName)) }
        if encryptedDNS { items.append(.encryptedDNS) }
        // Private Relay only covers Safari and a few system requests, so with a VPN carrying everything it isn't the
        // one in the way.
        if privateRelay == true { items.append(.privateRelay(sure: true)) } else if privateRelay == nil, !vpn { items.append(.privateRelay(sure: false)) }
        return items
    }

    /// What the cause's title names: the one Kilobat fixes, else the biggest one the person has to.
    public var lead: String? {
        if switchesDNS { return String(localized: "Your DNS settings", comment: "Fix it: what may hide a Wi-Fi sign-in page; the start of 'Your DNS settings may hide the sign-in page'") }
        if vpn { return vpnName ?? String(localized: "Your VPN", comment: "Fix it: what may hide a Wi-Fi sign-in page") }
        if encryptedDNS { return String(localized: "Encrypted DNS", comment: "Fix it: what may hide a Wi-Fi sign-in page: a DNS profile or app") }
        if privateRelay == true { return String(localized: "Private Relay", comment: "Fix it: what may hide a Wi-Fi sign-in page: iCloud Private Relay") }
        return nil
    }

    /// For a prompt pasted into an AI service: what was in the way, in English and without addresses.
    var agentNote: String? {
        var parts: [String] = []
        if switchesDNS { parts.append("custom DNS servers") }
        if encryptedDNS { parts.append("an encrypted DNS profile or app") }
        if vpn { parts.append("a VPN") }
        if privateRelay == true { parts.append("iCloud Private Relay") }
        return parts.isEmpty ? nil : "This Mac has " + parts.joined(separator: ", ") + ", which can hide the sign-in page."
    }

    /// A plain http address: a sign-in page answers for any unencrypted page, so this brings it up when the browser
    /// went straight to an https site and nothing appeared. Apple's own check host, which Kilobat already asks.
    public static let plainPage = URL(string: "http://captive.apple.com/")!
}

/// While Fix it has this Wi-Fi on its own DNS for a sign-in, the DNS to put back. Saved before the switch, so a quit
/// or a crash in between still finds it.
public struct PortalDNSHold: Codable, Equatable, Sendable {
    public var service: String
    public var servers: [String]
    public var date: Date
    public init(service: String, servers: [String], date: Date = Date()) { self.service = service; self.servers = servers; self.date = date }

    public static let key = "fixit.portalDNSHold"
    public static func load(_ defaults: UserDefaults = .standard) -> PortalDNSHold? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(PortalDNSHold.self, from: $0) }
    }
    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
    public static func clear(_ defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }

    /// Whether to put the person's DNS back now: only while the service still has the Wi-Fi's own DNS, which is what
    /// Fix it set. If they changed it since, theirs stands.
    public func shouldRestore(current: [String]?) -> Bool {
        guard let current else { return false }
        return current.isEmpty && !servers.isEmpty
    }
}
