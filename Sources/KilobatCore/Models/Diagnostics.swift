import Foundation

public enum ConnectionHealth: String, Codable, Sendable {
    case good, degraded, poor, unknown
    public var symbol: String {
        switch self { case .good: "face.smiling"; case .degraded: "face.dashed"; case .poor: "exclamationmark.triangle"; case .unknown: "questionmark.circle" }
    }
}

extension ConnectionHealth {
    /// How tall this state draws in a timeline, as a share of the full height, so states differ by more than colour:
    /// the worse the state, the taller the bar.
    public var timelineHeight: Double {
        switch self { case .unknown: 0.25; case .good: 0.5; case .degraded: 0.75; case .poor: 1 }
    }
    /// Consecutive equal states merged into runs, oldest first.
    public static func runs(_ states: [ConnectionHealth]) -> [(health: ConnectionHealth, count: Int)] {
        states.reduce(into: []) { runs, state in
            if runs.last?.health == state { runs[runs.count - 1].count += 1 } else { runs.append((state, 1)) }
        }
    }
}
public struct RadioSample: Codable, Sendable, Equatable {
    public var bssid: String? = nil
    public let ssid: String?
    public let interface: String?
    public let rssi: Int?
    public let noise: Int?
    public let transmitMbps: Double?
    public let channel: Int?
    public let band: String?
    /// The link's channel width in MHz.
    public var widthMHz: Int? = nil
    /// "Wi-Fi 6E" and "802.11ax"; the 802.11 name alone for modes older than Wi-Fi 4 (WiFiLink.standard).
    public var standard: String? = nil
    public var phyMode: String? = nil
    /// Such as "WPA3 Personal" (WiFiLink.security); `securityInfo` adds how safe it is.
    public var security: String? = nil
    public var transmitPowerDBm: Int? = nil
    /// The regulatory country the Wi-Fi reports, when CoreWLAN provides it.
    public var countryCode: String? = nil
    /// True when Wi-Fi is switched off or the Mac has none; nil while it's on, joined or not.
    public var radioOff: Bool? = nil
    public var securityInfo: WiFiLink.Security? { security.flatMap(WiFiLink.security(named:)) }
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
    /// The strongest security the network offers, such as "WPA2 Personal" (WiFiLink.security).
    public var security: String? = nil
    public var securityInfo: WiFiLink.Security? { security.flatMap(WiFiLink.security(named:)) }
    /// What the access point's beacon says about it (generation, rates, roaming, security details, multi-link). Nil without
    /// Location access, when macOS withholds the beacon, and in scans saved before Kilobat read it.
    public var details: AccessPointDetails? = nil
    /// The channel span, centre included, as the beacon or the standard channel plan places it.
    public var span: ChannelPlan.Span { ChannelPlan.span(channel: channel, band: band, widthMHz: widthMHz, center: details?.centerChannel) }

