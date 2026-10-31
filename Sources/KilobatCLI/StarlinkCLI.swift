import Foundation
import KilobatCore

/// `kilobat starlink`: the Starlink dish on this network, read straight from it, plus the outage log the app keeps.
/// Read-only: it never stows, reboots or changes the dish.
@MainActor enum StarlinkCLI {
    static let usage = "Use starlink [--hours 1…720] [--json]."

    static func run(_ args: [String]) async throws {
        try KilobatCLI.allow(args, ["--json", "--hours"], valued: ["--hours"])
        var hours = 24
        if let index = args.firstIndex(of: "--hours") {
            guard index + 1 < args.count, let value = Int(args[index + 1]), (1...720).contains(value) else { throw CLIError(usage) }
            hours = value
        }
        let reading = await read(hours: hours)
        if args.contains("--json") { try WiFiCLI.printObject(json(reading, hours: hours)); return }
        print(text(reading, hours: hours))
    }

    struct Reading {
        let status: StarlinkStatus?
        let history: StarlinkHistory?
        let map: StarlinkSkyMap?
        let outages: [StarlinkOutage]
    }

    static func read(hours: Int) async -> Reading {
        var journal = StarlinkJournal.load()
        guard let status = await Starlink.status() else {
            return Reading(status: nil, history: nil, map: nil, outages: journal.outages.filter { $0.end >= Date().addingTimeInterval(-Double(hours) * 3600) })
        }
        async let history = Starlink.history()
        async let map = Starlink.obstructionMap()
        let (recent, sky) = await (history, map)
        journal.merge((recent?.outages ?? []) + (status.outage.map { [$0] } ?? []))
        let since = Date().addingTimeInterval(-Double(hours) * 3600)
        return Reading(status: status, history: recent, map: sky, outages: journal.outages.filter { $0.end >= since })
    }

    static func json(_ reading: Reading, hours: Int) -> [String: Any] {
        func round(_ value: Double?) -> Any { value.map(WiFiCLI.tenths) ?? NSNull() }
        func percent(_ value: Double?) -> Any { value.map { WiFiCLI.tenths($0 * 100) } ?? NSNull() }
        var result: [String: Any] = ["present": reading.status != nil, "hours": hours]
        let evidence = StarlinkEvidence.make(outages: reading.outages, status: reading.status, since: Date().addingTimeInterval(-Double(hours) * 3600))
        result["outages"] = reading.outages.reversed().prefix(200).map { outage -> [String: Any] in
            ["start": ISO8601DateFormatter().string(from: outage.start), "seconds": WiFiCLI.tenths(outage.seconds), "cause": outage.cause.rawValue, "side": outage.side.rawValue,
             "didSwitchSatellite": outage.didSwitch.map { $0 as Any } ?? NSNull()]
        }
        result["outageSeconds"] = ["setup": WiFiCLI.tenths(evidence.setupSeconds), "network": WiFiCLI.tenths(evidence.networkSeconds), "dish": WiFiCLI.tenths(evidence.dishSeconds)]
        guard let status = reading.status else {
            result["message"] = "No Starlink dish answered at 192.168.100.1. Outages are from the log the Kilobat app keeps."
            return result
        }
        result["status"] = [
            "state": status.state.rawValue, "online": status.online, "hardware": status.hardware ?? NSNull(), "software": status.software ?? NSNull(),
            "uptimeSeconds": round(status.uptimeSeconds), "popLatencyMs": round(status.popLatencyMs), "popDropPercent": percent(status.popDropRate),
            "downlinkMbps": round(status.downlinkBps.map { $0 / 1e6 }), "uplinkMbps": round(status.uplinkBps.map { $0 / 1e6 }),
            "alerts": status.alerts.map { ["alert": $0.rawValue, "title": $0.title, "severity": $0.severity.rawValue, "advice": $0.advice] },
            "updatePending": status.updatePending, "mobility": status.mobility ?? NSNull(), "ethernetMbps": status.ethernetMbps.map { $0 as Any } ?? NSNull(),
            "treatAsMetered": status.treatAsMetered.map { $0 as Any } ?? NSNull(),
            "pointing": ["azimuth": round(status.azimuth), "elevation": round(status.elevation)],
        ] as [String: Any]
        var obstruction: [String: Any] = [
            "fractionPercent": percent(status.fractionObstructed), "currentlyObstructed": status.currentlyObstructed.map { $0 as Any } ?? NSNull(),
            "measuredOverSeconds": round(status.obstructionValidSeconds), "prolongedEverySeconds": round(status.obstructionIntervalSeconds), "prolongedForSeconds": round(status.obstructionDurationSeconds),
        ]
        if let map = reading.map {
            obstruction["map"] = ["rows": map.rows, "columns": map.columns, "frame": map.earthFrame ? "earth" : "dish", "mapped": map.mapped, "blockedPercent": WiFiCLI.tenths(map.blockedShare * 100),
                                  "blocked": map.blockedSectors.map { ["direction": StarlinkSkyMap.direction($0.index), "percent": WiFiCLI.tenths($0.share * 100), "elevation": round($0.elevation)] },
                                  "advice": map.advice(mobile: status.mobility != "stationary")] as [String: Any]
        }
        result["obstruction"] = obstruction
        if let history = reading.history {
            let latency = history.latencyMs.compactMap { $0 }.sorted()
            result["history"] = ["seconds": history.seconds,
                                 "popLatencyMs": ["median": round(latency.isEmpty ? nil : latency[latency.count / 2]), "p95": round(latency.isEmpty ? nil : latency[min(latency.count - 1, latency.count * 95 / 100)])],
                                 "allDevicesBytes": ["download": Int(history.bytes.down), "upload": Int(history.bytes.up)]] as [String: Any]
        }
        return result
    }

