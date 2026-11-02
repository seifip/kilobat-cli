import Foundation
import KilobatCore

/// `kilobat history forget <host> [--subdomains]` and `history clear --hour|--today|--all`: the histories that name
/// hosts (Blocked attempts, the agent network log, agent runs' destinations, Protection's notification memory).
/// The running app holds them in memory and would write them back, so it does the erasing; otherwise the files change here.
@MainActor enum HistoryCLI {
    struct Output: Encodable {
        let action: String
        let host: String?
        let subdomains: Bool?
        let range: String?
        /// Whether the running app did it; false when the files changed directly.
        let byApp: Bool
        let removed: HistoryChange
        let total: Int
    }

    static func run(_ args: [String]) async throws {
        let command: HistoryCommand
        do { command = try HistoryCommand.parse(args) } catch let failure as HistoryCommand.Failure { throw CLIError(failure.message) }
        let output = try await perform(command)
        let json: Bool
        switch command { case .clear(_, let flag), .forget(_, let flag): json = flag || Terminal.piped }
        if json { print(String(decoding: try DiagnosticsCLI.encode(output), as: UTF8.self)); return }
        let what = output.host.map { "Forgot \($0)" + (output.subdomains == true ? " and its subdomains" : "") } ?? "Cleared \(output.range == "all" ? "everything" : output.range == "today" ? "today" : "the last hour")"
        let parts = [("blocked attempts", output.removed.blockedAttempts), ("agent network log hosts", output.removed.agentLogHosts),
                     ("agent run destinations", output.removed.sessionDestinations), ("notification records", output.removed.notices)]
            .filter { $0.1 > 0 }.map { "\($0.1) \($0.0)" }
        print("✓ " + what + ": " + (parts.isEmpty ? "nothing matched." : parts.joined(separator: ", ") + "."))
    }

    static func perform(_ command: HistoryCommand) async throws -> Output {
        let change: HistoryChange, byApp: Bool
        if AppRelay.appRunning {
            guard let data = await AppRelay.ask(command.relayAction) else {
                throw CLIError("Kilobat is running but didn't answer. Update the app, or use Clear and Forget in the app.")
            }
            if let failure = try? JSONDecoder().decode([String: String].self, from: data), let message = failure["error"] {
                throw CLIError("History could not be fully cleared: " + message)
            }
            guard let answer = try? JSONDecoder().decode(HistoryChange.self, from: data) else {
                throw CLIError("Kilobat returned an invalid history reply. Use Clear and Forget in the app.")
            }
            change = answer; byApp = true
        } else {
            change = try HostHistoryFiles.erase(command.action, appDefaults: KilobatCLI.appDefaults); byApp = false
        }
        switch command {
        case .clear(let range, _): return Output(action: "clear", host: nil, subdomains: nil, range: range.rawValue, byApp: byApp, removed: change, total: change.total)
        case .forget(let match, _): return Output(action: "forget", host: match.host, subdomains: match.subdomains, range: nil, byApp: byApp, removed: change, total: change.total)
        }
    }
}
