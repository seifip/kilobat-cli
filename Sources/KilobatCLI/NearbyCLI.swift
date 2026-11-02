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
            let command: BluetoothCommand
            do { command = try BluetoothCommand.parse(args) } catch let error as DiagnosticError { throw CLIError(error.message) }
            switch command {
            case .devices(let json): try await bluetooth(json: json)
            case .audio(let json): try await audio(json: json)
            }
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
        if json == false, let output = BluetoothAudioProbe.output(), output.playing {
            print("\(output.name) is playing. For what may make it crackle: kilobat bluetooth audio\n")
        }
        for device in devices { print("\(device.connected ? "●" : "○") \(KilobatCLI.pad(device.name, 30)) \(device.kind.rawValue)\(NearbyRadios.sharesBand(device, wifiBand: band) ? " · shares 2.4 GHz with Wi-Fi" : "")") }
        print("\n" + (advice ?? "Wi-Fi \(band.map { "is on \($0)" } ?? "band unknown"); no band sharing to worry about."))
    }

    // MARK: Bluetooth audio

    /// What `bluetooth audio --json` and the MCP tool return.
    struct AudioSummary: Encodable {
        struct Step: Encodable {
            let text: String; let risk: String?; let action: String?
            private enum CodingKeys: String, CodingKey { case text, risk, action }
            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(text, forKey: .text); try container.encode(risk, forKey: .risk); try container.encode(action, forKey: .action)
            }
        }
        let source: String
        let output: BluetoothAudioOutput?
        let playing: Bool
        let risks: [BluetoothAudioRisk]
        let score: Int
        let level: BluetoothAudioCheck.Level?
        let notifyWorthy: Bool
        let headline: String?
        let detail: String?
        let advice: [Step]
        let conditions: BluetoothAudioConditions?
        let reported: Bool
        let basis: String
        let crackleReports: [BluetoothAudioReport]
        private enum CodingKeys: String, CodingKey { case source, output, playing, risks, score, level, notifyWorthy, headline, detail, advice, conditions, reported, basis, crackleReports }
        /// Missing values are written as null, so a script sees every key whether or not anything plays.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(source, forKey: .source); try container.encode(output, forKey: .output); try container.encode(playing, forKey: .playing)
            try container.encode(risks, forKey: .risks); try container.encode(score, forKey: .score); try container.encode(level, forKey: .level)
            try container.encode(notifyWorthy, forKey: .notifyWorthy); try container.encode(headline, forKey: .headline); try container.encode(detail, forKey: .detail)
            try container.encode(advice, forKey: .advice); try container.encode(conditions, forKey: .conditions); try container.encode(reported, forKey: .reported)
            try container.encode(basis, forKey: .basis); try container.encode(crackleReports, forKey: .crackleReports)
        }
    }
    /// The app's latest check while it runs, which has the Bluetooth signal, the busiest app and its scans; otherwise
    /// measured here over two seconds, without the busiest app or a signal unless system_profiler gives one.
    static func audioCheck() async -> (check: BluetoothAudioCheck?, source: String) {
        if let data = await AppRelay.ask("bluetooth-audio", timeout: .seconds(3)) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            if let relay = try? decoder.decode(BluetoothAudioRelay.self, from: data) { return (relay.check, "app") }
        }
        guard let output = BluetoothAudioProbe.output() else { return (nil, "cli") }
        let radio = await DiagnosticProbe().radio()
        var conditions = BluetoothAudioConditions()
        conditions.wifiBand = radio.band; conditions.wifiChannel = radio.channel; conditions.wifiName = radio.ssid
        let before = BluetoothAudioProbe.wifiBytes(interface: radio.interface), started = Date()
        async let awdl = NearbyRadios.awdlStatus()
        async let devices = bluetoothDevices()
        try? await Task.sleep(for: .seconds(2))
        if let before, let after = BluetoothAudioProbe.wifiBytes(interface: radio.interface), after >= before {
            conditions.wifiBytesPerSecond = Double(after - before) / max(1, Date().timeIntervalSince(started))
        }
        let link = await awdl
        conditions.airDropActive = link.up && link.active; conditions.airDropUsers = link.users
        BluetoothAudioWatch.fill(&conditions, output: output.name, devices: await devices)
        let networks = BluetoothAudioProbe.recentScan(SurveyJournal().scans)
        if let crowd = BluetoothAudioCheck.crowding(channel: radio.channel, band: radio.band, ownName: radio.ssid, networks: networks) {
            conditions.channelCrowding = crowd.crowding; conditions.quieterChannel = crowd.quieter
        }
        conditions.fasterBand = BluetoothAudioCheck.fasterBand(current: radio.ssid, band: radio.band, networks: networks, known: BluetoothAudioProbe.knownNetworks())
        return (BluetoothAudioCheck(output: output, conditions: conditions), "cli")
    }
    static func audioSummary() async -> AudioSummary {
        let (check, source) = await audioCheck()
        return AudioSummary(source: source, output: check?.output, playing: check?.output.playing ?? false, risks: check?.risks ?? [], score: check?.score ?? 0,
                            level: check?.level, notifyWorthy: check?.lineUp ?? false, headline: check?.headline, detail: check?.detail,
                            advice: (check?.advice ?? []).map { .init(text: $0.text, risk: $0.risk?.rawValue, action: $0.action?.rawValue) },
                            conditions: check?.conditions, reported: check?.reported ?? false, basis: BluetoothAudioCheck.basis,
                            crackleReports: Array(BluetoothAudioWatch.load().suffix(5).reversed()))
    }
    static func audio(json: Bool) async throws {
        if !json { FileHandle.standardError.write(Data("Checking the sound output, Wi-Fi and AirDrop…\n".utf8)) }
        let summary = await audioSummary()
        if json { print(String(decoding: try DiagnosticsCLI.encode(summary), as: UTF8.self)); return }
        guard let output = summary.output else {
            print("The sound output isn't Bluetooth. With AirPods or other Bluetooth headphones playing, this says what on the Wi-Fi side can make them crackle.")
            return
        }
        guard summary.playing else { print("\(output.name) is the sound output, but nothing is playing. Run this while it plays."); return }
        print("\(output.name) · \(output.microphone ? "on a call (hands-free mode)" : "playing") · \(output.transport == .le ? "Bluetooth LE" : "Bluetooth")")
        if let conditions = summary.conditions {
            var facts = [conditions.wifiBand.map { "Wi-Fi \($0)" + (conditions.wifiChannel.map { " ch \($0)" } ?? "") } ?? "Wi-Fi off"]
            if let active = conditions.airDropActive { facts.append(active ? "AirDrop link busy" + (conditions.airDropUsers.isEmpty ? "" : " (\(conditions.airDropUsers.joined(separator: ", ")))") : "AirDrop link quiet") }
            if let rate = conditions.wifiBytesPerSecond { facts.append(String(format: "Wi-Fi traffic %.1f Mbit/s", rate * 8 / 1_000_000)) }
            if let rssi = conditions.bluetoothRSSI { facts.append("Bluetooth \(rssi) dBm") }
            if let others = conditions.otherBluetoothDevices { facts.append("\(others) other Bluetooth device\(others == 1 ? "" : "s")") }
            print(facts.joined(separator: " · "))
        }
        print("\n" + (summary.risks.isEmpty ? Terminal.dim(summary.headline ?? "") : Terminal.rose(summary.headline ?? "")))
        if let detail = summary.detail { print(detail) }
        for (index, step) in summary.advice.enumerated() { print("  \(index + 1). \(step.text)") }
        if summary.advice.contains(where: { $0.action == "pauseAirDrop" }) { print("\nPause AirDrop: kilobat low-latency on --for 1h") }
        print("\n" + Terminal.dim(summary.basis))
    }
}
