import Foundation

/// The channels AirDrop's peer-to-peer link (AWDL) keeps returning to, so its "social" channels: 6 on 2.4 GHz, 44 and
/// 149 on 5 GHz (the RIPE 91 talk on AWDL latency; NVIDIA's GeForce NOW advice names 149 and 44 for the same reason).
/// A Mac on any other channel has to leave its own for a moment each time, which shows as regular ping spikes.
/// Only the primary channel counts here: whether a wide channel that merely covers 44 behaves the same is untested.
public enum AWDLChannels {
    public static let social: Set<Int> = [6, 44, 149]
    public enum Fit: Equatable, Sendable {
        /// The Wi-Fi is on one of AirDrop's channels: the link rarely has to leave it.
        case shares
        /// The Wi-Fi is elsewhere: AirDrop's link hops away from it.
        case offChannel
        /// Not on Wi-Fi, or the channel isn't known.
        case unknown
    }
    public static func fit(channel: Int?, band: String?) -> Fit {
        guard let channel, channel > 0, let band, band == "2.4 GHz" || band == "5 GHz" || band == "6 GHz" else { return .unknown }
        // 6 GHz channel numbers overlap 5 GHz ones; AirDrop's link doesn't use 6 GHz.
        if band == "6 GHz" { return .offChannel }
        return social.contains(channel) ? .shares : .offChannel
    }
    /// The channel AirDrop's link uses on the Wi-Fi's own band, to suggest to the router.
    public static func suggestion(band: String?) -> String {
        band == "2.4 GHz" ? "6" : String(localized: "149 or 44", comment: "Wi-Fi channels to suggest for the router: AirDrop's channels")
    }
    /// One sentence for the stutter test and the comparison, or nil when the channel isn't known.
    public static func note(channel: Int?, band: String?) -> String? {
        guard let channel else { return nil }
        switch fit(channel: channel, band: band) {
        case .offChannel:
            return String(localized: "Your Wi-Fi is on channel \(channel), and AirDrop’s link keeps visiting channels 44 and 149, so it has to leave yours each time. A router set to channel \(suggestion(band: band)) shares AirDrop’s channel, which can stop this.",
                          comment: "AirDrop's link (AWDL) and the Wi-Fi channel; the first argument is a channel number, the second like '149 or 44'")
        case .shares:
            return String(localized: "Your Wi-Fi is on channel \(channel), one AirDrop’s link also uses, so it rarely has to leave your channel.",
                          comment: "AirDrop's link (AWDL) and the Wi-Fi channel; the argument is 6, 44 or 149")
        case .unknown: return nil
        }
    }
}

/// What the guided comparison switches off for a moment: Bluetooth, or AirDrop's link (AWDL).
public enum RadioSwitch: String, Codable, Sendable, CaseIterable {
    case bluetooth, airDrop
    public var name: String {
        switch self {
        case .bluetooth: String(localized: "Bluetooth", comment: "Radio comparison: the switch being tested")
        case .airDrop: String(localized: "AirDrop", comment: "Radio comparison: the switch being tested")
        }
    }
    /// How long the radio needs after switching before a reading means anything.
    public var settle: TimeInterval { self == .bluetooth ? 3 : 1 }
}

/// One reading: latency to the router (or the internet when the router ignores ping) and, off a metered network, a
/// short download.
public struct RadioReading: Codable, Equatable, Sendable {
    public var medianMs: Double?
    public var p95Ms: Double?
    public var spikes: Int
    public var lossPercent: Double
    public var downloadMbps: Double?
    public init(medianMs: Double?, p95Ms: Double?, spikes: Int, lossPercent: Double = 0, downloadMbps: Double? = nil) {
        self.medianMs = medianMs; self.p95Ms = p95Ms; self.spikes = spikes; self.lossPercent = lossPercent; self.downloadMbps = downloadMbps
    }
    public init(_ stutter: StutterResult, downloadMbps: Double?) {
        self.init(medianMs: stutter.p50, p95Ms: stutter.p95, spikes: stutter.spikes.count, lossPercent: stutter.lossPercent, downloadMbps: downloadMbps)
    }
}

/// The moments the comparison measures, in order. Each switch is measured off and then back on, so a change that
/// goes away when the switch comes back is told apart from a line that just got better on its own.
public enum RadioStage: String, Codable, Sendable, Hashable {
    case asIs, bluetoothOff, bluetoothBack, airDropPaused, airDropBack
    public static func off(_ radio: RadioSwitch) -> RadioStage { radio == .bluetooth ? .bluetoothOff : .airDropPaused }
    public static func back(_ radio: RadioSwitch) -> RadioStage { radio == .bluetooth ? .bluetoothBack : .airDropBack }
}

/// How one reading moved against the readings either side of it.
public enum RadioChange: String, Codable, Sendable {
    case better, same, worse
    /// The line moved by itself between the readings either side, so this one can't be judged.
    case unclear
    /// Nothing to compare: not measured, or no reply.
    case notMeasured
}

