import Foundation

/// Which router this is, from its maker and what it answers on its usual ports. Each probe is a plain GET to the
/// router's own address on the local network, carrying no credentials, so a self-signed certificate is accepted here.
public enum RouterDetect {
    public struct Found: Equatable, Sendable {
        public var kind: RouterKind
        /// Where to connect: the scheme, the router's address and the port that answered.
        public var url: String
        public init(kind: RouterKind, url: String) { self.kind = kind; self.url = url }
    }

    /// The maker registered for the router's MAC address, as a first guess.
    public static func guess(vendor: String?) -> RouterKind? {
        guard let vendor = vendor?.lowercased() else { return nil }
        if vendor.contains("avm") || vendor.contains("fritz") { return .fritzbox }
        if vendor.contains("ubiquiti") { return .unifi }
        if vendor.contains("mikrotik") || vendor.contains("routerboard") { return .mikrotik }
        return nil
    }

    /// What a page says about the router behind it.
    public static func recognise(_ body: String, port: Int?) -> RouterKind? {
        let text = body.lowercased()
        if port == 49000, text.contains("urn:dslforum-org:device"), text.contains("avm") || text.contains("fritz") { return .fritzbox }
        if text.contains("unifi") { return .unifi }
        if text.contains("routeros") || text.contains("mikrotik") || text.contains("webfig") { return .mikrotik }
        if text.contains("luci") || text.contains("openwrt") { return .openwrt }
        return nil
    }

    /// Asks the router at `gateway` in turn, the maker's likely kind first. Nil when nothing answered like a router Kilobat reads.
    public static func detect(gateway: String, vendor: String?, transport: RouterTransport = RouterSession(pin: nil, trustAny: true)) async -> Found? {
        guard RouterAddress.isLocal(gateway) else { return nil }
        var probes: [(RouterKind, String)] = [(.fritzbox, "http://\(gateway):49000/tr64desc.xml"), (.unifi, "https://\(gateway)/"),
                                              (.mikrotik, "http://\(gateway)/"), (.openwrt, "http://\(gateway)/cgi-bin/luci/")]
        if let first = guess(vendor: vendor), let index = probes.firstIndex(where: { $0.0 == first }) { probes.insert(probes.remove(at: index), at: 0) }
        var pages: Set<String> = []
        for (_, address) in probes where pages.insert(address).inserted {
            guard let url = URL(string: address) else { continue }
            var request = RouterHTTP.request(url); request.timeoutInterval = 3
            guard let (data, _) = try? await transport.send(request), data.count < 2_000_000 else { continue }
            if let kind = recognise(String(decoding: data, as: UTF8.self), port: url.port) {
                return Found(kind: kind, url: kind.defaultURL(gateway: gateway))
            }
        }
        return nil
    }
}
