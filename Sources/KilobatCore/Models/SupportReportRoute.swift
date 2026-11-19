import Foundation

/// A watched route in the provider report, when the person picks one: what was watched, where lasting delay starts,
/// how the destination fared, and each hop's median, worst and loss. Private addresses become words, as everywhere
/// in the report; the provider's own routers keep their public addresses, since those are what support can act on.
public struct RouteEvidence: Codable, Sendable, Equatable {
    public struct Hop: Codable, Sendable, Equatable {
        public let ttl: Int
        public let router: String
        public let medianMs: Double?
        public let worstMs: Double?
        public let lossPercent: Double
        public let destination: Bool
    }
    public struct Point: Codable, Sendable, Equatable {
        public let date: Date
        public let ms: Double?
        public let lossPercent: Double
    }
    public var host: String
    public let started: Date
    public let ended: Date
    public let rounds: Int
    public let intervalSeconds: Double
    public let method: String
    public let destinationMedianMs: Double?
    public let destinationLossPercent: Double?
    public let troubleTTL: Int?
    public var verdict: String
    public let routeChanges: Int
    public var hops: [Hop]
    /// The destination over the watch in up to 60 steps, for the report's chart.
    public let series: [Point]

    public init(watch: WatchedRoute) {
        let timeline = RouteTimeline(watch: watch)
        host = watch.host
        started = watch.started; ended = watch.ended ?? watch.lastDate
        rounds = watch.rounds.count; intervalSeconds = watch.interval; method = watch.options.method == .icmp ? "ICMP" : "UDP"
        let replies = watch.rounds.compactMap { watch.destinationMs($0) }.sorted()
        destinationMedianMs = replies.isEmpty ? nil : replies[replies.count / 2]
        destinationLossPercent = watch.destinationAnswers && !watch.rounds.isEmpty ? Double(watch.rounds.count - replies.count) / Double(watch.rounds.count) * 100 : nil
        troubleTTL = timeline.troubleTTL
        verdict = SupportReport.redact(timeline.verdict)
        routeChanges = timeline.changes.count
        hops = timeline.rows.map { row in
            Hop(ttl: row.ttl, router: row.routers.first.map(SupportReport.redact) ?? String(localized: "no reply", comment: "A route hop that didn't answer"),
                medianMs: row.medianMs, worstMs: row.worstMs, lossPercent: row.lossPercent, destination: row.isDestination)
        }
        if let destination = timeline.rows.last(where: \.isDestination) {
            series = timeline.buckets(destination, count: min(60, max(1, watch.rounds.count))).filter { $0.probes > 0 }.map {
                Point(date: $0.start, ms: $0.mid, lossPercent: Double($0.lost) / Double($0.probes) * 100)
            }
        } else { series = [] }
    }

    /// One line for the report's findings.
    public var finding: String {
        let length = SupportReport.minutes(ended.timeIntervalSince(started) / 60)
        var line = String(localized: "Watching the route to \(host) for \(length) (\(rounds) traces): \(verdict)", comment: "Provider report finding: a watched route; the host, how long, how many traces and where delay starts")
        if let loss = destinationLossPercent, let median = destinationMedianMs {
            line += " " + String(localized: "The destination answered in \(SupportReport.ms(median)) (median) and missed \(String(format: "%.0f", locale: Locale.current, loss))% of probes.", comment: "Provider report finding: a watched route's destination")
        }
        return line
    }

    /// Without the host's name and address: "the host watched".
    func withoutNames() -> RouteEvidence {
        let word = String(localized: "the host watched", comment: "Replaces a watched route's host in the provider report, mid-sentence")
        var copy = self
        let destination = hops.last(where: \.destination)?.router
        func scrub(_ text: String) -> String {
            var text = text.replacingOccurrences(of: host, with: word, options: .caseInsensitive)
            if let destination, !destination.isEmpty { text = text.replacingOccurrences(of: destination, with: word) }
            return text
        }
        copy.host = word
        copy.verdict = scrub(verdict)
        copy.hops = hops.map { Hop(ttl: $0.ttl, router: $0.destination ? word : $0.router, medianMs: $0.medianMs, worstMs: $0.worstMs, lossPercent: $0.lossPercent, destination: $0.destination) }
        return copy
    }

    public var heading: String {
        String(localized: "Route to \(host), watched \(started.formatted(.dateTime.weekday(.abbreviated).hour().minute())) – \(ended.formatted(date: .omitted, time: .shortened))",
               comment: "A heading in the provider report: a watched route, its host and when")
    }
    public var note: String {
        String(localized: "\(method) traceroute, one probe a hop every \(Int(intervalSeconds)) seconds. A hop that skips replies while later hops answer is a router rate-limiting probes, not loss; only delay or loss that carries on to the end affects traffic.",
               comment: "The provider report's note under a watched route")
    }
    public func hopLine(_ hop: Hop) -> String {
        let median = SupportReport.ms(hop.medianMs), worst = SupportReport.ms(hop.worstMs)
        return "\(hop.ttl). \(hop.router)  " + String(localized: "median \(median), worst \(worst), \(String(format: "%.0f", locale: Locale.current, hop.lossPercent))% no reply", comment: "Provider report: one hop of a watched route")
            + (hop.ttl == troubleTTL ? "  ← " + String(localized: "delay starts", comment: "Route timeline: the hop where lasting delay starts") : "")
    }
}

