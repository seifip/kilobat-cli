import Foundation

/// `kilobat remote`'s options: how many reports, which kind, and JSON.
public struct RemoteSessionQuery: Equatable, Sendable {
    public enum Filter: String, Sendable, CaseIterable { case ssh, mosh, desktop }
    public var limit = 10
    public var filter: Filter?
    public var json = false
    public init() {}
    public static let usage = "Use remote [--limit 1…200] [--kind ssh|mosh|desktop] [--json]."

    public struct Invalid: Error, Equatable { public let message: String }

    /// `args` starts with `remote`.
    public static func parse(_ args: [String]) throws -> RemoteSessionQuery {
        var query = RemoteSessionQuery(), index = 1
        while index < args.count {
            switch args[index] {
            case "--json": query.json = true
            case "--limit":
                guard index + 1 < args.count, let value = Int(args[index + 1]), (1...200).contains(value) else { throw Invalid(message: usage) }
                query.limit = value; index += 1
            case "--kind":
                guard index + 1 < args.count, let value = Filter(rawValue: args[index + 1].lowercased()) else { throw Invalid(message: usage) }
                query.filter = value; index += 1
            default: throw Invalid(message: usage)
            }
            index += 1
        }
        return query
    }

    /// The newest reports first, of the kind asked for.
    public func select(_ reports: [RemoteSessionReport]) -> [RemoteSessionReport] {
        let kept = reports.filter { report in
            switch filter {
            case nil: true
            case .ssh: report.kind == .ssh
            case .mosh: report.kind == .mosh
            case .desktop: !report.kind.terminal
            }
        }
        return Array(kept.suffix(limit).reversed())
    }
}