    public init(id: String, ssid: String, rssi: Int, noise: Int, channel: Int, band: String, widthMHz: Int, security: String? = nil, details: AccessPointDetails? = nil) {
        self.id = id; self.ssid = ssid; self.rssi = rssi; self.noise = noise; self.channel = channel; self.band = band; self.widthMHz = widthMHz; self.security = security
        self.details = details
    }
}
extension RadioSample {
    /// The basic reading, for previews and other modules; the probe fills the rest.
    public static func basic(bssid: String? = nil, ssid: String?, interface: String?, rssi: Int?, noise: Int?, transmitMbps: Double?, channel: Int?, band: String?) -> RadioSample {
        RadioSample(bssid: bssid, ssid: ssid, interface: interface, rssi: rssi, noise: noise, transmitMbps: transmitMbps, channel: channel, band: band)
    }
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
    /// Replies that never came, worked out from the loss share; nil when nothing came back or ping didn't say.
    public var lost: Int? {
        guard let lossPercent, lossPercent < 100, !samples.isEmpty else { return nil }
        return Int((Double(samples.count) / (1 - lossPercent / 100)).rounded()) - samples.count
    }
}
/// What addresses an interface holds, without the addresses themselves (a snapshot is saved and shared).
public enum LinkAddressState: String, Codable, Sendable {
    /// An address a network gave it, or one set by hand: IPv4 outside 169.254/16, or IPv6 that isn't link-local.
    case assigned
    /// Only a 169.254 address: macOS asked for one and got no answer.
    case selfAssigned
    case none
    public static func classify(ipv4: [String], routableIPv6: Bool) -> LinkAddressState {
        if routableIPv6 || ipv4.contains(where: WakeProbe.usableAddress) { return .assigned }
        return ipv4.contains { $0.hasPrefix("169.254.") } ? .selfAssigned : .none
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
    /// The physical router, even when the default route points at a tunnel.
    public var physicalGateway: String? = nil
    /// Observed on the physical interface, used to distinguish Ethernet networks with the same router IP.
    public var gatewayMAC: String? = nil
    public var tunneledRoute: Bool? = nil
    /// The sign-in page came back on a network that was signed in to: the Wi-Fi logged you out, the internet isn't down.
    public var portalLoggedOut: Bool? = nil
    /// The Mac is on a device's own Wi-Fi (a printer's Wi-Fi Direct, a camera's or drone's network) where there is no
    /// internet by design: no alarm, no outage. The app fills it from the Wi-Fi name and whether anything past the router answered.
    public var setupNetwork: SetupNetworkMatch? = nil
    /// A second ping target (8.8.8.8), so one target that drops ICMP isn't read as an outage. Nil on samples saved before it was kept.
    public var secondary: PingResult? = nil
    /// Whether an HTTPS request got through, tried only when neither ping target answered.
    public var httpReachable: Bool? = nil
    /// The Wi-Fi interface's addresses when the check ran; nil in samples from before Kilobat read them.
    public var radioAddress: LinkAddressState? = nil
    var activeRadioHealth: ConnectionHealth? { wiredInterface == nil ? radio.health : nil }
    public enum Reach: Sendable { case up, down, unknown }
    /// Saved before the second probes were kept: judged as it was then, so history doesn't change its verdicts.
    var singleProbe: Bool { secondary == nil && httpReachable == nil }
    /// Whether anything past the router answered. Down only when every probe was tried and failed.
    public var reachability: Reach {
        if internet.average != nil || secondary?.average != nil || httpReachable == true { return .up }
        if singleProbe { return (internet.lossPercent ?? 0) >= 20 ? .down : .unknown }
        return secondary != nil && httpReachable == false ? .down : .unknown
    }
    /// The ping to read latency, jitter and loss from: the first target, or the second when the first sent nothing back.
    public var measured: PingResult {
        if internet.average == nil, let secondary, secondary.average != nil { return secondary }
        return internet
    }
    /// More than one reply lost across both targets. A single lost reply out of four is ordinary on Wi-Fi.
    var heavyLoss: Bool {
        if singleProbe { return (internet.lossPercent ?? 0) >= 20 }
        guard internet.average != nil else { return false }
        return (internet.lost ?? 0) + (secondary?.lost ?? 0) >= 2
    }
    public var health: ConnectionHealth {
        if setupNetwork != nil { return .unknown }
        if captivePortal == true { return .poor }
        if activeRadioHealth == .poor || reachability == .down || heavyLoss { return .poor }
        let ping = measured
        if activeRadioHealth == .degraded || (router?.average ?? 0) > 20 || (ping.average ?? 0) > 120 || (dnsMilliseconds ?? 0) > 150 || (ping.jitter ?? 0) > 30 { return .degraded }
        return reachability == .up ? .good : .unknown
    }
    public var advice: [String] {
        // A device's own Wi-Fi has no internet on purpose: that's the whole story.
        if let setupNetwork { return [setupNetwork.headline] }
        // A sign-in page in the way explains everything else that fails, so it's the only finding.
        if captivePortal == true {
            return [portalLoggedOut == true ? "The Wi-Fi’s sign-in page logged you out. Sign in again; the internet isn’t down."
                                            : "This network may require a login. Open the login page before testing again."]
        }
        var tips: [String] = []
        let ping = measured
        if activeRadioHealth == .poor || activeRadioHealth == .degraded { tips.append("Wi-Fi signal is weak or noisy. Use Radar to find a stronger spot, or try a different channel.") }
        if (router?.average ?? 0) > 20 { tips.append("The local link to your router is slow. Move closer, reduce competing traffic, then retest before restarting the router.") }
        if (ping.average ?? 0) > 120 && (router?.average ?? 100) < 20 { tips.append("Your router responds quickly, but the internet path is slow. Compare another network or test again later; the upstream connection may be congested.") }
        if (dnsMilliseconds ?? 0) > 150 { tips.append("DNS lookups are slow. Compare Cloudflare or Google DNS, then switch back to Network DNS if it does not help.") }
        if (ping.jitter ?? 0) > 30 { tips.append("Internet latency varies between replies. Run a loaded speed test to see whether competing transfers make it worse.") }
        if (ping.lossPercent ?? 0) >= 5 { tips.append("Some internet ping replies were lost. Compare router loss and repeat the test; filtering and congestion can both cause this.") }
        if internet.average == nil { tips.append("The internet ping target did not reply. Some networks block ICMP; this alone does not prove an outage.") }
        if tips.isEmpty { tips.append("No clear issue in this sample. Run a speed test to check capacity and delay under load.") }
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
        RealtimeLine.callCautions(latency: baseline.average, jitter: baseline.jitter, loss: baseline.lossPercent, added: addedLatency)
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
        RealtimeLine.agentLevel(latency: baseline.average, jitter: baseline.jitter, loss: baseline.lossPercent, added: addedLatency, up: uploadMbps)
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
        return RealtimeLine.gamingLevel(latency: latency, jitter: baseline.jitter, loss: baseline.lossPercent, added: addedLatency)
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

/// The real-time things Health grades, one row each in its Real-time quality card.
public enum RealtimeActivity: String, CaseIterable, Identifiable, Sendable {
    case calls, gaming, cloudGaming, streaming, remote, agents
    public var id: String { rawValue }
}

/// One honest scale for every activity, the app's: good, fair or poor, and why in a few words ("1080p video",
/// "Variable ping (76 ms jitter)"). The CLI keeps its own per-activity words (`videoReadiness` and the rest).
public struct RealtimeGrade: Sendable, Equatable {
    public let level: SpeedTestResult.Readiness
    public let reason: String
    public init(_ level: SpeedTestResult.Readiness, _ reason: String) { self.level = level; self.reason = reason }
}

/// What the grades read: the round trip, jitter and loss from live ping when it has enough replies (else the speed
/// test's idle ping), and the delay a busy line adds and the bandwidth from the last speed test.
public struct RealtimeLine: Sendable, Equatable {
    public var latency: Double?, jitter: Double?, loss: Double?, added: Double?, down: Double?, up: Double?

    public init(latency: Double? = nil, jitter: Double? = nil, loss: Double? = nil, added: Double? = nil, down: Double? = nil, up: Double? = nil) {
        self.latency = latency; self.jitter = jitter; self.loss = loss; self.added = added; self.down = down; self.up = up
    }

    public init(speed: SpeedTestResult?, ping: PingResult?) {
        // A blocked or half-answered ping isn't a reading; the speed test's idle ping stands in.
        let live = ping.flatMap { $0.samples.count >= 3 ? $0 : nil }
        let idle = speed.flatMap { $0.baseline.samples.count >= 3 ? $0.baseline : nil }
        let source = live ?? idle
        // Loss takes the lower of the two: networks and VPNs that rate-limit ping drop some replies to the live pinger
        // while the speed test's own pings all come back, and that isn't loss a game or a call would feel.
        let loss = [live?.lossPercent, idle?.lossPercent].compactMap { $0 }.min()
        self.init(latency: source?.average, jitter: source?.jitter, loss: loss, added: speed?.addedLatency,
                  down: speed?.downloadMbps, up: speed?.uploadMbps)
    }

    /// Nil until there's something to judge by. `obs` grades streaming as going live with OBS, at its `bitrate` when known;
    /// without OBS it grades watching video.
    public func grade(_ activity: RealtimeActivity, obs: Bool = false, bitrate: Int? = nil) -> RealtimeGrade? {
        switch activity {
        case .calls: calls
        case .gaming: gaming
        case .cloudGaming: cloudGaming
        case .streaming: obs ? goingLive(bitrate: bitrate) : watching
        case .remote: remote
        case .agents: agents
        }
    }

    // MARK: Shared with the CLI's words, so each threshold lives once.

    static func callCautions(latency: Double?, jitter: Double?, loss: Double?, added: Double?) -> [String] {
        var reasons: [String] = []
        if let value = latency, value > 300 { reasons.append(String(localized: "High latency (\(String(format: "%.0f", locale: Locale.current, value)) ms)")) }
        if let value = jitter, value > 30 { reasons.append(String(localized: "Variable ping (\(String(format: "%.0f", locale: Locale.current, value)) ms jitter)")) }
        if let value = loss, value > 2 { reasons.append(String(localized: "Missing ping replies (\(String(format: "%.0f", locale: Locale.current, value))%)")) }
        if let value = added, value > 100 { reasons.append(String(localized: "Delay under load (+\(String(format: "%.0f", locale: Locale.current, value)) ms)")) }
        return reasons
    }
    /// Online games send little data but need every packet on time.
    static func gamingLevel(latency: Double, jitter: Double?, loss: Double?, added: Double?) -> SpeedTestResult.Readiness {
        let jitter = jitter ?? 0, loss = loss ?? 0, added = added ?? 0
        if loss > 1 || jitter > 30 || latency > 100 || added > 100 { return .poor }
        return latency > 50 || jitter > 12 || added > 40 ? .fair : .good
    }
    /// Coding agents make many small round trips and upload context.
    static func agentLevel(latency: Double?, jitter: Double?, loss: Double?, added: Double?, up: Double?) -> SpeedTestResult.Readiness {
        let latency = latency ?? 0, jitter = jitter ?? 0, loss = loss ?? 0, up = up ?? .infinity
        if loss > 2 || (added ?? 0) > 200 || up < 0.5 { return .poor }
        return latency > 150 || jitter > 50 || up < 2 ? .fair : .good
    }

    // MARK: The grades

    /// Voice and video calls: the video the bandwidth carries, held back by anything that makes calls stutter.
    var calls: RealtimeGrade? {
        guard let down, let up else { return nil }
        guard min(down, up) >= 0.1 else { return RealtimeGrade(.poor, String(localized: "Too little bandwidth", comment: "Real-time quality: why an activity grades poor")) }
        if let caution = Self.callCautions(latency: latency, jitter: jitter, loss: loss, added: added).first { return RealtimeGrade(.fair, caution) }
        guard latency != nil else { return RealtimeGrade(.fair, String(localized: "Latency unknown", comment: "Real-time quality: no ping reply to judge by")) }
        if down >= 3 && up >= 3.8 { return RealtimeGrade(.good, String(localized: "1080p video", comment: "Real-time quality: the video quality calls can carry")) }
        if down >= 1.8 && up >= 2.6 { return RealtimeGrade(.good, String(localized: "720p video", comment: "Real-time quality: the video quality calls can carry")) }
        return RealtimeGrade(.fair, down >= 0.6 && up >= 1 ? String(localized: "SD video only", comment: "Real-time quality: calls can carry only standard-definition video")
                                                          : String(localized: "Voice only", comment: "Real-time quality: too little bandwidth for video calls"))
    }

    /// Online games: Competitive, Casual or Laggy, and the number that decided it.
    var gaming: RealtimeGrade? {
        guard let latency else { return nil }
        let jitter = jitter ?? 0, loss = loss ?? 0, added = added ?? 0
        switch Self.gamingLevel(latency: latency, jitter: jitter, loss: loss, added: added) {
        case .good: return RealtimeGrade(.good, String(localized: "Competitive · \(Self.ping(latency))", comment: "Real-time quality, gaming: good for competitive play; the argument is a round trip such as “18 ms ping”"))
        case .fair:
            let factor = latency > 50 ? Self.ping(latency) : jitter > 12 ? Self.jitter(jitter) : Self.busy(added)
            return RealtimeGrade(.fair, String(localized: "Casual · \(factor)", comment: "Real-time quality, gaming: fine for casual play, may lag in competitive games; the argument is the reason"))
        case .poor:
            let factor = loss > 1 ? Self.loss(loss) : jitter > 30 ? Self.jitter(jitter) : latency > 100 ? Self.ping(latency) : Self.busy(added)
            return RealtimeGrade(.poor, String(localized: "Laggy · \(factor)", comment: "Real-time quality, gaming: games will lag; the argument is the reason"))
        }
    }

    /// GeForce NOW, Xbox Cloud Gaming and the rest: 15 Mbps for 720p, 25 for 1080p, 45 for 4K, and a short, steady round trip.
    var cloudGaming: RealtimeGrade? {
        guard let down else { return nil }
        let latency = latency ?? 0, jitter = jitter ?? 0, loss = loss ?? 0, added = added ?? 0
        if down < 15 { return RealtimeGrade(.poor, String(localized: "\(Self.mbps(down)) download; streamed games need 15", comment: "Real-time quality, cloud gaming; a speed such as 9 Mbps")) }
        if latency > 80 { return RealtimeGrade(.poor, Self.ping(latency)) }
        if loss > 2 { return RealtimeGrade(.poor, Self.loss(loss)) }
        if jitter > 30 { return RealtimeGrade(.poor, Self.jitter(jitter)) }
        if added > 100 { return RealtimeGrade(.poor, Self.busy(added)) }
        if down < 25 { return RealtimeGrade(.fair, String(localized: "720p · \(Self.mbps(down)) download", comment: "Real-time quality, cloud gaming: enough for 720p; a speed such as 18 Mbps")) }
        if latency > 40 { return RealtimeGrade(.fair, Self.ping(latency)) }
        if jitter > 12 { return RealtimeGrade(.fair, Self.jitter(jitter)) }
        if loss > 0.5 { return RealtimeGrade(.fair, Self.loss(loss)) }
        if added > 40 { return RealtimeGrade(.fair, Self.busy(added)) }
        return RealtimeGrade(.good, down >= 45 ? String(localized: "4K · \(Self.mbps(down)) download", comment: "Real-time quality, cloud gaming: enough for 4K; a speed")
                                              : String(localized: "1080p · \(Self.mbps(down)) download", comment: "Real-time quality, cloud gaming: enough for 1080p; a speed"))
    }

    /// Going live with OBS: the upload against its bitrate plus 30% headroom, or the most it carries when the bitrate isn't known.
    func goingLive(bitrate: Int?) -> RealtimeGrade? {
        guard let up else { return nil }
        let unsteady = (jitter ?? 0) >= 30 || (loss ?? 0) >= 1
        let why = (loss ?? 0) >= 1 ? Self.loss(loss ?? 0) : Self.jitter(jitter ?? 0)
        if let bitrate, bitrate > 0 {
            let kbps = bitrate.formatted()
            switch StreamHeadroom.verdict(bitrate: bitrate, upload: up) {
            case .short: return RealtimeGrade(.poor, String(localized: "Not enough upload for \(kbps) kbps", comment: "Real-time quality, streaming; OBS's bitrate"))
            case .tight: return RealtimeGrade(.fair, String(localized: "Tight for \(kbps) kbps", comment: "Real-time quality, streaming: the upload covers OBS's bitrate but not the headroom"))
            default: return unsteady ? RealtimeGrade(.fair, why) : RealtimeGrade(.good, String(localized: "Ready for \(kbps) kbps", comment: "Real-time quality, streaming: the upload carries OBS's bitrate with headroom"))
            }
        }
        let most = StreamHeadroom.sustainable(upload: up)
        let reason = String(localized: "Go live at up to \(most.formatted()) kbps", comment: "Real-time quality, streaming: the highest OBS bitrate the upload carries with headroom")
        if most < 2_500 { return RealtimeGrade(.poor, reason) }
        if unsteady { return RealtimeGrade(.fair, why) }
        return RealtimeGrade(most >= 6_000 ? .good : .fair, reason)
    }

    /// Watching video, where OBS isn't set up: the resolution the download carries, buffering on a lossy line.
    var watching: RealtimeGrade? {
        guard let down else { return nil }
        if down < 3 { return RealtimeGrade(.poor, String(localized: "Too little bandwidth", comment: "Real-time quality: why an activity grades poor")) }
        if let loss, loss > 2 { return RealtimeGrade(.fair, String(localized: "May buffer · \(Self.loss(loss))", comment: "Real-time quality, watching video; the argument is the loss")) }
        if down >= 15 { return RealtimeGrade(.good, String(localized: "Watch in 4K", comment: "Real-time quality: the video quality the download carries")) }
        if down >= 5 { return RealtimeGrade(.good, String(localized: "Watch in 1080p", comment: "Real-time quality: the video quality the download carries")) }
        return RealtimeGrade(.fair, String(localized: "Watch in 720p", comment: "Real-time quality: the video quality the download carries"))
    }

    /// SSH and remote desktop: every keystroke waits a round trip; a remote screen also needs about 5 Mbps.
    var remote: RealtimeGrade? {
        guard let latency else { return nil }
        let jitter = jitter ?? 0, loss = loss ?? 0
        if latency > 200 { return RealtimeGrade(.poor, Self.ping(latency)) }
        if loss > 2 { return RealtimeGrade(.poor, Self.loss(loss)) }
        if jitter > 50 { return RealtimeGrade(.poor, Self.jitter(jitter)) }
        if latency > 80 { return RealtimeGrade(.fair, Self.ping(latency)) }
        if jitter > 20 { return RealtimeGrade(.fair, Self.jitter(jitter)) }
        if loss > 0.5 { return RealtimeGrade(.fair, Self.loss(loss)) }
        if let added, added > 100 { return RealtimeGrade(.fair, Self.busy(added)) }
        if let down, down < 5 { return RealtimeGrade(.fair, String(localized: "\(Self.mbps(down)) download; remote desktop may blur", comment: "Real-time quality, remote sessions; a speed")) }
        return RealtimeGrade(.good, String(localized: "Typing echoes in \(Self.number(latency)) ms", comment: "Real-time quality, remote sessions: SSH keystrokes come back after this round trip"))
    }

    /// Coding agents: Smooth, Sluggish or May stall, and the number that decided it.
    var agents: RealtimeGrade? {
        guard latency != nil || up != nil else { return nil }
        let level = Self.agentLevel(latency: latency, jitter: jitter, loss: loss, added: added, up: up)
        let latency = latency ?? 0, jitter = jitter ?? 0, loss = loss ?? 0, added = added ?? 0, up = up ?? .infinity
        switch level {
        case .good: return RealtimeGrade(.good, String(localized: "Smooth", comment: "How a coding agent may run on this connection"))
        case .fair:
            let factor = latency > 150 ? Self.ping(latency) : jitter > 50 ? Self.jitter(jitter) : Self.upload(up)
            return RealtimeGrade(.fair, String(localized: "Sluggish · \(factor)", comment: "Real-time quality, AI agents: they may run slowly; the argument is the reason"))
        case .poor:
            let factor = loss > 2 ? Self.loss(loss) : added > 200 ? Self.busy(added) : Self.upload(up)
            return RealtimeGrade(.poor, String(localized: "May stall · \(factor)", comment: "Real-time quality, AI agents: they may stall; the argument is the reason"))
        }
    }

    // MARK: Phrases for the number that decided a grade

    private static func number(_ value: Double) -> String { String(format: "%.0f", locale: Locale.current, value) }
    private static func mbps(_ value: Double) -> String { String(localized: "\(StreamHeadroom.mbps(value)) Mbps", comment: "A speed in megabits per second") }
    private static func ping(_ value: Double) -> String { String(localized: "\(number(value)) ms ping", comment: "Real-time quality: the round trip that decided a grade") }
    private static func jitter(_ value: Double) -> String { String(localized: "\(number(value)) ms jitter", comment: "Real-time quality: the jitter that decided a grade") }
    private static func loss(_ value: Double) -> String { String(localized: "\(String(format: "%.1f", locale: Locale.current, value))% loss", comment: "Real-time quality: the ping loss that decided a grade") }
    private static func busy(_ value: Double) -> String { String(localized: "+\(number(value)) ms when the line is busy", comment: "Real-time quality: the delay a busy line adds, which decided a grade") }
    private static func upload(_ value: Double) -> String { String(localized: "\(mbps(value)) upload", comment: "Real-time quality: the upload speed that decided a grade") }
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
    /// True when the Mac had no IPv4 default route during the test, so the IPv4 latency pings could not reply. Nil otherwise.
    public var noIPv4Route: Bool?
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

/// One network name with every radio heard broadcasting it, strongest first, so a mesh isn't a page of identical rows.
/// Hidden networks have no name to share and stay apart.
public struct NearbyNetworkGroup: Identifiable, Sendable {
    public let id: String
    public let radios: [NearbyNetwork]
    public var strongest: NearbyNetwork { radios[0] }

    /// "2.4 + 5 GHz"
    public var bands: String {
        let numbers = Set(radios.map { $0.band.replacingOccurrences(of: " GHz", with: "") })
        return numbers.sorted { (Double($0) ?? 0) < (Double($1) ?? 0) }.joined(separator: " + ") + " GHz"
    }

    public static let hiddenName = "Hidden network"

    public static func group(_ networks: [NearbyNetwork]) -> [NearbyNetworkGroup] {
        let sorted = networks.sorted { $0.rssi > $1.rssi }
        var order: [String] = [], radios: [String: [NearbyNetwork]] = [:]
        for network in sorted {
            let key = network.ssid == hiddenName ? network.id : network.ssid
            if radios[key] == nil { order.append(key) }
            radios[key, default: []].append(network)
        }
        return order.map { NearbyNetworkGroup(id: $0, radios: radios[$0]!) }
    }
}
