import Foundation
import KilobatCore

/// `kilobat overlay`: the streaming overlay without the app, until Ctrl-C.
enum OverlayCLI {
    static let usage = "Use overlay [--port 1024…65535] [--target internet|router|<host>]."

    static func run(_ args: [String]) async throws {
        var port = StreamOverlay.defaultPort, target = "internet", index = 1
        while index < args.count {
            switch args[index] {
            case "--port":
                guard index + 1 < args.count, let value = UInt16(args[index + 1]), value >= 1024 else { throw CLIError(usage) }
                port = value; index += 2
            case "--target":
                guard index + 1 < args.count, !args[index + 1].hasPrefix("-") else { throw CLIError(usage) }
                target = args[index + 1]; index += 2
            default: throw CLIError(usage)
            }
        }
        let overlay = StreamOverlay(port: port, target: target)
        do { try overlay.start() } catch { throw CLIError("Couldn't open port \(port): \(error.localizedDescription). Pick another with --port.") }
        print("Streaming overlay at \(overlay.url)")
        print("In OBS: Sources › + › Browser, set the URL to it, width 640, height 80. Only this Mac can open it.")
        print("Options: \(overlay.url)?show=ping,jitter,loss,graph&theme=dark|light|clear&size=s|m|l")
        print("Live speed needs the Kilobat app's overlay (Settings › Network). Ctrl-C to stop.")
        while true { try await Task.sleep(for: .seconds(3600)) }
    }
}
