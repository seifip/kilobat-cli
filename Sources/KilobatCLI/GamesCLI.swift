import Foundation
import KilobatCore

/// `kilobat games`: the games Kilobat can ping, a game's data centers with the closest one, or the server of the match
/// being played.
@MainActor enum GamesCLI {
    static let usage = "Use games [--game <game> | --all | --match] [--json]. Without one, lists the games."
    /// Where the site serves each game's icon.
    static let iconBase = "https://kilobat.app/assets/games/"

    static func run(_ args: [String]) async throws {
        try KilobatCLI.allow(args, ["--game", "--all", "--match", "--json"], valued: ["--game"])
        let json = args.contains("--json")
        if args.contains("--match") {
            let check = await CurrentMatch.check()
            if json { try WiFiCLI.printObject(matchJSON(check)) } else { print(text(check)) }
            return
        }
        let games: [GameServerTable.Game]
        if let index = args.firstIndex(of: "--game") {
            guard index + 1 < args.count else { throw CLIError(usage) }
            games = [try game(args[index + 1])]
        } else if args.contains("--all") {
            games = GameServerTable.bundled.popular
        } else {
            if json { try WiFiCLI.printObject(listJSON()) } else { print(list()) }
            return
        }
        var reports: [GamePingReport] = []
        for game in games {
            if !json { FileHandle.standardError.write(Data("Pinging \(game.regions.count) \(game.name) data centers…\n".utf8)) }
            reports.append(await GamePing.run(game))
        }
        if json {
            try WiFiCLI.printObject(reports.count == 1 ? reportJSON(reports[0]) : ["games": reports.map(reportJSON), "notMeasured": notMeasuredJSON()])
            return
        }
        for (index, report) in reports.enumerated() {
            if index > 0 { print("") }
            print(text(report))
        }
    }

    /// A game by id, alias or name; the games without a target say why.
    static func game(_ name: String) throws -> GameServerTable.Game {
        switch GameServerTable.bundled.lookup(name) {
        case .game(let game)?: return game
        case .notMeasured(let skipped)?:
            throw CLIError("\(skipped.name) isn't measured: \(skipped.reason) While you play it, kilobat games --match finds and pings your match's server.")
        case nil:
            throw CLIError("Unknown game '\(name)'. Use " + GameServerTable.bundled.popular.map(\.id).joined(separator: ", ") + ", or --match for the game you're playing.")
        }
    }

    static func kind(_ kind: GameServerTable.Game.Kind) -> String {
        switch kind {
        case .valve: "Valve relays"
        case .epic: "Epic ping servers"
        case .azure: "Azure regions"
        case .aws: "AWS regions"
        case .official: "Official test hosts"
        }
    }

    static func list() -> String {
        let games = GameServerTable.bundled.popular
        let width = (games.map(\.id.count) + [4]).max()!, names = (games.map(\.name.count)).max()!
        var lines = [Terminal.bold("Games Kilobat pings") + Terminal.dim(" · kilobat games --game <id>")]
        for game in games {
            lines.append("  " + game.id.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + game.name.padding(toLength: names, withPad: " ", startingAt: 0)
                         + "  " + Terminal.dim("\(kind(game.kind)), \(game.regions.count) \(game.regions.count == 1 ? "region" : "regions")"))
        }
        lines.append("")
        lines.append(Terminal.bold("Not measured") + Terminal.dim(" · kilobat games --match pings your match's server while you play"))
        for skipped in GameServerTable.bundled.notMeasured {
            lines.append("  " + skipped.name + Terminal.dim(" · " + skipped.reason))
        }
        lines.append("")
        lines.append(Terminal.dim("Ping to each region's data center, not to a match server. Table checked \(GameServerTable.bundled.updated)."))
        return lines.joined(separator: "\n")
    }

    static func text(_ report: GamePingReport) -> String {
        let table = GameServerTable.bundled.game(report.game)
        let ms = { (value: Double?) in value.map { String(format: "%.0f ms", $0) } ?? "—" }
        var lines = [Terminal.bold(report.name) + Terminal.dim(" · ping to each data center, \(GamePing.count) probes each")]
        let subtitle = { (region: GameRegionPing) in region.cloud ?? region.group }
        let width = max(12, report.regions.map(\.name.count).max() ?? 12), groups = max(10, report.regions.map { subtitle($0).count }.max() ?? 10)
        for region in report.regions {
            let best = region.region == report.best?.region
            let name = region.name.padding(toLength: width, withPad: " ", startingAt: 0), group = subtitle(region).padding(toLength: groups, withPad: " ", startingAt: 0)
            var line = (best ? Terminal.blue("★ ") : "  ") + (best ? Terminal.bold(name) : name) + "  " + Terminal.dim(group) + "  " + ms(region.median).leftPadded(7)
            if region.median != nil {
                line += Terminal.dim("  ±" + (region.jitter.map { String(format: "%.0f", $0) } ?? "0") + (region.lossPercent > 0 ? String(format: " · %.0f%% lost", region.lossPercent) : ""))
                if region.method != .icmp { line += Terminal.dim(" · " + region.method.rawValue.uppercased()) }
            } else { line += Terminal.dim("  no reply") }
            lines.append(line)
        }
        if let best = report.best, let target = report.overlayTarget {
            lines.append("")
            lines.append("Best for you: \(best.name)\(best.cloud.map { " (\($0))" } ?? ""), \(ms(best.median)). On stream: kilobat overlay --target \(target)")
        } else if report.noReplies {
            lines.append("")
            lines.append("No data center answered. This network may block ping; try another network or turn off a VPN that drops it.")
        }
        if let table { lines.append(Terminal.dim("Measured to \(table.target), not to a match server.")) }
        return lines.joined(separator: "\n")
    }

