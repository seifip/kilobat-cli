import Foundation

public enum ConnectionHealth: String, Codable, Sendable {
    case good, degraded, poor, unknown
    public var symbol: String {
        switch self { case .good: "face.smiling"; case .degraded: "face.dashed"; case .poor: "exclamationmark.triangle"; case .unknown: "questionmark.circle" }
    }
}
public struct RadioSample: Codable, Sendable {
    public var bssid: String? = nil
    public let ssid: String?
    public let interface: String?
    public let rssi: Int?
    public let noise: Int?
    public let transmitMbps: Double?
    public let channel: Int?
    public let band: String?
    public var snr: Int? { guard let rssi, let noise else { return nil }; return rssi - noise }
    public var score: Int? { rssi.map { min(100, max(0, ($0 + 90) * 2)) } }
    public var health: ConnectionHealth {
        guard let rssi else { return .unknown }
        if rssi < -75 || (snr ?? 30) < 15 { return .poor }
        if rssi < -65 || (snr ?? 30) < 25 { return .degraded }
        return .good
    }
}
public struct NearbyNetwork: Identifiable, Codable, Sendable {
    public let id: String
    public let ssid: String
    public let rssi: Int
    public let noise: Int
    public let channel: Int
    public let band: String
    public let widthMHz: Int
}
public struct PingResult: Codable, Sendable {
    public let host: String
    public let samples: [Double]
    public let lossPercent: Double?
    public var sampleOffsets: [Double]? = nil
    public var average: Double? { samples.isEmpty ? nil : samples.reduce(0, +) / Double(samples.count) }
    public var jitter: Double? {
        guard samples.count > 1 else { return nil }
        return zip(samples, samples.dropFirst()).map { abs($1 - $0) }.reduce(0, +) / Double(samples.count - 1)
    }
}
public struct DiagnosticSnapshot: Codable, Sendable {
    public let date: Date
    public let radio: RadioSample
    public let gateway: String?
    public let router: PingResult?
    public let internet: PingResult
    public let dnsMilliseconds: Double?
    public let dnsServers: [String]
    /// A sign-in page is in the way. The app fills it from its own checks (PortalWatch), not every sample.
    public var captivePortal: Bool?
    public let networkService: String?
    /// The Ethernet or USB interface traffic leaves through while Wi-Fi stays joined, such as a tethered phone.
    public var wiredInterface: String? = nil
    /// The sign-in page came back on a network that was signed in to: the Wi-Fi logged you out, the internet isn't down.
    public var portalLoggedOut: Bool? = nil
    public var health: ConnectionHealth {
        if captivePortal == true { return .poor }
        if radio.health == .poor || (internet.lossPercent ?? 0) >= 20 { return .poor }
        if radio.health == .degraded || (router?.average ?? 0) > 20 || (internet.average ?? 0) > 120 || (dnsMilliseconds ?? 0) > 150 || (internet.jitter ?? 0) > 30 { return .degraded }
        return internet.average == nil ? .unknown : .good
    }
    public var advice: [String] {
        // A sign-in page in the way explains everything else that fails, so it's the only finding.
        if captivePortal == true {
            return [portalLoggedOut == true ? "The Wi-Fi’s sign-in page logged you out. Sign in again; the internet isn’t down."
                                            : "This network may require a login. Open the login page before testing again."]
        }
        var tips: [String] = []
        if radio.health == .poor || radio.health == .degraded { tips.append("Wi-Fi signal is weak or noisy. Use Radar to find a stronger spot, or try a different channel.") }
        if (router?.average ?? 0) > 20 { tips.append("The local link to your router is slow. Move closer, reduce competing traffic, then retest before restarting the router.") }
        if (internet.average ?? 0) > 120 && (router?.average ?? 100) < 20 { tips.append("Your router responds quickly, but the internet path is slow. Compare another network or test again later; the upstream connection may be congested.") }
        if (dnsMilliseconds ?? 0) > 150 { tips.append("DNS lookups are slow. Compare Cloudflare or Google DNS, then restore Automatic if it does not help.") }
        if (internet.jitter ?? 0) > 30 { tips.append("Internet latency varies between replies. Run a loaded speed test to see whether competing transfers make it worse.") }
        if (internet.lossPercent ?? 0) >= 5 { tips.append("Some internet ping replies were lost. Compare router loss and repeat the test; filtering and congestion can both cause this.") }
        if internet.average == nil { tips.append("The internet ping target did not reply. Some networks block ICMP; this alone does not prove an outage.") }
        if tips.isEmpty { tips.append("No clear issue in this sample. Run a speed test to check capacity and latency under load.") }
        return tips
    }
}
public struct SpeedTestResult: Codable, Sendable {
    public let date: Date
    public let downloadMbps: Double
    public let uploadMbps: Double
    public let baseline: PingResult
    public let downloadLoaded: PingResult
    public let uploadLoaded: PingResult
    public let downloadSeconds: Double
    public let uploadSeconds: Double
    public let transferredBytes: Int
    /// Connections open at once: 1 for the default single-stream test, several for the parallel one. Nil on tests saved before it was recorded.
    public var streams: Int? = nil
    /// The test server: Cloudflare and the airport code of the data center that answered, such as "Cloudflare FRA".
    public var server: String? = nil
    /// The link, VPN and other traffic during the test, kept so two tests can be told apart.
    public var context: SpeedTestContext? = nil
    // Bandwidth tiers: Published conferencing and streaming bandwidth requirements.
    // Latency/loss checks are conservative Kilobat heuristics, not a call-quality guarantee.
    public var callCautionReasons: [String] {
        var reasons: [String] = []
        if let value = baseline.average, value > 300 { reasons.append(String(localized: "High latency (\(String(format: "%.0f", value)) ms)")) }
        if let value = baseline.jitter, value > 30 { reasons.append(String(localized: "Variable ping (\(String(format: "%.0f", value)) ms jitter)")) }
        if let value = baseline.lossPercent, value > 2 { reasons.append(String(localized: "Missing ping replies (\(String(format: "%.0f", value))%)")) }
        if let value = addedLatency, value > 100 { reasons.append(String(localized: "Delay under load (+\(String(format: "%.0f", value)) ms)")) }
        return reasons
    }
    private var callCaution: Bool { !callCautionReasons.isEmpty }
    private func callReadiness(_ tier: String) -> String {
        guard baseline.samples.count >= 3, baseline.lossPercent != nil else { return "\(tier) · latency unknown" }
        return callCaution ? "\(tier) · may stutter" : "\(tier) · likely suitable"
    }
    public var voiceReadiness: String {
        guard min(downloadMbps, uploadMbps) >= 0.1 else { return "Low bandwidth" }
        return callReadiness("Voice")
    }
    public var videoReadiness: String {
        if downloadMbps >= 3 && uploadMbps >= 3.8 { return callReadiness("1080p") }
        if downloadMbps >= 1.8 && uploadMbps >= 2.6 { return callReadiness("720p") }
        if downloadMbps >= 0.6 && uploadMbps >= 1 { return callReadiness("SD") }
        return "Low bandwidth"
    }
    public var streamingReadiness: String {
        let tier = downloadMbps >= 15 ? "4K" : downloadMbps >= 5 ? "1080p" : downloadMbps >= 3 ? "720p" : nil
        guard let tier else { return "Low bandwidth" }
        return (baseline.lossPercent ?? 0) > 2 ? "\(tier) · may buffer" : "\(tier) bandwidth"
    }
    public enum Readiness: Sendable { case good, fair, poor }
    /// Coding agents make many small round trips and upload context, so latency, jitter and loss matter more than speed.
    public var agentLevel: Readiness {
        let latency = baseline.average ?? 0, jitter = baseline.jitter ?? 0, loss = baseline.lossPercent ?? 0
        if loss > 2 || (addedLatency ?? 0) > 200 || uploadMbps < 0.5 { return .poor }
        return latency > 150 || jitter > 50 || uploadMbps < 2 ? .fair : .good
    }
    public var agentReadiness: String {
        switch agentLevel {
        case .poor: String(localized: "May stall", comment: "How a coding agent may run on this connection")
        case .fair: String(localized: "Sluggish", comment: "How a coding agent may run on this connection")
        case .good: String(localized: "Smooth", comment: "How a coding agent may run on this connection")
        }
    }
    /// Online games send little data but need every packet on time: latency, jitter, loss and the delay a busy line adds.
    /// Judged against the test's nearby server, so a game's own servers further away add their distance on top.
    public var gamingLevel: Readiness? {
        guard baseline.samples.count >= 3, let latency = baseline.average else { return nil }
        let jitter = baseline.jitter ?? 0, loss = baseline.lossPercent ?? 0, added = addedLatency ?? 0
        if loss > 1 || jitter > 30 || latency > 100 || added > 100 { return .poor }
        return latency > 50 || jitter > 12 || added > 40 ? .fair : .good
    }
    public var gamingReadiness: String {
        switch gamingLevel {
        case nil: String(localized: "Latency unknown", comment: "How online games may play on this connection")
        case .poor: String(localized: "Laggy", comment: "How online games may play on this connection")
        case .fair: String(localized: "Casual · may lag", comment: "How online games may play: fine for casual play, may lag in competitive games")
        case .good: String(localized: "Competitive", comment: "How online games may play on this connection: good enough for competitive play")
        }
    }
    public var addedLatency: Double? {
        guard let baseline = baseline.average, baseline.isFinite, (self.baseline.lossPercent ?? 0) <= 10, self.baseline.samples.count >= 3 else { return nil }
        var loaded: [Double] = []
        if downloadSeconds >= 2, let value = downloadLoaded.average { loaded.append(value) }
        if uploadSeconds >= 2, let value = uploadLoaded.average { loaded.append(value) }
        return loaded.max().map { max(0, $0 - baseline) }
    }
    public var bufferbloat: String {
        guard let addedLatency else { return "Inconclusive" }
        return addedLatency < 15 ? "Low" : addedLatency < 60 ? "Moderate" : "High"
    }
}

