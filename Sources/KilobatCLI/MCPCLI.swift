import Foundation
import Darwin
import KilobatCore

/// `kilobat mcp`: the CLI's diagnostics and controls as Model Context Protocol tools over stdio.
/// Tool results reuse the `--json` shapes so agents and scripts read the same fields.
@MainActor enum MCPCLI {
    static let instructions = """
    Kilobat reads this Mac's network: per-app traffic, Wi-Fi signal, router, internet and DNS latency, nearby networks and speed. \
    For slow or flaky internet, start with diagnose_network, then get_status to see which apps use bandwidth. \
    For Wi-Fi problems use get_wifi, scan_wifi and suggest_wifi_channel; for drops, get_network_history. When Wi-Fi is slow in one room on a mesh system, get_wifi_nodes says whether the Mac clings to a far node while a closer one is in range; reconnect_wifi moves it, but drops Wi-Fi for a few seconds, so ask first. When the connection got worse over days or someone asks whether to restart the router, get_router_checkup compares the router with its own normal and says whether restarts helped before. When the speed test is fine but one service (GitHub, iCloud, Steam, npm, Docker) downloads slowly, get_service_speed compares the user's own downloads from it with the line and says when the provider's route to it is the problem. \
    Run run_speedtest only when capacity or bufferbloat matters, and ask first on metered connections. When two results differ, compare_speed_tests lists what changed between them; for whether the user gets the speed they pay for, use get_plan_check. For a summary of the past week (outages and whose side they were on, frozen calls, the router, blocks, metered data) or how it compares with the week before, use get_weekly_digest. When outages may earn a credit from the internet provider, get_outage_credit adds up the ones beyond the router, applies the provider's published rule and drafts a claim the user sends themselves. \
    When pages are slow to start or someone asks which DNS is fastest, get_fastest_dns has the app's measurements per network; prefer it over benchmark_dns, which is one quick sample. For where traffic leaves (VPN or not) use get_exit_path; ask for public_ip only when the user wants it, since that contacts Cloudflare, and never present a VPN or an exit country as proof of privacy. \
    For slow hops along a route over time, trace_route with rounds and get_route_history; for the local network alone, run_lan_test against a device running iperf3 -s. \
    When calls, game streaming or remote desktops stutter but speed looks fine, run run_stutter_test, then get_nearby_radios for AirDrop and Bluetooth. When AirPods or other Bluetooth headphones crackle or cut out, get_bluetooth_audio says what on the Wi-Fi side is in the way and what to change. When a Chromecast, AirPlay TV or printer doesn't show up, or a cast or AirPlay mirror stutters, check_local_network says whether devices here can see each other (hotel and guest Wi-Fi often keeps them apart), whether the Mac is on a device's own Wi-Fi, and what on the Mac's side is in the way. \
    For why ssh typing lagged or a remote desktop froze, get_remote_session_reports has the app's report after each session, and says when Mosh would help. \
    For why OBS dropped frames, get_stream_reports says whether the network, the encoder or the GPU lost them; before going live, check_stream_readiness compares the upload with OBS's bitrate plus 30%. \
    For GeForce NOW, Xbox Cloud Gaming, Boosteroid, Amazon Luna or Shadow stuttering on this Mac, get_cloud_gaming has the session now (ping, bitrate, what's in the way, data on a hotspot) and a report after each with what was going on at every stutter. \
    For which region to play on in CS2, Dota 2, Fortnite, Apex, Siege, Age of Empires and other games, get_game_ping pings each data center and names the closest; with game match it pings the server of the match being played, for any game. \
    To say what a process or host is before blocking it (nsurlsessiond, cloudd, gateway.icloud.com), call explain_connection: it says whether blocking is safe and what breaks. \
    When one site, API or app can't connect, diagnose_connection finds the layer that stops it. When an app such as Slack or Zoom fails while the rest works, service_status says whether its status page reports an outage; when your own model provider keeps failing, ask it about yourself (claude-code, codex, copilot, cursor-cli, gemini-code-assist, or your API host). \
    get_household lists the Macs paired with this one at home and what each moves now, to name the Mac behind a frozen call. \
    For device traffic at home, get_home_usage has each device's reported rate now and today's total from the router the user connected in the app; when it measures the whole home only, say so rather than blaming one device. \
    When Matter, Thread or HomeKit devices won't set up or keep dropping, check_smart_home lists the Thread networks and their border routers, counts Matter and HomeKit devices, and checks IPv6, Bonjour, client isolation, the subnet and 2.4 GHz; it never sets up or controls a device. \
    On hotel, café or airport Wi-Fi, when the internet seems down, call get_captive_portal first: a sign-in page that logged the Mac out is not an outage. \
    Both say when a service looks blocked on this network rather than down, or isn't offered where the connection appears to be; report that as measured and suggest only another network or the operator, never a way around it. \
    Before a large download or upload or a long unattended run, call get_conditions: it reports metered links, Low Data Mode, VPN, battery and heat. \
    get_updaters says which updaters Kilobat pauses on metered networks, which update bytes still got through, and which apps update from inside themselves. \
    On a travel eSIM or another prepaid data pack, get_data_pack says what's left and the day it runs out at the recent pace; it counts this Mac only, so relay that and offer to correct it with the carrier's figure. \
    get_uploads lists apps uploading a lot now, with time left only when the total is known; hold_upload holds one until an unmetered or faster network, or lets it go, and pauses another app, so ask the user first. \
    keep_awake stops idle sleep for a set time; tell the user, ask first on battery, and call release_awake when done. Closing the lid still sleeps the Mac unless you pass lid_closed, which needs the user's explicit confirmation every time. \
    list_sessions shows earlier awake sessions and AI agent runs with the data they used. \
    agent_network_log lists every host an AI agent and the commands it started (npm, pip, curl, git) contacted, with bytes and plain flags; with no arguments it returns your own session, so you can check what an install talked to. \
    When a router, ISP or carrier reports more or less data than Kilobat, compare_usage sets the two side by side for the same period with the hours Kilobat recorded and likely reasons; never call either figure wrong. \
    get_app_bandwidth shows one app's traffic over an hour, day, week or month; get_access_policy what an app says it connects to. \
    check_vpn_leaks tests whether DNS, IPv6 or UDP goes around the VPN and names each fix; it contacts outside services, so run it when the user asks. \
    Before you fetch, install from or send data to an unfamiliar host, check_host_reputation says whether it is on a known malware, phishing, scam or tracker list (read-only, local, nothing sent). When Kilobat's Protection blocks one of your requests, tell the user what was blocked and why; never turn Protection off or allow a site to get your own request through, and call set_protection only when the user asked for the change. get_protection_status says what is on and how fresh the lists are. \
    When the user asks why Kilobat allowed or blocked something, explain_verdict lists every rule that matched, the one that decided first, and where to change each; propose a change, don't make it. \
    check_vpn and get_conditions report Kilobat's VPN kill switch (`killSwitch`); while it blocks, requests fail until the VPN is back, so ask the user to reconnect the VPN rather than turning it off. \
    set_profile, set_app_rule, set_new_app_mode, block_destination, decide_approval, set_dns, set_fastest_dns, set_dns_fallback, set_budget, set_data_pack, set_app_quota, set_network_cost, set_updater_pause, set_kill_switch and set_protection change the user's settings, and clear_history deletes history: describe the change and get the user's explicit confirmation before calling them. \
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
                description: "Lists nearby Wi-Fi networks with SSID, RSSI and noise (dBm), channel, band, channel width and the strongest `security` each offers (with `securityLevel`: strong, good, weak or open), to spot crowded channels, a stronger access point or an open network. Names come from the running Kilobat app, which has Location permission; without it SSIDs read \"Hidden network\". An empty list means scanning is unavailable. Same JSON as `kilobat scan --json`.",
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
        MCPTool(name: "get_fastest_dns", title: "Fastest DNS for this network",
                description: "Which DNS resolver is fastest on this network (every network Kilobat measured with `all`), read-only, from the quiet runs the Kilobat app makes a few times a day: the network's own resolver (from DHCP) against Cloudflare, Quad9, Google and any the user added, never on metered networks, through a VPN or behind a Wi-Fi sign-in page. Each run times 10 popular names (first lookup and repeat), a name that can't exist (to catch NXDOMAIN rewriting) and the CDN addresses each resolver hands out for 3 CDN names, against the network's own. Each network has `state` (learning: fewer than 3 days of runs; network: the network's own is fastest or nothing beat it clearly; faster: `choice` won), `choice`, `choiceMs` and `networkMs` (typical median first lookup plus any CDN penalty), `days`, `runs`, `penalized` (resolvers whose CDN answers connect clearly slower, which makes browsing slower despite fast lookups), `networkRewritesMissing`, `auto` (whether Kilobat switches here; Pro), `headline` (the sentence the app shows) and `resolvers` from the latest run (`medianMs`, `p90Ms`, `repeatMedianMs`, `failures`, `cdnPenaltyMs`, `reliable`, `note` on what each keeps, and who runs it: `label` such as \"Quad9 · Switzerland\", `runBy`, `entity` and `jurisdiction`, the country it's established in, null where Kilobat doesn't know, as for the network's own, labelled \"Your provider’s\"), `history` (each resolver's lookups in the runs over the last `historyDays` days: `answered`, `failed`, `slow` (answered after more than `slowMs`), `successRate`, and per-day `days`) and `pausedUntil` (resolvers paused there after lookups failed through them). `applied` is what Kilobat has set now (`fallback` true when it's the fallback), `fallback` the resolver the user picked for when the fastest fails (null: straight back to the network's own), `switches` the recent switches with their `reason`. Report numbers as measured on this Mac; a resolver isn't more private because it's faster, so mention its `note` and jurisdiction, and never guess a jurisdiction Kilobat left null. Same JSON as `kilobat dns fastest --json`.",
                inputSchema: schema(["all": ["type": "boolean", "default": false, "description": "Every network measured in the last 90 days, not only the current one."]]),
                annotations: readOnly) { arguments, _ in
            .json(try DiagnosticsCLI.encode(await DNSCLI.report(all: try boolean(arguments, "all") ?? false, store: TrafficStore(startMonitoring: false))))
        },
        MCPTool(name: "set_fastest_dns", title: "Switch to the fastest DNS automatically",
                description: "Turns automatic switching to the fastest DNS on (`enabled` true) or off, for every network or for one (`network`, a key or name from get_fastest_dns or list_networks). Pro; the Kilobat app does the switching through its helper, only after a resolver won on 3 different days, never while a VPN, a configuration profile or a Wi-Fi sign-in page manages DNS, never over DNS servers the user set themselves, and it puts automatic DNS back when lookups fail, on leaving the network and on quit. Turning it off puts the network's own DNS back where Kilobat had switched." + confirm,
                inputSchema: schema(["enabled": ["type": "boolean"],
                                     "network": ["type": "string", "description": "A key or name; every network if omitted."]], required: ["enabled"]),
                annotations: change) { arguments, _ in
            let network = (arguments["network"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard let enabled = try boolean(arguments, "enabled") else { throw MCPToolError("enabled must be true or false.") }
            do { return .json(try object(try await DNSCLI.setAuto(enabled, network: network, store: TrafficStore(startMonitoring: false)))) }
            catch let error as CLIError { throw MCPToolError(error.message) }
        },
        MCPTool(name: "set_dns_fallback", title: "Set the fallback DNS",
                description: "Sets the resolver the Kilobat app moves to when lookups fail through the fastest DNS it switched to on a network (`resolver`: cloudflare, quad9, google or an IP address), or `off` for none. Kilobat uses the fallback only if it answers a lookup right then and didn't fail in the latest run there; if the fallback fails too, or the change doesn't take, it puts the network's own (automatic) DNS back, as it does on quit, on leaving the network and for a VPN. A resolver that failed is paused on that network for 24 hours. Choosing a resolver the user had left out of fastest DNS adds it back to the ones Kilobat times. Returns `fallback` (null when off), `label` (who runs it and where) and `effect`." + confirm,
                inputSchema: schema(["resolver": ["type": "string", "description": "cloudflare, quad9, google, an IP address, or off."]], required: ["resolver"]),
                annotations: change) { arguments, _ in
            let text = try string(arguments, "resolver")
            let choice: DNSResolverChoice?
            if ["off", "none"].contains(text.lowercased()) { choice = nil }
            else if let named = DNSResolverChoice.named(text) { choice = named.isNetwork ? nil : named }
            else { throw MCPToolError("resolver must be cloudflare, quad9, google, an IP address, or off.") }
            return .json(try object(DNSCLI.setFallback(choice, store: TrafficStore(startMonitoring: false))))
        },
        MCPTool(name: "get_wifi", title: "Wi-Fi connection",
                description: "The current Wi-Fi link: whether Wi-Fi is on, network name (ssid, null if unavailable), interface, RSSI, noise and signal-to-noise ratio (dB), channel, band, negotiated link rate, a 0–100 signal score, channel width (`widthMHz`), the Wi-Fi `standard` (Wi-Fi 4 to 7, `phyMode` such as 802.11ax), `security` (such as WPA3 Personal) with `securityLevel` (strong, good, weak or open) and a `securityNote` for weak or open networks, `transmitPowerDBm` and `countryCode` when CoreWLAN provides them. Faster than diagnose_network when only the radio matters. Same JSON as `kilobat wifi status --json`.",
                annotations: readOnly) { _, _ in
            .json(try object(await WiFiCLI.wifiStatus()))
        },
        MCPTool(name: "get_wifi_nodes", title: "Wi-Fi mesh nodes",
                description: "The joined network's mesh nodes or access points, read-only, from the running Kilobat app (BSSIDs need its Location permission). `nodes`: each node's `id` (its lowest BSSID), `name` (the user's name for it, or null), `current` (this Mac is on it), `rssi` (its strongest radio, dBm), `bands` and `radios` (`bssid`, `rssi`, `channel`, `band`, `widthMHz`, `estimatedMbps`, a rough two-stream link rate from signal and width). Radios are grouped into nodes by their addresses (a few apart, or differing only in the locally administered bit). `state`: checking, noLocation, notWiFi, notJoined, singleNode, settling (roamed in the last minute), fine, watching (a better node is in range, not yet for two minutes) or stuck. `stuck` (null unless stuck): `node`, `nodeName`, `rssi`, `betterNode`, `betterName`, `betterRSSI`, `betterBand`, `differenceDB`, `minutes` and the estimated rates. Stuck means: this Mac's signal is weaker than -65 dBm, another node's radio on a band the Mac supports is at least 15 dB stronger and promises 1.5x the link rate, held for two minutes over three readings with the Mac's own signal steady. macOS itself only roams below about -75 dBm with a 12 dB better candidate. `repeats` counts episodes on this network in 14 days; with 3 or more, suggest the mesh system's steering or roaming settings. `headline`, `detail` and `advice` are the sentences the app shows. Same JSON as `kilobat wifi nodes --json`.",
                annotations: readOnly) { _, _ in
            do { return .json(try object(try await WiFiCLI.nodesReport())) } catch let error as CLIError { throw MCPToolError(error.message) }
        },
        MCPTool(name: "reconnect_wifi", title: "Move to the closer Wi-Fi node",
                description: "Moves this Mac to the closer mesh node through the running Kilobat app: it joins that node's radio directly with the network's saved password, and if that fails or lands elsewhere, turns Wi-Fi off and on so macOS picks the strongest radio. Wi-Fi drops for a few seconds, which interrupts calls, downloads and possibly this conversation's own connection; the result arrives once Wi-Fi is back. Returns `reconnected`, `method` (associate or power), `better` (now on the closer node), `node`, `rssi` and `sentence`, or `error`. Without the app running it only turns Wi-Fi off and on. Call it only after get_wifi_nodes reports `stuck`, and describe the interruption and get the user's explicit confirmation before calling. Same JSON as `kilobat wifi reconnect --json`.",
                annotations: MCPToolAnnotations(readOnly: false, destructive: true, idempotent: false)) { _, _ in
            guard AppRelay.appRunning else {
                try await WiFiConnection().restart()
                return .json(try object(["reconnected": true, "method": "power", "node": NSNull(), "sentence": "Wi-Fi restarted. Open Kilobat to see which node you’re on."]))
            }
            guard let data = await AppRelay.ask("nodes|reconnect", timeout: .seconds(60)), let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MCPToolError("The Kilobat app didn’t answer.")
            }
            return .json(try object(value))
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
                description: "Devices this Mac has recently talked to on the local network (the ARP neighbor cache), with what Kilobat remembers about each on this network: `address`, `mac`, `interface`, `name` (the user's name for it, else the device's own or its maker's), `status` (new: joined since Kilobat began watching this home network and not answered yet; known: the user's, or there when watching began; unknown: the user said they don't recognise it; ignored; null when Kilobat hasn't recorded this network), `verdict`, `friendlyName`, `hostname`, `vendor`, `privateAddress` (a randomised Wi-Fi address with no maker), `firstSeen`, `lastSeen`, `present`, `type` (camera, doorbell, tv for a TV or streaming stick, casting, speaker, printer, plug for a smart plug or switch, hub, console, phone for a phone or tablet, computer, drone for a drone or action camera, router, nas or unknown), `confidence` (set: the user chose it; high: the device declares it, such as a HomeKit category, a Cast receiver or a printing service; medium: a product name or a maker that makes mostly that; low: a weak hint; absent when unknown), `typeLabel` (as the app says it, such as \"Probably a camera (Wyze)\"), `typeEvidence` and `tags` (HomeKit, Matter, Thread border router). Say a medium or low type with its hedge, never as fact. Pass `all` to add remembered devices that aren't in the cache now. Not a full network scan. Never present a new or unknown device as an intruder: it is a device the user hasn't identified. Same JSON as `kilobat devices --json`.",
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
        MCPTool(name: "get_router_checkup", title: "Router check-up",
                description: "Whether the router has been getting slower over days, read-only, from the health checks the Kilobat app runs in the background (router ping and a name lookup about once a minute, only counting checks while this Mac's own traffic was light). `routers` holds the router this Mac used last (all seen in 60 days with `all`), each with: `state` — learning (fewer than 7 days with enough quiet checks; `days` says how many), waiting (no 3 recent days with data), normal, degraded (each of the last 3 days with data at least twice the usual router reply and 5 ms more, or 3+ points more ping loss, or 3+ drops a day) or signal (worse, but this Mac's Wi-Fi explains it: weaker signal, another band or access point); `baseline` (`routerMs`, `routerP90Ms`, `lossPercent`, `dnsMs`, `dropsPerDay` over up to 14 days before the recent ones); `recent` and `trend` (per day: `routerMs`, `lossPercent`, `dnsMs`, `drops`, `quietHours`); `symptoms` (slower, loss, drops; dns only alongside another, since lookups through the router also time the provider); `slowingSince`; `restarts` (newest first: `source` outage when the router went away for 30 s–10 min and the same router came back, or button when the user said they restarted it; `outcome` fixed, helped, didntHelp, unclear or noProblem, null while the day after is still being watched; `beforeMs`, `afterMs`); and `headline`, `detail`, `advice`, `followUp`, the sentences the app shows. Use it when someone asks whether to restart their router or why the connection got worse over days. Report the numbers as measured from this Mac; never claim the router is failing. `uptimeSeconds` comes from a router connected in the app (restarts with `source` router are its own word). `firmware` (or null) is a gentle reminder for a router Kilobat can name but not read: no firmware check known for about 3 months, with `maker`, `line` and `guide` (kilobat.app router guide, or null); never tell the user an update exists from it, and never start one. Same JSON as `kilobat router --json`.",
                inputSchema: schema(["all": ["type": "boolean", "default": false, "description": "Every router seen in the last 60 days, not only the latest."]]),
                annotations: readOnly) { arguments, _ in
            .json(try DiagnosticsCLI.encode(RouterCLI.reports(all: try boolean(arguments, "all") ?? false)))
        },
        MCPTool(name: "get_weekly_digest", title: "Weekly digest",
                description: "The week in a few lines, read-only, from what the Kilobat app keeps on this Mac: the 3–4 most notable facts of the seven days before the digest day (Monday by default), most notable first, and a sentence for a calm week. Facts, in the order they matter: `outages` (on the provider's side: the router answered while the internet didn't; outages at the user's own router or Wi-Fi rank lower), `calls` (calls that froze, and the most common cause), `remote` (SSH or remote desktop sessions that lagged), `router` (the router slower than its own normal for days), `starlink` (dish drops the setup can fix), `protection` (malware, phishing and scam hosts and the agent guard blocked, AI agents' first), `agents` (an agent sent data to a share, tunnel or large upload), `metered` (data on hotspots and other metered networks), `credit` (outages that may qualify for a provider credit), `plan` (speed tests under the plan), `signIns` (hotel or café Wi-Fi sign-in pages), `trackers`, `routerHealthy`. Each has `line` (the sentence the notification uses), `detail`, `comparison` (\"half last week’s\", \"up from 2 last week\", only when the week before was recorded and the change says something), `value` and `previous`, `days` (one value a day for a sparkline, where Kilobat has one), `problem` and `tab` (where the app has details). `calm` is true when nothing went wrong, with `summary` such as \"A calm week: no outages, every call clean and 38 GB at home.\"; `headline` is the notification's text; `partial` means Kilobat's history starts inside the week; `compared` says whether the week before was recorded. Zeros are never listed. Report the facts as measured; an outage on the provider's side is Kilobat's evidence, not proof. Same JSON as `kilobat week --json`.",
                inputSchema: schema(["weeks_ago": ["type": "integer", "minimum": 0, "maximum": 12, "default": 0, "description": "0 for the last full week (the one the latest digest covered), 1 for the week before, up to 12."]]),
                annotations: readOnly) { arguments, _ in
            .json(try DiagnosticsCLI.encode(WeekCLI.digest(weeksAgo: try integer(arguments, "weeks_ago", in: 0...12) ?? 0)))
        },
        MCPTool(name: "get_outage_credit", title: "Outage credit from the provider",
                description: "Adds up a month's internet outages that Kilobat can show were on the provider's side (the router kept answering while two internet servers and an HTTPS check failed, or a Starlink dish blamed Starlink's network), leaving out outages at the user's own router or Wi-Fi, ones without enough checks, and time the Mac was asleep. Then applies the provider's published outage-credit rule from Kilobat's bundled, dated table (Ofcom automatic compensation, Germany's § 58 TKG, Spain's RD 899/2009, Italy's AGCOM indemnities, Xfinity, AT&T, Orange, Free and others) and drafts a claim. Returns `providerName`, `provider` (with `asns`, `note` when no rule could be verified), `policy` (`threshold`, `credit`, `automatic`, `claim` with `url`, `phone`, `windowDays`, `source`, `checked`, `caveats`), `tally` (`outages` each with `start`, `end`, `routerChecks`, `routerAnswered`, `dishOutages`; `localSeconds`, `unprovenSeconds`, `asleepSeconds`), `estimate` (`qualifies`, `amount`, `currency`, `atLeast`, `needsPrice`, `days`, `askBy`), `verdict`, `terms`, `excluded` and `claim` (`subject`, `body` with an account-number placeholder). The provider and monthly price come from the app's History › Outage credit unless `provider`, `country` or `monthly_price` are passed for this call. Say \"may qualify\" and \"about\": providers count from when the fault is reported and decide what qualifies, so never promise money. Never send the claim; give it to the user. Same JSON as `kilobat credit --json`.",
                inputSchema: schema(["provider": ["type": "string", "description": "A provider id from `kilobat credit providers`, such as gb-bt or us-xfinity."],
                                     "country": ["type": "string", "description": "Two-letter country, for a provider Kilobat doesn't know: the country's law applies where one covers every provider."],
                                     "monthly_price": ["type": "number", "exclusiveMinimum": 0, "description": "What the user pays a month for internet, in the policy's currency."],
                                     "month": ["type": "string", "default": "this", "description": "this, last or a month such as 2026-09."]]),
                annotations: readOnly) { arguments, _ in
            var args = ["credit"]
            if let provider = arguments["provider"] as? String { args += ["--provider", provider] }
            if let country = arguments["country"] as? String { args += ["--country", country] }
            if let price = arguments["monthly_price"] as? NSNumber { args += ["--price", "\(price.doubleValue)"] }
            if let month = arguments["month"] as? String { args += ["--month", month] }
            let options: CreditOptions
            do { options = try CreditOptions.parse(args) } catch { throw MCPToolError(error.localizedDescription) }
            return .json(try DiagnosticsCLI.encode(CreditCLI.report(options)))
        },
        MCPTool(name: "get_service_speed", title: "Real speed to GitHub, iCloud, Steam and more",
                description: "How fast this Mac's own downloads from each service actually ran, read-only, from what the Kilobat app measured: every download of 5 MB or more (one service's connections together, over the seconds they were moving), named by the host the app asked for, the app, or the network its address belongs to (GitHub, Apple, Valve, Akamai, Fastly, Cloudflare, Amazon CloudFront, Google, Microsoft…). Video, music and calls are never counted. `networks` holds the network the Mac was on last (every network with downloads in 30 days with `all`), each with `capacity` (`mbps` and `source`: speedTest, the latest test on that network, or transfer, the fastest download seen), `rows` per service (`key`, `name`, `kind` service or network, `typicalMbps` the 30-day median, `latestMbps`, `latest`, `transfers`, `percentOfLine`, `slowToday` of `today`, `state` fast, mixed, slow or unknown, `pattern` with `startHour`, `endHour`, `days` when it's slow at the same hours each day, `via`, `testable`) and `finding` when one service is clearly slow: 3+ downloads in the last day under a third of the line, each with another site or a speed test 3× as fast within the hour, most of that service's downloads slow, and not slow on every other network. `kind` route means the slowdown is between the provider and that service; service means its status page reports a problem. It has `headline`, `detail`, `evidence` (status page, route trace hop where delay rises, time-of-day pattern) and `advice`. Report it as measured from this Mac; a route finding is strong evidence, not proof, of a peering or routing problem. Same JSON as `kilobat service-speed --json`; `kilobat service-speed --test <service>` measures one now (up to 25 MB, refused on metered networks), which this tool never does.",
                inputSchema: schema(["all": ["type": "boolean", "default": false, "description": "Every network with downloads in the last 30 days, not only the latest."]]),
                annotations: readOnly) { arguments, _ in
            .json(try DiagnosticsCLI.encode(ServiceSpeedCLI.reports(all: try boolean(arguments, "all") ?? false)))
        },
        MCPTool(name: "get_hotspot_throttling", title: "Is the carrier capping the phone hotspot?",
                description: "Whether the phone hotspot this Mac is on looks capped by the mobile carrier, read-only, from what the Kilobat app already measured: speed tests and this Mac's own downloads of 5 MB or more on that network in the last 14 days (each with whatever else downloaded at the same time, since a cap holds the whole hotspot), Health's idle pings, and video sessions (YouTube, Netflix, Twitch, Disney+, Prime Video) timed passively on hotspots. `networks` holds the current network first (`state` notHotspot when it isn't a phone hotspot or metered network; `kind` iPhone, android, bluetooth or metered), every hotspot Kilobat has seen with `all`. `state` cap means at least 4 measurements from 2+ sources (speed tests or different services), on 2+ occasions 2+ hours apart, sat within 8% of each other at one of the limits carriers publish (128, 512 and 600 kbps, 1, 1.5, 3, 4, 5, 6, 10 or 15 Mbps), with none faster, while the idle ping stayed normal (150 ms or less, jitter 40 ms or less, loss under 3%): `capMbps`, `plateauMbps`, `variationPercent`, `latencyMs`, `atCeiling`, `occasions`. `videoCap` means 3+ video sessions never fetched faster than about 1.5 Mbps while 2+ other measurements ran 2.5× faster (`videoMbps`, `otherMbps`). learning means too little to tell; noCap means speeds wander (signal or a busy cell) or beat every limit. Each report has `headline`, `detail`, `advice`, `evidence`, `measurements`, `videoSessions` and `carrier` (`id`, `name`, `page` with that carrier's published hotspot rules, `source` you or lookup, `sharedWith` MVNOs on the same network) or `carriersPage` when unknown. Say \"looks like\" and \"likely\": it can't tell a hotspot cap from a plan that caps all data, which the phone's own browser can. Never suggest hiding hotspot use from the carrier (TTL changes and the like); suggest checking the plan's hotspot allowance, the carrier page, or another plan. `carrier` names the carrier for this call (an id from the carrier list). Same JSON as `kilobat hotspot --json`; `kilobat hotspot --detect` looks the carrier up from the public address (Cloudflare and RIPE NCC), which this tool never does.",
                inputSchema: schema(["all": ["type": "boolean", "default": false, "description": "Every phone hotspot Kilobat has seen, not only the current network."],
                                     "carrier": ["type": "string", "enum": HotspotCarriers.all.map(\.id), "description": "The carrier, for this call only, when the user says which it is."]]),
                annotations: readOnly) { arguments, _ in
            let carrier = try (arguments["carrier"]).map { value -> HotspotThrottleReport.Carrier in
                guard let id = value as? String, let found = HotspotCarriers.carrier(id) else { throw MCPToolError("carrier must be one of: \(HotspotCarriers.all.map(\.id).joined(separator: ", ")).") }
                return .init(found, source: "you")
            }
            return .json(try DiagnosticsCLI.encode(await HotspotCLI.reports(all: try boolean(arguments, "all") ?? false, carrier: carrier)))
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
                description: "Whether now suits a large download or upload or a long unattended run: `connected`, `network` (Wi-Fi, Ethernet, Cellular), `metered` (what Kilobat acts on), `osMetered` (what macOS says) and `meteredSource` (macOS, or you when the user set the network's data cost), `lowDataMode`, `vpn` (the default route goes through a tunnel), `vpnInterface`, `vpnName` and `vpnConnected` (VPNs macOS lists as connected, which may carry only some destinations; get_exit_path has the detail), `internetLatencyMs` and `internetLossPercent` from a quick ping, `power` (`batteryPercent`, `onAC`, `thermal`, `lowPowerMode`), whether Kilobat keeps the Mac awake (`keptAwake`, `awakeReasons`, `awakeUntil` for keep_awake), `awakeOnPower` (`enabled`, `display`, `active`: the user's own Stay awake while plugged in setting, which no tool changes), `updaters` (`pauseOnMetered`, the setting, and `paused`, whether the filter pauses updaters on this network now; get_updaters has the detail), `killSwitch` (as in check_vpn: while `state` is blocking, new connections fail until the VPN is back) and one line of `advice`. Takes about 2 seconds. Same JSON as `kilobat conditions --json`.",
                annotations: MCPToolAnnotations(readOnly: true, openWorld: true)) { _, _ in
            .json(try object(await AwakeCLI.conditions(holdUntil: hold?.until)))
        },
        MCPTool(name: "get_updaters", title: "Updaters paused on metered networks",
                description: "Whether Kilobat pauses updater helpers on metered networks (`enabled`, on unless the user turned it off), whether this network is `metered` and they are `paused` now, and `filterActive` (null when the Kilobat app isn't running; pausing needs its network filter). `covered` lists the helpers it recognizes (`downloads` is false for Sparkle's and Squirrel's installers, which only install what the app already downloaded). `gotThrough` lists update bytes on the current network: an updater's own, or a System downloads service such as nsurlsessiond that connected for one (`shared`, so its bytes include other downloads); null without the running app. `pausedConnections` counts updater connections the filter stopped in the last 24 hours. `inProcess` lists installed apps that update from inside their own process (Sparkle or Squirrel), which can't be paused without blocking the app. `limits` says what pausing can't do. Same JSON as `kilobat updaters --json`.",
                annotations: readOnly) { _, _ in
            .json(try object(try UpdatersCLI.object(await UpdatersCLI.report(TrafficStore(startMonitoring: false)))))
        },
        MCPTool(name: "get_uploads", title: "Big uploads and held ones",
                description: "Apps uploading a lot right now and uploads held for a better network, from the running Kilobat app, read-only. A big upload is an app sending at least `thresholdBytesPerSecond` (1 MB/s, or half the upload a speed test measured on this network if that's less) for 20 seconds. Each entry has `app` (the key to pass to hold_upload), `name`, `ids`, `state` (uploading or held), `bytesPerSecond`, `sentBytes` since it started, and `totalBytes`, `doneBytes`, `file` and `etaSeconds` only when the total is knowable (curl -T sending one file: its size, and what curl has sent); for Dropbox, Google Drive, OneDrive, iCloud, git push and browsers they are null, so never invent a time left. `method` says how it can be held: suspend (sync and backup apps, paused), block (new connections refused by the network filter) or none, with `reason`. Held entries have `until` (`kind` unmetered, fast with `mbps`, time with `until`, or manual), `heldOn` and `resumesBy`, the latest it goes again. `appRunning` false means the app isn't open and nothing is measured. Same JSON as `kilobat uploads --json`.",
                annotations: readOnly) { _, _ in
            .json(try object(try UploadsCLI.object(await UploadsCLI.report())))
        },
        MCPTool(name: "diagnose_connection", title: "Why something can't connect",
                description: "Checks why one website, API or host can't be reached from this Mac, layer by layer: the Mac's network and the interface it uses (Wi-Fi, Ethernet, a phone hotspot or a VPN), the system proxy and PAC file, DNS and its resolver (including a VPN's private resolver for its domain), Kilobat's own rules, TCP and TLS over IPv4 and IPv6 separately, the same connection over each interface when there are several, the exact request (path and query kept) through the path the app uses, every redirect hop with its own IPv4 and IPv6 check of the final host, and with a VPN or proxy on, the direct path against the tunnel or proxy. A HEAD request the server refuses is retried once as a one-byte GET; nothing larger is downloaded. A broken IPv6 or IPv4 path, a tunnel that fails while direct connections work, a proxy that works where direct connections are blocked, and a redirect target that fails each get their own verdict. A passing check means this request from this Mac over that path works now, not that every app or transfer is fine. Returns `verdict`, `next` (what to do), `ok`, `steps` (`layer`, `status`: ok, warning, failed or skipped, and `detail`), `hops` (`url`, `host`, `method`, `status` or `error`), `method` (what the check sent: HEAD, or a one-byte GET), `path` (`kind`: appProxy, environmentProxy, systemProxy or direct; `proxy` as host:port; `untested`, an app setting the check couldn't go through), `client` (`id`, `name`, `version` of the app as installed), `date` (when the check ran), `failedAt`, and `services` when the host or app belongs to a service with a public status page (as service_status returns it, with a `Status page` step); when that page reports an outage and nothing on this Mac failed, the verdict says so. `target`, details and hop URLs never show query values or passwords. Pass `app` (a bundle ID or process:<name> from get_status) to include that app's rules, the proxy variables in its environment (HTTPS_PROXY, ALL_PROXY, NO_PROXY) and its open connections to the host or its proxy, compared with the fresh one, and a `Transfer` step that says whether bytes still arrive on them a few seconds apart. A quiet transfer may be stalled or finished with its connection still open: never report a download as finished from it. Pass `proxy` when the app uses a proxy address from its own settings: the request goes through it, and when that fails while direct connections work, the verdict says the network is fine and the app's path isn't. Some apps have a setting Kilobat can't read or go through, such as LM Studio's Hugging Face proxy (a switch with no address) for huggingface.co downloads: an `App setting` step cites dated user reports, and the verdict says the network works, not that the app's request does. Suggest the user checks that setting; never change another app's settings or promise it will resume a download on its own. Pass `failed_at` when the user says when the app failed. Pass `context` when the failing code runs in a container, VM or remote machine: the checks still run on this Mac, and a `Context` step says how to check from there. Pass `context` provider when a hosted service makes the request from its own servers (Warp's custom inference endpoint, say; pass its `app`, dev.warp.Warp-Stable, to name it): a `Provider` step says whether the target is private (localhost, a LAN or Tailscale address, a name only private DNS knows), which those servers can't reach however well it works from the Mac. Picking a known provider as `app` adds that step on its own, worded as an if. Never suggest SSH into the provider or exposing the Mac's service through a tunnel; the options are a public endpoint the user controls or a route the provider supports, quoted from `next`. When the user describes a slow or failing transfer already under way, say that a fresh check can't see that connection, and suggest get_app_bandwidth for it. When a failure could be the network itself, a `Network block` step and a `block` object say whether this network blocks the site, and lead the verdict (\"Slack looks blocked on this network, not down: …\"): `state` blocked, `signals` (nameMissing, nameSilent, privateAnswer, inventedAnswer, wrongServer: DNS tampering, measured against one DNS-over-HTTPS question to the user's trusted resolver, Cloudflare by default; tlsReset or tlsSilent: the secure connection cut once the name is sent while the same server answers another name; unreachable, only with a green status page; blockPage), `evidence`, `summary`, `next`, `place` (home, mobile, public, wifi, wired, unknown), `vpn` (the checks went through it), `resolver` and `status`. A sign-in page, Kilobat's own rules, Protection or kill switch, split DNS and an outage on the status page rule a block out. When the service itself refuses where the connection appears to be (HTTP 451 over a verified connection, or its own regional error such as OpenAI's unsupported_country_region_territory), a `Region` step and `block` with `state` regionUnavailable give `exitCountry` (registry data for the public address, through any VPN) and `timeZoneCountry` when the Mac's time zone differs. Report both as neutral facts: suggest another network or the operator for a block, the service's supported-countries list or support for a region; never suggest a VPN, proxy, other DNS or any way around a block or a regional restriction. Pass `error` with the error text or body the app got, so a regional refusal is recognised from it. Takes up to about 30 seconds. Same JSON as `kilobat why <target> --json`.",
                inputSchema: schema(["target": ["type": "string", "description": "A host such as api.example.com, or the exact http or https URL that fails, query included."],
                                     "app": ["type": "string", "description": "Bundle ID such as com.example.App, or process:<name>."],
                                     "proxy": ["type": "string", "description": "A proxy the app uses by its own setting, such as http://127.0.0.1:7890 or socks5://127.0.0.1:1080."],
                                     "context": ["type": "string", "enum": ConnectionDoctor.Context.allCases.map(\.rawValue), "description": "Where the failing code runs, when not on this Mac; provider for a hosted service whose servers make the request."],
                                     "failed_at": ["type": "string", "description": "When the app failed, as ISO 8601 (2026-10-29T14:05:00Z) or 14:05 today; recorded beside the check's own time."],
                                     "error": ["type": "string", "description": "The error message or body the app got, to recognise a service's own regional refusal."]], required: ["target"]),
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
                                                    context: context, policy: await AwakeCLI.policy(), failedAt: failedAt,
                                                    appError: (arguments["error"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            if report.steps.isEmpty { throw MCPToolError(report.verdict + " " + report.next) }
            return .json(try AwakeCLI.doctorJSON(report))
        },
        MCPTool(name: "list_sessions", title: "Awake sessions and agent runs",
                description: "Awake sessions and AI agent runs (Claude Code, Codex, Gemini CLI and others) the Kilobat app recorded over the last `days` (7 by default), newest first: `kind` (awake or agent), `title`, `start`, `end`, `ended` (Finished, Failed, Went quiet, Exited, Timer ended, Turned off); for agent runs the agent's hooks report, `session`, `cwd`, `project` and `state` (working, waitingForYou, done, stalled, networkFailed or failed; the last one seen for an ended run), `note` (e.g. Rate-limited until 3pm), `lastEvent` (last hook), `lastActive` (last traffic) and `lastCPU` (last CPU work), and `sharedTraffic` when bytes may include other runs of the same agent; only `ended` Finished means the agent said it was done. `executable`, `origin` (Homebrew, npm (node 22.3.0), Claude app…), `version` and `otherInstalls` show which install ran; bytes `received` and `sent`, bytes per process (`apps`), `destinations` an agent contacted, `events` (network changes during the run), `batteryStart`, `batteryEnd` and `peakThermal`. Recorded only while the app runs. Same JSON as `kilobat sessions --json --days N`.",
                inputSchema: schema(["days": ["type": "integer", "minimum": 1, "maximum": 365, "default": 7, "description": "Number of days."]]),
                annotations: readOnly) { arguments, _ in
            .json(try DiagnosticsCLI.encode(AwakeCLI.history(days: try integer(arguments, "days", in: 1...365) ?? 7)))
        },
        MCPTool(name: "agent_network_log", title: "Agent network log",
                description: "Every host an AI agent (Claude Code, Codex, Cursor, Gemini CLI, Aider and others) and the processes it started (npm, pip, curl, git, through shells too) contacted, as the Kilobat app recorded it from this Mac's own network statistics. Read-only and local. With no arguments: the session of the agent this MCP server runs under, when the log has it, else the latest session. `all` returns every session kept (30 days), `since` those since a time (30m, 2h, 3d, today, 2026-10-30), `agent` narrows to one agent (claude, codex, cursor, gemini…), `flagged` keeps only flagged hosts. Each session has `agent`, `project`, `cwd`, `start`, `end`, `running`, bytes `sent` and `received`, `hostCount`, `flaggedCount`, and `hosts`: `process`, `host` (the name, or the address when none is known), `nameSource` (filter: the name the app asked for; lookup: a well-known or command-line host that resolves to that address on this Mac; reverse: reverse DNS, not the name the app used), `addresses`, `port`, `transport`, `first`, `last`, `sent`, `received`, `connections` and `flags` (newHost, plainHTTP, largeUpload over 10 MB to a host other than the agent's own service, addressOnly, shareOrTunnel with `category` paste site, file share, tunnel or request catcher). Flags are reasons to look, not verdicts: say what was contacted, never that data was stolen. `unmatchedSent`/`unmatchedReceived` are bytes on connections that closed between one-second samples. `recording` false means the app isn't recording (it records with Kilobat Pro); a missing log means it never has. Traffic through system services (DNS, Docker's VM, nsurlsessiond) and processes that start and exit within half a second can be missing. Same JSON as `kilobat agent-log --json`.",
                inputSchema: schema(["all": ["type": "boolean", "description": "Every session in the log, newest first."],
                                     "since": ["type": "string", "description": "Sessions since then: 30m, 2h, 3d, 1w, today, yesterday, a date such as 2026-10-30 or an ISO 8601 time."],
                                     "agent": ["type": "string", "description": "One agent: claude, codex, cursor, gemini, aider, windsurf…"],
                                     "flagged": ["type": "boolean", "description": "Only hosts with a flag."]]),
                annotations: readOnly) { arguments, _ in
            var options = ["agent-log"]
            if try boolean(arguments, "all") == true { options.append("--all") }
            if try boolean(arguments, "flagged") == true { options.append("--flagged") }
            if let since = arguments["since"] as? String, !since.isEmpty { options += ["--since", since] }
            if let agent = arguments["agent"] as? String, !agent.isEmpty { options += ["--agent", agent] }
            let query: AgentLogQuery
            do { query = try AgentLogQuery.parse(options) } catch let failure as AgentLogQuery.Failure { throw MCPToolError(failure.message) }
            let (recording, updated, entries) = AgentLogCLI.load(query)
            return .json(try DiagnosticsCLI.encode(AgentLogCLI.Output(recording: recording, updated: updated, sessions: entries)))
        },
        MCPTool(name: "create_support_report", title: "Report for an ISP or IT desk",
                description: "Builds a report the user can send to their internet provider, IT desk or a friend: what this Mac measured on its current network over the last `hours` (24 by default, at most 168). `findings` are plain sentences, most useful first: outages, whether the delay starts at the router or beyond it, ping loss, speed tests against the user's plan, and the optional `host` check. `latency` has medians and the 95th percentile with hourly values; `outages` and `speedTests` list what was recorded. The report never includes the network's name, local IP addresses, hardware addresses, device names or which apps used the network, and says so in `leftOut`. Site names are left out by default, including hosts mentioned in redirects. Pass `include_site_names: true` only when the user wants those names included. Public server addresses in a host check stay. It only covers this Mac and the checks the Kilobat app recorded while it ran: if `findings` says nothing was recorded, tell the user to keep the app running and try later. Returns `text` (to paste into a support chat) and `report` (the same as JSON). For a printable page, the user can run `kilobat support-report --html --output ~/Desktop/report.html` or use the report button in Kilobat's Health tab, which saves a PDF. Never send the report anywhere yourself; give it to the user. Same as `kilobat support-report --json`.",
                inputSchema: schema(["hours": ["type": "integer", "minimum": 1, "maximum": 168, "default": 24, "description": "How far back to look."],
                                     "host": ["type": "string", "description": "A host or URL to check now and include, such as the site or service that fails."],
                                     "include_site_names": ["type": "boolean", "default": false, "description": "Keep the checked host's name and a slow service's name in the report. Off, they read \"the site checked\" and \"one service\". Pass true only when the user wants the names in it."]]),
                annotations: readOnly) { arguments, _ in
            let report = try await WiFiCLI.makeSupportReport(hours: try integer(arguments, "hours", in: 1...168) ?? 24, host: arguments["host"] as? String,
                                                             includeSites: try boolean(arguments, "include_site_names") ?? false)
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
                description: "Checks the VPN and proxies on this Mac from its routes and resolvers, read-only: `vpnState` (full, partial or off) and `vpn` (its name when macOS lists exactly one), `dnsServer` and `dnsInterface` (where name lookups go), `ipv6Interface` (where IPv6 leaves), and `findings`: DNS that skips the VPN (lookups go to the local network), IPv6 that skips it (sites over IPv6 see the real address), a proxy and a VPN both taking traffic, a dead system proxy. Each finding says what to try. `killSwitch` is Kilobat's VPN kill switch: `enabled` and `allowLAN` (the settings), `state` (off, needsPro, needsFilter, waiting: it arms the first time the VPN carries all traffic, protected, blocking: the VPN is down and new connections are refused, allowed: the user let traffic through for a few minutes until `allowedUntil`; null when the Kilobat app isn't running), `armed`, `vpnUp`, `filterActive` and a `summary`. It can't see inside the VPN app or prove privacy; say what was measured. Same as `kilobat vpn --json`.",
                inputSchema: schema([:]), annotations: readOnly) { _, _ in
            let killSwitch = ProxyCLI.killSwitch(await WiFiCLI.connection())
            return .json(try object(try ProxyCLI.vpnObject(await TunnelCheck.run(), killSwitch: killSwitch)))
        },
        MCPTool(name: "check_vpn_leaks", title: "VPN leak test",
                description: "Tests whether DNS, IPv6 or UDP (what a browser's WebRTC uses) goes around the VPN, and names the setting that fixes each, read-only. Run it only when the user asks about leaks or privacy with their VPN on: it contacts outside services, which see the user's address: bash.ws (which resolvers answered made-up lookups, with their network), Cloudflare (the exit address), Google's or Cloudflare's STUN server over UDP, through the VPN and straight out of Wi-Fi or Ethernet, and api6.ipify.org when IPv6 skips the VPN. Returns `checks`, each with `id` (dns, ipv6, udp), `status` (pass, fail, warning, skipped), `title`, `detail` and `fix` (what to change, in the VPN app's own words where Kilobat knows them, or in System Settings or the browser), plus `passed`, `summary`, `vpnState`, `vpn`, `tunnel`, `exitAddress` and `services` (the hosts asked). Without a VPN carrying all traffic every check is skipped. A pass covers this Mac at this moment, not every app or browser; never call a VPN private because it passed. Takes about ten seconds. Same JSON as `kilobat vpn leaks --json`.",
                inputSchema: schema([:]), annotations: MCPToolAnnotations(readOnly: true, openWorld: true)) { _, _ in
            .json(try object(try ProxyCLI.leakObject(await LeakTest.run())))
        },
        MCPTool(name: "get_call_reports", title: "Call quality reports",
                description: "The report cards the Kilobat app wrote after recent calls in Zoom, Teams, FaceTime, Slack, Webex, Discord, a browser and other calling apps, newest first, read-only. Each has `app`, `browser`, `start`, `end`, internet `median` ping and `jitter` in ms, `lossPercent`, and `freezes`: each with `at` (seconds into the call), `seconds`, `peak` ms (null when every ping was lost) and `cause` — `kind` app (with `app` and `uploading`), wifi (`weakSignal`), otherDevice (another device on the network, with `device` when Kilobat could name it; `kilobat` true when a paired Mac running Kilobat reported it was busy, with its busiest app in `deviceApp`), airDrop, starlink, portal (the Wi-Fi's sign-in page logged the Mac out) or beyondRouter. A freeze is two or more seconds of pings lost or 200 ms over the call's median. `service`, when present, is what the calling app's status page said as a call that froze beyond the router ended (`state`, `incident`, `page`). Kilobat never listens to calls; it notices the microphone and pings once a second. Empty when the app isn't running or no call was long enough. Same as `kilobat calls --json`.",
                inputSchema: schema(["limit": ["type": "integer", "minimum": 1, "maximum": 50, "default": 10, "description": "How many calls, newest first."]]), annotations: readOnly) { arguments, _ in
            let limit = try integer(arguments, "limit", in: 1...50) ?? 10
            return .json(try DiagnosticsCLI.encode(Array(CallStore.load().suffix(limit).reversed())))
        },
        MCPTool(name: "get_remote_session_reports", title: "SSH and remote desktop session reports",
                description: "The reports the Kilobat app wrote after recent SSH, Mosh, Screen Sharing, Parsec, Jump Desktop, Windows App (Microsoft Remote Desktop), AnyDesk, TeamViewer and RustDesk sessions, newest first, read-only. Use it when someone asks why typing lagged over ssh, why a remote desktop froze, or whether to switch to Mosh. Each has `kind` (ssh, mosh, screenSharing, parsec, jump, windowsApp, anyDesk, teamViewer, rustDesk), `host` as typed and `address`/`port` of the connection, `start`, `end`, `measured` (host: pinged the host itself; internet: the host ignores ping), `median`, `jitter`, `low` and `peak` round trip in ms, `lossPercent`, `base` (the host's usual round trip; 150 ms or more feels slow to type on) and `lags`: each with `at` (seconds in), `seconds`, `peak` ms and `cause` — `kind` portal (the Wi-Fi's sign-in page logged the Mac out; it comes first), app (with `app` and `uploading`), wifi (`weakSignal`), airDrop, otherDevice (`device` and `deviceApp` for a paired Mac), starlink, beyondRouter (your provider or further), remotePath (the internet answered but the host didn't: past your provider) or remoteSlow (input went unanswered while the host answered pings on time: the server itself was slow; claimed only after two such stalls). `strain` lists stretches when the Mac was overloaded. `verdict`, `advice` and `mosh` are the report's sentences; `suggestsMosh`, `far` and `clean` its findings. Suggest Mosh for ssh only when `suggestsMosh` is true, which holds when lags came from Wi-Fi, AirDrop, Starlink or the path, or the host is far, jittery or lossy; never for a busy app, the Mac or a slow server. A session counts only after a minute of input from the terminal or viewer in front, so scp, sftp, rsync, git over ssh and tunnels never appear. Kilobat never reads the session. Same as `kilobat remote --json`.",
                inputSchema: schema(["limit": ["type": "integer", "minimum": 1, "maximum": 50, "default": 10, "description": "How many sessions, newest first."],
                                     "kind": ["type": "string", "enum": ["ssh", "mosh", "desktop"], "description": "Only SSH, only Mosh, or only remote desktop apps."]]), annotations: readOnly) { arguments, _ in
            var query = RemoteSessionQuery()
            query.limit = try integer(arguments, "limit", in: 1...50) ?? 10
            if let kind = arguments["kind"] as? String {
                guard let filter = RemoteSessionQuery.Filter(rawValue: kind) else { throw MCPToolError("kind must be ssh, mosh or desktop.") }
                query.filter = filter
            }
            return .json(try DiagnosticsCLI.encode(query.select(RemoteSessionStore.load()).map(RemoteSessionReport.Exported.init)))
        },
        MCPTool(name: "get_stream_reports", title: "OBS stream reports",
                description: "The reports the Kilobat app wrote after recent OBS Studio streams, newest first, read-only. Use it when someone asks why OBS dropped frames, why a Twitch or YouTube stream lagged, or whether to lower the bitrate. Kilobat reads OBS's own counters over its local WebSocket (OBS 28+, opted in under Settings › Streaming) once a second, so each drop has a `source`: network (OBS's \"Dropped Frames (Network)\"), encoder (\"skipped frames due to encoding lag\") or render (\"frames missed due to rendering lag\": the GPU). Only network drops are the connection; never tell the user to fix their internet for encoder or render drops. Each report has `start`, `end`, `bitrate` (kbps OBS was set to, video plus audio; null when OBS doesn't say), `sent` (kbps actually sent), `uplink` (Mbps, the last speed test on that network) and `neededMbps` (bitrate plus 30% headroom), `frames`/`dropped`, `encoderFrames`/`encoderSkipped`, `renderFrames`/`renderSkipped` with `networkPercent`, `encoderPercent` and `renderPercent`, the internet `median`, `jitter` and `lossPercent`, `congestion` (OBS's worst, 0–1), and `drops`: each with `at` (seconds in), `seconds`, `frames`, `percent`, `source` and `cause` — `kind` app (with `app` and `uploading`), otherDevice, wifi (`weakSignal`), airDrop, starlink, portal, beyondRouter (the provider or the path to the ingest server), bitrate (set above what the upload carries with 30% headroom), encoder (with `top`, a process that maxed out the CPU) or render (`gpu`). `spans` gives each drop's clock times. `verdict`, `capacity`, `obsSide` and `advice` are the report's sentences; `meaningful` is whether it lost 0.5% or more, or 5% in one stretch; `held` lists apps Call mode for streams paused. Same as `kilobat stream reports --json`.",
                inputSchema: schema(["limit": ["type": "integer", "minimum": 1, "maximum": 50, "default": 10, "description": "How many streams, newest first."]]), annotations: readOnly) { arguments, _ in
            let limit = try integer(arguments, "limit", in: 1...50) ?? 10
            return .json(try DiagnosticsCLI.encode(Array(StreamStore.load().suffix(limit).reversed()).map(StreamReport.Exported.init)))
        },
        MCPTool(name: "check_stream_readiness", title: "Check before going live",
                description: "Before a live stream: whether the upload can carry OBS's bitrate with 30% headroom, whether the line is steady, and which apps are uploading now. The bitrate comes from `bitrate_kbps`, else OBS through the Kilobat app (or OBS directly when it has no password), else the last stream. With `measure` (default true) it runs an upload test of about eight seconds and at most 16 MB to Cloudflare, plus 20 pings to 1.1.1.1; on a metered network it does not measure and uses the last speed test on that network instead, unless `allow_metered` is true, which you pass only after the user agreed to use the data. Don't run it while the user is already live: the test competes with the stream. Returns `verdict` (ready, tight: covers the bitrate but not the headroom, short, unknown), `ready`, `upload` (Mbps) with `uploadSource` (test, history or none) and `uploadDate`, `bitrate` and `bitrateSource` (given, obs, lastStream), `neededMbps`, `suggestedKbps` (the highest bitrate the upload carries with headroom), `latency`, `jitter`, `lossPercent`, `unstable`, `metered`, `busy` apps, and the sentences `headline`, `summary` and `notes`. Same as `kilobat stream check --json`.",
                inputSchema: schema(["bitrate_kbps": ["type": "integer", "minimum": 100, "maximum": 100000, "description": "The stream's bitrate in kbps, video plus audio, when OBS isn't reachable."],
                                     "measure": ["type": "boolean", "default": true, "description": "Run the short upload test; false uses the last speed test."],
                                     "allow_metered": ["type": "boolean", "default": false, "description": "Measure on a metered network too. Only after the user agreed."]]),
                annotations: MCPToolAnnotations(readOnly: true, destructive: false, idempotent: false, openWorld: true)) { arguments, _ in
            let bitrate = try integer(arguments, "bitrate_kbps", in: 100...100_000)
            let measure = try boolean(arguments, "measure") ?? true, allowMetered = try boolean(arguments, "allow_metered") ?? false
            let check = await StreamCLI.readiness(bitrate: bitrate, measure: measure ? nil : false, allowMetered: allowMetered)
            return .json(try DiagnosticsCLI.encode(StreamReadiness.Exported(check)))
        },
        MCPTool(name: "get_cloud_gaming", title: "Cloud gaming sessions",
                description: "GeForce NOW, Xbox Cloud Gaming, Boosteroid, Amazon Luna and Shadow sessions as the Kilobat app measured them, read-only. Use it when someone asks why a cloud game stuttered, lagged or dropped to a blurry picture on this Mac, or how much data a session uses on a hotspot. `live` (null when nothing plays or the app isn't running; `appRunning` says which) is the session now: `service` (geforcenow, xbox, boosteroid, luna, shadow), `browser` (null for the Mac app), `minutes`, `pingMs`, `jitterMs`, `lossPercent` (over the last 30 s; `measured` is server when the stream's server answers ping, else internet), `mbps` (estimated from qualifying client traffic; other busy browser tabs can affect it), `gigabytes` so far, `gigabytesPerHour`, `metered`, and on a metered network `projectedGigabytes` for `projectedMinutes` (the usual session length here) and `budgetRunsOutMinutes`; `issues` are what is in the way now: `kind` airDrop, band24 (Wi-Fi on 2.4 GHz), weakSignal or app (with `app`, `uploading`, and `pausable` when Kilobat can hold it), each with `phrase` and `advice`. `holding` and `airDropPaused` say what the app paused. `reports` are the sessions after they ended, newest first and compact: `title`, `start`, `minutes`, `pingMs`, `jitterMs`, `lossPercent`, `averageMbps`, `lowMbps`, `gigabytes`, `gigabytesPerHour`, `metered`, `clean`, `verdict`, `advice`, `data` and `stutters`, each with `clock`, `seconds`, `peakMs`, `lowMbps`, `factors` (band24, weakSignal, airDrop, farNode, wifi, app, otherDevice, starlink, portal, beyondRouter: everything that held at the time, the Mac's conditions first) and `sentence` (such as: Stuttered at 21:14 for 40s: 2.4 GHz Wi-Fi while iCloud Photos uploaded). A stutter is two or more seconds of pings lost or 100 ms over the session's median, or three seconds or more of the stream's bitrate under 40% of its median. In a browser Kilobat names the service only from the hosts the browser talks to (its network filter's names or reverse DNS), so a browser session it couldn't name is missing, not clean. Kilobat never sees the game or the video. Same as `kilobat cloud-gaming --json` and `kilobat cloud-gaming reports --json`.",
                inputSchema: schema(["limit": ["type": "integer", "minimum": 1, "maximum": 50, "default": 5, "description": "How many past sessions, newest first."]]), annotations: readOnly) { arguments, _ in
            let limit = try integer(arguments, "limit", in: 1...50) ?? 5
            let app = await CloudGamingCLI.app()
            let reports = try JSONSerialization.jsonObject(with: DiagnosticsCLI.encode(Array(CloudGamingStore.load().suffix(limit).reversed()).map(CloudGamingReport.Exported.init)))
            return .json(try object(["appRunning": app != nil, "live": app?["live"] ?? NSNull(), "holding": app?["holding"] ?? [String](),
                                     "airDropPaused": app?["airDropPaused"] ?? false, "reports": reports]))
        },
        MCPTool(name: "get_household", title: "Paired Macs on the home network",
                description: "The Macs paired with this one in Kilobat › Settings › Household Macs, read-only, and what each is doing now as it reported it: `live` with `name`, `down` and `up` (bytes a second), `apps` (its three busiest apps by name), `call` (on a call) and `at`, plus `busy` (enough to freeze a call), `reachable` and `refused`. Also this Mac's `name`, `sharing`, `answering` (sharing on a network marked home), `home`, `pro` and `localNetwork` (macOS's Local Network permission). Live usage needs the Kilobat app running with Kilobat Pro; each Mac shares only if the person turned sharing on there. Use it when a call freezes because of another device on the network. It never pairs, unpairs or changes sharing: that happens only in the app, where both Macs show a code to compare. Same as `kilobat household --json`.",
                inputSchema: schema([:]), annotations: readOnly) { _, _ in
            .json(try DiagnosticsCLI.encode(await HouseholdCLI.report()))
        },
        MCPTool(name: "get_home_usage", title: "Every device's usage at home",
                description: "Each device's traffic counters on the home network, read-only, from the router the user connected in the Kilobat app (Devices › Connect your router; Kilobat Pro): FRITZ!Box over TR-064, UniFi Network, MikroTik RouterOS 7 or OpenWrt. The app signs in to the router with the password in its Keychain and only reads; this tool never signs in, connects or disconnects a router, and nothing is installed on the router. `state`: notConnected, notHome (the network isn't marked as home), needsPro, connecting, ok, needsAttention (the password or certificate needs the user) or error. `router`: `kind`, `name`, `address`, `uptimeSeconds`, and `measures`, which is perDevice when the router counts each device or wholeHome when it only counts the line: a FRITZ!Box never counts per device, UniFi does through its controller statistics, MikroTik once Kid Control has a profile or simple queues exist, OpenWrt with nlbwmon; `missing` says what to enable (rights, kidControl, nlbwmon, legacyAPI). `home`: the line's `down` and `up` now (bytes a second) and `todayDown`/`todayUp` (bytes). `devices`: each with `mac`, `name` (the user's name for it first), `address`, `active`, `down`/`up` now, `todayDown`/`todayUp`, `source` (router, thisMac or pairedMac: a Mac running Kilobat that reported itself, with its busiest `apps`). UniFi client counters and RouterOS queues can include LAN transfers; perDevice does not mean internet-only or WAN-qualified, and these numbers must not be used as camera internet-upload shares. `home` is only the WAN counters the router actually exposes, never a sum of client traffic. With wholeHome, `others` is the line minus what could be named; never attribute it to one device. `router.update` (or null) is the firmware as the router reports it: `product`, `installed`, `available`, `updateAvailable`, `url` (the router's own update screen) and `source` (router, or openwrt.org for OpenWrt's published release list); suggest the user updates there, and never start or claim an update yourself. `note` says what was measured. Use it when someone asks who is using the internet, which device is slowing the home down, or how much a device used today. Same as `kilobat router devices --json`.",
                inputSchema: schema([:]), annotations: readOnly) { _, _ in
            .json(try DiagnosticsCLI.encode(await RouterCLI.home()))
        },
        MCPTool(name: "check_smart_home", title: "Matter, Thread and HomeKit check",
                description: "Read-only smart-home check from Bonjour (about 4 seconds) and this Mac's own network state; it never sets up, pairs or controls a device. `headline` (e.g. \"Thread: one network (Home) with 3 border routers · Matter: 5 devices\"). `threadNetworks`: each Thread network seen through its border routers' _meshcop._udp advertisements, with `name`, `makers` (Apple, Google, Amazon, SmartThings, Home Assistant or the vendor), `borderRouters` (\"label · maker\"), `threadVersions` and `credentialSharing` (a border router supports Thread 1.4 credential sharing); more than one network means devices on one can't use the other's border routers. `idleBorderRouters` aren't on a network now. `matter`: `devices` (distinct, a device added to several apps counts once), `overThread`, `overWiFi`, `fabrics` (apps or hubs), `readyToSetUp` (devices advertising for commissioning). `homeKit`: `accessories`, `bridges`, `unpaired`, `overThread`, `categories`. `checks`: `ipv6`, `bonjour`, `isolation`, `subnet`, `wifi24`, each with `state` ok, warning, problem or unknown (Kilobat couldn't tell), `summary`, and for a failed check `fix` and `guide` (the router's guide on kilobat.app when the router is known; the page may not exist yet). `findings`: what to act on, with `fix` and `sources`. `localNetwork` denied means macOS's Local Network permission is off for the app running this server, so nothing could be seen. Same data as `kilobat smarthome --json`, without addresses and IDs.",
                annotations: readOnly) { _, _ in
            .json(try DiagnosticsCLI.encode(await SmartHomeCLI.report().compact))
        },
        MCPTool(name: "service_status", title: "Is it them or me?",
                description: "Is my own model provider down? Call this when you, an AI agent, keep getting errors, timeouts or overloaded responses from your provider while the rest of the network works: `service` claude-code (or claude-api) for Anthropic, codex or openai-api for OpenAI, copilot, cursor-cli, gemini-code-assist or vertex-ai for Google, mistral, groq, cohere, fireworks, together, huggingface, windsurf, zed or warp, or the API host you call, such as api.anthropic.com. Pages split by component are read per component, so a claude.ai outage doesn't count against the API or Claude Code. It also covers the public status pages of everyday services, read-only: Zoom, Slack, Microsoft Teams Free, Google Meet, Gmail, Google Drive and Docs, Discord, GitHub, GitLab, Cloudflare, Claude, ChatGPT, Cursor, Dropbox, iCloud, FaceTime, Notion, Figma, Linear, Jira, Confluence, Vercel, Netlify, npm, Docker, 1Password and more (`list` true names them all with their pages, without asking any). Pass `service` as a name (slack, google meet; claude or openai for all of that page's parts), a host or URL (github.com) or a bundle ID, several separated by commas; with none, the services of the apps running on this Mac. If the provider reports an outage, tell the user it's on the provider's side and wait or retry later rather than changing their network or settings. Each result has `service`, `state` (operational, maintenance, degraded, partialOutage, majorOutage, or unknown when the page couldn't be read), `incident` (the page's own title), `started`, `page` (the incident or status page to send the user to), `checked`, `problem`, `outage` and a `summary` sentence. Only report an outage the page states; when it's operational and the user's line is fine, say the status page reports no problems rather than guessing. Each named service's own host also gets one TLS connection from this Mac: `reachable` (true, false, or null when not checked) and `block`, null unless that connection fails and the block check finds that this network blocks it (`state` blocked, with `signals`, `evidence`, `summary`, `next`, `place`) or the service refuses this region (`state` regionUnavailable, `exitCountry`); then `summary` is the block's. The block check asks the user's trusted resolver (Cloudflare by default) one DNS-over-HTTPS question, only for a service that failed. Say a block as measured (\"Slack looks blocked on this network, not down\"), and suggest only another network, mobile data or roaming, or the network's operator; never suggest a VPN, proxy, other DNS or any way around it. Use it when one app or site fails while the rest of the internet works; diagnose_connection already includes it for a host it checks. Status-page requests carry nothing about the user; answers are cached for 3 minutes. Same JSON as `kilobat down --json`.",
                inputSchema: schema(["service": ["type": "string", "description": "A service name, host, URL or bundle ID; several separated by commas. Omit for the apps running now."],
                                     "list": ["type": "boolean", "description": "List the known services, their status pages and endpoints instead of checking any."]]),
                annotations: MCPToolAnnotations(readOnly: true, openWorld: true)) { arguments, _ in
            // An object, so clients get structured content: {"services": [...]}.
            func wrap(_ rows: Data) throws -> MCPToolOutput {
                .json(try JSONSerialization.data(withJSONObject: ["services": try JSONSerialization.jsonObject(with: rows)], options: [.sortedKeys, .withoutEscapingSlashes]))
            }
            if arguments["list"] as? Bool == true { return try wrap(try DownCLI.listJSON()) }
            let names = ((arguments["service"] as? String) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let services: [StatusService]
            do { services = try DownCLI.pick(names, all: false) } catch { throw MCPToolError(error.localizedDescription) }
            let statuses = await ServiceStatusChecker.shared.check(services)
            return try wrap(try DownCLI.statusJSON(statuses, reach: await DownCLI.reachability(services, statuses: statuses)))
        },
        MCPTool(name: "explain_connection", title: "What is this process or host?",
                description: "Explains a macOS process or an internet host from Kilobat's curated database, read-only and on this Mac (nothing is sent anywhere): what it is in plain words, how much traffic is normal, when it uses a lot, whether it is safe to block (`safeToBlock`: safe, caution or avoid) and exactly what breaks (`breaks`), the first way to reduce its use, the hosts a process uses or the processes a host serves, and the kilobat.app page with sources (`url`). Pass `process` as a name as Activity Monitor, nettop or get_status show it (nsurlsessiond, mDNSResponder, a 15-character cut-off name works), an executable path, a bundle ID or process:<name>; pass `host` as a hostname, URL or pattern (gateway.icloud.com, 1-courier.push.apple.com matches *.push.apple.com); pass both to explain one connection, and `address` to add the network that owns it and its country from Kilobat's bundled tables. Facts come only from Apple's documentation and the makers'; `known` false means the database doesn't cover it, and `facts` then lists only what Kilobat knows (path, signer, network, country) without guessing. Use it before suggesting a block: never tell the user to block or kill something whose `safeToBlock` is avoid, and quote `breaks`. Same JSON as `kilobat explain --json`.",
                inputSchema: schema(["process": ["type": "string", "description": "A process name, executable path, bundle ID or process:<name>."],
                                     "host": ["type": "string", "description": "A hostname or URL the process connects to."],
                                     "address": ["type": "string", "description": "The remote IP address, to add its network owner and country."]]),
                annotations: readOnly) { arguments, _ in
            for key in ["process", "host", "address"] where arguments[key] != nil && !(arguments[key] is NSNull) && !(arguments[key] is String) {
                throw MCPToolError("'\(key)' must be a string.")
            }
            let process = (arguments["process"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let host = (arguments["host"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let address = (arguments["address"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard process != nil || host != nil || address != nil else { throw MCPToolError("Pass process, host or both.") }
            guard Explainer.shared.available else { throw MCPToolError("Kilobat's explainer database isn't installed. It comes with the Kilobat app.") }
            var subject = ExplainCLI.subject(ExplainQuery(process: process, host: host))
            subject.address = address
            return .json(try object(ExplainCLI.row(Explainer.shared.explain(subject))))
        },
        MCPTool(name: "get_captive_portal", title: "Wi-Fi sign-in page (captive portal)",
                description: "Checks now whether a hotel, café, airport or coworking Wi-Fi's sign-in page (captive portal) is in the way, the standard way: an HTTP request to captive.apple.com, then Google's generate_204 if Apple's doesn't answer. Read-only; it never signs in or opens a browser. Returns `state` (open, portal or offline: neither check page answered), `status` for this network (none, signInNeeded, loggedOut: signed in earlier and the same sign-in page came back, so the internet isn't down; signedIn), `signInPage` (query values redacted) and `host`, `hintMinutes` (a length the page states), `network` and `place` (the This place name), `typicalMinutes` (how long sign-ins last here, the median of sign-ins the Kilobat app saw whole), `signedInSince`, `expectedEnd` and `minutesLeft` while signed in, `loggedOutSince`, and `networks`: each network that had a sign-in page with `sessions`, `measuredSessions`, `typicalMinutes`, `signedIn` and `lastSeen`. History is recorded by the app on this Mac only. Tell the user to sign in again (kilobat portal open) rather than restarting the router. Same as `kilobat portal --json`.",
                inputSchema: schema([:]), annotations: readOnly) { _, _ in
            .json(try await PortalCLI.json())
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
        MCPTool(name: "get_data_pack", title: "Data packs and when they run out",
                description: "Prepaid data packs such as a travel eSIM reached through a phone's hotspot or a travel router, read-only: each one's `name`, `sizeBytes`, `usedBytes`, `leftBytes`, `usedFraction`, `state` (upcoming, active, usedUp, expired or ended), `start`, `end`, `networks` (`keys` it counts by name, and `nameContains`), `perDayBytes` (the pace over `paceDays`, the last three days or since it started; `settling` true when that is under a day, so the pace counts as a day and may be low), `runsOut` and `daysEarly` when it runs out before it ends at that pace, `lastsWholePack`, `correction` (the carrier's figure, when the user set one), `alerts`, `holdUploads` and a `summary` line. `current` is the pack counting on the network the Mac is on now. Kilobat counts this Mac only (`limits`): when the phone or another device uses the same pack, less is left, so say so and suggest correcting it with the figure in the carrier's app; never present the forecast as the carrier's. Same JSON as `kilobat pack --json`.",
                annotations: readOnly) { _, _ in
            let store = TrafficStore(startMonitoring: false)
            do { return .json(try object(try PackCLI.perform(.status, store: store, app: await WiFiCLI.connection()))) }
            catch let error as CLIError { throw MCPToolError(error.message) }
        },
        MCPTool(name: "set_data_pack", title: "Add, correct or end a data pack",
                description: "Changes the user's data packs. `action` add: a pack of `gb` (0.01–10000) for `days` (1–400) or until `until` (YYYY-MM-DD, the last day it runs), from `start` (YYYY-MM-DD, now if omitted), named `name`, on `network`: a network name Kilobat has seen (list_networks) or text that the names of the networks to count contain, such as iPhone; the current network if omitted. A running pack on the same networks ends when it starts, and the networks it counts become metered. `action` correct: `left_gb`, what the carrier's app says is left. `action` end: ends it now; it stays in the history. `pack` names the pack for correct and end; the one on the current network if omitted. Returns the packs after the change, as get_data_pack does." + confirm,
                inputSchema: schema(["action": ["type": "string", "enum": ["add", "correct", "end"]],
                                     "gb": ["type": "number", "minimum": 0.01, "maximum": 10000],
                                     "days": ["type": "integer", "minimum": 1, "maximum": DataPack.maximumDays],
                                     "until": ["type": "string", "description": "The last day of the pack, as YYYY-MM-DD, instead of days."],
                                     "start": ["type": "string", "description": "When the pack started, as YYYY-MM-DD; now if omitted."],
                                     "network": ["type": "string", "description": "A network name or key from list_networks, or text the names contain."],
                                     "name": ["type": "string", "description": "What to call the pack, such as Japan eSIM."],
                                     "left_gb": ["type": "number", "minimum": 0, "maximum": 10000, "description": "For correct: GB left, as the carrier's app shows it."],
                                     "pack": ["type": "string", "description": "For correct and end: a pack's name or id from get_data_pack."]], required: ["action"]),
                annotations: change) { arguments, _ in
            let action = try string(arguments, "action")
            @MainActor func number(_ key: String) throws -> Double? {
                guard let raw = arguments[key], !(raw is NSNull) else { return nil }
                guard let value = raw as? NSNumber, !isBoolean(value), value.doubleValue.isFinite else { throw MCPToolError("\(key) must be a number.") }
                return value.doubleValue
            }
            var args = [action]
            switch action {
            case "add":
                guard let gb = try number("gb") else { throw MCPToolError("Pass gb, the pack's size.") }
                let days = try integer(arguments, "days", in: 1...DataPack.maximumDays), until = arguments["until"] as? String
                guard (days == nil) != (until == nil) else { throw MCPToolError("Pass days or until, not both.") }
                args += [String(gb), days.map(String.init) ?? until ?? ""]
                for (key, flag) in [("network", "--network"), ("name", "--name"), ("start", "--start")] {
                    if let value = arguments[key] as? String { args += [flag, value] }
                }
            case "correct":
                guard let left = try number("left_gb") else { throw MCPToolError("Pass left_gb, what the carrier's app says is left.") }
                args.append(String(left))
                if let pack = arguments["pack"] as? String { args += ["--pack", pack] }
            case "end":
                if let pack = arguments["pack"] as? String { args += ["--pack", pack] }
            default: throw MCPToolError("action takes add, correct or end.")
            }
            let command: PackCommand
            do { command = try PackCommand.parse(args).command } catch let error as DataPackError { throw MCPToolError(error.message) }
            let store = TrafficStore(startMonitoring: false)
            do { return .json(try object(try PackCLI.perform(command, store: store, app: await WiFiCLI.connection()))) }
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
        MCPTool(name: "set_kill_switch", title: "VPN kill switch",
                description: "Turns Kilobat's VPN kill switch `on` or `off` (Kilobat Pro, with the app's network filter on). While on, it arms the first time the VPN carries all traffic, and from then until the Mac restarts the filter refuses new connections whenever the VPN is down, except the VPN app and its helpers, Apple's networking services, the captive-portal login, Kilobat and, unless the user turned it off, the local network. Turning it off lets every app connect without the VPN, which can expose the user's traffic on the network they are on: never turn it off to make your own requests work; ask the user to reconnect the VPN. `lan` sets whether the local network stays reachable while it blocks. Returns `enabled`, `allowLAN`, `state` and `summary` as in check_vpn." + confirm,
                inputSchema: schema(["state": ["type": "string", "enum": ["on", "off"]],
                                     "lan": ["type": "boolean", "description": "Keep the local network reachable while the kill switch blocks."]], required: ["state"]),
                annotations: change) { arguments, _ in
            let value = try string(arguments, "state")
            guard ["on", "off"].contains(value) else { throw MCPToolError("state takes on or off.") }
            let store = TrafficStore(startMonitoring: false), on = value == "on"
            store.preferences.killSwitch = on ? true : nil
            if !on { store.preferences.killSwitchAllowedUntil = nil }
            if let lan = try boolean(arguments, "lan") { store.preferences.killSwitchLAN = lan ? nil : false }
            // The app reads the setting within a second; its answer after that says whether it armed.
            if AppRelay.appRunning { try? await Task.sleep(for: .milliseconds(1500)) }
            return .json(try object(ProxyCLI.killSwitch(await WiFiCLI.connection())))
        },
        MCPTool(name: "hold_upload", title: "Send an upload later",
                description: "Holds one app's upload until a better network (`action` hold), or lets a held one go now (`action` resume). Pass `app` from get_uploads (`app`, a bundle ID or the name). `until`: unmetered, fast (a network whose speed test measured 20 Mbps up or more, or one the user marked as fast), fast:<Mbps>, a time from 1m to 8h such as 2h, or manual; leave it out for unmetered on a metered network and fast otherwise. Sync and backup apps such as Dropbox and Google Drive are suspended and resume where they stopped; other apps only have new connections refused while the network filter is on. Browsers, macOS services, command-line tools such as git, and the app in front are never held. A hold always ends when its condition is met, after 8 hours, or when Kilobat quits. Needs the Kilobat app running and Kilobat Pro. Returns `held` or `resumed`, with `error` when it couldn't, and the `report` after the change. It pauses another app: say which app and until when, and get the user's explicit confirmation before calling.",
                inputSchema: schema(["app": ["type": "string", "description": "The upload's `app` from get_uploads, a bundle ID or an app name."],
                                     "action": ["type": "string", "enum": ["hold", "resume"], "default": "hold"],
                                     "until": ["type": "string", "description": "unmetered, fast, fast:<Mbps>, a duration such as 2h or 90m, or manual."]], required: ["app"]),
                annotations: change) { arguments, _ in
            let app = try string(arguments, "app")
            do {
                if arguments["action"] as? String == "resume" { return .json(try object(try await UploadsCLI.change(resume: app))) }
                let until = arguments["until"] as? String
                do { _ = try UploadCondition.parse(until) } catch { throw CLIError(error.localizedDescription) }
                return .json(try object(try await UploadsCLI.change(hold: app, until: until)))
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
                description: "Connections the Kilobat filter blocked in the last `days` (1 by default, up to 7), newest first: `date`, `app`, `endpoint`, `direction` and `reason` (app rule, blocklist entry, connection rule, budget, default deny, a block when asked, or Protection). Protection's blocks also carry `protection`: `kind` (malware, phishing, scam, threat, tracker, agentGuard), `list` (the list, or the agent-guard rule such as paste site or raw IP address), `host`, and `agent`, `agentPID` and `process` when an AI agent's process tree made the connection. Metadata only. Same data as `kilobat blocked-history`.",
                inputSchema: schema(["days": ["type": "integer", "minimum": 1, "maximum": 7, "default": 1]]),
                annotations: readOnly) { arguments, _ in
            let since = Date().addingTimeInterval(-Double(try integer(arguments, "days", in: 1...7) ?? 1) * 86_400)
            return .json(try FirewallCLI.encode(FilterEventJournal().events.filter { $0.date >= since }))
        },
        MCPTool(name: "explain_verdict", title: "Why Kilobat allows or blocks a connection",
                description: "Every Kilobat rule that matches a connection, in the order the filter checks them, and the one that decides: the VPN kill switch, Protection's threats and the agent guard, Unrestricted, destination rules (newest first), the blocklist, trackers, then the app's timed rule (the user's, or one Send later, call mode or going live set), the data budget, its quota, paused updaters, its rule in the current profile, an answer given when asked, and the profile's default. Pass `host` (a name, address or URL) and `app` (a bundle ID or process:<name>), either alone or both, with optional `port` and `direction`; or `blocked` (1–50) to explain the latest blocked attempts from the filter's own record instead. Returns `verdict` (allow, block or ask), `summary` (\"Blocked by Protection: login.example is on the phishing list (…)\"), `rules` (`rule`, `verdict`, `role` decided, alsoMatched or note, `source`, `text`, `line`, and `change` with `place`, `label` and the CLI `command` that changes it), `recorded` (true when the filter recorded it as it blocked; false for the rules as they are now), `enforced` (whether the filter runs; null without the app), `note` and the compact `trace`. An also-matched rule applied too but came later: changing the deciding rule can let it decide. Read-only and local. Changing a rule is the user's call: name the rule and its `change`, and use the change tools only with their yes. Same JSON as `kilobat verdict --json`.",
                inputSchema: schema(["host": ["type": "string", "description": "A host such as api.example.com, an IP address, or a URL."],
                                     "app": ["type": "string", "description": "Bundle ID such as com.tinyspeck.slackmacgap, or process:<name>."],
                                     "port": ["type": "integer", "minimum": 1, "maximum": 65535],
                                     "direction": ["type": "string", "enum": ["outgoing", "incoming"], "default": "outgoing"],
                                     "blocked": ["type": "integer", "minimum": 1, "maximum": 50, "description": "Explain this many of the latest blocked attempts instead."]]),
                annotations: readOnly) { arguments, _ in
            if let count = try integer(arguments, "blocked", in: 1...50) {
                return .json(try FirewallCLI.encode(await VerdictCLI.blocked(count)))
            }
            var args = ["verdict"]
            if let host = arguments["host"] as? String, !host.isEmpty { args.append(host) }
            if let app = arguments["app"] as? String, !app.isEmpty { args += ["--app", app] }
            if let port = try integer(arguments, "port", in: 1...65_535) { args += ["--port", String(port)] }
            if (arguments["direction"] as? String) == "incoming" { args.append("--incoming") }
            let options: VerdictCLI.Options
            do { options = try VerdictCLI.parse(args) } catch let error as CLIError { throw MCPToolError(error.message) }
            return .json(try FirewallCLI.encode(await VerdictCLI.inspect(host: options.host, app: options.app, port: options.port, direction: options.direction)))
        },
        MCPTool(name: "clear_history", title: "Clear history or forget a site",
                description: "Deletes entries from Kilobat's histories that name hosts: Blocked attempts, the agent network log, the destinations of agent runs and awake sessions, and Protection's memory of which notifications went out. `action` forget removes one `host` (a host name, IP address or URL; with `subdomains` also www. and every other subdomain) from all of them; clear removes everything from the last `range`: hour, today or all. Returns `removed` per history and `total`. It can't be undone. Never call it to hide what an agent did; only when the user asked to forget a site or clear history." + confirm,
                inputSchema: schema(["action": ["type": "string", "enum": ["forget", "clear"]],
                                     "host": ["type": "string", "description": "For forget: the site, such as example.com."],
                                     "subdomains": ["type": "boolean", "default": false, "description": "For forget: every subdomain too."],
                                     "range": ["type": "string", "enum": ["hour", "today", "all"], "description": "For clear: the last hour, today or everything."]], required: ["action"]),
                annotations: change) { arguments, _ in
            var options = [try string(arguments, "action")]
            switch options[0] {
            case "forget":
                guard let host = arguments["host"] as? String, !host.isEmpty else { throw MCPToolError("forget needs `host`.") }
                options.append(host)
                if try boolean(arguments, "subdomains") == true { options.append("--subdomains") }
            case "clear":
                guard let range = arguments["range"] as? String else { throw MCPToolError("clear needs `range`: hour, today or all.") }
                options.append("--" + range)
            default: throw MCPToolError("`action` is forget or clear.")
            }
            let command: HistoryCommand
            do { command = try HistoryCommand.parse(options) } catch let failure as HistoryCommand.Failure { throw MCPToolError(failure.message) }
            do { return .json(try DiagnosticsCLI.encode(try await HistoryCLI.perform(command))) } catch let error as CLIError { throw MCPToolError(error.message) }
        },
        MCPTool(name: "check_host_reputation", title: "Is a host known to be malicious?",
                description: "Whether `host` (a host name, IP address or URL) is on one of the lists Kilobat's Protection downloaded to this Mac: known malware, phishing and scam destinations (HaGeZi Threat Intelligence Feeds, URLhaus, HaGeZi Fake) and, when the user turned it on, a tracker list. Returns `listed`, `entry` (the listed name: the host or the parent domain that covers it), `lists` (`list`, `id`, `category`, `licence`), `category`, `allowedByYou`, `localNetwork`, `wouldBlock` (whether Kilobat blocks it for every app now), `indexBuilt` and a plain `note`. Read-only and local: nothing about the host leaves the Mac. Lists cover known destinations only, so not listed doesn't mean safe. Use it before fetching from, installing from or sending data to an unfamiliar host. Same JSON as `kilobat protect check <host> --json`.",
                inputSchema: schema(["host": ["type": "string", "description": "A host such as downloads.example.com, an IP address, or a URL."]], required: ["host"]),
                annotations: readOnly) { arguments, _ in
            do { return .json(try ProtectCLI.encode(try await ProtectCLI.check(try string(arguments, "host"), store: TrafficStore(startMonitoring: false)))) }
            catch let error as CLIError { throw MCPToolError(error.message) }
        },
        MCPTool(name: "get_protection_status", title: "Protection status",
                description: "Kilobat's Protection: whether `threats` (known malware, phishing and scam hosts, Pro), `trackers` (tracker and ad hosts in apps, off by default) and `agentGuard` (stricter rules for AI agents and the commands they start, Pro) are on, `threatEntries` and `trackerEntries`, when the lists were `updated`, each list's `name`, `licence`, `entries`, `updated` and `error` (a failed update keeps the last good copy), `allowedSites`, `uploadLimitMB`, `pro` and `filterActive` (nil when the app isn't running). Protection is enforced by the Kilobat app's network filter. Same JSON as `kilobat protect status --json`.",
                annotations: readOnly) { _, _ in
            .json(try ProtectCLI.encode(await ProtectCLI.status(TrafficStore(startMonitoring: false))))
        },
        MCPTool(name: "set_protection", title: "Change Protection",
                description: "Turns Kilobat's Protection parts on or off, chooses the tracker list, or allows a site. `threats` on/off (known malware, phishing and scam hosts), `trackers` on/off with optional `tracker_list`, `agent_guard` on/off (agents and their commands also kept from paste sites, file shares, tunnels, raw IP addresses and large uploads to new hosts), `allow_site` or `unallow_site` (a host whose subdomains are covered too). Never call this to turn Protection off or allow a site so that your own blocked request gets through: tell the user what was blocked and let them decide." + confirm,
                inputSchema: schema(["threats": ["type": "string", "enum": ["on", "off"]], "trackers": ["type": "string", "enum": ["on", "off"]],
                                     "agent_guard": ["type": "string", "enum": ["on", "off"]],
                                     "tracker_list": ["type": "string", "enum": ProtectionLists.trackers.map(\.id)],
                                     "allow_site": ["type": "string"], "unallow_site": ["type": "string"]]),
                annotations: change) { arguments, _ in
            let store = TrafficStore(startMonitoring: false)
            var commands: [ProtectCommand] = []
            for (key, part) in [("threats", ProtectCommand.Part.threats), ("trackers", .trackers), ("agent_guard", .agents)] {
                if let value = arguments[key] as? String { commands.append(.set(on: value == "on", parts: [part], trackerList: part == .trackers && value == "on" ? arguments["tracker_list"] as? String : nil)) }
            }
            if arguments["trackers"] == nil, let list = arguments["tracker_list"] as? String { commands.append(.set(on: true, parts: [.trackers], trackerList: list)) }
            if let site = arguments["allow_site"] as? String {
                guard ProtectionPreferences.allow(site, in: &store.preferences) != nil else { throw MCPToolError("allow_site must be a host such as example.com.") }
            }
            if let site = arguments["unallow_site"] as? String { _ = ProtectionPreferences.unallow(site, in: &store.preferences) }
            guard !commands.isEmpty || arguments["allow_site"] != nil || arguments["unallow_site"] != nil else { throw MCPToolError("Pass threats, trackers, agent_guard, tracker_list, allow_site or unallow_site.") }
            for command in commands { command.apply(to: &store.preferences) }
            return .json(try ProtectCLI.encode(await ProtectCLI.status(store)))
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
                description: "Pings each data center of a game 5 times and returns them fastest first, with the `best` one for this Mac. `game` is a game id or name: cs2, dota2, deadlock and tf2 (Valve's relay in each data center), fortnite (Epic's ping server per subregion), apex, dbd and marathon (Amazon GameLift's ping beacon in each AWS region the game uses), r6, aoe2, aoe3, aoe4 and aom (PlayFab's beacon in each Azure region the game uses), brawlhalla and hunt (the maker's published test hosts). Each region has `pingMs` (median), `jitterMs`, `lossPercent`, `method` (udp, icmp, or tcp), `host` and, for cloud regions, `cloud` (such as AWS eu-central-1). This is ping to the region's data center, not to a match server. `overlayTarget` (such as cs2:fra) is what `kilobat overlay --target` takes to show that ping on stream. Without `game`, returns the list of games (`games`, `notMeasured` with the reason each is missing) without pinging. `game: match` finds the game being played (the app in front, or any running game), its busiest UDP connection, and pings that server: `state` (found, noGame, noServer, hidden when the game's socket names no address), `server` (`address`, `port`, `country`, `knownDataCenter`), `answersPing` (false means the server ignores ping, which is not loss) and `pingMs`. Games in `notMeasured` (Valorant, League of Legends, Overwatch 2, Call of Duty and others) return an error with the reason; use `game: match` while the user plays them. Takes about 5 seconds per game and sends pings only. Same JSON as `kilobat games --json`.",
                inputSchema: schema(["game": ["type": "string", "description": "A game id or name (cs2, fortnite, apex, r6, aoe2…), or match for the server of the match being played. Leave out to list the games."]]),
                annotations: MCPToolAnnotations(readOnly: true, openWorld: true)) { arguments, _ in
            guard let name = (arguments["game"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { return .json(try object(GamesCLI.listJSON())) }
            if name.lowercased() == CurrentMatch.overlayTarget { return .json(try object(GamesCLI.matchJSON(await CurrentMatch.check()))) }
            let game: GameServerTable.Game
            do { game = try GamesCLI.game(name) } catch let error as CLIError { throw MCPToolError(error.message) }
            return .json(try object(GamesCLI.reportJSON(await GamePing.run(game))))
        },
        MCPTool(name: "get_nearby_radios", title: "AirDrop and Bluetooth",
                description: "The radios that share this Mac's Wi-Fi chip or band: `awdl` (whether the AirDrop link is up and active and which features use it: AirDrop, Universal Control, Sidecar, iPhone Mirroring, Continuity), AirDrop `visibility` (everyone, contacts, off), Bluetooth `devices` (`name`, `kind`, `connected`, `sharesBand`), the Wi-Fi band and coexistence `advice` when Bluetooth audio or input devices share 2.4 GHz with Wi-Fi.",
                annotations: readOnly) { _, _ in
            let awdl = await NearbyRadios.awdlStatus(), devices = await NearbyCLI.bluetoothDevices(), band = await DiagnosticProbe().radio().band
            return .json(try object(["awdl": NearbyCLI.awdlJSON(awdl), "visibility": NearbyRadios.airDropVisibility()?.key as Any? ?? NSNull(), "wifiBand": band as Any? ?? NSNull(),
                                     "devices": devices.map { ["name": $0.name, "kind": $0.kind.rawValue, "connected": $0.connected, "sharesBand": NearbyRadios.sharesBand($0, wifiBand: band)] },
                                     "advice": NearbyRadios.coexistence(wifiBand: band, devices: devices) as Any? ?? NSNull()] as [String: Any]))
        },
        MCPTool(name: "get_bluetooth_audio", title: "Bluetooth audio: why headphones crackle",
                description: "While AirPods or other Bluetooth headphones or speakers play on this Mac, what on the Wi-Fi side can make them crackle or cut out, read-only. `output` is the sound output when it is Bluetooth (`name`, `transport` classic or le, `playing`, `microphone` true when its microphone records too, which puts it in lower-quality hands-free mode, `sampleRate`), null otherwise. `risks`, in the order to fix them: wifi24GHz (the Mac's Wi-Fi shares 2.4 GHz with Bluetooth), crowdedChannel, airDrop (AirDrop's link, AWDL, busy: AirDrop, Universal Control, Sidecar), heavyTraffic (2.5 MB/s or more on Wi-Fi), weakBluetooth (-72 dBm or weaker), busyBluetooth (4 or more other Bluetooth devices connected). `advice` lists what to change, each with `text` and `action` (joinFasterBand: the Kilobat app can join a remembered 5 GHz network, named in `conditions.fasterBand`; pauseAirDrop: `kilobat low-latency on --for 1h`, which asks for an administrator password). `conditions` has the measurements; `score`, `level` (clear, some, high) and `notifyWorthy` (two or more risks at once); `crackleReports` are times the user told the app it crackled, with the risks then. Kilobat can't hear the audio: macOS doesn't expose Bluetooth dropouts to other apps, so say the advice comes from conditions, as `basis` does. `source` is app when the running app answered (it adds the Bluetooth signal and the busiest app), cli when measured here. Same as `kilobat bluetooth audio --json`.",
                annotations: readOnly) { _, _ in
            .json(try DiagnosticsCLI.encode(await NearbyCLI.audioSummary()))
        },
        MCPTool(name: "check_local_network", title: "Can I cast or print here?",
                description: "Whether devices on this network can see each other, for Chromecast, AirPlay and AirPrint, read-only; about 3–8 seconds. `verdict`: works (a TV, speaker or printer advertised itself; `devices` lists `name`, `kind` cast, airPlay or printer, `model`), isolated (proxy ARP suggests possible client isolation; it also supports ordinary routing, so it is not proof of blockage; `evidence` proxyARP), noneSeen (nothing to cast to, and no proof either way: say so, don't call it isolation), noAccess (macOS Local Network access is off for Kilobat), offline. `headline`, `detail` and `advice` are the sentences to relay. `peers` has the raw signals (`neighbours`, `answered`/`pinged`, `routerAliases`, `swept`, `subnetHosts`, `bonjourDevices`). `setupNetwork` is set when the Mac is on a device's own Wi-Fi (a printer's Wi-Fi Direct, a camera's, a drone's, a smart plug's setup network: `kind`, `maker`, `previous` Wi-Fi to go back to), where no internet is expected: don't treat that as an outage. `casting` is set while the Mac AirPlays or may be casting a browser tab; its `basis` explains that TV signal and dropped frames are not observable: `risks` (wifi24GHz, weakSignal, airDrop, heavyTraffic) and `advice` with `action` (pauseAirDrop: `kilobat low-latency on --for 1h`, which asks for an administrator password; pauseBackground and joinFasterBand: buttons in the Kilobat app). Pass `quick` to skip the peer sweep and peer pings. The standalone fallback still runs standard internet and captive-portal checks for device-setup classification. Same as `kilobat local check --json`.",
                inputSchema: schema(["quick": ["type": "boolean", "description": "Bonjour and the neighbour cache only, without the sweep and pings."]]),
                annotations: readOnly) { arguments, _ in
            .json(try DiagnosticsCLI.encode(await LocalCLI.summary(quick: arguments["quick"] as? Bool ?? false)))
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
