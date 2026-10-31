import AppKit
import CoreImage
import CoreWLAN
import Foundation
import KilobatCore

/// Wi-Fi control and the commands that read or change what the app keeps per network.
@MainActor enum WiFiCLI {
    static func run(_ args: [String]) async throws {
        let json = args.contains("--json"), rest = args.filter { $0 != "--json" }
        switch rest.first {
        case "wifi": try await wifi(Array(rest.dropFirst()), json: json)
        case "channels":
            guard rest.count == 1 else { throw CLIError("Use channels [--json].") }
            try await channels(json: json)
        case "networks": try await networks(Array(rest.dropFirst()), json: json)
        case "health-history": try healthHistory(Array(rest.dropFirst()), json: json)
        case "support-report": try await supportReport(Array(rest.dropFirst()), json: json)
        case "settings": try await settings(Array(rest.dropFirst()), json: json)
        case "low-latency": try await lowLatency(Array(rest.dropFirst()))
        case "quit": try await quit(Array(rest.dropFirst()))
        default: throw CLIError("Unknown command.")
        }
    }

    // MARK: Wi-Fi

    static func wifi(_ args: [String], json: Bool) async throws {
        let wifi = WiFiConnection()
        switch args.first ?? "status" {
        case "status":
            guard args.count <= 1 else { throw CLIError("Use wifi status [--json].") }
            let value = await wifiStatus(), radio = await DiagnosticProbe().radio()
            if json { try printObject(value); return }
            let powered = value["powered"] as? Bool ?? false, ssid = value["ssid"] as? String
            guard powered else { print("Wi-Fi is off. Turn it on with: kilobat wifi on"); return }
            print("\(ssid ?? (radio.rssi == nil ? "Not connected" : "Connected · name hidden (open the Kilobat app to show it)"))")
            if let rssi = radio.rssi {
                print("Signal \(rssi) dBm · SNR \(radio.snr.map { "\($0) dB" } ?? "—") · score \(radio.score ?? 0)/100")
                print("Channel \(radio.channel.map(String.init) ?? "—") · \(radio.band ?? "—") · link \(radio.transmitMbps.map { String(format: "%.0f Mbps", $0) } ?? "—")")
            }
        case "on", "off":
            guard args.count == 1 else { throw CLIError("Use wifi on or wifi off.") }
            try await wifi.power(args[0] == "on")
            print(args[0] == "on" ? "✓ Wi-Fi on." : "✓ Wi-Fi off.")
        case "restart":
            guard args.count == 1 else { throw CLIError("Use wifi restart.") }
            try await wifi.restart()
            print("✓ Wi-Fi restarted. macOS rejoins the preferred network.")
        case "disconnect":
            guard args.count == 1 else { throw CLIError("Use wifi disconnect.") }
            try await wifi.disconnect()
            print("✓ Disconnected. Wi-Fi stays on.")
        case "join":
            guard (2...3).contains(args.count), args.count == 2 || args[2] == "--password-stdin" else { throw CLIError("Use wifi join <name> [--password-stdin]. Saved networks join without a password.") }
            let password = args.count == 3 ? readLine(strippingNewline: true) ?? "" : nil
            try await join(args[1], password: password)
            print("✓ Joined \(args[1]).")
        case "known":
            guard args.count == 1 else { throw CLIError("Use wifi known [--json].") }
            let output = try await networksetup(["-listpreferredwirelessnetworks", interfaceName()])
            let names = output.split(separator: "\n").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if json { try printObject(names) } else { names.forEach { print($0) } }
        case "password", "share":
            guard args.count == 2 else { throw CLIError("Use wifi \(args[0]) <name>. macOS asks you to allow keychain access.") }
            let name = args[1], password = try savedPassword(name)
            let payload = WiFiShareDetails.payload(name: name, password: password, security: password.isEmpty ? "nopass" : "WPA")
            if json { try printObject(["name": name, "password": password, "qrPayload": payload]); return }
            if args[0] == "password" { print(password); return }
            print(qr(payload) ?? payload)
            print("\(name)\(password.isEmpty ? " · open network" : " · password: \(password)")")
        default: throw CLIError("Use wifi [status|on|off|restart|disconnect|join|known|password|share]. Run kilobat wifi --help.")
        }
    }