/// What a speed test ran over, beside its numbers. Nil fields weren't known (no Wi-Fi, or a test saved before they were recorded).
public struct SpeedTestContext: Codable, Sendable, Equatable {
    /// The default route's interface, such as en0 or utun3.
    public var interface: String?
    /// Wi-Fi, Ethernet, VPN or Other.
    public var kind: String?
    /// The VPN the default route went through: its name, or the tunnel interface. Nil when the test didn't go through one.
    public var vpn: String?
    public var ssid: String?
    public var band: String?
    public var channel: Int?
    public var rssi: Int?
    public var transmitMbps: Double?
    /// Bytes this Mac's network ports (Wi-Fi and Ethernet) carried during the test beyond the test's own; through a VPN this includes its overhead.
    public var otherBytes: Int?
    public init(interface: String? = nil, kind: String? = nil, vpn: String? = nil, ssid: String? = nil, band: String? = nil, channel: Int? = nil,
                rssi: Int? = nil, transmitMbps: Double? = nil, otherBytes: Int? = nil) {
        self.interface = interface; self.kind = kind; self.vpn = vpn; self.ssid = ssid; self.band = band; self.channel = channel
        self.rssi = rssi; self.transmitMbps = transmitMbps; self.otherBytes = otherBytes
    }
    /// The link the test ran over, from the default route and the Wi-Fi radio. Through a VPN on Wi-Fi the radio still carries the tunnel.
    public init(exit: ExitPath, radio: RadioSample) {
        let wifi = radio.interface != nil && radio.rssi != nil
        let kind: String? = exit.tunnel ? "VPN" : exit.interface == nil ? nil : exit.interface == radio.interface ? "Wi-Fi" : exit.interface?.hasPrefix("en") == true ? "Ethernet" : "Other"
        self.init(interface: exit.interface, kind: kind, vpn: exit.tunnel ? exit.vpnName ?? exit.interface : nil, ssid: wifi ? radio.ssid : nil,
                  band: wifi ? radio.band : nil, channel: wifi ? radio.channel : nil, rssi: wifi ? radio.rssi : nil, transmitMbps: wifi ? radio.transmitMbps : nil)
    }
}
