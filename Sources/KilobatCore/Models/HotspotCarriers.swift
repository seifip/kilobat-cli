import Foundation

/// A mobile carrier whose published hotspot rules have a page on kilobat.app/hotspot-limits. Matched by the public
/// address's network (its origin ASN and registered holder, from `ProviderLookup`) or picked by the person.
public struct HotspotCarrier: Codable, Sendable, Equatable, Identifiable {
    /// The page's slug: kilobat.app/hotspot-limits/<id>.
    public let id: String
    public let name: String
    /// ISO country.
    public let country: String
    /// Origin ASNs of its mobile network. Several carriers also run fixed lines from the same ASN; the match is only
    /// made on a phone hotspot, where it's the mobile side.
    public let asns: [Int]
    /// Lowercased pieces of the registered holder's name, for an ASN not in the list.
    public let orgs: [String]
    /// Brands that sell plans on this network, whose addresses look the same: the person picks one of them.
    public var sharedWith: [String] = []
    public init(id: String, name: String, country: String, asns: [Int], orgs: [String], sharedWith: [String] = []) {
        self.id = id; self.name = name; self.country = country; self.asns = asns; self.orgs = orgs; self.sharedWith = sharedWith
    }
    public var page: URL { URL(string: "https://kilobat.app/hotspot-limits/\(id)")! }
}

/// The carriers with a hotspot-limits page. Keep the ids in step with site/src/content/hotspot-limits.
public enum HotspotCarriers {
    public static let hub = URL(string: "https://kilobat.app/hotspot-limits")!

    public static let all: [HotspotCarrier] = [
        HotspotCarrier(id: "t-mobile", name: "T-Mobile", country: "US", asns: [21928], orgs: ["t-mobile usa", "t-mobile-as21928"], sharedWith: ["mint-mobile"]),
        HotspotCarrier(id: "verizon", name: "Verizon", country: "US", asns: [22394, 6167], orgs: ["cellco", "verizon wireless"], sharedWith: ["visible"]),
        HotspotCarrier(id: "att", name: "AT&T", country: "US", asns: [20057], orgs: ["at&t mobility", "att-mobility"]),
        // MVNOs: their subscribers' addresses belong to the host network, so they're only ever picked.
        HotspotCarrier(id: "visible", name: "Visible", country: "US", asns: [], orgs: []),
        HotspotCarrier(id: "mint-mobile", name: "Mint Mobile", country: "US", asns: [], orgs: []),
        HotspotCarrier(id: "ee", name: "EE", country: "GB", asns: [12576], orgs: ["ee-as", "orange personal communications", "everything everywhere"]),
        HotspotCarrier(id: "vodafone-uk", name: "Vodafone UK", country: "GB", asns: [25135], orgs: ["vodafone limited", "vodafone_uk", "vodafone uk"]),
        HotspotCarrier(id: "o2-uk", name: "O2", country: "GB", asns: [35228], orgs: ["telefonica uk", "telefónica uk", "o2 (uk)", "virgin media o2"]),
        HotspotCarrier(id: "three-uk", name: "Three", country: "GB", asns: [206067], orgs: ["hutchison 3g uk", "h3guk", "three uk"]),
        HotspotCarrier(id: "telekom", name: "Telekom", country: "DE", asns: [3320], orgs: ["deutsche telekom"]),
        HotspotCarrier(id: "vodafone-de", name: "Vodafone Germany", country: "DE", asns: [3209], orgs: ["vodafone gmbh", "vodafone deutschland", "vodanet"]),
        HotspotCarrier(id: "orange", name: "Orange", country: "FR", asns: [3215], orgs: ["orange s.a.", "france telecom"]),
        HotspotCarrier(id: "free-mobile", name: "Free Mobile", country: "FR", asns: [51207], orgs: ["free mobile"]),
        HotspotCarrier(id: "telstra", name: "Telstra", country: "AU", asns: [1221], orgs: ["telstra"]),
        HotspotCarrier(id: "rogers", name: "Rogers", country: "CA", asns: [812], orgs: ["rogers communications"]),
        HotspotCarrier(id: "docomo", name: "NTT docomo", country: "JP", asns: [9605], orgs: ["ntt docomo", "docomo"]),
    ]

    public static func carrier(_ id: String) -> HotspotCarrier? { all.first { $0.id == id } }

    /// "t-mobile", "T-Mobile" or "tmobile": the carrier, for `--carrier`.
    public static func find(_ text: String) -> HotspotCarrier? {
        func squeeze(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
        let query = squeeze(text)
        guard !query.isEmpty else { return nil }
        return all.first { squeeze($0.id) == query || squeeze($0.name) == query }
    }

    /// The carrier a public address's network belongs to: its ASN first, then its holder's name within the country.
    public static func match(asn: Int?, organization: String?, country: String?) -> HotspotCarrier? {
        if let asn, let carrier = all.first(where: { $0.asns.contains(asn) }) { return carrier }
        guard let organization = organization?.lowercased(), !organization.isEmpty else { return nil }
        let code = country?.uppercased()
        return all.first { carrier in
            !carrier.orgs.isEmpty && carrier.orgs.contains { organization.contains($0) } && (code == nil || carrier.country == code)
        }
    }

    /// Carriers to pick from, the country's first.
    public static func choices(country: String?) -> [HotspotCarrier] {
        let code = country?.uppercased()
        return all.filter { $0.country == code } + all.filter { $0.country != code }
    }
}
