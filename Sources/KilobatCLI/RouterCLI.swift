import Foundation
import KilobatCore

/// `kilobat router`: router check-up. Whether the router has been getting slower over days against its own normal,
/// how restarts went, and the verdict. Read-only; the app keeps the history from its background checks.
enum RouterCLI {
    struct Output: Encodable {
        /// The router this Mac used last, first; with --all, every router seen in the last 60 days.
        let routers: [RouterReport]
    }

    static func run(_ args: [String]) throws {
        let options: RouterReport.Options
        do { options = try RouterReport.Options.parse(args) } catch { throw CLIError(RouterReport.Options.usage) }
        let output = reports(all: options.all)
        if options.json { print(String(decoding: try DiagnosticsCLI.encode(output), as: UTF8.self)); return }
        guard !output.routers.isEmpty else {
            print("No router history yet. With the Kilobat app running, each background check adds to it; after 7 days with quiet checks Kilobat knows what's normal for your router.")
            return
        }
        for (index, report) in output.routers.enumerated() {
            if index > 0 { print("") }
            print(text(report))
        }
    }

    static func reports(all: Bool, now: Date = Date()) -> Output {
        let saved = RouterWatch.load()
        let ordered = saved.routers.sorted { ($0.id == saved.current ? 1 : 0, $0.lastSeen) > ($1.id == saved.current ? 1 : 0, $1.lastSeen) }
        return Output(routers: (all ? ordered : Array(ordered.prefix(1))).map { RouterReport($0, now: now) })
    }

    static func text(_ report: RouterReport) -> String {
        let ms = RouterReport.ms
        var lines = ["\(report.name)" + (report.mac.map { " · router \($0)" } ?? "")]
        lines.append("  \(report.state == .degraded ? "✗" : report.state == .normal ? "✓" : "·") \(report.headline)")
        for line in [report.detail, report.advice, report.followUp].compactMap({ $0 }) { lines.append("  \(line)") }
        if let base = report.baseline {
            var normal = ["router \(ms(base.routerMs)) (p90 \(ms(base.routerP90Ms)))", String(format: "loss %.1f%%", base.lossPercent)]
            if let dns = base.dnsMs { normal.append("lookups \(ms(dns))") }
            normal.append(String(format: "%.1f drops a day", base.dropsPerDay))
            lines.append("  Normal (\(base.days) days): " + normal.joined(separator: " · "))
        }
        if !report.recent.isEmpty {
            lines.append("  Recent:  " + report.recent.map { day in
                "\(day.day.formatted(.dateTime.weekday(.abbreviated).day())) \(ms(day.routerMs))" + (day.drops > 0 ? ", \(day.drops) drops" : "")
            }.joined(separator: " · "))
        }
        if report.trend.count > 3 { lines.append("  Trend:   " + report.trend.map { String(format: "%.0f", $0.routerMs) }.joined(separator: " ") + " ms (last \(report.trend.count) days with data)") }
        if !report.restarts.isEmpty {
            lines.append("  Restarts:")
            for restart in report.restarts.prefix(5) {
                let how = restart.source == "button" ? "you restarted it" : "went away for \(Int(restart.outageSeconds ?? 0)) s and came back"
                let outcome = switch restart.outcome {
                case "fixed": "fixed it"
                case "helped": "helped"
                case "didntHelp": "didn't help"
                case "unclear": "unclear"
                case "noProblem": "nothing was wrong before"
                default: "checking"
                }
                let numbers = [restart.beforeMs.map { "before \(ms($0))" }, restart.afterMs.map { "after \(ms($0))" }].compactMap { $0 }.joined(separator: ", ")
                lines.append("    \(restart.date.formatted(date: .abbreviated, time: .shortened))  \(how): \(outcome)" + (numbers.isEmpty ? "" : " (\(numbers))"))
            }
        }
        return lines.joined(separator: "\n")
    }
}
