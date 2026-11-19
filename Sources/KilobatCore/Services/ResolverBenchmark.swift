import Foundation

/// `kilobat dns-benchmark`: three lookups through the system resolver and through each resolver Fastest DNS times.
public enum ResolverBenchmark {
    public static let domains = ["example.com", "apple.com", "cloudflare.com"]
    /// "System" for the Mac's own, then the first address of each resolver in `candidates`: the one list Health's
    /// Fastest DNS uses, with the presets left in and the resolvers added in Settings.
    public static func resolvers(_ candidates: [DNSResolverChoice]) -> [String] {
        var list = ["System"]
        for choice in candidates where !choice.isNetwork { if let server = choice.servers.first, !list.contains(server) { list.append(server) } }
        return list
    }
    public static func parse(_ result: CommandResult) -> Double? {
        guard result.status == 0, result.output.contains("status: NOERROR"),
              let count = DiagnosticProbe.matches(#"ANSWER: (\d+)"#, in: result.output).first.flatMap(Int.init), count > 0,
              let time = DiagnosticProbe.matches(#"Query time: (\d+) msec"#, in: result.output).first.flatMap(Double.init) else { return nil }
        return time
    }
    public static func run(resolvers: [String]) async -> [ResolverTiming] {
        await withTaskGroup(of: ResolverTiming.self) { group in
            for resolver in resolvers {
                group.addTask {
                    var samples: [Double] = []
                    for domain in domains {
                        var args = ["+tries=1", "+time=2", "+stats", domain, "A"]
                        if resolver != "System" { args.insert("@" + resolver, at: 0) }
                        if let time = parse(await CommandRunner.run("/usr/bin/dig", args, timeout: 3)) { samples.append(time) }
                    }
                    return ResolverTiming(resolver: resolver, milliseconds: samples.isEmpty ? nil : samples.reduce(0, +) / Double(samples.count), replies: samples.count)
                }
            }
            var results: [ResolverTiming] = []
            for await row in group { results.append(row) }
            return results.sorted { ($0.milliseconds ?? .infinity) < ($1.milliseconds ?? .infinity) }
        }
    }
}