    static func wifiStatus() async -> [String: Any] {
        let powered = (try? await WiFiConnection().connection().powered) ?? false
        let radio = await DiagnosticProbe().radio()
        // macOS shows Wi-Fi names only to apps with Location permission; the running app has it.
        var ssid = radio.ssid
        if ssid == nil { ssid = await appSSID() }
        return ["powered": powered, "ssid": ssid ?? NSNull(), "interface": radio.interface ?? NSNull(), "rssi": radio.rssi ?? NSNull(),
                "noise": radio.noise ?? NSNull(), "signalNoiseRatio": radio.snr ?? NSNull(), "channel": radio.channel ?? NSNull(), "band": radio.band ?? NSNull(),
                "transmitMbps": radio.transmitMbps ?? NSNull(), "score": radio.score ?? NSNull()]
    }
    static func interfaceName() -> String { CWWiFiClient.shared().interface()?.interfaceName ?? "en0" }

    static func join(_ name: String, password: String?) async throws {
        // networksetup joins by name without Location permission and uses the saved password when none is given.
        var arguments = ["-setairportnetwork", interfaceName(), name]
        if let password, !password.isEmpty { arguments.append(password) }
        let output = try await networksetup(arguments)
        if output.localizedCaseInsensitiveContains("could not") || output.localizedCaseInsensitiveContains("error") || output.localizedCaseInsensitiveContains("failed") {
            throw CLIError(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func networksetup(_ arguments: [String]) async throws -> String {
        let result = await CommandRunner.run("/usr/sbin/networksetup", arguments, timeout: 30)
        guard result.status == 0 else { throw CLIError(result.output.isEmpty ? "networksetup failed." : result.output) }
        return result.output
    }

    /// The saved password from the keychain. macOS asks the user to allow access.
    static func savedPassword(_ name: String) throws -> String {
        let ssid = Data(name.utf8)
        var password: NSString?
        var status = CWKeychainFindWiFiPassword(.system, ssid, &password)
        if status == errSecItemNotFound { status = CWKeychainFindWiFiPassword(.user, ssid, &password) }
        if status == errSecItemNotFound { throw CLIError("No saved password for “\(name)”. Check the name, or look it up in Apple’s Passwords app.") }
        guard status == errSecSuccess, let password else { throw CLIError(status == errSecUserCanceled || status == errSecAuthFailed ? "Password access was cancelled." : "The saved password is unavailable (\(status)).") }
        return password as String
    }

    /// A QR code drawn with half blocks, black on white so it scans on dark and light terminals.
    static func qr(_ payload: String) -> String? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage"); filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage, let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cg), quiet = 2
        let size = bitmap.pixelsWide
        func dark(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < size, y < size else { return false }
            return (bitmap.colorAt(x: x, y: y)?.brightnessComponent ?? 1) < 0.5
        }
        var lines: [String] = []
        for y in stride(from: -quiet, to: size + quiet, by: 2) {
            var line = "\u{1B}[30;107m"
            for x in -quiet..<(size + quiet) {
                switch (dark(x, y), dark(x, y + 1)) {
                case (true, true): line += "█"
                case (true, false): line += "▀"
                case (false, true): line += "▄"
                default: line += " "
                }
            }
            lines.append(line + "\u{1B}[0m")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Channels

    static func channelAdvice() async throws -> [String: Any] {
        let radio = await DiagnosticProbe().radio()
        let networks = try await nearbyNetworks()
        let band = radio.band ?? "2.4 GHz"
        // The band's standard non-DFS channels count even when empty, so a free one can be recommended.
        let standard = ["2.4 GHz": [1, 6, 11], "5 GHz": [36, 40, 44, 48, 149, 153, 157, 161, 165]][band] ?? []
        let occupied = band == "2.4 GHz" ? [] : networks.filter { $0.band == band && $0.channel > 0 }.map(\.channel) + [radio.channel].compactMap { $0 }
        let candidates = Array(Set(standard + occupied)).sorted()
        let rows = candidates.map { (channel: $0, congestion: DiagnosticProbe.congestion(channel: $0, band: band, networks: networks)) }
        return ["band": band, "current": radio.channel ?? NSNull(), "recommended": rows.min { $0.congestion < $1.congestion }?.channel ?? NSNull(), "networksSeen": networks.count,
                "channels": rows.map { ["channel": $0.channel, "congestion": tenths($0.congestion)] }]
    }
    static func channels(json: Bool) async throws {
        let advice = try await channelAdvice()
        if json { try printObject(advice); return }
        let band = advice["band"] as? String ?? "", current = advice["current"] as? Int, best = advice["recommended"] as? Int
        let rows = (advice["channels"] as? [[String: Any]] ?? []).map { (channel: $0["channel"] as? Int ?? 0, congestion: ($0["congestion"] as? NSNumber)?.doubleValue ?? 0) }
        guard !rows.isEmpty else { print("No nearby networks to compare on \(band)."); return }
        print("\(band) · you are on channel \(current.map(String.init) ?? "—") · \(advice["networksSeen"] as? Int ?? 0) networks seen")
        for row in rows { print("  Ch \(KilobatCLI.pad(String(row.channel), 5))\(String(format: "%6.0f", row.congestion))\(row.channel == best ? "  ← least crowded" : "")\(row.channel == current ? "  (current)" : "")") }
        print("An estimate from visible networks and their widths. Change the channel in your router’s settings.")
    }

    /// Nearby networks with names when the app can provide them; the CLI alone sees them unnamed.
    static func nearbyNetworks() async throws -> [NearbyNetwork] {
        if let data = await AppRelay.ask("scan"), let networks = try? JSONDecoder().decode([NearbyNetwork].self, from: data), !networks.isEmpty {
            SurveyJournal().saveScan(networks)
            return networks
        }
        return try await DiagnosticProbe().scan()
    }

    /// The Wi-Fi name as the running app sees it; macOS hides it from the CLI without Location permission.
    static func appSSID() async -> String? { await connection()?["ssid"] as? String }
    static func connection(timeout: Duration = .seconds(3)) async -> [String: Any]? {
        guard let data = await AppRelay.ask("connection", timeout: timeout) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: Remembered networks

    static func networks(_ args: [String], json: Bool) async throws {
        let store = TrafficStore(startMonitoring: false)
        func name(_ key: String) -> String { store.networkSessions[key]?.name ?? "Unknown network" }
        switch args.first {
        case nil:
            let rows = await networkRows(store)
            if json { try printObject(rows); return }
            if rows.isEmpty { print("No networks yet. Kilobat records them while the app runs."); return }
            for row in rows {
                let profile = (row["profile"] as? String).map { "\($0) · " } ?? ""
                let budget = (row["budgetGB"] as? Double).map { "\($0.formatted()) GB budget · " } ?? ""
                let cost = row["meteredSource"] as? String == "you" ? ((row["metered"] as? Bool) == true ? "metered · " : "unmetered · ") : ""
                print("\(KilobatCLI.pad(row["name"] as? String ?? "", 28))\(profile)\(budget)\(cost)\(TrafficFormat.bytes(row["sessionBytes"] as? UInt64 ?? 0)) this session  \(row["key"] as? String ?? "")")
            }
        case "forget":
            guard args.count == 2 else { throw CLIError("Use networks forget <key or name>.") }
            let key = try network(args[1], store: store)
            store.preferences.networkProfiles?.removeValue(forKey: key); store.preferences.networkLimits?.removeValue(forKey: key); store.preferences.setCost(.automatic, for: key)
            print("✓ Forgot the profile, budget and data cost for \(name(key)).")
        case "cost":
            guard (2...3).contains(args.count), let cost = NetworkCost(rawValue: args[1].lowercased()) else { throw CLIError("Use networks cost <metered|unmetered|automatic> [key or name].") }
            var result = try await setCost(cost, network: args.count == 3 ? args[2] : nil, store: store)
            let effect = result.removeValue(forKey: "effect") as? String ?? ""
            if json { try printObject(result); return }
            print("✓ \(result["name"] as? String ?? "")\(result["lastRecorded"] as? Bool == true ? " (the network Kilobat last recorded)" : "") \(effect)")
        default: throw CLIError("Use networks [--json], networks cost <metered|unmetered|automatic> [name] or networks forget <key or name>.")
        }
    }
    static func networkKeys(_ store: TrafficStore) -> Set<String> {
        Set((store.preferences.networkProfiles ?? [:]).keys).union((store.preferences.networkLimits ?? [:]).keys).union((store.preferences.networkCost ?? [:]).keys)
            .union(store.networkSessions.keys).subtracting(["unknown"])
    }
    static func network(_ text: String, store: TrafficStore) throws -> String {
        let matches = networkKeys(store).filter { $0 == text || store.networkSessions[$0]?.name.caseInsensitiveCompare(text) == .orderedSame }
        guard matches.count == 1, let key = matches.first else { throw CLIError(matches.isEmpty ? "No network matches “\(text)”." : "Several networks match; use the key from kilobat networks.") }
        return key
    }
    /// Sets the data cost of `network` (a key or name), or of the network the app is on.
    static func setCost(_ cost: NetworkCost, network: String?, store: TrafficStore) async throws -> [String: Any] {
        let app = network == nil ? await connection() : nil
        let current = network == nil ? currentNetwork(store, app: app) : nil
        if network == nil && current == nil { throw CLIError("Kilobat hasn’t recorded a network yet. Open the app, or name one from kilobat networks.") }
        let key = try current?.key ?? Self.network(network ?? "", store: store)
        guard current?.identified ?? (store.networkSessions[key]?.identified != false) else {
            throw CLIError("Kilobat can’t tell this network apart yet — allow Location in the app so it can see the Wi-Fi name.")
        }
        store.preferences.setCost(cost, for: key)
        let travel = store.preferences.autoHotspot && store.preferences.networkProfiles?[key] == nil
        let effect = switch cost {
        case .automatic: "follows macOS again."
        case .unmetered: "is unmetered now."
        case .metered: "is metered now. Kilobat " + (travel ? "switches to Travel and skips" : "skips") + " scheduled speed tests there."
        }
        return ["key": key, "name": store.networkSessions[key]?.name ?? "Unknown network", "cost": cost.rawValue, "lastRecorded": current != nil && app == nil, "effect": effect]
    }
    /// The network the app is on, or failing that the one Kilobat last recorded.
    static func currentNetwork(_ store: TrafficStore, app: [String: Any]?) -> (key: String, identified: Bool)? {
        guard let key = QuotaCLI.currentNetwork(store, app: app) else { return nil }
        return (key, app?["networkIdentified"] as? Bool ?? (store.networkSessions[key]?.identified != false))
    }
    /// The current network's cost. Without the app, the network last recorded may not be this one, so only a stricter setting counts.
    static func currentCost(_ store: TrafficStore, app: [String: Any]?) -> NetworkCost {
        let cost = currentNetwork(store, app: app).map { store.preferences.cost(of: $0.key) } ?? .automatic
        return app == nil && cost == .unmetered ? .automatic : cost
    }
    static func networkRows(_ store: TrafficStore) async -> [[String: Any]] {
        let preferences = store.preferences, keys = networkKeys(store)
        async let path = AwakeCLI.currentPath()
        let app = await connection(), current = currentNetwork(store, app: app)?.key, os = await path.expensive
        func name(_ key: String) -> String { store.networkSessions[key]?.name ?? "Unknown network" }
        return keys.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }.map { key -> [String: Any] in
            let cost = key == current ? currentCost(store, app: app) : preferences.cost(of: key)
            // macOS only reports the network the Mac is on.
            let metered: [String: Any] = key == current ? cost.fields(os: os)
                : ["metered": cost == .automatic ? NSNull() : cost == .metered, "osMetered": NSNull(), "meteredSource": cost == .automatic ? NSNull() : "you"]
            return ["key": key, "name": name(key), "profile": preferences.networkProfiles?[key]?.lowercased() ?? NSNull(), "remembered": preferences.networkProfiles?[key] != nil,
                    "budgetGB": preferences.networkLimits?[key] ?? NSNull(), "sessionBytes": (store.networkSessions[key]?.received ?? 0) + (store.networkSessions[key]?.sent ?? 0),
                    "current": key == current, "cost": preferences.cost(of: key).rawValue].merging(metered) { $1 }
        }
    }

    // MARK: Health history

    static func healthHistory(_ args: [String], json: Bool) throws {
        var hours = 24
        if !args.isEmpty {
            guard args.count == 2, args[0] == "--hours", let value = Int(args[1]), (1...720).contains(value) else { throw CLIError("Use health-history [--hours 1…720] [--json].") }
            hours = value
        }
        let rows = healthRows(hours: hours)
        if json { try printObject(rows); return }
        guard !rows.isEmpty else { print("No health samples in the last \(hours) hours. The Kilobat app records them while it runs."); return }
        func ms(_ value: Any?) -> String { (value as? NSNumber).map { String(format: "%5.0f", $0.doubleValue) } ?? "    —" }
        print("Time    Health     Router Internet Jitter   DNS  Network")
        for row in rows.suffix(60) {
            let time = (row["date"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }?.formatted(date: .omitted, time: .shortened) ?? ""
            print("\(KilobatCLI.pad(time, 8))\(KilobatCLI.pad(row["health"] as? String ?? "", 9))\(ms(row["routerMs"]))   \(ms(row["internetMs"]))  \(ms(row["jitterMs"])) \(ms(row["dnsMs"]))  \(row["network"] as? String ?? "")")
        }
        if rows.count > 60 { print("… \(rows.count - 60) earlier samples; use --json for all.") }
    }

    /// A redacted report for an ISP or IT desk: findings, latency, outages, speed tests and an optional host check.
    static func supportReport(_ args: [String], json: Bool) async throws {
        let usage = "Use support-report [--hours 1…168] [--host <host>] [--markdown|--html] [--output <file>] [--json]."
        var hours = 24, host: String?, format = "text", output: String?
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--hours":
                guard index + 1 < args.count, let value = Int(args[index + 1]), (1...168).contains(value) else { throw CLIError(usage) }
                hours = value; index += 2
            case "--host":
                guard index + 1 < args.count, !args[index + 1].hasPrefix("-") else { throw CLIError(usage) }
                host = args[index + 1]; index += 2
            case "--output", "-o":
                guard index + 1 < args.count else { throw CLIError(usage) }
                output = args[index + 1]; index += 2
            case "--markdown": format = "markdown"; index += 1
            case "--html": format = "html"; index += 1
            default: throw CLIError(usage)
            }
        }
        let report = try await makeSupportReport(hours: hours, host: host)
        let body: String
        if json { body = String(decoding: try DiagnosticsCLI.encode(report), as: UTF8.self) }
        else { body = format == "html" ? report.html : format == "markdown" ? report.markdown : report.text }
        if let output {
            let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
            try body.write(to: url, atomically: true, encoding: .utf8)
            print("Saved \(url.path). It leaves out your network's name and every local address.")
        } else { print(body) }
    }

    static func makeSupportReport(hours: Int, host: String?) async throws -> SupportReport {
        let journal = NetworkJournal()
        let check: DoctorReport? = if let host { await ConnectionDoctor.run(host, policy: await AwakeCLI.policy()) } else { nil }
        let plan = KilobatCLI.appDefaults.double(forKey: "speed.planMbps")
        return SupportReport.make(samples: journal.samples, events: journal.events, speedTests: journal.speedTests,
                                  hours: hours, planMbps: plan, plans: PlanSpeeds.all(KilobatCLI.appDefaults), check: check)
    }

    static func healthRows(hours: Int) -> [[String: Any]] {
        let since = Date().addingTimeInterval(-Double(hours) * 3600)
        func round(_ value: Double?) -> Any { value.map(tenths) ?? NSNull() }
        return NetworkJournal().samples.filter { $0.date >= since }.map { sample in
            ["date": ISO8601DateFormatter().string(from: sample.date), "network": sample.networkName, "health": sample.health.rawValue,
             "rssi": sample.radio.rssi ?? NSNull(), "routerMs": round(sample.router?.average), "internetMs": round(sample.internet.average),
             "jitterMs": round(sample.internet.jitter), "lossPercent": round(sample.internet.lossPercent), "dnsMs": round(sample.dnsMilliseconds)]
        }
    }

    // MARK: Settings

    struct Setting {
        let key: String, values: String, detail: String
        let read: @MainActor (TrafficStore) -> String
        let write: @MainActor (TrafficStore, String) throws -> Void
        var appRestart = false
        /// Asked of the running app after the change is saved, so it applies at once.
        var relay: (@MainActor () -> String)? = nil
    }
    static func toggle(_ value: String) throws -> Bool {
        switch value.lowercased() { case "on", "true", "yes": return true; case "off", "false", "no": return false; default: throw CLIError("Use on or off.") }
    }
    static var defaults: UserDefaults { KilobatCLI.appDefaults }
    static let settingsList: [Setting] = [
        Setting(key: "new-apps", values: "allow|ask|block", detail: "What Travel and Work do with apps that have no rule; ask holds them until you decide in the app",
                read: { $0.preferences.askNewApps == true ? "ask" : $0.preferences.defaultAllow ? "allow" : "block" },
                write: { store, value in _ = try FirewallCLI.setMode(store, newApps: value, allowApple: nil) }),
        Setting(key: "apple-software", values: "on|off", detail: "Let Apple's own software connect when new apps are asked about or blocked",
                read: { $0.preferences.allowApple == true ? "on" : "off" }, write: { store, value in store.preferences.allowApple = try toggle(value) }),
        Setting(key: "auto-travel", values: "on|off", detail: "Switch to Travel on metered networks such as a phone hotspot",
                read: { $0.preferences.autoHotspot ? "on" : "off" }, write: { store, value in store.preferences.autoHotspot = try toggle(value) }),
        Setting(key: "pause-updaters", values: "on|off", detail: "Block updater helpers such as Google Updater and macOS Software Update while the network is metered",
                read: { UpdaterPause.enabled($0.preferences) ? "on" : "off" }, write: { store, value in store.preferences.pauseUpdaters = try toggle(value) ? nil : false }),
        Setting(key: "scope", values: "external|wifi|wired", detail: "Which traffic counts toward per-app totals",
                read: { $0.preferences.trafficScope ?? "external" },
                write: { store, value in guard ["external", "wifi", "wired"].contains(value) else { throw CLIError("Use external, wifi or wired.") }; store.preferences.trafficScope = value }),
        Setting(key: "alerts", values: "on|off", detail: "Notify when the connection drops or degrades",
                read: { _ in defaults.bool(forKey: "networkAlerts") ? "on" : "off" }, write: { _, value in defaults.set(try toggle(value), forKey: "networkAlerts") }, appRestart: true),
        Setting(key: "outage-trace", values: "on|off", detail: "Run a route trace automatically during outages",
                read: { _ in defaults.bool(forKey: "automaticOutageTrace") ? "on" : "off" }, write: { _, value in defaults.set(try toggle(value), forKey: "automaticOutageTrace") }, appRestart: true),
        Setting(key: "public-ip", values: "on|off", detail: "Have the app ask Cloudflare for your public IP on network changes and every 30 minutes (off by default)",
                read: { _ in defaults.bool(forKey: "publicIPLookup") ? "on" : "off" }, write: { _, value in defaults.set(try toggle(value), forKey: "publicIPLookup") }, appRestart: true),
        Setting(key: "speed-streams", values: "single|parallel", detail: "Speed tests in the app: one connection, or four at once",
                read: { _ in defaults.integer(forKey: "speedStreams") > 1 ? "parallel" : "single" },
                write: { _, value in guard ["single", "parallel"].contains(value) else { throw CLIError("Use single or parallel.") }; defaults.set(value == "parallel" ? SpeedTest.parallelStreams : 1, forKey: "speedStreams") }, appRestart: true),
        Setting(key: "check-interval", values: "12…3600", detail: "Seconds between background health checks",
                read: { _ in String(max(12, defaults.integer(forKey: "diagnosticInterval"))) },
                write: { _, value in guard let seconds = Int(value), (12...3600).contains(seconds) else { throw CLIError("Use 12 to 3600 seconds.") }; defaults.set(seconds, forKey: "diagnosticInterval") }, appRestart: true),
        Setting(key: "speed-schedule", values: "off|1…168", detail: "Hours between automatic speed tests",
                read: { _ in let hours = defaults.integer(forKey: "speedScheduleHours"); return hours > 0 ? String(hours) : "off" },
                write: { _, value in
                    if value == "off" || value == "0" { defaults.set(0, forKey: "speedScheduleHours"); return }
                    guard let hours = Int(value), (1...168).contains(hours) else { throw CLIError("Use off or 1 to 168 hours.") }; defaults.set(hours, forKey: "speedScheduleHours")
                }, appRestart: true),
        Setting(key: "plan-mbps", values: "0…10000", detail: "Your plan's download speed, to compare speed tests against (0 hides it)",
                read: { _ in defaults.double(forKey: "speed.planMbps").formatted() },
                write: { _, value in guard let mbps = Double(value), (0...10_000).contains(mbps) else { throw CLIError("Use 0 to 10000.") }; defaults.set(mbps, forKey: "speed.planMbps") }),
        Setting(key: "plan-check", values: "on|off", detail: "Pro: light speed tests up to three times a day, while the Mac is quiet, on networks with a plan speed set in the app (see kilobat plan)",
                read: { _ in defaults.bool(forKey: PlanCheck.enabledKey) ? "on" : "off" }, write: { _, value in defaults.set(try toggle(value), forKey: PlanCheck.enabledKey) }),
        Setting(key: "menu-bar", values: "icon|speed|download,upload,latency,vpn", detail: "What the menu bar item shows; vpn shows On, Split or Off and, with public-ip on, the exit IP's registry country",
                read: { _ in let shown = ["speed", "download", "upload", "latency", "vpn"].filter { defaults.bool(forKey: "menu." + $0) }; return shown.isEmpty ? "icon" : shown.joined(separator: ",") },
                write: { _, value in
                    let items = value == "icon" ? [] : value.split(separator: ",").map(String.init)
                    guard items.allSatisfy(["speed", "download", "upload", "latency", "vpn"].contains) else { throw CLIError("Use icon, or a comma list of speed, download, upload, latency and vpn.") }
                    for item in ["speed", "download", "upload", "latency", "vpn"] { defaults.set(items.contains(item), forKey: "menu." + item) }
                }),
        Setting(key: "units", values: "bytes|bits", detail: "Show rates in bytes or bits per second",
                read: { _ in defaults.bool(forKey: "menu.bits") ? "bits" : "bytes" },
                write: { _, value in guard ["bytes", "bits"].contains(value) else { throw CLIError("Use bytes or bits.") }; defaults.set(value == "bits", forKey: "menu.bits") }),
        Setting(key: "group-helpers", values: "on|off", detail: "Group helper processes under their app",
                read: { _ in defaults.object(forKey: "apps.groupHelpers") as? Bool ?? true ? "on" : "off" }, write: { _, value in defaults.set(try toggle(value), forKey: "apps.groupHelpers") }),
        Setting(key: "awake-on-power", values: "on|off", detail: "Stay awake while plugged in, until unplugged; keep-screen-on decides the screen",
                read: { _ in defaults.bool(forKey: "awake.power") ? "on" : "off" },
                write: { _, value in defaults.set(try toggle(value), forKey: "awake.power") },
                relay: { defaults.bool(forKey: "awake.power") ? "power|on" : "power|off" }),
        Setting(key: "keep-screen-on", values: "on|off", detail: "Keep the screen on too for everything the app keeps awake",
                read: { _ in defaults.bool(forKey: "awake.display") ? "on" : "off" }, write: { _, value in defaults.set(try toggle(value), forKey: "awake.display") }),
    ]

    static func settings(_ args: [String], json: Bool) async throws {
        let store = TrafficStore(startMonitoring: false)
        // A flag belongs to the value: settings awake-on-power on --display.
        var args = args
        switch args.count {
        case 0:
            if json { try printObject(Dictionary(uniqueKeysWithValues: settingsList.map { ($0.key, $0.read(store)) })); return }
            for setting in settingsList { print("\(KilobatCLI.pad(setting.key, 16))\(KilobatCLI.pad(setting.read(store), 22))\(setting.detail)") }
            print("\nChange one with: kilobat settings <name> <value>")
        case 1, 2:
            guard let setting = settingsList.first(where: { $0.key == args[0] }) else { throw CLIError("Unknown setting '\(args[0])'. Run kilobat settings.") }
            if args.count == 1 { print(json ? "\"\(setting.read(store))\"" : setting.read(store)); return }
            try setting.write(store, args[1])
            defaults.synchronize()
            // Without an answer, the app picks the change up when it next opens.
            var later = setting.appRestart && AppRelay.appRunning
            if let relay = setting.relay, AppRelay.appRunning { later = await AppRelay.ask(relay(), timeout: .seconds(3)) == nil }
            print("✓ \(setting.key) = \(setting.read(store))\(later ? " · takes effect when Kilobat restarts" : "")")
        default: throw CLIError("Use settings [name [value]].")
        }
    }

    // MARK: Low latency and quitting apps

    static func lowLatency(_ args: [String]) async throws {
        let usage = "Use low-latency on [--for 15m|1h|2h] [--until-quit <app>], or low-latency off."
        if args == ["off"] {
            let released = LowLatencyMode.releaseAll()
            await waitForAWDL()
            switch await LowLatencyMode.isUp() {
            case true?: print(released > 0 ? "✓ AWDL restored." : "AWDL is already on.")
            case false?:
                try await LowLatencyMode.forceRestore(reason: "Kilobat turns AirDrop (AWDL) back on.")
                print("✓ AWDL restored.")
            case nil: print("This Mac has no AWDL interface.")
            }
            return
        }
        guard args.first == "on" else { throw CLIError(usage) }
        try KilobatCLI.allow(args, ["--for", "--until-quit"], valued: ["--for", "--until-quit"])
        func value(_ flag: String) throws -> String? {
            guard let index = args.firstIndex(of: flag) else { return nil }
            guard index + 1 < args.count else { throw CLIError(usage) }
            return args[index + 1]
        }
        let seconds = try value("--for").map { text -> TimeInterval in
            guard let seconds = LowLatencyHold.seconds(text) else { throw CLIError("--for takes a length such as 15m, 1h or 2h, up to 4h.") }
            return seconds
        }
        let app = try value("--until-quit").map { name -> (pid: Int32, name: String) in
            let running = NSWorkspace.shared.runningApplications.first {
                $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame || $0.bundleIdentifier?.caseInsensitiveCompare(name) == .orderedSame
            }
            guard let running, let title = running.localizedName else { throw CLIError("'\(name)' isn't running. Open it first, or use --for.") }
            return (running.processIdentifier, title)
        }
        let mode = LowLatencyMode()
        await mode.enable(seconds: seconds ?? (app == nil ? 900 : nil), app: app)
        if let error = mode.error { throw CLIError(error) }
        print("✓ AWDL paused: AirDrop, Sidecar and Universal Control are off (\(mode.hold?.label() ?? "for now"), 4 hours at most).")
        print("  Keep this running during your call or game. Ctrl-C, closing Terminal or kilobat low-latency off restores them.")
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let stopped = AsyncStream<Void> { continuation in
            interrupt.setEventHandler { continuation.finish() }
            interrupt.resume()
            Task { @MainActor in
                while mode.active { try? await Task.sleep(for: .seconds(1)) }
                continuation.finish()
            }
        }
        for await _ in stopped {}
        mode.release()
        await waitForAWDL()
        print("\n✓ AWDL restored.")
    }
    /// The watchdog restores AWDL within a couple of seconds of its lease going away.
    static func waitForAWDL() async {
        for _ in 0..<5 {
            guard await LowLatencyMode.isUp() == false else { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    static func quit(_ args: [String]) async throws {
        let force = args.contains("--force"), targets = args.filter { $0 != "--force" }
        guard targets.count == 1, let pid = Int32(targets[0]) else { throw CLIError("Use quit <PID> [--force]. Find PIDs in status --json (processIDs) or destinations.") }
        let process = try await ProcessControl.inspect(pid: pid)
        try await ProcessControl.terminate(process, force: force)
        print("✓ \(force ? "Force quit" : "Asked to quit") \(process.name) (\(pid)).")
    }

    /// Rounded to 0.1 as a decimal, so JSON shows 6.9 rather than 6.9000000000000004.
    static func tenths(_ value: Double) -> Any { value.isFinite ? NSDecimalNumber(value: Int((value * 10).rounded())).multiplying(byPowerOf10: -1) : NSNull() }
    static func printObject(_ value: Any) throws {
        print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
    }
}
