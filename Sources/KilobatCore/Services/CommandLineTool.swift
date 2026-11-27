import Foundation

/// The `kilobat` command in Terminal: where it is, whether it is the copy inside Kilobat.app, and linking it there.
/// A linked command is the app's own signed copy, so every app update updates it too; a Homebrew copy only changes
/// when someone runs `brew upgrade`.
public struct CommandLineTool: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case app, homebrew, other }
    /// Where the shell finds it, such as /opt/homebrew/bin/kilobat.
    public let path: String
    public let source: Source
    public let version: String?

    public init(path: String, source: Source, version: String?) {
        self.path = path; self.source = source; self.version = version
    }

    /// The folders checked, in the order a default macOS PATH lists them.
    public static let folders = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]

    public static func source(resolved: String) -> Source {
        if resolved.hasSuffix(".app/Contents/Helpers/kilobat") { return .app }
        if resolved.contains("/Cellar/") { return .homebrew }
        return .other
    }

    /// The app's copy, beside the running app or in an Applications folder.
    public static func appCopy(bundle: URL? = nil) -> String? {
        let candidates = [bundle].compactMap { $0 } + ["/Applications", NSHomeDirectory() + "/Applications"].map { URL(fileURLWithPath: $0).appendingPathComponent("Kilobat.app") }
        return candidates.map { $0.appendingPathComponent("Contents/Helpers/kilobat").path }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The first working `kilobat` in the usual folders, as the shell would find it.
    public static func installed(in folders: [String] = folders) async -> CommandLineTool? {
        for folder in folders {
            let path = folder + "/kilobat"
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return CommandLineTool(path: path, source: source(resolved: resolved), version: await version(of: path))
        }
        return nil
    }

    /// "0.48.0" from `kilobat --version`.
    public static func version(of path: String) async -> String? {
        let result = await CommandRunner.run(path, ["--version"], timeout: 5)
        guard result.status == 0 else { return nil }
        return parseVersion(result.output)
    }

    static func parseVersion(_ output: String) -> String? {
        output.split(whereSeparator: \.isWhitespace).map(String.init).first { $0.first?.isNumber == true && $0.contains(".") }
    }

    /// True when `version` is older than `than`, comparing each number.
    public static func older(_ version: String?, than other: String?) -> Bool {
        guard let other else { return false }
        guard let version else { return true }
        let a = version.split(separator: ".").map { Int($0) ?? 0 }, b = other.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) where (i < a.count ? a[i] : 0) != (i < b.count ? b[i] : 0) {
            return (i < a.count ? a[i] : 0) < (i < b.count ? b[i] : 0)
        }
        return false
    }

    /// The folder to link into: the current command's folder, else the first writable one on the PATH.
    public static func folder(replacing current: CommandLineTool?) -> String {
        if let current { return (current.path as NSString).deletingLastPathComponent }
        return folders.dropLast().first { FileManager.default.isWritableFile(atPath: $0) } ?? "/usr/local/bin"
    }

    /// Points `kilobat` and `kb` at the app's copy. A Homebrew install is uninstalled first so Homebrew doesn't keep an
    /// old copy of its own; a folder that isn't writable (such as a missing /usr/local/bin) asks for an administrator.
    /// Returns the folder used.
    @discardableResult
    public static func link(to helper: String, replacing current: CommandLineTool?) async throws -> String {
        if current?.source == .homebrew { try await uninstallHomebrew() }
        let folder = folder(replacing: current)
        let fm = FileManager.default
        if fm.isWritableFile(atPath: folder) {
            for name in ["kilobat", "kb"] {
                let path = folder + "/" + name
                if name == "kb", !ours(path) { continue }
                if (try? fm.attributesOfItem(atPath: path)) != nil || (try? fm.destinationOfSymbolicLink(atPath: path)) != nil {
                    try fm.removeItem(atPath: path)
                }
                try fm.createSymbolicLink(atPath: path, withDestinationPath: helper)
            }
        } else {
            let kb = ours(folder + "/kb") ? " && ln -sfn \(shellQuoted(helper)) \(shellQuoted(folder + "/kb"))" : ""
            let command = "mkdir -p \(shellQuoted(folder)) && ln -sfn \(shellQuoted(helper)) \(shellQuoted(folder + "/kilobat"))" + kb
            let script = "do shell script \"\(appleScriptEscaped(command))\" with administrator privileges"
            let result = await CommandRunner.run("/usr/bin/osascript", ["-e", script], timeout: 300)
            guard result.status == 0 else {
                throw CommandLineToolError(result.output.contains("-128") ? String(localized: "Linking was cancelled.") : String(localized: "Kilobat couldn’t link the command in \(folder)."))
            }
        }
        return folder
    }

    /// Nothing there, or a link to a kilobat (an app copy's helper, or Homebrew's `kb`): safe to point at this app's copy.
    /// Another tool called `kb` is left alone; the alias is a convenience.
    static func ours(_ path: String) -> Bool {
        let fm = FileManager.default
        if let target = try? fm.destinationOfSymbolicLink(atPath: path) {
            return (target as NSString).lastPathComponent == "kilobat" || URL(fileURLWithPath: path).resolvingSymlinksInPath().lastPathComponent == "kilobat"
        }
        return (try? fm.attributesOfItem(atPath: path)) == nil
    }

    /// At launch of an installed app: when no kilobat is on the PATH, links the app's copy into a folder writable
    /// without a password (Homebrew's, on most Macs), so the command just works. Once: a link someone removes stays
    /// removed, unless it was left pointing at an app copy that is gone.
    public static func linkAtLaunch(helper: String, defaults: UserDefaults = .standard) async {
        let key = "cli.autoLinked", fm = FileManager.default
        guard await installed() == nil else { return }
        let dangling = folders.contains { folder in
            guard let target = try? fm.destinationOfSymbolicLink(atPath: folder + "/kilobat") else { return false }
            return target.hasSuffix(".app/Contents/Helpers/kilobat") && !fm.isExecutableFile(atPath: target)
        }
        guard dangling || !defaults.bool(forKey: key), fm.isWritableFile(atPath: folder(replacing: nil)) else { return }
        if (try? await link(to: helper, replacing: nil)) != nil { defaults.set(true, forKey: key) }
    }

    static func uninstallHomebrew() async throws {
        guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CommandLineToolError(String(localized: "Homebrew wasn’t found, so its copy of kilobat couldn’t be removed."))
        }
        let result = await CommandRunner.run("/usr/bin/env", ["HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_ENV_HINTS=1", brew, "uninstall", "--formula", "kilobat"], timeout: 180)
        guard result.status == 0 else { throw CommandLineToolError(String(localized: "Homebrew couldn’t remove its copy of kilobat. Run brew uninstall kilobat, then try again.")) }
    }

    static func shellQuoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func appleScriptEscaped(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
}

public struct CommandLineToolError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
