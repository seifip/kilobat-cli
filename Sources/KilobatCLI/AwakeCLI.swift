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
                let title = session.title + (session.project.map { " · " + $0 } ?? "")
                print("  \(KilobatCLI.pad(session.start.formatted(date: .abbreviated, time: .shortened), 22))\(KilobatCLI.pad(title, 24))\(session.summary)\(ended)")
                let top = session.apps.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) \(TrafficFormat.bytes($0.value))" }
                let hosts = session.destinations.isEmpty ? [] : [session.destinations.count == 1 ? "1 host" : "\(session.destinations.count) hosts"]
                let extra = top + hosts + [session.note, session.install].compactMap { $0 }
                if !extra.isEmpty { print(Terminal.dim("  \(String(repeating: " ", count: 46))" + extra.joined(separator: " · "))) }
            }
        case "why":
            var target: String?, app: String?, proxy: String?, context: ConnectionDoctor.Context?, failedAt: Date?, index = 1
            let usage = "Use why <url|host> [--app <id>] [--proxy <url>] [--context container|vm|remote|provider] [--failed-at <time>] [--json]."
            while index < args.count {
                switch args[index] {
                case "--json": index += 1
                case "--app":
                    guard index + 1 < args.count, args[index + 1].contains(".") || args[index + 1].hasPrefix("process:") else { throw CLIError("--app takes a bundle ID such as com.example.App, or process:<name>.") }
                    app = args[index + 1]; index += 2
                case "--proxy":
                    guard index + 1 < args.count, !args[index + 1].hasPrefix("-") else { throw CLIError("--proxy takes the proxy the app uses, such as http://127.0.0.1:7890 or socks5://127.0.0.1:1080.") }
                    proxy = args[index + 1]; index += 2
                case "--context":
                    guard index + 1 < args.count, let value = ConnectionDoctor.Context(rawValue: args[index + 1]) else { throw CLIError("--context takes container, vm, remote or provider.") }
                    context = value; index += 2
                case "--failed-at":
                    guard index + 1 < args.count, let value = ConnectionDoctor.failureTime(args[index + 1]) else { throw CLIError("--failed-at takes when the app failed, such as 14:05 or 2026-10-29T14:05:00Z, not a time still ahead.") }
                    failedAt = value; index += 2
                case let value where target == nil && !value.hasPrefix("-"): target = value; index += 1
                default: throw CLIError(usage)
                }
            }
            guard let target else { throw CLIError(usage) }
            let report = await ConnectionDoctor.run(target, app: app, proxy: proxy, context: context, policy: await policy(), failedAt: failedAt)
            if report.steps.isEmpty { throw CLIError(report.verdict + " " + report.next) }
            if args.contains("--json") { print(String(decoding: try doctorJSON(report), as: UTF8.self)) }
            else {
                let client = report.client.map { " · " + $0.name + ($0.version.map { " " + $0 } ?? "") } ?? ""
                print("Kilobat · why \(report.target)\(client)")
                print(Terminal.dim("  " + doctorRequest(report)))
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
            let plugged = value["awakeOnPower"] as? [String: Any]
            let onPower = (plugged?["enabled"] as? Bool) == true && (plugged?["active"] as? Bool) != true ? " · stays awake whenever plugged in" : ""
            print("  Awake     \(reasons.isEmpty ? "Kilobat isn’t keeping the Mac awake" : reasons.joined(separator: ", "))\(onPower)")
            let hold = value["lidHold"] as? [String: Any], until = (hold?["until"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            print("  Lid       " + (until.map { "Can close: Kilobat keeps the Mac running until " + $0.formatted(date: .omitted, time: .shortened) } ?? ((value["lidClosedAllowed"] as? Bool) == true ? "Allowed for agent runs; closing it now sleeps the Mac" : "Closing it sleeps the Mac")))
            let updaters = value["updaters"] as? [String: Any]
            print("  Updaters  " + ((updaters?["paused"] as? Bool) == true ? "Paused on this metered network · kilobat updaters"
                : (updaters?["pauseOnMetered"] as? Bool) == true ? "Running here; paused on metered networks while the filter is on" : "Never paused"))
            print("  Kill sw.  " + ProxyCLI.killSwitchLine(value["killSwitch"] as? [String: Any] ?? [:]))
            print("\n" + (value["advice"] as? String ?? ""))
        default: throw CLIError("Unknown command '\(args[0])'.")
        }
    }

    // MARK: Awake

    static func awake(_ args: [String]) async throws {
        let options: AwakeOptions
        do { options = try AwakeOptions.parse(args) } catch let invalid as AwakeOptions.Invalid { throw CLIError(invalid.message) }
        let (duration, untilQuiet, app, quietMinutes, display, command) = (options.duration, options.untilQuiet, options.app, options.quietMinutes, options.display, options.command)
        // Piped output gets the JSON summary; a wrapped command's own output stays untouched.
        let json = options.json || (Terminal.piped && command.isEmpty)
        if let target = options.frontmost { try await whileFrontmost(target, options: options, json: json); return }
        // The lid needs the app's power helper, so ask before anything starts.
        var lid: LidLease?
        if options.lidClosed {
            let until = Date().addingTimeInterval(min(duration ?? LidPolicy.longest, LidPolicy.longest))
            lid = try await holdLid(until: until, reason: command.isEmpty ? "kilobat awake" : "While \(command[0]) runs")
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
        else if command.isEmpty && !json { print("Keeping this Mac awake: \(mode.title.lowercased()). Ctrl-C to stop. " + (lid.map { "The lid can close: Kilobat keeps it running \($0.summary)." } ?? "Closing the lid still sleeps it.")) }

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
                var parts = ["Awake", TrafficFormat.rate(sessions.watchedRate)] + (lid == nil ? [] : ["lid closed OK"])
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
        // The app also lets go once this process is gone; this is just sooner.
        if lid != nil { _ = await AppRelay.ask(LidRelayRequest.release(owner: getpid()).action, timeout: .seconds(2)) }
        if let failure { throw CLIError("Traffic monitoring failed: \(failure)") }
        guard let session = ended else { return }

        let status = process.map { $0.terminationReason == .uncaughtSignal ? 128 + $0.terminationStatus : $0.terminationStatus }
        if json {
            var object = (try JSONSerialization.jsonObject(with: try DiagnosticsCLI.encode(session))) as? [String: Any] ?? [:]
            object["lidClosed"] = lid != nil
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

    /// `awake --while-frontmost <app>`: holds only while that app is in front, from the workspace's activation events.
    /// Switching away lets go, coming back holds again; it ends when the app quits, --for runs out, the battery reaches 20% or on Ctrl-C.
    static func whileFrontmost(_ target: String, options: AwakeOptions, json: Bool) async throws {
        guard let (id, name) = FrontmostWatcher.resolve(target) else {
            throw CLIError("No app named “\(target)”. Use its name as in Applications, e.g. Keynote, or a bundle ID such as com.apple.Preview.")
        }
        let defaults = UserDefaults(suiteName: "co.seifi.kilobat.cli") ?? .standard
        defaults.register(defaults: ["awake.agents": false, "awake.notify": false, "awake.webhook": ""])
        let sessions = SessionStore(defaults: defaults), start = Date()
        let condition = FrontmostCondition(app: id, name: name, display: options.display, until: options.duration.map { start.addingTimeInterval($0) })
        sessions.watchFrontmost(condition, now: start)
        signal(SIGINT) { _ in AwakeCLI.interrupted = true }
        signal(SIGTERM) { _ in AwakeCLI.interrupted = true }
        let screen = options.display ? "screen stays on" : "screen may dim"
        let live = Terminal.interactive && !json
        if live { fputs("\u{1b}[?25l", stdout) }
        else if !json { print("Keeping this Mac awake while \(name) is in front (\(screen)). Ctrl-C to stop. Closing the lid still sleeps it.") }

        var held = 0.0, last = start, lastTick = start
        while sessions.frontmost != nil && !interrupted {
            try? await Task.sleep(for: .milliseconds(250))
            let now = Date()
            if sessions.holdingFrontmost { held += now.timeIntervalSince(last) }
            last = now
            // The timer and the battery floor are checked here; focus changes arrive as events.
            if now.timeIntervalSince(lastTick) >= 2 { sessions.tick(apps: [], interval: now.timeIntervalSince(lastTick), now: now); lastTick = now }
            if live {
                let line = sessions.holdingFrontmost ? Terminal.violet("◉ ") + "Awake · \(name) in front · \(screen)" : Terminal.dim("○ ") + "Waiting for \(name) to come to the front"
                let left = condition.until.map { " · " + clock($0.timeIntervalSince(now)) + " left" } ?? ""
                fputs("\r" + line + " · held \(clock(held))" + left + Terminal.dim(" · Ctrl-C to stop") + "\u{1b}[K", stdout); fflush(stdout)
            }
        }
        if live { fputs("\r\u{1b}[K\u{1b}[?25h", stdout) }
        if sessions.frontmost != nil { sessions.stopFrontmost() }
        let end = Date(), ended = sessions.frontmostEnded ?? "Turned off"
        if json {
            let formatter = ISO8601DateFormatter()
            let object: [String: Any] = ["kind": "frontmost", "app": id, "name": name, "display": options.display, "start": formatter.string(from: start), "end": formatter.string(from: end),
                                         "until": condition.until.map { formatter.string(from: $0) } ?? NSNull(), "ended": ended, "heldSeconds": Int(held.rounded())]
            print(String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
        } else {
            print("✓ \(ended == "Turned off" ? "Stopped" : ended) · held awake \(clock(held)) of \(clock(end.timeIntervalSince(start))) while \(name) was in front")
        }
    }

    /// Asks the app for a lid hold owned by this process; the app's answer says why when it can't.
    static func holdLid(until: Date, reason: String) async throws -> LidLease {
        let setup = "Turn on “Allow running with the lid closed” in Kilobat Settings › Awake & agents."
        guard AppRelay.appRunning else { throw CLIError("--lid-closed needs the Kilobat app running. Open it, then: " + setup) }
        guard let data = await AppRelay.ask(LidRelayRequest.hold(until: until, owner: getpid(), reason: reason).action, timeout: .seconds(4)),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError("The Kilobat app didn’t answer. --lid-closed needs Kilobat 1.3 or later.")
        }
        guard reply["holding"] as? Bool == true, let text = reply["until"] as? String, let until = ISO8601DateFormatter().date(from: text) else {
            throw CLIError(reply["error"] as? String ?? setup)
        }
        return LidLease(until: until, reason: reason, batteryFloor: reply["batteryFloor"] as? Int ?? 20, onlyOnAC: reply["onlyOnAC"] as? Bool ?? false)
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
        // The app reports the current network's effective cost, which decides whether updaters are paused.
        // While the kill switch blocks, the doctor names it; the filter's own exemptions follow from the policy.
        let killSwitch = app?["killSwitch"] as? [String: Any], blocking = killSwitch?["state"] as? String == "blocking"
        return ConnectionDoctor.Policy(preferences: preferences, filterActive: app?["filteringActive"] as? Bool ?? false, budgetReached: budgetReached,
                                       metered: app?["metered"] as? Bool ?? false,
                                       killSwitch: KillSwitchPolicy(armed: blocking, vpnDown: blocking, allowLAN: killSwitch?["allowLAN"] as? Bool ?? true))
    }
    /// What was sent, over which path, and when, against when the app failed: "HEAD through LM Studio’s own proxy (127.0.0.1:7890) · checked 14:31 · app failed 14:02".
    static func doctorRequest(_ report: DoctorReport) -> String {
        let path: String? = report.path.map { path in
            (path.kind == .direct ? "directly" : "through " + ConnectionDoctor.via(path, app: report.client?.name)) + (path.untested.map { ", not through \($0)" } ?? "")
        }
        func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
        return [[report.method, path].compactMap { $0 }.joined(separator: " "), "checked " + time(report.date), report.failedAt.map { "app failed " + time($0) }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
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
        async let exit = ExitPath.current()
        async let ping = DiagnosticProbe.ping("1.1.1.1", count: 4, interval: 0.25)
        async let assertions = CommandRunner.run("/usr/bin/pmset", ["-g", "assertions"], timeout: 3)
        async let answer = AppRelay.ask("connection", timeout: .seconds(3))
        let (link, internet, power) = (await path, await ping, PowerState.read())
        let app = await answer.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let store = TrafficStore(startMonitoring: false), cost = WiFiCLI.currentCost(store, app: app), metered = cost.metered(os: link.expensive)
        // Paused only while the app's network filter enforces it.
        let updatersPaused = UpdaterPause.active(store.preferences, metered: metered) && app?["filteringActive"] as? Bool == true
        let exitPath = await exit
        let vpn = exitPath.tunnel ? exitPath.interface : nil
        let killSwitch = ProxyCLI.killSwitch(app)
        let reasons = Array(Set(DiagnosticProbe.matches(#"named: "(Kilobat[^"]*)""#, in: await assertions.output))).sorted()

        var advice: [String] = []
        if !link.connected { advice.append("Offline: network tasks will fail until the Mac reconnects.") }
        if killSwitch["state"] as? String == "blocking" { advice.append("The VPN is down and Kilobat’s kill switch blocks new connections until it’s back: downloads and requests will fail. Ask the user to reconnect their VPN; don’t turn the kill switch off for them.") }
        if metered { advice.append("Metered connection\(cost == .metered ? " (marked by the user)" : ""): avoid large downloads and uploads, or ask the user first.") }
        if updatersPaused { advice.append("Kilobat pauses app and system updaters here; apps that update from inside themselves still can.") }
        if link.constrained { advice.append("Low Data Mode is on: keep transfers small.") }
        if link.connected, let average = internet.average {
            if (internet.lossPercent ?? 0) >= 5 || average > 150 { advice.append("Unstable internet (\(Int(average)) ms, \(Int(internet.lossPercent ?? 0))% loss): expect slow transfers and retries.") }
        } else if link.connected { advice.append("The internet didn’t answer a ping; some networks block it. If requests fail, run diagnose_connection.") }
        if let vpn { advice.append("Traffic goes through a VPN (\(exitPath.vpnName.map { "\($0), \(vpn)" } ?? vpn)); some hosts may be blocked or slower.") }
        else if exitPath.vpn == .partial { advice.append("\(exitPath.vpnName ?? "A VPN") is connected but the default route doesn't use it; only some destinations go through it.") }
        if !power.onAC { advice.append("On battery" + (power.batteryPercent.map { " at \($0)%" } ?? "") + ((power.batteryPercent ?? 100) < 25 ? ": plug in before a long run." : ".")) }
        if power.lowPowerMode { advice.append("Low Power Mode is on: builds and transfers run slower.") }
        if ["serious", "critical"].contains(power.thermal) { advice.append("The Mac is running hot (\(power.thermal)): heavy work will be throttled.") }
        if advice.isEmpty { advice.append("Good conditions: online, unmetered, on power.") }

        let vpnFields: [String: Any] = ["vpn": vpn != nil, "vpnInterface": vpn ?? NSNull(), "vpnName": exitPath.vpnName ?? NSNull(), "vpnConnected": exitPath.connected]
        return cost.fields(os: link.expensive).merging(vpnFields) { $1 }.merging(["connected": link.connected, "network": link.kind, "interface": link.interface ?? NSNull(), "lowDataMode": link.constrained,
                "internetLatencyMs": internet.average.map { WiFiCLI.tenths($0) } ?? NSNull(), "internetLossPercent": internet.lossPercent ?? NSNull(),
                "power": ["batteryPercent": power.batteryPercent ?? NSNull(), "onAC": power.onAC, "thermal": power.thermal, "lowPowerMode": power.lowPowerMode] as [String: Any],
                "keptAwake": !reasons.isEmpty || holdUntil != nil, "awakeReasons": reasons,
                "awakeUntil": holdUntil.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
                // The setting is saved; whether its session is running now only the app knows.
                "awakeOnPower": ["enabled": KilobatCLI.appDefaults.bool(forKey: "awake.power"), "display": KilobatCLI.appDefaults.bool(forKey: "awake.display"),
                                 "active": app?["awakeByPower"] as? Bool ?? false] as [String: Any],
                // Only the app knows; it reports both when it runs.
                "lidClosedAllowed": app?["lidClosedAllowed"] as? Bool ?? false, "lidHold": app?["lidHold"] ?? NSNull(),
                "updaters": ["pauseOnMetered": UpdaterPause.enabled(store.preferences), "paused": updatersPaused] as [String: Any],
                "killSwitch": killSwitch,
                "advice": advice.joined(separator: " ")]) { $1 }
    }
}
