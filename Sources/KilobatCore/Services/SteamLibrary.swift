import Foundation

/// What Steam's own files on this Mac say: `steamapps/appmanifest_*.acf`, one per installed game, with its name and
/// any update's size. Read locally; no Steam account or request is involved.
public enum SteamLibrary {
    public struct App: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let flags: Int
        public let bytesToDownload: UInt64
        public let bytesDownloaded: UInt64
        public let targetBuild: String
        public var bytesLeft: UInt64 { bytesToDownload > bytesDownloaded ? bytesToDownload - bytesDownloaded : 0 }
        /// Steam has begun this update: running, started, or preallocating, downloading, staging or committing it.
        public var updating: Bool { flags & (256 | 1024 | 524_288 | 1_048_576 | 2_097_152 | 4_194_304) != 0 && flags & 512 == 0 && bytesLeft > 0 }
    }

    static func fields(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
            // Whitespace, key, whitespace, value, end.
            guard parts.count >= 5, result[String(parts[1])] == nil else { continue }
            result[String(parts[1])] = String(parts[3])
        }
        return result
    }

    public static func parse(_ text: String) -> App? {
        let values = fields(text)
        guard let id = values["appid"], let name = values["name"], !name.isEmpty else { return nil }
        return App(id: id, name: name, flags: Int(values["StateFlags"] ?? "") ?? 0, bytesToDownload: UInt64(values["BytesToDownload"] ?? "") ?? 0,
                   bytesDownloaded: UInt64(values["BytesDownloaded"] ?? "") ?? 0, targetBuild: values["TargetBuildID"] ?? values["buildid"] ?? "")
    }

    /// Every `path` in `libraryfolders.vdf`, for games kept on another drive.
    static func libraries(_ vdf: String) -> [String] {
        vdf.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
            return parts.count >= 5 && parts[1] == "path" ? String(parts[3]).replacingOccurrences(of: "\\\\", with: "/") : nil
        }
    }

    public static func apps(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [App] {
        let main = home.appendingPathComponent("Library/Application Support/Steam/steamapps")
        let extra = (try? String(contentsOf: main.appendingPathComponent("libraryfolders.vdf"), encoding: .utf8)).map(libraries) ?? []
        let folders = [main] + extra.map { URL(fileURLWithPath: $0).appendingPathComponent("steamapps") }.filter { $0.standardizedFileURL != main.standardizedFileURL }
        var found: [String: App] = [:]
        for folder in folders {
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where file.lastPathComponent.hasPrefix("appmanifest_") && file.pathExtension == "acf" {
                if let text = try? String(contentsOf: file, encoding: .utf8), let app = parse(text) { found[app.id] = app }
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The game Steam is updating now: the one with the most left.
    public static func updating(_ apps: [App]) -> App? { apps.filter(\.updating).max { $0.bytesLeft < $1.bytesLeft } }

    /// The games in `table` that are installed, by name or alias, most played first.
    public static func installedGames(_ apps: [App], table: GameServerTable) -> [GameServerTable.Game] {
        func key(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let names = Set(apps.map { key($0.name) })
        return table.popular.filter { game in
            names.contains(key(game.name)) || GameServerTable.aliases.contains { $0.value == game.id && names.contains(key($0.key)) }
        }
    }

    /// One warning a metered network deserves: an update that won't fit the budget, or 500 MB or more with no budget set.
    public static func meteredWarning(left: UInt64, metered: Bool, budgetLeft: UInt64?) -> Bool {
        guard metered, left > 0 else { return false }
        if let budgetLeft { return left > budgetLeft }
        return left >= 500_000_000
    }
}
