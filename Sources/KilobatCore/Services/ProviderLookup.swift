import Foundation

/// Which network a public address belongs to, from RIPE NCC's public RIPEstat API (stat.ripe.net, every region's
/// routing data, no key). Only asked when the person presses Detect: it sends RIPE NCC the public address, as any
/// website sees it. The address itself comes from `ExitPath.publicAddress()` (Cloudflare).
public struct ProviderLookup: Codable, Sendable, Equatable {
    public let address: String
    public let asn: Int?
    /// The network's registered holder, such as "COMCAST-7922 - Comcast Cable Communications, LLC".
    public let organization: String?
    /// The ISO country from Kilobat's bundled DB-IP data, looked up on this Mac.
    public let country: String?

    static func endpoint(_ path: String, _ resource: String) -> URL? {
        var parts = URLComponents(string: "https://stat.ripe.net/data/\(path)/data.json")
        parts?.queryItems = [URLQueryItem(name: "resource", value: resource), URLQueryItem(name: "sourceapp", value: "kilobat")]
        return parts?.url
    }

    /// The first origin ASN in a `network-info` reply: {"data": {"asns": ["7922"], "prefix": "…"}}.
    public static func asn(fromNetworkInfo data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let payload = object["data"] as? [String: Any],
              let asns = payload["asns"] as? [Any] else { return nil }
        return asns.lazy.compactMap { ($0 as? String).flatMap(Int.init) ?? ($0 as? Int) }.first
    }

    /// The holder in an `as-overview` reply: {"data": {"holder": "…"}}.
    public static func holder(fromOverview data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let payload = object["data"] as? [String: Any],
              let holder = payload["holder"] as? String, !holder.isEmpty else { return nil }
        return holder
    }

    public static func lookup(address: String, session: URLSession = .shared) async throws -> ProviderLookup {
        guard let info = endpoint("network-info", address) else { throw DiagnosticError(String(localized: "That isn’t a public address.")) }
        var request = URLRequest(url: info); request.timeoutInterval = 8
        let (data, _) = try await session.data(for: request)
        let asn = Self.asn(fromNetworkInfo: data)
        var organization: String?
        if let asn, let overview = endpoint("as-overview", "AS\(asn)") {
            var request = URLRequest(url: overview); request.timeoutInterval = 8
            organization = (try? await session.data(for: request)).flatMap { holder(fromOverview: $0.0) }
        }
        return ProviderLookup(address: address, asn: asn, organization: organization, country: GeoIP.shared.country(address)?.code)
    }

    /// The provider in Kilobat's table, if it knows this network.
    public func provider(in table: OutageCreditTable = .bundled) -> CreditProvider? { table.match(asn: asn, organization: organization, country: country) }
}
