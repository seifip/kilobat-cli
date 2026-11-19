import Foundation

/// One finding of the band-steering and sticky-client report.
public struct SteeringFinding: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// On 2.4 GHz while the same access point's 5 or 6 GHz radio is clearly better.
        case bandSteering
        /// Holding on to a weak access point while another of the same network is much stronger.
        case stickyClient
        /// Most of the last day on 2.4 GHz on a network that also has 5 GHz.
        case mostlyLowBand
        /// Nothing to report.
        case fine
    }
    public enum Level: String, Codable, Sendable { case caution, fine }
    public let kind: Kind
    public let level: Level
    public let title: String
    public let detail: String
    /// What the person can do about it; nil when nothing is needed.
    public let advice: String?
    /// The radio this Mac could be on instead.
    public let better: String?
    public var id: String { kind.rawValue }
}

/// Band steering and sticky clients, from what one Mac can see: its own link, the latest scan of nearby radios and the
/// roam history. A Mac hears how loud each access point is, not where it is, how busy it is or what the router's
/// steering is set to, and macOS makes the final choice; the findings say "could", not "would".
public enum SteeringReport {
    /// Weaker than this, a Mac is at the edge of a good link; macOS itself starts looking for another access point at −75 dBm.
    public static let weak = -70
    /// Another access point must be this much louder to count as clearly better: Apple's own roaming margin.
    public static let margin = 12
    /// A 5 or 6 GHz radio weaker than this isn't offered as better, whatever its width.
    public static let usable = -72
    public static let note = String(localized: "Kilobat sees how strong each access point sounds here, not where it is or how busy it is, and macOS makes the final choice.",
                                    comment: "Band steering report: the uncertainty note")

