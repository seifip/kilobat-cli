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
    When one site, API or app can't connect, diagnose_connection finds the layer that stops it. \
    Before a large download or upload or a long unattended run, call get_conditions: it reports metered links, Low Data Mode, VPN, battery and heat. \
    keep_awake stops idle sleep for a set time (closing the lid still sleeps the Mac); tell the user, ask first on battery, and call release_awake when done. \
    list_sessions shows earlier awake sessions and AI agent runs with the data they used. \
    get_app_bandwidth shows one app's traffic over an hour, day, week or month; get_access_policy what an app says it connects to. \
    set_profile, set_app_rule, set_new_app_mode, block_destination, decide_approval, set_dns and set_budget change the user's settings: describe the change and get the user's explicit confirmation before calling them. \
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
                description: "Measures download and upload Mbps against Cloudflare plus latency under load (`bufferbloat`: Low, Moderate, High or Inconclusive; `addedLatencyMs`). Also returns `voiceCalls`, `videoCalls` and `streaming` verdicts (the highest quality the bandwidth supports, and whether it may stutter) and `callWarnings` explaining any caution. Takes up to about 30 seconds and transfers up to `budget_mb` of data (80 MB by default). On a metered or hotspot connection, get the user's confirmation first and pass a small budget such as 10. Same JSON as `kilobat speedtest --json`.",
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
        MCPTool(name: "get_conditions", title: "Conditions for a long run",
                description: "Whether now suits a large download or upload or a long unattended run: `connected`, `network` (Wi-Fi, Ethernet, Cellular), `metered` (hotspot or marked expensive), `lowDataMode`, `vpn` and `vpnInterface`, `internetLatencyMs` and `internetLossPercent` from a quick ping, `power` (`batteryPercent`, `onAC`, `thermal`, `lowPowerMode`), whether Kilobat keeps the Mac awake (`keptAwake`, `awakeReasons`, `awakeUntil` for keep_awake) and one line of `advice`. Takes about 2 seconds. Same JSON as `kilobat conditions --json`.",
                annotations: MCPToolAnnotations(readOnly: true, openWorld: true)) { _, _ in
            .json(try object(await AwakeCLI.conditions(holdUntil: hold?.until)))
        },
        MCPTool(name: "diagnose_connection", title: "Why something can't connect",
                description: "Checks why one website, API or host can't be reached from this Mac, layer by layer: the Mac's network, VPN and proxy, DNS, Kilobat's own rules (blocklist, app and connection rules, data budget), the TCP connection, then TLS and the HTTP answer. Stops at the first layer that failed. Returns `verdict`, `next` (what to do), `ok` and `steps` (`layer`, `status`: ok, warning, failed or skipped, and `detail`). Pass `app` (a bundle ID or process:<name> from get_status) to include that app's rules. It checks from this Mac only; a sandbox, container or remote machine needs its own check. Takes up to about 20 seconds. Same JSON as `kilobat why <target> --json`.",
                inputSchema: schema(["target": ["type": "string", "description": "A host such as api.example.com, or an http or https URL."],
                                     "app": ["type": "string", "description": "Bundle ID such as com.example.App, or process:<name>."]], required: ["target"]),
                annotations: MCPToolAnnotations(readOnly: true, openWorld: true)) { arguments, _ in
            let app = arguments["app"] as? String
            let report = await ConnectionDoctor.run(try string(arguments, "target"), app: app?.isEmpty == false ? app : nil, policy: await AwakeCLI.policy())
            if report.steps.isEmpty { throw MCPToolError(report.verdict + " " + report.next) }
            return .json(try AwakeCLI.doctorJSON(report))
        },
        MCPTool(name: "list_sessions", title: "Awake sessions and agent runs",
                description: "Awake sessions and AI agent runs (Claude Code, Codex, Gemini CLI and others) the Kilobat app recorded over the last `days` (7 by default), newest first: `kind` (awake or agent), `title`, `start`, `end`, `ended` (Went quiet, Exited, Timer ended, Turned off), bytes `received` and `sent`, bytes per process (`apps`), `destinations` an agent contacted, `events` (network changes during the run), `batteryStart`, `batteryEnd` and `peakThermal`. Recorded only while the app runs. Same JSON as `kilobat sessions --json --days N`.",
                inputSchema: schema(["days": ["type": "integer", "minimum": 1, "maximum": 365, "default": 7, "description": "Number of days."]]),
                annotations: readOnly) { arguments, _ in
            .json(try DiagnosticsCLI.encode(AwakeCLI.history(days: try integer(arguments, "days", in: 1...365) ?? 7)))
        },
        MCPTool(name: "keep_awake", title: "Keep the Mac awake",
                description: "Stops this Mac from idle-sleeping for `minutes` (1–240) so a long build, download or agent run isn't cut off. Closing the lid still sleeps the Mac. Calling again replaces the previous hold; it ends early with release_awake or when this MCP server stops. Shows in `pmset -g assertions` as \"Kilobat: <reason>\". Changes no settings and is low risk: tell the user for how long, and on battery get their confirmation first.",
                inputSchema: schema(["minutes": ["type": "integer", "minimum": 1, "maximum": 240, "description": "How long to stay awake."],
                                     "reason": ["type": "string", "description": "What the Mac stays awake for, e.g. \"Running the test suite\"."]], required: ["minutes"]),
                annotations: MCPToolAnnotations(readOnly: false, destructive: false, idempotent: true)) { arguments, _ in
            guard let minutes = try integer(arguments, "minutes", in: 1...240) else { throw MCPToolError("Missing required integer argument 'minutes'.") }
            let reason = (arguments["reason"] as? String).map { String($0.prefix(80)) }.flatMap { $0.isEmpty ? nil : $0 } ?? "Agent run"
            _ = releaseHold()
            guard let assertion = SleepAssertion(reason: "Kilobat: " + reason) else { throw MCPToolError("macOS refused to keep the Mac awake.") }
            let until = Date().addingTimeInterval(Double(minutes) * 60)
            let timer = Task { @MainActor in
                try? await Task.sleep(for: .seconds(minutes * 60))
                if !Task.isCancelled { _ = releaseHold() }
            }
            hold = (assertion, until, timer)
            let power = PowerState.read()
            return .json(try object(["holding": true, "until": ISO8601DateFormatter().string(from: until), "reason": reason, "onAC": power.onAC, "batteryPercent": power.batteryPercent ?? NSNull(),
                                     "note": "Idle sleep is off until then. Closing the lid still sleeps the Mac."]))
        },
        MCPTool(name: "release_awake", title: "Let the Mac sleep again",
                description: "Ends a keep_awake hold early so the Mac can idle-sleep again. `released` is false when there was none. Releasing needs no confirmation.",
                annotations: MCPToolAnnotations(readOnly: false, destructive: false, idempotent: true)) { _, _ in
            .json(try object(["released": releaseHold()]))
        },
        MCPTool(name: "set_budget", title: "Set the data budget",
                description: "Sets the session data budget in GB (0.1–10000) for the current network. With the Kilobat app's filter on, new connections stop once it is used up in the travel and work profiles; unrestricted only tracks it." + confirm,
                inputSchema: schema(["gb": ["type": "number", "minimum": 0.1, "maximum": 10000]], required: ["gb"]),
                annotations: change) { arguments, _ in
            guard let raw = arguments["gb"] as? NSNumber, !isBoolean(raw), case let gb = raw.doubleValue, gb.isFinite, (0.1...10_000).contains(gb) else { throw MCPToolError("gb must be a number from 0.1 to 10000.") }
            TrafficStore(startMonitoring: false).preferences.limitGB = gb
            return .json(try object(["sessionBudgetGB": gb, "saved": true]))
        },
        MCPTool(name: "get_app_bandwidth", title: "One app's bandwidth over time",
                description: "Bytes one app sent and received in a calendar `range` (hour, day, week or month), split into buckets (minutes, hours, six-hour blocks or days), with totals and the peak rate and when it happened. Omit `app` for all traffic. `back` steps to earlier periods: 1 is the previous hour, day, week or month. Use the app names from get_usage_report `topApps` or get_status `apps[].name`; helpers count under the app that owns them. History is recorded while the Kilobat app runs. Same JSON as `kilobat bandwidth [app] <range> --back N --json`.",
                inputSchema: schema(["app": ["type": "string", "description": "App name, e.g. Google Chrome."],
                                     "range": ["type": "string", "enum": ["hour", "day", "week", "month"], "default": "day"],
                                     "back": ["type": "integer", "minimum": 0, "maximum": 400, "default": 0]]),
                annotations: readOnly) { arguments, _ in
            let range = FirewallCLI.rangeNamed((arguments["range"] as? String) ?? "day") ?? .day
            let app = (arguments["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .json(try object(FirewallCLI.bandwidth(app: app, range: range, back: try integer(arguments, "back", in: 0...400) ?? 0)))
        },
        MCPTool(name: "get_access_policy", title: "Connections an app declares",
                description: "What an app's developer says it connects to and why, from the Internet Access Policy file some apps ship (CleanShot X, Raycast, 1Password and others): `description`, `developer`, and `connections` with `hosts`, `port`, `purpose`, `denyConsequences` and whether each is `essential`. `declared` is false when the app ships none. Use it before blocking a domain an app needs. Same JSON as `kilobat access-policy <bundle-id> --json`.",
                inputSchema: schema(["app": ["type": "string", "description": "Bundle ID such as com.raycast.macos, or an app path."]], required: ["app"]),
                annotations: readOnly) { arguments, _ in
            .json(try object(try FirewallCLI.policy(app: try string(arguments, "app"))))
        },
        MCPTool(name: "set_new_app_mode", title: "How new apps are treated",
                description: "What Travel and Work do with apps that have no rule: `allow` lets them connect, `ask` holds their first connections until the user allows or blocks them in the Kilobat app (or you do with decide_approval), `block` blocks them silently. `allow_apple` lets Apple's own software through when asking or blocking. Unrestricted always allows." + confirm + " Takes effect only while the Kilobat app's network filter is enabled.",
                inputSchema: schema(["mode": ["type": "string", "enum": ["allow", "ask", "block"]],
                                     "allow_apple": ["type": "string", "enum": ["on", "off"]]]),
                annotations: change) { arguments, _ in
            let apple = (arguments["allow_apple"] as? String).map { $0 == "on" }
            return .json(try object(try FirewallCLI.setMode(TrafficStore(startMonitoring: false), newApps: arguments["mode"] as? String, allowApple: apple)))
        },
        MCPTool(name: "list_approvals", title: "Apps waiting for approval",
                description: "Apps the Kilobat filter is holding while new apps are asked about: `app` (rule key), `process`, `path`, `signer` and `signatureValid`, `pid`, `requests`, how many connections are `waiting`, and `destinations` (`host`, `address`, `port`). Held connections give up after a minute. Needs the Kilobat app running. Same JSON as `kilobat approvals --json`.",
                annotations: readOnly) { _, _ in
            .json(try FirewallCLI.encode(try await FirewallCLI.approvals()))
        },
        MCPTool(name: "decide_approval", title: "Allow or block a waiting app",
                description: "Answers an approval from list_approvals. `block` drops its held connections and saves a block rule in the active profile at once; pass `minutes` to block for a while only. `allow` doesn't apply by itself: it opens Kilobat's approval window on that app so the person confirms it, and returns `confirming: true`. Check the signature and destinations first." + confirm,
                inputSchema: schema(["app": ["type": "string"], "decision": ["type": "string", "enum": ["allow", "block"]],
                                     "minutes": ["type": "integer", "minimum": 1, "maximum": 1440]], required: ["app", "decision"]),
                annotations: change) { arguments, _ in
            let app = try string(arguments, "app"), decision = try string(arguments, "decision")
            guard ["allow", "block"].contains(decision) else { throw MCPToolError("decision must be allow or block.") }
            let result = try await FirewallCLI.decide(app, allowed: decision == "allow", minutes: try integer(arguments, "minutes", in: 1...1440))
            return .json(try object(["app": app, "decided": result.decided, "confirming": result.confirming]))
        },
        MCPTool(name: "block_destination", title: "Block a domain or IP",
                description: "Blocks or unblocks a `target` domain (subdomains included; *.example.com is accepted), IP address or CIDR range for every app, or with `app` for that app only as a connection rule in the active profile. Check get_access_policy first so you don't cut off a connection an app needs." + confirm + " Takes effect on new connections while the Kilobat app's network filter is enabled.",
                inputSchema: schema(["target": ["type": "string", "description": "example.com, *.example.com, 203.0.113.5 or 203.0.113.0/24."],
                                     "app": ["type": "string", "description": "Bundle ID or process:<name>; omit for every app."],
                                     "action": ["type": "string", "enum": ["block", "unblock"], "default": "block"]], required: ["target"]),
                annotations: change) { arguments, _ in
            let app = (arguments["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .json(try object(try FirewallCLI.blockDestination(try string(arguments, "target"), app: app, block: (arguments["action"] as? String ?? "block") != "unblock", store: TrafficStore(startMonitoring: false))))
        },
        MCPTool(name: "list_blocked_connections", title: "Recently blocked connections",
                description: "Connections the Kilobat filter blocked in the last `days` (1 by default, up to 7), newest first: `date`, `app`, `endpoint`, `direction` and `reason` (app rule, blocklist entry, connection rule, budget, default deny or a block when asked). Metadata only. Same data as `kilobat blocked-history`.",
                inputSchema: schema(["days": ["type": "integer", "minimum": 1, "maximum": 7, "default": 1]]),
                annotations: readOnly) { arguments, _ in
            let since = Date().addingTimeInterval(-Double(try integer(arguments, "days", in: 1...7) ?? 1) * 86_400)
            return .json(try FirewallCLI.encode(FilterEventJournal().events.filter { $0.date >= since }))
        },
    ] }

    /// The keep_awake hold, released by its timer, release_awake, or this process exiting.
    static var hold: (assertion: SleepAssertion, until: Date, timer: Task<Void, Never>)?
    static func releaseHold() -> Bool {
        guard let hold else { return false }
        hold.timer.cancel(); hold.assertion.release(); self.hold = nil
        return true
    }

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
