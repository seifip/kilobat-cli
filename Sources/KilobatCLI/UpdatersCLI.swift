import Foundation
import KilobatCore

/// `updaters`: which updaters Kilobat pauses on metered networks, which update bytes still got through, and which apps
/// update from inside their own process.
@MainActor enum UpdatersCLI {
    static func run(_ args: [String]) async throws {
        let json = args.contains("--json"), rest = Array(args.dropFirst()).filter { $0 != "--json" }
        let store = TrafficStore(startMonitoring: false)
        switch rest {
        case []:
            let value = await report(store)
            if json { try WiFiCLI.printObject(object(value)); return }
            print(lines(value).joined(separator: "\n"))
        case ["on"], ["off"]:
            let result = try await set(rest[0] == "on", store: store)
            if json { try WiFiCLI.printObject(result); return }
            print("✓ " + (result["effect"] as? String ?? ""))
        default: throw CLIError("Use updaters [--json], or updaters on|off.")
        }
    }

    /// Turns pausing on or off; says what that means on the current network.
    static func set(_ on: Bool, store: TrafficStore) async throws -> [String: Any] {
        store.preferences.pauseUpdaters = on ? nil : false
        let metered = await metered(store, app: await WiFiCLI.connection())
        let paused = UpdaterPause.active(store.preferences, metered: metered)
        let effect = !on ? "Updaters run on every network again."
            : paused ? "Updaters are paused on this metered network while the Kilobat app’s network filter is on."
            : metered ? "On. The Unrestricted profile allows every connection, so nothing is paused right now."
            : "On. Updaters will wait whenever this Mac is on a metered network."
        return ["enabled": on, "metered": metered, "paused": paused, "effect": effect]
    }

    /// The running app's report, which counts bytes on this network; without the app, the setting and what is installed.
    static func report(_ store: TrafficStore) async -> UpdaterPause.Report {
        if let data = await AppRelay.ask("updaters", timeout: .seconds(3)), let report = try? JSONDecoder().decode(UpdaterPause.Report.self, from: data) { return report }
        return UpdaterPause.report(store.preferences, metered: await metered(store, app: nil), filterActive: nil, apps: nil, delegations: [],
                                   events: FilterEventJournal().events, inProcess: UpdaterPause.inProcessApps())
    }
    static func metered(_ store: TrafficStore, app: [String: Any]?) async -> Bool {
        if let metered = app?["metered"] as? Bool { return metered }
        async let path = AwakeCLI.currentPath()
        return WiFiCLI.currentCost(store, app: app).metered(os: await path.expensive)
    }

    /// The report's JSON, with null where only the running app could say.
    static func object(_ report: UpdaterPause.Report) throws -> [String: Any] {
        var value = try JSONSerialization.jsonObject(with: try DiagnosticsCLI.encode(report)) as? [String: Any] ?? [:]
        for key in ["filterActive", "gotThrough"] where value[key] == nil { value[key] = NSNull() }
        return value
    }

    static func lines(_ report: UpdaterPause.Report) -> [String] {
        let filter = report.filterActive.map { $0 ? "filter on" : "filter off" } ?? "filter state unknown without the app"
        var lines = ["Kilobat · updaters",
                     "  Pause on metered networks: \(report.enabled ? "on" : "off") · \(report.metered ? "metered" : "unmetered") · \(filter)",
                     "  " + report.summary, "", "Covered"]
        for helper in report.covered {
            lines.append("  \(KilobatCLI.pad(helper.name, 24))\(helper.downloads ? "" : Terminal.dim("installs only · "))\(helper.detail)")
        }
        lines += ["", "Got through on this network"]
        switch report.gotThrough {
        case nil: lines.append(Terminal.dim("  Open the Kilobat app to count them; it measures each process’s bytes."))
        case let rows? where rows.isEmpty: lines.append("  No update bytes seen on this network.")
        case let rows?:
            for row in rows {
                let shared = row.shared ? Terminal.dim(" · shared with other downloads, for " + row.forUpdaters.joined(separator: ", ")) : ""
                lines.append("  \(KilobatCLI.pad(row.name, 24))\(TrafficFormat.bytes(row.bytes))\(shared)")
            }
        }
        if report.pausedConnections > 0 { lines.append("  Paused \(report.pausedConnections) updater connection\(report.pausedConnections == 1 ? "" : "s") in the last 24 hours.") }
        lines += ["", "Update from inside the app, so can’t be paused separately"]
        if report.inProcess.isEmpty { lines.append("  None found in Applications.") }
        for updater in ["Sparkle", "Squirrel"] {
            let names = report.inProcess.filter { $0.updater == updater }.map(\.name)
            if !names.isEmpty { lines.append("  \(KilobatCLI.pad(updater, 10))" + names.joined(separator: ", ")) }
        }
        lines += ["", Terminal.dim(report.limits)]
        return lines
    }
}
