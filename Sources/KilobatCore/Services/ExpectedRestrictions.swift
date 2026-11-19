import Foundation

/// A read-only guide of what public reports say is restricted in a country.
/// The file is a snapshot. Kilobat does not scan test lists, and it does not fetch this file in the background.
/// `NetworkBlockCheck` stays the live result. This guide never replaces that verdict and never suggests a way around a block.
///
/// On-disk JSON uses snake_case. Schema 1, the contract JN-0012's `site/src/data/restrictions/latest.json` fills in:
/// `schema_version`, `updated_at`, `label`, `kind`, `live_check`, `data_status`, `disclaimer`, optional `data_note`,
/// `sources` (`id`, `name`, `url`, `role`, `ingest`) and `countries`.
/// A country has `code`, `name`, optional `summary`, and `entries`.
/// An entry has `target`, `kind` (`domain`, `service`, `category` or `shutdown`), `summary`, `sources` (source ids),
/// optional `as_of`, and optional `citations` (`source`, `title`, `url`).
/// A source with `ingest` false, NetBlocks today, may be cited by link. An entry whose sources are only cite-only is dropped.
/// Production rows are not in the stub. Do not invent NetBlocks measurements.
public enum ExpectedRestrictions {
    public static let schema = 1
    public static let label = "expected here per sources"
    /// Beside the CLI, in the app bundle, or in the repo while developing. Never the network.
    public static let fileNames = ["restrictions-latest.json", "latest.json"]

    public struct File: Codable, Sendable, Equatable {
        public var schemaVersion: Int
        public var updatedAt: String
        public var label: String
        public var kind: String
        public var liveCheck: String
        public var dataStatus: String
        public var disclaimer: String
        public var dataNote: String?
        public var sources: [Source]
        public var countries: [Country]
    }

