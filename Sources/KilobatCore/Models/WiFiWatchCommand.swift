import Foundation

/// `kilobat wifi watch [--for 2m] [--every 15s] [--csv]`, parsed. `--json` is taken off before this.
public struct WiFiWatchCommand: Equatable, Sendable {
    public var duration: TimeInterval = 120
    public var interval: TimeInterval = 15
    public var csv = false
    public init() {}

    public static func parse(_ args: [String]) throws -> WiFiWatchCommand {
        var command = WiFiWatchCommand(), index = 0
        let usage = DiagnosticError("Use wifi watch [--for 2m] [--every 15s] [--json|--csv]. From 30 seconds to 10 minutes; scans at least 10 seconds apart.")
        while index < args.count {
            switch args[index] {
            case "--csv": command.csv = true; index += 1
            case "--for", "--every":
                guard index + 1 < args.count, let seconds = seconds(args[index + 1]) else { throw usage }
                if args[index] == "--for" {
                    guard (30...600).contains(seconds) else { throw usage }
                    command.duration = seconds
                } else {
                    guard (10...60).contains(seconds) else { throw usage }
                    command.interval = seconds
                }
                index += 2
            default: throw usage
            }
        }
        return command
    }

    /// "2m", "90s", "120" (seconds) or "1.5m".
    public static func seconds(_ text: String) -> TimeInterval? {
        let value = text.lowercased()
        if value.hasSuffix("min"), let number = Double(value.dropLast(3)) { return number * 60 }
        if value.hasSuffix("m"), let number = Double(value.dropLast()) { return number * 60 }
        if value.hasSuffix("s"), let number = Double(value.dropLast()) { return number }
        return Double(value)
    }

    /// "2 min" or "45 s".
    public static func label(_ seconds: TimeInterval) -> String {
        seconds >= 60 && seconds.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(seconds / 60)) min" : "\(Int(seconds)) s"
    }
}
