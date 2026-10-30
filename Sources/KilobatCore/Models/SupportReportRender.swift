import Foundation

public extension SupportReport {
    private var dateLine: String {
        created.formatted(.dateTime.day().month(.wide).year().hour().minute()) + " · last " + (hours % 24 == 0 && hours > 24 ? "\(hours / 24) days" : "\(hours) hours")
    }

    /// For pasting into a support chat or an email.
    var text: String {
        var lines = ["Network report · \(dateLine)", "\(mac) · \(connection)", ""]
        lines += findings.map { "• " + $0 }
        if let latency {
            lines += ["", "Checks: \(latency.checks) · router \(Self.ms(latency.routerMedianMs)) · internet \(Self.ms(latency.internetMedianMs)) (p95 \(Self.ms(latency.internetP95Ms))) · DNS \(Self.ms(latency.dnsMedianMs))"
                      + (latency.lossPercent.map { String(format: " · loss %.1f%%", $0) } ?? "")]
        }
        if !outages.isEmpty {
            lines += ["", "Outages:"] + outages.map { "  \($0.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())) – \($0.end.formatted(date: .omitted, time: .shortened)) (\(Self.minutes($0.minutes)))" }
        }
        if !speedTests.isEmpty {
            lines += ["", "Speed tests:"] + speedTests.map { "  \($0.date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))  ↓ \(Self.mbps($0.downloadMbps))  ↑ \(Self.mbps($0.uploadMbps))  idle \(Self.ms($0.idleMs))  under load \($0.bufferbloat)" }
        }
        if let check {
            lines += ["", "Check of \(check.host):"] + check.steps.map { "  \($0.status.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0)) \($0.layer): \($0.detail)" }
        }
        lines += ["", "Left out for privacy: " + leftOut.joined(separator: "; ") + ".", Self.footer]
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
        if !speedTests.isEmpty {
            lines += ["", "## Speed tests", "", "| When | Download | Upload | Idle latency | Under load |", "|---|---|---|---|---|"]
            lines += speedTests.map { "| \($0.date.formatted(.dateTime.weekday(.abbreviated).hour().minute())) | \(Self.mbps($0.downloadMbps)) | \(Self.mbps($0.uploadMbps)) | \(Self.ms($0.idleMs)) | \($0.bufferbloat) |" }
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
        <header><div class="brand">\(batSVG)<span>kilobat</span></div><div class="meta">Network report<br><span>\(esc(dateLine))</span></div></header>
        <p class="device">\(esc(mac)) · \(esc(connection))</p>
        <section class="findings"><h2>What was measured</h2><ul>\(findings.map { "<li>\(esc($0))</li>" }.joined())</ul></section>
        """
        if let latency {
            body += "<section><h2>Latency</h2><div class=\"stats\">"
            for (label, value) in [("Router", Self.ms(latency.routerMedianMs)), ("Internet", Self.ms(latency.internetMedianMs)), ("Internet p95", Self.ms(latency.internetP95Ms)),
                                   ("DNS", Self.ms(latency.dnsMedianMs)), ("Ping loss", latency.lossPercent.map { String(format: "%.1f%%", $0) } ?? "—"), ("Checks", "\(latency.checks)")] {
                body += "<div><span>\(label)</span><b>\(esc(value))</b></div>"
            }
            body += "</div>\(chart(latency))<p class=\"note\">Median per hour. Blue: internet; violet: router; shaded: the internet was unreachable.</p></section>"
        }
        if !outages.isEmpty {
            body += "<section><h2>Outages</h2><table><tr><th>Started</th><th>Ended</th><th>Length</th></tr>"
            body += outages.map { "<tr><td>\(when($0.start))</td><td>\(esc($0.end.formatted(date: .omitted, time: .shortened)))</td><td>\(esc(Self.minutes($0.minutes)))</td></tr>" }.joined()
            body += "</table></section>"
        }
        if !speedTests.isEmpty {
            body += "<section><h2>Speed tests</h2><table><tr><th>When</th><th>Download</th><th>Upload</th><th>Idle latency</th><th>Under load</th></tr>"
            body += speedTests.map { "<tr><td>\(when($0.date))</td><td>\(esc(Self.mbps($0.downloadMbps)))</td><td>\(esc(Self.mbps($0.uploadMbps)))</td><td>\(esc(Self.ms($0.idleMs)))</td><td>\(esc($0.bufferbloat))</td></tr>" }.joined()
            body += "</table>" + (planMbps.map { "<p class=\"note\">Plan: \(esc(Self.mbps($0))) download.</p>" } ?? "") + "</section>"
        }
        if let check {
            body += "<section><h2>Check of \(esc(check.host))</h2><p class=\"\(check.ok ? "ok" : "bad")\">\(esc(check.verdict))</p><table>"
            body += check.steps.map { "<tr><td class=\"s-\($0.status)\">\(esc($0.status))</td><th>\(esc($0.layer))</th><td>\(esc($0.detail))</td></tr>" }.joined()
            body += "</table></section>"
        }
        body += "<footer><p>Left out for privacy: \(esc(leftOut.joined(separator: "; "))). Measured from this Mac only; other devices on the network aren’t included.</p><p class=\"mark\">\(esc(Self.footer))</p></footer>"
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><title>Network report · \(esc(created.formatted(date: .abbreviated, time: .omitted)))</title>
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
