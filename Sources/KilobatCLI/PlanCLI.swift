import Foundation
import KilobatCore

/// `kilobat plan`: how each network's speed tests compare with the plan it pays for. Read-only; the app runs the checks.
@MainActor enum PlanCLI {
    struct Network: Encodable {
        let network: String
        let planMbps: Double
        /// "network" when the plan was set for this network; "default" for the single plan from `settings plan-mbps`.
        let planSource: String
        let headline: String
        let sentence: String
        let summary: PlanSummary
    }
    struct Output: Encodable {
        /// Whether the app runs scheduled plan checks (Settings › Network › Plan check, Pro).
        let planCheck: Bool
        let days: Int
        let networks: [Network]
    }

    static let usage = "Use plan [--days 7…90] [--json]."

    static func run(_ args: [String]) throws {
        try KilobatCLI.allow(args, ["--days", "--json"], valued: ["--days"])
        var days = PlanSummary.window
        if let index = args.firstIndex(of: "--days") {
            guard index + 1 < args.count, let value = Int(args[index + 1]), (7...90).contains(value) else { throw CLIError(usage) }
            days = value
        }
        let output = summaries(days: days)
        if args.contains("--json") { print(String(decoding: try DiagnosticsCLI.encode(output), as: UTF8.self)); return }
        if output.networks.isEmpty {
            print("No plan to compare with yet. Set your plan's download speed for this network in Kilobat (under a speed test result, or Settings › Network › Plan speed), or with kilobat settings plan-mbps 500, then run a few speed tests.")
        }
        for (index, entry) in output.networks.enumerated() {
            let summary = entry.summary
            if index > 0 { print("") }
            print("\(entry.network) · plan \(PlanSummary.mbps(entry.planMbps))" + (entry.planSource == "default" ? " (the plan from settings plan-mbps)" : ""))
            print("  \(entry.headline)")
            print("  \(entry.sentence)")
            var detail = ["upload \(PlanSummary.mbps(summary.uploadMedianMbps))"]
            if let peak = summary.peakMedianMbps { detail.append("evenings \(PlanSummary.mbps(peak)) (\(summary.peakChecks))") }
            if let rest = summary.offPeakMedianMbps { detail.append("rest of the day \(PlanSummary.mbps(rest)) (\(summary.offPeakChecks))") }
            detail.append("under half the plan \(PlanSummary.percent(summary.underHalfPercent))")
            detail.append("range \(PlanSummary.mbps(summary.slowestMbps))–\(PlanSummary.mbps(summary.fastestMbps))")
            print("  " + detail.joined(separator: " · "))
            if !summary.scheduledOnly { print("  Counts the tests you ran: fewer than \(PlanSummary.enoughScheduled) scheduled checks so far.") }
        }
        if !output.planCheck {
            print("\nScheduled plan checks are off. Turn on Settings › Network › Plan check in Kilobat (Pro), or run kilobat settings plan-check on.")
        }
    }

    /// Networks with their own plan; with none set, the newest tested network against the single plan.
    static func summaries(days: Int, now: Date = Date()) -> Output {
        let defaults = KilobatCLI.appDefaults, tests = NetworkJournal().speedTests
        let plans = PlanSpeeds.all(defaults)
        var candidates: [(key: String, plan: Double, source: String)] = plans.map { ($0.key, $0.value, "network") }
        if candidates.isEmpty, let plan = PlanSpeeds.plan(for: nil, defaults), let newest = tests.last(where: { $0.networkKey != "unknown" }) {
            candidates = [(newest.networkKey, plan, "default")]
        }
        let networks = candidates.compactMap { candidate -> Network? in
            guard let summary = PlanSummary.make(tests: tests, network: candidate.key, planMbps: candidate.plan, days: days, now: now) else { return nil }
            let name = tests.last { $0.networkKey == candidate.key }?.networkName ?? "Unknown network"
            return Network(network: name, planMbps: candidate.plan, planSource: candidate.source, headline: summary.headline, sentence: summary.sentence, summary: summary)
        }.sorted { $0.summary.last > $1.summary.last }
        return Output(planCheck: defaults.bool(forKey: PlanCheck.enabledKey), days: days, networks: networks)
    }
}
