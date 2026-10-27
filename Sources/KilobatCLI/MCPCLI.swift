import Foundation
import Darwin
import KilobatCore

/// `kilobat mcp`: the CLI's diagnostics and controls as Model Context Protocol tools over stdio.
/// Tool results reuse the `--json` shapes so agents and scripts read the same fields.
@MainActor enum MCPCLI {
    static let instructions = """
    Kilobat reads this Mac's network: per-app traffic, Wi-Fi signal, router, internet and DNS latency, nearby networks and speed. \
    For slow or flaky internet, start with diagnose_network, then get_status to see which apps use bandwidth. \
    Run run_speedtest only when capacity or bufferbloat matters, and ask first on metered connections. \
    set_profile, set_app_rule and set_dns change the user's settings: describe the change and get the user's explicit confirmation before calling them. \
    Rules are saved locally; blocking requires the Kilobat app with its network filter enabled.
    """

    static func serve() async {
        if isatty(STDIN_FILENO) == 1 {
            FileHandle.standardError.write(Data("Kilobat MCP server on stdio. Add it to an MCP client as: kilobat mcp\n".utf8))
        }
        let server = MCPServer(name: "kilobat", title: "Kilobat", version: KilobatCLI.version, instructions: instructions, tools: tools) { data in
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
        do { for try await line in FileHandle.standardInput.bytes.lines { server.receive(Data(line.utf8)) } }
        catch { FileHandle.standardError.write(Data("kilobat mcp: \(error.localizedDescription)\n".utf8)) }
        await server.drain()
    }

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
            return .json(try KilobatCLI.statusJSON(store))
        },
        MCPTool(name: "diagnose_network", title: "Diagnose connection",
                description: "Checks Wi-Fi signal, the local router, internet latency, DNS and captive portals in a few seconds. Returns `health` (good, degraded, poor, unknown), plain-language `advice`, `signalScore` (0–100), `signalNoiseRatio` (dB), `routerLatencyMs`, `internetLatencyMs`, `internetJitterMs` and raw `measurements`: radio RSSI/noise/channel/band, router and internet ping average, jitter and loss, DNS lookup milliseconds, resolvers and captivePortal. Start here for slow or flaky internet. Same JSON as `kilobat diagnose --json`.",
                annotations: MCPToolAnnotations(readOnly: true, openWorld: true)) { _, _ in
            .json(try DiagnosticsCLI.diagnoseJSON(await DiagnosticProbe().snapshot()))
        },
        MCPTool(name: "scan_wifi", title: "Nearby Wi-Fi networks",
                description: "Lists nearby Wi-Fi networks with SSID, RSSI and noise (dBm), channel, band and channel width, to spot crowded channels or a stronger access point. macOS may require Location permission for the Kilobat app; an empty list means scanning is unavailable. Same JSON as `kilobat scan --json`.",
                annotations: readOnly) { _, _ in
            .json(try DiagnosticsCLI.encode(try await DiagnosticProbe().scan()))
        },
        MCPTool(name: "run_speedtest", title: "Speed and bufferbloat test",
                description: "Measures download and upload Mbps against Cloudflare plus latency under load (`bufferbloat`: Low, Moderate, High or Inconclusive; `addedLatencyMs`). Takes up to about 30 seconds and transfers up to `budget_mb` of data (80 MB by default). On a metered or hotspot connection, ask the user first and pass a small budget such as 10. Same JSON as `kilobat speedtest --json`.",
                inputSchema: schema(["budget_mb": ["type": "integer", "minimum": 1, "maximum": 80, "default": 80, "description": "Maximum data to transfer, in megabytes."]]),
                annotations: MCPToolAnnotations(readOnly: true, idempotent: false, openWorld: true)) { arguments, context in
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
                inputSchema: schema(["days": ["type": "integer", "minimum": 1, "maximum": 30, "default": 7, "description": "Number of days, including today."]]),
                annotations: readOnly) { arguments, _ in
            let days = try integer(arguments, "days", in: 1...30) ?? 7
            return .json(try DiagnosticsCLI.encode(UsageSummary(TrafficStore(startMonitoring: false).usage, days: days)))
        },
        MCPTool(name: "list_rules", title: "Current profile rules",
                description: "The active profile (travel, work or unrestricted), whether unknown apps are allowed by default, saved allow/block rules by bundle ID or process:<name>, unexpired temporary rules and the session data budget. Same JSON as `kilobat rules --json`.",
                annotations: readOnly) { _, _ in
            .json(try KilobatCLI.rulesJSON(TrafficStore(startMonitoring: false)))
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
                description: "Saves an allow or block rule for one app in the current travel or work profile; unrestricted has no rules. Identify the app by bundle ID (from get_status `apps[].id`, e.g. com.apple.Music) or process:<name>. Pass `minutes` for a temporary rule." + confirm + " Blocking takes effect only while the Kilobat app's network filter is enabled.",
                inputSchema: schema(["app": ["type": "string", "description": "Bundle ID such as com.example.App, or process:<name>."],
                                     "action": ["type": "string", "enum": ["allow", "block"]],
                                     "minutes": ["type": "integer", "minimum": 1, "maximum": 1440, "description": "Make the rule temporary."]], required: ["app", "action"]),
                annotations: change) { arguments, _ in
            let store = TrafficStore(startMonitoring: false)
            let app = try string(arguments, "app"), action = try string(arguments, "action")
            guard ["allow", "block"].contains(action) else { throw MCPToolError("action must be allow or block.") }
            let minutes = try integer(arguments, "minutes", in: 1...1440)
            try KilobatCLI.saveAppRule(app, allowed: action == "allow", minutes: minutes, in: store)
            var result: [String: Any] = ["app": app, "allowed": action == "allow", "profile": store.preferences.profile.rawValue.lowercased(), "saved": true]
            if let minutes { result["expires"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double(minutes) * 60)) }
            return .json(try object(result))
        },
        MCPTool(name: "set_dns", title: "Set DNS servers",
                description: "Sets the active network service's DNS to automatic (the network's own resolvers), cloudflare (1.1.1.1) or google (8.8.8.8). macOS shows the user an administrator password prompt." + confirm + " Suggest restoring automatic if the change does not help.",
                inputSchema: schema(["provider": ["type": "string", "enum": ["automatic", "cloudflare", "google"]]], required: ["provider"]),
                annotations: change) { arguments, _ in
            let (provider, service) = try await DiagnosticsCLI.setDNS(try string(arguments, "provider"))
            return .json(try object(["provider": provider.rawValue.lowercased(), "service": service, "servers": provider == .automatic ? [] : provider.addresses]))
        },
    ] }

    static func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }
    static func string(_ arguments: [String: Any], _ key: String) throws -> String {
        guard let value = arguments[key] as? String, !value.isEmpty else { throw MCPToolError("Missing required string argument '\(key)'.") }
        return value
    }
    static func integer(_ arguments: [String: Any], _ key: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let raw = arguments[key], !(raw is NSNull) else { return nil }
        guard let value = (raw as? NSNumber).flatMap({ Int(exactly: $0.doubleValue) }), range.contains(value) else {
            throw MCPToolError("'\(key)' must be an integer from \(range.lowerBound) to \(range.upperBound).")
        }
        return value
    }
    static func object(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
}
