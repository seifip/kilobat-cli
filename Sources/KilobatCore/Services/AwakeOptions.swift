import Foundation

/// `kilobat awake`'s options, checked before anything starts.
public struct AwakeOptions: Equatable, Sendable {
    public var duration: Double?
    public var untilQuiet = false
    public var app: String?
    public var quietMinutes = 3
    public var display = false
    public var json = false
    public var lidClosed = false
    /// An app's name or bundle ID: stay awake only while it is in front.
    public var frontmost: String?
    /// What runs after `--`.
    public var command: [String] = []
    public var hasCommand: Bool { !command.isEmpty }

    public struct Invalid: Error, Equatable { public let message: String }
    static let flags: Set<String> = ["--for", "--until-quiet", "--app", "--quiet", "--display", "--json", "--lid-closed", "--while-frontmost"]
    static let valued: Set<String> = ["--for", "--app", "--quiet", "--while-frontmost"]

    /// `args` starts with `awake`.
    public static func parse(_ args: [String]) throws -> AwakeOptions {
        func fail(_ message: String) -> Invalid { Invalid(message: message) }
        let split = args.firstIndex(of: "--")
        let options = Array(args[..<(split ?? args.endIndex)])
        var parsed = AwakeOptions(command: split.map { Array(args[($0 + 1)...]) } ?? [])
        var index = 1
        while index < options.count {
            guard flags.contains(options[index]) else { throw fail("Unexpected '\(options[index])'. Run kilobat awake --help.") }
            index += valued.contains(options[index]) ? 2 : 1
        }
        func value(_ flag: String) throws -> String? {
            guard let index = options.firstIndex(of: flag) else { return nil }
            guard index + 1 < options.count else { throw fail("\(flag) needs a value. Run kilobat awake --help.") }
            return options[index + 1]
        }
        if split != nil && parsed.command.isEmpty { throw fail("Name a command after --, e.g. kilobat awake -- make test.") }
        parsed.untilQuiet = options.contains("--until-quiet"); parsed.display = options.contains("--display")
        parsed.json = options.contains("--json"); parsed.lidClosed = options.contains("--lid-closed")
        parsed.duration = try value("--for").map { text in
            guard let seconds = seconds(text), (1...86_400).contains(seconds) else { throw fail("--for takes a duration such as 45s, 90m or 2h, up to 24h.") }
            return seconds
        }
        guard [parsed.duration != nil, parsed.untilQuiet, parsed.hasCommand].filter({ $0 }).count <= 1 else { throw fail("Choose one of --for, --until-quiet or -- <command>.") }
        parsed.app = try value("--app")
        parsed.frontmost = try value("--while-frontmost")
        if let app = parsed.frontmost {
            guard !app.trimmingCharacters(in: .whitespaces).isEmpty, !app.hasPrefix("-") else { throw fail("--while-frontmost takes an app's name or bundle ID, e.g. Keynote or com.apple.Preview.") }
            if parsed.untilQuiet || parsed.hasCommand { throw fail("--while-frontmost goes with --for and --display only.") }
            // With the lid closed nothing is in front, so the condition never holds the lid.
            if parsed.lidClosed { throw fail("--while-frontmost can't hold the lid: with it closed, no app is in front.") }
        }
        let quiet = try value("--quiet")
        if (parsed.app != nil || quiet != nil) && !parsed.untilQuiet { throw fail("--app and --quiet go with --until-quiet.") }
        if let app = parsed.app, !(app.contains(".") || app.hasPrefix("process:")) { throw fail("--app takes a bundle ID such as com.example.App, or process:<name>.") }
        if let quiet {
            guard let seconds = seconds(quiet), case let minutes = Int((seconds / 60).rounded(.up)), (1...60).contains(minutes) else { throw fail("--quiet takes 1 to 60 minutes, e.g. 3m.") }
            parsed.quietMinutes = minutes
        }
        // The helper caps any stretch at 8 hours; a longer timer would quietly lose the lid partway.
        if parsed.lidClosed, let duration = parsed.duration, duration > LidPolicy.longest { throw fail("--lid-closed holds 8 hours at most; use --for 8h or less.") }
        return parsed
    }

    /// 90m, 2h, 45s or 1h30m; a bare number is minutes.
    public static func seconds(_ text: String) -> Double? {
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
}
