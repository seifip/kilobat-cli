import Foundation

public struct ResolverProgress: Identifiable, Sendable {
    public var id: String { resolver }
    public let resolver: String
    public var samples: [Double?] = []
    public var domain: String? = nil
    public var finished = false
    public var replies: Int { samples.compactMap { $0 }.count }
    public var average: Double? { let times = samples.compactMap { $0 }; return times.isEmpty ? nil : times.reduce(0, +) / Double(times.count) }
    public init(resolver: String) { self.resolver = resolver }
}
public enum ResolverBenchmark {
    public static let resolvers = ["System", "1.1.1.1", "8.8.8.8", "9.9.9.9"]
    public static let domains = ["example.com", "apple.com", "cloudflare.com"]
    public static func parse(_ result: CommandResult) -> Double? {
        guard result.status == 0, result.output.contains("status: NOERROR"),
              let count = DiagnosticProbe.matches(#"ANSWER: (\d+)"#, in: result.output).first.flatMap(Int.init), count > 0,
              let time = DiagnosticProbe.matches(#"Query time: (\d+) msec"#, in: result.output).first.flatMap(Double.init) else { return nil }
        return time
    }
    public static func run(progress: @escaping @Sendable (ResolverProgress) async -> Void = { _ in }) async -> [ResolverTiming] {
        await withTaskGroup(of: ResolverTiming.self) { group in
            for resolver in resolvers {
                group.addTask {
                    var row = ResolverProgress(resolver: resolver)
                    for domain in domains {
                        guard !Task.isCancelled else { break }
                        row.domain = domain; await progress(row)
                        var args = ["+tries=1", "+time=2", "+stats", domain, "A"]
                        if resolver != "System" { args.insert("@" + resolver, at: 0) }
                        let response = await CommandRunner.run("/usr/bin/dig", args, timeout: 3)
                        guard !Task.isCancelled else { break }
                        row.samples.append(parse(response)); await progress(row)
                    }
                    row.domain = nil; row.finished = true; await progress(row)
                    return ResolverTiming(resolver: resolver, milliseconds: row.average, replies: row.replies)
                }
            }
            var results: [ResolverTiming] = []
            for await row in group { results.append(row) }
            return results.sorted { ($0.milliseconds ?? .infinity) < ($1.milliseconds ?? .infinity) }
        }
    }
}
