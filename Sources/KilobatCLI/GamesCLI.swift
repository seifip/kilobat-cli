import Foundation
import KilobatCore

/// `kilobat games`: ping each data center of CS2, Dota 2, Deadlock and Fortnite and name the closest.
@MainActor enum GamesCLI {
    static let usage = "Use games [--game cs2|dota2|deadlock|fortnite] [--json]."

    static func run(_ args: [String]) async throws {
        try KilobatCLI.allow(args, ["--game", "--json"], valued: ["--game"])
        let json = args.contains("--json")
        let games: [GameServerTable.Game]
        if let index = args.firstIndex(of: "--game") {
            guard index + 1 < args.count else { throw CLIError(usage) }
            games = [try game(args[index + 1])]
        } else { games = GameServerTable.bundled.games }
        var reports: [GamePingReport] = []
        for game in games {
            if !json { FileHandle.standardError.write(Data("Pinging \(game.regions.count) \(game.name) data centers…\n".utf8)) }
            reports.append(await GamePing.run(game))
        }
        if json {
            try WiFiCLI.printObject(reports.count == 1 ? reportJSON(reports[0]) : ["games": reports.map(reportJSON), "notIncluded": GameServerTable.unsupported])
            return
        }
        for (index, report) in reports.enumerated() {
            if index > 0 { print("") }
            print(text(report))
        }
        if games.count > 1 { print("\n" + Terminal.dim("Valorant, League of Legends and Apex Legends aren't included: none has a public server that answers a ping.")) }
    }

    /// A game by id, alias or name; the games without a target say why.
    static func game(_ name: String) throws -> GameServerTable.Game {
        let key = name.lowercased().replacingOccurrences(of: " ", with: "")
        let id = GameServerTable.aliases[key] ?? key
        if let game = GameServerTable.bundled.game(id) { return game }
        if let reason = GameServerTable.unsupported[id] { throw CLIError(reason + " Supported: " + GameServerTable.bundled.games.map(\.id).joined(separator: ", ") + ".") }
        throw CLIError("Unknown game '\(name)'. Use " + GameServerTable.bundled.games.map(\.id).joined(separator: " or ") + ".")
    }

    static func text(_ report: GamePingReport) -> String {
        let table = GameServerTable.bundled.game(report.game)
        let ms = { (value: Double?) in value.map { String(format: "%.0f ms", $0) } ?? "—" }
        var lines = [Terminal.bold(report.name) + Terminal.dim(" · ping to each data center, \(GamePing.count) pings each")]
        let width = max(12, report.regions.map(\.name.count).max() ?? 12), groups = max(10, report.regions.map(\.group.count).max() ?? 10)
        for region in report.regions {
            let best = region.region == report.best?.region
            let name = region.name.padding(toLength: width, withPad: " ", startingAt: 0), group = region.group.padding(toLength: groups, withPad: " ", startingAt: 0)
            var line = (best ? Terminal.blue("★ ") : "  ") + (best ? Terminal.bold(name) : name) + "  " + Terminal.dim(group) + "  " + ms(region.median).leftPadded(7)
            if region.median != nil {
                line += Terminal.dim("  ±" + (region.jitter.map { String(format: "%.0f", $0) } ?? "0") + (region.lossPercent > 0 ? String(format: " · %.0f%% lost", region.lossPercent) : ""))
                if region.method == .tcp { line += Terminal.dim(" · TCP") }
            } else { line += Terminal.dim("  no reply") }
            lines.append(line)
        }
        if let best = report.best, let target = report.overlayTarget {
            lines.append("")
            lines.append("Best for you: \(best.name), \(ms(best.median)). On stream: kilobat overlay --target \(target)")
        } else if report.noReplies {
            lines.append("")
            lines.append("No data center answered. This network may block ping; try another network or turn off a VPN that drops it.")
        }
        if let table { lines.append(Terminal.dim("Measured to \(table.target), not to a match server.")) }
        return lines.joined(separator: "\n")
    }

    static func reportJSON(_ report: GamePingReport) -> [String: Any] {
        func round(_ value: Double?) -> Any { value.map(WiFiCLI.tenths) ?? NSNull() }
        func region(_ region: GameRegionPing) -> [String: Any] {
            ["region": region.region, "name": region.name, "group": region.group, "host": region.host.isEmpty ? NSNull() : region.host, "method": region.method.rawValue,
             "pingMs": round(region.median), "jitterMs": round(region.jitter), "lossPercent": WiFiCLI.tenths(region.lossPercent), "samplesMs": region.samples.map(round)]
        }
        let table = GameServerTable.bundled.game(report.game)
        return ["game": report.game, "name": report.name, "date": ISO8601DateFormatter().string(from: report.date),
                "measuredTo": table?.target ?? NSNull(), "source": table?.source ?? NSNull(), "tableUpdated": GameServerTable.bundled.updated,
                "best": report.best.map(region) ?? NSNull(), "overlayTarget": report.overlayTarget ?? NSNull(), "noReplies": report.noReplies,
                "regions": report.regions.map(region)]
    }
}

private extension String {
    func leftPadded(_ width: Int) -> String { count >= width ? self : String(repeating: " ", count: width - count) + self }
}
