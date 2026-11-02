import Foundation

/// `kilobat stream`'s options: status, the check before going live, or the reports.
public struct StreamQuery: Equatable, Sendable {
    public enum Command: String, Sendable { case status, check, reports }
    public var command = Command.status
    public var json = false
    public var limit = 10
    /// The bitrate to check against, in kbps, instead of OBS's.
    public var bitrate: Int?
    /// nil: measure unless the network is metered. true measures anyway; false reads the last speed test.
    public var measure: Bool?
    public var port: UInt16?
    /// Read the OBS password from stdin, for the CLI without the app.
    public var passwordStdin = false
    public init() {}
    public static let usage = "Use stream [status|check|reports] [--json]: check [--bitrate <kbps>] [--measure|--no-measure], reports [--limit 1…200], status [--port <port>] [--password-stdin]."

    public struct Invalid: Error, Equatable { public let message: String }

    /// `args` starts with `stream`.
    public static func parse(_ args: [String]) throws -> StreamQuery {
        var query = StreamQuery(), index = 1
        if index < args.count, let command = Command(rawValue: args[index]) { query.command = command; index += 1 }
        func value(_ allowed: Bool) throws -> String {
            guard allowed, index + 1 < args.count else { throw Invalid(message: usage) }
            index += 1
            return args[index]
        }
        while index < args.count {
            switch args[index] {
            case "--json": query.json = true
            case "--limit":
                guard let limit = Int(try value(query.command == .reports)), (1...200).contains(limit) else { throw Invalid(message: usage) }
                query.limit = limit
            case "--bitrate":
                guard let kbps = Int(try value(query.command == .check)), (100...100_000).contains(kbps) else { throw Invalid(message: "The bitrate is in kbps, 100 to 100000, as OBS shows it (6000 for 6 Mbps).") }
                query.bitrate = kbps
            case "--measure", "--no-measure":
                guard query.command == .check, query.measure == nil else { throw Invalid(message: usage) }
                query.measure = args[index] == "--measure"
            case "--port":
                guard let port = UInt16(try value(query.command != .reports)), port >= 1024 else { throw Invalid(message: usage) }
                query.port = port
            case "--password-stdin":
                guard query.command != .reports else { throw Invalid(message: usage) }
                query.passwordStdin = true
            default: throw Invalid(message: usage)
            }
            index += 1
        }
        return query
    }
}
