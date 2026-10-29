import Foundation
import KilobatCore

/// `stutter`, `airdrop` and `bluetooth`: latency spikes and the radios that share the Wi-Fi chip.
@MainActor enum NearbyCLI {
    static func run(_ args: [String]) async throws {
        let json = args.contains("--json"), rest = Array(args.filter { $0 != "--json" }.dropFirst())
        switch args[0] {
        case "stutter": try await stutter(rest, json: json)
        case "airdrop": try await airdrop(rest, json: json)
        case "bluetooth":
            guard rest.isEmpty else { throw CLIError("Use bluetooth [--json].") }
            try await bluetooth(json: json)
        default: throw CLIError("Unknown command.")
        }
    }

    // MARK: Stutter test

    static func stutter(_ args: [String], json: Bool) async throws {
        try KilobatCLI.allow(["stutter"] + args, ["--seconds", "--target"], valued: ["--seconds", "--target"])
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let seconds = try value("--seconds").map { text -> Int in
            guard let seconds = Int(text), StutterTest.seconds.contains(seconds) else { throw CLIError("--seconds takes 10 to 60.") }
            return seconds
        } ?? 20
        let target = value("--target") ?? "router"
        if !json { FileHandle.standardError.write(Data("Pinging \(target) every 50 ms for \(seconds) s…\n".utf8)) }
        let result = try await StutterTest.run(target: target, seconds: seconds)
        if json { try WiFiCLI.printObject(stutterJSON(result, samples: true)); return }
        let ms = { (value: Double?) in value.map { String(format: "%.0f ms", $0) } ?? "—" }
        print("Stutter test · \(result.target == result.host ? result.host : "\(result.target) (\(result.host))") · \(result.samples.count) pings in \(Int(result.seconds)) s")
        print(strip(result))
        print("Median \(ms(result.p50)) · p95 \(ms(result.p95)) · p99 \(ms(result.p99)) · worst \(ms(result.max)) · loss \(String(format: "%.0f%%", result.lossPercent))\(result.pingLimited ? " (rate-limited)" : "")")
        if !result.spikes.isEmpty {
            print("\(result.spikes.count) spike\(result.spikes.count == 1 ? "" : "s") over \(ms(result.threshold)) at " + result.spikes.prefix(12).map { String(format: "%.1fs", $0.at) }.joined(separator: ", ") + (result.spikes.count > 12 ? " …" : ""))
        }
        if let awdl = result.awdl { print(awdl.summary) }
        print("\n" + result.verdict)
    }
    /// One block per column: the slowest ping in each slice, rose when it is a spike.
    static func strip(_ result: StutterResult, width: Int = 60) -> String {
        let blocks = Array("▁▂▃▄▅▆▇█"), top = max(result.max ?? 1, 1), limit = result.threshold ?? .infinity
        let size = max(1, Int((Double(result.samples.count) / Double(width)).rounded(.up)))
        return stride(from: 0, to: result.samples.count, by: size).map { start -> String in
            let slice = result.samples[start..<min(start + size, result.samples.count)]
            guard let worst = slice.compactMap({ $0 }).max() else { return Terminal.dim("·") }
            let block = String(blocks[min(blocks.count - 1, Int(worst / top * Double(blocks.count - 1)))])
            return worst > limit ? Terminal.rose(block) : Terminal.violet(block)
        }.joined()
    }
    static func stutterJSON(_ result: StutterResult, samples: Bool) -> [String: Any] {
        func round(_ value: Double?) -> Any { value.map(WiFiCLI.tenths) ?? NSNull() }
        var value: [String: Any] = [
            "target": result.target, "host": result.host, "seconds": Int(result.seconds), "intervalMs": Int(result.interval * 1000),
            "sent": result.samples.count, "received": result.received, "lossPercent": WiFiCLI.tenths(result.lossPercent), "pingRateLimited": result.pingLimited,
            "latencyMs": ["p50": round(result.p50), "p95": round(result.p95), "p99": round(result.p99), "max": round(result.max)],
            "spikeThresholdMs": round(result.threshold), "spikeCount": result.spikes.count,
            "spikes": result.spikes.map { ["atSeconds": WiFiCLI.tenths($0.at), "peakMs": WiFiCLI.tenths($0.peak), "pings": $0.samples] },
            "periodSeconds": round(result.periodSeconds), "pattern": result.pattern.rawValue, "verdict": result.verdict,
        ]
        if let awdl = result.awdl { value["awdl"] = awdlJSON(awdl) }
        if samples { value["samplesMs"] = result.samples.map(round) }
        return value
    }

