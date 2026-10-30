import Foundation
import Darwin
import KilobatCore

enum DiagnosticsCLI {
    @MainActor static func run(_ args: [String]) async throws {
        switch args[0] {
        case "diagnose":
            guard args.dropFirst().allSatisfy({ $0 == "--json" }) else { throw CLIError("Use diagnose [--json].") }
            let snapshot = await DiagnosticProbe().snapshot()
            let ssid = snapshot.radio.ssid == nil ? await WiFiCLI.appSSID() : nil
            if args.contains("--json") { print(String(decoding: try diagnoseJSON(snapshot, ssid: ssid), as: UTF8.self)) }
            else {
                let report = DiagnosticStore.report(snapshot)
                print(ssid.map { report.replacingOccurrences(of: "Network: Name unavailable (Location permission may be required)", with: "Network: " + $0) } ?? report)
            }
        case "scan":
            guard args.dropFirst().allSatisfy({ $0 == "--json" }) else { throw CLIError("Use scan [--json].") }
            let networks = try await WiFiCLI.nearbyNetworks()
            if args.contains("--json") { print(String(decoding: try scanJSON(networks), as: UTF8.self)) }
            else {
                print("Nearby Wi-Fi networks · macOS Location permission may be required\n")
                for network in networks { print("\(KilobatCLI.pad(network.ssid, 30)) \(network.rssi) dBm · Ch \(network.channel > 0 ? String(network.channel) : "—") · \(network.band == "Unknown" ? "—" : network.band) · \(network.widthMHz) MHz") }
                if networks.isEmpty { print("No networks returned. Enable Wi-Fi scanning in the Kilobat app.") }
                else if networks.allSatisfy({ $0.ssid == "Hidden network" }) { print("\nNames are hidden: macOS shows them only to apps with Location permission. Open the Kilobat app and run this again.") }
            }
        case "radar":
            guard args.dropFirst().allSatisfy({ ["--watch", "--json"].contains($0) }) else { throw CLIError("Use radar [--watch] [--json].") }
            let probe = DiagnosticProbe()
            let watch = args.contains("--watch")
            var best = 0
            let appSSID = await WiFiCLI.appSSID()
            if watch { Terminal.nonblockingInput() }
            defer { Terminal.restoreInput() }
            repeat {
                let radio = await probe.radio()
                best = max(best, radio.score ?? 0)
                if args.contains("--json") { try printJSON(RadioOutput(radio: radio, ssid: radio.ssid ?? appSSID, score: radio.score, signalNoiseRatio: radio.snr)) }
                else {
                    if watch && isatty(STDOUT_FILENO) == 1 { print("\u{1b}[2J\u{1b}[H", terminator: "") }
                    print("Kilobat Radar · \(radio.ssid ?? appSSID ?? "Wi-Fi name unavailable")")
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
                if ["--json", "--parallel", "--progress"].contains(args[index]) { index += 1; continue }
                guard args[index] == "--budget-mb", index + 1 < args.count,
                      let amount = Int(args[index + 1]), (1...80).contains(amount) else {
                    throw CLIError("Use speedtest [--parallel] [--json] [--progress] [--budget-mb 1…80]. Uses at most 80 MB by default.")
                }
                budget = amount; index += 2
            }
            let streams = args.contains("--parallel") ? SpeedTest.parallelStreams : 1
            // --progress: one JSON line per update on stderr, for tools that draw the test live.
            let live = args.contains("--progress")
            let result = try await SpeedTest.run(maximumBytes: budget * 1_000_000, streams: streams, updates: { update in
                guard live else { return }
                var line: [String: Any] = ["phase": update.phase.rawValue, "fraction": update.fraction, "bytes": update.bytes]
                if let megabits = update.megabits { line["mbps"] = megabits }
                if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) {
                    FileHandle.standardError.write(data + Data("\n".utf8))
                }
            }) { progress in
                FileHandle.standardError.write(Data((progress + "\n").utf8))
            }
            if args.contains("--json") { print(String(decoding: try speedJSON(result), as: UTF8.self)) }
            else {
                print(String(format: "↓ %.1f Mbps   ↑ %.1f Mbps", result.downloadMbps, result.uploadMbps) + "   \(result.server ?? "Cloudflare") · \(streams == 1 ? "1 connection" : "\(streams) connections")"
                      + (result.context?.vpn.map { " · through \($0)" } ?? ""))
                print("Bufferbloat: \(result.bufferbloat)")
                if let latency = result.addedLatency { print(String(format: "Added latency: %.1f ms", latency)) }
                else { print("Insufficient sustained load or ping replies for a reliable bufferbloat comparison.") }
                print("Video calls: \(result.videoReadiness)   Streaming: \(result.streamingReadiness)")
                for warning in result.callCautionReasons { print("  ! \(warning)") }
                print("\(TrafficFormat.bytes(UInt64(result.transferredBytes))) transferred to/from Cloudflare")
                print("How it measures: " + SpeedTest.method(streams: result.streams))
            }
        case "dns":
            guard args.count <= 2 else { throw CLIError("Use dns [automatic|cloudflare|google|quad9|flush]. Changes require administrator approval.") }
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
    /// `ssid` fills in the name macOS hides from the CLI, as the running app reports it.
    static func diagnoseJSON(_ snapshot: DiagnosticSnapshot, ssid: String? = nil) throws -> Data {
        try encode(DiagnosticOutput(measurements: snapshot, ssid: snapshot.radio.ssid ?? ssid, health: snapshot.health.rawValue, advice: snapshot.advice, signalScore: snapshot.radio.score, signalNoiseRatio: snapshot.radio.snr,
                                    routerLatencyMs: snapshot.router?.average, internetLatencyMs: snapshot.internet.average, internetJitterMs: snapshot.internet.jitter))
    }
    /// Scan results with unmeasured noise, channel and band as null, so agents never compute SNR against 0 dBm.
    static func scanJSON(_ networks: [NearbyNetwork]) throws -> Data {
        try encode(networks.map { ScanOutput(id: $0.id, ssid: $0.ssid, rssi: $0.rssi, noise: $0.noise == 0 ? nil : $0.noise, channel: $0.channel > 0 ? $0.channel : nil,
                                             band: $0.band == "Unknown" ? nil : $0.band, widthMHz: $0.widthMHz) })
    }
    static func speedJSON(_ result: SpeedTestResult) throws -> Data {
        try encode(SpeedOutput(measurements: result, bufferbloat: result.bufferbloat, addedLatencyMs: result.addedLatency,
                               idleLatencyMs: result.baseline.average, jitterMs: result.baseline.jitter,
                               voiceCalls: result.voiceReadiness, videoCalls: result.videoReadiness, streaming: result.streamingReadiness, agents: result.agentReadiness,
                               callWarnings: result.callCautionReasons, method: SpeedTest.method(streams: result.streams)))
    }
    static func setDNS(_ name: String) async throws -> (DNSProvider, String) {
        guard let provider = DNSProvider.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }), let service = await DiagnosticProbe().snapshot().networkService else {
            throw CLIError("Choose automatic, cloudflare, google or quad9 on an active network service.")
        }
        try await DNSService.set(provider, service: service)
        return (provider, service)
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    private static func printJSON<T: Encodable>(_ value: T) throws { print(String(decoding: try encode(value), as: UTF8.self)) }
    private struct DiagnosticOutput: Encodable {
        let measurements: DiagnosticSnapshot
        let ssid: String?
        let health: String
        let advice: [String]
        let signalScore: Int?
        let signalNoiseRatio: Int?
        let routerLatencyMs: Double?
        let internetLatencyMs: Double?
        let internetJitterMs: Double?
    }
    private struct ScanOutput: Encodable {
        let id: String, ssid: String, rssi: Int, noise: Int?, channel: Int?, band: String?, widthMHz: Int
        enum CodingKeys: CodingKey { case id, ssid, rssi, noise, channel, band, widthMHz }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id); try container.encode(ssid, forKey: .ssid); try container.encode(rssi, forKey: .rssi)
            try container.encode(noise, forKey: .noise); try container.encode(channel, forKey: .channel); try container.encode(band, forKey: .band); try container.encode(widthMHz, forKey: .widthMHz)
        }
    }
    private struct RadioOutput: Encodable {
        let radio: RadioSample
        let ssid: String?
        let score: Int?
        let signalNoiseRatio: Int?
    }
    private struct SpeedOutput: Encodable {
        let measurements: SpeedTestResult
        let bufferbloat: String
        let addedLatencyMs: Double?
        let idleLatencyMs: Double?
        let jitterMs: Double?
        let voiceCalls: String
        let videoCalls: String
        let streaming: String
        let agents: String
        let callWarnings: [String]
        let method: String
    }
}
