import Foundation

/// `kilobat why <target>` and `kilobat doctor <target>`, parsed: kept here so the parsing can be tested.
public struct ConnectionCheckCommand: Equatable, Sendable {
    public struct Failure: Error, Equatable { public let message: String }
    public static let usage = "Use why <url|host> [--app <id>] [--proxy <url>] [--context container|vm|remote|provider] [--failed-at <time>] [--error <text>] [--json]."

    public var target: String
    public var app: String?
    public var proxy: String?
    public var context: ConnectionDoctor.Context?
    public var failedAt: Date?
    /// The error the app got, to recognise a service's own regional refusal.
    public var appError: String?
    public var json = false

    /// `args` start with the command's own name, why or doctor.
    public static func parse(_ args: [String], now: Date = Date()) throws -> ConnectionCheckCommand {
        var target: String?, command = ConnectionCheckCommand(target: ""), index = 1
        func value(_ check: (String) -> Bool, _ message: String) throws -> String {
            guard index + 1 < args.count, check(args[index + 1]) else { throw Failure(message: message) }
            defer { index += 2 }
            return args[index + 1]
        }
        while index < args.count {
            switch args[index] {
            case "--json": command.json = true; index += 1
            case "--app": command.app = try value({ $0.contains(".") || $0.hasPrefix("process:") }, "--app takes a bundle ID such as com.example.App, or process:<name>.")
            case "--proxy": command.proxy = try value({ !$0.hasPrefix("-") }, "--proxy takes the proxy the app uses, such as http://127.0.0.1:7890 or socks5://127.0.0.1:1080.")
            case "--context":
                let text = try value({ ConnectionDoctor.Context(rawValue: $0) != nil }, "--context takes container, vm, remote or provider.")
                command.context = ConnectionDoctor.Context(rawValue: text)
            case "--failed-at":
                let text = try value({ ConnectionDoctor.failureTime($0, now: now) != nil }, "--failed-at takes when the app failed, such as 14:05 or 2026-10-29T14:05:00Z, not a time still ahead.")
                command.failedAt = ConnectionDoctor.failureTime(text, now: now)
            case "--error": command.appError = try value({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }, "--error takes the error the app got, such as its message or JSON body.")
            case let value where target == nil && !value.hasPrefix("-"): target = value; index += 1
            default: throw Failure(message: usage)
            }
        }
        guard let target else { throw Failure(message: usage) }
        command.target = target
        return command
    }
}
