import Foundation

public struct SpeedTestUpdate: Sendable {
    public enum Phase: String, Sendable { case latency, download, upload, complete }
    public let phase: Phase
    public let fraction: Double
    public let megabits: Double?
    public let bytes: Int
}

public enum SpeedTest {
    /// Bounded to 64 MB down + 16 MB up. Short tests explicitly report inconclusive bloat.
    public static func run(maximumBytes: Int = 80_000_000, updates: @escaping @Sendable (SpeedTestUpdate) -> Void = { _ in }, progress: @escaping @Sendable (String) -> Void) async throws -> SpeedTestResult {
        updates(SpeedTestUpdate(phase: .latency, fraction: 0, megabits: nil, bytes: 0))
        progress("Measuring idle latency…")
        let baseline = await DiagnosticProbe.ping("1.1.1.1", count: 5)
        try Task.checkCancellation()
        progress("Measuring download and loaded latency…")
        async let downPing = DiagnosticProbe.ping("1.1.1.1", count: 20)
        let down = try await transfer(upload: false, cap: max(1, maximumBytes * 4 / 5), updates: updates)
        let downloadLoaded = trim(await downPing, duration: down.seconds)
        try Task.checkCancellation()
        progress("Measuring upload and loaded latency…")
        async let upPing = DiagnosticProbe.ping("1.1.1.1", count: 20)
        let up = try await transfer(upload: true, cap: max(1, maximumBytes / 5), updates: updates)
        let uploadLoaded = trim(await upPing, duration: up.seconds)
        updates(SpeedTestUpdate(phase: .complete, fraction: 1, megabits: nil, bytes: down.bytes + up.bytes))
        return SpeedTestResult(date: Date(), downloadMbps: Double(down.bytes) * 8 / down.seconds / 1_000_000,
                               uploadMbps: Double(up.bytes) * 8 / up.seconds / 1_000_000,
                               baseline: baseline, downloadLoaded: downloadLoaded, uploadLoaded: uploadLoaded,
                               downloadSeconds: down.seconds, uploadSeconds: up.seconds,
                               transferredBytes: down.bytes + up.bytes)
    }
    private static func trim(_ ping: PingResult, duration: Double) -> PingResult {
        guard let offsets = ping.sampleOffsets, offsets.count == ping.samples.count else {
            return PingResult(host: ping.host, samples: [], lossPercent: nil)
        }
        let samples = zip(ping.samples, offsets).filter { latency, offset in offset + latency / 1000 <= duration }.map(\.0)
        return PingResult(host: ping.host, samples: samples, lossPercent: nil)
    }
    private static func transfer(upload: Bool, cap: Int, updates: @escaping @Sendable (SpeedTestUpdate) -> Void) async throws -> (bytes: Int, seconds: Double) {
        let transport = SpeedTransfer()
        defer { transport.close() }
        let sampler = SpeedSampler()
        let start = Date()
        let phase: SpeedTestUpdate.Phase = upload ? .upload : .download
        updates(SpeedTestUpdate(phase: phase, fraction: 0, megabits: nil, bytes: 0))
        var bytes = 0
        var chunk = 128_000
        while Date().timeIntervalSince(start) < 8 && bytes < cap {
            try Task.checkCancellation()
            let count = min(chunk, cap - bytes)
            let url = URL(string: "https://speed.cloudflare.com/\(upload ? "__up" : "__down?bytes=\(count)&nonce=\(UUID().uuidString)")")!
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 10
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if upload {
                request.httpMethod = "POST"
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            }
            let completed = bytes
            let received = try await transport.request(request, body: upload ? Data(repeating: 0xA5, count: count) : nil) { current in
                if let rate = sampler.sample(bytes: completed + current) {
                    let fraction = min(0.99, max(Date().timeIntervalSince(start) / 8, Double(completed + current) / Double(cap)))
                    updates(SpeedTestUpdate(phase: phase, fraction: fraction, megabits: rate, bytes: completed + current))
                }
            }
            guard received == count else { throw DiagnosticError("The server returned an unexpected transfer size. Test discarded.") }
            bytes += received
            let elapsed = max(0.001, Date().timeIntervalSince(start))
            chunk = min(upload ? 1_000_000 : 4_000_000, max(64_000, Int(Double(bytes) / elapsed * 0.5)))
        }
        let seconds = max(0.001, Date().timeIntervalSince(start))
        updates(SpeedTestUpdate(phase: phase, fraction: 1, megabits: Double(bytes) * 8 / seconds / 1_000_000, bytes: bytes))
        return (bytes, seconds)
    }
}
