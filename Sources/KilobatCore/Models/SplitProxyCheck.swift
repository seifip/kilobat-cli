import Foundation

/// Whether a proxy on the network answers connections for websites, as many plane and satellite links do. Such a proxy
/// completes the TCP handshake itself, nearby, so TCP connects at once while the first encrypted exchange, which has
/// to reach the real server, takes the link's full delay. This reports what was measured; it can't see the proxy.
public struct SplitProxyCheck: Codable, Sendable, Equatable {
    public enum Failure: String, Codable, Sendable { case reset, timeout, other }

    /// One secure connection: how long TCP and then TLS took, or how it failed.
    public struct Host: Codable, Sendable, Equatable {
        public let name: String
        public var tcpMs: Int?
        public var tlsMs: Int?
        public var failure: Failure?
        public init(name: String, tcpMs: Int? = nil, tlsMs: Int? = nil, failure: Failure? = nil) {
            self.name = name; self.tcpMs = tcpMs; self.tlsMs = tlsMs; self.failure = failure
        }
        var completed: Bool { failure == nil && tcpMs != nil && tlsMs != nil }
        /// TCP answered from close by, then the encrypted exchange took the long way.
        var looksProxied: Bool {
            guard failure == nil, let tcpMs, let tlsMs else { return false }
            return tcpMs <= SplitProxyCheck.fastConnect && tlsMs >= SplitProxyCheck.slowHandshake && tlsMs >= max(tcpMs, 1) * SplitProxyCheck.ratio
        }
    }

    public enum Verdict: String, Codable, Sendable { case noProxy, proxyLikely, parallelFailures, notEnoughData, behindVPN, signInFirst }

    /// TCP this quick came from close by. Generous, because a full cabin's Wi-Fi delays even a nearby proxy's reply.
    public static let fastConnect = 100
    /// Below this the link isn't slow enough for the gap to matter, as with an office's proxy.
    public static let slowHandshake = 300
    public static let ratio = 5
    /// Connections that have to fail, resets and timeouts together, before it's more than one bad host.
    public static let failures = 2
    /// A ping this slow, or none while DNS works, is the kind of link where the check is worth offering.
    public static let slowPing = 250.0
    /// A reading stops describing the network after this long.
    public static let freshFor: TimeInterval = 1800
    /// The check costs about this much: certificates, mostly, for six connections.
    public static let approximateKB = 30

    public var date: Date
    /// The network it was measured on, so another network never shows this one's result.
    public var network: String?
    public var hosts: [Host]
    public var verdict: Verdict

    public init(date: Date = Date(), network: String?, hosts: [Host], vpn: Bool = false, portal: Bool = false) {
        self.date = date; self.network = network; self.hosts = hosts
        verdict = vpn ? .behindVPN : portal ? .signInFirst : Self.verdict(hosts)
    }

    public static func verdict(_ hosts: [Host]) -> Verdict {
        let completed = hosts.filter(\.completed), proxied = completed.filter(\.looksProxied).count
        let failed = hosts.filter { $0.failure == .reset || $0.failure == .timeout }.count
        if proxied >= 3 && proxied * 2 > completed.count { return .proxyLikely }
        // Nothing got through: that's a blocked or dead link, not connections failing side by side.
        if failed >= failures && completed.count >= 2 { return .parallelFailures }
        return completed.count >= 3 ? .noProxy : .notEnoughData
    }

    /// Whether to offer the check: a link slow enough, or ping blocked while names still resolve, and nothing in the way.
    public static func worthOffering(pingMs: Double?, dnsWorks: Bool, vpn: Bool, portal: Bool) -> Bool {
        guard !vpn, !portal else { return false }
        if let pingMs { return pingMs >= slowPing }
        return dnsWorks
    }

    public func isCurrent(network: String?, now: Date = Date()) -> Bool { self.network == network && now.timeIntervalSince(date) < Self.freshFor }

    var completed: [Host] { hosts.filter(\.completed) }
    var failed: Int { hosts.filter { $0.failure == .reset || $0.failure == .timeout }.count }
    static func median(_ values: [Int]) -> Int? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted.count.isMultiple(of: 2) ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2]
    }
    public var tcpMedian: Int? { Self.median(completed.compactMap(\.tcpMs)) }
    public var tlsMedian: Int? { Self.median(completed.compactMap(\.tlsMs)) }

    /// The worse readings, which a Health finding marks as something to look at.
    public var isConcern: Bool { verdict == .proxyLikely || verdict == .parallelFailures }

    public var title: String {
        switch verdict {
        case .proxyLikely: String(localized: "This network’s proxy seems to be slowing connections, not your Mac", comment: "Health finding: plane or satellite Wi-Fi's split-TCP proxy")
        case .parallelFailures: String(localized: "Connections opened together are failing", comment: "Health finding: several parallel connections were reset or timed out")
        case .noProxy: String(localized: "No sign of a proxy slowing connections", comment: "Health finding: the network proxy check found nothing")
        case .notEnoughData: String(localized: "Too few connections finished to tell", comment: "Health finding: the network proxy check couldn't conclude")
        case .behindVPN: String(localized: "A VPN hides this network’s proxy from the check", comment: "Health finding: the network proxy check wasn't run")
        case .signInFirst: String(localized: "Sign in to this Wi-Fi first", comment: "Health finding: the network proxy check wasn't run on a sign-in page")
        }
    }

    public var detail: String {
        let total = hosts.count, done = completed.count, tcp = tcpMedian ?? 0, tls = tlsMedian ?? 0
        switch verdict {
        case .proxyLikely:
            let seen = String(localized: "\(completed.filter(\.looksProxied).count) of \(total) secure connections got a TCP reply in about \(tcp) ms, then took about \(tls) ms to finish encrypting. A gap that wide usually means something on the network answers for websites, as plane and satellite Wi-Fi often do.", comment: "Health finding: connections measured, total, TCP ms, TLS ms")
            guard failed > 0 else { return seen }
            return seen + " " + String(localized: "\(failed) of \(total) failed.", comment: "Health finding: parallel connections that were reset or timed out")
        case .parallelFailures:
            return String(localized: "\(failed) of \(total) secure connections opened at the same time were reset or timed out, while \(done) worked.", comment: "Health finding: failed, total, worked")
        case .noProxy:
            return String(localized: "\(done) of \(total) secure connections: TCP about \(tcp) ms, then about \(tls) ms to finish encrypting.", comment: "Health finding: worked, total, TCP ms, TLS ms")
        case .notEnoughData:
            return String(localized: "\(done) of \(total) secure connections finished.", comment: "Health finding: worked, total")
        case .behindVPN:
            return String(localized: "Your traffic goes through the VPN’s tunnel. Turn the VPN off and check again to measure this network.", comment: "Health finding")
        case .signInFirst:
            return String(localized: "Until then the sign-in page answers instead of the internet.", comment: "Health finding")
        }
    }

    /// The tooltip: what follows from it, and only that.
    public var advice: String {
        switch verdict {
        case .proxyLikely: String(localized: "Nothing on this Mac needs changing for this. It’s measured from six well-known sites and can’t see the proxy itself.", comment: "Health finding tooltip")
        case .parallelFailures: String(localized: "Opening one page at a time may help. It’s measured from six well-known sites and doesn’t say why they failed.", comment: "Health finding tooltip")
        default: String(localized: "Six small secure connections to well-known sites, about \(Self.approximateKB) KB in all. It only runs when you ask.", comment: "Health finding tooltip")
        }
    }
}
