import Foundation

/// What an agent's own hook says about its run: it started, is working, waits for the person, is done or failed.
public struct AgentEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case start, working, waiting, done, failed }
    public var kind: Kind
    /// As the hook names it (`claude`, `codex`) or as Kilobat shows it (`Claude Code`).
    public var agent: String
    public var session: String?
    public var cwd: String?
    public var message: String?
    /// The agent's process, found by walking up from the hook, so its traffic counts towards this run.
    public var pid: Int32?
    public var time: Date

    public init(kind: Kind, agent: String, session: String? = nil, cwd: String? = nil, message: String? = nil, pid: Int32? = nil, time: Date = Date()) {
        self.kind = kind; self.agent = agent; self.session = session; self.cwd = cwd; self.message = message; self.pid = pid; self.time = time
    }

    /// Anything can post to the relay, so oversize fields are rejected rather than trimmed.
    public var valid: Bool {
        !agent.isEmpty && agent.count <= 40 && session.map { !$0.isEmpty && $0.count <= 128 } != false
            && cwd.map { !$0.isEmpty && $0.count <= 1024 } != false && (message?.count ?? 0) <= 200 && (pid ?? 1) > 0
    }

    public static func decode(_ data: Data) -> AgentEvent? {
        guard data.count <= 4096, let event = try? JSONDecoder().decode(AgentEvent.self, from: data), event.valid else { return nil }
        return event
    }

    /// What a hook's JSON says: Claude Code, Codex and Gemini CLI hooks on stdin, or Codex `notify` as an argument.
    /// Only ids, folders and short status text are read; prompts and replies are not.
    public struct Hook: Equatable, Sendable {
        /// The hook's event name, nil when the JSON names none.
        public var event: String?
        /// Nil for events that say nothing about the run, such as a login notification.
        public var kind: Kind?
        public var session: String?
        public var cwd: String?
        public var message: String?

        static let kinds: [String: Kind] = ["SessionStart": .start, "UserPromptSubmit": .working, "BeforeAgent": .working,
                                            "Notification": .waiting, "PermissionRequest": .waiting,
                                            "Stop": .done, "AfterAgent": .done, "SessionEnd": .done, "agent-turn-complete": .done, "StopFailure": .failed]
        /// Claude Code's and Gemini CLI's notifications that mean the person is needed.
        static let waiting: Set<String> = ["permission_prompt", "idle_prompt", "elicitation_dialog", "ToolPermission"]

        public init(_ object: [String: Any]) {
            func text(_ key: String) -> String? { (object[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            event = text("hook_event_name") ?? text("type")
            kind = event.flatMap { Self.kinds[$0] }
            if event == "Notification", let type = text("notification_type"), !Self.waiting.contains(type) { kind = nil }
            // Claude Code stops a turn while background tasks still run; the run isn't done until they are.
            if event == "Stop", let tasks = object["background_tasks"] as? [Any], !tasks.isEmpty { kind = .working }
            session = text("session_id") ?? text("thread-id")
            cwd = text("cwd")
            message = event == "StopFailure" ? text("error_details") ?? text("error") : event == "Notification" ? text("message") : nil
            // A rate limit is a wait, not a failure. For StopFailure the last message is the API error itself, not a reply.
            let said = [message, event == "StopFailure" ? text("last_assistant_message") : nil].compactMap { $0 }.joined(separator: ". ")
            if let limit = Self.rateLimit(said, error: event == "StopFailure" ? text("error") : nil) { kind = .waiting; message = limit }
        }

        /// "Rate-limited until 3pm (Europe/Prague)" when the text clearly says so and names the reset; no guessing.
        static func rateLimit(_ text: String, error: String? = nil) -> String? {
            guard error == "rate_limit" || text.range(of: #"(?i)rate[ -]?limit|usage limit|(?:session|daily|weekly|hourly|\d+-hour) limit|too many requests"#, options: .regularExpression) != nil else { return nil }
            func capture(_ pattern: String) -> String? {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { return nil }
                return text[range].trimmingCharacters(in: .whitespaces)
            }
            if let wait = capture(#"\b(?:try again|retry|resets?) in\s+([^.;\n∙·]{1,40})"#) { return "Rate-limited for " + wait }
            if let until = capture(#"\bresets?\s+(?:at\s+|on\s+)?([^.;\n∙·]{1,60})"#) ?? capture(#"\btry again (?:at|after)\s+([^.;\n∙·]{1,60})"#) { return "Rate-limited until " + until }
            return "Rate-limited"
        }
    }
}

/// Agent events kept while the app isn't running, read once when it opens. Small and bounded: hooks fire on every turn.
public enum AgentEventSpool {
    public static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat/agent-events.jsonl")
    }
    static let maxLines = 200, maxBytes = 64_000
    /// Older events describe runs the app can no longer follow.
    static let maxAge: TimeInterval = 6 * 3600

    public static func append(_ event: AgentEvent, to file: URL = file) throws {
        guard event.valid else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = try JSONEncoder().encode(event) + Data("\n".utf8)
        // Appends are atomic for a line this small, so two hooks at once don't interleave.
        let descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let written = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        let size = written > 0 ? Int(lseek(descriptor, 0, SEEK_END)) : 0
        close(descriptor)
        guard size > maxBytes, let data = try? Data(contentsOf: file) else { return }
        // Keep the newest half so trimming doesn't happen on every append.
        let lines = data.split(separator: UInt8(ascii: "\n")).suffix(maxLines / 2)
        try Data(lines.joined(separator: [UInt8(ascii: "\n")]) + [UInt8(ascii: "\n")]).write(to: file, options: .atomic)
    }

    /// Reads and removes the spool, oldest first, dropping lines that are malformed, oversize or too old.
    public static func drain(_ file: URL = file, now: Date = Date()) -> [AgentEvent] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        try? FileManager.default.removeItem(at: file)
        return data.split(separator: UInt8(ascii: "\n")).suffix(maxLines).compactMap { AgentEvent.decode(Data($0)) }
            .filter { now.timeIntervalSince($0.time) <= maxAge && $0.time <= now.addingTimeInterval(60) }
    }
}
