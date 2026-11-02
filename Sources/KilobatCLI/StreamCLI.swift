import Foundation
import KilobatCore

/// `kilobat stream`: OBS as the app sees it, the check before going live, and the reports after each stream.
enum StreamCLI {
    static func run(_ args: [String]) async throws {
        let query: StreamQuery
        do { query = try StreamQuery.parse(args) } catch let invalid as StreamQuery.Invalid { throw CLIError(invalid.message) }
        switch query.command {
        case .status: try await status(query)
        case .check: try await check(query)
        case .reports: reports(query)
        }
    }

    /// The app's view of OBS: the connection with the Keychain's password, a stream in progress, the bitrate.
    static func app() async -> [String: Any]? {
        guard let data = await AppRelay.ask("stream", timeout: .seconds(8)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func print(json value: Any) throws {
        Swift.print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
    }

    static func status(_ query: StreamQuery) async throws {
        if !query.passwordStdin, query.port == nil, let app = await app() {
            if query.json { try print(json: app.merging(["source": "app"]) { $1 }); return }
            guard app["enabled"] as? Bool == true else {
                Swift.print("Stream reports are off. Turn on Settings › Streaming › Stream reports from OBS in the Kilobat app, or run kilobat stream check before going live.")
                return
            }
            switch app["connection"] as? String {
            case "connected": Swift.print("OBS connected (WebSocket \(app["obsWebSocketVersion"] as? String ?? "5"), port \(app["port"] ?? 4455))")
            case "failed": Swift.print("OBS not connected: \(app["error"] as? String ?? "unknown error")")
            default: Swift.print("Looking for OBS on port \(app["port"] ?? 4455)…")
            }
            if let live = app["live"] as? [String: Any] {
                let dropped = live["droppedFrames"] as? Int ?? 0, total = live["totalFrames"] as? Int ?? 0
                Swift.print("Streaming since \(app["since"] as? String ?? "?"): \(dropped) of \(total) frames dropped (network, \(StreamReport.format(live["droppedPercent"] as? Double ?? 0)))"
                            + ((app["bitrateKbps"] as? Int).map { ", bitrate \($0) kbps" } ?? ""))
                if let encoder = live["encoderSkippedFrames"] as? Int, let render = live["renderSkippedFrames"] as? Int {
                    Swift.print("OBS's own counters since it started: \(encoder) skipped to encoding lag, \(render) missed to rendering lag")
                }
            } else {
                Swift.print("Not streaming." + ((app["bitrateKbps"] as? Int).map { " OBS's bitrate: \($0) kbps." } ?? ""))
            }
            if let holding = app["holding"] as? [String], !holding.isEmpty { Swift.print("Call mode for streams holds \(holding.formatted(.list(type: .and))).") }
            return
        }
        // Without the app: OBS directly, with a password from stdin when it has one.
        let password = query.passwordStdin ? readLine(strippingNewline: true) : nil
        let client = OBSClient(port: query.port ?? OBSProtocol.defaultPort, password: password)
        do { try await client.connect() } catch let error as OBSError {
            if query.json { try print(json: ["source": "obs", "connection": "failed", "errorKind": error.kind.rawValue, "error": error.message]); return }
            throw CLIError(error.message + (error.kind == .passwordNeeded ? " Pipe it in: kilobat stream status --password-stdin." : ""))
        }
        defer { Task { await client.disconnect() } }
        let status = try await client.streamStatus()
        let stats = try? await client.stats()
        let bitrate = await client.bitrate()
        if query.json {
            var value: [String: Any] = ["source": "obs", "connection": "connected", "obsWebSocketVersion": await client.version ?? NSNull(), "streaming": status.active,
                                        "bitrateKbps": bitrate ?? NSNull(), "congestion": status.congestion, "droppedFrames": status.skippedFrames, "totalFrames": status.totalFrames,
                                        "reconnecting": status.reconnecting]
            if let stats { value["encoderSkippedFrames"] = stats.encoderSkipped; value["renderSkippedFrames"] = stats.renderSkipped }
            try print(json: value); return
        }
        Swift.print("OBS connected (WebSocket \(await client.version ?? "5")). The Kilobat app isn't running, so no report is being written.")
        Swift.print(status.active ? "Streaming: \(status.skippedFrames) of \(status.totalFrames) frames dropped (network)." : "Not streaming.")
        if let bitrate { Swift.print("Bitrate: \(bitrate) kbps") }
    }

    /// The check, as the CLI and the MCP server run it: the bitrate from the flag, the app, the last report or OBS; a
    /// short upload test unless the network is metered (or `measure` says otherwise); the app's busy apps.
    @MainActor static func readiness(bitrate given: Int?, measure: Bool?, allowMetered: Bool = false) async -> StreamReadiness {
        let app = await app()
        var bitrate = given, source: String? = given == nil ? nil : "given"
        if bitrate == nil, let value = app?["bitrateKbps"] as? Int { bitrate = value; source = "obs" }
        if bitrate == nil, let value = app?["lastBitrateKbps"] as? Int ?? StreamStore.load().last(where: { $0.bitrate != nil })?.bitrate { bitrate = value; source = "lastStream" }
        if bitrate == nil, app == nil {
            let client = OBSClient(password: nil)
            if (try? await client.connect(timeout: .seconds(2))) != nil, let value = await client.bitrate() { bitrate = value; source = "obs" }
            await client.disconnect()
        }
        let metered: Bool
        if let value = app?["metered"] as? Bool { metered = value }
        else {
            let store = TrafficStore(startMonitoring: false)
            metered = WiFiCLI.currentCost(store, app: await WiFiCLI.connection()).metered(os: await AwakeCLI.currentPath().expensive)
        }
        var history: (mbps: Double, date: Date)?
        if let mbps = app?["uplinkMbps"] as? Double, let date = (app?["uplinkDate"] as? String).flatMap(ISO8601DateFormatter().date) { history = (mbps, date) }
        else if let last = NetworkJournal().speedTests.last, Date().timeIntervalSince(last.result.date) < 7 * 86_400 {
            history = (last.result.uploadMbps, last.result.date)
        }
        let busy = (app?["busy"] as? [[String: Any]] ?? []).compactMap { entry -> Preflight.Issue? in
            guard let name = entry["app"] as? String, !name.isEmpty else { return nil }
            return Preflight.Issue(kind: .app, app: name, uploading: entry["uploading"] as? Bool)
        }
        // Never on a metered network unless asked: --measure, or the MCP's allow_metered after asking the user.
        let go = measure ?? (!metered || allowMetered)
        return await StreamCheck.run(bitrate: bitrate, bitrateSource: source, measure: go, history: history, metered: metered, busy: busy)
    }

    static func check(_ query: StreamQuery) async throws {
        if !query.json { FileHandle.standardError.write(Data("Checking your upload for about eight seconds…\n".utf8)) }
        let check = await readiness(bitrate: query.bitrate, measure: query.measure)
        if query.json { Swift.print(String(decoding: try DiagnosticsCLI.encode(StreamReadiness.Exported(check)), as: UTF8.self)); return }
        Swift.print("\(check.ready ? "✓" : "!") \(check.headline)")
        Swift.print("  \(check.summary)")
        for note in check.notes { Swift.print("  \(note)") }
        let line = [check.latency.map { String(format: "ping %.0f ms", $0) }, check.jitter.map { String(format: "jitter %.0f ms", $0) }, check.lossPercent.map { String(format: "loss %.1f%%", $0) }].compactMap { $0 }
        if !line.isEmpty { Swift.print("  " + line.joined(separator: " · ")) }
        if check.bitrate == nil { Swift.print("  OBS's bitrate is unknown: pass --bitrate <kbps>, or turn on stream reports in the app.") }
    }

    static func reports(_ query: StreamQuery) {
        let reports = Array(StreamStore.load().suffix(query.limit).reversed())
        if query.json { Swift.print(String(decoding: (try? DiagnosticsCLI.encode(reports.map(StreamReport.Exported.init))) ?? Data("[]".utf8), as: UTF8.self)); return }
        guard !reports.isEmpty else {
            Swift.print("No streams yet. Turn on Settings › Streaming › Stream reports from OBS in the Kilobat app; each OBS stream over a minute gets a report when it ends.")
            return
        }
        for report in reports {
            let minutes = max(1, Int((report.seconds / 60).rounded()))
            let line = ["network \(StreamReport.format(report.networkPercent))", "encoder \(StreamReport.format(report.encoderPercent))", "render \(StreamReport.format(report.renderPercent))",
                        report.bitrate.map { "\($0) kbps" }].compactMap { $0 }.joined(separator: " · ")
            Swift.print("\(report.start.formatted(date: .abbreviated, time: .shortened))  \(report.title), \(minutes) min  \(line)")
            Swift.print("  \(report.clean ? "✓" : "✗") \(report.verdict)")
            for drop in report.drops {
                Swift.print("    \(report.span(drop))  \(drop.frames) frames (\(StreamReport.format(drop.percent))), \(drop.source.rawValue): \(drop.cause.phrase)")
            }
            if let capacity = report.capacity { Swift.print("  \(capacity)") }
            if let side = report.obsSide { Swift.print("  \(side)") }
            if let advice = report.advice { Swift.print("  \(advice)") }
        }
    }
}