    public static func evaluate(radio: RadioSample, networks: [NearbyNetwork], supportedBands: Set<String>? = nil, roams: RoamSummary? = nil) -> [SteeringFinding] {
        guard let ssid = radio.ssid, let rssi = radio.rssi, let band = radio.band, let channel = radio.channel else { return [] }
        let width = radio.widthMHz ?? 20
        let bssid = radio.bssid.flatMap(MeshNodes.normalize)
        let current = NodeRadio(bssid: bssid ?? "00:00:00:00:00:00", rssi: rssi, channel: channel, band: band, widthMHz: width)
        let rate = max(current.estimatedMbps, radio.transmitMbps ?? 0)
        let peers = networks.filter { $0.ssid == ssid && $0.rssi < 0 && (bssid == nil || MeshNodes.normalize($0.id) != bssid) && !($0.band == band && $0.channel == channel && bssid == nil) }
            .map { (network: $0, radio: NodeRadio(bssid: $0.id, rssi: $0.rssi, channel: $0.channel, band: $0.band, widthMHz: $0.widthMHz)) }
        let supported = supportedBands ?? ["2.4 GHz", "5 GHz"]
        func sameBox(_ other: NodeRadio) -> Bool? { bssid == nil ? nil : MeshNodes.sameNode(current, other) }
        let joinedDetails = networks.first { MeshNodes.normalize($0.id) == bssid }?.details
        var findings: [SteeringFinding] = []

        // Band steering: a faster band from the same box (or, without BSSIDs, from the same network).
        if band == "2.4 GHz" {
            let faster = peers.filter { $0.radio.band != "2.4 GHz" && supported.contains($0.radio.band) && $0.radio.rssi >= usable
                && sameBox($0.radio) != false && $0.radio.estimatedMbps >= rate * MeshNodes.gain }
            if let best = faster.max(by: { $0.radio.estimatedMbps < $1.radio.estimatedMbps }) {
                // The rate estimate compares two radios; it isn't precise enough to quote as a multiple. Whole sentences, so
                // each language can phrase "how much more" its own way.
                let much = best.radio.estimatedMbps / max(rate, 1) >= 3
                let detail: String = switch (sameBox(best.radio) == true, much) {
                case (true, true):
                    String(localized: "This Mac is on 2.4 GHz at \(rssi) dBm. The same access point’s \(best.radio.band) radio reaches it at \(best.radio.rssi) dBm and could carry several times as much.",
                           comment: "Band steering report; signal, band, signal")
                case (true, false):
                    String(localized: "This Mac is on 2.4 GHz at \(rssi) dBm. The same access point’s \(best.radio.band) radio reaches it at \(best.radio.rssi) dBm and could carry clearly more.",
                           comment: "Band steering report; signal, band, signal")
                case (false, true):
                    String(localized: "This Mac is on 2.4 GHz at \(rssi) dBm. This network’s \(best.radio.band) radio reaches it at \(best.radio.rssi) dBm and could carry several times as much.",
                           comment: "Band steering report without access point addresses; signal, band, signal")
                case (false, false):
                    String(localized: "This Mac is on 2.4 GHz at \(rssi) dBm. This network’s \(best.radio.band) radio reaches it at \(best.radio.rssi) dBm and could carry clearly more.",
                           comment: "Band steering report without access point addresses; signal, band, signal")
                }
                findings.append(SteeringFinding(kind: .bandSteering, level: .caution,
                                                title: String(localized: "On 2.4 GHz while \(best.radio.band) is strong here", comment: "Band steering report title; the argument is a band"),
                                                detail: detail,
                                                advice: String(localized: "Turn on band steering (some routers call it Smart Connect) in the router, or turn Wi-Fi off and on so macOS picks again.",
                                                               comment: "Band steering report advice"),
                                                better: best.network.id))
            }
        }

        // Sticky client: a weak link while another box of the same network is much louder and faster.
        if rssi <= weak {
            let louder = peers.filter { sameBox($0.radio) != true && supported.contains($0.radio.band) && $0.radio.rssi >= rssi + margin && $0.radio.estimatedMbps >= rate * MeshNodes.gain }
            if let best = louder.max(by: { $0.radio.rssi < $1.radio.rssi }) {
                var detail = String(localized: "This Mac is at \(rssi) dBm while another access point of this network is at \(best.radio.rssi) dBm (\(best.radio.band), channel \(best.radio.channel)). macOS usually moves only once the signal falls to about −75 dBm and another is 12 dB stronger.",
                                    comment: "Sticky client report; signal, signal, band and channel")
                if let ignored = roams?.ignored, !ignored.isEmpty {
                    detail += " " + (ignored.count == 1
                        ? String(localized: "It happened once more in the last day.", comment: "Sticky client report: roam history")
                        : String(localized: "It happened \(ignored.count) more times in the last day.", comment: "Sticky client report: roam history; a count"))
                }
                var advice = String(localized: "Turn Wi-Fi off and on to make macOS choose again. If it keeps happening, a minimum-signal setting on the router can push clients off a far access point.",
                                    comment: "Sticky client report advice")
                if let joinedDetails, !joinedDetails.radioMeasurement && !joinedDetails.bssTransition {
                    advice += " " + String(localized: "This access point doesn’t advertise 802.11k or 802.11v, which help a Mac find a better one; turning them on in the router may help.",
                                           comment: "Sticky client report advice")
                }
                findings.append(SteeringFinding(kind: .stickyClient, level: .caution,
                                                title: String(localized: "Holding on to a weak access point", comment: "Sticky client report title"),
                                                detail: detail, advice: advice, better: best.network.id))
            }
        }

        // The last day: mostly on 2.4 GHz although this network also has a 5 GHz radio.
        if let roams, !findings.contains(where: { $0.kind == .bandSteering }), peers.contains(where: { $0.radio.band != "2.4 GHz" && supported.contains($0.radio.band) }) {
            let total = roams.visits.reduce(0.0) { $0 + $1.dwell }
            let low = roams.visits.filter { $0.band == "2.4 GHz" }.reduce(0.0) { $0 + $1.dwell }
            if total >= 1800, low / total >= 0.5 {
                let share = Int((low / total * 100).rounded())
                findings.append(SteeringFinding(kind: .mostlyLowBand, level: .caution,
                                                title: String(localized: "Mostly on 2.4 GHz today", comment: "Band steering report title"),
                                                detail: String(localized: "This Mac spent \(share)% of the last day on 2.4 GHz, though this network also has a faster band. 2.4 GHz reaches further but carries less and is shared with Bluetooth and neighbours.",
                                                               comment: "Band steering report; a percentage"),
                                                advice: String(localized: "If the 5 GHz signal is good where you sit, band steering in the router, or a separate 5 GHz network name, keeps the Mac on it.",
                                                               comment: "Band steering report advice"),
                                                better: nil))
            }
        }

        if findings.isEmpty {
            let radios = peers.count + 1
            findings.append(SteeringFinding(kind: .fine, level: .fine,
                                            title: String(localized: "No band-steering or sticky-client problem seen", comment: "Band steering report title"),
                                            detail: radios == 1
                                                ? String(localized: "This scan heard one radio of \(ssid), the one this Mac is on.", comment: "Band steering report; a network name")
                                                : String(localized: "This scan heard \(radios) radios of \(ssid); none is clearly better than the one this Mac is on.", comment: "Band steering report; a count and a network name"),
                                            advice: nil, better: nil))
        }
        return findings
    }
}
