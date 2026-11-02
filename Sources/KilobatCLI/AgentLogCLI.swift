import Foundation
import Darwin
import KilobatCore

/// `kilobat agent-log`: every host an AI agent and the processes it started contacted, with bytes. Reads what the
/// app recorded (it records with Pro); `--watch` records here, live, for as long as it runs.
@MainActor enum AgentLogCLI {
    nonisolated(unsafe) static var interrupted = false
    static var failure: String?

    static func run(_ args: [String]) async throws {
        if args.contains("--watch") { return try await watch(args.filter { $0 != "--watch" }) }
        let query: AgentLogQuery
        do { query = try AgentLogQuery.parse(args) } catch let failure as AgentLogQuery.Failure { throw CLIError(failure.message) }
        let (recording, updated, entries) = load(query)
        if query.json {
            print(String(decoding: try DiagnosticsCLI.encode(Output(recording: recording, updated: updated, sessions: entries)), as: UTF8.self)); return
        }
        guard updated != nil else {
            print("No agent network log yet. With Kilobat Pro, the app records every host Claude Code, Codex, Cursor and other agents")
            print("contact, with the processes they start. Without it, `kilobat agent-log --watch` records live in this terminal.")
            return
        }
        if recording == false { print(Terminal.dim("The app isn't recording: the agent network log is part of Kilobat Pro. `kilobat agent-log --watch` records here.")) }
        guard !entries.isEmpty else {
            print(query.agent.map { "No sessions for \($0) in the log." } ?? (query.since == nil ? "No agent sessions in the log yet." : "No agent sessions in that period."))
            return
        }
        print("Kilobat · agent network log")
        for entry in entries { print(""); print(lines(entry, flagged: query.flagged).joined(separator: "\n")) }
    }

    struct Output: Encodable {
        /// Whether the app was recording when it last saved; nil when it never did.
        let recording: Bool?
        let updated: Date?
        let sessions: [AgentLogEntry]
    }

    /// The app's saved log, as reported, chosen by the query. The caller's own agent counts as the latest when it is in the log.
    static func load(_ query: AgentLogQuery) -> (recording: Bool?, updated: Date?, entries: [AgentLogEntry]) {
        guard let file = AgentLogFile.load() else { return (nil, nil, []) }
        let source = ProcessSource.live
        // Still running: its process is there with the same start time, and the app wrote recently.
        let running = Set(file.sessions.filter { session in
            session.end == nil && Date().timeIntervalSince(file.updated) < 120 && source.entry(session.pid).map { AgentProcessTree.key($0.pid, $0.start) == session.key } == true
        }.map(\.key))
        let entries = AgentNetworkLog.report(file.sessions, pastHosts: Set(file.pastHosts), running: running)
        return (file.recording, file.updated, query.select(entries, within: ancestors()))
    }

    /// This process's parents, nearest first: run from an agent's shell, its own session is the one asked about.
    static func ancestors() -> [Int32] {
        var pids: [Int32] = [], pid = getppid()
        while pid > 1, pids.count < 32, let entry = ProcessSource.live.entry(pid) { pids.append(pid); pid = entry.ppid }
        return pids
    }

    static func lines(_ entry: AgentLogEntry, flagged: Bool) -> [String] {
        let when = entry.start.formatted(date: .abbreviated, time: .shortened) + " – " + (entry.running ? "running" : entry.end.map { $0.formatted(date: .omitted, time: .shortened) } ?? "ended")
        let count = entry.hostCount == 1 ? "1 host" : "\(entry.hostCount) hosts"
        var out = [Terminal.bold(entry.title) + Terminal.dim("  " + when)]
        out.append(Terminal.dim("  \(count) · ↑ \(TrafficFormat.bytes(entry.sent)) ↓ \(TrafficFormat.bytes(entry.received))" + (entry.flaggedCount > 0 ? " · \(entry.flaggedCount) flagged" : "")))
        if let cwd = entry.cwd { out.append(Terminal.dim("  " + cwd)) }
        let groups = entry.processes.map { ($0.process, flagged ? $0.hosts.filter(\.flagged) : $0.hosts) }.filter { !$0.1.isEmpty }
        if groups.isEmpty { out.append("  " + (flagged ? "Nothing flagged." : "No connections recorded.")) }
        for (process, hosts) in groups {
            out.append("  " + Terminal.violet(process))
            for host in hosts {
                let mark = host.flagged ? Terminal.rose("!") : " "
                let name = host.host + (host.nameSource == "reverse" ? " (reverse DNS)" : "")
                out.append("  \(mark) \(KilobatCLI.pad(name, 36))\(KilobatCLI.pad("\(host.port)/\(host.transport)", 10))↑ \(KilobatCLI.pad(TrafficFormat.bytes(host.sent), 10))↓ \(KilobatCLI.pad(TrafficFormat.bytes(host.received), 10))\(KilobatCLI.pad("\(host.connections)×", 6))" + (host.flagged ? Terminal.rose(host.notes) : ""))
            }
        }
        if entry.unmatchedSent + entry.unmatchedReceived > 0 {
            out.append(Terminal.dim("  Also ↑ \(TrafficFormat.bytes(entry.unmatchedSent)) ↓ \(TrafficFormat.bytes(entry.unmatchedReceived)) on connections that closed before Kilobat saw where they went."))
        }
        return out
    }

    /// Records live from this terminal: Apple's nettop, read here, with no app and no Pro. Nothing is saved.
    static func watch(_ args: [String]) async throws {
        let query: AgentLogQuery
        do { query = try AgentLogQuery.parse(args) } catch let failure as AgentLogQuery.Failure { throw CLIError(failure.message) }
        if query.all || query.since != nil { throw CLIError("--watch records from now on; --all and --since read what the app recorded.") }
        let store = AgentNetworkLogStore()
        let monitor = NettopMonitor()
        monitor.start(onSample: { snapshot in Task { @MainActor in store.consume(snapshot) } },
                      onError: { error in Task { @MainActor in AgentLogCLI.failure = error } })
        signal(SIGINT) { _ in AgentLogCLI.interrupted = true }
        signal(SIGTERM) { _ in AgentLogCLI.interrupted = true }
        if !query.json { print("Watching what AI agents contact. Ctrl-C to stop; nothing is saved." + (query.agent.map { " Only \($0)." } ?? "")) }
        var printed: Set<String> = []
        while !interrupted && failure == nil {
            try? await Task.sleep(for: .milliseconds(500))
            for entry in store.report.reversed() where query.matches(entry) {
                for host in entry.hosts where (!query.flagged || host.flagged) && printed.insert(entry.id.uuidString + host.id).inserted {
                    if query.json {
                        struct Line: Encodable { let agent: String; let pid: Int32; let project: String?; let host: AgentHostSummary }
                        print(String(decoding: try DiagnosticsCLI.encode(Line(agent: entry.agent, pid: entry.pid, project: entry.project, host: host)), as: UTF8.self))
                    } else {
                        let mark = host.flagged ? Terminal.rose("! ") : "  "
                        print("\(mark)\(KilobatCLI.pad(entry.agent, 14))\(KilobatCLI.pad(host.process, 18))\(host.host):\(host.port)" + (host.flagged ? "  " + Terminal.rose(host.notes) : ""))
                    }
                    fflush(stdout)
                }
            }
        }
        monitor.stop()
        if let failure { throw CLIError(failure) }
        if !query.json {
            let entries = store.report.filter(query.matches)
            print(entries.isEmpty ? "\nNo agent traffic while watching." : "")
            for entry in entries { print(lines(entry, flagged: query.flagged).joined(separator: "\n")); print("") }
        }
    }
}
