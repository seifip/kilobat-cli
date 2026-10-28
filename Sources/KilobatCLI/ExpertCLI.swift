import Foundation
import KilobatCore

@MainActor enum ExpertCLI {
    static func run(_ args: [String]) async throws {
        let command = args.first ?? ""
        /// Rejects flags a command doesn't know instead of silently ignoring them.
        func allow(_ flags: Set<String>, valued: Set<String> = []) throws {
            var index = 1
            while index < args.count {
                guard flags.contains(args[index]) else { throw CLIError("Unexpected '\(args[index])'. Run kilobat \(command) --help.") }
                index += valued.contains(args[index]) ? 2 : 1
            }
        }
        func json<T: Encodable>(_ value: T) throws { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601; print(String(decoding: try encoder.encode(value), as: UTF8.self)) }
        switch command {
        case "blocked-history": try json(FilterEventJournal().events)
        case "destinations":
            try allow(["--pid", "--json"], valued: ["--pid"])
            let pid: Int32?
            if let index = args.firstIndex(of: "--pid") { guard index + 1 < args.count, let value = Int32(args[index + 1]), value > 0 else { throw CLIError("Use destinations [--pid PID] [--json].") }; pid = value } else { pid = nil }
            let rows = try await ExpertTools.destinations(pid: pid)
            if args.contains("--json") { try json(rows) } else { for row in rows { print("\(row.pid)\t\(row.process)\t\(row.transport)\t\(row.endpoint)\t\(row.state)") } }
        case "devices":
            if args.count == 4, args[1] == "name" {
                // Shares the names the app shows in its Devices view.
                var names = KilobatCLI.appDefaults.dictionary(forKey: "deviceNames") as? [String: String] ?? [:]
                let mac = args[2].lowercased(), name = args[3].trimmingCharacters(in: .whitespaces)
                guard mac.split(separator: ":").count == 6 else { throw CLIError("Use devices name <MAC-address> <name>; an empty name removes it.") }
                names[mac] = name.isEmpty ? nil : name
                KilobatCLI.appDefaults.set(names, forKey: "deviceNames")
                print(name.isEmpty ? "Name removed for \(mac)." : "✓ \(mac) is now “\(name)”."); return
            }
            try allow(["--bonjour", "--json"])
            let rows = await namedDevices()
            let services = args.contains("--bonjour") ? await ExpertTools.bonjour() : nil
            if args.contains("--json") {
                struct Output: Encodable { let devices: [LANDevice]; let bonjour: String? }
                if let services { try json(Output(devices: rows, bonjour: services)) } else { try json(rows) }
            } else { for row in rows { print("\(row.address)\t\(row.mac)\t\(row.interface)\t\(row.name)") }; if let services { print(services) } }
        case "http-check":
            let url = args.dropFirst().filter { $0 != "--json" }
            guard url.count == 1, args.count <= 3 else { throw CLIError("Use http-check <http-or-https-URL> [--json].") }
            guard args.contains("--json") else { print(try await DiagnosticHandoff.httpTiming(url: url[url.startIndex])); return }
            print(String(decoding: try JSONSerialization.data(withJSONObject: try await httpTiming(url[url.startIndex]), options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
        case "router-counters":
            guard args.count == 2 else { throw CLIError("Use router-counters <UPnP-control-URL>.") }; try json(await RouterCounters.read(controlURL: args[1]))
        case "connection-rules": try json(TrafficStore(startMonitoring: false).preferences.connectionRules ?? [])
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
            guard args.count == 2 else { throw CLIError("Use trace <host>.") }; let result = try await ExpertTools.route(to: args[1]); SurveyJournal().saveRoute(host: args[1], output: result); print(result)
        case "dns-benchmark": try json(await ExpertTools.benchmarkDNS())
        case "dns-profile":
            guard args.count == 2 else { throw CLIError("Use dns-profile <https-endpoint> > Kilobat-DNS.mobileconfig. Review and install manually.") }; print(String(decoding: try ExpertTools.encryptedDNSProfile(url: args[1]), as: UTF8.self))
        case "lan-test":
            guard args.count >= 2 else { throw CLIError("Use lan-test <server> [--reverse]. Requires iperf3 and a second local endpoint.") }; print(try await ExpertTools.lanSpeed(host: args[1], reverse: args.contains("--reverse")))
        case "spots":
            let journal = SurveyJournal()
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
        case "scan-history": try json(SurveyJournal().scans)
        case "route-history": try json(SurveyJournal().routes)
        case "outages", "speed-history":
            var since = Date.distantPast
            if args.count > 1 {
                guard args.count == 3, args[1] == "--days", let days = Int(args[2]), (1...365).contains(days) else { throw CLIError("Use \(command) [--days 1…365].") }
                since = Date().addingTimeInterval(-Double(days) * 86400)
            }
            let journal = NetworkJournal()
            if command == "outages" { try json(journal.events.filter { $0.start >= since }) } else { try json(journal.speedTests.filter { $0.result.date >= since }) }
        default: throw CLIError("Unknown expert command.")
        }
    }

    /// Neighbor cache with the names the user gave devices in the app.
    static func namedDevices() async -> [LANDevice] {
        let names = KilobatCLI.appDefaults.dictionary(forKey: "deviceNames") as? [String: String] ?? [:]
        return await ExpertTools.devices().map { row in var row = row; if let name = names[row.mac.lowercased()] ?? names[row.mac] { row.name = name }; return row }
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