/// What switching one radio off did.
public struct RadioEffect: Codable, Equatable, Sendable {
    public let radio: RadioSwitch
    public let latency: RadioChange
    public let speed: RadioChange
    /// The readings it was judged on: just before, with it off, and with it back.
    public let before: RadioReading
    public let off: RadioReading
    public let back: RadioReading?
    public var helped: Bool { latency == .better || speed == .better }
    public var unclear: Bool { !helped && (latency == .unclear || speed == .unclear) }
}

/// Why a switch wasn't tested.
public enum RadioSkip: String, Codable, Sendable {
    /// Kilobat has no Bluetooth access, or macOS doesn't offer the switch.
    case unavailable
    /// It was already off.
    case alreadyOff
    /// The person said not now.
    case declined
    /// Switching it failed, such as a cancelled password prompt.
    case failed
}

/// The comparison's answer, in the order it's worth saying.
public enum RadioVerdict: Equatable, Sendable {
    /// One or both switches made a clear difference that went away when it came back.
    case helped([RadioSwitch])
    /// Neither made a difference: the honest end, with no next toggle to offer.
    case noneHelped
    /// The readings moved too much on their own to tell.
    case unclear
    /// There was nothing to switch off.
    case nothingTested
}

public struct RadioComparison: Equatable, Sendable {
    public var effects: [RadioEffect]
    public var skipped: [RadioSwitch: RadioSkip]
    /// The Wi-Fi channel and band during the comparison, for the AirDrop channel advice.
    public var channel: Int?
    public var band: String?
    public init(effects: [RadioEffect], skipped: [RadioSwitch: RadioSkip] = [:], channel: Int? = nil, band: String? = nil) {
        self.effects = effects; self.skipped = skipped; self.channel = channel; self.band = band
    }

    /// A latency change has to beat a quarter of the old value and 15 ms, as in Fix it; throughput a quarter and 10 Mbps.
    public static let share = 0.25, latencyMs = 15.0, speedMbps = 10.0
    /// A spike count counts as gone when it falls to a third, from at least three.
    public static let spikesFrom = 3

    /// Judges one switch from the reading before it, the reading with it off and the reading after it came back.
    /// "Better" needs the off reading to beat both neighbours: half the margin against each and the full margin against
    /// their average. Neighbours that disagree with each other by more than the margin make it unclear.
    public static func effect(_ radio: RadioSwitch, before: RadioReading, off: RadioReading, back: RadioReading?) -> RadioEffect {
        let latency = judge(lowerIsBetter: true, before: before.p95Ms, off: off.p95Ms, back: back?.p95Ms, floor: latencyMs,
                            spikes: (before.spikes, off.spikes, back?.spikes))
        let speed = judge(lowerIsBetter: false, before: before.downloadMbps, off: off.downloadMbps, back: back?.downloadMbps, floor: speedMbps, spikes: nil)
        return RadioEffect(radio: radio, latency: latency, speed: speed, before: before, off: off, back: back)
    }

    static func judge(lowerIsBetter: Bool, before: Double?, off: Double?, back: Double?, floor: Double, spikes: (Int, Int, Int?)?) -> RadioChange {
        guard let before, let off else { return .notMeasured }
        let neighbours = [before] + (back.map { [$0] } ?? [])
        let base = neighbours.reduce(0, +) / Double(neighbours.count)
        let needed = max(base * share, floor)
        // Positive is an improvement whichever way the number runs.
        func gain(_ from: Double) -> Double { lowerIsBetter ? from - off : off - from }
        // Spikes that mostly vanish count even when the 95th percentile hides them: a few a second is not 5% of pings.
        let fewerSpikes: Bool = {
            guard let spikes else { return false }
            let around = [spikes.0] + (spikes.2.map { [$0] } ?? [])
            let baseline = Double(around.reduce(0, +)) / Double(around.count)
            return baseline >= Double(spikesFrom) && Double(spikes.1) * 3 <= baseline && around.allSatisfy { $0 >= spikesFrom - 1 }
        }()
        if (gain(base) >= needed && neighbours.allSatisfy { gain($0) >= needed / 2 }) || fewerSpikes { return .better }
        if let back, abs(back - before) > needed { return .unclear }
        if gain(base) <= -needed && neighbours.allSatisfy({ gain($0) <= -needed / 2 }) { return .worse }
        return .same
    }

    public var verdict: RadioVerdict {
        if effects.isEmpty { return .nothingTested }
        let helped = effects.filter(\.helped).map(\.radio)
        if !helped.isEmpty { return .helped(helped) }
        return effects.contains(where: \.unclear) ? .unclear : .noneHelped
    }

