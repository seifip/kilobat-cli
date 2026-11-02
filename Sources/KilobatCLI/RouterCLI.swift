import Foundation
import KilobatCore

/// `kilobat router`: router check-up. Whether the router has been getting slower over days against its own normal,
/// how restarts went, and the verdict. Read-only; the app keeps the history from its background checks.
enum RouterCLI {
    struct Output: Encodable {
        /// The router this Mac used last, first; with --all, every router seen in the last 60 days.
        let routers: [RouterReport]
    }

    static func run(_ args: [String]) async throws {
        let command: RouterCommand
        do { command = try RouterCommand.parse(args) } catch { throw CLIError((error as? DiagnosticError)?.message ?? RouterCommand.usage) }
        switch command {
        case .checkup(let options): try checkup(options)
        case .connect(let kind, let json): try connect(kind, json: json)
        case .devices(let json):
            let report = await home()
            if json { print(String(decoding: try DiagnosticsCLI.encode(report), as: UTF8.self)); return }
            print(text(report))
        case .disconnect(let json): try await disconnect(json: json)
        }
    }

    /// `router connect`: the steps only. Passwords never go on the command line; the app keeps them in its Keychain.
    static func connect(_ kind: RouterKind?, json: Bool) throws {
        let kinds = kind.map { [$0] } ?? RouterKind.connectable
        if json {
            let value = kinds.map { ["kind": $0.rawValue, "name": $0.name, "steps": RouterSetup.steps($0)] as [String: Any] }
            print(String(decoding: try JSONSerialization.data(withJSONObject: ["routers": value, "privacy": RouterSetup.privacy], options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
            return
        }
        print("Connect your router in the Kilobat app (Kilobat Pro): Devices › Connect your router. The CLI never takes a router password.")
        for kind in kinds {
            print("\n\(kind.name)")
            for (index, step) in RouterSetup.steps(kind).enumerated() { print("  \(index + 1). \(step)") }
        }
        print("\n\(RouterSetup.privacy)")
        print("Then: kilobat router devices")
    }

    /// The app's view of the router, which signs in with the Keychain's password; without the app, what it last saved.
    static func home() async -> HomeUsageReport {
        if let data = await AppRelay.ask("router", timeout: .seconds(10)) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            if var report = try? decoder.decode(HomeUsageReport.self, from: data) { report.appRunning = true; return report }
        }
        let saved = HomeUsageStore.load()
        let message = "The Kilobat app isn't running. Open it to read the router; the CLI never signs in to the router itself."
        var report = HomeUsageReport(state: saved.book.routers.isEmpty ? .notConnected : .error, error: saved.book.routers.isEmpty ? nil : message,
                                     note: HomeUsageReport.note(kind: saved.book.routers.last?.kind, perDevice: false, missing: []), pro: false)
        if let router = saved.book.routers.last {
            report.network = router.networkName
            report.router = .init(kind: router.kind, name: router.model ?? router.kind.name, model: router.model, firmware: router.firmware,
                                  address: router.base?.host ?? router.url, measures: "unknown", uptimeSeconds: nil, missing: [])
            if let total = saved.ledger.today(network: router.network)[HomeUsageLedger.home] { report.home = .init(todayDown: total.down, todayUp: total.up) }
        }
        report.appRunning = false
        return report
    }

    static func disconnect(json: Bool) async throws {
        if let data = await AppRelay.ask("router|disconnect", timeout: .seconds(8)),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if json { print(String(decoding: data, as: UTF8.self)); return }
            if let name = value["disconnected"] as? String { print("✓ Disconnected \(name). Its password is gone from the Keychain.") }
            else { print("No router is connected for this network.") }
            return
        }
        let gone = try HomeUsageStore.forget(network: nil)
        if json {
            print(String(decoding: try JSONSerialization.data(withJSONObject: ["disconnected": (gone?.model ?? gone?.kind.name).map { $0 as Any } ?? NSNull(), "appRunning": false], options: [.sortedKeys]), as: UTF8.self))
            return
        }
        guard let gone else { print("No router is connected."); return }
        print("✓ Disconnected \(gone.model ?? gone.kind.name) on \(gone.networkName). The app removes its password from the Keychain when it next opens.")
    }

    static func text(_ report: HomeUsageReport) -> String {
        func rate(_ value: Double?) -> String { value.map(TrafficFormat.rate) ?? "—" }
        func bytes(_ down: UInt64?, _ up: UInt64?) -> String {
            guard let down, let up else { return "—" }
            return "↓ \(TrafficFormat.bytes(down)) ↑ \(TrafficFormat.bytes(up))"
        }
        switch report.state {
        case .notConnected: return "No router connected. " + report.note + "\nSetup steps: kilobat router connect"
        case .notHome: return "\(report.network ?? "This network") isn't marked as home, so Kilobat doesn't read its router here."
        case .needsPro: return "Reading your router is part of Kilobat Pro."
        default: break
        }
        var lines: [String] = []
        if let router = report.router {
            let measures = router.measures == "perDevice" ? "each device" : router.measures == "wholeHome" ? "whole home only" : "not read yet"
            var head = "\(router.name) · \(router.address) · \(measures)"
            if let uptime = router.uptimeSeconds { head += " · up \(Duration.seconds(uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2)))" }
            lines.append(head)
        }
        if let error = report.error { lines.append("! \(error)") }
        if let update = report.router?.update {
            if let line = update.line { lines.append("  ↑ \(line)" + (update.url.map { " Update in the router: \($0)" } ?? "")) }
            else if let installed = update.installed { lines.append("  \(update.product) \(installed), up to date as far as the router knows") }
        }
        if let home = report.home {
            lines.append("  Home now ↓ \(rate(home.down)) ↑ \(rate(home.up)) · today \(bytes(home.todayDown, home.todayUp))")
        }
        if !report.devices.isEmpty {
            lines.append("  \(KilobatCLI.pad("DEVICE", 30))\(KilobatCLI.pad("↓ NOW", 12))\(KilobatCLI.pad("↑ NOW", 12))TODAY")
            for device in report.devices {
                var name = device.name
                if device.thisMac { name += " (this Mac)" } else if device.pairedMac { name += " (Kilobat)" }
                var line = "  \(KilobatCLI.pad(name, 30))\(KilobatCLI.pad(rate(device.down), 12))\(KilobatCLI.pad(rate(device.up), 12))\(bytes(device.todayDown, device.todayUp))"
                if let apps = device.apps, !apps.isEmpty { line += "  \(apps.joined(separator: ", "))" }
                if !device.active { line += "  offline" }
                lines.append(line)
            }
        }
        if let others = report.others { lines.append("  \(KilobatCLI.pad("Other devices", 30))\(KilobatCLI.pad(rate(others.down), 12))\(rate(others.up))") }
        lines.append(report.note)
        return lines.joined(separator: "\n")
    }

    static func checkup(_ options: RouterReport.Options) throws {
        let output = reports(all: options.all)
        if options.json { print(String(decoding: try DiagnosticsCLI.encode(output), as: UTF8.self)); return }
        guard !output.routers.isEmpty else {
            print("No router history yet. With the Kilobat app running, each background check adds to it; after 7 days with quiet checks Kilobat knows what's normal for your router.")
            return
        }
        for (index, report) in output.routers.enumerated() {
            if index > 0 { print("") }
            print(text(report))
        }
    }

    static func reports(all: Bool, now: Date = Date()) -> Output {
        let saved = RouterWatch.load()
        let ordered = saved.routers.sorted { ($0.id == saved.current ? 1 : 0, $0.lastSeen) > ($1.id == saved.current ? 1 : 0, $1.lastSeen) }
        return Output(routers: (all ? ordered : Array(ordered.prefix(1))).map { RouterReport($0, now: now) })
    }

    static func text(_ report: RouterReport) -> String {
        let ms = RouterReport.ms
        var lines = ["\(report.name)" + (report.mac.map { " · router \($0)" } ?? "")]
        lines.append("  \(report.state == .degraded ? "✗" : report.state == .normal ? "✓" : "·") \(report.headline)")
        for line in [report.detail, report.advice, report.followUp].compactMap({ $0 }) { lines.append("  \(line)") }
        if let firmware = report.firmware { lines.append("  · \(firmware.line)" + (firmware.guide.map { " How: \($0)" } ?? "")) }
        if let uptime = report.uptimeSeconds {
            lines.append("  Up for \(Duration.seconds(uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 2))), as the connected router says")
        }
        if let base = report.baseline {
            var normal = ["router \(ms(base.routerMs)) (p90 \(ms(base.routerP90Ms)))", String(format: "loss %.1f%%", base.lossPercent)]
            if let dns = base.dnsMs { normal.append("lookups \(ms(dns))") }
            normal.append(String(format: "%.1f drops a day", base.dropsPerDay))
            lines.append("  Normal (\(base.days) days): " + normal.joined(separator: " · "))
        }
        if !report.recent.isEmpty {
            lines.append("  Recent:  " + report.recent.map { day in
                "\(day.day.formatted(.dateTime.weekday(.abbreviated).day())) \(ms(day.routerMs))" + (day.drops > 0 ? ", \(day.drops) drops" : "")
            }.joined(separator: " · "))
        }
        if report.trend.count > 3 { lines.append("  Trend:   " + report.trend.map { String(format: "%.0f", $0.routerMs) }.joined(separator: " ") + " ms (last \(report.trend.count) days with data)") }
        if !report.restarts.isEmpty {
            lines.append("  Restarts:")
            for restart in report.restarts.prefix(5) {
                let how = restart.source == "button" ? "you restarted it" : restart.source == "router" ? "the router restarted (its own uptime)" : "went away for \(Int(restart.outageSeconds ?? 0)) s and came back"
                let outcome = switch restart.outcome {
                case "fixed": "fixed it"
                case "helped": "helped"
                case "didntHelp": "didn't help"
                case "unclear": "unclear"
                case "noProblem": "nothing was wrong before"
                default: "checking"
                }
                let numbers = [restart.beforeMs.map { "before \(ms($0))" }, restart.afterMs.map { "after \(ms($0))" }].compactMap { $0 }.joined(separator: ", ")
                lines.append("    \(restart.date.formatted(date: .abbreviated, time: .shortened))  \(how): \(outcome)" + (numbers.isEmpty ? "" : " (\(numbers))"))
            }
        }
        return lines.joined(separator: "\n")
    }
}
