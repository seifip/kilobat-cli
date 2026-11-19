import Foundation

/// The steps a connection takes to come back after the Mac wakes, in order.
public enum WakeStage: String, Codable, Sendable, CaseIterable {
    /// Wi-Fi joined, or the cable's link came up.
    case link
    /// The router gave this Mac an address.
    case address
    /// A name lookup answered.
    case dns
    /// The first web request went through.
    case internet

    public var name: String {
        switch self {
        case .link: String(localized: "Link", comment: "Wake timing: Wi-Fi joined or the cable's link came up")
        case .address: String(localized: "Address", comment: "Wake timing: the router gave the Mac an address")
        case .dns: String(localized: "DNS", comment: "Wake timing: the first name lookup answered")
        case .internet: String(localized: "Internet", comment: "Wake timing: the first web request went through")
        }
    }
}

/// One wake: how many seconds after macOS said the Mac woke each step was first seen. A stage that never came within
/// the watch stays nil. Kept in the network journal (wakes.json); readings are about half a second apart, so the
/// times are good to about half a second.
public struct WakeRecord: Codable, Identifiable, Sendable, Equatable {
    public var id = UUID()
    public let woke: Date
    /// When the Mac went to sleep, when Kilobat saw it.
    public var slept: Date?
    public var interface: String?
    public var wired: Bool
    public var network: String?
    public var networkKey: String?
    public var link: Double?
    public var address: Double?
    public var dns: Double?
    public var internet: Double?
    /// The first ping reply from the internet: with a VPN, a reply without a web request means the tunnel passes ping
    /// but not TCP.
    public var ping: Double?
    /// The VPN that carried all traffic after the wake, when one did.
    public var vpn: String?
    public var fullTunnel: Bool?
    /// How long Kilobat watched.
    public var watched: Double

    public init(woke: Date, slept: Date? = nil, interface: String?, wired: Bool, network: String? = nil, networkKey: String? = nil,
                link: Double? = nil, address: Double? = nil, dns: Double? = nil, internet: Double? = nil, ping: Double? = nil,
                vpn: String? = nil, fullTunnel: Bool? = nil, watched: Double = 0) {
        self.woke = woke; self.slept = slept; self.interface = interface; self.wired = wired; self.network = network; self.networkKey = networkKey
        self.link = link; self.address = address; self.dns = dns; self.internet = internet; self.ping = ping
        self.vpn = vpn; self.fullTunnel = fullTunnel; self.watched = watched
    }

    public func seconds(_ stage: WakeStage) -> Double? {
        switch stage { case .link: link; case .address: address; case .dns: dns; case .internet: internet }
    }
    /// Whether the full tunnel passed TCP: nil without one.
    public var tunnelTCP: Bool? { fullTunnel == true ? internet != nil : nil }

    /// Back online within this is an ordinary wake.
    public static let slowAfter = 10.0
    /// What went wrong, if anything: the first stage that never came, or the slowest one.
    public enum Problem: Equatable, Sendable {
        case none
        /// Everything came back, but this stage took most of the time.
        case slow(WakeStage, seconds: Double)
        /// This stage never came within the watch.
        case never(WakeStage)
        /// Ping went through the VPN, web requests didn't.
        case tunnelNoTCP
    }

    public var problem: Problem {
        if fullTunnel == true, ping != nil, internet == nil { return .tunnelNoTCP }
        if let missing = WakeStage.allCases.first(where: { seconds($0) == nil }) { return .never(missing) }
        guard let internet, internet > Self.slowAfter else { return .none }
        // The step that took the longest is the one to name.
        var previous = 0.0, worst: (WakeStage, Double) = (.link, 0)
        for stage in WakeStage.allCases {
            let time = seconds(stage) ?? previous, gap = max(0, time - previous)
            if gap > worst.1 { worst = (stage, gap) }
            previous = max(previous, time)
        }
        return .slow(worst.0, seconds: worst.1)
    }

    /// "Link 0.4 s · Address 2.1 s · DNS 2.3 s · Internet 2.8 s", with "—" for a stage that never came.
    public var stagesLine: String {
        WakeStage.allCases.map { stage in
            "\(stage.name) " + (seconds(stage).map(Self.format) ?? "—")
        }.joined(separator: " · ")
    }
    static func format(_ seconds: Double) -> String {
        seconds < 10 ? String(format: "%.1f s", locale: Locale.current, seconds) : String(format: "%.0f s", locale: Locale.current, seconds)
    }