    // MARK: AirDrop

    static func awdlJSON(_ awdl: AWDLStatus) -> [String: Any] {
        ["available": awdl.available, "up": awdl.up, "active": awdl.active, "usedBy": awdl.users, "processes": awdl.processes, "summary": awdl.summary]
    }
    static func airdrop(_ args: [String], json: Bool) async throws {
        switch args.first ?? "status" {
        case "status":
            guard args.count <= 1 else { throw CLIError("Use airdrop [status|everyone|contacts|off] [--json].") }
            let awdl = await NearbyRadios.awdlStatus(), visibility = NearbyRadios.airDropVisibility()
            if json { try WiFiCLI.printObject(["visibility": visibility?.key as Any? ?? NSNull(), "awdl": awdlJSON(awdl)] as [String: Any]); return }
            print("AirDrop: \(visibility.map { $0 == .off ? "receiving off" : "visible to \($0.rawValue.lowercased())" } ?? "visibility unknown")")
            print(awdl.summary)
            if !awdl.processes.isEmpty { print("Processes: " + awdl.processes.joined(separator: ", ")) }
        case let choice where AirDropVisibility.allCases.contains { $0.key == choice }:
            guard args.count == 1 else { throw CLIError("Use airdrop everyone|contacts|off.") }
            let wanted = AirDropVisibility.allCases.first { $0.key == choice }!
            if json { try WiFiCLI.printObject(setAirDrop(wanted)); return }
            let result = setAirDrop(wanted)
            print(result["note"] as? String ?? "")
        default: throw CLIError("Use airdrop [status|everyone|contacts|off] [--json].")
        }
    }
    /// macOS lets only System Settings change AirDrop visibility, so this opens it at the right page.
    static func setAirDrop(_ wanted: AirDropVisibility) -> [String: Any] {
        let current = NearbyRadios.airDropVisibility()
        if current == wanted { return ["visibility": wanted.key, "changed": false, "openedSettings": false, "note": "AirDrop is already set to \(wanted.rawValue)."] }
        NearbyRadios.openAirDropSettings()
        return ["visibility": current?.key ?? NSNull(), "requested": wanted.key, "changed": false, "openedSettings": true,
                "note": "macOS lets only System Settings change AirDrop visibility. It's open at General › AirDrop & Handoff: choose \(wanted.rawValue) under AirDrop."]
    }

    // MARK: Bluetooth

    /// The app's view when it has Bluetooth permission; otherwise system_profiler, which needs none.
    static func bluetoothDevices() async -> [BluetoothDevice] {
        if let data = await AppRelay.ask("bluetooth"), let devices = try? JSONDecoder().decode([BluetoothDevice].self, from: data) { return devices }
        let result = await CommandRunner.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 15)
        return NearbyRadios.parseSystemProfiler(Data(result.output.utf8))
    }
    static func bluetooth(json: Bool) async throws {
        let devices = await bluetoothDevices(), band = await DiagnosticProbe().radio().band
        let advice = NearbyRadios.coexistence(wifiBand: band, devices: devices)
        if json {
            try WiFiCLI.printObject(["wifiBand": band as Any? ?? NSNull(), "advice": advice as Any? ?? NSNull(),
                                     "devices": devices.map { ["name": $0.name, "kind": $0.kind.rawValue, "connected": $0.connected, "sharesBand": NearbyRadios.sharesBand($0, wifiBand: band)] }] as [String: Any])
            return
        }
        if devices.isEmpty { print("No paired Bluetooth devices found."); return }
        for device in devices { print("\(device.connected ? "●" : "○") \(KilobatCLI.pad(device.name, 30)) \(device.kind.rawValue)\(NearbyRadios.sharesBand(device, wifiBand: band) ? " · shares 2.4 GHz with Wi-Fi" : "")") }
        print("\n" + (advice ?? "Wi-Fi \(band.map { "is on \($0)" } ?? "band unknown"); no band sharing to worry about."))
    }
}
