import Foundation
import Observation

public struct StutterSpike: Codable, Sendable, Equatable {
    /// Seconds from the start of the test.
    public let at: Double
    public let peak: Double
    public let samples: Int
}

public struct StutterResult: Codable, Sendable {
    public enum Pattern: String, Codable, Sendable { case steady, few, periodic, irregular, noReplies }
    public let date: Date
    public let target: String
    public let host: String
    public let interval: Double
    /// Milliseconds per probe in send order; nil for a lost one.
    public let samples: [Double?]
    public let p50: Double?
    public let p95: Double?
    public let p99: Double?
    public let max: Double?
    public let threshold: Double?
    public let spikes: [StutterSpike]
    public let periodSeconds: Double?
    public let pattern: Pattern
    public let awdl: AWDLStatus?
    public var received: Int { samples.compactMap { $0 }.count }
    public var lossPercent: Double { samples.isEmpty ? 0 : Double(samples.count - received) / Double(samples.count) * 100 }
    public var seconds: Double { Double(samples.count) * interval }
    public var local: Bool { target == "router" }
    /// Many routers answer only about ten pings a second: every other reply goes missing, one at a time.
    /// That is rate limiting, not loss.
    /// Its signature: a clean first second (the router's burst allowance), then gaps of one or two.
    public var pingLimited: Bool {
        let lost = samples.filter { $0 == nil }.count
        guard samples.count > 40, lost * 10 >= samples.count, lost < samples.count, !samples.prefix(20).contains(where: { $0 == nil }) else { return false }
        var runs: [Int] = [], run = 0
        for sample in samples + [0] {
            if sample == nil { run += 1 } else if run > 0 { runs.append(run); run = 0 }
        }
        return runs.filter { $0 <= 2 }.reduce(0, +) * 10 >= lost * 9
    }

    public var verdict: String {
        let peak = max.map { String(format: "%.0f ms", $0) } ?? "—"
        let loss = pingLimited ? " \(local ? "The router" : "It") answered only some of the fast pings; that's rate limiting, not lost traffic."
            : lossPercent >= 2 ? String(format: " %.0f%% of pings got no reply.", lossPercent) : ""
        let place = local ? " on your local network" : ""
        switch pattern {
        case .noReplies:
            return local ? "Your router didn't answer. Some routers ignore ping; try the internet target." : "No replies from \(host). It may not answer ping."
        case .steady:
            return (local ? "No spikes on your local network. If calls still stutter, the cause is likely beyond your network or in the app." : "No spikes. If calls still stutter, the cause is likely in the app or the service.") + loss
        case .few:
            return "A few brief spikes\(place), up to \(peak). That happens on Wi-Fi now and then and rarely explains steady stutter." + loss
        case .periodic:
            let every = periodSeconds.map(StutterTest.every) ?? "at a regular interval"
            let link: String
            if let awdl, awdl.available, !awdl.up { link = " AirDrop/AWDL was paused, so it isn't the cause here." }
            else if let awdl, awdl.up, !awdl.users.isEmpty { link = " That pattern often comes from AirDrop/AWDL scanning, and the AirDrop link was in use by \(NearbyRadios.list(awdl.users)). Try the low-latency pause and run the test again." }
            else { link = " That pattern often comes from AirDrop/AWDL scanning. Try the low-latency pause and run the test again." }
            return "Regular spikes \(every)\(place), up to \(peak)." + (local ? link : " Test your router too: if they show there, they start on your Wi-Fi.") + loss
        case .irregular:
            return "Spikes at irregular times\(place), up to \(peak). " + (local ? "A busy network, interference or weak signal is more likely than a scan cycle." : "Test your router too: if they don't show there, they come from beyond your network.") + loss
        }
    }
}

public enum StutterTest {
    public static let interval = 0.05
    public static let seconds = 10...60