    static func text(_ reading: Reading, hours: Int) -> String {
        guard let status = reading.status else {
            var lines = ["No Starlink dish answered at 192.168.100.1."]
            if !reading.outages.isEmpty { lines += ["", "From the app's log (last \(hours) h):"] + outageLines(reading.outages, hours: hours) }
            return lines.joined(separator: "\n")
        }
        func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "—" }
        func mbps(_ bps: Double?) -> String { bps.map { String(format: $0 < 10e6 ? "%.1f Mbps" : "%.0f Mbps", $0 / 1e6) } ?? "—" }
        let state = status.online ? Terminal.blue(status.stateTitle) : Terminal.rose(status.stateTitle)
        var head = "Starlink · \(state)"
        if let software = status.software { head += " · software \(software)" }
        if let uptime = status.uptimeSeconds { head += " · up \(Duration.seconds(uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2)))" }
        var lines = [head]
        lines.append(pad("Ground station") + "\(ms(status.popLatencyMs)) · drop \(String(format: "%.1f%%", (status.popDropRate ?? 0) * 100))")
        lines.append(pad("Live") + "↓ \(mbps(status.downlinkBps))  ↑ \(mbps(status.uplinkBps))  (every device on the dish)")
        if let fraction = status.fractionObstructed {
            var line = pad("Obstructed") + String(format: "%.1f%% of the time", fraction * 100)
            if let valid = status.obstructionValidSeconds, valid > 0 { line += " over \(Duration.seconds(valid).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 1)))" }
            line += status.currentlyObstructed == true ? " · " + Terminal.rose("blocked now") : " · clear now"
            lines.append(line)
        }
        if let every = status.obstructionIntervalSeconds, let duration = status.obstructionDurationSeconds {
            lines.append(pad("Prolonged") + String(format: "%.1f s blocked every %@", duration, Duration.seconds(every).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1))))
        }
        if status.alerts.isEmpty { lines.append(pad("Alerts") + "none") }
        for (index, alert) in status.alerts.enumerated() {
            lines.append(pad(index == 0 ? "Alerts" : "") + (alert.severity == .problem ? Terminal.rose(alert.title) : alert.title) + Terminal.dim(" · " + alert.advice))
        }
        if let map = reading.map {
            lines += ["", "Sky map" + Terminal.dim(map.earthFrame ? " (north up)" : " (as the dish faces)")] + sky(map)
            lines.append(map.advice(mobile: status.mobility != "stationary"))
        }
        if let history = reading.history, history.seconds > 0 {
            let bytes = history.bytes
            lines += ["", "Last \(history.seconds / 60) min through the dish (all devices): ↓ \(TrafficFormat.bytes(UInt64(bytes.down)))  ↑ \(TrafficFormat.bytes(UInt64(bytes.up)))"]
        }
        lines += ["", "Outages, last \(hours) h:"] + (reading.outages.isEmpty ? ["  none logged"] : outageLines(reading.outages, hours: hours))
        return lines.joined(separator: "\n")
    }

    static func pad(_ text: String) -> String { text.padding(toLength: 16, withPad: " ", startingAt: 0) }

    static func outageLines(_ outages: [StarlinkOutage], hours: Int) -> [String] {
        let evidence = StarlinkEvidence.make(outages: outages, status: nil, since: Date().addingTimeInterval(-Double(hours) * 3600))
        let totals = [(StarlinkOutage.Side.setup, evidence.setupSeconds), (.network, evidence.networkSeconds), (.dish, evidence.dishSeconds)]
            .map { "\($0.0.title) \(length($0.1))" }.joined(separator: " · ")
        return ["  " + totals] + outages.suffix(12).reversed().map { outage in
            "  \(outage.start.formatted(.dateTime.weekday(.abbreviated).hour().minute().second()))  \(length(outage.seconds).padding(toLength: 8, withPad: " ", startingAt: 0)) \(outage.cause.title) " + Terminal.dim("(\(outage.side.title))")
        }
    }
    static func length(_ seconds: Double) -> String { seconds < 60 ? "\(Int(seconds.rounded())) s" : String(format: "%.1f min", seconds / 60) }

    /// The map in characters, two columns per row so it stays round: blocked cells in rose, clear ones as dots.
    static func sky(_ map: StarlinkSkyMap, rows: Int = 13) -> [String] {
        let columns = rows * 2 + 1
        var lines: [String] = []
        for row in 0..<rows {
            var line = "  "
            for column in 0..<columns {
                let x = (Double(column) + 0.5) / Double(columns), y = (Double(row) + 0.5) / Double(rows)
                let dx = x - 0.5, dy = y - 0.5
                if (dx * dx + dy * dy).squareRoot() > 0.5 { line += " "; continue }
                // The worst cell in this character's patch of the map.
                let r0 = Int(y * Double(map.rows)), c0 = Int(x * Double(map.columns))
                let span = max(1, map.rows / rows / 2)
                var seen = false, worst: Float = 1
                for r in max(0, r0 - span)...min(map.rows - 1, r0 + span) {
                    for c in max(0, c0 - span / 2)...min(map.columns - 1, c0 + span / 2) {
                        let value = map.snr[r * map.columns + c]
                        if value >= 0 { seen = true; worst = min(worst, value) }
                    }
                }
                line += !seen ? Terminal.dim("·") : worst < 0.5 ? Terminal.rose("█") : Terminal.blue("•")
            }
            if row == 0, map.earthFrame { line += Terminal.dim("  N ↑") }
            lines.append(line)
        }
        return lines
    }
}
