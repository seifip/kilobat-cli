import Foundation

public extension SupportReport {
    private var dateLine: String {
        let date = created.formatted(.dateTime.day().month(.wide).year().hour().minute())
        return hours % 24 == 0 && hours > 24 ? String(localized: "\(date) · last \(hours / 24) days", comment: "When the provider report was made and the days it covers")
            : String(localized: "\(date) · last \(hours) hours", comment: "When the provider report was made and the hours it covers")
    }
    private var leftOutLine: String { String(localized: "Left out for privacy: \(leftOut.joined(separator: "; ")).", comment: "Items joined with semicolons") }
    private static func result(_ status: String) -> String {
        switch status {
        case "ok": String(localized: "OK", comment: "A connection check layer passed, in the provider report")
        case "warning": String(localized: "Warning", comment: "A connection check layer is worth a look, in the provider report")
        case "failed": String(localized: "Failed", comment: "A connection check layer failed, in the provider report")
        case "skipped": String(localized: "Skipped", comment: "A connection check layer was skipped, in the provider report")
        default: status
        }
    }
    private static func seconds(_ evidence: StarlinkEvidence, _ side: StarlinkOutage.Side) -> Double? {
        let value = switch side { case .setup: evidence.setupSeconds; case .network: evidence.networkSeconds; case .dish: evidence.dishSeconds }
        return value > 0 ? value : nil
    }
    /// "No satellites (Starlink’s network)".
    private static func cause(_ outage: StarlinkEvidence.Outage) -> String {
        let cause = StarlinkOutage.Cause(rawValue: outage.cause) ?? .unknown
        return "\(cause.title) (\((StarlinkOutage.Side(rawValue: outage.side) ?? cause.side).title))"
    }
    /// Label and value pairs for the plan check, in the order every format shows them.
    private static func planRows(_ plan: PlanSummary) -> [(String, String)] {
        [(String(localized: "Plan", comment: "The internet plan’s download speed, in the provider report’s plan check"), PlanSummary.mbps(plan.planMbps)),
         (String(localized: "Median", comment: "Median download over the plan check, in the provider report"), "\(PlanSummary.mbps(plan.downloadMedianMbps)) (\(PlanSummary.percent(plan.percentOfPlan)))"),
         (String(localized: "Upload", comment: "Median upload over the plan check, in the provider report"), PlanSummary.mbps(plan.uploadMedianMbps)),
         (String(localized: "Evenings", comment: "Median download between 7 and 11 pm, in the provider report"), plan.peakMedianMbps.map(PlanSummary.mbps) ?? "—"),
         (String(localized: "Rest of the day", comment: "Median download outside 7 to 11 pm, in the provider report"), plan.offPeakMedianMbps.map(PlanSummary.mbps) ?? "—"),
         (String(localized: "Under half", comment: "Share of speed tests below half the plan, in the provider report"), PlanSummary.percent(plan.underHalfPercent))]
    }
    private var planHeading: String {
        guard let planCheck else { return "" }
        return planCheck.scheduledOnly
            ? String(localized: "Against the plan: \(planCheck.checks) scheduled checks over \(planCheck.days) days", comment: "A heading in the provider report: a count of automatic speed tests and the days they cover")
            : String(localized: "Against the plan: \(planCheck.checks) speed tests over \(planCheck.days) days", comment: "A heading in the provider report: a count of speed tests and the days they cover")
    }
    private static func grade(_ bufferbloat: String) -> String { Bundle.main.localizedString(forKey: bufferbloat, value: bufferbloat, table: nil) }

