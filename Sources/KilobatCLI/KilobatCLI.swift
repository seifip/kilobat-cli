import Foundation
import Darwin
import KilobatCore

@main
struct KilobatCLI {
    @MainActor static func main() async {
        // English whatever the Mac's language: scripts and agents parse what the CLI and MCP server print from KilobatCore.
        let defaults = UserDefaults.standard
        defaults.setVolatileDomain(defaults.volatileDomain(forName: UserDefaults.argumentDomain).merging(["AppleLanguages": ["en"]]) { $1 }, forName: UserDefaults.argumentDomain)
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch {
            FileHandle.standardError.write(Data("kilobat: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor static func run(_ arguments: [String]) async throws {
        var args = arguments
        let command = args.first ?? (Terminal.interactive ? "menu" : "status")
        // Flags after `--` belong to the command `awake` runs.
        if args.count >= 2, args.first == "help" || args.prefix(while: { $0 != "--" }).dropFirst().contains(where: { ["--help", "-h"].contains($0) }) {
            print(try commandHelp(args.first == "help" ? args[1] : command)); return
        }
        // Like `mo status | jq`: piped output switches to JSON so scripts never parse the human layout.
        if Terminal.piped, ["status", "watch", "bandwidth", "access-policy", "approvals", "diagnose", "scan", "radar", "speedtest", "rules", "destinations", "devices", "interfaces", "http-check", "wifi", "channels", "networks", "health-history", "settings", "sessions", "why", "conditions", "stutter", "airdrop", "bluetooth", "updaters", "ip", "speed-compare", "lan-test", "plan"].contains(command), !args.contains("--json") {
            if args.isEmpty { args = [command] }
            args.append("--json")
        }
        // A piped report gets the compact JSON summary unless a format was chosen; raw samples can run to megabytes.
        if Terminal.piped, command == "report", !args.contains("--json"), !args.contains("--csv") { args += args.dropFirst().first == "compare" ? ["--json"] : ["--summary", "--json"] }
        switch command {
        case "blocklist", "domain-exception", "remember-network", "scope": try await PolicyCLI.run(args)
        case "bandwidth", "access-policy", "block-host", "unblock-host", "approvals", "approve", "deny": try await FirewallCLI.run(args)
        case "remove-connection-rule", "blocked-history", "http-check", "router-counters", "connection-rule", "connection-rules", "signature", "discover", "bonjour", "capture", "wake", "destinations", "devices", "interfaces", "trace", "dns-benchmark", "dns-profile", "lan-test", "outages", "speed-history", "spots", "scan-history", "route-history", "ip", "speed-compare": try await ExpertCLI.run(args)
        case "diagnose", "scan", "radar", "speedtest", "dns": try await DiagnosticsCLI.run(args)
        case "awake", "sessions", "why", "conditions": try await AwakeCLI.run(args)
        case "limit", "quota": try await QuotaCLI.run(args)
        case "updaters": try await UpdatersCLI.run(args)
        case "agent-event": await AgentCLI.run(args)
        case "overlay": try await OverlayCLI.run(args)
        case "proxy", "vpn": try await ProxyCLI.run(args)
        case "calls": try CallsCLI.run(args)
        case "plan": try PlanCLI.run(args)
        case "wifi", "channels", "networks", "health-history", "support-report", "settings", "low-latency", "quit": try await WiFiCLI.run(args)
        case "stutter", "airdrop", "bluetooth": try await NearbyCLI.run(args)
        case "--help", "-h", "help": print(help)
        case "completion":
            guard args.count <= 2 else { throw CLIError("Use completion [zsh|bash|fish].") }
            let shell = args.count == 2 ? args[1] : URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "zsh").lastPathComponent
            print(try completionScript(shell))
            if isatty(STDOUT_FILENO) == 1 {
                let setup = ["zsh": "echo 'source <(kilobat completion zsh)' >> ~/.zshrc", "bash": "echo 'source <(kilobat completion bash)' >> ~/.bashrc", "fish": "kilobat completion fish > ~/.config/fish/completions/kilobat.fish"][shell] ?? ""
                FileHandle.standardError.write(Data("\n# Enable it with:\n#   \(setup)\n".utf8))
            }
        case "update":
            try allow(args, [])
            let path = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
            guard path.contains("/Cellar/") else {
                print("This copy was not installed with Homebrew.")
                print("Download the latest CLI from https://kilobat.app, or install with: brew install seifip/kilobat/kilobat")
                return
            }
            let brew = Process(); brew.executableURL = URL(fileURLWithPath: "/usr/bin/env"); brew.arguments = ["brew", "upgrade", "kilobat"]
            try brew.run(); brew.waitUntilExit()
            if brew.terminationStatus != 0 { throw CLIError("brew upgrade kilobat failed.") }
        case "--version", "version": try allow(args, []); print("Kilobat \(version)")
        case "mcp":
            guard args.count == 1 else { throw CLIError("Use mcp with no arguments. It speaks the Model Context Protocol on stdin/stdout.") }
            await MCPCLI.serve()
        case "menu": try allow(args, []); await menu()
        case "status", "watch":
            let valid = Set(["--watch", "--json"])
            guard args.dropFirst().allSatisfy({ valid.contains($0) }) else { throw CLIError("Use status [--watch] [--json].") }
            try await status(watch: command == "watch" || args.contains("--watch"), json: args.contains("--json"))
        case "profile":
            let store = TrafficStore(startMonitoring: false)
            guard args.count <= 2 else { throw CLIError("Use profile [travel|work|unrestricted].") }
            if args.count == 1 {
                for profile in NetworkProfile.allCases {
                    print("\(store.preferences.profile == profile ? "●" : "○") \(profile.rawValue.lowercased())  \(profile.subtitle)")
                }
            } else {
                let profile = try selectProfile(args[1], in: store)
                print("✓ \(profile.rawValue) profile selected. UI updates on the next sample.")
                print("  Rules are saved; enforcement requires the open app and its active signed filter.")
            }
        case "allow", "block", "reset":
            let options = try ruleOptions(args, command: command)
            guard let id = options.id else { throw CLIError("Use \(command) <bundle-id|process:name> [--profile name]\(command == "reset" ? "" : " [--minutes 1…1440]").") }
            let store = TrafficStore(startMonitoring: false)
            let profile = options.profile ?? store.preferences.profile
            if command == "reset" {
                guard options.minutes == nil else { throw CLIError("reset takes no --minutes.") }
                print(store.removeRule(id, in: profile)
                    ? "✓ Removed the rule for \(id) in \(profile.rawValue). It now follows the default: \(store.preferences.defaultAllow ? "allow" : "block")."
                    : "No rule for \(id) in \(profile.rawValue).")
                return
            }
            try saveAppRule(id, allowed: command == "allow", minutes: options.minutes, profile: profile, in: store)
            print("✓ Saved \(command) rule for \(id) in \(profile.rawValue)\(options.minutes.map { " for \($0) minutes" } ?? "").")
            print("  Enforcement requires the open app and its active signed filter.")
        case "rules":
            let options = try ruleOptions(args, command: command)
            guard options.id == nil, options.minutes == nil else { throw CLIError("Use rules [--profile name] [--json].") }
            let store = TrafficStore(startMonitoring: false)
            let profile = options.profile ?? store.preferences.profile
            if args.contains("--json") { print(String(decoding: try rulesJSON(store, profile: profile, app: await WiFiCLI.connection()), as: UTF8.self)); return }
            print("\(profile.rawValue)\(profile == store.preferences.profile ? " (active)" : "") · saved access rules")
            if profile == .unrestricted { print("Unrestricted allows every app; its rules apply only after switching to Travel or Work."); return }
            let rules = store.preferences.rules[profile.rawValue] ?? [:]
            print("Apps without a rule: \(store.preferences.defaultAllow ? "allow" : "block")")
            for (id, allowed) in rules.sorted(by: { $0.key < $1.key }) { print("\(allowed ? "allow" : "block")  \(id)") }
            for (key, rule) in (store.preferences.temporaryRules ?? [:]).filter({ $0.key.hasPrefix(profile.rawValue + "|") && $0.value.expires > Date() }).sorted(by: { $0.key < $1.key }) {
                print("\(rule.allowed ? "allow" : "block")  \(key.dropFirst(profile.rawValue.count + 1)) · until \(rule.expires.formatted(date: .omitted, time: .shortened))")
            }
            print("Saved rules · check the app for live filter status")
        case "report":
            if args.dropFirst().first == "compare" { try ReportCLI.compare(args); return }
            var days = 30, index = 1
            while index < args.count {
                if ["--json", "--csv", "--summary"].contains(args[index]) { index += 1; continue }
                guard args[index] == "--days", index + 1 < args.count, let value = Int(args[index + 1]), (1...365).contains(value) else { throw CLIError("Use report [--json|--csv] [--summary] [--days 1…365].") }
                days = value; index += 2
            }
            let store = TrafficStore(startMonitoring: false)
            let since = Calendar.current.date(byAdding: .day, value: 1 - days, to: Calendar.current.startOfDay(for: Date())) ?? .distantPast
            let usage = store.usage.filter { $0.date >= since }
            if args.contains("--summary") {
                let summary = UsageSummary(store.usage, days: days)
                if args.contains("--json") { print(String(decoding: try DiagnosticsCLI.encode(summary), as: UTF8.self)); return }
                print("Kilobat · last \(days) days · Internet ↓ \(TrafficFormat.bytes(summary.downloadBytes))  ↑ \(TrafficFormat.bytes(summary.uploadBytes))")
                for app in summary.topApps { print("  \(pad(app.name, 30))\(TrafficFormat.bytes(app.bytes))") }
                if summary.localBytes > 0 { print("  Local network: \(TrafficFormat.bytes(summary.localBytes)), not counted") }
                if summary.localBytes > 0 { print("Local network and AirDrop: \(TrafficFormat.bytes(summary.localBytes)), not counted above") }
                return
            }
            if args.contains("--json") {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
                print(String(decoding: try encoder.encode(usage), as: UTF8.self))
            } else if args.contains("--csv") {
                // One row per app per sample, so a spreadsheet can pivot by app; the totals row has an empty app.
                print("timestamp,app,download_bytes,upload_bytes,bytes")
                for entry in usage {
                    let time = ISO8601DateFormatter().string(from: entry.date)
                    print("\(time),,\(entry.received),\(entry.sent),\(entry.total)")
                    for (app, bytes) in entry.apps.sorted(by: { $0.key < $1.key }) where bytes > 0 { print("\(time),\(csv(app)),,,\(bytes)") }
                }
            } else {
                print("Kilobat · last \(days) days (recorded while the app is running)")
                print("↓ \(TrafficFormat.bytes(usage.reduce(0) { $0 + $1.received }))  ↑ \(TrafficFormat.bytes(usage.reduce(0) { $0 + $1.sent }))")
                print("\(usage.count) samples · data stays on this Mac · --summary for top apps")
            }
        case "open":
            try allow(args, [])
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            let candidates = [URL(fileURLWithPath: "/Applications/Kilobat.app"), executable.deletingLastPathComponent().appendingPathComponent("Kilobat.app"), executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("dist/Kilobat.app")]
            guard let app = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw CLIError("App bundle not found. Run script/build_and_run.sh first.") }
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open"); process.arguments = [app.path]; try process.run(); process.waitUntilExit()
            if process.terminationStatus != 0 { throw CLIError("Could not open the app.") }
        case "doctor":
            try allow(args, [])
            print("✓ macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
            print("\(FileManager.default.isExecutableFile(atPath: "/usr/bin/nettop") ? "✓" : "✕") Apple nettop traffic monitoring")
            print("✓ Shared local preferences and usage history")
            guard let app = await WiFiCLI.connection() else {
                print("○ The Kilobat app is not running. History, Wi-Fi names and blocking need it: kilobat open")
                return
            }
            print("✓ Kilobat app running\((app["ssid"] as? String).map { " · on \($0)" } ?? "")")
            switch app["filteringActive"] as? Bool {
            case true?: print("✓ Network filter active: rules and budgets are enforced")
            case false?: print("○ Network filter off: rules are saved but not enforced. Turn it on in Kilobat › Profiles.")
            default: print("○ Filter status unavailable")
            }
            print((app["pro"] as? Bool) == true ? "✓ Kilobat Pro" : "○ Kilobat Free: blocking, budgets and history need Pro in the app")
        default: throw CLIError("Unknown command '\(command)'. Run kilobat --help.")
        }
    }

    static let version = "0.12.0"

    /// Rejects arguments a command doesn't know instead of silently ignoring them. `valued` flags take the next argument.
    static func allow(_ args: [String], _ flags: Set<String>, valued: Set<String> = []) throws {
        var index = 1
        while index < args.count {
            guard flags.contains(args[index]) else { throw CLIError("Unexpected '\(args[index])'. Run kilobat \(args[0]) --help.") }
            index += valued.contains(args[index]) ? 2 : 1
        }
    }

    /// Starts monitoring and waits up to 8 s for the first per-app sample.
    @MainActor static func sampledStore() async -> TrafficStore {
        // Traffic to a local proxy is the app's, and the proxy core's own is not counted twice.
        ProxyRouting.shared.update(await ProxyEnvironment.current())
        let store = TrafficStore(recordHistory: false)
        for _ in 0..<40 {
            if store.ready && !store.apps.isEmpty { break }
            if store.error != nil { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return store
    }

    @MainActor static func status(watch: Bool, json: Bool) async throws {
        let store = await sampledStore()
        defer { store.shutdown() }
        if let error = store.error { throw CLIError("Traffic monitoring failed: \(error)") }
        // The app's network usage and filter state change slowly; refresh them every 10 s.
        var app = await WiFiCLI.connection(), fetched = Date()
        if watch && !json && Terminal.interactive { await liveMonitor(store, app: app) }
        else if watch {
            while true {
                if Date().timeIntervalSince(fetched) >= 10 { app = await WiFiCLI.connection(); fetched = Date() }
                if json { outputJSON(store, app: app) } else { print(dashboard(store, app: app).joined(separator: "\n") + "\n") }
                fflush(stdout)
                try? await Task.sleep(for: .seconds(1))
            }
        } else if json { outputJSON(store, app: app) }
        else { print(dashboard(store, app: app).joined(separator: "\n")) }
    }

    /// Full-screen live monitor with single-key controls, in the style of `mo status`.
    @MainActor static func liveMonitor(_ store: TrafficStore, app: [String: Any]?) async {
        Terminal.enter()
        defer { Terminal.leave() }
        let filters = ["All apps", "Active", "Allowed", "Blocked"]
        var bySession = false, searching = false, app = app, fetched = Date()
        while true {
            if Date().timeIntervalSince(fetched) >= 10 { app = await WiFiCLI.connection(); fetched = Date() }
            // Everything but the app rows takes 18 lines; the rows shrink to fit the window.
            var lines = dashboard(store, app: app, bySession: bySession, rows: max(1, Terminal.height - 18))
            lines.append("")
            if searching {
                lines.append("  " + Terminal.violet("/") + " " + store.search + Terminal.violet("▏") + Terminal.dim("   Enter keep · Esc clear"))
            } else {
                let search = store.search.isEmpty ? "" : " “\(store.search)”"
                lines.append(Terminal.dim("  q quit · s sort: \(bySession ? "session" : "live") · f filter: \(store.filter.lowercased()) · / search\(search)"))
            }
            Terminal.draw(lines)
            guard let key = await Terminal.waitForKey(1) else { continue }
            if searching {
                switch key {
                case .enter: searching = false
                case .escape: searching = false; store.search = ""
                case .backspace: if !store.search.isEmpty { store.search.removeLast() }
                case .char(let character): store.search.append(character)
                default: break
                }
                continue
            }
            switch key {
            case .char("q"), .escape: return
            case .char("s"): bySession.toggle()
            case .char("f"): store.filter = filters[((filters.firstIndex(of: store.filter) ?? 0) + 1) % filters.count]
            case .char("/"): searching = true
            default: break
            }
        }
    }

    /// `app` is the running app's relay answer; without it the session line shows only what this command sampled.
    @MainActor static func dashboard(_ store: TrafficStore, app: [String: Any]? = nil, bySession: Bool = false, rows: Int = 12) -> [String] {
        let violet = Terminal.violet, blue = Terminal.blue
        var lines = ["", violet("  ◉  kilobat"), "  \(store.networkKind) · \(app?["metered"] as? Bool ?? store.metered ? "Metered" : "Unmetered") · \(store.preferences.profile.rawValue) · Filtering status: see app", ""]
        lines.append(Terminal.dim("  ↓ DOWNLOAD                         ↑ UPLOAD"))
        lines.append("  \(blue(pad(TrafficFormat.rate(store.download), 35)))\(violet(TrafficFormat.rate(store.upload)))")
        lines.append("  \(blue(pad(spark(store.downloadHistory), 35)))\(violet(spark(store.uploadHistory)))")
        lines.append("")
        if let bytes = (app?["sessionBytes"] as? NSNumber)?.uint64Value, let used = (app?["budgetUsed"] as? NSNumber)?.doubleValue {
            let budget = (app?["budgetGB"] as? NSNumber)?.doubleValue ?? store.preferences.limitGB
            lines.append("  SESSION  \(TrafficFormat.bytes(bytes)) / \(budget.formatted()) GB")
            let progress = Int(min(1, max(0, used)) * 42)
            lines.append("  " + violet(String(repeating: "━", count: progress)) + Terminal.dim(String(repeating: "─", count: 42 - progress)))
        } else {
            lines.append("  SAMPLED  \(TrafficFormat.bytes(store.total)) since this command started")
            lines.append(Terminal.dim("  Open Kilobat for this network's session use against the \(store.preferences.limitGB.formatted()) GB budget"))
        }
        lines.append("")
        lines.append(Terminal.dim("  \(pad("APPLICATION", 29))\(pad(bySession ? "LIVE" : "LIVE ↓", 14))\(pad(bySession ? "SESSION ↓" : "SESSION", 12))RULE"))
        lines.append(Terminal.dim("  " + String(repeating: "─", count: 65)))
        let apps = bySession ? store.filteredApps.sorted { $0.total > $1.total } : store.filteredApps
        for app in apps.prefix(rows) {
            lines.append("  \(pad(app.name, 29))\(pad(TrafficFormat.rate(app.rate), 14))\(pad(TrafficFormat.bytes(app.total), 12))\(store.isAllowed(app.id) ? blue("allow") : violet("block"))")
        }
        if !store.ready { lines.append("  Listening for connections…") }
        else if apps.isEmpty { lines.append(Terminal.dim("  No apps match.")) }
        lines.append("")
        lines.append(Terminal.dim("  Rules are saved locally. Filtering requires the network extension."))
        return lines
    }
    /// The Mac app's preferences domain, where it keeps settings the CLI shares (device names, alerts, menu bar).
    static var appDefaults: UserDefaults { UserDefaults(suiteName: "co.seifi.kilobat") ?? .standard }
    static func csv(_ value: String) -> String { value.contains(where: { ",\"\n".contains($0) }) ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value }
    static func pad(_ text: String, _ length: Int) -> String {
        let clipped = text.count > length - 1 ? String(text.prefix(length - 2)) + "…" : text
        return clipped + String(repeating: " ", count: max(1, length - clipped.count))
    }
    static func spark(_ values: [Double]) -> String {
        let bars = Array("▁▂▃▄▅▆▇█")
        let values = Array(values.suffix(26))
        let maximum = max(1, values.max() ?? 1)
        return String(values.map { bars[min(7, Int($0 / maximum * 7))] })
    }
    @MainActor static func outputJSON(_ store: TrafficStore, app: [String: Any]?) {
        if let encoded = try? statusJSON(store, app: app) { print(String(decoding: encoded, as: UTF8.self)) }
    }
    @MainActor static func statusJSON(_ store: TrafficStore, app: [String: Any]? = nil) throws -> Data {
        // sessionBytes counts only this command's sampling window (sampleSeconds); networkSessionBytes is the app's figure. Both count
        // Internet bytes only, from the Wi-Fi and Ethernet counters when `countsInterfaces`. An app's sessionBytes is everything it moved, split into internetBytes and localBytes (LAN, AirDrop), with tunnelBytes inside a VPN.
        // A system download service's onBehalfOf lists the apps the filter saw it download for; null without the filter.
        let downloadsFor = (app?["downloadsFor"] as? [String: [String]]) ?? [:], filtered = app?["filteringActive"] as? Bool == true
        let groups = Dictionary(AppTrafficGroup.make(store.filteredApps, grouped: true).flatMap { group in group.members.map { ($0.id, group) } }) { first, _ in first }
        var data: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()), "sampleSeconds": WiFiCLI.tenths(Date().timeIntervalSince(store.startedAt)), "mode": "observer", "filteringActive": NSNull(), "connected": store.connected, "network": store.networkKind, "metered": store.metered, "osMetered": store.osExpensive, "meteredSource": "macOS", "profile": store.preferences.profile.rawValue.lowercased(), "downloadBytesPerSecond": store.download, "uploadBytesPerSecond": store.upload, "sessionBytes": store.total, 
                                   "localBytes": store.local, "tunnelBytes": store.tunnel, "unattributedBytes": store.unattributedBytes, "countsInterfaces": store.countsInterfaces,
                                   "apps": store.filteredApps.map { traffic in
            var row: [String: Any] = ["id": traffic.id, "name": traffic.name, "downloadBytesPerSecond": traffic.downloadRate, "uploadBytesPerSecond": traffic.uploadRate, "sessionBytes": traffic.total,
                                      "internetBytes": traffic.internet, "localBytes": traffic.local, "tunnelBytes": traffic.tunnel, "allowedRule": store.isAllowed(traffic.id), "processIDs": traffic.processIDs]
            if let path = traffic.executablePath { row["executablePath"] = path }
            if let path = traffic.bundlePath { row["bundlePath"] = path }
            // The app it belongs to, grouped as the app's list groups helpers under their owner.
            if let group = groups[traffic.id] {
                row["groupID"] = group.id; row["groupName"] = group.summary.name
                if let path = group.summary.bundlePath { row["groupPath"] = path }
            }
            if let service = SystemDownloads.service(for: traffic) {
                row["systemDownload"] = service.detail
                row["onBehalfOf"] = filtered ? (downloadsFor[service.process] ?? []) : NSNull()
            }
            return row
        }]
        if let app { data.merge(appFields(app)) { _, new in new } }
        data["budget"] = QuotaCLI.budgetJSON(store, app: app); data["quotas"] = QuotaCLI.quotasJSON(store, app: app)
        return try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    /// What only the running app knows: filter state, Wi-Fi name and this network's budget use.
    static func appFields(_ app: [String: Any]) -> [String: Any] {
        var fields: [String: Any] = ["filteringActive": app["filteringActive"] ?? NSNull(), "ssid": app["ssid"] ?? NSNull()]
        if let budget = app["budgetGB"] { fields["sessionBudgetGB"] = budget }
        if let used = app["budgetUsed"] { fields["budgetUsed"] = used }
        if let bytes = app["sessionBytes"] { fields["networkSessionBytes"] = bytes }
        for key in ["metered", "osMetered", "meteredSource", "vpn", "vpnInterface", "vpnName"] { if let value = app[key] { fields[key] = value } }
        if let bytes = app["localBytes"] { fields["networkLocalBytes"] = bytes }
        if let bytes = app["unattributedBytes"] { fields["networkUnattributedBytes"] = bytes }
        return fields
    }
    @MainActor static func rulesJSON(_ store: TrafficStore, profile selected: NetworkProfile? = nil, app: [String: Any]? = nil) throws -> Data {
        let selected = selected ?? store.preferences.profile, profile = selected.rawValue
        let rules = (store.preferences.rules[profile] ?? [:]).sorted { $0.key < $1.key }.map { ["id": $0.key, "allowed": $0.value] as [String: Any] }
        let temporary = (store.preferences.temporaryRules ?? [:]).filter { $0.key.hasPrefix(profile + "|") && $0.value.expires > Date() }.sorted { $0.key < $1.key }
            .map { ["id": String($0.key.dropFirst(profile.count + 1)), "allowed": $0.value.allowed, "expires": ISO8601DateFormatter().string(from: $0.value.expires)] as [String: Any] }
        let connections = (store.preferences.connectionRules ?? []).filter { $0.profile == profile }.map {
            ["id": $0.id.uuidString, "app": $0.app, "host": $0.host, "port": $0.port.isEmpty ? NSNull() : $0.port, "direction": $0.direction, "allowed": $0.allowed] as [String: Any]
        }
        let newApps = selected == .unrestricted ? "allow" : store.preferences.askNewApps == true ? "ask" : store.preferences.defaultAllow ? "allow" : "block"
        let data: [String: Any] = ["profile": profile.lowercased(), "active": selected == store.preferences.profile, "defaultAllow": selected == .unrestricted || store.preferences.defaultAllow,
                                   "newApps": newApps, "allowApple": store.preferences.allowApple == true, "rules": rules, "temporaryRules": temporary,
                                   "connectionRules": connections, "blockedHosts": store.preferences.blockedHosts ?? [], "blocklistEntries": store.preferences.blockedDomains?.count ?? 0,
                                   "sessionBudgetGB": store.preferences.limitGB, "filteringActive": app?["filteringActive"] ?? NSNull(),
                                   "budget": QuotaCLI.budgetJSON(store, app: app), "quotas": QuotaCLI.quotasJSON(store, app: app)]
        return try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    @MainActor @discardableResult static func selectProfile(_ name: String, in store: TrafficStore) throws -> NetworkProfile {
        guard let profile = NetworkProfile.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) else { throw CLIError("Choose travel, work, or unrestricted.") }
        store.preferences.profile = profile
        return profile
    }
    @MainActor static func saveAppRule(_ id: String, allowed: Bool, minutes: Int?, profile: NetworkProfile? = nil, in store: TrafficStore) throws {
        guard id.contains(".") || id.hasPrefix("process:"), !id.contains(" ") else { throw CLIError("Use a bundle ID such as com.example.App, or process:<name> for a process rule.") }
        let profile = profile ?? store.preferences.profile
        guard profile != .unrestricted else { throw CLIError("Unrestricted allows every app. Pass --profile travel or work, or select one first.") }
        if let minutes {
            guard (1...1440).contains(minutes) else { throw CLIError("Temporary rule duration must be 1…1440 minutes.") }
            store.setTemporary(id, allowed: allowed, minutes: minutes, in: profile)
        } else { store.setAllowed(id, allowed, in: profile) }
    }
    /// Shared parsing for allow, block, reset and rules: an optional app ID, --profile and --minutes.
    static func ruleOptions(_ args: [String], command: String) throws -> (id: String?, profile: NetworkProfile?, minutes: Int?) {
        var id: String?, profile: NetworkProfile?, minutes: Int?, index = 1
        while index < args.count {
            switch args[index] {
            case "--json": index += 1
            case "--profile":
                guard index + 1 < args.count, let value = NetworkProfile.allCases.first(where: { $0.rawValue.lowercased() == args[index + 1].lowercased() }) else { throw CLIError("--profile takes travel, work or unrestricted.") }
                profile = value; index += 2
            case "--minutes":
                guard index + 1 < args.count, let value = Int(args[index + 1]) else { throw CLIError("--minutes takes a number from 1 to 1440.") }
                minutes = value; index += 2
            case let value where id == nil && !value.hasPrefix("-"):
                guard value.contains(".") || value.hasPrefix("process:"), !value.contains(" ") else { throw CLIError("Use a bundle ID such as com.example.App, or process:<name> for a process rule.") }
                id = value; index += 1
            default: throw CLIError("Unexpected '\(args[index])'. Run kilobat \(command) --help.")
            }
        }
        return (id, profile, minutes)
    }

    static let menuItems: [(key: Character, title: String, detail: String, command: [String])] = [
        ("1", "Live monitor", "See every app's traffic", ["status", "--watch"]),
        ("2", "Speed test", "Download, upload and latency", ["speedtest"]),
        ("3", "Diagnose", "Signal, router, internet, DNS", ["diagnose"]),
        ("4", "Signal radar", "Find a stronger spot", ["radar", "--watch"]),
        ("5", "Nearby networks", "Scan Wi-Fi channels", ["scan"]),
        ("6", "Profiles", "Travel, Work, Unrestricted", ["profile"]),
        ("7", "Access rules", "Review your saved rules", ["rules"]),
        ("8", "Usage report", "Your last 30 days", ["report"]),
        ("9", "Doctor", "Check your setup", ["doctor"]),
        ("0", "Open app", "Native dashboard", ["open"]),
    ]

    /// Arrow-key menu: ↑↓ or j/k to move, Enter to open, a digit to jump, q to quit.
    @MainActor static func menu() async {
        guard Terminal.interactive else { print(help); return }
        var index = 0
        while true {
            Terminal.enter()
            var choice: [String]?
            while choice == nil {
                var lines = ["", "  " + Terminal.violet("◉  kilobat") + Terminal.dim("  your network, out of the dark"), ""]
                for (position, item) in menuItems.enumerated() {
                    let row = "\(item.key)  \(pad(item.title, 18))"
                    lines.append(position == index
                        ? "  " + Terminal.violet("➤ ") + Terminal.bold(row) + item.detail
                        : "    " + row + Terminal.dim(item.detail))
                }
                lines += ["", Terminal.dim("  ↑↓ move · Enter open · 0–9 jump · q quit")]
                Terminal.draw(lines)
                switch await Terminal.waitForKey(60) {
                case .up?, .char("k")?: index = (index + menuItems.count - 1) % menuItems.count
                case .down?, .char("j")?, .tab?: index = (index + 1) % menuItems.count
                case .enter?: choice = menuItems[index].command
                case .char("q")?, .escape?: Terminal.leave(); return
                case .char(let digit)?:
                    if let position = menuItems.firstIndex(where: { $0.key == digit }) { index = position; choice = menuItems[position].command }
                default: break
                }
            }
            Terminal.leave()
            guard let command = choice else { continue }
            do { try await run(command) } catch { print(Terminal.rose("✕ ") + error.localizedDescription) }
            // Live screens return straight to the menu; one-shot output stays until a keypress.
            if !command.contains("--watch") {
                print(Terminal.dim("\n  Press any key to return to the menu"))
                Terminal.enter(); _ = await Terminal.waitForKey(3600); Terminal.leave()
            }
        }
    }

    static let commands: [(name: String, detail: String)] = [
        ("status", "Live per-app traffic"), ("profile", "List or select a profile"), ("allow", "Save an allow rule"),
        ("block", "Save a block rule"), ("rules", "Review saved rules"), ("limit", "Read or set the data budget and its cycle"), ("quota", "Per-app data quotas"), ("updaters", "Pause updaters on metered networks"),
        ("report", "Usage history, or compare it with a router or provider"), ("open", "Open the Mac app"), ("doctor", "Check your setup"),
        ("mcp", "MCP server for AI agents (stdio)"),
        ("diagnose", "Wi-Fi, router, internet and DNS checks"), ("radar", "Signal score and best-spot finder"),
        ("scan", "Nearby networks"), ("speedtest", "Speed and loaded-latency test"), ("dns", "Read or set DNS"),
        ("awake", "Keep the Mac awake, network-aware"), ("sessions", "Awake sessions and AI agent runs"),
        ("agent-event", "Report an agent's state from its hooks"), ("why", "Find what stops a connection"), ("conditions", "Metered, VPN, battery: fit for a long run?"), ("ip", "Where traffic leaves: interface, VPN, public IP"),
        ("completion", "Shell completion script"), ("update", "Update the CLI"), ("help", "Show help"),
        ("blocked-history", "Blocked-flow metadata"), ("connection-rules", "List destination rules"),
        ("connection-rule", "Save a destination rule"), ("remove-connection-rule", "Remove a destination rule"),
        ("destinations", "Observed process sockets"), ("devices", "Local devices and services"),
        ("interfaces", "Physical and VPN counters"), ("trace", "Route probe, once or several times"), ("dns-benchmark", "Resolver timings"),
        ("dns-profile", "Export an encrypted-DNS profile"), ("lan-test", "iperf3 LAN test"), ("blocklist", "Manage a domain list"),
        ("domain-exception", "Save a domain exception"), ("remember-network", "Remember profile and budget"),
        ("scope", "Set monitoring scope"), ("http-check", "HTTP timing breakdown"), ("router-counters", "UPnP router counters"),
        ("signature", "Inspect process signing"), ("bonjour", "Browse Bonjour services"), ("discover", "Host discovery"),
        ("capture", "Bounded packet capture"), ("wake", "Wake-on-LAN"), ("spots", "Saved Wi-Fi spots"),
        ("scan-history", "Saved scans"), ("route-history", "Saved routes, hop by hop over time"), ("outages", "Outage records"),
        ("speed-history", "Speed test records"), ("speed-compare", "What differed between two speed tests"), ("reset", "Remove an app rule"), ("wifi", "Wi-Fi status and control"),
        ("channels", "Least crowded channel"), ("networks", "Networks and remembered settings"), ("health-history", "Connection checks over time"), ("support-report", "Report for your ISP or IT desk"), ("plan", "Speed tests against the plan you pay for"), ("overlay", "Live ping overlay for streaming"), ("proxy", "Proxy apps and routes"), ("vpn", "VPN leak checks"), ("calls", "Report cards after calls"),
        ("settings", "Read or change settings"), ("low-latency", "Pause AWDL for calls and games"), ("stutter", "Find periodic latency spikes"),
        ("airdrop", "AirDrop link, its users and visibility"), ("bluetooth", "Bluetooth devices sharing the Wi-Fi band"), ("quit", "Quit a process"),
        ("bandwidth", "One app's sent and received over time"), ("access-policy", "Connections an app declares"),
        ("approvals", "Apps waiting for approval"), ("approve", "Allow a waiting app"), ("deny", "Block a waiting app"),
        ("block-host", "Block a domain or IP"), ("unblock-host", "Unblock a domain or IP"),
    ]
    static let commandValues: [String: [String]] = [
        "status": ["--watch", "--json"], "profile": ["travel", "work", "unrestricted"], "report": ["compare", "--csv", "--json", "--summary", "--days", "--total", "--unit", "--direction", "--from", "--to", "--period", "--network"],
        "rules": ["--json", "--profile"], "limit": ["--cycle", "--reset-day", "--alert"], "quota": ["--list", "--json", "--upload", "--all-networks", "--remove"], "updaters": ["on", "off", "--json"], "awake": ["--for", "--until-quiet", "--app", "--quiet", "--display", "--lid-closed", "--while-frontmost", "--json"],
        "sessions": ["--days", "--json"], "agent-event": ["start", "working", "waiting", "done", "failed", "--agent", "--session", "--cwd", "--message", "--stdin-json", "--json-arg", "--verbose"], "why": ["--app", "--proxy", "--context", "--failed-at", "--json"], "conditions": ["--json"], "allow": ["--minutes", "--profile"], "block": ["--minutes", "--profile"], "reset": ["--profile"],
        "diagnose": ["--json"], "radar": ["--watch", "--json"], "scan": ["--json"], "channels": ["--json"], "speedtest": ["--json", "--budget-mb", "--parallel", "--progress"], "ip": ["--public", "--json"], "speed-compare": ["--json"], "trace": ["--rounds", "--json"], "route-history": ["--host", "--json"],
        "dns": ["automatic", "cloudflare", "google", "quad9", "flush"], "completion": ["zsh", "bash", "fish"],
        "wifi": ["status", "on", "off", "restart", "disconnect", "join", "known", "password", "share", "--json", "--password-stdin"],
        "networks": ["cost", "forget", "metered", "unmetered", "automatic", "--json"], "health-history": ["--hours", "--json"], "support-report": ["--hours", "--host", "--markdown", "--html", "--output", "--json"], "overlay": ["--port", "--target"], "proxy": ["routes", "test", "--app", "--json"], "vpn": ["--json"], "calls": ["--limit", "--json"], "plan": ["--days", "--json"], "low-latency": ["on", "off", "--for", "--until-quit"],
        "stutter": ["--seconds", "--target", "router", "internet", "--json"], "airdrop": ["status", "everyone", "contacts", "off", "--json"], "bluetooth": ["--json"], "quit": ["--force"],
        "settings": ["new-apps", "auto-travel", "pause-updaters", "scope", "alerts", "outage-trace", "public-ip", "speed-streams", "check-interval", "speed-schedule", "plan-mbps", "plan-check", "menu-bar", "units", "group-helpers", "awake-on-power", "keep-screen-on", "on", "off"],
        "destinations": ["--pid", "--json"], "bandwidth": ["hour", "day", "week", "month", "--back", "--json"], "access-policy": ["--json"],
        "approvals": ["--json"], "approve": ["--minutes"], "deny": ["--minutes"], "block-host": ["--app"], "unblock-host": ["--app"], "devices": ["name", "--bonjour", "--json"], "interfaces": ["--json"], "lan-test": ["--reverse", "--json"],
        "spots": ["save", "remove"], "outages": ["--days"], "speed-history": ["--days"], "http-check": ["--json"],
        "blocklist": ["status", "import", "clear"], "scope": ["external", "wifi", "wired"], "connection-rule": ["allow", "block"],
    ]

    static func completionScript(_ shell: String) throws -> String {
        let names = commands.map(\.name).joined(separator: " ")
        switch shell {
        case "zsh":
            let described = commands.map { "'\($0.name):\($0.detail)'" }.joined(separator: " ")
            let cases = commandValues.sorted { $0.key < $1.key }.map { "    \($0.key)) _values '\($0.key)' \($0.value.joined(separator: " ")) ;;" }.joined(separator: "\n")
            return """
            #compdef kilobat
            _kilobat() {
              if (( CURRENT == 2 )); then
                local -a commands=(\(described))
                _describe 'command' commands
              else
                case $words[2] in
            \(cases)
                  *) _files ;;
                esac
              fi
            }
            compdef _kilobat kilobat kb
            """
        case "bash":
            let cases = commandValues.sorted { $0.key < $1.key }.map { "    \($0.key)) COMPREPLY=($(compgen -W \"\($0.value.joined(separator: " "))\" -- \"$cur\")) ;;" }.joined(separator: "\n")
            return """
            _kilobat() {
              local cur=${COMP_WORDS[COMP_CWORD]}
              if [[ $COMP_CWORD -eq 1 ]]; then
                COMPREPLY=($(compgen -W "\(names)" -- "$cur")); return
              fi
              case ${COMP_WORDS[1]} in
            \(cases)
                *) COMPREPLY=($(compgen -f -- "$cur")) ;;
              esac
            }
            complete -F _kilobat kilobat kb
            """
        case "fish":
            let top = commands.map { "complete -c kilobat -f -n __fish_use_subcommand -a \($0.name) -d '\($0.detail)'" }
            let values = commandValues.sorted { $0.key < $1.key }.map { "complete -c kilobat -f -n '__fish_seen_subcommand_from \($0.key)' -a '\($0.value.joined(separator: " "))'" }
            return (top + values + ["complete -c kb -w kilobat"]).joined(separator: "\n")
        default: throw CLIError("Unsupported shell '\(shell)'. Use zsh, bash or fish.")
        }
    }

    /// Help for one command: its usage lines from the full help, plus continuation lines.
    static func commandHelp(_ topic: String) throws -> String {
        var matched: [String] = [], capturing = false
        for line in help.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // "spots / scan-history / route-history  …" documents three commands; "allow|block <app>" two.
            let usage = trimmed.components(separatedBy: "  ").first ?? ""
            let heads = usage.components(separatedBy: " / ").compactMap { $0.split(separator: " ").first }.flatMap { $0.split(separator: "|") }
            if line.hasPrefix("  "), heads.contains(where: { $0 == topic }) {
                matched.append(line); capturing = true
            } else if capturing, trimmed.hasPrefix("[") { matched.append(line) }
            else { capturing = false }
        }
        guard !matched.isEmpty else { throw CLIError("No help for '\(topic)'. Run kilobat --help.") }
        return "Usage:\n" + matched.joined(separator: "\n")
    }

    static let help = """
    kilobat · your network, out of the dark

    Usage: kilobat [command] [options]
           kb [command] [options]      kb is a short alias for kilobat
           kilobat <command> --help

      menu                  Interactive menu, also with no command: ↑↓ move, Enter open, q quit

    Monitor
      status [--watch]      Live per-app traffic and session budget
             [--json]       Snapshot, or a JSONL stream with --watch
      watch [--json]        Same as status --watch
      report [--csv|--json]  Export locally recorded usage history
        [--summary]         Daily totals and top apps instead of raw samples
        [--days 1…365]      Limit the window (30 days default; the app keeps up to a year)
      report compare --total 40GB  Set a router's or provider's figure beside Kilobat's for the same period
        [--unit GB|GiB|MB|…]  The figure's unit, if --total has none; GB is decimal, GiB binary
        [--direction both|download|upload]  What the figure counts (both by default)
        [--from DATE --to DATE]  2026-10-01, 2026-10-01 18:00 or ISO 8601; a date-only --to includes that day
        [--period last-month]  Or this-month, last-7-days, yesterday, today, last-24-hours
        [--network NAME]    Count only this network; repeat for more (all by default)
        [--json|--csv]      Export with the scope, recorded hours and every gap, to share
      bandwidth [app] [hour|day|week|month]  Sent and received for one app or all, with the peak
        [--back N]          An earlier period: --back 1 is the previous hour, day, week or month
        [--json]            Totals and per-bucket bytes
      access-policy <bundle-id> [--json]  The connections an app's developer declares, and why
      health-history [--hours 1…720] [--json]  Router, internet and DNS checks over time
      overlay [--port 7171] [--target internet|router]  Live ping overlay for OBS at localhost, until Ctrl-C
      proxy [--json]        Proxy apps (Clash, Surge, sing-box…), the system proxy and what's wrong with them
      proxy routes [--app <name>]  Which rule and proxy node each app's connections took
      proxy test            How fast each proxy group's current node answers
      vpn [--json]          The VPN, and whether DNS or IPv6 skip it
      calls [--limit 1…200] [--json]  After each call: whether it froze and what caused it (written by the app)
      support-report [--hours 1…168] [--host <host>]  A report for your ISP or IT desk, without
        [--markdown|--html] [--output <file>]  your network's name or local addresses; text by default
      plan [--days 7…90] [--json]  Speed tests against the plan you pay for: median, evenings, under half
      networks [--json]    Networks seen, with remembered profile, budget and data cost
      networks cost <metered|unmetered|automatic> [name]  Set a network's data cost (this one by default)
      networks forget <name>  Drop a network's remembered profile, budget and data cost

    Diagnose
      diagnose [--json]     Wi-Fi, router, internet, DNS and portal checks
      radar [--watch]       Signal score and best-spot finder (4 Hz)
            [--json]        Machine-readable samples
      scan [--json]         Nearby networks and channel widths
      channels [--json]     Congestion per channel and the least crowded one
      speedtest [--json]    Speed, loaded latency, call and streaming verdicts
        [--budget-mb 1…80]  Maximum data use (80 MB default)
        [--parallel]        Four connections at once, as most speed-test sites use, instead of one
        [--progress]        A JSON line per update on stderr: phase, fraction, live Mbps
      speed-compare [<test> <test>] [--json]  What differed between two saved tests: network, time, server,
                            connections, Wi-Fi band and signal, VPN, other traffic; the newest two by default
      ip [--json]           Where traffic leaves: the default route's interface and any VPN, read on this Mac
        [--public]          Also ask Cloudflare for the public IP, with its registry country
      stutter [--json]     Ping every 50 ms to find latency spikes and how regular they are
        [--seconds 10…60]   Test length (20 s default)
        [--target router|internet|<host>]  What to ping (the router by default)
      dns [provider]        Read DNS, set automatic/cloudflare/google/quad9, or flush

    Wi-Fi
      wifi [status] [--json]  Current network, signal, channel and link rate
      wifi on|off|restart   Turn Wi-Fi on or off, or restart it
      wifi disconnect       Leave the current network; Wi-Fi stays on
      wifi join <name>      Join a saved network, or a new one
        [--password-stdin]  Read the password from standard input
      wifi known [--json]   Saved networks in order of preference
      wifi password <name>  Show a saved password (macOS asks first)
      wifi share <name>     Password and a QR code to scan with a phone
      low-latency on        Pause AirDrop/AWDL for calls and games while this runs (15 min default)
        [--for 15m|1h|2h]   Pause for longer, up to 4h
        [--until-quit <app>]  Restore when that app quits
      low-latency off       Restore AWDL, also for a pause started elsewhere
      airdrop [status] [--json]  AirDrop visibility, the AirDrop link and what uses it
      airdrop everyone|contacts|off  Open AirDrop settings to change visibility (only macOS can)
      bluetooth [--json]    Bluetooth devices and whether they share 2.4 GHz with Wi-Fi

    Awake & agents
      awake                 Keep the Mac awake until Ctrl-C; closing the lid sleeps it unless --lid-closed
        [--for 90m|2h|45s]  Stop after a while
        [--until-quiet]     Stop once the Mac stays below 16 KB/s
        [--app <id>]        With --until-quiet, watch one app only
        [--quiet 1…60]      Quiet minutes that end it (3 default)
        [--display]         Keep the display on too
        [--lid-closed]      Keep running with the lid closed, 8h at most; needs the app's power helper
        [--json]            JSON summary at the end
      awake [--display] [--lid-closed] -- <command> [args]  Stay awake while a command runs
        [--json]            Summary on stderr with the bytes its processes moved; exits with its status
      awake --while-frontmost <app>  Stay awake only while that app (Keynote, or a bundle ID) is in front
        [--display]         Keep the screen on too; otherwise only the Mac stays awake and the screen may dim
        [--for 90m|2h]      End after a while, even with the app in front
        [--json]            JSON summary; switching away lets the Mac sleep, it ends when the app quits or at 20% battery
      settings awake-on-power on|off  The app stays awake while plugged in and lets go when unplugged
        [--display]         Keep the screen on too; Turn Off in the app holds until the next plug-in
      sessions [--days 1…365] [--json]  Awake sessions and AI agent runs the app recorded
      agent-event <kind>    For an agent's hooks: start, working, waiting, done or failed
        [--agent name]      claude, codex, gemini…; found from the hook's process if left out
        [--session id]      Tells runs in one folder apart
        [--cwd path]        The project folder; the current one by default
        [--message text]    Shown in the notification, up to 200 characters
        [--stdin-json]      Read the hook's JSON from stdin (Claude Code, Codex, Gemini CLI)
        [--json-arg]        Read it from the last argument (Codex notify)
        [--verbose]         Say what happened; otherwise prints nothing and always exits 0
      why <url|host> [--json]  The layer that stops a connection; exits 1 if one failed
                            The full URL is requested, query included; output hides query values
        [--app <id>]        Also check that app's rules, the proxy in its environment and its open connections
        [--proxy <url>]     Test through the proxy address the app uses by its own setting
        [--failed-at <time>]  When the app failed (14:05 or ISO 8601), kept beside the check's own time
        [--context container|vm|remote|provider]  Where the failing code runs; provider: a hosted service's own servers
      conditions [--json]   Metered, Low Data Mode, VPN, latency, battery and heat, with advice

    Control
      profile [name]        List or select travel, work, unrestricted
      allow|block <bundle-id>  Save an allow or block rule
        [--minutes 1…1440]  Make the rule temporary
        [--profile name]    Use another profile than the active one
      reset <bundle-id>     Remove an app's rule [--profile name]
      rules [--json]        Review a profile's rules [--profile name]
      limit [GB]            Read or set this network's data budget; approximate, as usage is sampled
        [--cycle session|daily|weekly|monthly]  When it starts over (session: only when reset)
        [--reset-day N]     Day it starts: 1–31 monthly, 1 (Monday) to 7 weekly
        [--alert 50,80,100]  Notify at these percentages once per cycle, or none
      quota <bundle-id> <GB>  Limit one app's data per budget cycle
        [--upload]          Count uploads only
        [--all-networks]    Count every network, not just this one
      quota <bundle-id> --remove  Remove an app's quota
      quota --list [--json]  Quotas with use in the current cycle
      updaters [--json]     Updaters paused on metered networks, update bytes that got through, apps that update inside
      updaters on|off       Pause updater helpers while the network is metered (on by default); the apps keep working
      settings [name [value]]  Read or change Kilobat's settings; new-apps allow|ask|block
      approvals [--json]    Apps waiting for approval while new-apps is ask
      approve|deny <app-id>  deny blocks a waiting app at once; approve asks you to confirm in the app
        [--minutes 1…1440]  Decide for a while instead
      block-host|unblock-host <domain|IP|CIDR>  Block for every app, *.example.com style
        [--app <id>]        Only for one app, as a connection rule
      quit <PID> [--force]  Quit a process, e.g. one using the network

    Setup
      open                  Open the native Mac app
      doctor                Check the app, filter and monitoring
      completion [shell]    Print a zsh, bash or fish completion script
      mcp                   MCP server for AI agents over stdio
      update                Update a Homebrew install
      version|--version     Print version
      help [command]        Show this help, or one command's usage

    Expert tools
      blocked-history                     Archived blocked-flow metadata (JSON)
      connection-rules                    List destination rules (JSON)
      connection-rule allow|block <app> <host> [port] [direction]
      remove-connection-rule <UUID>       Remove a destination rule
      destinations [--pid PID] [--json]   Observed process sockets
      devices [--bonjour] [--json]        Local neighbor cache / services
      devices name <MAC> <name>           Name a device; an empty name removes it
      interfaces [--json]                 Separate physical / VPN counters
      trace <host>                        Bounded 12-hop route probe
        [--rounds 2…10]                   Trace several times, 3 probes a hop, and show each hop's loss and delay
        [--json]                          The hop-by-hop summary as JSON
      dns-benchmark                       Resolver timings as JSON
      dns-profile <https-endpoint>        Export encrypted-DNS profile XML
      lan-test <server> [--reverse]       Five-second iperf3 test to a device running iperf3 -s
        [--json]                          Mbps, bytes and retransmissions; needs iperf3 installed by you
      blocklist status|import <path>|clear  Manage a domain list
      domain-exception <app> <domain>     Save a domain exception
      remember-network                    Remember current profile and budget
      scope external|wifi|wired           Set process monitoring scope
      http-check <URL> [--json]           DNS/connect/TLS/first-byte timing
      router-counters <control-URL>       Read whole-router UPnP counters
      signature <PID>                     Inspect process signing
      bonjour <_service._tcp>             Browse service instances
      discover <private-IP-or-subnet>     Explicit host discovery (requires nmap)
      capture <interface> <file.pcap>     Explicit bounded packet capture
      wake <MAC-address>                  Send a local Wake-on-LAN packet
      spots [save <name>|remove <id>]     Saved Wi-Fi spots (JSON)
      scan-history / route-history        Saved scans and routes (JSON)
        [--host <host>]                   One host's traces hop by hop: loss, best, average, worst, route changes
      outages / speed-history [--days N]  Persisted records (JSON)

    Live screens: q quit · s sort · f filter · / search.
    Output switches to JSON automatically when piped. NO_COLOR disables colors.
    Wi-Fi names and filter status come from the running app, which has
    the Location permission macOS requires.
    Monitor mode: live traffic works without root. Access rules are saved
    but require a signed, activated Network Extension to block traffic.
    CLI and UI share profiles and rules. History is recorded by the UI.
    No telemetry or accounts.
    """
}
struct CLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
