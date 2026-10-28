import Foundation
import Darwin
import KilobatCore

/// `kilobat mcp`: the CLI's diagnostics and controls as Model Context Protocol tools over stdio.
/// Tool results reuse the `--json` shapes so agents and scripts read the same fields.
@MainActor enum MCPCLI {
    static let instructions = """
    Kilobat reads this Mac's network: per-app traffic, Wi-Fi signal, router, internet and DNS latency, nearby networks and speed. \
    For slow or flaky internet, start with diagnose_network, then get_status to see which apps use bandwidth. \
    For Wi-Fi problems use get_wifi, scan_wifi and suggest_wifi_channel; for drops, get_network_history. \
    Run run_speedtest only when capacity or bufferbloat matters, and ask first on metered connections. \
    set_profile, set_app_rule, set_dns and set_budget change the user's settings: describe the change and get the user's explicit confirmation before calling them. \
    Rules are saved locally; blocking requires the Kilobat app with its network filter enabled. get_status reports `filteringActive` when the app is running.
    """

    static func serve() async {
        if isatty(STDIN_FILENO) == 1 {
            FileHandle.standardError.write(Data("Kilobat MCP server on stdio. Add it to an MCP client as: kilobat mcp\n".utf8))
        }
        let tools = tools, schemas = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.inputSchema) })
        let server = MCPServer(name: "kilobat", title: "Kilobat", version: KilobatCLI.version, instructions: instructions, tools: tools) { data in
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                if let reply = preflight(Data(line.utf8), schemas: schemas) { FileHandle.standardOutput.write(reply + Data("\n".utf8)) }
                else { server.receive(Data(line.utf8)) }
            }
        }
        catch { FileHandle.standardError.write(Data("kilobat mcp: \(error.localizedDescription)\n".utf8)) }
        await server.drain()
    }

    /// Rejects what MCPServer would otherwise accept: a request id that is not a string or number (MCP forbids null),
    /// and tool arguments outside the tool's schema, such as unknown keys or `true` where a number is expected.
    static func preflight(_ line: Data, schemas: [String: [String: Any]]) -> Data? {
        guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let method = request["method"] as? String, let id = request["id"] else { return nil }
        func failure(_ code: Int, _ message: String) -> Data? { try? object(["jsonrpc": "2.0", "id": code == -32600 ? NSNull() : id, "error": ["code": code, "message": message]]) }
        guard id is String || (id is NSNumber && !isBoolean(id)) else { return failure(-32600, "Invalid Request: id must be a string or number.") }
        guard method == "tools/call", let params = request["params"] as? [String: Any], let name = params["name"] as? String,
              let properties = schemas[name]?["properties"] as? [String: [String: Any]], let arguments = params["arguments"] as? [String: Any] else { return nil }
        for (key, value) in arguments.sorted(by: { $0.key < $1.key }) where !(value is NSNull) {
            guard let type = properties[key]?["type"] as? String else { return failure(-32602, "Unknown argument '\(key)' for \(name).") }
            let valid = type == "string" ? value is String : (value is NSNumber && !isBoolean(value))
            if !valid { return failure(-32602, "Argument '\(key)' must be \(type == "string" ? "a string" : "a number").") }
        }
        return nil
    }
    static func isBoolean(_ value: Any) -> Bool { CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() }

    static let readOnly = MCPToolAnnotations(readOnly: true)
    static let change = MCPToolAnnotations(readOnly: false, destructive: true, idempotent: true)
    static let confirm = " Changes the user's settings: explain what will change and get explicit confirmation before calling."

    static var tools: [MCPTool] { [
        MCPTool(name: "get_status", title: "Live traffic snapshot",
                description: "Per-app network traffic on this Mac right now: connection, network kind (Wi-Fi, Ethernet, Cellular), whether it is metered (hotspot), active profile, total download/upload bytes per second, session bytes, and each app's rates and saved allow/block rule. Samples for 2–8 seconds. Same JSON as `kilobat status --json`.",
                annotations: readOnly) { _, _ in
            let store = await KilobatCLI.sampledStore()
            defer { store.shutdown() }
            if let error = store.error { throw MCPToolError("Traffic monitoring failed: \(error)") }
            return .json(try KilobatCLI.statusJSON(store, app: await WiFiCLI.connection()))
        },
        MCPTool(name: "diagnose_network", title: "Diagnose connection",
                description: "Checks Wi-Fi signal, the local router, internet latency, DNS and captive portals in a few seconds. Returns `health` (good, degraded, poor, unknown), plain-language `advice`, `signalScore` (0–100), `signalNoiseRatio` (dB), `routerLatencyMs`, `internetLatencyMs`, `internetJitterMs` and raw `measurements`: radio RSSI/noise/channel/band, router and internet ping average, jitter and loss, DNS lookup milliseconds, resolvers and captivePortal. Start here for slow or flaky internet. Same JSON as `kilobat diagnose --json`.",
                annotations: MCPToolAnnotations(readOnly: true, openWorld: true)) { _, _ in
            let snapshot = await DiagnosticProbe().snapshot()
            return .json(try DiagnosticsCLI.diagnoseJSON(snapshot, ssid: snapshot.radio.ssid == nil ? await WiFiCLI.appSSID() : nil))
        },
        MCPTool(name: "scan_wifi", title: "Nearby Wi-Fi networks",
                description: "Lists nearby Wi-Fi networks with SSID, RSSI and noise (dBm), channel, band and channel width, to spot crowded channels or a stronger access point. Names come from the running Kilobat app, which has Location permission; without it SSIDs read \"Hidden network\". An empty list means scanning is unavailable. Same JSON as `kilobat scan --json`.",
                annotations: readOnly) { _, _ in
            .json(try DiagnosticsCLI.scanJSON(try await WiFiCLI.nearbyNetworks()))
        },
        MCPTool(name: "run_speedtest", title: "Speed and bufferbloat test",
                description: "Measures download and upload Mbps against Cloudflare plus latency under load (`bufferbloat`: Low, Moderate, High or Inconclusive; `addedLatencyMs`). Also returns `voiceCalls`, `videoCalls` and `streaming` verdicts (the highest quality the bandwidth supports, and whether it may stutter) and `callWarnings` explaining any caution. Takes up to about 30 seconds and transfers up to `budget_mb` of data (80 MB by default). On a metered or hotspot connection, ask the user first and pass a small budget such as 10. Same JSON as `kilobat speedtest --json`.",
                inputSchema: schema(["budget_mb": ["type": "integer", "minimum": 1, "maximum": 80, "default": 80, "description": "Maximum data to transfer, in megabytes."]]),
                annotations: MCPToolAnnotations(readOnly: false, destructive: false, idempotent: false, openWorld: true)) { arguments, context in
            let budget = try integer(arguments, "budget_mb", in: 1...80) ?? 80
            let (messages, relay) = AsyncStream.makeStream(of: String.self)
            let forward = Task { for await message in messages { context.progress(message) } }
            defer { relay.finish() }
            let result = try await SpeedTest.run(maximumBytes: budget * 1_000_000) { relay.yield($0) }
            relay.finish(); await forward.value
            return .json(try DiagnosticsCLI.speedJSON(result))
        },
        MCPTool(name: "get_usage_report", title: "Usage history",
                description: "Data used on this Mac over the last `days` (7 by default): download and upload totals, per-day totals and the top 10 apps by bytes. History is recorded while the Kilobat app runs and never leaves the Mac. Same JSON as `kilobat report --summary --json --days N`.",
                inputSchema: schema(["days": ["type": "integer", "minimum": 1, "maximum": 365, "default": 7, "description": "Number of days, including today."]]),
                annotations: readOnly) { arguments, _ in
            let days = try integer(arguments, "days", in: 1...365) ?? 7
            return .json(try DiagnosticsCLI.encode(UsageSummary(TrafficStore(startMonitoring: false).usage, days: days)))
        },
        MCPTool(name: "list_rules", title: "Profile rules",
                description: "Rules for the active profile, or for `profile` if given: the profile name, whether it is `active`, whether unknown apps are allowed by default, saved allow/block rules by bundle ID or process:<name>, unexpired temporary rules and the session data budget. Same JSON as `kilobat rules --json [--profile name]`.",
                inputSchema: schema(["profile": profileProperty]),
                annotations: readOnly) { arguments, _ in
            .json(try KilobatCLI.rulesJSON(TrafficStore(startMonitoring: false), profile: try profile(arguments), app: await WiFiCLI.connection()))
        },
        MCPTool(name: "set_profile", title: "Set profile",
                description: "Selects a profile. travel allows only essential apps to save mobile or hotspot data, work pauses distractions, unrestricted allows every app." + confirm + " Blocking takes effect only while the Kilobat app's network filter is enabled.",
                inputSchema: schema(["profile": ["type": "string", "enum": ["travel", "work", "unrestricted"]]], required: ["profile"]),
                annotations: change) { arguments, _ in
            let store = TrafficStore(startMonitoring: false)
            let profile = try KilobatCLI.selectProfile(try string(arguments, "profile"), in: store)
            return .json(try object(["profile": profile.rawValue.lowercased(), "saved": true, "note": "Blocking requires the Kilobat app with its network filter enabled."]))
        },
        MCPTool(name: "set_app_rule", title: "Allow or block an app",
                description: "Saves an allow or block rule for one app, or removes its rule with `reset` so it follows the profile default. Applies to the active travel or work profile, or to `profile` if given; unrestricted has no rules. Identify the app by bundle ID (from get_status `apps[].id`, e.g. com.apple.Music) or process:<name>. Pass `minutes` for a temporary rule." + confirm + " Blocking takes effect only while the Kilobat app's network filter is enabled.",
                inputSchema: schema(["app": ["type": "string", "description": "Bundle ID such as com.example.App, or process:<name>."],
                                     "action": ["type": "string", "enum": ["allow", "block", "reset"]],
                                     "profile": profileProperty,
                                     "minutes": ["type": "integer", "minimum": 1, "maximum": 1440, "description": "Make the rule temporary."]], required: ["app", "action"]),
                annotations: change) { arguments, _ in
            let store = TrafficStore(startMonitoring: false)
            let app = try string(arguments, "app"), action = try string(arguments, "action")
            guard ["allow", "block", "reset"].contains(action) else { throw MCPToolError("action must be allow, block or reset.") }
            let target = try profile(arguments) ?? store.preferences.profile
            if action == "reset" {
                return .json(try object(["app": app, "profile": target.rawValue.lowercased(), "removed": store.removeRule(app, in: target)]))
            }
            let minutes = try integer(arguments, "minutes", in: 1...1440)
            try KilobatCLI.saveAppRule(app, allowed: action == "allow", minutes: minutes, profile: target, in: store)
            var result: [String: Any] = ["app": app, "allowed": action == "allow", "profile": target.rawValue.lowercased(), "saved": true]
            if let minutes { result["expires"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double(minutes) * 60)) }
            return .json(try object(result))
        },
        MCPTool(name: "set_dns", title: "Set DNS servers",
                description: "Sets the active network service's DNS to automatic (the network's own resolvers), cloudflare (1.1.1.1), google (8.8.8.8) or quad9 (9.9.9.9), or with `flush` clears the DNS cache, which helps after a site moved or a stale \"server not found\" but does not make DNS faster. macOS shows the user an administrator password prompt." + confirm + " Suggest restoring automatic if a change does not help.",
                inputSchema: schema(["provider": ["type": "string", "enum": ["automatic", "cloudflare", "google", "quad9", "flush"]]], required: ["provider"]),
                annotations: change) { arguments, _ in
            if try string(arguments, "provider") == "flush" {
                try await NetworkTools.flushDNS()
                return .json(try object(["flushed": true]))
            }
            let (provider, service) = try await DiagnosticsCLI.setDNS(try string(arguments, "provider"))
            return .json(try object(["provider": provider.rawValue.lowercased(), "service": service, "servers": provider == .automatic ? [] : provider.addresses]))
        },
        MCPTool(name: "get_wifi", title: "Wi-Fi connection",
                description: "The current Wi-Fi link: whether Wi-Fi is on, network name (ssid, null if unavailable), interface, RSSI, noise and signal-to-noise ratio (dB), channel, band, negotiated link rate and a 0–100 signal score. Faster than diagnose_network when only the radio matters. Same JSON as `kilobat wifi status --json`.",
                annotations: readOnly) { _, _ in
            .json(try object(await WiFiCLI.wifiStatus()))
        },
        MCPTool(name: "suggest_wifi_channel", title: "Least crowded channel",
                description: "Estimates congestion on each candidate channel in the current band from nearby networks and their widths, and names the least crowded one (`recommended`). The user changes the channel in their router's settings; hidden interference can change the best choice. Same JSON as `kilobat channels --json`.",
                annotations: readOnly) { _, _ in
            .json(try object(try await WiFiCLI.channelAdvice()))
        },
        MCPTool(name: "get_network_history", title: "Network history",
                description: "Records the Kilobat app kept while running. `kind`: `outages` (drops: Unreachable, Wi-Fi roam, Network changed, with start and end), `speed_tests` (earlier speed test results per network) or `health` (periodic router, internet, jitter, loss and DNS measurements). `days` limits the window (1 by default for health, 30 otherwise). A gap means the app was not running, not that nothing happened.",
                inputSchema: schema(["kind": ["type": "string", "enum": ["outages", "speed_tests", "health"]],
                                     "days": ["type": "integer", "minimum": 1, "maximum": 30]], required: ["kind"]),
                annotations: readOnly) { arguments, _ in
            let kind = try string(arguments, "kind")
            let days = try integer(arguments, "days", in: 1...30)
            let since = Date().addingTimeInterval(-Double(days ?? (kind == "health" ? 1 : 30)) * 86400)
            let journal = NetworkJournal()
            switch kind {
            case "outages": return .json(try DiagnosticsCLI.encode(journal.events.filter { $0.start >= since }))
            case "speed_tests": return .json(try DiagnosticsCLI.encode(journal.speedTests.filter { $0.result.date >= since }))
            case "health": return .json(try JSONSerialization.data(withJSONObject: WiFiCLI.healthRows(hours: (days ?? 1) * 24), options: [.sortedKeys, .withoutEscapingSlashes]))
            default: throw MCPToolError("kind must be outages, speed_tests or health.")
            }
        },
        MCPTool(name: "benchmark_dns", title: "Compare DNS resolvers",
                description: "Times lookups of three domains through the system resolver, Cloudflare (1.1.1.1), Google (8.8.8.8) and Quad9 (9.9.9.9). Each entry has `resolver`, `milliseconds` (null if none answered) and `replies` out of 3. Run it twice before recommending a change. Same JSON as `kilobat dns-benchmark`.",
                annotations: MCPToolAnnotations(readOnly: true, openWorld: true)) { _, _ in
            .json(try DiagnosticsCLI.encode(await ExpertTools.benchmarkDNS()))
        },
        MCPTool(name: "check_url", title: "Time one website",
                description: "Requests the headers of one http or https URL and returns the HTTP `status` and cumulative `dnsMs`, `connectMs`, `tlsMs`, `firstByteMs` and `totalMs`, to tell a slow site from a slow connection or DNS. Same JSON as `kilobat http-check <URL> --json`.",
                inputSchema: schema(["url": ["type": "string", "description": "An http or https URL."]], required: ["url"]),
                annotations: MCPToolAnnotations(readOnly: true, openWorld: true)) { arguments, _ in
            .json(try object(try await ExpertCLI.httpTiming(try string(arguments, "url"))))
        },
        MCPTool(name: "list_connections", title: "Open connections by process",
                description: "Open network sockets on this Mac: `pid`, `process`, `transport`, `endpoint` (local -> remote address:port) and `state`. Pass `pid` to narrow to one process, for example one found in get_status `apps[].processIDs`. Same JSON as `kilobat destinations --json`.",
                inputSchema: schema(["pid": ["type": "integer", "minimum": 1]]),
                annotations: readOnly) { arguments, _ in
            .json(try DiagnosticsCLI.encode(try await ExpertTools.destinations(pid: try integer(arguments, "pid", in: 1...Int(Int32.max)).map(Int32.init))))
        },
        MCPTool(name: "list_devices", title: "Devices on the local network",
                description: "Devices this Mac has recently talked to on the local network (the ARP neighbor cache): `address`, `mac`, `interface` and `name`, including names the user gave them in Kilobat. Not a full network scan. Same JSON as `kilobat devices --json`.",
                annotations: readOnly) { _, _ in
            .json(try DiagnosticsCLI.encode(try await ExpertCLI.namedDevices()))
        },
        MCPTool(name: "trace_route", title: "Trace the route to a host",
                description: "A 12-hop route probe to `host`, as plain text. A latency jump that persists to the last hop is real; a single slow hop that recovers is usually a router deprioritizing probes. Takes up to about 30 seconds. Same output as `kilobat trace <host>`.",
                inputSchema: schema(["host": ["type": "string", "description": "Hostname or IP address."]], required: ["host"]),
                annotations: MCPToolAnnotations(readOnly: true, openWorld: true)) { arguments, _ in
            let host = try string(arguments, "host")
            let result = try await ExpertTools.route(to: host)
            SurveyJournal().saveRoute(host: host, output: result)
            return .text(result)
        },
        MCPTool(name: "list_networks", title: "Known networks",
                description: "Networks Kilobat has seen, with `key`, `name`, the `profile` and `budgetGB` remembered for each (null if none) and data used in the current session there. Same JSON as `kilobat networks --json`.",
                annotations: readOnly) { _, _ in
            .json(try JSONSerialization.data(withJSONObject: WiFiCLI.networkRows(TrafficStore(startMonitoring: false)), options: [.sortedKeys, .withoutEscapingSlashes]))
        },
        MCPTool(name: "set_budget", title: "Set the data budget",
                description: "Sets the session data budget in GB (0.1–10000) for the current network. With the Kilobat app's filter on, new connections stop once it is used up in the travel and work profiles; unrestricted only tracks it." + confirm,
                inputSchema: schema(["gb": ["type": "number", "minimum": 0.1, "maximum": 10000]], required: ["gb"]),
                annotations: change) { arguments, _ in
            guard let raw = arguments["gb"] as? NSNumber, !isBoolean(raw), case let gb = raw.doubleValue, gb.isFinite, (0.1...10_000).contains(gb) else { throw MCPToolError("gb must be a number from 0.1 to 10000.") }
            TrafficStore(startMonitoring: false).preferences.limitGB = gb
            return .json(try object(["sessionBudgetGB": gb, "saved": true]))
        },
    ] }

    static func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }
    static let profileProperty: [String: Any] = ["type": "string", "enum": ["travel", "work", "unrestricted"], "description": "Defaults to the active profile."]
    static func profile(_ arguments: [String: Any]) throws -> NetworkProfile? {
        guard let raw = arguments["profile"], !(raw is NSNull) else { return nil }
        guard let name = raw as? String, let value = NetworkProfile.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) else { throw MCPToolError("profile must be travel, work or unrestricted.") }
        return value
    }
    static func string(_ arguments: [String: Any], _ key: String) throws -> String {
        guard let value = arguments[key] as? String, !value.isEmpty else { throw MCPToolError("Missing required string argument '\(key)'.") }
        return value
    }
    static func integer(_ arguments: [String: Any], _ key: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let raw = arguments[key], !(raw is NSNull) else { return nil }
        guard !isBoolean(raw), let value = (raw as? NSNumber).flatMap({ Int(exactly: $0.doubleValue) }), range.contains(value) else {
            throw MCPToolError("'\(key)' must be an integer from \(range.lowerBound) to \(range.upperBound).")
        }
        return value
    }
    static func object(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
}