    /// Linear interpolation between closest ranks.
    public static func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = p / 100 * Double(sorted.count - 1)
        let low = Int(rank.rounded(.down)), high = Int(rank.rounded(.up))
        return sorted[low] + (sorted[high] - sorted[low]) * (rank - Double(low))
    }
    public static func threshold(median: Double) -> Double { Swift.max(3 * median, 50) }
    /// A stall delays every probe sent during it, so consecutive slow replies are one spike.
    public static func spikes(_ samples: [Double?], interval: Double) -> [StutterSpike] {
        guard let median = percentile(samples.compactMap { $0 }.sorted(), 50) else { return [] }
        let limit = threshold(median: median)
        var spikes: [StutterSpike] = [], start: Int?, peak = 0.0, count = 0
        func close() { if let start { spikes.append(StutterSpike(at: Double(start) * interval, peak: peak, samples: count)) }; start = nil; peak = 0; count = 0 }
        for (index, sample) in samples.enumerated() {
            guard let sample else { continue }
            if sample > limit {
                if start == nil { start = index }
                peak = Swift.max(peak, sample); count += 1
            } else { close() }
        }
        close()
        return spikes
    }
    /// The interval a chain of spikes repeats at, if one explains at least 60% of the spikes and fills 70% of
    /// its own beats. Following the chain spike to spike absorbs drift, up to two missed beats are skipped,
    /// and strays in between don't break it. On synthetic runs: about 1% false positives on random spike
    /// times, and over 90% found for 0.5–3 s periods with 15% of beats missing.
    public static func period(_ times: [Double]) -> Double? {
        guard times.count >= 5 else { return nil }
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        let rounded = gaps.filter { $0 >= 0.2 }.map { ($0 / 0.05).rounded() * 0.05 }
        let candidates = Set(rounded + [percentile(gaps.sorted(), 50) ?? 0]).filter { $0 >= 0.2 }.sorted()
        var best: (beats: Int, coverage: Double, period: Double)?
        for period in candidates {
            let tolerance = Swift.max(0.08, period * 0.12)
            func next(after last: Double) -> Double? {
                for step in 1...3 {
                    let target = last + Double(step) * period
                    if let hit = times.filter({ $0 > last && abs($0 - target) <= tolerance }).min(by: { abs($0 - target) < abs($1 - target) }) { return hit }
                }
                return nil
            }
            for start in times {
                var chain = [start]
                while let hit = next(after: chain[chain.count - 1]) { chain.append(hit) }
                let span = chain[chain.count - 1] - start, beats = (span / period).rounded() + 1
                let coverage = Double(chain.count) / beats
                guard chain.count >= 5, Double(chain.count) >= 0.6 * Double(times.count), coverage >= 0.7 else { continue }
                if let current = best, (chain.count, coverage) <= (current.beats, current.coverage) { continue }
                best = (chain.count, coverage, span / (beats - 1))
            }
        }
        return best?.period
    }
    public static func every(_ seconds: Double) -> String {
        abs(seconds - 1) < 0.15 ? "about every second" : String(format: seconds < 10 ? "about every %.1f s" : "about every %.0f s", seconds)
    }
    public static func analyze(_ samples: [Double?], target: String, host: String, interval: Double = interval, awdl: AWDLStatus? = nil, date: Date = Date()) -> StutterResult {
        let sorted = samples.compactMap { $0 }.sorted()
        let spikes = spikes(samples, interval: interval)
        let period = period(spikes.map(\.at))
        let pattern: StutterResult.Pattern = sorted.isEmpty ? .noReplies : spikes.isEmpty ? .steady : period != nil ? .periodic : spikes.count < 3 ? .few : .irregular
        return StutterResult(date: date, target: target, host: host, interval: interval, samples: samples,
                             p50: percentile(sorted, 50), p95: percentile(sorted, 95), p99: percentile(sorted, 99), max: sorted.last,
                             threshold: percentile(sorted, 50).map(threshold), spikes: spikes, periodSeconds: period, pattern: pattern, awdl: awdl)
    }
    /// One slot per probe, filled by icmp_seq; duplicates and late strays outside the run are ignored.
    public static func parse(_ output: String, count: Int) -> [Double?] {
        var samples = [Double?](repeating: nil, count: count)
        for line in output.split(separator: "\n") where line.contains("icmp_seq=") && !line.contains("DUP") {
            guard let seq = DiagnosticProbe.matches("icmp_seq=([0-9]+)", in: String(line)).first.flatMap(Int.init), seq < count,
                  let time = DiagnosticProbe.matches("time=([0-9.]+) ms", in: String(line)).first.flatMap(Double.init) else { continue }
            samples[seq] = time
        }
        return samples
    }
    public static func host(for target: String) async throws -> String {
        switch target {
        case "router":
            let route = await CommandRunner.run("/sbin/route", ["-n", "get", "default"])
            guard let gateway = DiagnosticProbe.matches("gateway:\\s+([^\\s]+)", in: route.output).first else { throw DiagnosticError("No router found. Connect to a network, or test the internet instead.") }
            return gateway
        case "internet": return "1.1.1.1"
        default:
            guard !target.hasPrefix("-"), !target.isEmpty, target.allSatisfy({ $0.isLetter || $0.isNumber || ".-:".contains($0) }) else { throw DiagnosticError("Use router, internet, or a host name or IP address.") }
            return target
        }
    }
    /// /sbin/ping sends every 50 ms without root on current macOS (only intervals under 2 ms need it).
    /// If an older ping refuses, it falls back to 100 ms over the same time.
    public static func run(target: String, seconds: Int = 20) async throws -> StutterResult {
        let host = try await host(for: target), seconds = Swift.min(Swift.max(seconds, Self.seconds.lowerBound), Self.seconds.upperBound)
        async let before = NearbyRadios.awdlStatus()
        var interval = Self.interval
        var count = Int(Double(seconds) / interval)
        var result = await ping(host, count: count, interval: interval)
        if result.output.contains("too short") {
            interval = 0.1; count = seconds * 10
            result = await ping(host, count: count, interval: interval)
        }
        if result.status != 0 && !result.output.contains("icmp_seq") && result.output.contains("ping:") {
            throw DiagnosticError(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var awdl = await before
        let after = await NearbyRadios.awdlStatus()
        awdl.up = awdl.up && after.up; awdl.active = awdl.active || after.active
        for user in after.users where !awdl.users.contains(user) { awdl.users.append(user) }
        awdl.processes = Array(Set(awdl.processes + after.processes)).sorted()
        return analyze(parse(result.output, count: count), target: target, host: host, interval: interval, awdl: awdl)
    }
    private static func ping(_ host: String, count: Int, interval: Double) async -> CommandResult {
        await CommandRunner.run("/sbin/ping", ["-n", "-c", String(count), "-i", String(interval), "-W", "1000", host], timeout: Double(count) * interval + 5)
    }
    public static func comparison(before: StutterResult, after: StutterResult) -> String {
        let was = before.spikes.count, now = after.spikes.count
        let worst = { (result: StutterResult) in result.max.map { String(format: "%.0f ms", $0) } ?? "—" }
        if was < 3 { return "There were few spikes to begin with (\(was) before, \(now) with the pause), so this can't tell much." }
        if now <= was / 3 { return "With the pause on, spikes dropped from \(was) to \(now) and the worst ping from \(worst(before)) to \(worst(after)). Keep it on for your call or stream." }
        if now * 3 >= was * 2 { return "Spikes stayed (\(was) before, \(now) with the pause), so AirDrop/AWDL is unlikely to be the cause here. You can restore it." }
        return "Spikes went from \(was) to \(now) with the pause. Run the test once more to be sure."
    }
}

/// The Health tab's stutter test and its before/after comparison with the low-latency pause.
@MainActor @Observable public final class StutterStore {
    public var target = "router"
    public var seconds = 20
    public private(set) var running = false
    public private(set) var started: Date?
    public private(set) var result: StutterResult?
    public private(set) var before: StutterResult?
    public var error: String?
    public init() {}
    public func run() async {
        guard !running else { return }
        before = nil
        result = await measure() ?? result
    }
    public func compare(using mode: LowLatencyMode, seconds hold: TimeInterval?, app: (pid: Int32, name: String)? = nil) async {
        guard !running else { return }
        let baseline = result?.target == target ? result : await measure()
        guard let baseline else { return }
        if !mode.active {
            await mode.enable(seconds: hold, app: app)
            if let message = mode.error { mode.error = nil; error = message; return }
        }
        guard let after = await measure() else { return }
        before = baseline; result = after
    }
    private func measure() async -> StutterResult? {
        running = true; started = Date(); error = nil
        defer { running = false; started = nil }
        do { return try await StutterTest.run(target: target, seconds: seconds) }
        catch { self.error = error.localizedDescription; return nil }
    }
}
