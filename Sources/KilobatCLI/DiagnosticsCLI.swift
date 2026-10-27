import Foundation
import Darwin
import KilobatCore

enum DiagnosticsCLI {
    @MainActor static func run(_ args: [String]) async throws {
        switch args[0] {
        case "diagnose":
            guard args.dropFirst().allSatisfy({ $0 == "--json" }) else { throw CLIError("Use diagnose [--json].") }
            let snapshot = await DiagnosticProbe().snapshot()
            if args.contains("--json") { print(String(decoding: try diagnoseJSON(snapshot), as: UTF8.self)) }
            else { print(DiagnosticStore.report(snapshot)) }
        case "scan":
            guard args.dropFirst().allSatisfy({ $0 == "--json" }) else { throw CLIError("Use scan [--json].") }
            let networks = try await DiagnosticProbe().scan()
            if args.contains("--json") { try printJSON(networks) }
            else {
                print("Nearby Wi-Fi networks · macOS Location permission may be required\n")
                for network in networks { print("\(KilobatCLI.pad(network.ssid, 30)) \(network.rssi) dBm · Ch \(network.channel) · \(network.band) · \(network.widthMHz) MHz") }
                if networks.isEmpty { print("No networks returned. Enable Wi-Fi scanning in the Kilobat app.") }
            }
        case "radar":
            guard args.dropFirst().allSatisfy({ ["--watch", "--json"].contains($0) }) else { throw CLIError("Use radar [--watch] [--json].") }
            let probe = DiagnosticProbe()
            let watch = args.contains("--watch")
            var best = 0
            let previousFlags = fcntl(STDIN_FILENO, F_GETFL)
            if watch { _ = fcntl(STDIN_FILENO, F_SETFL, previousFlags | O_NONBLOCK) }
            defer { if watch { _ = fcntl(STDIN_FILENO, F_SETFL, previousFlags) } }
            repeat {
                let radio = await probe.radio()
                best = max(best, radio.score ?? 0)
                if args.contains("--json") { try printJSON(RadioOutput(radio: radio, score: radio.score, signalNoiseRatio: radio.snr)) }
                else {
                    if watch && isatty(STDOUT_FILENO) == 1 { print("\u{1b}[2J\u{1b}[H", terminator: "") }
                    print("Kilobat Radar · \(radio.ssid ?? "Wi-Fi name unavailable")")
                    print("Signal \(radio.rssi.map { "\($0) dBm" } ?? "unavailable") · SNR \(radio.snr.map { "\($0) dB" } ?? "unavailable")")
                    print("Score \(radio.score.map(String.init) ?? "—")/100 · Best \(best)")
                    print(best - (radio.score ?? best) >= 10 ? "Go back — the previous spot was stronger." : "Walk around to compare signal. q + Return to exit.")
                }
                fflush(stdout)
                if watch {
                    var input = [UInt8](repeating: 0, count: 32)
                    let count = read(STDIN_FILENO, &input, input.count)
                    if count == 0 || (count > 0 && input.prefix(count).contains(113)) { break }
                    try await Task.sleep(for: .milliseconds(250))
                }
            } while watch
        case "speedtest":
            var budget = 80
            var index = 1
            while index < args.count {
                if args[index] == "--json" { index += 1; continue }
                guard args[index] == "--budget-mb", index + 1 < args.count,
                      let amount = Int(args[index + 1]), (1...80).contains(amount) else {
                    throw CLIError("Use speedtest [--json] [--budget-mb 1…80]. Uses at most 80 MB by default.")
                }
                budget = amount; index += 2
            }
            let result = try await SpeedTest.run(maximumBytes: budget * 1_000_000) { progress in
                FileHandle.standardError.write(Data((progress + "\n").utf8))
            }
            if args.contains("--json") { print(String(decoding: try speedJSON(result), as: UTF8.self)) }
            else {
                print(String(format: "↓ %.1f Mbps   ↑ %.1f Mbps", result.downloadMbps, result.uploadMbps))
                print("Bufferbloat: \(result.bufferbloat)")
                if let latency = result.addedLatency { print(String(format: "Added latency: %.1f ms", latency)) }
                else { print("Insufficient sustained load or ping replies for a reliable bufferbloat comparison.") }
                print("\(TrafficFormat.bytes(UInt64(result.transferredBytes))) transferred to/from Cloudflare")
            }
        case "dns":
            guard args.count <= 2 else { throw CLIError("Use dns [automatic|cloudflare|google|flush]. Changes require administrator approval.") }
            if args.count == 2 && args[1] == "flush" {
                try await NetworkTools.flushDNS(); print("✓ DNS cache flushed."); return
            }
            if args.count == 1 { print("Resolvers: " + (await DiagnosticProbe().snapshot()).dnsServers.joined(separator: ", ")); return }
            let (provider, service) = try await setDNS(args[1])
            print("✓ \(service) now uses \(provider.rawValue) DNS.")
        default: throw CLIError("Unknown diagnostics command.")
        }
    }
    // The --json shapes below are shared with `kilobat mcp`, so agents see the same fields either way.
    static func diagnoseJSON(_ snapshot: DiagnosticSnapshot) throws -> Data {
        try encode(DiagnosticOutput(measurements: snapshot, health: snapshot.health.rawValue, advice: snapshot.advice, signalScore: snapshot.radio.score, signalNoiseRatio: snapshot.radio.snr,
                                    routerLatencyMs: snapshot.router?.average, internetLatencyMs: snapshot.internet.average, internetJitterMs: snapshot.internet.jitter))
    }
    static func speedJSON(_ result: SpeedTestResult) throws -> Data {
        try encode(SpeedOutput(measurements: result, bufferbloat: result.bufferbloat, addedLatencyMs: result.addedLatency))
    }
    static func setDNS(_ name: String) async throws -> (DNSProvider, String) {
        guard let provider = DNSProvider.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }), let service = await DiagnosticProbe().snapshot().networkService else {
            throw CLIError("Choose automatic, cloudflare, or google on an active network service.")
        }
        try await DNSService.set(provider, service: service)
        return (provider, service)
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    private static func printJSON<T: Encodable>(_ value: T) throws { print(String(decoding: try encode(value), as: UTF8.self)) }
    private struct DiagnosticOutput: Encodable {
        let measurements: DiagnosticSnapshot
        let health: String
        let advice: [String]
        let signalScore: Int?
        let signalNoiseRatio: Int?
        let routerLatencyMs: Double?
        let internetLatencyMs: Double?
        let internetJitterMs: Double?
    }
    private struct RadioOutput: Encodable {
        let radio: RadioSample
        let score: Int?
        let signalNoiseRatio: Int?
    }
    private struct SpeedOutput: Encodable {
        let measurements: SpeedTestResult
        let bufferbloat: String
        let addedLatencyMs: Double?
    }
}
