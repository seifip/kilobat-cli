import Foundation
import KilobatCore
import os

/// `kilobat trace` and `kilobat route-history`'s watch views: one trace, several, or a watch that re-traces on an interval.
@MainActor enum TraceCLI {
    static let usage = """
    Use trace <host> [--rounds 2…10] [--protocol udp|icmp] [--max-hops 1…64] [--size 60…1500] [--json],
    or trace <host> --watch [--interval 5s] [--for 15m] [--alert] [--json|--csv]: interval 1–60 s, up to 4 h; Ctrl-C stops early.
    """
    /// Ctrl-C during a watch ends it cleanly instead of killing the process mid-save.
    private static let interrupted = OSAllocatedUnfairLock(initialState: false)

    /// "5s", "15m", "2h" or plain seconds.
    static func seconds(_ text: String) -> Double? {
        let lower = text.lowercased()
        let units: [(String, Double)] = [("ms", 0.001), ("s", 1), ("m", 60), ("h", 3600)]
        for (suffix, scale) in units where lower.hasSuffix(suffix) {
            guard let value = Double(lower.dropLast(suffix.count)), value > 0 else { return nil }
            return value * scale
        }
        return Double(lower).flatMap { $0 > 0 ? $0 : nil }
    }

    static func value(_ args: [String], _ flag: String) throws -> String? {
        guard let index = args.firstIndex(of: flag) else { return nil }
        guard index + 1 < args.count else { throw CLIError(usage) }
        return args[index + 1]
    }

    static func options(_ args: [String]) throws -> TraceOptions {
        switch TraceOptions.parse(protocol: try value(args, "--protocol"), maxHops: try value(args, "--max-hops"), size: try value(args, "--size")) {
        case .success(let options): return options
        case .failure(let error): throw CLIError(error.message)
        }
    }

    static func json<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    /// A watch and what it shows, as `--json` prints it and MCP returns it.
    struct WatchReport: Encodable {
        let watch: Summary
        let history: RouteHistory
        let destination: Destination
        struct Summary: Encodable {
            let id: UUID, host: String, label: String?, address: String?, started: Date, ended: Date?, end: String?
            let intervalSeconds: Double, durationSeconds: Double?, rounds: Int, options: TraceOptions, routeChanges: [Date]
        }
        struct Destination: Encodable {
            let answers: Bool, lossPercent: Double?, medianMs: Double?, worstMs: Double?
        }
        init(_ watch: WatchedRoute) {
            let replies = watch.rounds.compactMap { watch.destinationMs($0) }.sorted()
            self.watch = Summary(id: watch.id, host: watch.host, label: watch.label, address: watch.address, started: watch.started, ended: watch.ended, end: watch.end?.rawValue,
                                 intervalSeconds: watch.interval, durationSeconds: watch.duration, rounds: watch.rounds.count, options: watch.options, routeChanges: RouteTimeline.changes(in: watch))
            history = RouteHistory(watch: watch)
            let answers = watch.destinationAnswers
            destination = Destination(answers: answers, lossPercent: answers && !watch.rounds.isEmpty ? Double(watch.rounds.count - replies.count) / Double(watch.rounds.count) * 100 : nil,
                                      medianMs: replies.isEmpty ? nil : replies[replies.count / 2], worstMs: replies.last)
        }
    }

    static func run(_ args: [String]) async throws {
        let flags: Set<String> = ["--rounds", "--json", "--csv", "--watch", "--interval", "--for", "--alert", "--protocol", "--max-hops", "--size"]
        let valued: Set<String> = ["--rounds", "--interval", "--for", "--protocol", "--max-hops", "--size"]
        let rest = try ExpertCLI.positional(args, flags, valued: valued)
        guard rest.count == 1, let host = rest.first else { throw CLIError(usage) }
        let options = try options(args)
        let journal = SurveyJournal()
        if args.contains("--watch") { try await watch(host: host, args: args, options: options, journal: journal); return }
        guard !args.contains("--csv"), !args.contains("--interval"), !args.contains("--for"), !args.contains("--alert") else { throw CLIError("--interval, --for, --alert and --csv go with --watch. " + usage) }
        var rounds = 1
        if let text = try value(args, "--rounds") {
            guard let count = Int(text), (2...10).contains(count) else { throw CLIError(usage) }
            rounds = count
        }
        if rounds == 1 && !args.contains("--json") {
            let result = try await ExpertTools.route(to: host, options: options); journal.saveRoute(host: host, output: result); print(result); return
        }
        try await ExpertTools.routeRounds(to: host, rounds: rounds, options: options) { output in
            journal.saveRoute(host: host, output: output)
            FileHandle.standardError.write(Data("Trace \(journal.routes.filter { $0.host == host }.count) saved.\n".utf8))
        }
        let history = RouteHistory(host: host, routes: journal.routes, watches: journal.watches)
        if args.contains("--json") { try json(history) } else { print(history.text) }
    }