    public var title: String {
        switch verdict {
        case .helped(let radios) where radios.count > 1: String(localized: "Bluetooth and AirDrop both slow this Wi-Fi", comment: "Radio comparison result")
        case .helped(let radios): radios.first == .bluetooth ? String(localized: "Bluetooth slows this Wi-Fi", comment: "Radio comparison result")
                                                               : String(localized: "AirDrop slows this Wi-Fi", comment: "Radio comparison result")
        case .noneHelped: String(localized: "Neither Bluetooth nor AirDrop changed it", comment: "Radio comparison result")
        case .unclear: String(localized: "Too uneven to tell", comment: "Radio comparison result")
        case .nothingTested: String(localized: "Nothing to compare", comment: "Radio comparison result")
        }
    }

    /// What it means and what to do: one short paragraph, never a further toggle when nothing helped.
    public var detail: String {
        switch verdict {
        case .helped(let radios):
            var lines: [String] = []
            if radios.contains(.bluetooth) {
                if band == "2.4 GHz" { lines.append(String(localized: "Bluetooth shares 2.4 GHz with your Wi-Fi. A 5 GHz network avoids that.", comment: "Radio comparison advice")) }
                else {
                    lines.append(String(localized: "With Bluetooth off the Wi-Fi was clearly better, even on \(band ?? "5 GHz"). That points to how macOS or the Wi-Fi chip shares the radio. Turn Bluetooth off when you need full speed, use a cable, or tell Apple with Feedback Assistant.",
                                        comment: "Radio comparison advice; the argument is a Wi-Fi band such as 5 GHz"))
                    if AWDLChannels.fit(channel: channel, band: band) == .offChannel, let channel {
                        lines.append(String(localized: "Some people fixed this by moving the router from channel \(channel) to 149. That is also AirDrop’s channel, so the two may be linked.",
                                            comment: "Radio comparison advice; the argument is the current channel"))
                    }
                }
            }
            if radios.contains(.airDrop) {
                if let note = AWDLChannels.note(channel: channel, band: band), AWDLChannels.fit(channel: channel, band: band) == .offChannel { lines.append(note) }
                lines.append(String(localized: "Pause AirDrop for calls and games from the Wi-Fi & Bluetooth menu.", comment: "Radio comparison advice"))
            }
            return lines.joined(separator: " ")
        case .noneHelped:
            return String(localized: "None of these changed it, so this Mac’s radio isn’t being crowded by them. That points to macOS or the Wi-Fi firmware, or to the network itself.",
                          comment: "Radio comparison: nothing helped, said honestly instead of offering another switch")
        case .unclear:
            return String(localized: "The line changed by itself between readings, so the comparison can’t say. Try again when nothing big is downloading.", comment: "Radio comparison result detail")
        case .nothingTested:
            return String(localized: "Bluetooth and AirDrop were already off, or couldn’t be switched, so there was nothing to compare.", comment: "Radio comparison result detail")
        }
    }

    /// One line a switch's row shows, such as "Ping 120 → 18 ms · 160 → 380 Mbps".
    public static func line(_ effect: RadioEffect) -> String {
        var parts: [String] = []
        if let was = effect.before.p95Ms, let now = effect.off.p95Ms {
            parts.append(String(localized: "Ping \(number(was)) → \(number(now)) ms", comment: "Radio comparison: worst-case ping before and with the switch off"))
        }
        if let was = effect.before.downloadMbps, let now = effect.off.downloadMbps {
            parts.append(String(localized: "\(number(was)) → \(number(now)) Mbps", comment: "Radio comparison: download before and with the switch off"))
        }
        return parts.isEmpty ? String(localized: "No reading", comment: "Radio comparison: nothing measured") : parts.joined(separator: " · ")
    }
    static func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0))) }

    /// Plain English for the CLI and a pasted report, whatever the app's language.
    public var plainSummary: String {
        var lines = ["Radio comparison: \(title)"]
        for effect in effects {
            lines.append("- \(effect.radio.rawValue) off: \(Self.line(effect)) (latency \(effect.latency.rawValue), speed \(effect.speed.rawValue))")
        }
        for (radio, skip) in skipped.sorted(by: { $0.key.rawValue < $1.key.rawValue }) { lines.append("- \(radio.rawValue): not tested (\(skip.rawValue))") }
        return lines.joined(separator: "\n")
    }
}

/// Where Fix it offers the comparison: after a run on Wi-Fi that didn't end Fixed, for a cause the radio could be behind.
public enum RadioCheckPolicy {
    /// Pro, like Fix it and the stutter test's comparison with AirDrop paused.
    public static let needsPro = true
    public static func offered(after cause: FixCause, outcome: FixOutcome, onWiFi: Bool) -> Bool {
        guard onWiFi else { return false }
        switch outcome { case .fixed, .noIssue: return false; default: break }
        switch cause { case .airDrop, .router, .provider: return true; default: return false }
    }
    /// The stutter test offers it after spikes on the local network, the radio's side of the line.
    public static func offered(after stutter: StutterResult) -> Bool {
        stutter.local && [.periodic, .irregular, .few].contains(stutter.pattern)
    }
}
