import Foundation
import KilobatCore

/// `kilobat calls`: the report cards the app wrote after each call. Read-only; the app does the listening.
enum CallsCLI {
    static func run(_ args: [String]) throws {
        let json = args.contains("--json")
        var limit = 10
        if let index = args.firstIndex(of: "--limit") {
            guard index + 1 < args.count, let value = Int(args[index + 1]), (1...200).contains(value) else { throw CLIError("Use calls [--limit 1…200] [--json].") }
            limit = value
        }
        guard args.dropFirst().allSatisfy({ ["--json", "--limit"].contains($0) || Int($0) != nil }) else { throw CLIError("Use calls [--limit 1…200] [--json].") }
        let reports = Array(CallStore.load().suffix(limit).reversed())
        if json { print(String(decoding: try DiagnosticsCLI.encode(reports), as: UTF8.self)); return }
        guard !reports.isEmpty else {
            print("No calls yet. With the Kilobat app running, each call in Zoom, Teams, FaceTime, Slack, a browser or another calling app gets a report card when it ends.")
            return
        }
        for report in reports {
            let minutes = max(1, Int((report.seconds / 60).rounded()))
            let ping = [report.median.map { String(format: "ping %.0f ms", $0) }, report.jitter.map { String(format: "jitter %.0f ms", $0) }, String(format: "loss %.1f%%", report.lossPercent)].compactMap { $0 }.joined(separator: " · ")
            print("\(report.start.formatted(date: .abbreviated, time: .shortened))  \(report.title), \(minutes) min  \(ping)")
            print("  \(report.clean ? "✓" : "✗") \(report.verdict)")
            for freeze in report.freezes {
                print("    \(Int(freeze.at / 60)):\(String(format: "%02d", Int(freeze.at) % 60))  \(Int(freeze.seconds)) s, " + (freeze.peak.map { String(format: "worst %.0f ms", $0) } ?? "no replies") + ", \(freeze.cause.phrase)")
            }
            if let advice = report.advice { print("  \(advice)") }
        }
    }
}