    public struct Source: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var url: String
        public var role: String
        public var ingest: Bool
    }

    public struct Country: Codable, Sendable, Equatable {
        public var code: String
        public var name: String
        public var summary: String?
        public var entries: [Entry]
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var target: String
        public var kind: String
        public var summary: String
        public var sources: [String]
        public var asOf: String?
        public var citations: [Citation]?
        public var links: [Citation] { citations ?? [] }
    }

    public struct Citation: Codable, Sendable, Equatable {
        public var source: String
        public var title: String
        public var url: String
    }

    /// What `kilobat restrictions` and `get_country_restrictions` return. Camel case, like the other CLI JSON.
    public struct CountryReport: Codable, Sendable, Equatable {
        public var country: String
        public var name: String
        public var found: Bool
        public var label: String
        public var schemaVersion: Int
        public var updatedAt: String
        public var disclaimer: String
        public var dataStatus: String
        public var dataNote: String?
        public var liveCheck: String
        public var basis: String
        public var sources: [Source]
        public var summary: String?
        public var entries: [ListedEntry]
        public var note: String?

        public var text: String {
            var lines = ["\(ExpectedRestrictions.label) · \(country)"]
            if name != country { lines[0] += " · \(name)" }
            lines.append("Updated \(updatedAt). This is a guide, not a live probe. \(liveCheck) is what this Mac measures.")
            if let dataNote, !dataNote.isEmpty { lines.append(dataNote) }
            if !found {
                lines.append("No rows for \(country) in this \(dataStatus) snapshot.")
            } else {
                if let summary, !summary.isEmpty { lines.append(summary) }
                if entries.isEmpty { lines.append("No listed targets for \(country).") }
                for entry in entries {
                    let when = entry.asOf.map { " as of \($0)" } ?? ""
                    let name = entry.target.isEmpty ? entry.kind : entry.target
                    lines.append("\(name)  \(entry.summary)\(when)")
                }
            }
            let used = sources.filter(\.ingest).map { "\($0.name), \($0.role)" }
            let cited = sources.filter { !$0.ingest }.map(\.name)
            if !used.isEmpty { lines.append(used.joined(separator: ". ")) }
            if !cited.isEmpty { lines.append(cited.joined(separator: ", ") + " is cite-only and is not ingested.") }
            lines.append(disclaimer)
            return lines.joined(separator: "\n")
        }
    }

    public struct ListedEntry: Codable, Sendable, Equatable {
        public var target: String
        public var kind: String
        public var summary: String
        public var sources: [String]
        public var asOf: String?
        public var citations: [Citation]
    }

    /// A note beside a live check. It does not replace `verdict`, `next` or `block`.
    public struct Note: Codable, Sendable, Equatable {
        public var label: String
        public var country: String
        public var countryBasis: String
        public var updatedAt: String
        public var summary: String
        public var sentence: String
        public var sources: [String]
        public var targets: [String]
        public var liveCheck: String
    }

    public static func decode(_ data: Data) throws -> File {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let file = try decoder.decode(File.self, from: data)
        guard file.schemaVersion == schema else {
            throw ExpectedRestrictionsError("This restrictions guide uses schema \(file.schemaVersion). Kilobat reads schema \(schema).")
        }
        return file
    }

    /// The snapshot on disk. Missing and unreadable files throw. Nothing is downloaded.
    public static func load() throws -> File {
        guard let url = locate() else {
            throw ExpectedRestrictionsError("Kilobat has no restrictions guide. It ships with the app as restrictions-latest.json.")
        }
        return try read(url)
    }

    public static func read(_ url: URL) throws -> File {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw ExpectedRestrictionsError("Kilobat could not read the restrictions guide.")
        }
        guard data.count <= 8_000_000 else {
            throw ExpectedRestrictionsError("The restrictions guide is larger than 8 MB, so Kilobat did not read it.")
        }
        do { return try decode(data) } catch let error as ExpectedRestrictionsError {
            throw error
        } catch {
            throw ExpectedRestrictionsError("The restrictions guide is not the expected JSON.")
        }
    }

    /// The country the user asked for. A code with no rows is a successful empty guide, not an error.
    public static func country(_ code: String, in file: File? = nil) throws -> CountryReport {
        let file = try file ?? load()
        let normalized = try iso(code)
        let match = file.countries.first { $0.code.uppercased() == normalized }
        let entries = (match?.entries ?? []).filter { visible($0, file: file) }.map(listed)
        let summary = match?.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let keptSummary = summary.flatMap { $0.isEmpty || advice($0) ? nil : $0 }
        let note = sentence(summary: keptSummary, entries: entries.map(\.summary))
        return CountryReport(country: normalized, name: match?.name ?? regionName(normalized), found: match != nil,
                             label: file.label.isEmpty ? label : file.label, schemaVersion: file.schemaVersion, updatedAt: file.updatedAt,
                             disclaimer: file.disclaimer, dataStatus: file.dataStatus, dataNote: file.dataNote, liveCheck: file.liveCheck,
                             basis: "requested", sources: file.sources, summary: keptSummary, entries: entries, note: note)
    }

    /// A note for one target in one country. A country-wide shutdown matches without a host. A general summary does not.
    public static func note(in file: File, country: String, countryBasis: String, target: String?, serviceIDs: [String] = [], hosts: [String] = []) -> Note? {
        guard let code = try? iso(country), let place = file.countries.first(where: { $0.code.uppercased() == code }) else { return nil }
        let names = Set((hosts + [target].compactMap { $0 }).map(host))
        let ids = Set(serviceIDs.map { $0.lowercased() })
        let rows = place.entries.filter { visible($0, file: file) && matches($0, hosts: names, serviceIDs: ids) }
        guard !rows.isEmpty, let summary = sentence(summary: nil, entries: rows.map(\.summary)) else { return nil }
        let sourceIDs = Array(Set(rows.flatMap(\.sources))).sorted()
        return Note(label: file.label.isEmpty ? label : file.label, country: code, countryBasis: countryBasis, updatedAt: file.updatedAt,
                    summary: rows.map(\.summary).joined(separator: " "), sentence: summary, sources: sourceIDs,
                    targets: rows.map { $0.target.isEmpty ? $0.kind : $0.target }, liveCheck: file.liveCheck)
    }

    static func locate() -> URL? {
        var folders: [URL] = []
        if let override = ProcessInfo.processInfo.environment["KILOBAT_RESTRICTIONS"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.isReadableFile(atPath: url.path) { return url }
        }
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() { folders.append(executable) }
        folders.append(contentsOf: GeoIP.resources)
        var cursor = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<5 {
            folders.append(cursor.appendingPathComponent("site/src/data/restrictions"))
            folders.append(cursor.appendingPathComponent("Assets/Restrictions"))
            folders.append(cursor.appendingPathComponent("site/public/restrictions"))
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }
        for folder in folders {
            for name in fileNames {
                let url = folder.appendingPathComponent(name)
                if FileManager.default.isReadableFile(atPath: url.path) { return url }
            }
        }
        return nil
    }

    static func iso(_ code: String) throws -> String {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let letters = normalized.unicodeScalars.allSatisfy { $0.value < 128 && CharacterSet.uppercaseLetters.contains($0) }
        guard normalized.count == 2, letters else {
            throw ExpectedRestrictionsError("Use a two-letter ISO country code, such as DE.")
        }
        return normalized
    }

    static func visible(_ entry: Entry, file: File) -> Bool {
        let ids = Set(entry.sources)
        let ingested = file.sources.contains { ids.contains($0.id) && $0.ingest }
        let summary = entry.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return ingested && !summary.isEmpty && !advice(summary)
    }

    /// Phrases that tell someone how to get around a block. Factual reports do not use them, and Kilobat will not show them.
    static func advice(_ text: String) -> Bool {
        let value = text.lowercased()
        let phrases = ["use a vpn", "use vpn", "try a vpn", "install a vpn", "use a proxy", "try a proxy", "circumvent", "bypass", "get around", "way around", "work around", "change your dns", "switch dns", "use tor"]
        return phrases.contains { value.contains($0) }
    }

    static func matches(_ entry: Entry, hosts: Set<String>, serviceIDs: Set<String>) -> Bool {
        if entry.kind == "shutdown" { return true }
        let target = host(entry.target)
        if entry.kind == "service" {
            if serviceIDs.contains(entry.target.lowercased()) { return true }
            if serviceIDs.contains(target) { return true }
        }
        guard !target.isEmpty else { return false }
        return hosts.contains { $0 == target || $0.hasSuffix("." + target) }
    }

    static func host(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = name.range(of: "://") { name = String(name[scheme.upperBound...]) }
        if let slash = name.firstIndex(of: "/") { name = String(name[..<slash]) }
        if name.filter({ $0 == ":" }).count == 1, let colon = name.lastIndex(of: ":") { name = String(name[..<colon]) }
        while name.hasSuffix(".") { name.removeLast() }
        return name
    }

    static func listed(_ entry: Entry) -> ListedEntry {
        ListedEntry(target: entry.target, kind: entry.kind, summary: entry.summary, sources: entry.sources, asOf: entry.asOf, citations: entry.links)
    }

    static func sentence(summary: String?, entries: [String]) -> String? {
        let parts = ([summary].compactMap { $0 } + entries).map { text -> String in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasSuffix(".") ? trimmed : trimmed + "."
        }
        guard !parts.isEmpty else { return nil }
        var body = parts.joined(separator: " ")
        if body.count > 600 { body = String(body.prefix(600)).trimmingCharacters(in: .whitespaces) + "." }
        let sentence = String(localized: "Expected here per sources: \(body) This comes from public reports, not a measurement on this Mac.",
                              comment: "Restrictions guide. The argument is a factual summary from the guide. Do not add VPN, proxy or DNS advice.")
        return advice(sentence) ? nil : sentence
    }

    static func regionName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }
}

public struct ExpectedRestrictionsError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
