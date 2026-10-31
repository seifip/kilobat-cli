import Foundation
import KilobatCore

/// `kilobat overlay`: the streaming overlay without the app, until Ctrl-C.
enum OverlayCLI {
    static let usage = "Use overlay [--port 1024…65535] [--target internet|router|match|<game>:<region>|<host>]."

    static func run(_ args: [String]) async throws {
        var port = StreamOverlay.defaultPort, target = "internet", index = 1
        while index < args.count {
            switch args[index] {
            case "--port":
                guard index + 1 < args.count, let value = UInt16(args[index + 1]), value >= 1024 else { throw CLIError(usage) }
                port = value; index += 2
            case "--target":
                guard index + 1 < args.count, !args[index + 1].hasPrefix("-") else { throw CLIError(usage) }
                target = try check(args[index + 1]); index += 2
            default: throw CLIError(usage)
            }
        }
        let overlay = StreamOverlay(port: port, target: target)
        do { try overlay.start() } catch { throw CLIError("Couldn't open port \(port): \(error.localizedDescription). Pick another with --port.") }
        print("Streaming overlay at \(overlay.url)")
        if let (game, region) = GameServerTable.bundled.target(target) { print("Pinging \(game.name)'s \(region.name) data center once a second.") }
        if target == CurrentMatch.overlayTarget { print("Pinging the server of the match you're playing once a second; Kilobat looks for it again every 30 seconds.") }
        print("In OBS: Sources › + › Browser, set the URL to it, width 640, height 80. Only this Mac can open it.")
        print("Options: \(overlay.url)?show=ping,jitter,loss,graph&theme=dark|light|clear&size=s|m|l")
        print("Live speed needs the Kilobat app's overlay (Settings › Network). Ctrl-C to stop.")
        while true { try await Task.sleep(for: .seconds(3600)) }
    }

    /// A game region is checked against the table, so a typo isn't pinged as a host name.
    static func check(_ target: String) throws -> String {
        let parts = target.lowercased().split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return target }
        let game: GameServerTable.Game
        switch GameServerTable.bundled.lookup(parts[0]) {
        case .game(let found)?: game = found
        case .notMeasured(let skipped)?: throw CLIError("\(skipped.name) isn't measured: \(skipped.reason) Use --target match while you play it.")
        case nil: return target
        }
        guard GameServerTable.bundled.target("\(game.id):\(parts[1])") != nil else {
            throw CLIError("No \(game.name) region '\(parts[1])'. Use one of: " + game.regions.map(\.id).joined(separator: ", ") + ". kilobat games --game \(game.id) finds the closest.")
        }
        return "\(game.id):\(parts[1])"
    }
}
