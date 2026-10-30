import Foundation

public struct SpeedTestUpdate: Sendable {
    public enum Phase: String, Sendable { case latency, download, upload, complete }
    public let phase: Phase
    public let fraction: Double
    public let megabits: Double?
    public let bytes: Int
}

public enum SpeedTest {
    /// Connections the parallel test opens at once.
    public static let parallelStreams = 4

    /// Bounded to 64 MB down + 16 MB up, shared across streams. Short tests explicitly report inconclusive bloat.
    /// `streams` 1 is one HTTPS request at a time; more open that many at once, as most speed-test sites do.
    public static func run(maximumBytes: Int = 80_000_000, streams: Int = 1, updates: @escaping @Sendable (SpeedTestUpdate) -> Void = { _ in }, progress: @escaping @Sendable (String) -> Void) async throws -> SpeedTestResult {
        let streams = min(max(streams, 1), 8)
        updates(SpeedTestUpdate(phase: .latency, fraction: 0, megabits: nil, bytes: 0))
        progress(String(localized: "Measuring idle latency…"))
        async let exit = ExitPath.current()
        async let radio = DiagnosticProbe().radio()
        let baseline = await DiagnosticProbe.ping("1.1.1.1", count: 5)
        var context = SpeedTestContext(exit: await exit, radio: await radio)
        let before = InterfaceCounters.read()
        try Task.checkCancellation()
        progress(streams == 1 ? String(localized: "Measuring download and loaded latency…") : String(localized: "Measuring download over \(streams) connections and loaded latency…"))
        async let downPing = DiagnosticProbe.ping("1.1.1.1", count: 20)
        let down = try await transfer(upload: false, cap: max(1, maximumBytes * 4 / 5), streams: streams, updates: updates)
        let downloadLoaded = trim(await downPing, duration: down.seconds)
        try Task.checkCancellation()
        progress(streams == 1 ? String(localized: "Measuring upload and loaded latency…") : String(localized: "Measuring upload over \(streams) connections and loaded latency…"))
        async let upPing = DiagnosticProbe.ping("1.1.1.1", count: 20)
        let up = try await transfer(upload: true, cap: max(1, maximumBytes / 5), streams: streams, updates: updates)
        let uploadLoaded = trim(await upPing, duration: up.seconds)
        updates(SpeedTestUpdate(phase: .complete, fraction: 1, megabits: nil, bytes: down.bytes + up.bytes))
        if let before, let after = InterfaceCounters.read() { context.otherBytes = otherBytes(before: before, after: after, test: down.bytes + up.bytes) }
        var result = SpeedTestResult(date: Date(), downloadMbps: Double(down.bytes) * 8 / down.seconds / 1_000_000,
                                     uploadMbps: Double(up.bytes) * 8 / up.seconds / 1_000_000,
                                     baseline: baseline, downloadLoaded: downloadLoaded, uploadLoaded: uploadLoaded,
                                     downloadSeconds: down.seconds, uploadSeconds: up.seconds,
                                     transferredBytes: down.bytes + up.bytes)
        result.streams = streams
        result.server = (down.dataCenter ?? up.dataCenter).map { "Cloudflare " + $0 } ?? "Cloudflare"
        result.context = context
        return result
    }

    /// What the network ports carried during the test beyond the test itself. Physical ports only, so a VPN's tunnel isn't counted twice.
    static func otherBytes(before: [String: ByteCount], after: [String: ByteCount], test: Int) -> Int {
        let moved = after.reduce(UInt64(0)) { total, entry in
            guard InterfaceCounters.physical(entry.key, scope: "external", wifi: []), let start = before[entry.key] else { return total }
            return total + (entry.value - start).total
        }
        return max(0, Int(clamping: moved) - test)
    }

    /// "8a1b2c3d4e5f6789-FRA" → "FRA".
    static func dataCenter(_ ray: String) -> String? {
        guard let dash = ray.lastIndex(of: "-") else { return nil }
        let code = ray[ray.index(after: dash)...]
        return code.count == 3 && code.allSatisfy(\.isLetter) ? code.uppercased() : nil
    }

