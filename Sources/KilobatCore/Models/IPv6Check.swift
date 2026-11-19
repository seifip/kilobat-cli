import Foundation

/// What a check found about IPv6 on the network in use. Facts only: no address, interface or prefix is kept.
/// (`IPv6Facts`, in Smart Home, is a different thing on purpose: which kinds of address an interface holds, for Matter.)
public struct IPv6Reading: Codable, Sendable, Equatable {
    /// The IPv6 primary interface holds a 2000::/3 address (not fe80::, not fc00::/7).
    public var globalAddress: Bool
    /// An IPv6 default route exists. Nil: the route state could not be read.
    public var defaultRoute: Bool?
    /// An IPv4 default route exists.
    public var ipv4Route: Bool
    /// Either default route leaves through a tunnel.
    public var tunneled: Bool
    /// IPv6 connected to at least one of two public addresses. Nil: not tried.
    public var reachable: Bool?
    /// IPv4 connected to its public address. Nil: not tried.
    public var ipv4Reachable: Bool?

    public init(globalAddress: Bool, defaultRoute: Bool?, ipv4Route: Bool, tunneled: Bool, reachable: Bool?, ipv4Reachable: Bool?) {
        self.globalAddress = globalAddress; self.defaultRoute = defaultRoute; self.ipv4Route = ipv4Route
        self.tunneled = tunneled; self.reachable = reachable; self.ipv4Reachable = ipv4Reachable
    }
}

public enum IPv6Verdict: String, Codable, Sendable {
    /// No global IPv6 address, or an address with no default route: nothing is offered.
    case none
    case working
    /// An address and a route, IPv4 connects, neither IPv6 target does.
    case advertisedButBroken
    /// No IPv4 default route and IPv6 connects.
    case ipv6Only
    case unknown
}

/// A line for Health, in measured words only.
public struct IPv6Finding: Sendable, Equatable {
    public enum Level: Sendable, Equatable { case caution, fine }
    public let id: String
    public let title: String
    public let detail: String
    /// The tooltip and VoiceOver text: the measured sentences, without the advice.
    public let help: String
    public let level: Level
}

public enum IPv6Check {
    /// Seconds a connection has to open. BSD retransmits a lost SYN at about 1 s and again at about 3 s.
    public static let connectTimeout = 3.0
    /// Seconds between checks on a network that has IPv6.
    public static let recheckInterval = 15.0 * 60
    /// Seconds before a first failure is tried again, so a break that lasts is confirmed within about two minutes.
    public static let retryInterval = 60.0
    /// Cloudflare and Google, which Kilobat already contacts for its pings. Both must fail for a failure to count.
    public static let targets6 = ["2606:4700:4700::1111", "2001:4860:4860::8888"]
    public static let target4 = "1.1.1.1"

    /// First matching row wins.
    public static func verdict(_ r: IPv6Reading) -> IPv6Verdict {
        if r.tunneled { return .unknown }
        if !r.globalAddress { return .none }
        guard let route = r.defaultRoute else { return .unknown }
        if !route { return .none }
        guard let reachable = r.reachable else { return .unknown }
        if reachable { return r.ipv4Route ? .working : .ipv6Only }
        return r.ipv4Reachable == true ? .advertisedButBroken : .unknown
    }

    /// Whether a connection is worth opening at all: an address and a route to use it, and no tunnel owning either route.
    public static func canConnect(_ r: IPv6Reading) -> Bool { r.globalAddress && r.defaultRoute == true && !r.tunneled }

    /// Two readings in a row, on one network. A reading that is not a failure stays in the history, so a failure, a
    /// success and a failure do not add up.
    public static func confirmed(_ recent: [IPv6Verdict]) -> Bool {
        let last = recent.suffix(2)
        return last.count == 2 && last.allSatisfy { $0 == .advertisedButBroken }
    }

    /// Whether a run that opens connections is due. The first run on a network, and one the person asked for, always
    /// go; after that every 15 minutes, or a minute after an unconfirmed failure. A metered network is left alone
    /// between those.
    public static func due(now: Date, lastRun: Date?, lastVerdict: IPv6Verdict?, confirmed: Bool, metered: Bool, forced: Bool) -> Bool {
        if forced { return true }
        guard let lastRun else { return true }
        if metered { return false }
        let wait = lastVerdict == .advertisedButBroken && !confirmed ? retryInterval : recheckInterval
        return now.timeIntervalSince(lastRun) >= wait
    }

    public static func finding(_ verdict: IPv6Verdict, confirmed: Bool) -> IPv6Finding? {
        switch verdict {
        case .advertisedButBroken:
            guard confirmed else { return nil }
            let measured = String(localized: "This Mac has an IPv6 address and route here, but connections to Cloudflare and Google over IPv6 didn’t go through, twice in a row. A connection to Cloudflare over IPv4 did.",
                                  comment: "Health finding tooltip: what was measured when IPv6 doesn’t connect, with no advice")
            let advice = String(localized: "If some apps are slow to connect, restart your router; if it stays like this, check its IPv6 settings or ask your provider.",
                                comment: "Health finding: what to try when IPv6 doesn’t connect; follows the measured sentences")
            return IPv6Finding(id: "ipv6:advertisedButBroken",
                               title: String(localized: "IPv6 isn’t connecting on this network", comment: "Health finding title: this Mac has an IPv6 address and route but connections over IPv6 fail"),
                               detail: measured + " " + advice, help: measured, level: .caution)
        case .ipv6Only:
            let detail = String(localized: "This network gave this Mac no IPv4 route, and a connection to Cloudflare or Google over IPv6 went through. Kilobat’s ping checks use IPv4, so latency isn’t measured here.",
                                comment: "Health finding detail: an IPv6-only network; the ping checks can’t measure latency")
            return IPv6Finding(id: "ipv6:ipv6Only",
                               title: String(localized: "No IPv4 on this network", comment: "Health finding title: the network gave this Mac no IPv4 route"),
                               detail: detail, help: detail, level: .fine)
        case .working, .none, .unknown:
            return nil
        }
    }

    /// Shown on a speed test taken with no IPv4 route, where the latency rows are empty.
    public static var latencyNote: String {
        String(localized: "Latency wasn’t measured: this network has no IPv4 route and the latency check pings an IPv4 address.",
               comment: "Speed test result note: the latency rows are empty because the network has no IPv4 route")
    }
}

/// `kilobat diagnose --json` and `diagnose_network`: the verdict and the six facts behind it, never an address.
public struct IPv6Summary: Codable, Sendable, Equatable {
    public var verdict: IPv6Verdict
    public var confirmed: Bool
    public var globalAddress: Bool
    public var defaultRoute: Bool?
    public var ipv4Route: Bool
    public var tunneled: Bool
    public var reachable: Bool?
    public var ipv4Reachable: Bool?

    public init(_ reading: IPv6Reading, confirmed: Bool) {
        verdict = IPv6Check.verdict(reading); self.confirmed = confirmed
        globalAddress = reading.globalAddress; defaultRoute = reading.defaultRoute; ipv4Route = reading.ipv4Route
        tunneled = reading.tunneled; reachable = reading.reachable; ipv4Reachable = reading.ipv4Reachable
    }
}
