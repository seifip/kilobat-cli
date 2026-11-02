import Foundation

/// Shared router-guide links for readiness checks and firmware reminders. Manufacturer names alone
/// cannot distinguish TP-Link Archer from Deco or NETGEAR Nighthawk from Orbi, so those get no link.
public enum RouterGuides {
    static let makers: [(match: String, slug: String)] = [
        ("avm", "fritzbox"), ("fritz", "fritzbox"), ("asustek", "asus"), ("asus", "asus"),
        ("eero", "eero"), ("ubiquiti", "ubiquiti-unifi"), ("unifi", "ubiquiti-unifi"),
        ("routerboard", "mikrotik"), ("mikrotik", "mikrotik"), ("synology", "synology-router"),
        ("gl technologies", "glinet"), ("linksys", "linksys"), ("draytek", "draytek-vigor"),
        ("keenetic", "keenetic"), ("tenda", "tenda"), ("cudy", "cudy"), ("firewalla", "firewalla"),
        ("mercusys", "mercusys"), ("buffalo", "buffalo-airstation"), ("plume design", "plume-homepass"),
        ("space exploration", "starlink-router"), ("starlink", "starlink-router"), ("xiaomi", "xiaomi"),
        ("google", "google-nest-wifi"), ("apple", "apple-airport"), ("huawei", "huawei"), ("nec platforms", "nec-aterm"),
    ]

    public static func slug(vendor: String?) -> String? {
        guard let vendor = vendor?.lowercased() else { return nil }
        return makers.first { vendor.contains($0.match) }?.slug
    }

    public static func slug(maker: String) -> String? { slug(vendor: maker) }
    public static func url(vendor: String?) -> String? { slug(vendor: vendor).map { "https://kilobat.app/routers/\($0)" } }
    public static func firmware(maker: String) -> String? { url(vendor: maker).map { $0 + "#firmware" } }
}
