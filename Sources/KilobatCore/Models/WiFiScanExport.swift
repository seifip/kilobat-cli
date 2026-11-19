import Foundation

/// A scan as CSV, one row per access point, every field Kilobat read: for a spreadsheet, an IT desk or a site survey.
public enum WiFiScanExport {
    public static let header = ["scanned", "ssid", "bssid", "vendor", "rssi_dbm", "noise_dbm", "snr_db", "band", "channel", "width_mhz", "center_channel", "dfs",
                                "generation", "standard", "streams", "max_rate_mbps", "security", "key_management", "pairwise_ciphers", "group_cipher", "pmf",
                                "transition_mode", "802.11k", "802.11v", "802.11r", "mobility_domain", "country", "beacon_interval_tu", "dtim_period",
                                "stations", "channel_utilization_percent", "multi_link", "mld_address", "other_links", "ap_name", "chip_vendors",
                                "basic_rates_mbps", "supported_rates_mbps", "wps", "passpoint", "note"]

    /// `note` is the saved scan's note, repeated on each row so a filtered sheet keeps it.
    public static func csv(_ networks: [NearbyNetwork], date: Date, note: String? = nil) -> String {
        line(header) + rows(networks, date: date, note: note).map(line).joined()
    }

    /// Several saved scans in one file, oldest first.
    public static func csv(_ scans: [SavedScan]) -> String {
        line(header) + scans.sorted { $0.date < $1.date }.flatMap { rows($0.networks, date: $0.date, note: $0.note) }.map(line).joined()
    }

    static func rows(_ networks: [NearbyNetwork], date: Date, note: String?) -> [[String]] {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        format.timeZone = .current
        let when = format.string(from: date)
        return networks.map { network in
            let d = network.details, s = d?.security
            func flag(_ value: Bool?) -> String { value.map { $0 ? "yes" : "no" } ?? "" }
            func number(_ value: Double?) -> String { value.map { $0.formatted(.number.precision(.fractionLength(0...1)).grouping(.never).locale(Locale(identifier: "en_US_POSIX"))) } ?? "" }
            let known = d != nil
            return [when, text(network.ssid), network.id.hasPrefix("hidden-") ? "" : network.id, text(d?.vendor ?? ""), String(network.rssi),
                    network.noise == 0 ? "" : String(network.noise), network.noise == 0 ? "" : String(network.rssi - network.noise),
                    network.band, network.channel > 0 ? String(network.channel) : "", String(network.widthMHz), d?.centerChannel.map(String.init) ?? "",
                    flag(ChannelPlan.touchesDFS(network.span, band: network.band)),
                    d?.generation?.name ?? "", d?.generation?.standard ?? "", d?.streams.map(String.init) ?? "", number(d?.maxRateMbps),
                    s?.summary ?? network.security ?? "", s?.keyManagement.joined(separator: " ") ?? "", s?.pairwiseCiphers.joined(separator: " ") ?? "",
                    s?.groupCipher ?? "", s?.pmf.rawValue ?? "", s.map { flag($0.transition || $0.oweTransition) } ?? "",
                    known ? flag(d?.radioMeasurement) : "", known ? flag(d?.bssTransition) : "", known ? flag(d?.fastRoaming) : "", d?.mobilityDomain ?? "",
                    d?.country ?? "", d?.beaconInterval.map(String.init) ?? "", d?.dtimPeriod.map(String.init) ?? "",
                    d?.stations.map(String.init) ?? "", d?.channelUtilization.map { String(Int(($0 * 100).rounded())) } ?? "",
                    known ? flag(d?.multiLink != nil) : "", d?.multiLink?.mldAddress ?? "",
                    d?.multiLink?.links.map { "\($0.band) ch \($0.channel)" }.joined(separator: " ") ?? "", text(d?.apName ?? ""),
                    d?.vendorElements.joined(separator: " ") ?? "",
                    d?.basicRates.map { number($0) }.joined(separator: " ") ?? "", d?.rates.map { number($0) }.joined(separator: " ") ?? "",
                    known ? flag(d?.wps) : "", known ? flag(d?.passpoint) : "", text(note ?? "")]
        }
    }

    static func line(_ fields: [String]) -> String { fields.map(RoamSummary.field).joined(separator: ",") + "\n" }

    /// A name anyone nearby can choose (an SSID, an AP's own name, a note) is kept from running as a spreadsheet formula.
    static func text(_ value: String) -> String {
        guard let first = value.first, "=+-@\t\r".contains(first) else { return value }
        return "'" + value
    }
}
