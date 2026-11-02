import Foundation
import KilobatCore

/// `kilobat cloud-gaming`: the session the app is measuring now, and the reports after each one. Read-only; the app
/// notices the sessions.
enum CloudGamingCLI {
    static func run(_ args: [String]) async throws {
        let query: CloudGamingQuery
        do { query = try CloudGamingQuery.parse(args) } catch let invalid as CloudGamingQuery.Invalid { throw CLIError(invalid.message) }
        switch query.command {
        case .status: try await status(query)
        case .reports: try reports(query)
        }
    }

    static func app() async -> [String: Any]? {
        guard let data = await AppRelay.ask("cloud-gaming", timeout: .seconds(5)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func print(json value: Any) throws {
        Swift.print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
    }

    /// The live session's lines, as text.
    static func text(live: [String: Any]) -> [String] {
        func ms(_ key: String) -> String? { (live[key] as? Double).map { String(format: "%.0f ms", $0) } }
        var lines = ["\(live["title"] as? String ?? "Cloud game") · live \(live["minutes"] as? Int ?? 0) min"]
        let measured = live["measured"] as? String == "server" ? "to its server" : "to the internet"
        let numbers = [ms("pingMs").map { "ping \($0) \(measured)" }, ms("jitterMs").map { "jitter \($0)" },
                       (live["lossPercent"] as? Double).map { String(format: "loss %.0f%%", $0) },
                       (live["mbps"] as? Double).map { String(format: "%.0f Mbps", $0) },
                       (live["gigabytes"] as? Double).map { String(format: "%.1f GB so far", $0) }].compactMap { $0 }
        if !numbers.isEmpty { lines.append("  " + numbers.joined(separator: " · ")) }
        let issues = live["issues"] as? [[String: Any]] ?? []
        if issues.isEmpty { lines.append("  ✓ Nothing on this Mac is in the way.") }
        for issue in issues { lines.append("  ! \(issue["phrase"] as? String ?? ""). \(issue["advice"] as? String ?? "")") }
        if let data = live["data"] as? String { lines.append("  " + data) }
        return lines
    }

    static func status(_ query: CloudGamingQuery) async throws {
        guard let app = await app() else {
            if query.json { try print(json: ["source": "none", "playing": false, "error": "The Kilobat app isn't running."]); return }
            Swift.print("The Kilobat app isn't running. It notices cloud gaming sessions and measures them; open it, then play.")
            if let last = CloudGamingStore.load().last { Swift.print("Last session: \(last.title), \(last.start.formatted(date: .abbreviated, time: .shortened)): \(last.verdict)") }
            return
        }
        if query.json { try print(json: app.merging(["source": "app"]) { $1 }); return }
        guard app["enabled"] as? Bool == true else {
            Swift.print("Cloud gaming reports are off. Turn on Settings › Streaming › Cloud gaming reports in the Kilobat app.")
            return
        }
        if let live = app["live"] as? [String: Any] {
            for line in text(live: live) { Swift.print(line) }
            let paused = (app["airDropPaused"] as? Bool == true ? ["AirDrop"] : []) + (app["holding"] as? [String] ?? [])
            if !paused.isEmpty { Swift.print("  Paused until you stop playing: \(paused.formatted(.list(type: .and))).") }
        } else {
            Swift.print("No cloud gaming session right now. Kilobat notices GeForce NOW, Boosteroid and Shadow in their Mac apps, and GeForce NOW, Xbox Cloud Gaming, Amazon Luna, Boosteroid and Shadow in a browser.")
            if let last = CloudGamingStore.load().last { Swift.print("Last session: \(last.title), \(last.start.formatted(date: .abbreviated, time: .shortened)): \(last.verdict)") }
        }
    }

    static func reports(_ query: CloudGamingQuery) throws {
        let reports = Array(CloudGamingStore.load().suffix(query.limit).reversed())
        if query.json { Swift.print(String(decoding: try DiagnosticsCLI.encode(reports.map(CloudGamingReport.Exported.init)), as: UTF8.self)); return }
        guard !reports.isEmpty else {
            Swift.print("No cloud gaming sessions yet. With the Kilobat app running, each GeForce NOW, Xbox Cloud Gaming, Boosteroid, Amazon Luna or Shadow session over two minutes gets a report when it ends.")
            return
        }
        for report in reports { for line in text(report) { Swift.print(line) } }
    }

    static func text(_ report: CloudGamingReport) -> [String] {
        let minutes = max(1, Int((report.seconds / 60).rounded()))
        let numbers = [report.median.map { String(format: "ping %.0f ms", $0) }, report.jitter.map { String(format: "jitter %.0f ms", $0) },
                       String(format: "loss %.1f%%", report.lossPercent), report.averageMbps.map { String(format: "%.0f Mbps", $0) },
                       CloudGamingData.format(Double(report.bytes))].compactMap { $0 }.joined(separator: " · ")
        var lines = ["\(report.start.formatted(date: .abbreviated, time: .shortened))  \(report.title), \(minutes) min  \(numbers)",
                     "  \(report.clean ? "✓" : "✗") \(report.verdict)"]
        if report.stutters.count > 1 { lines += report.stutters.map { "    " + report.sentence($0) } }
        if report.metered, let data = report.data { lines.append("  \(data)") }
        if let mac = report.macDetail { lines.append("  \(mac)") }
        if let advice = report.advice { lines.append("  \(advice)") }
        return lines
    }
}