    public var title: String {
        switch problem {
        case .none:
            return internet.map { String(localized: "Back online \(Self.format($0)) after waking", comment: "Wake timing; the argument is like 2.8 s") }
                ?? String(localized: "Woke up", comment: "Wake timing")
        case .slow: return String(localized: "Slow to reconnect after sleep", comment: "Wake timing finding")
        case .never(.link): return wired ? String(localized: "The cable’s link didn’t come back after sleep", comment: "Wake timing finding")
                                         : String(localized: "Wi-Fi didn’t rejoin after sleep", comment: "Wake timing finding")
        case .never(.address): return String(localized: "No address after sleep", comment: "Wake timing finding")
        case .never(.dns): return String(localized: "DNS didn’t answer after sleep", comment: "Wake timing finding")
        case .never(.internet): return String(localized: "No internet after sleep", comment: "Wake timing finding")
        case .tunnelNoTCP: return String(localized: "\(vpn ?? String(localized: "Your VPN")) passed no web traffic after sleep", comment: "Wake timing finding; the argument is a VPN")
        }
    }

    /// Which step to look at, in plain words.
    public var advice: String? {
        let stage: WakeStage
        switch problem {
        case .none: return nil
        case .tunnelNoTCP:
            return String(localized: "Ping went through but web pages didn’t, though the VPN looked connected. Reconnect the VPN after waking. If that keeps happening, send its makers this timing.", comment: "Wake timing advice")
        case .slow(let slow, _): stage = slow
        case .never(let missing): stage = missing
        }
        switch stage {
        case .link:
            return wired ? String(localized: "The cable’s link was the slow part. Unplug the adapter or dock and plug it back in; if it happens after every sleep, look for a firmware update for the adapter or dock.", comment: "Wake timing advice")
                         : String(localized: "Joining Wi-Fi was the slow part. If it happens after every sleep, forget the network and join it again, or check for a macOS update.", comment: "Wake timing advice")
        case .address:
            return String(localized: "The router was slow to give this Mac an address. If it keeps happening, restart the router.", comment: "Wake timing advice")
        case .dns:
            return vpn != nil ? String(localized: "Lookups were the slow part, and they go through the VPN. Reconnecting the VPN usually fixes it.", comment: "Wake timing advice")
                              : String(localized: "Lookups were the slow part. Health shows whether a faster DNS would help.", comment: "Wake timing advice")
        case .internet:
            return String(localized: "This Mac was ready, but the first web request still waited, so the delay was past it: the router, the VPN or the provider.", comment: "Wake timing advice")
        }
    }

    /// The problem in plain English, for the CLI.
    public var plainProblem: String {
        switch problem {
        case .none: "none"
        case .slow(let stage, let seconds): "slow: \(stage.rawValue) took \(String(format: "%.1f", seconds))s"
        case .never(let stage): "\(stage.rawValue) never came back"
        case .tunnelNoTCP: "\(vpn ?? "VPN") passed ping but no web traffic"
        }
    }
    /// Plain English for the CLI and logs, whatever the app's language.
    public var plainLine: String {
        let stages = WakeStage.allCases.map { "\($0.rawValue) \(seconds($0).map { String(format: "%.1fs", $0) } ?? "never")" }.joined(separator: ", ")
        let tunnel = tunnelTCP.map { $0 ? ", tunnel passed TCP" : ", tunnel passed no TCP" + (ping != nil ? " (ping did)" : "") } ?? ""
        return stages + tunnel
    }
}

/// Builds one wake's record from readings taken while watching; the probe does the reading. Each stage keeps the
/// first time it was seen, and a later stage seen first fills the earlier ones, since it needs them.
public struct WakeWatch: Sendable {
    public private(set) var record: WakeRecord
    public init(woke: Date, slept: Date? = nil, interface: String?, wired: Bool) {
        record = WakeRecord(woke: woke, slept: slept, interface: interface, wired: wired)
    }
    public mutating func observe(at seconds: Double, link: Bool?, address: Bool?) {
        if address == true { seen(.address, seconds) }
        if link == true { seen(.link, seconds) }
        record.watched = max(record.watched, seconds)
    }
    public mutating func dnsAnswered(at seconds: Double) { seen(.dns, seconds) }
    public mutating func internetAnswered(at seconds: Double) { seen(.internet, seconds) }
    public mutating func pingAnswered(at seconds: Double) { if record.ping == nil { record.ping = seconds } }
    public mutating func tunnel(vpn: String?, full: Bool) { record.vpn = full ? (vpn ?? "VPN") : nil; record.fullTunnel = full ? true : nil }
    /// Everything that can be seen has been: the web works and ping had its chance.
    public func done(at seconds: Double) -> Bool {
        guard let internet = record.internet else { return false }
        return record.ping != nil || seconds - internet >= 4
    }

    private mutating func seen(_ stage: WakeStage, _ seconds: Double) {
        for earlier in WakeStage.allCases.prefix(while: { $0 != stage }) + [stage] where record.seconds(earlier) == nil {
            switch earlier {
            case .link: record.link = seconds
            case .address: record.address = seconds
            case .dns: record.dns = seconds
            case .internet: record.internet = seconds
            }
        }
        record.watched = max(record.watched, seconds)
    }
}