    static func watch(host: String, args: [String], options: TraceOptions, journal: SurveyJournal) async throws {
        guard !args.contains("--rounds") else { throw CLIError("--rounds and --watch don't go together. " + usage) }
        guard !(args.contains("--json") && args.contains("--csv")) else { throw CLIError("Choose --json or --csv.") }
        let interval = try value(args, "--interval").map { text -> Double in
            guard let value = seconds(text), (1...60).contains(value) else { throw CLIError("Use an --interval from 1s to 60s.") }
            return value
        } ?? 5
        let duration = try value(args, "--for").map { text -> Double in
            guard let value = seconds(text), value >= interval, value <= 4 * 3600 else { throw CLIError("Use --for from the interval up to 4h, such as 15m.") }
            return value
        } ?? 900
        let alerts = args.contains("--alert")
        interrupted.withLock { $0 = false }
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { interrupted.withLock { $0 = true } }
        source.resume()
        defer { source.cancel(); signal(SIGINT, SIG_DFL) }
        let log = FileHandle.standardError
        log.write(Data("Watching \(host) every \(Self.duration(interval)) for \(Self.duration(duration)) (\(options.summary)). Ctrl-C stops.\n".utf8))
        var latch = RouteAlertLatch(), saved = Date.distantPast
        let rule = RouteAlertRule.standard
        let watch = try await ExpertTools.watchRoute(host: host, options: options, interval: interval, duration: duration,
                                                     stop: { interrupted.withLock { $0 } ? .stopped : nil }) { watch in
            guard let round = watch.rounds.last, watch.running else { return }
            let time = watch.date(round).formatted(date: .omitted, time: .standard)
            let destination = watch.destinationMs(round).map { "destination \(Int($0.rounded())) ms" } ?? (watch.destinationAnswers ? "destination: no reply" : "destination hasn't answered")
            log.write(Data("\(time)  \(round.ms.count) hops  \(destination)\n".utf8))
            let trouble = rule.trouble(in: watch)
            if latch.update(trouble, at: round.t, rule: rule), alerts, let trouble {
                log.write(Data("\u{7}! \(RouteAlertRule.message(trouble, watch: watch, history: RouteHistory(watch: watch)).body)\n".utf8))
            }
            if Date().timeIntervalSince(saved) >= 60 { saved = Date(); journal.saveWatch(watch) }
        }
        journal.saveWatch(watch)
        if let line = watch.endLine { log.write(Data("\(line) after \(watch.rounds.count) rounds. Saved; see kilobat route-history --watch \(watch.id.uuidString.prefix(8)).\n".utf8)) }
        if watch.end == .failed { throw CLIError("traceroute got no answer from \(host). Check the name, or try --protocol icmp.") }
        if args.contains("--csv") { print(watch.csv, terminator: ""); return }
        if args.contains("--json") { try json(WatchReport(watch)); return }
        print(text(watch))
    }

    /// The watch's table, its destination line and where the route changed.
    static func text(_ watch: WatchedRoute) -> String {
        let report = WatchReport(watch)
        var lines = [RouteHistory(watch: watch).text]
        if let loss = report.destination.lossPercent, let median = report.destination.medianMs {
            lines.append("Destination: median \(Int(median.rounded())) ms, \(Int(loss.rounded()))% lost over \(watch.rounds.count) rounds.")
        } else if !watch.destinationAnswers {
            lines.append("\(watch.address ?? watch.host) didn't answer traceroute probes" + (watch.options.method == .udp ? "; --protocol icmp may get through." : "."))
        }
        if !report.watch.routeChanges.isEmpty {
            lines.append("New routers appeared at " + report.watch.routeChanges.map { $0.formatted(date: .omitted, time: .standard) }.joined(separator: ", ") + ".")
        }
        return lines.joined(separator: "\n")
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds)) s" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        return String(format: "%g h", seconds / 3600)
    }

    /// `route-history --watches` and `route-history --watch <id>`.
    static func history(_ args: [String]) throws -> Bool {
        let journal = SurveyJournal()
        if args.contains("--watches") {
            try KilobatCLI.allow(args, ["--watches", "--json"])
            let rows = journal.watches.reversed().map(WatchReport.init)
            if args.contains("--json") || !Terminal.interactive { try json(rows.map(\.watch)); return true }
            if rows.isEmpty { print("No watched routes yet. Run kilobat trace <host> --watch."); return true }
            for row in rows {
                let summary = row.watch
                print("\(summary.id.uuidString.prefix(8))  \(summary.started.formatted(date: .abbreviated, time: .shortened))  \(summary.label ?? summary.host)  \(summary.rounds) rounds  \(summary.end ?? "running")")
            }
            return true
        }
        if let index = args.firstIndex(of: "--watch"), index + 1 >= args.count { throw CLIError("Use route-history --watch <id> [--json|--csv]; kilobat route-history --watches lists the ids.") }
        guard let id = try value(args, "--watch") else { return false }
        try KilobatCLI.allow(args, ["--watch", "--json", "--csv"], valued: ["--watch"])
        let matches = journal.watches.filter { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }
        guard matches.count == 1, let watch = matches.first else {
            throw CLIError(matches.isEmpty ? "No watched route \(id). List them with kilobat route-history --watches." : "\(id) matches several watches; give more of the id.")
        }
        if args.contains("--csv") { print(watch.csv, terminator: "") }
        else if args.contains("--json") { try json(WatchReport(watch)) }
        else { print(text(watch)) }
        return true
    }
}
