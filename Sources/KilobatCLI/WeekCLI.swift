import Foundation
import KilobatCore

/// `kilobat week`: the weekly digest, as the app's Monday notification tells it, from what Kilobat keeps on this Mac.
/// Read-only. The CLI is free, so causes show as they do in `kilobat calls`; there is no Pro line.
enum WeekCLI {
    static func digest(weeksAgo: Int, now: Date = Date()) -> WeeklyDigest {
        let defaults = KilobatCLI.appDefaults
        let week = WeekOptions(weeksAgo: weeksAgo).week(schedule: DigestSchedule.load(defaults), now: now)
        return WeeklyDigest.make(DigestInput.saved(defaults: defaults, now: now), week: week, pro: true, now: now)
    }

    static func run(_ args: [String]) throws {
        let options: WeekOptions
        do { options = try WeekOptions.parse(args) } catch { throw CLIError(error.localizedDescription) }
        let digest = digest(weeksAgo: options.weeksAgo)
        if options.json { print(String(decoding: try DiagnosticsCLI.encode(digest), as: UTF8.self)); return }
        print(Terminal.bold("Week of \(digest.range)"))
        if digest.empty {
            print("Nothing recorded that week. With the Kilobat app running, it keeps outages, calls, data use and Protection's blocks for this.")
            return
        }
        if digest.partial { print(Terminal.dim("Kilobat's history starts partway through this week.")) }
        if let summary = digest.summary { print("  ✓ \(summary)") }
        for fact in digest.facts {
            let line = fact.line.prefix(1).uppercased() + fact.line.dropFirst()
            print("  \(fact.problem ? "✗" : "·") \(line)" + (fact.comparison.map { Terminal.dim(" (\($0))") } ?? ""))
            if let detail = fact.detail, !detail.isEmpty { print(Terminal.dim("    \(detail)")) }
        }
        let schedule = DigestSchedule.load(KilobatCLI.appDefaults)
        if schedule.enabled, options.weeksAgo == 0 {
            let day = Calendar.current.weekdaySymbols[schedule.weekday - 1]
            print(Terminal.dim("\nThe app sends this every \(day) at \(schedule.hour):00 (Settings › Monitoring › Weekly digest)."))
        }
    }
}
