import Foundation

/// Which router this is, from its maker and what it answers on its usual ports. Each probe is a plain GET to the
/// router's own address on the local network, carrying no credentials, so a self-signed certificate is accepted here.
public enum RouterDetect {
    public struct Found: Equatable, Sendable {
        public var kind: RouterKind
        /// Where to connect: the scheme, the router's address and the port that answered.
        public var url: String
        /// The name a UPnP router gives; the others report theirs once connected.
        public var model: String?
        public init(kind: RouterKind, url: String, model: String? = nil) { self.kind = kind; self.url = url; self.model = model }
    }

    /// The maker registered for the router's MAC address, as a first guess.
    public static func guess(vendor: String?) -> RouterKind? {
        guard let vendor = vendor?.lowercased() else { return nil }
        if vendor.contains("avm") || vendor.contains("fritz") { return .fritzbox }
        if vendor.contains("ubiquiti") { return .unifi }
        if vendor.contains("mikrotik") || vendor.contains("routerboard") { return .mikrotik }
        return nil
    }

    /// Whether the page a probe fetched is that kind of router's own. A marker counts only as a whole word or phrase:
    /// "unified" is not UniFi and "Lucida" is not LuCI. A path the request itself named is never a marker, since an
    /// error page echoes it.
    public static func recognise(_ body: String, as kind: RouterKind, port: Int?) -> Bool {
        let text = body.lowercased()
        func has(_ phrase: String) -> Bool {
            text.range(of: "(?<![a-z0-9])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![a-z0-9])", options: .regularExpression) != nil
        }
        switch kind {
        case .fritzbox: return port == 49000 && text.contains("urn:dslforum-org:device") && (has("avm") || has("fritz") || text.contains("fritz!box"))
        case .unifi:
            // The product writes "UniFi" (or all lower or upper case in ids and paths); an ISP's "Unifi" brand is not it.
            return body.range(of: "(?<![A-Za-z0-9])(UniFi|unifi|UNIFI)(?![A-Za-z0-9])", options: .regularExpression) != nil || has("ubiquiti")
        case .mikrotik: return has("routeros") || has("mikrotik") || has("webfig")
        case .openwrt:
            // The probe's own path (/cgi-bin/luci) is cut out first: an error page echoes it.
            let own = text.replacingOccurrences(of: "cgi-bin/luci", with: " ")
            return text.contains("/luci-static/") || own.range(of: "(?<![a-z0-9])(openwrt|luci)(?![a-z0-9])", options: .regularExpression) != nil
        case .upnp: return false
        }
    }

    public static func detect(gateway: String, vendor: String?, transport: RouterTransport = RouterSession(pin: nil, trustAny: true),
                              upnp: @Sendable (String) async -> RouterCounters.Device? = { await RouterCounters.device(gateway: $0) }) async -> Found? {
        guard RouterAddress.isLocal(gateway) else { return nil }
        var probes: [(RouterKind, String)] = [(.fritzbox, "http://\(gateway):49000/tr64desc.xml"), (.unifi, "https://\(gateway)/"),
                                              (.mikrotik, "http://\(gateway)/"), (.openwrt, "http://\(gateway)/cgi-bin/luci/")]
        if let first = guess(vendor: vendor), let index = probes.firstIndex(where: { $0.0 == first }) { probes.insert(probes.remove(at: index), at: 0) }
        var pages: Set<String> = []
        for (kind, address) in probes where pages.insert(address).inserted {
            guard let url = URL(string: address) else { continue }
            var request = RouterHTTP.request(url); request.timeoutInterval = 3
            guard let (data, _) = try? await transport.send(request), data.count < 2_000_000 else { continue }
            if recognise(String(decoding: data, as: UTF8.self), as: kind, port: url.port) {
                return Found(kind: kind, url: kind.defaultURL(gateway: gateway))
            }
        }
        if let device = await upnp(gateway) { return Found(kind: .upnp, url: device.control, model: device.model) }
        return nil
    }
}