    static func text(_ check: MatchCheck) -> String {
        let ms = { (value: Double?) in value.map { String(format: "%.0f ms", $0) } ?? "—" }
        switch check.state {
        case .noGame:
            return "No game is open. Start a match, then run kilobat games --match again."
        case .noServer:
            return "\(check.game ?? "The game") has no connection to a game server right now. Start a match, then try again."
        case .hidden:
            return "\(check.game ?? "The game") sends to its server from a socket macOS doesn't label with an address, so Kilobat can't see which server it is."
        case .found:
            guard let server = check.server else { return "" }
            var lines = [Terminal.bold("Your current match") + Terminal.dim(" · \(server.game)"),
                         "Server  \(server.address):\(server.port) \(server.transport)" + (server.place.map { Terminal.dim(" · \($0)") } ?? "")]
            if check.answersPing {
                lines.append("Ping    \(ms(check.median))" + Terminal.dim("  ±" + String(format: "%.0f", check.jitter ?? 0) + ((check.lossPercent ?? 0) > 0 ? String(format: " · %.0f%% lost", check.lossPercent!) : "")))
                lines.append(Terminal.dim("On stream: kilobat overlay --target match"))
            } else {
                lines.append("Ping    " + Terminal.dim("This server doesn't answer ping. Many game servers don't; it isn't loss."))
            }
            if server.known == nil { lines.append(Terminal.dim("Country from DB-IP (db-ip.com): where the address is registered.")) }
            return lines.joined(separator: "\n")
        }
    }

    static func iconURL(_ icon: String?) -> Any { icon.map { iconBase + $0 + ".webp" } ?? NSNull() }

    static func listJSON() -> [String: Any] {
        ["tableUpdated": GameServerTable.bundled.updated,
         "games": GameServerTable.bundled.popular.map { game -> [String: Any] in
             ["game": game.id, "name": game.name, "measuredBy": game.kind.rawValue, "measuredTo": game.target, "hosting": game.hosting, "source": game.source,
              "icon": iconURL(game.icon), "regions": game.regions.map { region -> [String: Any] in
                  ["region": region.id, "name": region.name, "group": region.group, "cloud": region.cloud ?? NSNull()]
              }]
         },
         "notMeasured": notMeasuredJSON()]
    }

    static func notMeasuredJSON() -> [[String: Any]] {
        GameServerTable.bundled.notMeasured.map { ["game": $0.id, "name": $0.name, "why": $0.why.rawValue, "reason": $0.reason, "icon": iconURL($0.icon)] }
    }

    static func reportJSON(_ report: GamePingReport) -> [String: Any] {
        func round(_ value: Double?) -> Any { value.map(WiFiCLI.tenths) ?? NSNull() }
        func region(_ region: GameRegionPing) -> [String: Any] {
            ["region": region.region, "name": region.name, "group": region.group, "cloud": region.cloud ?? NSNull(), "host": region.host.isEmpty ? NSNull() : region.host,
             "method": region.method.rawValue, "pingMs": round(region.median), "jitterMs": round(region.jitter), "lossPercent": WiFiCLI.tenths(region.lossPercent),
             "samplesMs": region.samples.map(round)]
        }
        let table = GameServerTable.bundled.game(report.game)
        return ["game": report.game, "name": report.name, "date": ISO8601DateFormatter().string(from: report.date), "icon": iconURL(table?.icon),
                "measuredBy": table?.kind.rawValue ?? NSNull(), "measuredTo": table?.target ?? NSNull(), "hosting": table?.hosting ?? NSNull(),
                "source": table?.source ?? NSNull(), "tableUpdated": GameServerTable.bundled.updated,
                "best": report.best.map(region) ?? NSNull(), "overlayTarget": report.overlayTarget ?? NSNull(), "noReplies": report.noReplies,
                "regions": report.regions.map(region)]
    }

    static func matchJSON(_ check: MatchCheck) -> [String: Any] {
        func round(_ value: Double?) -> Any { value.map(WiFiCLI.tenths) ?? NSNull() }
        var object: [String: Any] = ["state": check.state.rawValue, "game": check.game ?? NSNull(), "date": ISO8601DateFormatter().string(from: check.date)]
        if let server = check.server {
            object["server"] = ["address": server.address, "port": server.port, "transport": server.transport, "country": server.country ?? NSNull(),
                                "countryName": server.countryName ?? NSNull(), "knownDataCenter": server.known ?? NSNull(), "bytes": server.bytes]
            object["answersPing"] = check.answersPing
            object["pingMs"] = round(check.median); object["jitterMs"] = round(check.jitter); object["lossPercent"] = round(check.lossPercent)
            object["samplesMs"] = check.samples.map(round)
            object["overlayTarget"] = CurrentMatch.overlayTarget
        }
        return object
    }
}

private extension String {
    func leftPadded(_ width: Int) -> String { count >= width ? self : String(repeating: " ", count: width - count) + self }
}
