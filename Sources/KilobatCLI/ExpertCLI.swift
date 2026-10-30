import Foundation
import KilobatCore

@MainActor enum ExpertCLI {
    static func run(_ args: [String]) async throws {
        let command = args.first ?? ""
        func allow(_ flags: Set<String>, valued: Set<String> = []) throws { try KilobatCLI.allow(args, flags, valued: valued) }
        func json<T: Encodable>(_ value: T) throws { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601; print(String(decoding: try encoder.encode(value), as: UTF8.self)) }
        switch command {
        case "blocked-history": try allow(["--json"]); try json(FilterEventJournal().events)
        case "destinations":
            try allow(["--pid", "--json"], valued: ["--pid"])
            let pid: Int32?
            if let index = args.firstIndex(of: "--pid") { guard index + 1 < args.count, let value = Int32(args[index + 1]), value > 0 else { throw CLIError("Use destinations [--pid PID] [--json].") }; pid = value } else { pid = nil }
            let rows = try await ExpertTools.destinations(pid: pid)
            if args.contains("--json") { try json(rows) } else { for row in rows { print("\(row.pid)\t\(row.process)\t\(row.transport)\t\(row.endpoint)\t\(row.state)") } }
        case "devices":
            if args.count > 1, args[1] == "name" {
                // Piped output appends --json; naming has no JSON form, so it is ignored here.
                let args = args.filter { $0 != "--json" }
                // Shares the names the app shows in its Devices view.
                var names = KilobatCLI.appDefaults.dictionary(forKey: "deviceNames") as? [String: String] ?? [:]
                let mac = args.count == 4 ? args[2].lowercased() : "", name = args.count == 4 ? args[3].trimmingCharacters(in: .whitespaces) : ""
                guard mac.split(separator: ":").count == 6 else { throw CLIError("Use devices name <MAC-address> <name>; an empty name removes it.") }
                names[mac] = name.isEmpty ? nil : name
                KilobatCLI.appDefaults.set(names, forKey: "deviceNames")
                print(name.isEmpty ? "Name removed for \(mac)." : "✓ \(mac) is now “\(name)”."); return
            }
            try allow(["--bonjour", "--json"])
            let rows = try await namedDevices()
            let services = args.contains("--bonjour") ? await ExpertTools.bonjour() : nil
            if args.contains("--json") {
                struct Output: Encodable { let devices: [LANDevice]; let bonjour: String? }
                if let services { try json(Output(devices: rows, bonjour: services)) } else { try json(rows) }
            } else {
                if rows.isEmpty { print("No devices in the neighbor cache. Devices appear after this Mac talks to them.") }
                for row in rows { print("\(row.address)\t\(row.mac)\t\(row.interface)\t\(row.name)") }
                if let services { print(services) }
            }
        case "http-check":
            let url = args.dropFirst().filter { $0 != "--json" }
            guard url.count == 1, args.count <= 3 else { throw CLIError("Use http-check <http-or-https-URL> [--json].") }
            guard args.contains("--json") else { print(try await DiagnosticHandoff.httpTiming(url: url[url.startIndex])); return }
            print(String(decoding: try JSONSerialization.data(withJSONObject: try await httpTiming(url[url.startIndex]), options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
        case "router-counters":
            guard args.count == 2 else { throw CLIError("Use router-counters <UPnP-control-URL>.") }; try json(await RouterCounters.read(controlURL: args[1]))
        case "connection-rules": try allow(["--json"]); try json(TrafficStore(startMonitoring: false).preferences.connectionRules ?? [])
        case "remove-connection-rule":
            guard args.count == 2, let id = UUID(uuidString: args[1]) else { throw CLIError("Use remove-connection-rule <rule-UUID>.") }
            let store = TrafficStore(startMonitoring: false)
            guard store.preferences.connectionRules?.contains(where: { $0.id == id }) == true else { throw CLIError("Rule not found.") }
            store.preferences.connectionRules?.removeAll { $0.id == id }
            print("Rule removed. An open Kilobat app synchronizes the filter on its next sample.")
        case "connection-rule":
            guard (4...6).contains(args.count), ["allow", "block"].contains(args[1]), ExpertTools.validHost(args[3]) else { throw CLIError("Use connection-rule <allow|block> <bundle-id|process:name> <host> [port] [incoming|outgoing|any].") }
            let port = args.count > 4 ? args[4] : "", direction = args.count > 5 ? args[5] : "any"
            guard port.isEmpty || Int(port).map({ (1...65535).contains($0) }) == true, ["any", "incoming", "outgoing"].contains(direction) else { throw CLIError("Invalid port or direction.") }
            let store = TrafficStore(startMonitoring: false)
            guard store.preferences.profile != .unrestricted else { throw CLIError("Select Travel or Work before saving a connection rule.") }
            var rules = store.preferences.connectionRules ?? []; rules.append(ConnectionRule(app: args[2], host: args[3], port: port, direction: direction, allowed: args[1] == "allow", profile: store.preferences.profile.rawValue)); store.preferences.connectionRules = rules
            print("Rule saved. Requires an active signed filter; existing flows are unaffected.")
        case "signature":
            guard args.count == 2, let pid = Int32(args[1]) else { throw CLIError("Use signature <PID>.") }; print(try await DiagnosticHandoff.signature(pid: pid))
        case "discover":
            guard args.count == 2 else { throw CLIError("Use discover <private-address-or-/24-subnet>.") }; print(try await DiagnosticHandoff.discoverHosts(target: args[1]))
        case "bonjour":
            guard args.count == 2 else { throw CLIError("Use bonjour <_service._tcp>.") }; print(try await DiagnosticHandoff.browseBonjour(type: args[1]))
        case "capture":
            guard args.count == 3 else { throw CLIError("Use capture <interface> <output.pcap>. Records private packet headers for up to 15 seconds; requires administrator authorization.") }; try await DiagnosticHandoff.capture(interface: args[1], destination: URL(fileURLWithPath: args[2])); print("Capture saved.")
        case "wake":
            guard args.count == 2 else { throw CLIError("Use wake <MAC-address>.") }; try DeviceActions.wake(mac: args[1]); print("Wake packet sent; wake-up is not confirmed.")
        case "interfaces":
            try allow(["--json"])
            let rows = ExpertTools.interfaces()
            if args.contains("--json") { try json(rows) } else { for row in rows { print("\(row.name)\t\(row.up ? "up" : "down")\t↓ \(row.received)\t↑ \(row.sent)\(row.vpn ? "\tVPN (overlaps physical counters)" : "")") } }
        case "trace":
            let usage = "Use trace <host> [--rounds 2…10] [--json]."
            let rest = try positional(args, ["--rounds", "--json"], valued: ["--rounds"])
            guard rest.count == 1, let host = rest.first else { throw CLIError(usage) }
            var rounds = 1
            if let index = args.firstIndex(of: "--rounds") {
                guard index + 1 < args.count, let value = Int(args[index + 1]), (2...10).contains(value) else { throw CLIError(usage) }
                rounds = value
            }
            let journal = SurveyJournal()
            if rounds == 1 && !args.contains("--json") { let result = try await ExpertTools.route(to: host); journal.saveRoute(host: host, output: result); print(result); return }
            try await ExpertTools.routeRounds(to: host, rounds: rounds) { output in
                journal.saveRoute(host: host, output: output)
                FileHandle.standardError.write(Data("Trace \(journal.routes.filter { $0.host == host }.count) saved.\n".utf8))
            }
            let history = RouteHistory(host: host, routes: journal.routes)
            if args.contains("--json") { try json(history) } else { print(history.text) }
        case "ip":
            try allow(["--public", "--json"])
            let path = await ExitPath.current(lookup: args.contains("--public"))
            if args.contains("--json") { print(String(decoding: try JSONSerialization.data(withJSONObject: exitJSON(path, lookedUp: args.contains("--public")), options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)); return }
            print(path.summary + ".")
            if !path.connected.isEmpty { print("Connected VPNs: " + path.connected.joined(separator: ", ")) }
            if let address = path.publicAddress { print("Public IP: \(address.address)" + (address.countryName.map { ", registered in \($0)" } ?? "")); print(ExitPath.registryNote) }
            else if args.contains("--public") { print("Cloudflare didn't say which address it saw.") }
            else { print("Add --public to ask Cloudflare for your public IP. " + ExitPath.lookupNote) }
        case "speed-compare":
            let keys = try positional(args, ["--json"])
            let tests = NetworkJournal().speedTests
            let pair: (SavedSpeedTest, SavedSpeedTest)
            switch keys.count {
            case 0:
                guard let latest = SpeedComparison.latestPair(tests) else { throw CLIError("Two saved speed tests are needed. Run them in the Kilobat app, which keeps them with their context.") }
                pair = latest
            case 2:
                guard let a = SpeedComparison.find(keys[keys.startIndex], in: tests), let b = SpeedComparison.find(keys[keys.startIndex + 1], in: tests), a.id != b.id else {
                    throw CLIError("Name two different tests by place (1 is the newest) or by id from speed-history.")
                }
                pair = (a, b)
            default: throw CLIError("Use speed-compare [<test> <test>] [--json]: places (1 is the newest) or ids from speed-history; the newest two by default.")
            }
            let comparison = SpeedComparison(pair.0, pair.1)
            if args.contains("--json") { try json(comparison) } else { print(comparison.text) }
        case "dns-benchmark": try allow(["--json"]); try json(await ExpertTools.benchmarkDNS())
        case "dns-profile":
            guard args.count == 2 else { throw CLIError("Use dns-profile <https-endpoint> > Kilobat-DNS.mobileconfig. Review and install manually.") }; print(String(decoding: try ExpertTools.encryptedDNSProfile(url: args[1]), as: UTF8.self))
        case "lan-test":
            let hosts = try positional(args, ["--reverse", "--json"])
            guard hosts.count == 1 else { throw CLIError("Use lan-test <server> [--reverse] [--json]. Needs iperf3 on this Mac and iperf3 -s on the server; Kilobat installs nothing.") }
            let result = try await ExpertTools.lanSpeed(host: hosts[hosts.startIndex], reverse: args.contains("--reverse"))
            if args.contains("--json") { try json(result) } else { print(result.summary) }
        case "spots":
            let journal = SurveyJournal(), args = args.filter { $0 != "--json" }
            switch args.count > 1 ? args[1] : nil {
            case nil: try json(journal.spots)
            case "save":
                guard args.count >= 3 else { throw CLIError("Use spots save <name>.") }
                let name = args.dropFirst(2).joined(separator: " "), radio = await DiagnosticProbe().radio()
                guard radio.rssi != nil else { throw CLIError("No Wi-Fi signal to save. Connect to Wi-Fi first.") }
                journal.saveSpot(name: name, radio: radio)
                print("✓ Saved “\(name)”: \(radio.rssi ?? 0) dBm, score \(radio.score ?? 0)/100.")
            case "remove":
                guard args.count == 3, let id = UUID(uuidString: args[2]), journal.spots.contains(where: { $0.id == id }) else { throw CLIError("Use spots remove <id>, with an id from kilobat spots.") }
                journal.removeSpot(id); print("✓ Spot removed.")
            default: throw CLIError("Use spots, spots save <name> or spots remove <id>.")
            }
        case "scan-history": try allow(["--json"]); try json(SurveyJournal().scans)
        case "route-history":
            try allow(["--host", "--json"], valued: ["--host"])
            let routes = SurveyJournal().routes
            guard let index = args.firstIndex(of: "--host") else { try json(routes); return }
            guard index + 1 < args.count else { throw CLIError("Use route-history [--host <host>] [--json]. Hosts: " + RouteHistory.hosts(routes).joined(separator: ", ")) }
            let history = RouteHistory(host: args[index + 1], routes: routes)
            guard history.runs > 0 else { throw CLIError("No saved traces to \(args[index + 1]). Run kilobat trace \(args[index + 1]) --rounds 3.") }
            if args.contains("--json") { try json(history) } else { print(history.text) }
        case "outages", "speed-history":
            try allow(["--days", "--json"], valued: ["--days"])
            var since = Date.distantPast
            if let index = args.firstIndex(of: "--days") {
                guard index + 1 < args.count, let days = Int(args[index + 1]), (1...365).contains(days) else { throw CLIError("Use \(command) [--days 1…365].") }
                since = Date().addingTimeInterval(-Double(days) * 86400)
            }
            let journal = NetworkJournal()
            if command == "outages" { try json(journal.events.filter { $0.start >= since }) } else { try json(journal.speedTests.filter { $0.result.date >= since }) }
        default: throw CLIError("Unknown expert command.")
        }
    }

    /// The arguments that aren't flags (or a flag's value), after checking every flag is one of `flags`.
    static func positional(_ args: [String], _ flags: Set<String>, valued: Set<String> = []) throws -> [String] {
        var rest: [String] = [], index = 1
        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("--") {
                guard flags.contains(arg) else { throw CLIError("Unexpected '\(arg)'. Run kilobat \(args[0]) --help.") }
                index += valued.contains(arg) ? 2 : 1
            } else { rest.append(arg); index += 1 }
        }
        return rest
    }

    /// Where traffic leaves, for `kilobat ip --json` and MCP get_exit_path. `lookedUp` says whether Cloudflare was asked.
    static func exitJSON(_ path: ExitPath, lookedUp: Bool) -> [String: Any] {
        let address = path.publicAddress
        return ["date": ISO8601DateFormatter().string(from: path.date), "interface": path.interface ?? NSNull(), "tunnel": path.tunnel, "vpn": path.vpn.rawValue,
                "vpnName": path.vpnName ?? NSNull(), "vpnConnected": path.connected, "publicIP": address?.address ?? NSNull(),
                "publicIPCountry": address?.country ?? NSNull(), "publicIPCountryName": address?.countryName ?? NSNull(),
                "publicIPSource": lookedUp ? "Cloudflare (\(ExitPath.traceURL.absoluteString))" : NSNull(), "lookedUp": lookedUp,
                "summary": path.summary, "note": lookedUp ? ExitPath.registryNote : "Read from this Mac's routes and VPN list; nothing was sent anywhere."]
    }

    /// Neighbor cache with the names the user gave devices in the app.
    static func namedDevices() async throws -> [LANDevice] {
        let names = KilobatCLI.appDefaults.dictionary(forKey: "deviceNames") as? [String: String] ?? [:]
        let rows = await ExpertTools.devices()
        // With a router there is always at least its entry; an empty cache means macOS withheld it from this process.
        if rows.isEmpty, await defaultGateway() != nil {
            throw CLIError("macOS hid the device list from the CLI. Open Kilobat › Tools › Devices, or allow Local Network access for your terminal in System Settings › Privacy & Security › Local Network.")
        }
        return rows.map { row in var row = row; if let name = names[row.mac.lowercased()] ?? names[row.mac] { row.name = name }; return row }
    }
    static func defaultGateway() async -> String? {
        DiagnosticProbe.matches(#"gateway:\s+(\S+)"#, in: await CommandRunner.run("/sbin/route", ["-n", "get", "default"], timeout: 3).output).first
    }

    /// curl's cumulative timings in milliseconds, keyed for scripts.
    static func httpTiming(_ url: String) async throws -> [String: Any] {
        let output = try await DiagnosticHandoff.httpTiming(url: url)
        var timing: [String: Any] = ["url": url]
        let keys = ["DNS": "dnsMs", "Connect": "connectMs", "TLS": "tlsMs", "First byte": "firstByteMs", "Total": "totalMs"]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { continue }
            let label = parts.dropLast().joined(separator: " "), value = String(parts.last!)
            if label == "HTTP" { timing["status"] = Int(value) ?? 0 }
            else if let key = keys[label], let seconds = Double(value.dropLast()) { timing[key] = (seconds * 1000).rounded() }
        }
        return timing
    }
}
