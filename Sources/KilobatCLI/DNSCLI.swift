import Foundation
import KilobatCore

/// `kilobat dns fastest|auto|exclude|include`: the fastest DNS for each network. The app measures and switches; the
/// command line reads what it saved and changes the settings it reads.
@MainActor enum DNSCLI {
    static func run(_ command: FastestDNSCommand) async throws {
        let store = TrafficStore(startMonitoring: false)
        switch command {
        case .fastest(let all, let json):
            let report = await report(all: all, store: store)
            if json { print(String(decoding: try DiagnosticsCLI.encode(report), as: UTF8.self)); return }
            print(text(report))
        case .auto(let on, let network, let json):
            let result = try await setAuto(on, network: network, store: store)
            if json { print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)); return }
            print("✓ " + (result["effect"] as? String ?? ""))
        case .exclude(let choice):
            store.preferences.setDNSExcluded(choice, excluded: true)
            print(choice.id.hasPrefix("custom:") ? "✓ Removed \(choice.name); Kilobat no longer times it." : "✓ Kilobat no longer times or picks \(choice.name).")
        case .include(let choice):
            store.preferences.setDNSExcluded(choice, excluded: false)
            print("✓ Kilobat times \(choice.name) on each network from the next run.")
        case .fallback(let choice, let json):
            let result = setFallback(choice, store: store)
            if json { print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)); return }
            print("✓ " + (result["effect"] as? String ?? ""))
        }
    }

    /// The resolver Kilobat moves to when the fastest fails on a network, before the network's own; nil is none.
    static func setFallback(_ choice: DNSResolverChoice?, store: TrafficStore) -> [String: Any] {
        store.preferences.setDNSFallback(choice)
        guard let choice = store.preferences.dnsFallbackChoice else {
            return ["fallback": NSNull(), "effect": "No fallback: when lookups fail through the fastest DNS, Kilobat puts the network's own DNS back."]
        }
        return ["fallback": choice.id, "name": choice.name, "servers": choice.servers, "label": choice.jurisdiction(locale: FastestDNSReport.english),
                "effect": "When lookups fail through the fastest DNS, Kilobat moves to \(who(choice)) if it answers, and to the network's own DNS if that fails too."]
    }

    /// "Quad9 (Switzerland)", "94.140.14.14 (AdGuard · Cyprus)", "203.0.113.53 (unknown operator)".
    static func who(_ choice: DNSResolverChoice) -> String {
        let english = FastestDNSReport.english
        guard let known = choice.runBy() else { return "\(choice.name) (\(choice.jurisdiction(locale: english).lowercased()))" }
        return "\(choice.name) (\(known.name == choice.name ? known.countryName(english) : known.label(english)))"
    }

    static func report(all: Bool, store: TrafficStore) async -> FastestDNSReport {
        let app = await WiFiCLI.connection()
        let current = app?["networkKey"] as? String
        return FastestDNSReport(saved: FastestDNSWatch.load(), preferences: store.preferences, current: current == "unknown" ? nil : current, all: all)
    }

    /// Turns switching on or off for `network` (a key or name), or for every network.
    static func setAuto(_ on: Bool, network: String?, store: TrafficStore) async throws -> [String: Any] {
        let pro = await WiFiCLI.connection()?["pro"] as? Bool
        guard let network else {
            store.preferences.setFastestDNS(on, network: nil)
            return ["enabled": on, "network": NSNull(), "pro": pro ?? NSNull(),
                    "effect": on ? "Kilobat switches to the fastest DNS on each network once it has won there on 3 days" + (pro == false ? " (needs Kilobat Pro)." : ".")
                                 : "Kilobat no longer switches DNS; it puts back automatic DNS where it had switched."]
        }
        let saved = FastestDNSWatch.load()
        let matches = saved.networks.filter { $0.network == network || $0.name.caseInsensitiveCompare(network) == .orderedSame }.map(\.network)
        let key = matches.count == 1 ? matches[0] : try WiFiCLI.network(network, store: store)
        store.preferences.setFastestDNS(on, network: key)
        let name = saved.networks.first { $0.network == key }?.name ?? store.networkSessions[key]?.name ?? network
        return ["enabled": on, "network": key, "name": name, "pro": pro ?? NSNull(),
                "effect": on ? "\(name): Kilobat uses the fastest DNS there once one has won on 3 days" + (pro == false ? " (needs Kilobat Pro)." : ".")
                             : "\(name): Kilobat keeps the network's own DNS there."]
    }

    static func text(_ report: FastestDNSReport) -> String {
        func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "—" }
        guard !report.networks.isEmpty else {
            return "No DNS runs yet. With the Kilobat app running, it times your network's DNS against Cloudflare, Quad9 and Google a few times a day (never on metered networks, through a VPN or behind a sign-in page)."
        }
        var lines: [String] = []
        for network in report.networks {
            if !lines.isEmpty { lines.append("") }
            lines.append("\(network.name)\(network.current ? " (this network)" : "") · switching \(network.auto ? "on" : "off")")
            lines.append("  " + network.headline)
            if network.networkRewritesMissing { lines.append("  ! The network's DNS answers names that don't exist (NXDOMAIN rewriting).") }
            for resolver in network.resolvers {
                var row = "  \(KilobatCLI.pad(resolver.name, 14))\(KilobatCLI.pad(ms(resolver.medianMs), 9))p90 \(KilobatCLI.pad(ms(resolver.p90Ms), 9))repeat \(KilobatCLI.pad(ms(resolver.repeatMedianMs), 8))\(resolver.label)"
                if resolver.failures > 0 { row += " · \(resolver.failures)/\(resolver.queries) failed" }
                if resolver.cdnPenaltyMs > 0 { row += " · far CDN answers +\(ms(resolver.cdnPenaltyMs))" }
                if resolver.rewritesMissing { row += " · rewrites missing names" }
                lines.append(row)
            }
            if let last = network.lastRun { lines.append("  \(network.runs) runs on \(network.days) days · last \(last.formatted(date: .abbreviated, time: .shortened))") }
            if !network.history.isEmpty {
                lines.append("  Lookups answered, last \(network.historyDays) days (oldest first; █ all, ▆ 95%+, ▃ 80%+, ▁ less, · not timed):")
                for item in network.history { lines.append("  " + KilobatCLI.pad(item.name, 14) + historyLine(item, days: network.historyDays, now: Date())) }
            }
            for (id, until) in network.pausedUntil.sorted(by: { $0.key < $1.key }) {
                lines.append("  Paused here after failing: \(DNSResolverChoice.from(id: id)?.name ?? id) until \(until.formatted(date: .abbreviated, time: .shortened)).")
            }
        }
        if let applied = report.applied {
            let name = DNSResolverChoice.from(id: applied.resolver)?.name ?? applied.resolver
            lines += ["", "Now: \(applied.service) uses \(name)\(applied.fallback ? " (the fallback)" : "") on \(applied.networkName), set by Kilobat \(applied.since.formatted(date: .abbreviated, time: .shortened))."]
        }
        lines.append(report.fallback.flatMap { DNSResolverChoice.from(id: $0.id) }.map { "Fallback: \(who($0)), when the fastest fails; then the network's own." }
                     ?? "Fallback: none. When the fastest fails, the network's own DNS comes back (kilobat dns fallback <resolver> to set one).")
        if let latest = report.switches.first {
            lines.append("Last switch: \(latest.network), \(latest.from) → \(latest.to) (\(latest.reason)), \(latest.date.formatted(date: .abbreviated, time: .shortened)).")
        }
        lines += ["", "Rule: " + report.rule]
        return lines.joined(separator: "\n")
    }

    /// "█████▆·█ 99.6% answered · 3 slow of 1,240": one mark per day, then the totals.
    static func historyLine(_ item: FastestDNSReport.History, days: Int, now: Date, calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let byDay = Dictionary(item.days.map { (calendar.startOfDay(for: $0.date), $0) }, uniquingKeysWith: { first, _ in first })
        let marks = (0..<days).reversed().map { back -> String in
            guard let date = calendar.date(byAdding: .day, value: -back, to: today), let day = byDay[date], day.answered + day.failed > 0 else { return "·" }
            let rate = Double(day.answered) / Double(day.answered + day.failed)
            return rate >= 1 ? "█" : rate >= 0.95 ? "▆" : rate >= 0.8 ? "▃" : "▁"
        }.joined()
        // Rounded down, so one failure in thousands never reads as 100%.
        let rate = item.successRate.map { String(format: "%.1f%%", ($0 * 1000).rounded(.down) / 10) } ?? "—"
        return "\(marks) \(rate) answered · \(item.slow) slow of \((item.answered + item.failed).formatted())"
    }
}
