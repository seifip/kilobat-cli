import Foundation

/// What the Wi-Fi icon should say beyond signal strength, as macOS's own Wi-Fi icon does: still joining, or joined
/// without a working internet. Nil when the connection is fine, or there's nothing fresh enough to judge.
public enum WiFiAttention: Equatable, Sendable {
    /// Joining, or joined a moment ago and still waiting for the router's address and the first check.
    case connecting
    /// A sign-in page is in the way, or it logged the Mac out.
    case signIn
    /// Joined, but the router never gave the Mac an address.
    case noAddress
    /// Joined with an address, and every internet probe failed.
    case noInternet

    /// How long after joining the icon keeps cycling while the router's address and the first check come in.
    public static let joinWindow: TimeInterval = 30

    /// `joining`: Kilobat's own Join is running. `associatedAt`: when the radio last joined a network. A check counts
    /// only when it was taken on the network the radio is on now, after it joined, in the last three minutes.
    public static func judge(radio: RadioSample?, snapshot: DiagnosticSnapshot?, portalInTheWay: Bool, joining: Bool,
                             associatedAt: Date?, now: Date = Date()) -> WiFiAttention? {
        guard let radio, radio.ssid != nil || radio.rssi != nil else { return nil }
        if joining { return .connecting }
        let fresh = snapshot.flatMap { sample -> DiagnosticSnapshot? in
            guard sample.wiredInterface == nil, radio.ssid == nil || sample.radio.ssid == radio.ssid,
                  sample.date >= (associatedAt ?? .distantPast), now.timeIntervalSince(sample.date) < 180 else { return nil }
            return sample
        }
        if portalInTheWay, fresh != nil { return .signIn }
        if let associatedAt, now.timeIntervalSince(associatedAt) < joinWindow, fresh?.gateway == nil { return .connecting }
        guard let fresh, fresh.setupNetwork == nil else { return nil }
        if fresh.gateway == nil { return .noAddress }
        return fresh.reachability == .down ? .noInternet : nil
    }
}