public extension SupportReport {
    /// The report with a watched route the person chose, and its line in the findings.
    func with(route watch: WatchedRoute?) -> SupportReport {
        guard let watch, watch.rounds.count >= 2 else { return self }
        var copy = self
        let evidence = RouteEvidence(watch: watch)
        copy.route = evidence
        copy.findings.append(evidence.finding)
        return copy
    }

    /// The route's section in the plain-text report.
    internal var routeText: [String] {
        guard let route else { return [] }
        return ["", route.heading + ":"] + route.hops.map { "  " + route.hopLine($0) } + ["  " + route.note]
    }
    internal var routeMarkdown: [String] {
        guard let route else { return [] }
        var lines = ["", "## " + route.heading, "", route.verdict, "", "| Hop | Router | Median | Worst | No reply |", "|---|---|---|---|---|"]
        lines += route.hops.map { hop in
            let mark = hop.ttl == route.troubleTTL ? " **←**" : ""
            return "| \(hop.ttl) | \(hop.router)\(mark) | \(Self.ms(hop.medianMs)) | \(Self.ms(hop.worstMs)) | \(String(format: "%.0f%%", locale: Locale.current, hop.lossPercent)) |"
        }
        return lines + ["", "_" + route.note + "_"]
    }
    internal func routeHTML(_ esc: (String) -> String) -> String {
        guard let route else { return "" }
        var body = "<section><h2>\(esc(route.heading))</h2><p>\(esc(route.verdict))</p>\(routeChart(route))<table><tr>"
            + [String(localized: "Hop", comment: "Route timeline column: the hop number and router"), String(localized: "Router"), String(localized: "Median", comment: "Route timeline column: each hop's median reply time"),
               String(localized: "Worst"), String(localized: "No reply", comment: "Provider report: share of probes a hop didn't answer")].map { "<th>\(esc($0))</th>" }.joined() + "</tr>"
        body += route.hops.map { hop in
            "<tr\(hop.ttl == route.troubleTTL ? " class=\"bad\"" : "")><td>\(hop.ttl)</td><td>\(esc(hop.router))</td><td>\(esc(Self.ms(hop.medianMs)))</td><td>\(esc(Self.ms(hop.worstMs)))</td><td>\(esc(String(format: "%.0f%%", locale: Locale.current, hop.lossPercent)))</td></tr>"
        }.joined()
        return body + "</table><p class=\"note\">\(esc(route.note))</p></section>"
    }
    /// The destination's median per step as a line, with steps that lost probes shaded.
    private func routeChart(_ route: RouteEvidence) -> String {
        let points = route.series
        guard points.count > 1 else { return "" }
        let width = 640.0, height = 110.0, top = 8.0, bottom = 18.0
        let span = max(1, route.ended.timeIntervalSince(route.started))
        let ceiling = max(20, (points.compactMap(\.ms).max() ?? 20) * 1.15)
        func x(_ d: Date) -> Double { min(width, max(0, d.timeIntervalSince(route.started) / span * width)) }
        func y(_ v: Double) -> Double { top + (height - top - bottom) * (1 - min(1, v / ceiling)) }
        let step = width / Double(points.count)
        let shade = points.filter { $0.lossPercent > 0 }.map {
            "<rect x=\"\(String(format: "%.1f", x($0.date)))\" y=\"\(top)\" width=\"\(String(format: "%.1f", step))\" height=\"\(height - top - bottom)\" fill=\"#e08575\" opacity=\"\(String(format: "%.2f", 0.15 + 0.5 * min(1, $0.lossPercent / 100)))\"/>"
        }.joined()
        var path = "", drawing = false
        for point in points {
            guard let ms = point.ms else { drawing = false; continue }
            path += "\(drawing ? "L" : "M")\(String(format: "%.1f", x(point.date) + step / 2)) \(String(format: "%.1f", y(ms))) "
            drawing = true
        }
        let labels = "<text x=\"0\" y=\"\(height - 4)\">\(route.started.formatted(date: .omitted, time: .shortened))</text><text x=\"\(width)\" y=\"\(height - 4)\" text-anchor=\"end\">\(route.ended.formatted(date: .omitted, time: .shortened))</text><text x=\"0\" y=\"\(top + 8)\">\(Int(ceiling)) ms</text>"
        return """
        <svg class="chart" viewBox="0 0 \(Int(width)) \(Int(height))" preserveAspectRatio="none" style="height:110px">
        <line x1="0" y1="\(height - bottom)" x2="\(width)" y2="\(height - bottom)" stroke="#d9d9e3"/>\(shade)<path d="\(path)" fill="none" stroke="#2f80e0" stroke-width="2"/>\(labels)</svg>
        """
    }
}