    /// For pasting into a support chat or an email.
    var text: String {
        var lines = [String(localized: "Network report · \(dateLine)", comment: "The provider report’s title line, then when it was made and what it covers"), "\(mac) · \(connection)", ""]
        lines += findings.map { "• " + $0 }
        if let latency {
            lines += ["", ([String(localized: "Checks: \(latency.checks)", comment: "How many health checks the provider report covers"),
                            String(localized: "router \(Self.ms(latency.routerMedianMs))", comment: "Median latency to the router, in the provider report"),
                            String(localized: "internet \(Self.ms(latency.internetMedianMs)) (p95 \(Self.ms(latency.internetP95Ms)))", comment: "Median and 95th-percentile internet latency, in the provider report"),
                            String(localized: "DNS \(Self.ms(latency.dnsMedianMs))", comment: "Median DNS lookup time, in the provider report")]
                           + [latency.lossPercent.map { String(localized: "loss \(String(format: "%.1f", $0))%", comment: "Average ping loss, in the provider report") }].compactMap { $0 }).joined(separator: " · ")]
        }
        if !outages.isEmpty {
            lines += ["", String(localized: "Outages:", comment: "A heading in the provider report")] + outages.map { "  \($0.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())) – \($0.end.formatted(date: .omitted, time: .shortened)) (\(Self.minutes($0.minutes)))" }
        }
        if let starlink {
            lines += ["", String(localized: "Starlink dish log:", comment: "A heading in the provider report")]
            lines += StarlinkOutage.Side.allCases.compactMap { side in Self.seconds(starlink, side).map { "  \(side.title): \(StarlinkEvidence.length($0))" } }
            lines += starlink.outages.suffix(20).map { "  \($0.start.formatted(.dateTime.weekday(.abbreviated).hour().minute().second()))  \(StarlinkEvidence.length($0.seconds))  \(Self.cause($0))" }
        }
        if !speedTests.isEmpty {
            lines += ["", String(localized: "Speed tests:", comment: "A heading in the provider report")] + speedTests.map { test in
                let when = test.date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
                return "  " + String(localized: "\(when)  ↓ \(Self.mbps(test.downloadMbps))  ↑ \(Self.mbps(test.uploadMbps))  idle \(Self.ms(test.idleMs))  under load \(Self.grade(test.bufferbloat))", comment: "One speed test in the provider report: when, download, upload, idle latency and the bufferbloat grade (Low, Moderate, High)")
            }
        }
        if let planCheck {
            lines += ["", planHeading + ":", "  " + Self.planRows(planCheck).map { "\($0.0) \($0.1)" }.joined(separator: " · ")]
        }
        if let check {
            lines += ["", String(localized: "Check of \(check.host):", comment: "A heading in the provider report: a site that was checked layer by layer")]
                + check.steps.map { "  \(Self.result($0.status).uppercased().padding(toLength: 7, withPad: " ", startingAt: 0)) \($0.layer): \($0.detail)" }
        }
        lines += ["", leftOutLine, Self.footer]
        return lines.joined(separator: "\n")
    }

    var markdown: String {
        var lines = ["# Network report", "", "\(dateLine)  ", "\(mac) · \(connection)", "", "## What was measured", ""]
        lines += findings.map { "- " + $0 }
        if let latency {
            lines += ["", "## Latency", "", "| Router | Internet | Internet p95 | DNS | Loss | Checks |", "|---|---|---|---|---|---|",
                      "| \(Self.ms(latency.routerMedianMs)) | \(Self.ms(latency.internetMedianMs)) | \(Self.ms(latency.internetP95Ms)) | \(Self.ms(latency.dnsMedianMs)) | \(latency.lossPercent.map { String(format: "%.1f%%", $0) } ?? "—") | \(latency.checks) |"]
        }
        if !outages.isEmpty {
            lines += ["", "## Outages", "", "| Started | Ended | Length |", "|---|---|---|"]
            lines += outages.map { "| \($0.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())) | \($0.end.formatted(date: .omitted, time: .shortened)) | \(Self.minutes($0.minutes)) |" }
        }
        if let starlink {
            lines += ["", "## Starlink dish log", ""] + StarlinkOutage.Side.allCases.compactMap { side in Self.seconds(starlink, side).map { "- \(side.title): \(StarlinkEvidence.length($0))" } }
            lines += ["", "| Started | Length | Cause |", "|---|---|---|"] + starlink.outages.suffix(20).map { "| \($0.start.formatted(.dateTime.weekday(.abbreviated).hour().minute().second())) | \(StarlinkEvidence.length($0.seconds)) | \(Self.cause($0)) |" }
        }
        if !speedTests.isEmpty {
            lines += ["", "## Speed tests", "", "| When | Download | Upload | Idle latency | Under load |", "|---|---|---|---|---|"]
            lines += speedTests.map { "| \($0.date.formatted(.dateTime.weekday(.abbreviated).hour().minute())) | \(Self.mbps($0.downloadMbps)) | \(Self.mbps($0.uploadMbps)) | \(Self.ms($0.idleMs)) | \($0.bufferbloat) |" }
        }
        if let planCheck {
            let rows = Self.planRows(planCheck)
            lines += ["", "## " + planHeading, "", "| " + rows.map(\.0).joined(separator: " | ") + " |", "|" + String(repeating: "---|", count: rows.count), "| " + rows.map(\.1).joined(separator: " | ") + " |"]
        }
        if let check {
            lines += ["", "## Check of \(check.host)", "", "| Layer | Result | Detail |", "|---|---|---|"]
            lines += check.steps.map { "| \($0.layer) | \($0.status) | \($0.detail.replacingOccurrences(of: "|", with: "\\|")) |" }
        }
        lines += ["", "_Left out for privacy: " + leftOut.joined(separator: "; ") + "._", "", "_\(Self.footer)_"]
        return lines.joined(separator: "\n")
    }

