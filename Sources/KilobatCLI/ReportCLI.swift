import Foundation
import KilobatCore

/// `kilobat report compare`: a router's or provider's total beside what Kilobat recorded for the same period.
@MainActor enum ReportCLI {
    static let usage = "Use report compare --total 40GB [--unit GB|GiB|…] [--direction both|download|upload] (--from DATE --to DATE | --period last-month|this-month|last-7-days|yesterday|today|last-24-hours) [--network NAME]… [--json|--csv]."

    static func compare(_ args: [String]) throws {
        var options: [String: String] = [:], networks: [String] = [], index = 2
        while index < args.count {
            let flag = args[index]
            if ["--json", "--csv"].contains(flag) { index += 1; continue }
            guard ["--total", "--unit", "--direction", "--from", "--to", "--period", "--network"].contains(flag), index + 1 < args.count else { throw CLIError(usage) }
            if flag == "--network" { networks.append(args[index + 1]) } else { options[flag] = args[index + 1] }
            index += 2
        }
        guard let totalText = options["--total"] else { throw CLIError("Pass --total, the router's or provider's figure, such as --total 40GB. " + usage) }
        let comparison = try comparison(total: totalText, unit: options["--unit"], direction: options["--direction"], from: options["--from"], to: options["--to"],
                                        period: options["--period"], networks: networks)
        if args.contains("--json") { print(String(decoding: try comparison.json(), as: UTF8.self)); return }
        if args.contains("--csv") { print(comparison.csv(), terminator: ""); return }
        print(text(comparison).joined(separator: "\n"))
    }

    /// Shared with the MCP tool, which passes a bare number as `total` and its unit apart.
    static func comparison(total totalText: String, unit unitText: String?, direction directionText: String?, from: String?, to: String?,
                           period presetText: String?, networks requested: [String], now: Date = Date()) throws -> UsageComparison {
        guard let parsed = UsageComparison.total(totalText) else { throw CLIError("Can't read '\(totalText)' as a total. Write it like 40GB, 40 GiB or 1.5 TB.") }
        let named = try unitText.map { text -> UsageComparison.Unit in
            guard let unit = UsageComparison.Unit.named(text) else { throw CLIError("Unknown unit '\(text)'. Use B, KB, MB, GB, TB (decimal) or KiB, MiB, GiB, TiB (binary).") }
            return unit
        }
        if let named, let own = parsed.unit, named != own { throw CLIError("--total says \(own.rawValue) but --unit says \(named.rawValue). Pass one.") }
        guard let unit = named ?? parsed.unit else { throw CLIError("Say the total's unit, as written by the router or provider: --total 40GB, or --unit GB. GB is decimal, GiB binary.") }
        guard let direction = UsageComparison.Direction(rawValue: (directionText ?? "both").lowercased()) else { throw CLIError("--direction takes both, download or upload.") }

        let interval: DateInterval
        if let presetText {
            guard from == nil, to == nil else { throw CLIError("Pass --period or --from and --to, not both.") }
            guard let preset = UsageComparison.Preset(rawValue: presetText.lowercased()) else {
                throw CLIError("--period takes " + UsageComparison.Preset.allCases.map(\.rawValue).joined(separator: ", ") + ".")
            }
            interval = preset.interval(now: now)
        } else {
            guard let from, let to else { throw CLIError("Say which period the figure covers: --from and --to, or --period last-month and the like.") }
            guard let start = UsageComparison.date(from) else { throw CLIError("Can't read --from '\(from)'. Use 2026-10-01, 2026-10-01 18:00 or ISO 8601.") }
            guard let end = UsageComparison.date(to, end: true) else { throw CLIError("Can't read --to '\(to)'. Use 2026-10-31, 2026-10-31 18:00 or ISO 8601.") }
            guard end > start else { throw CLIError("--to must come after --from.") }
            interval = DateInterval(start: start, end: end)
        }
        guard interval.duration <= 400 * 86_400 else { throw CLIError("Compare at most 400 days; Kilobat keeps a year of history.") }

        let store = TrafficStore(startMonitoring: false)
        let names = UsageComparison.networkNames(store.usage, sessions: store.networkSessions)
        var scope: Set<String>?
        if !requested.isEmpty {
            scope = []
            for request in requested {
                let matches = names.filter { $0.key == request || $0.value.lowercased() == request.lowercased() }.map(\.key)
                guard !matches.isEmpty else {
                    throw CLIError("No recorded network named '\(request)'. Recorded: " + Set(names.values).sorted().joined(separator: ", ") + ".")
                }
                scope?.formUnion(matches)
            }
        }
        return UsageComparison.make(store.usage, period: interval, scope: scope, names: names, total: parsed.amount, unit: unit, direction: direction,
                                    monitoringScope: store.preferences.trafficScope, sleeps: store.sleeps, now: now)
    }

    static func text(_ result: UsageComparison) -> [String] {
        let formatter = DateFormatter(); formatter.dateFormat = "d MMM yyyy HH:mm"; formatter.timeZone = TimeZone(identifier: result.timeZone)
        let amount = result.amount, hours = UsageComparison.Text().hours
        var lines = ["Kilobat and your figure · \(formatter.string(from: result.start)) – \(formatter.string(from: result.end)), \(result.timeZone) · \(result.direction.title.lowercased())", ""]
        let alternate = result.alternateUnit.flatMap { unit in result.alternateBytes.map { " · \(amount($0)) if it means \(unit.rawValue)" } } ?? ""
        lines.append("  Your figure    \(amount(result.externalBytes))\(alternate)")
        lines.append("  Kilobat        \(amount(result.kilobatBytes)) · ↓ \(amount(result.downloadBytes))  ↑ \(amount(result.uploadBytes)) · " + result.scopeName)
        let percent = result.differencePercent.map { " (\(Int(abs($0).rounded()))%)" } ?? ""
        lines.append("  Difference     " + (result.differenceBytes == 0 ? "none" : "\(amount(result.differenceBytes.magnitude)) \(result.differenceBytes > 0 ? "less" : "more") on Kilobat\(percent)"))
        lines.append("  Recorded       \(hours(result.recordedHours)) of \(hours(result.periodHours)) hours (\(Int((result.coverage * 100).rounded()))%)" + (result.gaps.isEmpty ? "" : " · \(result.gaps.count) gap\(result.gaps.count == 1 ? "" : "s")"))
        for gap in result.gaps.sorted(by: { $0.hours > $1.hours }).prefix(5) {
            lines.append("    \(formatter.string(from: gap.start)) – \(formatter.string(from: gap.end))  \(hours(gap.hours)) h  \(gap.detail)")
        }
        if result.gaps.count > 5 { lines.append("    and \(result.gaps.count - 5) more in --json or --csv") }
        if result.networks.count > 1 || !result.allNetworks {
            let shown = result.networks.filter { $0.bytes > 0 || $0.counted }
            lines.append("  Networks       " + shown.prefix(6).map { "\($0.name) \(amount($0.bytes))\($0.counted ? "" : ", not counted")" }.joined(separator: " · ") + (shown.count > 6 ? " · \(shown.count - 6) more" : ""))
        }
        if !result.topApps.isEmpty { lines.append("  Top apps       " + result.topApps.map { "\($0.name) \(amount($0.bytes))" }.joined(separator: " · ")) }
        lines += ["", result.summary, "", "Likely reasons"]
        lines += result.reasons.map { "  • " + $0.text }
        lines += ["", "--json or --csv exports the period, scope, coverage and every gap to share with your provider."]
        return lines
    }
}
