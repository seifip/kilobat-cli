import AppKit
import Foundation
import KilobatCore

/// `kilobat verdict`: the rule inspector. Every Kilobat rule that matches a host or app, in the order the filter checks
/// them, and the one that decides; `--blocked` explains the latest blocked attempts from the filter's own record.
/// The running app answers with what only it knows (who holds an app, whether its filter runs); without it the CLI
/// reads the saved rules.
@MainActor enum VerdictCLI {
    struct Options: Equatable {
        var host: String?
        var app: String?
        var port: String?
        var direction = "outgoing"
        var blocked: Int?
        var json = false
    }

    nonisolated static let usage = "Use verdict <host> [--app <id>] [--port N] [--incoming] [--json], verdict --app <id>, or verdict --blocked [1…50]."

    nonisolated static func parse(_ args: [String]) throws -> Options {
        var options = Options(), index = 1
        func value() throws -> String {
            guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else { throw CLIError(usage) }
            index += 1; return args[index]
        }
        while index < args.count {
            switch args[index] {
            case "--json": options.json = true
            case "--app": options.app = try value()
            case "--port":
                let port = try value()
                guard let number = Int(port), (1...65_535).contains(number) else { throw CLIError("A port is a number from 1 to 65535.") }
                options.port = String(number)
            case "--incoming": options.direction = "incoming"
            case "--blocked":
                if index + 1 < args.count, let count = Int(args[index + 1]) {
                    guard (1...50).contains(count) else { throw CLIError("--blocked takes 1 to 50 attempts.") }
                    options.blocked = count; index += 1
                } else { options.blocked = 5 }
            case let other where !other.hasPrefix("-") && options.host == nil:
                let raw = URL(string: other).flatMap { $0.scheme == nil ? nil : $0.host } ?? other
                guard let host = HostName.normalize(raw) else { throw CLIError("'\(other)' isn't a host name, IP address or URL.") }
                options.host = host
            default: throw CLIError("Unexpected '\(args[index])'. " + usage)
            }
            index += 1
        }
        // Relay arguments are separated by |, so neither part may hold one.
        if options.app?.contains("|") == true { throw CLIError("An app ID can't contain |.") }
        if options.blocked != nil, options.host != nil || options.app != nil { throw CLIError(usage) }
        if options.blocked == nil, options.host == nil, options.app == nil { throw CLIError(usage) }
        return options
    }

    static func run(_ args: [String]) async throws {
        let options = try parse(args)
        if let count = options.blocked {
            let inspections = await blocked(count)
            if options.json { print(String(decoding: try FirewallCLI.encode(Array(inspections)), as: UTF8.self)); return }
            if inspections.isEmpty { print("No blocked attempts recorded. They appear once Kilobat's network filter is on and blocks something."); return }
            for inspection in inspections {
                let when = inspection.date?.formatted(date: .abbreviated, time: .standard) ?? ""
                print(Terminal.dim(when) + "  " + subject(inspection))
                print(text(inspection, indent: "  ") + "\n")
            }
            return
        }
        let inspection = await inspect(host: options.host, app: options.app, port: options.port, direction: options.direction)
        if options.json { print(String(decoding: try FirewallCLI.encode(inspection), as: UTF8.self)); return }
        print(subject(inspection))
        print(text(inspection, indent: ""))
    }

    /// Asks the running app first: it knows who holds an app (Send later, call mode, a stream) and whether its filter runs.
    static func inspect(host: String?, app: String?, port: String?, direction: String) async -> RuleInspection {
        let action = "verdict|" + [app ?? "", host ?? "", port ?? "", direction].joined(separator: "|")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let data = await AppRelay.ask(action, timeout: .seconds(3)), let inspection = try? decoder.decode(RuleInspection.self, from: data) { return inspection }
        return await localInspector(apps: [app].compactMap { $0 }).inspect(host: host, port: port, app: app, direction: direction)
    }

    /// The latest blocked attempts, newest first, each with the filter's own trace when it recorded one.
    static func blocked(_ count: Int) async -> [RuleInspection] {
        let events = FilterEventJournal().events.sorted { $0.date > $1.date }.prefix(count)
        let inspector = await localInspector(apps: events.map(\.app))
        return events.map { inspector.inspect($0) }
    }

    /// The saved rules, plus what the app's relay says about the budget, quotas, the kill switch and the filter.
    static func localInspector(apps: [String] = []) async -> RuleInspector {
        let policy = await AwakeCLI.policy(), app = await WiFiCLI.connection()
        var context = RuleContext(filterActive: app == nil ? nil : policy.filterActive)
        for id in Set(apps) { context.names[id] = displayName(id) }
        return RuleInspector(preferences: policy.preferences, budgetReached: policy.budgetReached, quotaReached: app?["quotaReached"] as? [String] ?? [],
                             metered: policy.metered, killSwitch: policy.killSwitch, protection: policy.protection, index: policy.index, context: context)
    }

    /// Slack for com.tinyspeck.slackmacgap, from the installed app; nil for a command-line tool or an app that isn't here.
    static func displayName(_ id: String) -> String? {
        guard !id.hasPrefix("process:"), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func subject(_ inspection: RuleInspection) -> String {
        let destination = (inspection.host ?? inspection.address).map { $0 + (inspection.port.map { ":" + $0 } ?? "") }
        let who = inspection.appName ?? "Any app"
        return [destination.map { "\(who) → \($0)" } ?? who, inspection.direction].joined(separator: " · ")
    }

    static func text(_ inspection: RuleInspection, indent: String) -> String {
        var lines: [String] = []
        for rule in inspection.rules {
            let line: String = switch rule.role {
            case .decided: rule.verdict == .block ? Terminal.violet(rule.line) : Terminal.blue(rule.line)
            case .alsoMatched, .note: rule.line
            }
            lines.append(indent + line)
            lines.append(indent + Terminal.dim("  change: " + rule.change.label + (rule.change.command.map { " · " + $0 } ?? "")))
        }
        lines.append(indent + Terminal.dim(inspection.recorded ? "As the filter recorded it, in the order it checks rules." : "Your rules as they are now, in the order the filter checks them."))
        if let note = inspection.note { lines.append(indent + note) }
        if inspection.enforced == nil && !inspection.recorded { lines.append(indent + Terminal.dim("The Kilobat app isn't running, so holds and the filter's state aren't known.")) }
        return lines.joined(separator: "\n")
    }
}
