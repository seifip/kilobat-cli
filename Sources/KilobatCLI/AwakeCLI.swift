import Foundation
import Darwin
import Network
import KilobatCore

/// `awake`, `sessions`, `why` and `conditions`: unattended work, the runs the app recorded, and why something can't connect.
@MainActor enum AwakeCLI {
    nonisolated(unsafe) static var interrupted = false

    static func run(_ args: [String]) async throws {
        switch args[0] {
        case "awake": try await awake(args)
        case "sessions":
            try KilobatCLI.allow(args, ["--days", "--json"], valued: ["--days"])
            var days = 7
            if let index = args.firstIndex(of: "--days") {
                guard index + 1 < args.count, let value = Int(args[index + 1]), (1...365).contains(value) else { throw CLIError("Use sessions [--days 1…365] [--json].") }
                days = value
            }
            let sessions = history(days: days)
            if args.contains("--json") { print(String(decoding: try DiagnosticsCLI.encode(sessions), as: UTF8.self)); return }
            guard !sessions.isEmpty else {
                print("No sessions in the last \(days) days. The Kilobat app records awake sessions and AI agent runs while it runs.")
                return
            }
            print("Kilobat sessions · last \(days) days")
            for session in sessions {
                let ended = session.ended.map { " · " + $0.lowercased() } ?? ""
                print("  \(KilobatCLI.pad(session.start.formatted(date: .abbreviated, time: .shortened), 22))\(KilobatCLI.pad(session.title, 24))\(session.summary)\(ended)")
                let top = session.apps.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) \(TrafficFormat.bytes($0.value))" }
                let hosts = session.destinations.isEmpty ? [] : [session.destinations.count == 1 ? "1 host" : "\(session.destinations.count) hosts"]
                if !top.isEmpty || !hosts.isEmpty { print(Terminal.dim("  \(String(repeating: " ", count: 46))" + (top + hosts).joined(separator: " · "))) }
            }
        case "why":
            var target: String?, app: String?, index = 1
            while index < args.count {
                switch args[index] {
                case "--json": index += 1
                case "--app":
                    guard index + 1 < args.count, args[index + 1].contains(".") || args[index + 1].hasPrefix("process:") else { throw CLIError("--app takes a bundle ID such as com.example.App, or process:<name>.") }
                    app = args[index + 1]; index += 2
                case let value where target == nil && !value.hasPrefix("-"): target = value; index += 1
                default: throw CLIError("Use why <url|host> [--app <id>] [--json].")
                }
            }
            guard let target else { throw CLIError("Use why <url|host> [--app <id>] [--json].") }
            let report = await ConnectionDoctor.run(target, app: app, policy: await policy())
            if report.steps.isEmpty { throw CLIError(report.verdict + " " + report.next) }
            if args.contains("--json") { print(String(decoding: try doctorJSON(report), as: UTF8.self)) }
            else {
                print("Kilobat · why \(report.host)\(app.map { " · " + $0 } ?? "")")
                for step in report.steps {
                    let mark = switch step.status { case .ok: Terminal.green("✓"); case .warning: Terminal.violet("!"); case .failed: Terminal.rose("✗"); case .skipped: Terminal.dim("–") }
                    print("  \(mark) \(KilobatCLI.pad(step.layer, 18))\(step.detail)")
                }
                print("\n" + Terminal.bold(report.verdict))
                print("→ " + report.next)
            }
            if !report.ok { fflush(stdout); exit(1) }
        case "conditions":
            try KilobatCLI.allow(args, ["--json"])
            let value = await conditions()
            if args.contains("--json") { try WiFiCLI.printObject(value); return }
            let power = value["power"] as? [String: Any] ?? [:]
            let link = (value["connected"] as? Bool) == true ? "\(value["network"] as? String ?? "Network")\((value["interface"] as? String).map { " (\($0))" } ?? "")" : "Offline"
            var flags = [(value["metered"] as? Bool) == true ? "metered" : "unmetered"]
            if (value["lowDataMode"] as? Bool) == true { flags.append("Low Data Mode") }
            if (value["vpn"] as? Bool) == true { flags.append("VPN \(value["vpnInterface"] as? String ?? "")") }
            print("Kilobat · conditions")
            print("  Network   \(link) · \(flags.joined(separator: " · "))")
            let latency = (value["internetLatencyMs"] as? NSNumber).map { "\(Int($0.doubleValue.rounded())) ms" } ?? "no ping reply"
            print("  Internet  \(latency)\((value["internetLossPercent"] as? Double).map { " · \(Int($0))% loss" } ?? "")")
            let battery = (power["batteryPercent"] as? Int).map { " · battery \($0)%" } ?? ""
            print("  Power     \((power["onAC"] as? Bool) == true ? "On power" : "On battery")\(battery) · \(power["thermal"] as? String ?? "unknown") heat\((power["lowPowerMode"] as? Bool) == true ? " · Low Power Mode" : "")")
            let reasons = value["awakeReasons"] as? [String] ?? []
            print("  Awake     \(reasons.isEmpty ? "Kilobat isn’t keeping the Mac awake" : reasons.joined(separator: ", "))")
            print("\n" + (value["advice"] as? String ?? ""))
        default: throw CLIError("Unknown command '\(args[0])'.")
        }
    }

    // MARK: Awake

    static func awake(_ args: [String]) async throws {
        let split = args.firstIndex(of: "--")
        let options = Array(args[..<(split ?? args.endIndex)]), command = split.map { Array(args[($0 + 1)...]) } ?? []
        try KilobatCLI.allow(options, ["--for", "--until-quiet", "--app", "--quiet", "--display", "--json"], valued: ["--for", "--app", "--quiet"])
        func value(_ flag: String) throws -> String? {
            guard let index = options.firstIndex(of: flag) else { return nil }
            guard index + 1 < options.count else { throw CLIError("\(flag) needs a value. Run kilobat awake --help.") }
            return options[index + 1]
        }
        let untilQuiet = options.contains("--until-quiet"), display = options.contains("--display")
        // Piped output gets the JSON summary; a wrapped command's own output stays untouched.
        let json = options.contains("--json") || (Terminal.piped && command.isEmpty)
        if split != nil && command.isEmpty { throw CLIError("Name a command after --, e.g. kilobat awake -- make test.") }
        let duration = try value("--for").map { text -> Double in
            guard let seconds = seconds(text), (1...86_400).contains(seconds) else { throw CLIError("--for takes a duration such as 45s, 90m or 2h, up to 24h.") }
            return seconds
        }
        guard [duration != nil, untilQuiet, !command.isEmpty].filter({ $0 }).count <= 1 else { throw CLIError("Choose one of --for, --until-quiet or -- <command>.") }
        let app = try value("--app"), quiet = try value("--quiet")
        if (app != nil || quiet != nil) && !untilQuiet { throw CLIError("--app and --quiet go with --until-quiet.") }
        if let app, !(app.contains(".") || app.hasPrefix("process:")) { throw CLIError("--app takes a bundle ID such as com.example.App, or process:<name>.") }
        var quietMinutes = 3
        if let quiet {
            guard let seconds = seconds(quiet), case let minutes = Int((seconds / 60).rounded(.up)), (1...60).contains(minutes) else { throw CLIError("--quiet takes 1 to 60 minutes, e.g. 3m.") }
            quietMinutes = minutes
        }

        // Watching one app waits for a first sample, which names it and the helpers that count towards it.
        let traffic = app == nil ? TrafficStore(recordHistory: false) : await KilobatCLI.sampledStore()
        // A registered (unsaved) domain: the CLI never shows notifications, posts webhooks or writes the app's settings.
        let defaults = UserDefaults(suiteName: "co.seifi.kilobat.cli") ?? .standard
        defaults.register(defaults: ["awake.agents": false, "awake.notify": false, "awake.display": display, "awake.quietMinutes": quietMinutes, "awake.webhook": ""])
        let sessions = SessionStore(defaults: defaults)
        var ended: WorkSession?
        sessions.onEnd = { if $0.kind == .awake { ended = $0 } }
        let mode: AwakeMode
        if let duration { mode = .timer(until: Date().addingTimeInterval(duration)) }
        else if untilQuiet { mode = .untilQuiet(app: app, name: app.map { id in traffic.apps.first { $0.id == id }?.name ?? id.replacingOccurrences(of: "process:", with: "") } ?? "") }
        else { mode = .indefinite }
        sessions.start(mode)
        guard sessions.holdingAwake else { traffic.shutdown(); throw CLIError("macOS refused to keep the Mac awake.") }

        var process: Process?
        if !command.isEmpty {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/env"); child.arguments = command
            do { try child.run() } catch { sessions.stop(); traffic.shutdown(); throw CLIError("Could not run \(command[0]): \(error.localizedDescription)") }
            process = child
        }
        // Ctrl-C reaches a wrapped command too; it exits and its status passes through.
        signal(SIGINT) { _ in AwakeCLI.interrupted = true }
        signal(SIGTERM) { _ in AwakeCLI.interrupted = true }
        let live = Terminal.interactive && !json && command.isEmpty
        if live { fputs("\u{1b}[?25l", stdout) }
        else if command.isEmpty && !json { print("Keeping this Mac awake: \(mode.title.lowercased()). Ctrl-C to stop. Closing the lid still sleeps it.") }

        var lastTick = Date(), received: UInt64 = 0, sent: UInt64 = 0, failure: String?
        while ended == nil && failure == nil && !interrupted && process?.isRunning != false {
            try? await Task.sleep(for: .milliseconds(250))
            let now = Date(), elapsed = now.timeIntervalSince(lastTick)
            if elapsed >= 2 {
                if let error = traffic.error, untilQuiet { failure = error; continue }
                if let pid = process?.processIdentifier, process?.isRunning == true {
                    // Apps group processes by name, so a shared app counts by the share of its processes in the command's tree.
                    let family = descendants(of: [pid])
                    for app in traffic.apps where app.rate > 0 {
                        let share = Double(app.processIDs.filter(family.contains).count) / Double(max(1, app.processIDs.count))
                        received += UInt64(app.downloadRate * elapsed * share); sent += UInt64(app.uploadRate * elapsed * share)
                    }
                }
                sessions.tick(apps: traffic.apps, interval: elapsed, now: now)
                lastTick = now
            }
            if live, let session = sessions.awake {
                var parts = ["Awake", TrafficFormat.rate(sessions.watchedRate)]
                switch mode {
                case .timer(let until): parts.insert(clock(until.timeIntervalSince(now)) + " left", at: 1)
                case .untilQuiet(let id, let name):
                    parts.insert(id == nil ? "until quiet" : "until \(name) is quiet", at: 1)
                    parts.append("quiet \(clock(sessions.quietSince.map { now.timeIntervalSince($0) } ?? 0)) of \(clock(Double(quietMinutes * 60)))")
                case .indefinite: parts.append(clock(now.timeIntervalSince(session.start)))
                }
                fputs("\r" + Terminal.violet("◉ ") + parts.joined(separator: " · ") + Terminal.dim(" · Ctrl-C to stop") + "\u{1b}[K", stdout); fflush(stdout)
            }
        }
        if live { fputs("\r\u{1b}[K\u{1b}[?25h", stdout) }
        process?.waitUntilExit()
        if ended == nil { sessions.stop() }
        traffic.shutdown()
        if let failure { throw CLIError("Traffic monitoring failed: \(failure)") }
        guard let session = ended else { return }

        let status = process.map { $0.terminationReason == .uncaughtSignal ? 128 + $0.terminationStatus : $0.terminationStatus }
        if json {
            var object = (try JSONSerialization.jsonObject(with: try DiagnosticsCLI.encode(session))) as? [String: Any] ?? [:]
            if let status {
                object["title"] = "While \(command.joined(separator: " ")) ran"
                object["command"] = command; object["exitStatus"] = status
                object["commandReceived"] = received; object["commandSent"] = sent
            }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            // Beside a wrapped command, the summary goes to stderr so the command's stdout stays clean.
            if status == nil { print(String(decoding: data, as: UTF8.self)) } else { FileHandle.standardError.write(data + Data("\n".utf8)) }
        } else if let status {
            FileHandle.standardError.write(Data("kilobat: stayed awake while \(command[0]) ran · \(clock(session.duration)) · its processes moved ↓ \(TrafficFormat.bytes(received))  ↑ \(TrafficFormat.bytes(sent)) · exit \(status)\n".utf8))
        } else {
            let reason = session.ended == "Turned off" ? "Stopped" : session.ended ?? "Stopped"
            print("✓ \(reason) · awake \(session.summary)")
        }
        if let status { fflush(stdout); exit(status) }
    }

    /// 90m, 2h, 45s or 1h30m; a bare number is minutes.
    static func seconds(_ text: String) -> Double? {
        if let minutes = Double(text) { return minutes > 0 ? minutes * 60 : nil }
        let units: [Character: Double] = ["h": 3600, "m": 60, "s": 1]
        var total = 0.0, number = ""
        for character in text.lowercased() {
            if character.isNumber || character == "." { number.append(character); continue }
            guard let value = Double(number), let unit = units[character] else { return nil }
            total += value * unit; number = ""
        }
        return number.isEmpty && total > 0 ? total : nil
    }
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }
    /// Every process descended from `roots`, roots included.
    static func descendants(of roots: [Int32]) -> Set<Int32> {
        var family = Set(roots), queue = roots
        while let pid = queue.popLast() {
            var children = [Int32](repeating: 0, count: 256)
            let count = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<Int32>.size))
            guard count > 0 else { continue }
            for child in children.prefix(Int(count)) where child > 0 && family.insert(child).inserted { queue.append(child) }
        }
        return family
    }

    // MARK: Sessions and the connection doctor

    /// The app's record of awake sessions and agent runs, newest first.
    static func history(days: Int) -> [WorkSession] {
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat/sessions.json")
        guard let data = try? Data(contentsOf: file), let sessions = try? JSONDecoder().decode([WorkSession].self, from: data) else { return [] }
        let since = Date().addingTimeInterval(-Double(days) * 86_400)
        return sessions.filter { $0.start >= since }.sorted { $0.start > $1.start }
    }

    /// Saved rules plus what only the running app knows: whether the filter enforces them and whether the budget ran out.
    static func policy() async -> ConnectionDoctor.Policy {
        let preferences = TrafficStore(startMonitoring: false).preferences, app = await WiFiCLI.connection()
        // Unrestricted only tracks the budget; it never stops connections.
        let budgetReached = ((app?["budgetUsed"] as? NSNumber)?.doubleValue ?? 0) >= 1 && preferences.profile != .unrestricted
        return ConnectionDoctor.Policy(preferences: preferences, filterActive: app?["filteringActive"] as? Bool ?? false, budgetReached: budgetReached)
    }
    static func doctorJSON(_ report: DoctorReport) throws -> Data {
        var object = (try JSONSerialization.jsonObject(with: try DiagnosticsCLI.encode(report))) as? [String: Any] ?? [:]
        object["ok"] = report.ok
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: Conditions

    struct Path: Sendable { let connected: Bool; let kind: String; let interface: String?; let expensive: Bool; let constrained: Bool }
    static func currentPath() async -> Path {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.pathUpdateHandler = nil; monitor.cancel()
                let kind = path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.wiredEthernet) ? "Ethernet" : path.usesInterfaceType(.cellular) ? "Cellular" : path.status == .satisfied ? "Other" : "None"
                continuation.resume(returning: Path(connected: path.status == .satisfied, kind: kind, interface: path.availableInterfaces.first?.name, expensive: path.isExpensive, constrained: path.isConstrained))
            }
            monitor.start(queue: DispatchQueue(label: "co.seifi.kilobat.path"))
        }
    }

    /// Whether now suits a long run or a big transfer, with one line of advice for an agent. `holdUntil` is the MCP server's own keep_awake.
    static func conditions(holdUntil: Date? = nil) async -> [String: Any] {
        async let path = currentPath()
        async let route = CommandRunner.run("/sbin/route", ["-n", "get", "default"], timeout: 3)
        async let ping = DiagnosticProbe.ping("1.1.1.1", count: 4, interval: 0.25)
        async let assertions = CommandRunner.run("/usr/bin/pmset", ["-g", "assertions"], timeout: 3)
        let (link, internet, power) = (await path, await ping, PowerState.read())
        let interface = DiagnosticProbe.matches(#"interface:\s+(\S+)"#, in: await route.output).first
        let vpn = interface.flatMap { ["utun", "ipsec", "ppp"].contains(where: $0.hasPrefix) ? $0 : nil }
        let reasons = Array(Set(DiagnosticProbe.matches(#"named: "(Kilobat[^"]*)""#, in: await assertions.output))).sorted()

        var advice: [String] = []
        if !link.connected { advice.append("Offline: network tasks will fail until the Mac reconnects.") }
        if link.expensive { advice.append("Metered connection: avoid large downloads and uploads, or ask the user first.") }
        if link.constrained { advice.append("Low Data Mode is on: keep transfers small.") }
        if link.connected, let average = internet.average {
            if (internet.lossPercent ?? 0) >= 5 || average > 150 { advice.append("Unstable internet (\(Int(average)) ms, \(Int(internet.lossPercent ?? 0))% loss): expect slow transfers and retries.") }
        } else if link.connected { advice.append("The internet didn’t answer a ping; some networks block it. If requests fail, run diagnose_connection.") }
        if let vpn { advice.append("Traffic goes through a VPN (\(vpn)); some hosts may be blocked or slower.") }
        if !power.onAC { advice.append("On battery" + (power.batteryPercent.map { " at \($0)%" } ?? "") + ((power.batteryPercent ?? 100) < 25 ? ": plug in before a long run." : ".")) }
        if power.lowPowerMode { advice.append("Low Power Mode is on: builds and transfers run slower.") }
        if ["serious", "critical"].contains(power.thermal) { advice.append("The Mac is running hot (\(power.thermal)): heavy work will be throttled.") }
        if advice.isEmpty { advice.append("Good conditions: online, unmetered, on power.") }

        return ["connected": link.connected, "network": link.kind, "interface": link.interface ?? NSNull(), "metered": link.expensive, "lowDataMode": link.constrained,
                "vpn": vpn != nil, "vpnInterface": vpn ?? NSNull(),
                "internetLatencyMs": internet.average.map { WiFiCLI.tenths($0) } ?? NSNull(), "internetLossPercent": internet.lossPercent ?? NSNull(),
                "power": ["batteryPercent": power.batteryPercent ?? NSNull(), "onAC": power.onAC, "thermal": power.thermal, "lowPowerMode": power.lowPowerMode] as [String: Any],
                "keptAwake": !reasons.isEmpty || holdUntil != nil, "awakeReasons": reasons,
                "awakeUntil": holdUntil.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
                "advice": advice.joined(separator: " ")]
    }
}