    /// A self-contained page that prints cleanly to PDF: light, one column, a latency chart, no scripts or external files.
    var html: String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        func when(_ d: Date) -> String { esc(d.formatted(.dateTime.weekday(.abbreviated).hour().minute())) }
        var body = """
        <header><div class="brand">\(batSVG)<span>kilobat</span></div><div class="meta">\(esc(String(localized: "Network report", comment: "The provider report’s title")))<br><span>\(esc(dateLine))</span></div></header>
        <p class="device">\(esc(mac)) · \(esc(connection))</p>
        <section class="findings"><h2>\(esc(String(localized: "What was measured", comment: "A heading in the provider report")))</h2><ul>\(findings.map { "<li>\(esc($0))</li>" }.joined())</ul></section>
        """
        if let latency {
            body += "<section><h2>\(esc(String(localized: "Latency")))</h2><div class=\"stats\">"
            for (label, value) in [(String(localized: "Router"), Self.ms(latency.routerMedianMs)), (String(localized: "Internet"), Self.ms(latency.internetMedianMs)),
                                   (String(localized: "Internet p95", comment: "95th-percentile internet latency, in the provider report"), Self.ms(latency.internetP95Ms)),
                                   ("DNS", Self.ms(latency.dnsMedianMs)), (String(localized: "Ping loss", comment: "Share of pings with no reply, in the provider report"), latency.lossPercent.map { String(format: "%.1f%%", $0) } ?? "—"),
                                   (String(localized: "Checks", comment: "How many health checks the provider report covers"), "\(latency.checks)")] {
                body += "<div><span>\(esc(label))</span><b>\(esc(value))</b></div>"
            }
            body += "</div>\(chart(latency))<p class=\"note\">\(esc(String(localized: "Median per hour. Blue: internet; violet: router; shaded: the internet was unreachable.", comment: "The provider report’s latency chart legend")))</p></section>"
        }
        if !outages.isEmpty {
            body += "<section><h2>\(esc(String(localized: "Outages", comment: "A heading in the provider report")))</h2><table><tr><th>\(esc(String(localized: "Started", comment: "When an outage started")))</th>"
                + "<th>\(esc(String(localized: "Ended", comment: "When an outage ended")))</th><th>\(esc(String(localized: "Length", comment: "How long an outage lasted")))</th></tr>"
            body += outages.map { "<tr><td>\(when($0.start))</td><td>\(esc($0.end.formatted(date: .omitted, time: .shortened)))</td><td>\(esc(Self.minutes($0.minutes)))</td></tr>" }.joined()
            body += "</table></section>"
        }
        if let starlink {
            body += "<section><h2>\(esc(String(localized: "Starlink dish log", comment: "A heading in the provider report")))</h2><div class=\"stats sides\">"
            for side in StarlinkOutage.Side.allCases { body += "<div><span>\(esc(side.title))</span><b>\(esc(Self.seconds(starlink, side).map(StarlinkEvidence.length) ?? "0 s"))</b></div>" }
            body += "</div><table><tr><th>\(esc(String(localized: "Started", comment: "When an outage started")))</th><th>\(esc(String(localized: "Length", comment: "How long an outage lasted")))</th><th>\(esc(String(localized: "Cause", comment: "Why the Starlink dish was offline, in the provider report")))</th></tr>"
            body += starlink.outages.suffix(20).map { "<tr><td>\(esc($0.start.formatted(.dateTime.weekday(.abbreviated).hour().minute().second())))</td><td>\(esc(StarlinkEvidence.length($0.seconds)))</td><td>\(esc(Self.cause($0)))</td></tr>" }.joined()
            body += "</table><p class=\"note\">\(esc(String(localized: "From the dish’s own outage log. Your setup: obstructions, heat, power save, cable. Starlink’s network: no satellite in view, no reply from the ground station.", comment: "The provider report’s note under the Starlink outage log")))</p></section>"
        }
        if !speedTests.isEmpty {
            body += "<section><h2>\(esc(String(localized: "Speed tests", comment: "A heading in the provider report")))</h2><table><tr>"
                + [String(localized: "When"), String(localized: "Download"), String(localized: "Upload"), String(localized: "Idle latency"), String(localized: "Under load")].map { "<th>\(esc($0))</th>" }.joined() + "</tr>"
            body += speedTests.map { "<tr><td>\(when($0.date))</td><td>\(esc(Self.mbps($0.downloadMbps)))</td><td>\(esc(Self.mbps($0.uploadMbps)))</td><td>\(esc(Self.ms($0.idleMs)))</td><td>\(esc(Self.grade($0.bufferbloat)))</td></tr>" }.joined()
            body += "</table>" + (planMbps.map { "<p class=\"note\">\(esc(String(localized: "Plan: \(Self.mbps($0)) download.", comment: "The internet plan’s download speed, in the provider report")))</p>" } ?? "") + "</section>"
        }
        if let planCheck {
            body += "<section><h2>\(esc(planHeading))</h2><div class=\"stats\">" + Self.planRows(planCheck).map { "<div><span>\(esc($0.0))</span><b>\(esc($0.1))</b></div>" }.joined()
            body += "</div><p class=\"note\">\(esc(String(localized: "Evenings are 7 to 11 pm, when home connections are busiest. Under half: tests below half the plan’s speed.", comment: "The provider report’s plan check note")))</p></section>"
        }
        if let check {
            body += "<section><h2>\(esc(String(localized: "Check of \(check.host)", comment: "A heading in the provider report: a site that was checked layer by layer")))</h2><p class=\"\(check.ok ? "ok" : "bad")\">\(esc(check.verdict))</p><table>"
            body += check.steps.map { "<tr><td class=\"s-\($0.status)\">\(esc(Self.result($0.status)))</td><th>\(esc($0.layer))</th><td>\(esc($0.detail))</td></tr>" }.joined()
            body += "</table></section>"
        }
        body += "<footer><p>\(esc(leftOutLine)) \(esc(String(localized: "Measured from this Mac only; other devices on the network aren’t included.", comment: "The provider report’s footer")))</p><p class=\"mark\">\(esc(Self.footer))</p></footer>"
        let title = String(localized: "Network report · \(created.formatted(date: .abbreviated, time: .omitted))", comment: "The provider report’s page title and the day it was made")
        return """
        <!doctype html><html lang="\(Bundle.main.preferredLocalizations.first ?? "en")"><head><meta charset="utf-8"><title>\(esc(title))</title>
        <style>\(css)</style></head><body><main>\(body)</main></body></html>
        """
    }

    private var batSVG: String {
        ##"<svg viewBox="0 0 26 22" width="22" height="19" aria-hidden="true"><path fill="#7a5cf0" d="M2 5 Q6 10 10 8 V2 L13 6 L16 2 V8 Q20 10 24 5 L25 17 Q22 13 20 16 Q17 13 16 18 L13 21 L10 18 Q9 13 6 16 Q4 13 1 17Z"/></svg>"##
    }

    /// Hourly medians as two lines, with outages shaded across the hours they touched.
    private func chart(_ latency: Latency) -> String {
        let points = latency.hourly
        guard points.count > 1, let first = points.first?.hour, let last = points.last?.hour else { return "" }
        let width = 640.0, height = 150.0, top = 10.0, bottom = 22.0
        let span = max(1, last.timeIntervalSince(first))
        let ceiling = max(20, (points.compactMap(\.internetMs) + points.compactMap(\.routerMs)).max() ?? 20) * 1.15
        func x(_ d: Date) -> Double { min(width, max(0, d.timeIntervalSince(first) / span * width)) }
        func y(_ v: Double) -> Double { top + (height - top - bottom) * (1 - min(1, v / ceiling)) }
        func path(_ values: [(Date, Double)]) -> String {
            values.enumerated().map { "\($0.offset == 0 ? "M" : "L")\(String(format: "%.1f", x($0.element.0))) \(String(format: "%.1f", y($0.element.1)))" }.joined(separator: " ")
        }
        let shade = outages.map { o in
            let x1 = x(o.start), x2 = max(x1 + 2, x(o.end))
            return "<rect x=\"\(String(format: "%.1f", x1))\" y=\"\(top)\" width=\"\(String(format: "%.1f", x2 - x1))\" height=\"\(height - top - bottom)\" fill=\"#e08575\" opacity=\"0.25\"/>"
        }.joined()
        let internet = path(points.compactMap { p in p.internetMs.map { (p.hour, $0) } })
        let router = path(points.compactMap { p in p.routerMs.map { (p.hour, $0) } })
        let labels = [first, first.addingTimeInterval(span / 2), last].enumerated().map { index, date in
            "<text x=\"\(String(format: "%.0f", x(date)))\" y=\"\(height - 6)\" text-anchor=\"\(["start", "middle", "end"][index])\">\(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))</text>"
        }.joined()
        let scale = "<text x=\"0\" y=\"\(top + 8)\">\(Int(ceiling)) ms</text>"
        return """
        <svg class="chart" viewBox="0 0 \(Int(width)) \(Int(height))" preserveAspectRatio="none">
        <line x1="0" y1="\(height - bottom)" x2="\(width)" y2="\(height - bottom)" stroke="#d9d9e3"/>\(shade)
        <path d="\(router)" fill="none" stroke="#7a5cf0" stroke-width="1.6"/><path d="\(internet)" fill="none" stroke="#2f80e0" stroke-width="2"/>\(labels)\(scale)</svg>
        """
    }

    private var css: String {
        """
        @page { margin: 16mm; }
        * { box-sizing: border-box; }
        body { margin: 0; background: #fff; color: #1c1d26; font: 13px/1.5 -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif; }
        main { max-width: 680px; margin: 0 auto; padding: 32px 20px; }
        header { display: flex; justify-content: space-between; align-items: flex-start; border-bottom: 1px solid #ececf2; padding-bottom: 14px; }
        .brand { display: flex; align-items: center; gap: 8px; font-weight: 700; font-size: 17px; letter-spacing: -0.3px; }
        .meta { text-align: right; font-weight: 600; } .meta span { font-weight: 400; color: #6e7287; font-size: 12px; }
        .device { color: #6e7287; margin: 10px 0 18px; }
        h2 { font-size: 13px; margin: 22px 0 8px; }
        .findings { background: #f6f4fe; border: 1px solid #e7e1fb; border-radius: 9px; padding: 4px 16px 10px; }
        .findings ul { margin: 0; padding-left: 18px; } .findings li { margin: 6px 0; }
        .stats { display: grid; grid-template-columns: repeat(6, 1fr); gap: 8px; }
        .stats div { border: 1px solid #ececf2; border-radius: 9px; padding: 8px 10px; }
        .stats.sides { grid-template-columns: repeat(3, 1fr); margin-bottom: 10px; }
        .stats span { display: block; color: #6e7287; font-size: 11px; } .stats b { font-size: 15px; font-variant-numeric: tabular-nums; }
        .chart { width: 100%; height: 150px; margin-top: 12px; } .chart text { font-size: 10px; fill: #6e7287; }
        table { width: 100%; border-collapse: collapse; font-variant-numeric: tabular-nums; }
        th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid #f0f0f5; vertical-align: top; } th { font-weight: 600; }
        .note { color: #6e7287; font-size: 11px; margin: 6px 0 0; }
        .ok { color: #239a5b; font-weight: 600; } .bad { color: #c8553f; font-weight: 600; }
        .s-ok { color: #239a5b; } .s-failed { color: #c8553f; font-weight: 600; } .s-warning { color: #d97a00; } .s-skipped { color: #6e7287; }
        footer { margin-top: 28px; padding-top: 12px; border-top: 1px solid #ececf2; color: #6e7287; font-size: 11px; }
        .mark { color: #7a5cf0; font-weight: 600; font-size: 12px; }
        @media (max-width: 560px) { .stats { grid-template-columns: repeat(3, 1fr); } header { flex-direction: column; gap: 8px; } .meta { text-align: left; } }
        """
    }
}
