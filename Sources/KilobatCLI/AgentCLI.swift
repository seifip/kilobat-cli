import Foundation
import Darwin
import KilobatCore

/// `agent-event`: an agent's own hook tells the app that a run started, is working, waits for the person, or is done.
/// Hooks run it on every turn, and some read its output, so it is quick, silent and always exits 0: a broken hook must never break the agent.
@MainActor enum AgentCLI {
    static let usage = "Use agent-event <start|working|waiting|done|failed> [--agent name] [--session id] [--cwd path] [--message text] [--stdin-json|--json-arg] [--verbose]."

    static func run(_ args: [String]) async {
        let verbose = args.contains("--verbose")
        // stderr, never stdout: Claude Code and Codex add a hook's stdout to the model's context.
        func say(_ text: String) { if verbose { FileHandle.standardError.write(Data("kilobat: \(text)\n".utf8)) } }
        var options = Array(args.dropFirst()), payload: [String: Any]?
        // Codex `notify` appends its JSON as the last argument.
        if options.contains("--json-arg"), let last = options.last, last.hasPrefix("{") { options.removeLast(); payload = object(Data(last.utf8)) }
        if options.contains("--stdin-json"), isatty(STDIN_FILENO) == 0 { payload = object(readInput()) }
        var kind: String?, values: [String: String] = [:], index = 0
        while index < options.count {
            let option = options[index]
            switch option {
            case "--agent", "--session", "--cwd", "--message":
                guard index + 1 < options.count else { return say("\(option) needs a value. " + usage) }
                values[option] = options[index + 1]; index += 2
            case "--stdin-json", "--json-arg", "--verbose": index += 1
            case _ where kind == nil && !option.hasPrefix("-"): kind = option; index += 1
            default: return say("Unexpected '\(option)'. " + usage)
            }
        }
        let hook = payload.map(AgentEvent.Hook.init)
        let event: AgentEvent.Kind
        if let hook, let name = hook.event {
            guard let mapped = hook.kind else { return say("Nothing to record: \(name) says nothing about the run's state.") }
            event = mapped
        } else {
            guard let kind, let parsed = AgentEvent.Kind(rawValue: kind) else { return say(usage) }
            event = parsed
        }
        let process = agentProcess()
        guard let agent = nonEmpty(values["--agent"]) ?? process?.name else { return say("Name the agent with --agent, e.g. --agent claude.") }
        // The agent's process lets the app count its traffic towards this run.
        let pid = process.flatMap { AgentCatalog.name($0.name) == (AgentCatalog.name(agent) ?? agent) ? $0.pid : nil }
        let session = nonEmpty(values["--session"]) ?? hook?.session
        let cwd = nonEmpty(values["--cwd"]) ?? hook?.cwd ?? FileManager.default.currentDirectoryPath
        let message = (nonEmpty(values["--message"]) ?? hook?.message).map { String($0.replacingOccurrences(of: "\n", with: " ").prefix(200)) }
        // Over-long ids are dropped rather than cut, so two runs never end up sharing one.
        let record = AgentEvent(kind: event, agent: agent, session: session.flatMap { $0.count <= 128 ? $0 : nil },
                                cwd: cwd.count <= 1024 ? cwd : nil, message: message, pid: pid)
        guard record.valid, let json = try? JSONEncoder().encode(record) else { return say("The agent name must be 1 to 40 characters.") }
        let label = "\(event.rawValue) for \(AgentCatalog.name(agent) ?? agent)" + (record.session.map { " · session \($0)" } ?? "") + (record.cwd.map { " · " + $0 } ?? "")
        // An app too old to know agent events doesn't answer, so the event waits for a newer one.
        if await AppRelay.ask("agent|" + String(decoding: json, as: UTF8.self), timeout: .milliseconds(500)) != nil { return say("Sent \(label) to the Kilobat app.") }
        do {
            try AgentEventSpool.append(record)
            say("The Kilobat app isn't running or didn't answer. Saved \(label) for when it opens, in \(AgentEventSpool.file.path).")
        } catch { say("The Kilobat app didn't take the event, and it couldn't be saved: \(error.localizedDescription)") }
    }

    private static func nonEmpty(_ text: String?) -> String? { text.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
    private static func object(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }

    /// A hook's JSON, up to 4 MB; Claude Code's Stop payload carries the last reply, which can be long.
    private static func readInput() -> Data {
        var data = Data()
        while data.count < 4_000_000, let chunk = try? FileHandle.standardInput.read(upToCount: 65_536), !chunk.isEmpty { data.append(chunk) }
        return data
    }

    /// The nearest ancestor that is a known agent: the hook's shell runs under Claude Code or Codex.
    static func agentProcess() -> (pid: Int32, name: String)? {
        var pid = getppid()
        for _ in 0..<8 where pid > 1 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
            let name = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let short = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if let match = [name, short].first(where: { AgentCatalog.name($0) != nil }) { return (pid, match) }
            pid = Int32(info.pbi_ppid)
        }
        return nil
    }
}
