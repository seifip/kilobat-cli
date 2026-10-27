import Foundation
import Darwin
import KilobatCore

@main
struct KilobatCLI {
    @MainActor static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch {
            FileHandle.standardError.write(Data("kilobat: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor static func run(_ arguments: [String]) async throws {
        var args = arguments
        let command = args.first ?? (Terminal.interactive ? "menu" : "status")
        if args.count >= 2, args.first == "help" || ["--help", "-h"].contains(args.last!) {
            print(try commandHelp(args.first == "help" ? args[1] : command)); return
        }
        // Like `mo status | jq`: piped output switches to JSON so scripts never parse the human layout.
        if Terminal.piped, ["status", "watch", "diagnose", "scan", "radar", "speedtest"].contains(command), !args.contains("--json") {
            if args.isEmpty { args = [command] }
            args.append("--json")
        }
        switch command {
        case "blocklist", "domain-exception", "remember-network", "scope": try await PolicyCLI.run(args)
        case "remove-connection-rule", "blocked-history", "http-check", "router-counters", "connection-rule", "connection-rules", "signature", "discover", "bonjour", "capture", "wake", "destinations", "devices", "interfaces", "trace", "dns-benchmark", "dns-profile", "lan-test", "outages", "speed-history", "spots", "scan-history", "route-history": try await ExpertCLI.run(args)
        case "diagnose", "scan", "radar", "speedtest", "dns": try await DiagnosticsCLI.run(args)
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
            let path = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
            guard path.contains("/Cellar/") else {
                print("This copy was not installed with Homebrew.")
                print("Download the latest CLI from https://kilobat.app, or install with: brew install kilobat/tap/kilobat")
                return
            }
            let brew = Process(); brew.executableURL = URL(fileURLWithPath: "/usr/bin/env"); brew.arguments = ["brew", "upgrade", "kilobat"]
            try brew.run(); brew.waitUntilExit()
            if brew.terminationStatus != 0 { throw CLIError("brew upgrade kilobat failed.") }
        case "--version", "version": print("Kilobat \(version)")
        case "mcp":
            guard args.count == 1 else { throw CLIError("Use mcp with no arguments. It speaks the Model Context Protocol on stdin/stdout.") }
            await MCPCLI.serve()
        case "menu": await menu()
        case "status", "watch":
            let valid = Set(["--watch", "--json"])
            guard args.dropFirst().allSatisfy({ valid.contains($0) }) else { throw CLIError("Use status [--watch] [--json].") }
            await status(watch: command == "watch" || args.contains("--watch"), json: args.contains("--json"))
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
        case "allow", "block":
            guard (args.count == 2 || (args.count == 4 && args[2] == "--minutes")), (args[1].contains(".") || args[1].hasPrefix("process:")), !args[1].contains(" ") else { throw CLIError("Use \(command) <bundle-id>, e.g. com.example.App. Process rules use process:<name>.") }
            let store = TrafficStore(startMonitoring: false)
            try saveAppRule(args[1], allowed: command == "allow", minutes: args.count == 4 ? Int(args[3]) ?? 0 : nil, in: store)
            print("✓ Saved \(command) rule for \(args[1]) in \(store.preferences.profile.rawValue).")
            print("  Enforcement requires the open app and its active signed filter.")
        case "rules":
            guard args.dropFirst().allSatisfy({ $0 == "--json" }) else { throw CLIError("Use rules [--json].") }
            let store = TrafficStore(startMonitoring: false)
            if args.contains("--json") { print(String(decoding: try rulesJSON(store), as: UTF8.self)); return }
            print("\(store.preferences.profile.rawValue) · saved access rules")
            let rules = store.preferences.rules[store.preferences.profile.rawValue] ?? [:]
            if rules.isEmpty { print("No explicit rules. New apps: \(store.preferences.defaultAllow ? "allow" : "block").") }
            for (id, allowed) in rules.sorted(by: { $0.key < $1.key }) { print("\(allowed ? "allow" : "block")  \(id)") }
            for (key, rule) in (store.preferences.temporaryRules ?? [:]).filter({ $0.key.hasPrefix(store.preferences.profile.rawValue + "|") && $0.value.expires > Date() }).sorted(by: { $0.key < $1.key }) {
                print("\(rule.allowed ? "allow" : "block")  \(key) · expires \(rule.expires.formatted())")
            }
            print("Saved rules · check the app for live filter status")
        case "limit":
            let store = TrafficStore(startMonitoring: false)
            if args.count == 1 { print("Session budget: \(store.preferences.limitGB) GB (informational in monitor mode)") }
            else {
                guard args.count == 2, let amount = Double(args[1]), amount.isFinite, amount >= 0.1, amount <= 10_000 else { throw CLIError("Use limit <GB>, between 0.1 and 10000.") }
                store.preferences.limitGB = amount
                print("✓ Session budget: \(amount) GB. Monitor mode does not stop transfers.")
            }
        case "report":
            var days = 30, index = 1
            while index < args.count {
                if ["--json", "--csv", "--summary"].contains(args[index]) { index += 1; continue }
                guard args[index] == "--days", index + 1 < args.count, let value = Int(args[index + 1]), (1...30).contains(value) else { throw CLIError("Use report [--json|--csv] [--summary] [--days 1…30].") }
                days = value; index += 2
            }
            let store = TrafficStore(startMonitoring: false)
            if args.contains("--summary") {
                let summary = UsageSummary(store.usage, days: days)
                if args.contains("--json") { print(String(decoding: try DiagnosticsCLI.encode(summary), as: UTF8.self)); return }
                print("Kilobat · last \(days) days · ↓ \(TrafficFormat.bytes(summary.downloadBytes))  ↑ \(TrafficFormat.bytes(summary.uploadBytes))")
                for app in summary.topApps { print("  \(pad(app.name, 30))\(TrafficFormat.bytes(app.bytes))") }
                return
            }
            if args.contains("--json") {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                print(String(decoding: try encoder.encode(store.usage), as: UTF8.self))
            } else if args.contains("--csv") {
                print("timestamp,download_bytes,upload_bytes")
                for entry in store.usage { print("\(ISO8601DateFormatter().string(from: entry.date)),\(entry.received),\(entry.sent)") }
            } else {
                print("Kilobat · last 30 days (recorded while the UI is running)")
                print("↓ \(TrafficFormat.bytes(store.usage.reduce(0) { $0 + $1.received }))  ↑ \(TrafficFormat.bytes(store.usage.reduce(0) { $0 + $1.sent }))")
                print("\(store.usage.count) samples · data stays on this Mac")
            }
        case "open":
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            let candidates = [URL(fileURLWithPath: "/Applications/Kilobat.app"), executable.deletingLastPathComponent().appendingPathComponent("Kilobat.app"), executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("dist/Kilobat.app")]
            guard let app = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw CLIError("App bundle not found. Run script/build_and_run.sh first.") }
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open"); process.arguments = [app.path]; try process.run(); process.waitUntilExit()
            if process.terminationStatus != 0 { throw CLIError("Could not open the app.") }
        case "doctor":
            print("✓ macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
            print("\(FileManager.default.isExecutableFile(atPath: "/usr/bin/nettop") ? "✓" : "✕") Apple nettop traffic monitoring")
            print("✓ Shared local preferences and usage history")
            print("○ Filter activation cannot be verified by this CLI. Check the app’s filtering status.")
            print("  Enable the provisioned extension from the app’s settings.")
        default: throw CLIError("Unknown command '\(command)'. Run kilobat --help.")
        }
    }

    static let version = "0.1.0"

    /// Starts monitoring and waits up to 8 s for the first per-app sample.
    @MainActor static func sampledStore() async -> TrafficStore {
        let store = TrafficStore(recordHistory: false)
        for _ in 0..<40 {
            if store.ready && !store.apps.isEmpty { break }
            if store.error != nil { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return store
    }

    @MainActor static func status(watch: Bool, json: Bool) async {
        let store = await sampledStore()
        defer { store.shutdown() }
        if watch && !json && Terminal.interactive { await liveMonitor(store) }
        else if watch {
            while true {
                if json { outputJSON(store) } else { print(dashboard(store).joined(separator: "\n") + "\n") }
                fflush(stdout)
                try? await Task.sleep(for: .seconds(1))
            }
        } else if json { outputJSON(store) }
        else { print(dashboard(store).joined(separator: "\n")) }
        if let error = store.error { FileHandle.standardError.write(Data("\(error)\n".utf8)) }
    }

    /// Full-screen live monitor with single-key controls, in the style of `mo status`.
    @MainActor static func liveMonitor(_ store: TrafficStore) async {
        Terminal.enter()
        defer { Terminal.leave() }
        let filters = ["All apps", "Active", "Allowed", "Blocked"]
        var bySession = false, searching = false
        while true {
            var lines = dashboard(store, bySession: bySession)
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

    @MainActor static func dashboard(_ store: TrafficStore, bySession: Bool = false) -> [String] {
        let violet = Terminal.violet, blue = Terminal.blue
        var lines = ["", violet("  ◉  kilobat"), "  \(store.networkKind) · \(store.expensive ? "Metered" : "Unmetered") · \(store.preferences.profile.rawValue) · Filtering status: see app", ""]
        lines.append(Terminal.dim("  ↓ DOWNLOAD                         ↑ UPLOAD"))
        lines.append("  \(blue(pad(TrafficFormat.rate(store.download), 35)))\(violet(TrafficFormat.rate(store.upload)))")
        lines.append("  \(blue(pad(spark(store.downloadHistory), 35)))\(violet(spark(store.uploadHistory)))")
        lines.append("")
        lines.append("  SESSION  \(TrafficFormat.bytes(store.total)) / \(store.preferences.limitGB) GB")
        let progress = Int(store.limitFraction * 42)
        lines.append("  " + violet(String(repeating: "━", count: progress)) + Terminal.dim(String(repeating: "─", count: 42 - progress)))
        lines.append("")
        lines.append(Terminal.dim("  \(pad("APPLICATION", 29))\(pad(bySession ? "LIVE" : "LIVE ↓", 14))\(pad(bySession ? "SESSION ↓" : "SESSION", 12))RULE"))
        lines.append(Terminal.dim("  " + String(repeating: "─", count: 65)))
        let apps = bySession ? store.filteredApps.sorted { $0.total > $1.total } : store.filteredApps
        for app in apps.prefix(12) {
            lines.append("  \(pad(app.name, 29))\(pad(TrafficFormat.rate(app.rate), 14))\(pad(TrafficFormat.bytes(app.total), 12))\(store.isAllowed(app.id) ? blue("allow") : violet("block"))")
        }
        if !store.ready { lines.append("  Listening for connections…") }
        else if apps.isEmpty { lines.append(Terminal.dim("  No apps match.")) }
        lines.append("")
        lines.append(Terminal.dim("  Rules are saved locally. Filtering requires the network extension."))
        return lines
    }
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
    @MainActor static func outputJSON(_ store: TrafficStore) {
        if let encoded = try? statusJSON(store) { print(String(decoding: encoded, as: UTF8.self)) }
    }
    @MainActor static func statusJSON(_ store: TrafficStore) throws -> Data {
        let data: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()), "mode": "observer", "filteringActive": NSNull(), "connected": store.connected, "network": store.networkKind, "metered": store.expensive, "profile": store.preferences.profile.rawValue.lowercased(), "downloadBytesPerSecond": store.download, "uploadBytesPerSecond": store.upload, "sessionBytes": store.total, "apps": store.filteredApps.map { ["id": $0.id, "name": $0.name, "downloadBytesPerSecond": $0.downloadRate, "uploadBytesPerSecond": $0.uploadRate, "sessionBytes": $0.total, "allowedRule": store.isAllowed($0.id)] as [String: Any] }]
        return try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
    }
    @MainActor static func rulesJSON(_ store: TrafficStore) throws -> Data {
        let profile = store.preferences.profile.rawValue
        let rules = (store.preferences.rules[profile] ?? [:]).sorted { $0.key < $1.key }.map { ["id": $0.key, "allowed": $0.value] as [String: Any] }
        let temporary = (store.preferences.temporaryRules ?? [:]).filter { $0.key.hasPrefix(profile + "|") && $0.value.expires > Date() }.sorted { $0.key < $1.key }
            .map { ["id": String($0.key.dropFirst(profile.count + 1)), "allowed": $0.value.allowed, "expires": ISO8601DateFormatter().string(from: $0.value.expires)] as [String: Any] }
        let data: [String: Any] = ["profile": profile.lowercased(), "defaultAllow": store.preferences.profile == .unrestricted || store.preferences.defaultAllow, "rules": rules, "temporaryRules": temporary, "sessionBudgetGB": store.preferences.limitGB, "filteringActive": NSNull()]
        return try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
    }
    @MainActor @discardableResult static func selectProfile(_ name: String, in store: TrafficStore) throws -> NetworkProfile {
        guard let profile = NetworkProfile.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) else { throw CLIError("Choose travel, work, or unrestricted.") }
        store.preferences.profile = profile
        return profile
    }
    @MainActor static func saveAppRule(_ id: String, allowed: Bool, minutes: Int?, in store: TrafficStore) throws {
        guard id.contains(".") || id.hasPrefix("process:"), !id.contains(" ") else { throw CLIError("Use a bundle ID such as com.example.App, or process:<name> for a process rule.") }
        guard store.preferences.profile != .unrestricted else { throw CLIError("Unrestricted allows every app. Select travel or work first.") }
        if let minutes {
            guard (1...1440).contains(minutes) else { throw CLIError("Temporary rule duration must be 1…1440 minutes.") }
            store.setTemporary(id, allowed: allowed, minutes: minutes)
        } else { store.setAllowed(id, allowed) }
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
        ("block", "Save a block rule"), ("rules", "Review saved rules"), ("limit", "Read or set the session budget"),
        ("report", "Export usage history"), ("open", "Open the Mac app"), ("doctor", "Check your setup"),
        ("mcp", "MCP server for AI agents (stdio)"),
        ("diagnose", "Wi-Fi, router, internet and DNS checks"), ("radar", "Signal score and best-spot finder"),
        ("scan", "Nearby networks"), ("speedtest", "Speed and loaded-latency test"), ("dns", "Read or set DNS"),
        ("completion", "Shell completion script"), ("update", "Update the CLI"), ("help", "Show help"),
        ("blocked-history", "Blocked-flow metadata"), ("connection-rules", "List destination rules"),
        ("connection-rule", "Save a destination rule"), ("remove-connection-rule", "Remove a destination rule"),
        ("destinations", "Observed process sockets"), ("devices", "Local devices and services"),
        ("interfaces", "Physical and VPN counters"), ("trace", "Route probe"), ("dns-benchmark", "Resolver timings"),
        ("dns-profile", "Export an encrypted-DNS profile"), ("lan-test", "iperf3 LAN test"), ("blocklist", "Manage a domain list"),
        ("domain-exception", "Save a domain exception"), ("remember-network", "Remember profile and budget"),
        ("scope", "Set monitoring scope"), ("http-check", "HTTP timing breakdown"), ("router-counters", "UPnP router counters"),
        ("signature", "Inspect process signing"), ("bonjour", "Browse Bonjour services"), ("discover", "Host discovery"),
        ("capture", "Bounded packet capture"), ("wake", "Wake-on-LAN"), ("spots", "Saved Wi-Fi spots"),
        ("scan-history", "Saved scans"), ("route-history", "Saved routes"), ("outages", "Outage records"),
        ("speed-history", "Speed test records"),
    ]
    static let commandValues: [String: [String]] = [
        "status": ["--watch", "--json"], "profile": ["travel", "work", "unrestricted"], "report": ["--csv", "--json", "--summary", "--days"], "rules": ["--json"],
        "diagnose": ["--json"], "radar": ["--watch", "--json"], "scan": ["--json"], "speedtest": ["--json", "--budget-mb"],
        "dns": ["automatic", "cloudflare", "google", "flush"], "completion": ["zsh", "bash", "fish"],
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
            compdef _kilobat kilobat
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
            complete -F _kilobat kilobat
            """
        case "fish":
            let top = commands.map { "complete -c kilobat -f -n __fish_use_subcommand -a \($0.name) -d '\($0.detail)'" }
            let values = commandValues.sorted { $0.key < $1.key }.map { "complete -c kilobat -f -n '__fish_seen_subcommand_from \($0.key)' -a '\($0.value.joined(separator: " "))'" }
            return (top + values).joined(separator: "\n")
        default: throw CLIError("Unsupported shell '\(shell)'. Use zsh, bash or fish.")
        }
    }

    /// Help for one command: its usage lines from the full help, plus continuation lines.
    static func commandHelp(_ topic: String) throws -> String {
        var matched: [String] = [], capturing = false
        for line in help.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let head = trimmed.split(separator: " ").first.map(String.init) ?? ""
            if line.hasPrefix("  "), head.split(whereSeparator: { $0 == "|" || $0 == "/" }).contains(where: { $0 == topic }) {
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
           kilobat <command> --help

      (no command)          Interactive menu: ↑↓ move, Enter open, q quit

    Monitor
      status [--watch]      Live per-app traffic and session budget
             [--json]       Snapshot, or a JSONL stream with --watch
      report [--csv|--json]  Export locally recorded usage history
        [--summary]         Daily totals and top apps instead of raw samples
        [--days 1…30]       Limit the summary window (30 days default)

    Diagnose
      diagnose [--json]     Wi-Fi, router, internet, DNS and portal checks
      radar [--watch]       Signal score and best-spot finder (4 Hz)
            [--json]        Machine-readable samples
      scan [--json]         Nearby networks and channel widths
      speedtest [--json]    Cloudflare speed and loaded-latency test
        [--budget-mb 1…80]  Maximum data use (80 MB default)
      dns [provider]        Read DNS, set automatic/cloudflare/google, or flush

    Control
      profile [name]        List or select travel, work, unrestricted
      allow <bundle-id>     Save an allow rule in the current profile
      block <bundle-id>     Save a block rule in the current profile
        [--minutes 1…1440]  Make the rule temporary
      rules [--json]        Review current profile's rules
      limit [GB]            Read or set the session budget

    Setup
      open                  Open the native Mac app
      doctor                Check monitoring and filtering readiness
      completion [shell]    Print a zsh, bash or fish completion script
      mcp                   MCP server for AI agents over stdio
      update                Update a Homebrew install
      --version             Print version

    Expert tools
      blocked-history                     Archived blocked-flow metadata (JSON)
      connection-rules                    List destination rules (JSON)
      connection-rule allow|block <app> <host> [port] [direction]
      remove-connection-rule <UUID>       Remove a destination rule
      destinations [--pid PID] [--json]   Observed process sockets
      devices [--bonjour] [--json]        Local neighbor cache / services
      interfaces [--json]                 Separate physical / VPN counters
      trace <host>                        Bounded 12-hop route probe
      dns-benchmark                       Resolver timings as JSON
      dns-profile <https-endpoint>        Export encrypted-DNS profile XML
      lan-test <server> [--reverse]       Five-second iperf3 LAN test
      blocklist status|import <path>|clear  Manage a domain list
      domain-exception <app> <domain>     Save a domain exception
      remember-network                    Remember current profile and budget
      scope external|wifi|wired           Set process monitoring scope
      http-check <URL>                    DNS/connect/TLS/first-byte timing
      router-counters <control-URL>       Read whole-router UPnP counters
      signature <PID>                     Inspect process signing
      bonjour <_service._tcp>             Browse service instances
      discover <private-IP-or-subnet>     Explicit host discovery (requires nmap)
      capture <interface> <file.pcap>     Explicit bounded packet capture
      wake <MAC-address>                  Send a local Wake-on-LAN packet
      spots / scan-history / route-history  Saved Wi-Fi and route observations (JSON)
      outages / speed-history             Persisted records (JSON)

    Live screens: q quit · s sort · f filter · / search.
    Output switches to JSON automatically when piped. NO_COLOR disables colors.
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
