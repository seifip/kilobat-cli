import Foundation

/// Made-up block checks for screenshots and the debug snapshots, run through the real rules. Addresses are documentation
/// ranges (RFC 5737), never a real service's.
public enum NetworkBlockSamples {
    /// Slack's name missing on a hotel Wi-Fi, Discord's TLS cut on mobile data, and Claude refusing a roaming exit.
    public static func blocks(now: Date = Date()) -> [NetworkBlock] {
        var slack = BlockMeasurements(host: "slack.com", system: DNSAnswer(.nxdomain), trusted: .addresses(["203.0.113.10", "203.0.113.11"]))
        slack.systemHandshake = nil
        let slackContext = BlockContext(serviceID: "slack", service: "Slack", status: .operational, statusSentence: "Slack’s status page reports no problems.", place: .public)
        var discord = BlockMeasurements(host: "discord.com", system: .addresses(["198.51.100.7"]), trusted: .addresses(["198.51.100.7"]))
        discord.systemHandshake = .reset; discord.repeatHandshake = .reset; discord.controlHandshake = .alert; discord.trustedHandshake = .reset
        let discordContext = BlockContext(serviceID: "discord", service: "Discord", status: .operational, statusSentence: "Discord’s status page reports no problems.", place: .mobile)
        let pattern = RegionRefusal.patterns.first { $0.text == "app-unavailable-in-region" }
        let claude = RegionRefusal.finding(host: "claude.ai", who: "Anthropic", signal: .regionError, pattern: pattern,
                                           context: BlockContext(serviceID: "claude", service: "Claude", status: .operational, place: .mobile), exit: "DE", zone: "ES", date: now)
        return [NetworkBlockRules.classify(slack, slackContext, date: now), NetworkBlockRules.classify(discord, discordContext, date: now), claude].compactMap { $0 }
    }

    /// A connection check of slack.com on that hotel Wi-Fi, with its layers and the block leading the verdict.
    public static func report(now: Date = Date()) -> DoctorReport {
        let block = blocks(now: now)[0]
        let steps = [
            DoctorStep(layer: "Network", status: .ok, detail: "Online; the router at 192.0.2.1 answers."),
            DoctorStep(layer: "Interface", status: .ok, detail: "Connections leave through Wi-Fi (en0)."),
            DoctorStep(layer: "Proxy", status: .ok, detail: "No system proxy for this address."),
            DoctorStep(layer: "DNS", status: .failed, detail: "slack.com didn’t resolve with your DNS (192.0.2.53), but 1.1.1.1 resolves it to 203.0.113.10, 203.0.113.11."),
            DoctorStep(layer: "Status page", status: .ok, detail: "Slack’s status page reports no problems."),
        ]
        let report = DoctorReport(target: "https://slack.com", host: "slack.com", app: nil, verdict: "", next: "", steps: steps, date: now)
        return ConnectionDoctor.withBlock(report, block)
    }
}