    /// How Kilobat's test measures, and why another speed test can show a different number.
    public static func method(streams: Int?) -> String {
        let how = (streams ?? 1) > 1
            ? String(localized: "\(streams!) HTTPS connections at once to Cloudflare’s nearest data center, 8 seconds each way and at most 80 MB in all.")
            : String(localized: "One HTTPS connection at a time to Cloudflare’s nearest data center, 8 seconds each way and at most 80 MB.")
        return how + " " + String(localized: "Latency is a ping to 1.1.1.1 before and during the transfers.")
    }
    public static let otherTests = String(localized: "Speedtest by Ookla, fast.com and macOS’s networkQuality open several connections at once, pick their own servers and run until the speed settles, so on fast or distant links they usually show more than one connection gets. One connection is closer to what a single download gets; several are closer to what the link can carry. Run both here to see how much that matters on your connection.")

    private static func trim(_ ping: PingResult, duration: Double) -> PingResult {
        guard let offsets = ping.sampleOffsets, offsets.count == ping.samples.count else {
            return PingResult(host: ping.host, samples: [], lossPercent: nil)
        }
        let samples = zip(ping.samples, offsets).filter { latency, offset in offset + latency / 1000 <= duration }.map(\.0)
        return PingResult(host: ping.host, samples: samples, lossPercent: nil)
    }

    /// The streams share one byte budget and one progress total.
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var reserved = 0
        private var completed = 0
        private var inFlight: [Int: Int] = [:]
        let cap: Int
        init(cap: Int) { self.cap = cap }
        /// Up to `wanted` bytes of what's left of the budget; nil once it's spent.
        func reserve(_ wanted: Int) -> Int? {
            lock.withLock {
                let count = min(wanted, cap - reserved)
                guard count > 0 else { return nil }
                reserved += count; return count
            }
        }
        func progress(_ stream: Int, _ bytes: Int) -> Int { lock.withLock { inFlight[stream] = bytes; return completed + inFlight.values.reduce(0, +) } }
        func complete(_ stream: Int, _ bytes: Int) { lock.withLock { inFlight[stream] = 0; completed += bytes } }
    }

    private static func transfer(upload: Bool, cap: Int, streams: Int, updates: @escaping @Sendable (SpeedTestUpdate) -> Void) async throws -> (bytes: Int, seconds: Double, dataCenter: String?) {
        let sampler = SpeedSampler(), tally = Tally(cap: cap)
        let start = Date()
        let phase: SpeedTestUpdate.Phase = upload ? .upload : .download
        updates(SpeedTestUpdate(phase: phase, fraction: 0, megabits: nil, bytes: 0))
        let (bytes, dataCenter) = try await withThrowingTaskGroup(of: (Int, String?).self) { group in
            for stream in 0..<streams {
                group.addTask {
                    let transport = SpeedTransfer()
                    defer { transport.close() }
                    var bytes = 0, chunk = max(64_000, 128_000 / streams)
                    while Date().timeIntervalSince(start) < 8, let count = tally.reserve(chunk) {
                        try Task.checkCancellation()
                        let url = URL(string: "https://speed.cloudflare.com/\(upload ? "__up" : "__down?bytes=\(count)&nonce=\(UUID().uuidString)")")!
                        var request = URLRequest(url: url)
                        request.cachePolicy = .reloadIgnoringLocalCacheData
                        request.timeoutInterval = 10
                        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                        if upload {
                            request.httpMethod = "POST"
                            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                        }
                        let received = try await transport.request(request, body: upload ? Data(repeating: 0xA5, count: count) : nil) { current in
                            let total = tally.progress(stream, current)
                            if let rate = sampler.sample(bytes: total) {
                                let fraction = min(0.99, max(Date().timeIntervalSince(start) / 8, Double(total) / Double(cap)))
                                updates(SpeedTestUpdate(phase: phase, fraction: fraction, megabits: rate, bytes: total))
                            }
                        }
                        guard received == count else { throw DiagnosticError(String(localized: "The server returned an unexpected transfer size. Test discarded.")) }
                        tally.complete(stream, received)
                        bytes += received
                        let elapsed = max(0.001, Date().timeIntervalSince(start))
                        chunk = min(upload ? 1_000_000 : 4_000_000, max(64_000, Int(Double(bytes) / elapsed * 0.5)))
                    }
                    return (bytes, transport.dataCenter)
                }
            }
            var total = 0, dataCenter: String?
            for try await (bytes, center) in group { total += bytes; dataCenter = dataCenter ?? center }
            return (total, dataCenter)
        }
        let seconds = max(0.001, Date().timeIntervalSince(start))
        updates(SpeedTestUpdate(phase: phase, fraction: 1, megabits: Double(bytes) * 8 / seconds / 1_000_000, bytes: bytes))
        return (bytes, seconds, dataCenter)
    }
}
