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
        case "wakes": try wakes(rest, json: json)
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
                print("Channel \(radio.channel.map(String.init) ?? "—") · \(radio.band ?? "—")\(radio.widthMHz.map { " · \($0) MHz" } ?? "") · link \(radio.transmitMbps.map { String(format: "%.0f Mbps", $0) } ?? "—")")
                let standard = radio.standard.map { name in radio.phyMode.map { $0 == name ? name : "\(name) (\($0))" } ?? name }
                let parts = [standard, radio.security, radio.transmitPowerDBm.map { "transmit \($0) dBm" }].compactMap { $0 }
                if !parts.isEmpty { print(parts.joined(separator: " · ")) }
                if let note = radio.securityInfo?.note { print(note) }
                if let current = value["macAddress"] as? String {
                    let hardware = value["hardwareAddress"] as? String
                    switch value["privateAddress"] as? Bool {
                    case true?: print("Private Wi-Fi address: on · the router sees \(current)\(hardware.map { ", not the hardware address \($0)" } ?? "")")
                    case false?: print("Private Wi-Fi address: off · the router sees the hardware address \(current)")
                    default: print("Wi-Fi address \(current)")
                    }
                }
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
        case "roams": try roams(args, json: json)
        case "scan": try await scan(Array(args.dropFirst()) + (json ? ["--json"] : []))
        case "watch": try await watch(Array(args.dropFirst()), json: json)
        case "steering":
            guard args.count == 1 else { throw CLIError("Use wifi steering [--json].") }
            try await steering(json: json)
        case "nodes", "reconnect":
            let command: WiFiNodesCommand
            do { command = try WiFiNodesCommand.parse(args) } catch let error as DiagnosticError { throw CLIError(error.message) }
            try await nodes(command, json: json)
        default: throw CLIError("Use wifi [status|scan|watch|steering|on|off|restart|disconnect|join|known|password|share|nodes|reconnect|roams]. Run kilobat wifi --help.")
        }
    }

    // MARK: Scan, watch and steering

    /// `scan` and `wifi scan`: nearby networks, with `--details` everything their beacons say, as text, `--json` or `--csv`.
    static func scan(_ args: [String]) async throws {
        guard args.allSatisfy({ ["--json", "--csv", "--details"].contains($0) }), !(args.contains("--json") && args.contains("--csv")) else {
            throw CLIError("Use scan [--details] [--json|--csv].")
        }
        let networks = try await nearbyNetworks()
        if args.contains("--json") { print(String(decoding: try DiagnosticsCLI.scanJSON(networks), as: UTF8.self)); return }
        if args.contains("--csv") { print(WiFiScanExport.csv(networks, date: Date()), terminator: ""); return }
        let details = args.contains("--details")
        print("Nearby Wi-Fi networks · macOS Location permission may be required\n")
        for network in networks {
            let generation = network.details?.generation.map { " · \($0.name)" } ?? ""
            let channel = network.channel > 0 ? String(network.channel) : "—", band = network.band == "Unknown" ? "—" : network.band
            print("\(KilobatCLI.pad(network.ssid, 30)) \(network.rssi) dBm · Ch \(channel) · \(band) · \(network.widthMHz) MHz\(network.security.map { " · \($0)" } ?? "")\(generation)")
            if details, let line = detailLine(network) { print("    " + line) }
        }
        if networks.isEmpty { print("No networks returned. Enable Wi-Fi scanning in the Kilobat app.") }
        else if networks.allSatisfy({ $0.ssid == "Hidden network" }) { print("\nNames are hidden: macOS shows them only to apps with Location permission. Open the Kilobat app and run this again.") }
        else if details && networks.allSatisfy({ $0.details == nil }) { print("\nBeacon details need Location access, which only the Kilobat app has. Open it and run this again.") }
    }

    /// "aa:bb:… Broadcom · 2 streams · up to 1201 Mbps · 802.11k/v/r · WPA3 Personal, PMF required · 12 clients, channel 35% busy".
    static func detailLine(_ network: NearbyNetwork) -> String? {
        guard let d = network.details else { return nil }
        var parts: [String] = []
        if !network.id.hasPrefix("hidden-") { parts.append(network.id + (d.vendor.map { " " + $0 } ?? "")) }
        if let streams = d.streams { parts.append("\(streams) stream\(streams == 1 ? "" : "s")") }
        if let rate = d.maxRateMbps { parts.append("up to \(Int(rate.rounded())) Mbps") }
        let roaming = [d.radioMeasurement ? "k" : nil, d.bssTransition ? "v" : nil, d.fastRoaming ? "r" : nil].compactMap { $0 }
        parts.append(roaming.isEmpty ? "no 802.11k/v/r" : "802.11" + roaming.joined(separator: "/"))
        if let security = d.security { parts.append(security.summary + (security.pmf == .off ? "" : ", PMF \(security.pmf.rawValue)")) }
        if let link = d.multiLink { parts.append("multi-link" + (link.links.isEmpty ? "" : " with " + link.links.map { "\($0.band) ch \($0.channel)" }.joined(separator: ", "))) }
        if let stations = d.stations { parts.append("\(stations) clients" + (d.channelUtilization.map { ", channel \(Int(($0 * 100).rounded()))% busy" } ?? "")) }
        if let country = d.country { parts.append(country) }
        if ChannelPlan.touchesDFS(network.span, band: network.band) { parts.append("DFS") }
        return parts.joined(separator: " · ")
    }

    /// `wifi watch [--for 2m] [--every 15s] [--json|--csv]`: scans every so often for a few minutes and reports each access
    /// point's signal. The app does the scans when it runs (it has Location access); the CLI reads its own link between.
    static func watch(_ args: [String], json: Bool) async throws {
        let command: WiFiWatchCommand
        do { command = try WiFiWatchCommand.parse(args) } catch let error as DiagnosticError { throw CLIError(error.message) }
        let probe = DiagnosticProbe()
        let app = AppRelay.appRunning ? await connection() : nil
        let ssid = app?["ssid"] as? String, bssid = app?["bssid"] as? String
        let scan: WiFiWatchSession.Scan = { try await nearbyNetworks(save: false) }
        let link: WiFiWatchSession.Link = {
            let radio = await probe.radio()
            var sample = RadioSample.basic(bssid: radio.bssid ?? bssid, ssid: radio.ssid ?? ssid, interface: radio.interface, rssi: radio.rssi, noise: radio.noise,
                                           transmitMbps: radio.transmitMbps, channel: radio.channel, band: radio.band)
            sample.widthMHz = radio.widthMHz
            return sample
        }
        let session = WiFiWatchSession(scan: scan, link: link, pauseScans: { false }, clock: { Date() }, pause: { seconds in try? await Task.sleep(for: .seconds(seconds)) })
        let quiet = json || command.csv
        if !quiet {
            print("Watching for \(WiFiWatchCommand.label(command.duration)), a scan every \(Int(command.interval)) s. Each scan takes Wi-Fi off its channel for a moment.")
            if !AppRelay.appRunning { print("The Kilobat app isn’t running, so access points show without names or addresses.") }
        }
        var lastScans = 0
        let recording = await session.record(duration: command.duration, interval: command.interval) { recording in
            guard !quiet, recording.scans.count != lastScans else { return }
            lastScans = recording.scans.count
            let own = recording.link.last.map { " · you \($0.rssi) dBm" } ?? ""
            print("  scan \(recording.scans.count) · \(recording.scans.last?.readings.count ?? 0) radios heard\(own)")
        }
        if command.csv { print(recording.csv, terminator: ""); return }
        if json { try printObject(watchJSON(recording)); return }
        print("")
        for series in recording.series(limit: 10) {
            var range = ""
            if let low = series.low, let high = series.high, low != high { range = " (\(low) to \(high))" }
            let mark = series.own ? "●" : series.sameNetwork ? "○" : " "
            print("  \(mark) \(KilobatCLI.pad(series.radio.ssid, 24))\(KilobatCLI.pad("\(series.radio.band) ch \(series.radio.channel)", 14))\(series.median.map { "\($0) dBm" } ?? "—")\(range)\(series.missed > 0 ? " · missed \(series.missed)" : "")")
        }
        print("")
        print(recording.summary)
        print("Export with: kilobat wifi watch --csv > watch.csv")
    }

    static func watchJSON(_ recording: WiFiWatchRecording) -> [String: Any] {
        let format = ISO8601DateFormatter()
        let points: [[String: Any]] = recording.series(limit: 64).map { series in
            ["id": series.id, "ssid": series.radio.ssid, "band": series.radio.band, "channel": series.radio.channel, "joined": series.own, "sameNetwork": series.sameNetwork,
             "medianRssi": series.median ?? NSNull(), "minRssi": series.low ?? NSNull(), "maxRssi": series.high ?? NSNull(), "missedScans": series.missed,
             "rssi": series.points.map { value -> Any in value ?? NSNull() }]
        }
        return ["start": format.string(from: recording.start), "durationSeconds": Int(recording.duration), "intervalSeconds": Int(recording.interval),
                "scanTimes": recording.scans.map { format.string(from: $0.date) }, "skippedScans": recording.skipped, "linkSpreadDb": recording.linkSpread ?? NSNull(),
                "summary": recording.summary, "link": recording.link.map { ["time": format.string(from: $0.date), "rssi": $0.rssi] as [String: Any] }, "accessPoints": points]
    }

    /// `wifi steering`: band steering and sticky clients, from a scan and the roam history the app keeps.
    static func steering(json: Bool) async throws {
        let value = try await steeringReport()
        if json { try printObject(value); return }
        guard value["ssid"] is String else { print("Not on Wi-Fi, or the network’s name is hidden: open the Kilobat app (it has Location access) and run this again."); return }
        for finding in value["findings"] as? [[String: Any]] ?? [] {
            print((finding["level"] as? String == "caution" ? "! " : "✓ ") + (finding["title"] as? String ?? ""))
            print("  " + (finding["detail"] as? String ?? ""))
            if let advice = finding["advice"] as? String { print("  " + advice) }
        }
        print("")
        print(SteeringReport.note)
    }
    static func steeringReport() async throws -> [String: Any] {
        let probe = DiagnosticProbe()
        let radio = await probe.radio(), networks = try await nearbyNetworks(save: false)
        let app = AppRelay.appRunning ? await connection() : nil
        var current = RadioSample.basic(bssid: radio.bssid ?? (app?["bssid"] as? String), ssid: radio.ssid ?? (app?["ssid"] as? String), interface: radio.interface,
                                        rssi: radio.rssi, noise: radio.noise, transmitMbps: radio.transmitMbps, channel: radio.channel, band: radio.band)
        current.widthMHz = radio.widthMHz
        let roams = RoamSummary(NodeWatch.saved(directory: appFolder).roams, network: nil, since: Date().addingTimeInterval(-86_400))
        let findings = SteeringReport.evaluate(radio: current, networks: networks, supportedBands: await probe.supportedBands(), roams: roams.isEmpty ? nil : roams)
        return ["findings": findings.map { ["kind": $0.kind.rawValue, "level": $0.level.rawValue, "title": $0.title, "detail": $0.detail,
                                            "advice": $0.advice ?? NSNull(), "betterAccessPoint": $0.better ?? NSNull()] as [String: Any] },
                "note": SteeringReport.note, "ssid": current.ssid ?? NSNull(), "band": radio.band ?? NSNull(), "rssi": radio.rssi ?? NSNull()]
    }

    // MARK: Mesh nodes

    /// The nodes as the app sees them: BSSIDs need Location permission, which only the app has.
    static func nodesReport() async throws -> [String: Any] {
        guard AppRelay.appRunning else { throw CLIError("Wi-Fi nodes need the Kilobat app running: macOS shows access point addresses only to apps with Location access. Open it with kilobat open.") }
        guard let data = await AppRelay.ask("nodes", timeout: .seconds(4)), let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError("The Kilobat app didn’t answer. If it keeps not answering, update the app: older versions don’t list Wi-Fi nodes.")
        }
        return value
    }
    static func nodes(_ command: WiFiNodesCommand, json: Bool) async throws {
        switch command {
        case .list:
            let report = try await nodesReport()
            if json { try printObject(report); return }
            let state = report["state"] as? String ?? ""
            if state == "noLocation" { print("Kilobat needs Location access to see Wi-Fi nodes. Allow it in System Settings › Privacy & Security › Location Services."); return }
            if state == "notWiFi" { print("Not on Wi-Fi."); return }
            let nodes = report["nodes"] as? [[String: Any]] ?? []
            if nodes.isEmpty { print(state == "checking" ? "Kilobat is still taking its first reading. Try again in a minute." : "No nodes heard yet."); return }
            print("\(report["ssid"] as? String ?? "This network") · \(nodes.count == 1 ? "one node" : "\(nodes.count) nodes")")
            for node in nodes {
                let name = node["name"] as? String ?? "Unnamed node", current = node["current"] as? Bool == true
                let bands = (node["bands"] as? [String] ?? []).joined(separator: ", ")
                print("  \(current ? "●" : " ") \(KilobatCLI.pad(name, 20))\(KilobatCLI.pad("\(node["rssi"] as? Int ?? 0) dBm", 9))\(KilobatCLI.pad(bands, 16))\(node["id"] as? String ?? "")\(current ? "  (this Mac)" : "")")
            }
            if let headline = report["headline"] as? String {
                print("")
                print(headline + ". " + (report["detail"] as? String ?? ""))
                if let advice = report["advice"] as? String { print(advice) }
                print("Switch with: kilobat wifi reconnect")
            } else if state == "watching" { print("A closer node is in range; Kilobat waits two minutes before calling it.") }
            if nodes.contains(where: { $0["name"] is NSNull }) { print("Name one with: kilobat wifi nodes name <id> Office") }
        case .name(let node, let name):
            guard AppRelay.appRunning else { throw CLIError("Naming nodes needs the Kilobat app running. Open it with kilobat open.") }
            let action = "nodes|name|\(node.replacingOccurrences(of: "|", with: ""))|\(name)"
            guard let data = await AppRelay.ask(action, timeout: .seconds(4)), let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CLIError("The Kilobat app didn’t answer.") }
            if json { try printObject(value); return }
            guard value["named"] as? Bool == true else { throw CLIError(value["error"] as? String ?? "Couldn’t name that node.") }
            print(name.trimmingCharacters(in: .whitespaces).isEmpty ? "✓ Name cleared." : "✓ Named \(name).")
        case .reconnect:
            guard AppRelay.appRunning else {
                // Without the app there are no BSSIDs to aim at; off and on still lets macOS pick the strongest radio.
                try await WiFiConnection().restart()
                if json { try printObject(["reconnected": true, "method": "power", "node": NSNull(), "sentence": "Wi-Fi restarted. Open Kilobat to see which node you’re on."]) }
                else { print("✓ Wi-Fi turned off and on; macOS joins the strongest radio it hears. Open Kilobat to see which node you’re on.") }
                return
            }
            if !json { print("Reconnecting… Wi-Fi drops for a few seconds.") }
            guard let data = await AppRelay.ask("nodes|reconnect", timeout: .seconds(60)), let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CLIError("The Kilobat app didn’t answer.") }
            if json { try printObject(value); return }
            guard value["reconnected"] as? Bool == true else { throw CLIError(value["error"] as? String ?? "Couldn’t reconnect.") }
            print((value["better"] as? Bool == true ? "✓ " : "") + (value["sentence"] as? String ?? "Reconnected."))
        }
    }

    static func wifiStatus() async -> [String: Any] {
        let powered = (try? await WiFiConnection().connection().powered) ?? false
        let radio = await DiagnosticProbe().radio()
        // macOS shows Wi-Fi names only to apps with Location permission; the running app has it.
        var ssid = radio.ssid
        if ssid == nil { ssid = await appSSID() }
        var address: WiFiAddressState?
        if let interface = radio.interface { address = await PrivateWiFiAddress.read(interface: interface) }
        return ["macAddress": address?.current ?? NSNull(), "hardwareAddress": address?.hardware ?? NSNull(), "privateAddress": address?.isPrivate ?? NSNull(),
                "powered": powered, "ssid": ssid ?? NSNull(), "interface": radio.interface ?? NSNull(), "rssi": radio.rssi ?? NSNull(),
                "noise": radio.noise ?? NSNull(), "signalNoiseRatio": radio.snr ?? NSNull(), "channel": radio.channel ?? NSNull(), "band": radio.band ?? NSNull(),
                "transmitMbps": radio.transmitMbps ?? NSNull(), "score": radio.score ?? NSNull(), "widthMHz": radio.widthMHz ?? NSNull(),
                "standard": radio.standard ?? NSNull(), "phyMode": radio.phyMode ?? NSNull(), "security": radio.security ?? NSNull(),
                "securityLevel": radio.securityInfo?.level.rawValue ?? NSNull(), "securityNote": radio.securityInfo?.note ?? NSNull(),
                "transmitPowerDBm": radio.transmitPowerDBm ?? NSNull(), "countryCode": radio.countryCode ?? NSNull()]
    }
    // MARK: Roams and wakes

    static var appFolder: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat") }

    /// Every stay on an access point the app recorded, as a summary, CSV or a text report for an IT desk.
    static func roams(_ args: [String], json: Bool) throws {
        guard case .roams(let hours, let format) = try parse(args) else { return }
        let saved = NodeWatch.saved(directory: appFolder)
        let names = saved.places.values.reduce(into: [String: String]()) { $0.merge($1.names) { first, _ in first } }
        let summary = RoamSummary(saved.roams, network: nil, since: Date().addingTimeInterval(-Double(hours) * 3600), names: names)
        switch format {
        case .csv: print(summary.csv(names: names), terminator: ""); return
        case .text: print(summary.text(names: names, mac: nil, system: ProcessInfo.processInfo.operatingSystemVersionString), terminator: ""); return
        case .summary: break
        }
        if json {
            let format = ISO8601DateFormatter()
            try printObject(["roams": summary.roams, "lateRoams": summary.late, "briefStays": summary.brief, "ignoredBetter": summary.ignored.count,
                             "accessPoints": summary.accessPoints.map { ["bssid": $0.bssid, "name": $0.name ?? NSNull(), "band": $0.band, "channel": $0.channel, "stays": $0.visits,
                                                                        "dwellSeconds": Int($0.dwell.rounded()), "medianSignalAtRoam": $0.leftAt ?? NSNull()] as [String: Any] },
                             "stays": summary.visits.map { visit -> [String: Any] in
                                 ["bssid": visit.bssid, "ssid": visit.ssid ?? NSNull(), "band": visit.band, "channel": visit.channel, "joined": format.string(from: visit.start),
                                  "lastReading": format.string(from: visit.end), "dwellSeconds": Int(visit.dwell.rounded()), "signalAtJoin": visit.firstRSSI, "signalAtLeave": visit.lastRSSI,
                                  "weakest": visit.weakestRSSI, "ended": visit.ended?.rawValue ?? "current", "next": visit.next ?? NSNull(),
                                  "betterHeard": visit.ignored.map { ["bssid": $0.bssid, "rssi": $0.betterRSSI, "strongerBy": $0.difference, "seconds": Int($0.seconds.rounded())] as [String: Any] } ?? NSNull()]
                             }])
            return
        }
        guard !summary.isEmpty else { print("No Wi-Fi stays recorded in the last \(hours) hours. The Kilobat app records them while it runs, with Location access."); return }
        print("\(summary.roams) roam\(summary.roams == 1 ? "" : "s") in the last \(hours) hours · \(summary.late) at -75 dBm or weaker · \(summary.brief) stays under a minute")
        for point in summary.accessPoints.prefix(12) {
            print("  \(KilobatCLI.pad(point.name ?? point.bssid, 20))\(KilobatCLI.pad(point.band + " ch \(point.channel)", 14))\(KilobatCLI.pad("\(Int((point.dwell / 60).rounded())) min", 10))\(point.leftAt.map { "left at \($0) dBm" } ?? "")")
        }
        for line in summary.ignoredLines(names: names) { print(line) }
        print("Export with: kilobat wifi roams --csv > roams.csv, or --text for a report to paste.")
    }

    /// Each wake the app timed: when the link, the address, DNS and the first web request came back.
    static func wakes(_ args: [String], json: Bool) throws {
        guard case .wakes(let days) = try parse(args) else { return }
        let since = Date().addingTimeInterval(-Double(days) * 86_400)
        let wakes = NetworkJournal().wakes.filter { $0.woke >= since }
        if json {
            let format = ISO8601DateFormatter()
            try printObject(wakes.map { wake -> [String: Any] in
                ["woke": format.string(from: wake.woke), "network": wake.network ?? NSNull(), "interface": wake.interface ?? NSNull(), "wired": wake.wired,
                 "linkSeconds": wake.link ?? NSNull(), "addressSeconds": wake.address ?? NSNull(), "dnsSeconds": wake.dns ?? NSNull(), "internetSeconds": wake.internet ?? NSNull(),
                 "pingSeconds": wake.ping ?? NSNull(), "vpn": wake.vpn ?? NSNull(), "tunnelPassedTCP": wake.tunnelTCP ?? NSNull(), "watchedSeconds": wake.watched,
                 "problem": wake.problem == .none ? NSNull() : wake.plainProblem]
            })
            return
        }
        guard !wakes.isEmpty else { print("No wakes timed in the last \(days) days. The Kilobat app times each wake while it runs."); return }
        for wake in wakes.suffix(30) {
            let time = wake.woke.formatted(date: .abbreviated, time: .shortened)
            print("\(KilobatCLI.pad(time, 22))\(wake.plainLine)\(wake.problem == .none ? "" : "  ← " + wake.plainProblem)")
        }
        if wakes.count > 30 { print("… \(wakes.count - 30) earlier wakes; use --json for all.") }
    }
    private static func parse(_ args: [String]) throws -> WiFiHistoryCommand {
        do { return try WiFiHistoryCommand.parse(args) } catch let error as DiagnosticError { throw CLIError(error.message) }
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
        let result = WiFiPasswordLookup.live.find(ssid: Data(name.utf8))
        if let password = result.password { return password }
        switch result.failure ?? .notFound {
        case .notFound: throw CLIError("No saved password Kilobat can read for “\(name)” (\(result.codes)). Check the name, or look it up in Apple’s Passwords app.")
        case .cancelled: throw CLIError("Password access was cancelled.")
        case let failure: throw CLIError("\(failure.message) (\(result.codes))")
        }
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

    /// `band` defaults to the band this Mac is on.
    static func channelAdvice(band requested: String? = nil) async throws -> [String: Any] {
        let radio = await DiagnosticProbe().radio()
        let networks = try await nearbyNetworks()
        let band = requested ?? radio.band ?? "2.4 GHz"
        let onBand = radio.band == band
        // The Mac's own network is left out: a mesh shares its channel on purpose. Its name comes from the app when it runs.
        var ssid: String?
        if onBand { ssid = radio.ssid; if ssid == nil { ssid = await appSSID() } }
        let advice = ChannelPlan.advice(band: band, networks: networks, ssid: ssid, channel: onBand ? radio.channel : nil, width: onBand ? radio.widthMHz : nil)
        return ["band": band, "current": advice.current ?? NSNull(), "recommended": advice.recommended ?? NSNull(), "networksSeen": advice.networksSeen,
                "widthMHz": advice.widthMHz, "ownNetworkLeftOut": ssid != nil, "overlappingCurrent": advice.overlappingCurrent, "advice": advice.sentence,
                "recommendedIsDFS": advice.rows.first { $0.channel == advice.recommended }?.dfs ?? false,
                "channels": advice.rows.map { ["channel": $0.channel, "congestion": tenths($0.cost), "dfs": $0.dfs] as [String: Any] }]
    }
    static func channels(json: Bool) async throws {
        let advice = try await channelAdvice()
        if json { try printObject(advice); return }
        let band = advice["band"] as? String ?? "", current = advice["current"] as? Int, best = advice["recommended"] as? Int
        let rows = (advice["channels"] as? [[String: Any]] ?? []).map { (channel: $0["channel"] as? Int ?? 0, congestion: ($0["congestion"] as? NSNumber)?.doubleValue ?? 0) }
        guard !rows.isEmpty else { print("No nearby networks to compare on \(band)."); return }
        print("\(band) · you are on channel \(current.map(String.init) ?? "—") · \(advice["networksSeen"] as? Int ?? 0) networks seen")
        print("For \(advice["widthMHz"] as? Int ?? 20) MHz channels" + (advice["ownNetworkLeftOut"] as? Bool == true ? " · your own network's radios left out" : " · open the Kilobat app so your own network can be left out"))
        for row in rows { print("  Ch \(KilobatCLI.pad(String(row.channel), 5))\(String(format: "%6.0f", row.congestion))\(row.channel == best ? "  ← least crowded" : "")\(row.channel == current ? "  (current)" : "")") }
        if let sentence = advice["advice"] as? String { print(sentence) }
        print("An estimate from visible networks and their widths. Change the channel in your router’s settings.")
    }

    /// Nearby networks with names when the app can provide them; the CLI alone sees them unnamed.
    /// `save` false keeps a watch session's repeated scans out of the saved scans.
    static func nearbyNetworks(save: Bool = true) async throws -> [NearbyNetwork] {
        if let data = await AppRelay.ask("scan"), let networks = try? JSONDecoder().decode([NearbyNetwork].self, from: data), !networks.isEmpty {
            if save { SurveyJournal().saveScan(networks) }
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
            store.preferences.networkFastestDNS?.removeValue(forKey: key)
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
            .union((store.preferences.networkBudgetModes ?? [:]).keys).union(store.networkSessions.keys).subtracting(["unknown"])
    }
    static func network(_ text: String, store: TrafficStore) throws -> String {
        let matches = networkKeys(store).filter { $0 == text || store.networkSessions[$0]?.name.caseInsensitiveCompare(text) == .orderedSame }
        guard matches.count == 1, let key = matches.first else { throw CLIError(matches.isEmpty ? "No network matches “\(text)”." : "Several networks match; use the key from kilobat networks.") }
        return key
    }
    /// Sets the data cost of `network` (a key or name), or of the network the app is on.
    static func setCost(_ cost: NetworkCost, network: String?, store: TrafficStore) async throws -> [String: Any] {
        let app = network == nil ? await connection() : nil
        // Another change may have been saved while the app answered.
        store.reloadPreferences()
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
        case .metered: "is metered now. Kilobat " + (travel ? "switches to Essentials and skips" : "skips") + " scheduled speed tests there."
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
            let budgetMode = preferences.budgetMode(for: key)
            // macOS only reports the network the Mac is on.
            let metered: [String: Any] = key == current ? cost.fields(os: os)
                : ["metered": cost == .automatic ? NSNull() : cost == .metered, "osMetered": NSNull(), "meteredSource": cost == .automatic ? NSNull() : "you"]
            return ["key": key, "name": name(key), "profile": preferences.networkProfiles?[key]?.lowercased() ?? NSNull(), "remembered": preferences.networkProfiles?[key] != nil,
                    "budgetMode": budgetMode.rawValue, "budgetGB": budgetMode == .off ? NSNull() : (preferences.networkLimits?[key] ?? 5), "sessionBytes": (store.networkSessions[key]?.received ?? 0) + (store.networkSessions[key]?.sent ?? 0),
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
        let usage = "Use support-report [--hours 1…168] [--host <host>] [--route <watch-id>] [--include-sites] [--markdown|--html] [--output <file>] [--json]."
        var hours = 24, host: String?, format = "text", output: String?, includeSites = false, route: String?
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
            case "--route":
                guard index + 1 < args.count, !args[index + 1].hasPrefix("-") else { throw CLIError(usage) }
                route = args[index + 1]; index += 2
            case "--include-sites": includeSites = true; index += 1
            case "--markdown": format = "markdown"; index += 1
            case "--html": format = "html"; index += 1
            default: throw CLIError(usage)
            }
        }
        let report = try await makeSupportReport(hours: hours, host: host, includeSites: includeSites, route: route)
        let body: String
        if json { body = String(decoding: try DiagnosticsCLI.encode(report), as: UTF8.self) }
        else { body = format == "html" ? report.html : format == "markdown" ? report.markdown : report.text }
        if let output {
            let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
            try body.write(to: url, atomically: true, encoding: .utf8)
            print("Saved \(url.path). It leaves out your network's name and every local address.")
        } else { print(body) }
    }

    /// Without the names of the sites in it unless `includeSites`: the checked host and a slow service's name.
    /// `route` names a watched route (its id, or the first characters of it) to add.
    static func makeSupportReport(hours: Int, host: String?, includeSites: Bool = false, route: String? = nil) async throws -> SupportReport {
        let watch = try route.map { id -> WatchedRoute in
            let matches = SurveyJournal().watches.filter { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) && $0.rounds.count >= 2 }
            guard matches.count == 1, let watch = matches.first else { throw CLIError(matches.isEmpty ? "No watched route \(id). List them with kilobat route-history --watches." : "\(id) matches several watches; give more of the id.") }
            return watch
        }
        let journal = NetworkJournal()
        let check: DoctorReport? = if let host { await ConnectionDoctor.run(host, policy: await AwakeCLI.policy()) } else { nil }
        let plan = KilobatCLI.appDefaults.double(forKey: "speed.planMbps")
        // The dish's own log, when this network is a Starlink dish's; a live reading adds what the app hasn't saved yet.
        let dish = StarlinkJournal.load()
        // A slow route to one service, from what the app measured on this network.
        let services = journal.samples.last.map { ServiceSpeedReport(log: ServiceSpeedWatch.load(), network: $0.networkKey, speedTests: journal.speedTests) }
        let report = SupportReport.make(samples: journal.samples, events: journal.events, speedTests: journal.speedTests,
                                        hours: hours, planMbps: plan, plans: PlanSpeeds.settings(KilobatCLI.appDefaults), check: check,
                                        starlink: dish.evidence(network: journal.samples.last?.networkKey, hours: hours), serviceSpeed: services,
                                        macOSUpgrade: journal.macOSComparison(network: journal.samples.last?.networkKey))
        let routed = report.with(route: watch)
        return includeSites ? routed : routed.withoutSiteNames()
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
        Setting(key: "new-apps", values: "allow|alert|ask|block", detail: "What Essentials and Work do with apps that have no rule; alert allows and lists them for review (kilobat new-apps); ask holds them until you decide in the app",
                read: { NewAppPolicy.mode($0.preferences).rawValue },
                write: { store, value in _ = try FirewallCLI.setMode(store, newApps: value, allowApple: nil) }),
        Setting(key: "apple-software", values: "on|off", detail: "Let Apple's own software connect when new apps are asked about or blocked",
                read: { $0.preferences.allowApple == true ? "on" : "off" }, write: { store, value in store.preferences.allowApple = try toggle(value) }),
        Setting(key: "auto-travel", values: "on|off", detail: "Switch to Essentials on metered networks such as a phone hotspot",
                read: { $0.preferences.autoHotspot ? "on" : "off" }, write: { store, value in store.preferences.autoHotspot = try toggle(value) }),
        Setting(key: "pause-updaters", values: "on|off", detail: "Block updater helpers such as Google Updater and macOS Software Update while the network is metered",
                read: { UpdaterPause.enabled($0.preferences) ? "on" : "off" }, write: { store, value in store.preferences.pauseUpdaters = try toggle(value) ? nil : false }),
        Setting(key: "pause-cloud-sync", values: "on|off", detail: "Block Dropbox, Google Drive, OneDrive and other cloud storage clients while the network is metered; they catch up on an unmetered network",
                read: { CloudSyncPause.enabled($0.preferences) ? "on" : "off" }, write: { store, value in store.preferences.pauseCloudSync = try toggle(value) ? nil : false }),
        Setting(key: "kill-switch", values: "on|off", detail: "Pro: block new connections while the VPN is down; arms once the VPN has carried all traffic since boot (see kilobat vpn)",
                read: { KillSwitchState.enabled($0.preferences) ? "on" : "off" },
                write: { store, value in
                    let on = try toggle(value)
                    store.preferences.killSwitch = on ? true : nil
                    if !on { store.preferences.killSwitchAllowedUntil = nil }
                }),
        Setting(key: "kill-switch-lan", values: "on|off", detail: "While the kill switch blocks, still reach printers, file shares and other devices on the local network",
                read: { KillSwitchState.allowLAN($0.preferences) ? "on" : "off" }, write: { store, value in store.preferences.killSwitchLAN = try toggle(value) ? nil : false }),
        Setting(key: "scope", values: "external|wifi|wired", detail: "Which traffic counts toward per-app totals",
                read: { $0.preferences.trafficScope ?? "external" },
                write: { store, value in guard ["external", "wifi", "wired"].contains(value) else { throw CLIError("Use external, wifi or wired.") }; store.preferences.trafficScope = value }),
        Setting(key: "alerts", values: "on|off", detail: "Notify when the connection drops or degrades",
                read: { _ in defaults.object(forKey: "networkAlerts") as? Bool ?? true ? "on" : "off" }, write: { _, value in defaults.set(try toggle(value), forKey: "networkAlerts") }, appRestart: true),
        Setting(key: "router-alerts", values: "on|off", detail: "Pro: one notification when the router has been slower than its normal for days (on by default)",
                read: { _ in RouterWatch.alertsEnabled(defaults) ? "on" : "off" }, write: { _, value in defaults.set(try toggle(value), forKey: RouterWatch.alertsKey) }),
        Setting(key: "node-alerts", values: "on|off", detail: "One notification when the Mac stays on a far Wi-Fi mesh node for five minutes (on by default)",
                read: { _ in NodeWatch.alertsEnabled(defaults) ? "on" : "off" }, write: { _, value in defaults.set(try toggle(value), forKey: NodeWatch.alertsKey) }),
        Setting(key: "bluetooth-audio-alerts", values: "on|off", detail: "One notification per listening session when Wi-Fi may make Bluetooth audio crackle (on by default)",
                read: { _ in BluetoothAudioWatch.alertsEnabled(defaults) ? "on" : "off" }, write: { _, value in defaults.set(try toggle(value), forKey: BluetoothAudioWatch.alertsKey) }),
        Setting(key: "digest", values: "on|off", detail: "One notification with last week's outages, calls and data, Monday at 9 by default (on by default; day and time in the app)",
                read: { _ in DigestSchedule.load(defaults).enabled ? "on" : "off" }, write: { _, value in defaults.set(try toggle(value), forKey: DigestSchedule.enabledKey) }, appRestart: true),
        Setting(key: "block-alerts", values: "on|off", detail: "One notification per service, network and day when a service you use looks blocked on this network (on by default)",
                read: { _ in defaults.object(forKey: "blockAlerts") as? Bool ?? true ? "on" : "off" }, write: { _, value in defaults.set(try toggle(value), forKey: "blockAlerts") }, appRestart: true),
        Setting(key: "block-check-resolver", values: "cloudflare|quad9", detail: "Asked over DNS-over-HTTPS for a control answer, only while a failure is diagnosed (Cloudflare by default)",
                read: { TrustedResolver.chosen($0.preferences).rawValue },
                write: { store, value in
                    guard let resolver = TrustedResolver(rawValue: value) else { throw CLIError("Use cloudflare or quad9.") }
                    store.preferences.blockCheckResolver = resolver == .cloudflare ? nil : resolver.rawValue
                }),
        Setting(key: "outage-trace", values: "on|off", detail: "Run a route trace automatically during outages",
                read: { _ in defaults.object(forKey: "automaticOutageTrace") as? Bool ?? true ? "on" : "off" }, write: { _, value in defaults.set(try toggle(value), forKey: "automaticOutageTrace") }, appRestart: true),
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
        Setting(key: "menu-bar", values: "icon|speed|download,upload,latency,vpn,budget,game", detail: "What the menu bar item shows; vpn shows On, Split or Off and, with public-ip on, the exit IP's registry country",
                read: { _ in let shown = ["speed", "download", "upload", "latency", "vpn", "budget", "game"].filter { defaults.bool(forKey: "menu." + $0) }; return shown.isEmpty ? "icon" : shown.joined(separator: ",") },
                write: { _, value in
                    let items = value == "icon" ? [] : value.split(separator: ",").map(String.init)
                    guard items.allSatisfy(["speed", "download", "upload", "latency", "vpn", "budget", "game"].contains) else { throw CLIError("Use icon, or a comma list of speed, download, upload, latency and vpn.") }
                    for item in ["speed", "download", "upload", "latency", "vpn", "budget", "game"] { defaults.set(items.contains(item), forKey: "menu." + item) }
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
        try KilobatCLI.allow(["low-latency"] + args.dropFirst(), ["--for", "--until-quit"], valued: ["--for", "--until-quit"])
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
    static func tenths(_ value: Double) -> Any { value.isFinite && abs(value) < 1e15 ? NSDecimalNumber(value: Int((value * 10).rounded())).multiplying(byPowerOf10: -1) : NSNull() }
    static func printObject(_ value: Any) throws {
        print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
    }
}
