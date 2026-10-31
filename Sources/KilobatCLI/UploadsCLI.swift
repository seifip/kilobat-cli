import Foundation
import KilobatCore

/// `uploads`: apps uploading a lot right now and the ones held for a better network, from the running app, which
/// measures each app's uploads. `uploads hold` and `uploads resume` ask the app to hold or let go.
@MainActor enum UploadsCLI {
    static func run(_ args: [String]) async throws {
        let parsed: (command: UploadsCommand, json: Bool)
        do { parsed = try UploadsCommand.parse(Array(args.dropFirst())) } catch let error as UploadError { throw CLIError(error.message) }
        switch parsed.command {
        case .list:
            let report = await report()
            if parsed.json { try WiFiCLI.printObject(try object(report)); return }
            print(lines(report).joined(separator: "\n"))
        case .hold(let app, let until):
            let result = try await change(hold: app, until: until)
            if parsed.json { try WiFiCLI.printObject(result); return }
            guard result["held"] as? Bool == true else { throw CLIError(result["error"] as? String ?? "Kilobat couldn’t hold \(app).") }
            let how = result["method"] as? String == "block" ? "its new connections wait" : "paused"
            print("✓ \(result["name"] as? String ?? app) held \(result["until"] as? String ?? ""), \(how). Send it now with kilobat uploads resume \"\(result["app"] as? String ?? app)\".")
        case .resume(let app):
            let result = try await change(resume: app)
            if parsed.json { try WiFiCLI.printObject(result); return }
            guard result["resumed"] as? Bool == true else { throw CLIError("Nothing called \(app) is held.") }
            print("✓ \(app) can upload again.")
        }
    }

    /// The running app's report; without the app, an empty one that says so.
    static func report() async -> UploadsReport {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let data = await AppRelay.ask("uploads", timeout: .seconds(3)), let report = try? decoder.decode(UploadsReport.self, from: data) { return report }
        return UploadsReport(appRunning: false, thresholdBytesPerSecond: SendLater.floorRate, uploads: [])
    }

    /// Asks the app to hold `app` or to `resume` one; the reply carries the report after the change.
    static func change(hold app: String? = nil, until: String? = nil, resume: String? = nil) async throws -> [String: Any] {
        let action = app.map { "uploads|hold|\($0)|\(until ?? "auto")" } ?? "uploads|resume|\(resume ?? "")"
        guard AppRelay.appRunning else { throw CLIError("Send later needs the Kilobat app running: it measures each app’s uploads and resumes them. Open it with kilobat open.") }
        guard let data = await AppRelay.ask(action, timeout: .seconds(5)), var value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError("The Kilobat app didn’t answer. Update it to the latest version, or try again.")
        }
        if let report = value["report"], let data = try? JSONSerialization.data(withJSONObject: report) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode(UploadsReport.self, from: data) { value["report"] = try object(decoded) }
        }
        return value
    }

    /// The report's JSON, with null where a value isn't known.
    static func object(_ report: UploadsReport) throws -> [String: Any] {
        var value = try JSONSerialization.jsonObject(with: try DiagnosticsCLI.encode(report)) as? [String: Any] ?? [:]
        for key in ["network", "metered", "uplinkMbps", "filterActive", "pro"] where value[key] == nil { value[key] = NSNull() }
        value["uploads"] = (value["uploads"] as? [[String: Any]] ?? []).map { entry in
            var entry = entry
            for key in ["totalBytes", "doneBytes", "file", "etaSeconds", "reason", "until", "heldOn", "resumesBy"] where entry[key] == nil { entry[key] = NSNull() }
            return entry
        }
        return value
    }

    static func lines(_ report: UploadsReport) -> [String] {
        guard report.appRunning else {
            return ["Kilobat · uploads", "  Open the Kilobat app: it measures each app’s uploads and holds the ones you send later."]
        }
        let network = [report.network, report.metered.map { $0 ? "metered" : "unmetered" }, report.uplinkMbps.map { String(format: "%.0f Mbps up measured", $0) }]
            .compactMap { $0 }.joined(separator: " · ")
        var lines = ["Kilobat · uploads", "  " + network, "  Big upload: \(TrafficFormat.rate(report.thresholdBytesPerSecond)) or more for 20 seconds", ""]
        if report.uploads.isEmpty { lines.append("  No app is uploading a lot right now, and nothing is held.") }
        for entry in report.uploads {
            let detail: String
            if entry.state == "held" {
                detail = "held \(entry.until?.phrase ?? "") · \(TrafficFormat.bytes(entry.sentBytes)) sent before" + (entry.heldOn.map { " · held on \($0)" } ?? "")
                    + (entry.resumesBy.map { " · resumes by \($0.formatted(date: .omitted, time: .shortened)) at the latest" } ?? "")
            } else if let total = entry.totalBytes, let done = entry.doneBytes, let eta = entry.etaSeconds {
                detail = "\(TrafficFormat.rate(entry.bytesPerSecond)) · \(TrafficFormat.bytes(done)) of \(TrafficFormat.bytes(total))" + (entry.file.map { " (\($0))" } ?? "")
                    + " · about \(Duration.seconds(eta).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))) left"
            } else {
                detail = "\(TrafficFormat.rate(entry.bytesPerSecond)) · \(TrafficFormat.bytes(entry.sentBytes)) so far"
            }
            lines.append("  \(KilobatCLI.pad(entry.name, 16))\(detail)")
            guard entry.state != "held" else { continue }
            let indent = "  " + KilobatCLI.pad("", 16)
            switch entry.method {
            case .suspend: lines.append(Terminal.dim(indent + "kilobat uploads hold \"\(entry.app)\" pauses it"))
            case .block: lines.append(Terminal.dim(indent + "kilobat uploads hold \"\(entry.app)\" refuses its new connections (needs the network filter)"))
            case .none: lines.append(Terminal.dim(indent + (entry.reason ?? "Shown only.")))
            }
        }
        if report.pro == false { lines += ["", "  Holding uploads is part of Kilobat Pro."] }
        lines += ["", Terminal.dim(report.limits)]
        return lines
    }
}
