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
    Run run_speedtest only when capacity or bufferbloat matters, and ask first on metered connections. When two results differ, compare_speed_tests lists what changed between them; for whether the user gets the speed they pay for, use get_plan_check. \
    For where traffic leaves (VPN or not) use get_exit_path; ask for public_ip only when the user wants it, since that contacts Cloudflare, and never present a VPN or an exit country as proof of privacy. \
    For slow hops along a route over time, trace_route with rounds and get_route_history; for the local network alone, run_lan_test against a device running iperf3 -s. \
    When calls, game streaming or remote desktops stutter but speed looks fine, run run_stutter_test, then get_nearby_radios for AirDrop and Bluetooth. \
    For which CS2, Dota 2, Deadlock or Fortnite region to play on, get_game_ping pings each data center and names the closest. \
    When one site, API or app can't connect, diagnose_connection finds the layer that stops it. \
    Before a large download or upload or a long unattended run, call get_conditions: it reports metered links, Low Data Mode, VPN, battery and heat. \
    get_updaters says which updaters Kilobat pauses on metered networks, which update bytes still got through, and which apps update from inside themselves. \
    keep_awake stops idle sleep for a set time; tell the user, ask first on battery, and call release_awake when done. Closing the lid still sleeps the Mac unless you pass lid_closed, which needs the user's explicit confirmation every time. \
    list_sessions shows earlier awake sessions and AI agent runs with the data they used. \
    When a router, ISP or carrier reports more or less data than Kilobat, compare_usage sets the two side by side for the same period with the hours Kilobat recorded and likely reasons; never call either figure wrong. \
    get_app_bandwidth shows one app's traffic over an hour, day, week or month; get_access_policy what an app says it connects to. \
    set_profile, set_app_rule, set_new_app_mode, block_destination, decide_approval, set_dns, set_budget, set_app_quota, set_network_cost and set_updater_pause change the user's settings: describe the change and get the user's explicit confirmation before calling them. \
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
            let valid = type == "string" ? value is String : type == "boolean" ? isBoolean(value) : (value is NSNumber && !isBoolean(value))
            if !valid { return failure(-32602, "Argument '\(key)' must be \(type == "string" ? "a string" : type == "boolean" ? "true or false" : "a number").") }
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
                description: "Measures download and upload Mbps against Cloudflare plus latency under load (`bufferbloat`: Low, Moderate, High or Inconclusive; `addedLatencyMs`). Also returns `voiceCalls`, `videoCalls` and `streaming` verdicts (the highest quality the bandwidth supports, and whether it may stutter) and `callWarnings` explaining any caution. Takes up to about 30 seconds and transfers up to `budget_mb` of data (80 MB by default). On a metered or hotspot connection, get the user's confirmation first and pass a small budget such as 10. `measurements` also records `streams`, `server` (the Cloudflare data center) and `context` (interface, connection kind, VPN, Wi-Fi band, channel, signal and link rate, and `otherBytes` this Mac moved during the test), and `method` says how it measured. One connection (the default) reads lower than Ookla, fast.com or networkQuality on fast or distant links because those open several; pass `parallel` for four connections at once when the user compares with such a site. Same JSON as `kilobat speedtest --json`.",
                inputSchema: schema(["budget_mb": ["type": "integer", "minimum": 1, "maximum": 80, "default": 80, "description": "Maximum data to transfer, in megabytes."],
                                     "parallel": ["type": "boolean", "default": false, "description": "Four connections at once instead of one, sharing the same data budget."]]),
                annotations: MCPToolAnnotations(readOnly: false, destructive: false, idempotent: false, openWorld: true)) { arguments, context in
            let budget = try integer(arguments, "budget_mb", in: 1...80) ?? 80
            let parallel = try boolean(arguments, "parallel") ?? false
            let (messages, relay) = AsyncStream.makeStream(of: String.self)
            let forward = Task { for await message in messages { context.progress(message) } }
            defer { relay.finish() }
            let result = try await SpeedTest.run(maximumBytes: budget * 1_000_000, streams: parallel ? SpeedTest.parallelStreams : 1) { relay.yield($0) }
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
        MCPTool(name: "compare_usage", title: "Compare with a router or provider",
                description: "Sets a router's, ISP's or carrier's data figure beside what Kilobat recorded on this Mac for the same period, networks and direction. Pass `total` and its `unit` exactly as the router or provider shows them (GB is decimal, GiB binary; many providers write GB for either), `direction` (both, download or upload) and the period: `from` and `to` (2026-10-01, 2026-10-01 18:00 or ISO 8601 with an offset; a date-only `to` includes that day; ask the user for the provider's time zone when it matters) or a `period` preset. `network` limits it to one network by name or key from list_networks. Returns Kilobat's `kilobatBytes` and `kilobatAmount` in the same unit, `downloadBytes`, `uploadBytes`, `differenceBytes` (the figure minus Kilobat), `alternateBytes` (the figure read in the other unit system), `localBytes` (local network and AirDrop, not counted), `unattributedBytes` (packet headers and the like, counted), `otherNetworkBytes`, `periodHours`, `recordedHours`, `coverage`, `gaps` (`start`, `end`, `hours`, `reason`: asleep, notRecorded, otherNetwork, beforeHistory or notYet), `networks`, `topApps`, a `summary` and `reasons`, the likely causes of the difference in plain English, most likely first. Kilobat sees only this Mac and only while it runs, so a router or provider total is usually higher; relay the reasons and never conclude that the provider, the router or Kilobat is wrong, or that the difference proves malware or a billing error. Same JSON as `kilobat report compare --json`.",
                inputSchema: schema(["total": ["type": "number", "minimum": 0, "description": "The router's or provider's figure, e.g. 40."],
                                     "unit": ["type": "string", "enum": UsageComparison.Unit.allCases.map(\.rawValue), "description": "The unit the router or provider shows."],
                                     "direction": ["type": "string", "enum": ["both", "download", "upload"], "default": "both"],
                                     "from": ["type": "string", "description": "Start of the figure's period, e.g. 2026-10-01."],
                                     "to": ["type": "string", "description": "End of the figure's period, e.g. 2026-10-31 (that day included)."],
                                     "period": ["type": "string", "enum": UsageComparison.Preset.allCases.map(\.rawValue), "description": "A ready-made period instead of from and to."],
                                     "network": ["type": "string", "description": "A network name or key from list_networks; every network when left out."]], required: ["total", "unit"]),
                annotations: readOnly) { arguments, _ in
            guard let total = arguments["total"] as? NSNumber, !isBoolean(total), total.doubleValue.isFinite, total.doubleValue >= 0 else { throw MCPToolError("Pass total, the router's or provider's figure.") }
            do {
                let network = (arguments["network"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return .json(try ReportCLI.comparison(total: String(total.doubleValue), unit: try string(arguments, "unit"), direction: arguments["direction"] as? String,
                                                      from: arguments["from"] as? String, to: arguments["to"] as? String, period: arguments["period"] as? String,
                                                      networks: network.map { [$0] } ?? []).json(pretty: false))
            } catch let error as CLIError { throw MCPToolError(error.message) }
        },
        MCPTool(name: "list_rules", title: "Profile rules",
                description: "Rules for the active profile, or for `profile` if given: the profile name, whether it is `active`, whether unknown apps are allowed by default, saved allow/block rules by bundle ID or process:<name>, unexpired temporary rules, the data `budget` (limit, `cycle`, `alerts`, `usedBytes` this cycle and when it `resets`) and app `quotas` with their use. Same JSON as `kilobat rules --json [--profile name]`.",
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
                description: "Devices this Mac has recently talked to on the local network (the ARP neighbor cache), with what Kilobat remembers about each on this network: `address`, `mac`, `interface`, `name` (the user's name for it, else the device's own or its maker's), `status` (new: joined since Kilobat began watching this home network and not answered yet; known: the user's, or there when watching began; unknown: the user said they don't recognise it; ignored; null when Kilobat hasn't recorded this network), `verdict`, `friendlyName`, `hostname`, `vendor`, `privateAddress` (a randomised Wi-Fi address with no maker), `firstSeen`, `lastSeen` and `present`. Pass `all` to add remembered devices that aren't in the cache now. Not a full network scan. Never present a new or unknown device as an intruder: it is a device the user hasn't identified. Same JSON as `kilobat devices --json`.",
                inputSchema: schema(["all": ["type": "boolean", "default": false, "description": "Also list devices remembered on this network that aren't in the neighbor cache now."]]),
                annotations: readOnly) { arguments, _ in
            .json(try DiagnosticsCLI.encode(try await ExpertCLI.deviceListing(all: try boolean(arguments, "all") ?? false)))
        },
        MCPTool(name: "trace_route", title: "Trace the route to a host",
                description: "A 12-hop route probe to `host`, as plain text. A latency jump that persists to the last hop is real; a single slow hop that recovers is usually a router deprioritizing probes. Each trace is saved. Pass `rounds` (2–5) to trace several times with three probes a hop, like mtr: the text then ends with each hop's loss, best, average, worst and last delay over every saved trace to that host and a line on where the delay starts. Takes up to about 30 seconds a round. Same output as `kilobat trace <host> [--rounds N]`.",
                inputSchema: schema(["host": ["type": "string", "description": "Hostname or IP address."],
                                     "rounds": ["type": "integer", "minimum": 1, "maximum": 5, "default": 1, "description": "Traces to run in a row."]], required: ["host"]),
                annotations: MCPToolAnnotations(readOnly: true, openWorld: true)) { arguments, context in
            let host = try string(arguments, "host")
            let rounds = try integer(arguments, "rounds", in: 1...5) ?? 1
            let journal = SurveyJournal()
            guard rounds > 1 else {
                let result = try await ExpertTools.route(to: host)
                journal.saveRoute(host: host, output: result)
                return .text(result)
            }
            var last = ""
            try await ExpertTools.routeRounds(to: host, rounds: rounds) { output in
                journal.saveRoute(host: host, output: output); last = output
                context.progress("Trace \(journal.routes.filter { $0.host == host }.count) saved")
            }
            return .text(last + "\n\n" + RouteHistory(host: host, routes: journal.routes).text)
        },
        MCPTool(name: "get_route_history", title: "Route to a host over time",
                description: "Every saved trace to `host` combined hop by hop, like mtr: `hops` (`ttl`, `addresses` seen there, most often first, `replies` and `probes`, `bestMs`, `averageMs`, `worstMs`, `lastMs`, `changed` when different routers answered in different runs), `runs`, `first` and `last`, `pathChanges` (runs whose routers differ from the run before) and `verdict`, where the delay starts. A hop that skips replies while later hops answer is a router rate-limiting probes, not loss. Without `host`, returns `hosts`, the hosts with saved traces. Same JSON as `kilobat route-history --host <host> --json`.",
                inputSchema: schema(["host": ["type": "string", "description": "A host traced before."]]),
                annotations: readOnly) { arguments, _ in
            let routes = SurveyJournal().routes
            guard let host = (arguments["host"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { return .json(try object(["hosts": RouteHistory.hosts(routes)])) }
            let history = RouteHistory(host: host, routes: routes)
            guard history.runs > 0 else { throw MCPToolError("No saved traces to \(host). Run trace_route first.") }
            return .json(try DiagnosticsCLI.encode(history))
        },
        MCPTool(name: "compare_speed_tests", title: "Why two speed tests differ",
                description: "Sets two speed tests the Kilobat app saved side by side and lists what was different between them, each with a plain-English note on how it can change a result: `network`, `time` (evening or hours apart), `server` (Cloudflare data center), `method` (one connection or several), `connection` (Wi-Fi, Ethernet, VPN), `vpn`, Wi-Fi `band`, `signal` and `linkRate`, `otherTraffic` on this Mac during the test, idle `latency` and `dataLimit`. Returns `first` and `second` (the earlier test first), `downloadChangePercent`, `uploadChangePercent`, `differences` (`factor`, `first`, `second`, `note`), `unknown` (factors one of the tests didn't record, such as tests saved by an older version) and `summary`. Name tests by `first` and `second`: an id from get_network_history speed_tests, or a place where 1 is the newest; the newest two by default. It lists recorded differences; never claim one of them caused the change, or that a result is wrong. Same JSON as `kilobat speed-compare --json`.",
                inputSchema: schema(["first": ["type": "string", "description": "A test id, or its place (1 is the newest)."],
                                     "second": ["type": "string", "description": "A test id, or its place (1 is the newest)."]]),
                annotations: readOnly) { arguments, _ in
            let tests = NetworkJournal().speedTests
            let a = (arguments["first"] as? String) ?? (arguments["first"] as? NSNumber).map { $0.stringValue }
            let b = (arguments["second"] as? String) ?? (arguments["second"] as? NSNumber).map { $0.stringValue }
            let pair: (SavedSpeedTest, SavedSpeedTest)
            if a == nil && b == nil {
                guard let latest = SpeedComparison.latestPair(tests) else { throw MCPToolError("Fewer than two saved speed tests. The Kilobat app saves the tests it runs.") }
                pair = latest
            } else {
                guard let a, let b, let one = SpeedComparison.find(a, in: tests), let two = SpeedComparison.find(b, in: tests), one.id != two.id else {
                    throw MCPToolError("Pass both first and second: two different test ids, or places where 1 is the newest.")
                }
                pair = (one, two)
            }
            return .json(try DiagnosticsCLI.encode(SpeedComparison(pair.0, pair.1)))
        },
        MCPTool(name: "get_plan_check", title: "Speed against the plan",
                description: "How each network's speed tests over the last `days` (30 by default) compare with the download speed its plan promises. `networks` lists each network with a plan: `network`, `planMbps`, `planSource` (network: set for that network in the app; default: the single plan from `settings plan-mbps`), `headline` (e.g. \"You got 61% of your 500 Mbps\"), `sentence` (the line the provider report uses) and `summary`: `checks`, `scheduledOnly` (true when only the app's scheduled plan checks were counted; false when there were fewer than three and tests the user ran count too), `downloadMedianMbps`, `uploadMedianMbps`, `percentOfPlan`, `peakMedianMbps` and `peakChecks` (7 to 11 pm local time), `offPeakMedianMbps` and `offPeakChecks`, `underHalfPercent` (tests under half the plan), `slowestMbps`, `fastestMbps`, `first`, `last`. `planCheck` says whether the app runs scheduled checks (a Pro setting the user turns on in Settings › Network › Plan check); they are light parallel tests, up to three a day, only when the Mac is quiet, unmetered, off VPN and not in a call. An empty `networks` means no plan is set or nothing was tested. Report the numbers as measured from this Mac; a slow Wi-Fi link or another device can also pull them down, so don't claim the provider is at fault. Same JSON as `kilobat plan --json`.",
                inputSchema: schema(["days": ["type": "integer", "minimum": 7, "maximum": 90, "default": 30, "description": "How many days back to summarize."]]),
                annotations: readOnly) { arguments, _ in
            .json(try DiagnosticsCLI.encode(PlanCLI.summaries(days: try integer(arguments, "days", in: 7...90) ?? PlanSummary.window)))
        },
        MCPTool(name: "get_exit_path", title: "Where traffic leaves: VPN and public IP",
                description: "Where this Mac's traffic leaves, read on the Mac: the default route's `interface`, `tunnel`, `vpn` (full: the default route goes through a tunnel; partial: a VPN is connected but the default route doesn't use it, so only some destinations go through it; off), `vpnName` (when macOS lists exactly one VPN connected) and `vpnConnected` (every VPN configuration macOS lists as connected). Pass `public_ip` true to also ask Cloudflare which address it sees (`publicIP`) and look up the country it is registered to in Kilobat's local DB-IP data (`publicIPCountry`, `publicIPCountryName`). That sends one request to Cloudflare, so only pass it when the user asks for their public IP or VPN exit. Report it as measured, e.g. \"traffic leaves through utun3 (WireGuard), exit IP registered in Germany\": the registry country isn't where the user or server is, and neither it nor a VPN shows that a connection is private, anonymous or secure. Same JSON as `kilobat ip [--public] --json`.",
                inputSchema: schema(["public_ip": ["type": "boolean", "default": false, "description": "Also ask Cloudflare for the public IP. Contacts a third party."]]),
                annotations: MCPToolAnnotations(readOnly: true, openWorld: true)) { arguments, _ in
            let lookup = try boolean(arguments, "public_ip") ?? false
            return .json(try object(ExpertCLI.exitJSON(await ExitPath.current(lookup: lookup), lookedUp: lookup)))
        },
        MCPTool(name: "run_lan_test", title: "Throughput to a device on the network",
                description: "Five seconds of iperf3 between this Mac and `host`, a device the user runs `iperf3 -s` on, to measure the local network (Wi-Fi, cabling, a mesh link) apart from the internet. `reverse` true has the server send. Returns `receivedMbps`, `sentMbps`, `bytes`, `seconds`, `streams`, `retransmits` (TCP retransmissions on the sending side, when known) and `direction`. Needs iperf3 installed on this Mac by the user; Kilobat never installs it, and the error says how. Moves a lot of data on the local network for five seconds, which can slow other devices meanwhile; it doesn't use the internet unless `host` is on it. Get the user's confirmation first, with the host they named. Same JSON as `kilobat lan-test <host> --json`.",
                inputSchema: schema(["host": ["type": "string", "description": "Hostname or IP address of the device running iperf3 -s."],
                                     "reverse": ["type": "boolean", "default": false, "description": "Measure the server sending to this Mac."]], required: ["host"]),
                annotations: MCPToolAnnotations(readOnly: false, destructive: false, idempotent: false, openWorld: true)) { arguments, _ in
            .json(try DiagnosticsCLI.encode(try await ExpertTools.lanSpeed(host: try string(arguments, "host"), reverse: try boolean(arguments, "reverse") ?? false)))
        },
        MCPTool(name: "list_networks", title: "Known networks",
                description: "Networks Kilobat has seen, with `key`, `name`, the `profile` and `budgetGB` remembered for each (null if none), data used in the current session there, `current`, the data `cost` the user set (automatic, metered or unmetered) and `metered`, `osMetered` and `meteredSource` (macOS only reports the current network). Same JSON as `kilobat networks --json`.",
                annotations: readOnly) { _, _ in
            .json(try JSONSerialization.data(withJSONObject: await WiFiCLI.networkRows(TrafficStore(startMonitoring: false)), options: [.sortedKeys, .withoutEscapingSlashes]))
        },
        MCPTool(name: "get_conditions", title: "Conditions for a long run",
                description: "Whether now suits a large download or upload or a long unattended run: `connected`, `network` (Wi-Fi, Ethernet, Cellular), `metered` (what Kilobat acts on), `osMetered` (what macOS says) and `meteredSource` (macOS, or you when the user set the network's data cost), `lowDataMode`, `vpn` (the default route goes through a tunnel), `vpnInterface`, `vpnName` and `vpnConnected` (VPNs macOS lists as connected, which may carry only some destinations; get_exit_path has the detail), `internetLatencyMs` and `internetLossPercent` from a quick ping, `power` (`batteryPercent`, `onAC`, `thermal`, `lowPowerMode`), whether Kilobat keeps the Mac awake (`keptAwake`, `awakeReasons`, `awakeUntil` for keep_awake), `awakeOnPower` (`enabled`, `display`, `active`: the user's own Stay awake while plugged in setting, which no tool changes), `updaters` (`pauseOnMetered`, the setting, and `paused`, whether the filter pauses updaters on this network now; get_updaters has the detail) and one line of `advice`. Takes about 2 seconds. Same JSON as `kilobat conditions --json`.",
                annotations: MCPToolAnnotations(readOnly: true, openWorld: true)) { _, _ in
            .json(try object(await AwakeCLI.conditions(holdUntil: hold?.until)))
        },
        MCPTool(name: "get_updaters", title: "Updaters paused on metered networks",
                description: "Whether Kilobat pauses updater helpers on metered networks (`enabled`, on unless the user turned it off), whether this network is `metered` and they are `paused` now, and `filterActive` (null when the Kilobat app isn't running; pausing needs its network filter). `covered` lists the helpers it recognizes (`downloads` is false for Sparkle's and Squirrel's installers, which only install what the app already downloaded). `gotThrough` lists update bytes on the current network: an updater's own, or a System downloads service such as nsurlsessiond that connected for one (`shared`, so its bytes include other downloads); null without the running app. `pausedConnections` counts updater connections the filter stopped in the last 24 hours. `inProcess` lists installed apps that update from inside their own process (Sparkle or Squirrel), which can't be paused without blocking the app. `limits` says what pausing can't do. Same JSON as `kilobat updaters --json`.",
                annotations: readOnly) { _, _ in
            .json(try object(try UpdatersCLI.object(await UpdatersCLI.report(TrafficStore(startMonitoring: false)))))
        },
        MCPTool(name: "diagnose_connection", title: "Why something can't connect",
                description: "Checks why one website, API or host can't be reached from this Mac, layer by layer: the Mac's network and the interface it uses (Wi-Fi, Ethernet, a phone hotspot or a VPN), the system proxy and PAC file, DNS and its resolver (including a VPN's private resolver for its domain), Kilobat's own rules, TCP and TLS over IPv4 and IPv6 separately, the same connection over each interface when there are several, the exact request (path and query kept) through the path the app uses, every redirect hop with its own IPv4 and IPv6 check of the final host, and with a VPN or proxy on, the direct path against the tunnel or proxy. A HEAD request the server refuses is retried once as a one-byte GET; nothing larger is downloaded. A broken IPv6 or IPv4 path, a tunnel that fails while direct connections work, a proxy that works where direct connections are blocked, and a redirect target that fails each get their own verdict. A passing check means this request from this Mac over that path works now, not that every app or transfer is fine. Returns `verdict`, `next` (what to do), `ok`, `steps` (`layer`, `status`: ok, warning, failed or skipped, and `detail`), `hops` (`url`, `host`, `method`, `status` or `error`), `method` (what the check sent: HEAD, or a one-byte GET), `path` (`kind`: appProxy, environmentProxy, systemProxy or direct; `proxy` as host:port; `untested`, an app setting the check couldn't go through), `client` (`id`, `name`, `version` of the app as installed), `date` (when the check ran) and `failedAt`. `target`, details and hop URLs never show query values or passwords. Pass `app` (a bundle ID or process:<name> from get_status) to include that app's rules, the proxy variables in its environment (HTTPS_PROXY, ALL_PROXY, NO_PROXY) and its open connections to the host or its proxy, compared with the fresh one, and a `Transfer` step that says whether bytes still arrive on them a few seconds apart. A quiet transfer may be stalled or finished with its connection still open: never report a download as finished from it. Pass `proxy` when the app uses a proxy address from its own settings: the request goes through it, and when that fails while direct connections work, the verdict says the network is fine and the app's path isn't. Some apps have a setting Kilobat can't read or go through, such as LM Studio's Hugging Face proxy (a switch with no address) for huggingface.co downloads: an `App setting` step cites dated user reports, and the verdict says the network works, not that the app's request does. Suggest the user checks that setting; never change another app's settings or promise it will resume a download on its own. Pass `failed_at` when the user says when the app failed. Pass `context` when the failing code runs in a container, VM or remote machine: the checks still run on this Mac, and a `Context` step says how to check from there. Pass `context` provider when a hosted service makes the request from its own servers (Warp's custom inference endpoint, say; pass its `app`, dev.warp.Warp-Stable, to name it): a `Provider` step says whether the target is private (localhost, a LAN or Tailscale address, a name only private DNS knows), which those servers can't reach however well it works from the Mac. Picking a known provider as `app` adds that step on its own, worded as an if. Never suggest SSH into the provider or exposing the Mac's service through a tunnel; the options are a public endpoint the user controls or a route the provider supports, quoted from `next`. When the user describes a slow or failing transfer already under way, say that a fresh check can't see that connection, and suggest get_app_bandwidth for it. Takes up to about 30 seconds. Same JSON as `kilobat why <target> --json`.",
                inputSchema: schema(["target": ["type": "string", "description": "A host such as api.example.com, or the exact http or https URL that fails, query included."],
                                     "app": ["type": "string", "description": "Bundle ID such as com.example.App, or process:<name>."],
                                     "proxy": ["type": "string", "description": "A proxy the app uses by its own setting, such as http://127.0.0.1:7890 or socks5://127.0.0.1:1080."],
                                     "context": ["type": "string", "enum": ConnectionDoctor.Context.allCases.map(\.rawValue), "description": "Where the failing code runs, when not on this Mac; provider for a hosted service whose servers make the request."],
                                     "failed_at": ["type": "string", "description": "When the app failed, as ISO 8601 (2026-10-29T14:05:00Z) or 14:05 today; recorded beside the check's own time."]], required: ["target"]),
                annotations: MCPToolAnnotations(readOnly: true, openWorld: true)) { arguments, _ in
            let app = arguments["app"] as? String, proxy = arguments["proxy"] as? String
            let context = try (arguments["context"] as? String).flatMap { value in
                guard let context = ConnectionDoctor.Context(rawValue: value) else { throw MCPToolError("context takes container, vm, remote or provider.") }
                return context
            }
            let failedAt = try (arguments["failed_at"] as? String).map { value in
                guard let date = ConnectionDoctor.failureTime(value) else { throw MCPToolError("failed_at takes when the app failed, such as 2026-10-29T14:05:00Z or 14:05, not a time still ahead.") }
                return date
            }
            let report = await ConnectionDoctor.run(try string(arguments, "target"), app: app?.isEmpty == false ? app : nil, proxy: proxy?.isEmpty == false ? proxy : nil,
                                                    context: context, policy: await AwakeCLI.policy(), failedAt: failedAt)
            if report.steps.isEmpty { throw MCPToolError(report.verdict + " " + report.next) }
            return .json(try AwakeCLI.doctorJSON(report))
        },
        MCPTool(name: "list_sessions", title: "Awake sessions and agent runs",
                description: "Awake sessions and AI agent runs (Claude Code, Codex, Gemini CLI and others) the Kilobat app recorded over the last `days` (7 by default), newest first: `kind` (awake or agent), `title`, `start`, `end`, `ended` (Finished, Failed, Went quiet, Exited, Timer ended, Turned off); for agent runs the agent's hooks report, `session`, `cwd`, `project` and `state` (working, waitingForYou, done, stalled, networkFailed or failed; the last one seen for an ended run), `note` (e.g. Rate-limited until 3pm), `lastEvent` (last hook), `lastActive` (last traffic) and `lastCPU` (last CPU work), and `sharedTraffic` when bytes may include other runs of the same agent; only `ended` Finished means the agent said it was done. `executable`, `origin` (Homebrew, npm (node 22.3.0), Claude app…), `version` and `otherInstalls` show which install ran; bytes `received` and `sent`, bytes per process (`apps`), `destinations` an agent contacted, `events` (network changes during the run), `batteryStart`, `batteryEnd` and `peakThermal`. Recorded only while the app runs. Same JSON as `kilobat sessions --json --days N`.",
                inputSchema: schema(["days": ["type": "integer", "minimum": 1, "maximum": 365, "default": 7, "description": "Number of days."]]),
                annotations: readOnly) { arguments, _ in
            .json(try DiagnosticsCLI.encode(AwakeCLI.history(days: try integer(arguments, "days", in: 1...365) ?? 7)))
        },
        MCPTool(name: "create_support_report", title: "Report for an ISP or IT desk",
                description: "Builds a report the user can send to their internet provider, IT desk or a friend: what this Mac measured on its current network over the last `hours` (24 by default, at most 168). `findings` are plain sentences, most useful first: outages, whether the delay starts at the router or beyond it, ping loss, speed tests against the user's plan, and the optional `host` check. `latency` has medians and the 95th percentile with hourly values; `outages` and `speedTests` list what was recorded. The report never includes the network's name, local IP addresses, hardware addresses, device names or which apps used the network, and says so in `leftOut`. Public server addresses in a host check stay. It only covers this Mac and the checks the Kilobat app recorded while it ran: if `findings` says nothing was recorded, tell the user to keep the app running and try later. Returns `text` (to paste into a support chat) and `report` (the same as JSON). For a printable page, the user can run `kilobat support-report --html --output ~/Desktop/report.html` or use the report button in Kilobat's Health tab, which saves a PDF. Never send the report anywhere yourself; give it to the user. Same as `kilobat support-report --json`.",
                inputSchema: schema(["hours": ["type": "integer", "minimum": 1, "maximum": 168, "default": 24, "description": "How far back to look."],
                                     "host": ["type": "string", "description": "A host or URL to check now and include, such as the site or service that fails."]]),
                annotations: readOnly) { arguments, _ in
            let report = try await WiFiCLI.makeSupportReport(hours: try integer(arguments, "hours", in: 1...168) ?? 24, host: arguments["host"] as? String)
            let object = try JSONSerialization.jsonObject(with: DiagnosticsCLI.encode(report))
            return .json(try MCPCLI.object(["text": report.text, "report": object]))
        },
        MCPTool(name: "get_proxy_status", title: "Proxy apps and routes",
                description: "Proxy apps on this Mac (Clash Verge, ClashX, mihomo, Mihomo Party, FlClash, Surge, sing-box, Stash, V2Ray or Xray, Shadowsocks and others) and the system proxy, read-only. `clients` lists each app: `running`, `ports`, `controller` (its API address; secrets are never returned), `mode` (rule, global or direct) and `tun`. `system` is macOS's proxy setting, with `dead` true when it points at this Mac and nothing answers, which breaks every app that follows it. `carriers` are processes that forward other apps' traffic (proxy cores, VPN tunnels); Kilobat counts that traffic for the apps, not the carrier. `findings` name problems and what to try: a dead system proxy, DNS or IPv6 that skip a VPN, a proxy and a VPN both taking traffic, global mode, and Kilobat's filter not seeing apps that use the system proxy. With `routes` true, also returns `routes`: for each live connection through a Clash-compatible API, the `app`, `host`, `rule`, `node` (DIRECT, REJECT or the proxy server) and `group`. Never change the proxy app's settings or nodes; tell the user what to change. Same as `kilobat proxy --json` and `kilobat proxy routes --json`.",
                inputSchema: schema(["routes": ["type": "boolean", "default": false, "description": "Also list each app's live routes through the proxy."]]),
                annotations: readOnly) { arguments, _ in
            let check = await TunnelCheck.run()
            let status = try JSONSerialization.jsonObject(with: DiagnosticsCLI.encode(ProxyCLI.statusObject(check)))
            guard arguments["routes"] as? Bool == true else { return .json(try MCPCLI.object(["status": status])) }
            let routes = (try? await ProxyCLI.makeRoutes()) ?? []
            return .json(try MCPCLI.object(["status": status, "routes": try JSONSerialization.jsonObject(with: DiagnosticsCLI.encode(routes))]))
        },
        MCPTool(name: "test_proxy_nodes", title: "Test proxy nodes",
                description: "For each running Clash-compatible proxy app, measures how fast the node each proxy group uses now answers: one small request through it to a 204 page (Google's generate_204), with a 5-second limit. Returns `client`, `group`, `node` and `delayMs`, null when the node doesn't answer. Use it when sites fail or feel slow only with the proxy on: a node with no answer or a delay in the seconds is the likely cause, and the user can pick another node in that group. It changes nothing. Same as `kilobat proxy test --json`.",
                inputSchema: schema([:]), annotations: MCPToolAnnotations(readOnly: true, openWorld: true)) { _, _ in
            var results: [ProxyCLI.NodeDelay] = []
            for (client, api) in try await ProxyCLI.apis() {
                for group in try await api.groups() { if let node = group.now { results.append(.init(client: client.name, group: group.name, node: node, delayMs: await api.delay(node))) } }
            }
            return .json(try DiagnosticsCLI.encode(results))
        },
        MCPTool(name: "check_vpn", title: "VPN leak and conflict check",
                description: "Checks the VPN and proxies on this Mac from its routes and resolvers, read-only: `vpnState` (full, partial or off) and `vpn` (its name when macOS lists exactly one), `dnsServer` and `dnsInterface` (where name lookups go), `ipv6Interface` (where IPv6 leaves), and `findings`: DNS that skips the VPN (lookups go to the local network), IPv6 that skips it (sites over IPv6 see the real address), a proxy and a VPN both taking traffic, a dead system proxy. Each finding says what to try. It can't see inside the VPN app or prove privacy; say what was measured. Same as `kilobat vpn --json`.",
                inputSchema: schema([:]), annotations: readOnly) { _, _ in
            .json(try DiagnosticsCLI.encode(await TunnelCheck.run()))
        },
        MCPTool(name: "get_call_reports", title: "Call quality reports",
                description: "The report cards the Kilobat app wrote after recent calls in Zoom, Teams, FaceTime, Slack, Webex, Discord, a browser and other calling apps, newest first, read-only. Each has `app`, `browser`, `start`, `end`, internet `median` ping and `jitter` in ms, `lossPercent`, and `freezes`: each with `at` (seconds into the call), `seconds`, `peak` ms (null when every ping was lost) and `cause` — `kind` app (with `app` and `uploading`), wifi (`weakSignal`), airDrop or beyondRouter. A freeze is two or more seconds of pings lost or 200 ms over the call's median. Kilobat never listens to calls; it notices the microphone and pings once a second. Empty when the app isn't running or no call was long enough. Same as `kilobat calls --json`.",
                inputSchema: schema(["limit": ["type": "integer", "minimum": 1, "maximum": 50, "default": 10, "description": "How many calls, newest first."]]), annotations: readOnly) { arguments, _ in
            let limit = try integer(arguments, "limit", in: 1...50) ?? 10
            return .json(try DiagnosticsCLI.encode(Array(CallStore.load().suffix(limit).reversed())))
        },
        MCPTool(name: "get_starlink_status", title: "Starlink dish status",
                description: "Reads the Starlink dish on this network straight from it (192.168.100.1, local only) and the outage log the Kilobat app keeps, read-only. `present` is false when no dish answers; then only logged `outages` come back. With a dish: `status` (`state` such as online, obstructed, noSatellites, booting; `popLatencyMs` to Starlink's ground station; `popDropPercent`; live `downlinkMbps`/`uplinkMbps` for every device on the dish; `alerts` each with `title`, `severity` and `advice` — heat throttling, motors stuck, snow melt heating, outside the service area, update waiting for a restart and more; `software`; `uptimeSeconds`; `mobility`), `obstruction` (`fractionPercent`, `currentlyObstructed`, and `map.blocked`: the compass directions where the sky is blocked with their share and elevation, plus plain `advice`), `history` (the last ~15 min: ground-station ping and bytes through the dish), and `outages` with `cause` and `side`: setup (obstructions, heat, power save, cable — fixable where the dish is), network (no satellites, no reply from Starlink — the provider's side) or dish (restarts, repositioning). `outageSeconds` totals each side. Use it when someone on Starlink asks why the internet dropped, whether to move the dish, or what to tell Starlink support. It never stows, reboots or changes the dish. Same as `kilobat starlink --json`.",
                inputSchema: schema(["hours": ["type": "integer", "minimum": 1, "maximum": 720, "default": 24, "description": "Outages over this many hours."]]), annotations: readOnly) { arguments, _ in
            let hours = try integer(arguments, "hours", in: 1...720) ?? 24
            return .json(try object(StarlinkCLI.json(await StarlinkCLI.read(hours: hours), hours: hours)))
        },
        MCPTool(name: "keep_awake", title: "Keep the Mac awake",
                description: "Stops this Mac from idle-sleeping for `minutes` (1–240) so a long build, download or agent run isn't cut off. Calling again replaces the previous hold; it ends early with release_awake or when this MCP server stops. Shows in `pmset -g assertions` as \"Kilobat: <reason>\". Changes no settings and is low risk: tell the user for how long, and on battery get their confirmation first. Closing the lid still sleeps the Mac unless `lid_closed` is true: then the Kilobat app's power helper keeps it running with the lid shut, which works only after the user allowed it in Kilobat Settings and approved the helper. A closed Mac in a bag can overheat and drains its battery, so get the user's explicit confirmation for lid_closed every time, saying for how long; Kilobat still lets it sleep at the user's battery floor, when it runs hot, and when the time is up. `lidHold` in the result says until when, and `lidFloor` at which battery percentage it gives up.",
                inputSchema: schema(["minutes": ["type": "integer", "minimum": 1, "maximum": 240, "description": "How long to stay awake."],
                                     "reason": ["type": "string", "description": "What the Mac stays awake for, e.g. \"Running the test suite\"."],
                                     "lid_closed": ["type": "boolean", "default": false, "description": "Also keep running with the lid closed. Needs the user's confirmation."]], required: ["minutes"]),
                annotations: MCPToolAnnotations(readOnly: false, destructive: false, idempotent: true)) { arguments, _ in
            guard let minutes = try integer(arguments, "minutes", in: 1...240) else { throw MCPToolError("Missing required integer argument 'minutes'.") }
            let reason = (arguments["reason"] as? String).map { String($0.prefix(80)) }.flatMap { $0.isEmpty ? nil : $0 } ?? "Agent run"
            let lidClosed = arguments["lid_closed"] as? Bool ?? false
            await releaseHold()
            let until = Date().addingTimeInterval(Double(minutes) * 60)
            var lid: LidLease?
            if lidClosed {
                do { lid = try await AwakeCLI.holdLid(until: until, reason: reason) } catch { throw MCPToolError(error.localizedDescription) }
            }
            guard let assertion = SleepAssertion(reason: "Kilobat: " + reason) else {
                if lid != nil { _ = await AppRelay.ask(LidRelayRequest.release(owner: getpid()).action, timeout: .seconds(2)) }
                throw MCPToolError("macOS refused to keep the Mac awake.")
            }
            let timer = Task { @MainActor in
                try? await Task.sleep(for: .seconds(minutes * 60))
                if !Task.isCancelled { await releaseHold() }
            }
            hold = (assertion, until, lid != nil, timer)
            let power = PowerState.read()
            return .json(try object(["holding": true, "until": ISO8601DateFormatter().string(from: until), "reason": reason, "onAC": power.onAC, "batteryPercent": power.batteryPercent ?? NSNull(),
                                     "lidHold": lid.map { ISO8601DateFormatter().string(from: $0.until) } ?? NSNull(), "lidFloor": lid.map { $0.onlyOnAC ? 100 : $0.batteryFloor } ?? NSNull(),
                                     "note": lid.map { "Idle sleep is off until then, and the lid can close until \($0.until.formatted(date: .omitted, time: .shortened)); Kilobat lets the Mac sleep \($0.onlyOnAC ? "if it's unplugged" : "at \($0.batteryFloor)% battery") or when it runs hot." } ?? "Idle sleep is off until then. Closing the lid still sleeps the Mac."]))
        },
        MCPTool(name: "release_awake", title: "Let the Mac sleep again",
                description: "Ends a keep_awake hold early, with its lid-closed hold if any, so the Mac can sleep again. `released` is false when there was none. Releasing needs no confirmation.",
                annotations: MCPToolAnnotations(readOnly: false, destructive: false, idempotent: true)) { _, _ in
            .json(try object(["released": await releaseHold()]))
        },
        MCPTool(name: "set_budget", title: "Set the data budget",
                description: "Sets the current network's data budget: `gb` (0.1–10000), when it starts over (`cycle`: session only resets by hand, or daily, weekly, monthly), `reset_day` (1–31 for monthly, 1 Monday to 7 Sunday for weekly) and `alerts`, the percentages that notify once per cycle (\"50,80,100\" or \"none\"). Omitted values stay as they are. With the Kilobat app's filter on, new connections stop once it is used up in the travel and work profiles; unrestricted only tracks it. Usage is sampled, so the cap is approximate." + confirm,
                inputSchema: schema(["gb": ["type": "number", "minimum": 0.1, "maximum": 10000],
                                     "cycle": ["type": "string", "enum": ["session", "daily", "weekly", "monthly"]],
                                     "reset_day": ["type": "integer", "minimum": 1, "maximum": 31],
                                     "alerts": ["type": "string", "description": "Comma-separated percentages such as 50,80,100, or none."]]),
                annotations: change) { arguments, _ in
            var gb: Double?
            if let raw = arguments["gb"], !(raw is NSNull) {
                guard let number = raw as? NSNumber, !isBoolean(number), number.doubleValue.isFinite, (0.1...10_000).contains(number.doubleValue) else { throw MCPToolError("gb must be a number from 0.1 to 10000.") }
                gb = number.doubleValue
            }
            let cycle = arguments["cycle"] as? String, alerts = arguments["alerts"] as? String, day = try integer(arguments, "reset_day", in: 1...31)
            guard gb != nil || cycle != nil || day != nil || alerts != nil else { throw MCPToolError("Pass gb, cycle, reset_day or alerts.") }
            let store = TrafficStore(startMonitoring: false)
            do { return .json(try object(try QuotaCLI.applyBudget(store, gb: gb, cycle: cycle, resetDay: day, alerts: alerts, network: QuotaCLI.currentNetwork(store, app: await WiFiCLI.connection())))) }
            catch let error as CLIError { throw MCPToolError(error.message) }
        },
        MCPTool(name: "set_network_cost", title: "Set a network's data cost",
                description: "Sets what the current network, or `network` (a key or name from list_networks), costs. `metered` gets the protection of a phone hotspot: Kilobat switches to Travel (when that is on and no profile is remembered for the network) and skips scheduled speed tests. Use it for Android hotspots and USB or Ethernet tethering that macOS doesn't flag. `unmetered` overrides macOS, `automatic` follows it again. Kilobat refuses a network it can't tell apart, such as Wi-Fi whose name macOS hides without Location access." + confirm,
                inputSchema: schema(["cost": ["type": "string", "enum": NetworkCost.allCases.map(\.rawValue)],
                                     "network": ["type": "string", "description": "A key or name from list_networks; the current network if omitted."]], required: ["cost"]),
                annotations: change) { arguments, _ in
            guard let cost = NetworkCost(rawValue: try string(arguments, "cost")) else { throw MCPToolError("cost takes metered, unmetered or automatic.") }
            let network = (arguments["network"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            do {
                return .json(try object(try await WiFiCLI.setCost(cost, network: network, store: TrafficStore(startMonitoring: false))))
            } catch let error as CLIError { throw MCPToolError(error.message) }
        },
        MCPTool(name: "set_updater_pause", title: "Pause updaters on metered networks",
                description: "Turns pausing updaters on metered networks `on` (the default) or `off`. While on and the network is metered, the Kilobat app's network filter blocks updater helpers (Google Updater, Microsoft AutoUpdate, macOS Software Update, App Store downloads, Sparkle's and Squirrel's helpers) with an ordinary rule; the apps themselves keep working, nothing in other apps or macOS changes, and updates resume on an unmetered network. Returns `enabled`, `metered`, `paused` and the `effect` in words." + confirm,
                inputSchema: schema(["pause": ["type": "string", "enum": ["on", "off"]]], required: ["pause"]),
                annotations: change) { arguments, _ in
            do {
                return .json(try object(try await UpdatersCLI.set(try string(arguments, "pause") == "on", store: TrafficStore(startMonitoring: false))))
            } catch let error as CLIError { throw MCPToolError(error.message) }
        },
        MCPTool(name: "set_app_quota", title: "Set an app's data quota",
                description: "Limits how much data one app may use per budget cycle (daily with a session budget), counting `direction` total or upload only, on this `network` or on all of them. With the Kilobat app's filter on, its new connections stop once the quota is used up, as with the budget; a temporary allow rule still lets it through. `action` remove deletes the app's quotas. Identify the app by bundle ID (get_status `apps[].id`) or process:<name>. Usage is sampled, so it is approximate." + confirm,
                inputSchema: schema(["app": ["type": "string", "description": "Bundle ID such as com.getdropbox.dropbox, or process:<name>."],
                                     "gb": ["type": "number", "minimum": 0.01, "maximum": 10000],
                                     "direction": ["type": "string", "enum": ["total", "upload"], "default": "total"],
                                     "network": ["type": "string", "enum": ["this", "all"], "default": "this"],
                                     "action": ["type": "string", "enum": ["set", "remove"], "default": "set"]], required: ["app"]),
                annotations: change) { arguments, _ in
            let app = try string(arguments, "app"), store = TrafficStore(startMonitoring: false)
            if arguments["action"] as? String == "remove" { return .json(try object(["app": app, "removed": QuotaCLI.removeQuota(app, store: store)])) }
            guard let raw = arguments["gb"] as? NSNumber, !isBoolean(raw) else { throw MCPToolError("Pass gb, the quota in GB.") }
            do {
                let quota = try QuotaCLI.setQuota(app, gb: raw.doubleValue, uploadOnly: arguments["direction"] as? String == "upload", everyNetwork: arguments["network"] as? String == "all",
                                                  network: QuotaCLI.currentNetwork(store, app: await WiFiCLI.connection()), store: store)
                return .json(try object(["app": app, "name": quota.name, "limitBytes": quota.bytes, "uploadOnly": quota.uploadOnly, "network": quota.network ?? NSNull(), "saved": true]))
            } catch let error as CLIError { throw MCPToolError(error.message) }
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
        MCPTool(name: "run_stutter_test", title: "Find latency spikes",
                description: "Pings the router (or `target`: internet for 1.1.1.1, or a host) every 50 ms for `seconds` (20 by default) to find the short latency spikes that make calls, game streaming and remote desktops stutter while speed and loss look fine. Returns `latencyMs` (p50, p95, p99, max), `lossPercent` (`pingRateLimited` is true when the router answers only some fast pings, which is not real loss), `spikes` (`atSeconds`, `peakMs`; a spike is over 3× the median and over 50 ms), `periodSeconds` when spikes repeat at a regular interval, `pattern` (steady, few, periodic, irregular, noReplies), `awdl` (the AirDrop link and what used it) and a plain `verdict`. Regular spikes on the router often come from AirDrop/AWDL scanning, but not always; a speed test can't see them. Sends pings only. Same JSON as `kilobat stutter --json` without the raw samples.",
                inputSchema: schema(["seconds": ["type": "integer", "minimum": 10, "maximum": 60, "default": 20],
                                     "target": ["type": "string", "description": "router (default), internet, or a host name or IP address."]]),
                annotations: MCPToolAnnotations(readOnly: true, openWorld: true)) { arguments, _ in
            let target = (arguments["target"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "router"
            do { return .json(try object(NearbyCLI.stutterJSON(try await StutterTest.run(target: target, seconds: try integer(arguments, "seconds", in: 10...60) ?? 20), samples: false))) }
            catch let error as DiagnosticError { throw MCPToolError(error.message) }
        },
        MCPTool(name: "get_game_ping", title: "Ping game data centers",
                description: "Pings each data center of a game 5 times and returns them fastest first, with the `best` one for this Mac. `game` is cs2, dota2 or deadlock (Valve's relay in each data center, from Steam's public relay list for that game) or fortnite (Epic's ping server in each matchmaking subregion); without it, all four, which takes about 20 seconds. Each region has `pingMs` (median), `jitterMs`, `lossPercent`, `method` (icmp, or tcp where ping is blocked) and `host`. This is ping to the region's data center, not to a match server. `overlayTarget` (such as cs2:fra) is what `kilobat overlay --target` takes to show that ping on stream. Valorant, League of Legends and Apex Legends have no public target that answers ping and return an error saying so. Takes about 5 seconds per game and sends pings only. Same JSON as `kilobat games --json`.",
                inputSchema: schema(["game": ["type": "string", "description": "cs2, dota2, deadlock or fortnite. All four when left out; pass one when the user named a game."]]),
                annotations: MCPToolAnnotations(readOnly: true, openWorld: true)) { arguments, _ in
            if let name = (arguments["game"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
                let game: GameServerTable.Game
                do { game = try GamesCLI.game(name) } catch let error as CLIError { throw MCPToolError(error.message) }
                return .json(try object(GamesCLI.reportJSON(await GamePing.run(game))))
            }
            var reports: [[String: Any]] = []
            for game in GameServerTable.bundled.games { reports.append(GamesCLI.reportJSON(await GamePing.run(game))) }
            return .json(try object(["games": reports, "notIncluded": GameServerTable.unsupported]))
        },
        MCPTool(name: "get_nearby_radios", title: "AirDrop and Bluetooth",
                description: "The radios that share this Mac's Wi-Fi chip or band: `awdl` (whether the AirDrop link is up and active and which features use it: AirDrop, Universal Control, Sidecar, iPhone Mirroring, Continuity), AirDrop `visibility` (everyone, contacts, off), Bluetooth `devices` (`name`, `kind`, `connected`, `sharesBand`), the Wi-Fi band and coexistence `advice` when Bluetooth audio or input devices share 2.4 GHz with Wi-Fi.",
                annotations: readOnly) { _, _ in
            let awdl = await NearbyRadios.awdlStatus(), devices = await NearbyCLI.bluetoothDevices(), band = await DiagnosticProbe().radio().band
            return .json(try object(["awdl": NearbyCLI.awdlJSON(awdl), "visibility": NearbyRadios.airDropVisibility()?.key as Any? ?? NSNull(), "wifiBand": band as Any? ?? NSNull(),
                                     "devices": devices.map { ["name": $0.name, "kind": $0.kind.rawValue, "connected": $0.connected, "sharesBand": NearbyRadios.sharesBand($0, wifiBand: band)] },
                                     "advice": NearbyRadios.coexistence(wifiBand: band, devices: devices) as Any? ?? NSNull()] as [String: Any]))
        },
        MCPTool(name: "set_airdrop_visibility", title: "Change AirDrop visibility",
                description: "Asks for AirDrop visibility `everyone`, `contacts` or `off`. macOS lets only System Settings change it, so this opens System Settings at General › AirDrop & Handoff for the user to choose, and returns the current `visibility` and `openedSettings`. Opens a window on the user's screen: explain why and get the user's explicit confirmation before calling.",
                inputSchema: schema(["visibility": ["type": "string", "enum": ["everyone", "contacts", "off"]]], required: ["visibility"]),
                annotations: change) { arguments, _ in
            guard let wanted = AirDropVisibility.allCases.first(where: { $0.key == (arguments["visibility"] as? String) }) else { throw MCPToolError("visibility must be everyone, contacts or off.") }
            return .json(try object(NearbyCLI.setAirDrop(wanted)))
        },
    ] }

    /// The keep_awake hold, released by its timer, release_awake, or this process exiting; the app drops its lid hold then too.
    static var hold: (assertion: SleepAssertion, until: Date, lid: Bool, timer: Task<Void, Never>)?
    @discardableResult static func releaseHold() async -> Bool {
        guard let hold else { return false }
        hold.timer.cancel(); hold.assertion.release(); self.hold = nil
        if hold.lid { _ = await AppRelay.ask(LidRelayRequest.release(owner: getpid()).action, timeout: .seconds(2)) }
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
    static func boolean(_ arguments: [String: Any], _ key: String) throws -> Bool? {
        guard let raw = arguments[key], !(raw is NSNull) else { return nil }
        guard isBoolean(raw), let value = raw as? Bool else { throw MCPToolError("'\(key)' must be true or false.") }
        return value
    }
    static func object(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
}
