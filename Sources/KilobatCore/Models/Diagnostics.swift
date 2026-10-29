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
    public let captivePortal: Bool?
    public let networkService: String?
    /// The Ethernet or USB interface traffic leaves through while Wi-Fi stays joined, such as a tethered phone.
    public var wiredInterface: String? = nil
    public var health: ConnectionHealth {
        if captivePortal == true { return .poor }
        if radio.health == .poor || (internet.lossPercent ?? 0) >= 20 { return .poor }
        if radio.health == .degraded || (router?.average ?? 0) > 20 || (internet.average ?? 0) > 120 || (dnsMilliseconds ?? 0) > 150 || (internet.jitter ?? 0) > 30 { return .degraded }
        return internet.average == nil ? .unknown : .good
    }
    public var advice: [String] {
        var tips: [String] = []
        if captivePortal == true { tips.append("This network may require a login. Open the login page before testing again.") }
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
    // Bandwidth tiers: Published conferencing and streaming bandwidth requirements.
    // Latency/loss checks are conservative Kilobat heuristics, not a call-quality guarantee.
    public var callCautionReasons: [String] {
        var reasons: [String] = []
        if let value = baseline.average, value > 300 { reasons.append(String(format: "High latency (%.0f ms)", value)) }
        if let value = baseline.jitter, value > 30 { reasons.append(String(format: "Variable ping (%.0f ms jitter)", value)) }
        if let value = baseline.lossPercent, value > 2 { reasons.append(String(format: "Missing ping replies (%.0f%%)", value)) }
        if let value = addedLatency, value > 100 { reasons.append(String(format: "Delay under load (+%.0f ms)", value)) }
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
    /// Coding agents make many small round trips and upload context, so latency, jitter and loss matter more than speed.
    public var agentReadiness: String {
        let latency = baseline.average ?? 0, jitter = baseline.jitter ?? 0, loss = baseline.lossPercent ?? 0
        if loss > 2 || (addedLatency ?? 0) > 200 || uploadMbps < 0.5 { return "May stall" }
        if latency > 150 || jitter > 50 || uploadMbps < 2 { return "Sluggish" }
        return "Smooth"
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
