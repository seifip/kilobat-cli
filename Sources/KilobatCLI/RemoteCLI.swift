import Foundation
import KilobatCore

/// `kilobat remote`: the reports the app wrote after SSH, Mosh and remote desktop sessions. Read-only; the app measures.
enum RemoteCLI {
    static func run(_ args: [String]) throws {
        let query: RemoteSessionQuery
        do { query = try RemoteSessionQuery.parse(args) } catch let invalid as RemoteSessionQuery.Invalid { throw CLIError(invalid.message) }
        let reports = query.select(RemoteSessionStore.load())
        if query.json { print(String(decoding: try DiagnosticsCLI.encode(reports.map(RemoteSessionReport.Exported.init)), as: UTF8.self)); return }
        guard !reports.isEmpty else {
            print("No remote sessions yet. With the Kilobat app running, each ssh or mosh typed into for over a minute, and each Screen Sharing, Parsec, Jump Desktop, Windows App, AnyDesk, TeamViewer or RustDesk session, gets a report when it ends.")
            return
        }
        for report in reports {
            let minutes = max(1, Int((report.seconds / 60).rounded()))
            let to = report.measured == .host ? "rtt" : "internet"
            let line = [report.median.map { String(format: "\(to) %.0f ms", $0) }, report.jitter.map { String(format: "jitter %.0f ms", $0) }, String(format: "loss %.1f%%", report.lossPercent)].compactMap { $0 }.joined(separator: " · ")
            print("\(report.start.formatted(date: .abbreviated, time: .shortened))  \(report.title), \(minutes) min  \(line)")
            print("  \(report.clean ? "✓" : "✗") \(report.verdict)")
            for lag in report.lags {
                let worst = lag.cause.kind == .remoteSlow ? "input unanswered" : lag.peak.map { String(format: "worst %.0f ms", $0) } ?? "no replies"
                print("    \(Int(lag.at / 60)):\(String(format: "%02d", Int(lag.at) % 60))  \(Int(lag.seconds.rounded())) s, \(worst), \(lag.cause.phrase(host: report.place))")
            }
            if let advice = report.advice { print("  \(advice)") }
            if let mosh = report.mosh { print("  \(mosh)") }
        }
    }
}
