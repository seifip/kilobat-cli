import Foundation
import Security

/// "What is this connection?": Kilobat's curated database of macOS processes and internet hosts, the same one that
/// builds kilobat.app/processes and kilobat.app/hosts. `script/build_explainer.py` writes it to explainer.json from
/// site/src/content/{processes,hosts}; it is looked up on this Mac, so asking never sends anything anywhere.
public struct ExplainerDatabase: Codable, Sendable, Equatable {
    public var version: Int
    public var checked: String
    public var site: String
    public var processes: [ExplainerProcess]
    public var hosts: [ExplainerHost]
}

/// Whether a firewall rule against it is harmless: nothing you rely on breaks (safe), a feature you may use stops
/// (caution), or macOS or the Mac's security needs it (avoid).
public enum ExplainerVerdict: String, Codable, Sendable {
    case safe, caution, avoid
    public var label: String {
        switch self {
        case .safe: String(localized: "Safe to block", comment: "Explainer verdict: blocking this process or host breaks nothing you rely on")
        case .caution: String(localized: "Block with care", comment: "Explainer verdict: blocking this stops a feature you may use")
        case .avoid: String(localized: "Don’t block", comment: "Explainer verdict: macOS or the Mac's security needs this")
        }
    }
}

public struct ExplainerProcess: Codable, Sendable, Equatable, Identifiable {
    public var slug: String
    public var name: String
    public var aliases: [String]
    public var ids: [String]
    public var paths: [String]
    public var labels: [String]
    public var maker: String
    public var category: String
    public var summary: String
    public var normal: String
    public var heavy: [String]
    public var verdict: ExplainerVerdict
    public var block: String
    public var breaks: [String]
    public var reduce: String
    public var hosts: [String]
    public var checked: String
    public var id: String { slug }
    public var url: URL { URL(string: "https://kilobat.app/processes/\(slug)")! }
}

public struct ExplainerHost: Codable, Sendable, Equatable, Identifiable {
    public var slug: String
    public var host: String
    /// Exact names, and `*.suffix` for every name under a domain (not the domain itself).
    public var match: [String]
    public var owner: String
    public var category: String
    public var summary: String
    public var verdict: ExplainerVerdict
    public var block: String
    public var breaks: [String]
    public var processes: [String]
    public var checked: String
    public var id: String { slug }
    public var url: URL { URL(string: "https://kilobat.app/hosts/\(slug)")! }
}

/// What Kilobat knows about one connection, process or host, from this Mac alone. Every field is optional: a
/// Blocked attempts row has a bundle ID and a host, a Connections row a process name, a PID and an address.
public struct ExplainSubject: Sendable, Equatable, Hashable, Codable {
    public var process: String?
    public var path: String?
    /// A bundle ID or code-signing identifier, or Kilobat's `process:<name>` app id.
    public var identifier: String?
    /// "Apple", "Developer ID: Name (TEAMID)", "Signed, no team" or "Unsigned", from the code signature on this Mac.
    public var signer: String?
    public var host: String?
    public var address: String?
    public init(process: String? = nil, path: String? = nil, identifier: String? = nil, signer: String? = nil, host: String? = nil, address: String? = nil) {
        self.process = process?.nilIfBlank
        self.path = path?.nilIfBlank
        self.identifier = identifier?.nilIfBlank
        self.signer = signer?.nilIfBlank
        self.host = host?.nilIfBlank
        self.address = address?.nilIfBlank
    }
    public var isEmpty: Bool { process == nil && path == nil && identifier == nil && host == nil && address == nil }
}

/// Facts Kilobat has about something the database doesn't know: shown as they are, and the only input to the
/// on-device best guess.
public struct ExplainerFacts: Sendable, Hashable, Codable {
    public var process: String?
    public var path: String?
    public var identifier: String?
    public var signer: String?
    public var host: String?
    public var address: String?
    /// The network the address belongs to, such as Apple or Akamai, from Kilobat's bundled table; nil for most.
    public var network: String?
    /// The country the address is registered in, from the bundled DB-IP table.
    public var country: String?
    /// Where the code lives: part of macOS, an app, or a command-line tool someone installed.
    public var kind: String?
    public var isEmpty: Bool { [process, path, identifier, signer, host, address, network, country].allSatisfy { $0 == nil } }
}

public struct Explanation: Sendable, Equatable, Codable {
    public var process: ExplainerProcess?
    public var host: ExplainerHost?
    public var facts: ExplainerFacts
    /// Neither the process nor the host is in the database: the facts are all there is, plus the on-device guess.
    public var unknown: Bool { process == nil && host == nil }
}

public final class Explainer: @unchecked Sendable {
    public static let shared = Explainer()
    private let lock = NSLock()
    private var loaded = false
    private var source: Data?
    private var database: ExplainerDatabase?

    /// The bundled database, or the installed app's when the CLI runs on its own (or the file KILOBAT_EXPLAINER names).
    public init() {}
    /// A database from its JSON, for tests.
    public init(json: Data) { source = json }

    public var available: Bool { load() != nil }
    public var processes: [ExplainerProcess] { load()?.processes ?? [] }
    public var hosts: [ExplainerHost] { load()?.hosts ?? [] }
    public var checked: String? { load()?.checked }

    public func process(slug: String) -> ExplainerProcess? { processes.first { $0.slug == slug } }
    public func host(slug: String) -> ExplainerHost? { hosts.first { $0.slug == slug } }

    /// The process entry for a running process: by its executable path first, then its signing identifier or bundle
    /// ID, then its name. A 15-character name, as nettop and Kilobat cut them, matches the one entry it begins.
    public func process(name: String? = nil, path: String? = nil, identifier: String? = nil) -> ExplainerProcess? {
        let all = processes
        if let path = path?.nilIfBlank {
            if let hit = all.first(where: { $0.paths.contains { Self.pathMatches(pattern: $0, path: path) } }) { return hit }
        }
        if var id = identifier?.nilIfBlank {
            if id.hasPrefix("process:") { id = String(id.dropFirst(8)); if let hit = byName(id, in: all) { return hit } }
            let lower = id.lowercased()
            if let hit = all.first(where: { $0.ids.contains { $0.lowercased() == lower } }) { return hit }
            // Electron and Chromium helpers are signed as <app bundle ID>.helper.
            if lower.hasSuffix(".helper"), !lower.hasPrefix("com.google.chrome") { return all.first { $0.slug == "electron-helpers" } }
        }
        if let name = name?.nilIfBlank { return byName(name, in: all) }
        if let path = path?.nilIfBlank { return byName((path as NSString).lastPathComponent, in: all) }
        return nil
    }

    private func byName(_ raw: String, in all: [ExplainerProcess]) -> ExplainerProcess? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        let lower = name.lowercased()
        let names: (ExplainerProcess) -> [String] = { [$0.name] + $0.aliases.filter { !$0.contains("*") } }
        if let hit = all.first(where: { names($0).contains { $0.lowercased() == lower } }) { return hit }
        // nettop cuts names to 15 characters: "identityservice" is identityservicesd, when only one entry begins so.
        if name.count == 15 {
            let begins = all.filter { names($0).contains { $0.lowercased().hasPrefix(lower) } }
            if begins.count == 1 { return begins[0] }
        }
        // Name patterns such as "* Helper (Renderer)", for apps built on Electron.
        return all.first { $0.aliases.contains { $0.contains("*") && Self.glob($0.lowercased(), lower) } }
    }

    /// The host entry for a name: an exact name first, then the longest `*.suffix` the name is under.
    public func host(_ raw: String) -> ExplainerHost? {
        let name = Self.normalizedHost(raw)
        guard !name.isEmpty else { return nil }
        let all = hosts
        if let hit = all.first(where: { $0.match.contains(name) }) { return hit }
        var best: (ExplainerHost, Int)?
        for entry in all {
            for pattern in entry.match where pattern.hasPrefix("*.") {
                let suffix = String(pattern.dropFirst(1))
                if name.hasSuffix(suffix), name.count > suffix.count, suffix.count > (best?.1 ?? 0) { best = (entry, suffix.count) }
            }
        }
        return best?.0
    }

    /// Everything Kilobat can say about a subject from this Mac: its entries, and the facts for the rest.
    public func explain(_ subject: ExplainSubject) -> Explanation {
        let process = (subject.process ?? subject.path ?? subject.identifier) == nil ? nil
            : self.process(name: subject.process, path: subject.path, identifier: subject.identifier)
        let host = subject.host.flatMap { self.host($0) }
        return Explanation(process: process, host: host, facts: Self.facts(subject))
    }

    /// The facts about a subject, without any lookup off the Mac: the network owner and country from Kilobat's bundled
    /// tables, and where the code lives from its path.
    public static func facts(_ subject: ExplainSubject, owners: NetworkOwners = .shared, geo: GeoIP = .shared) -> ExplainerFacts {
        var facts = ExplainerFacts(process: subject.process, path: subject.path, identifier: subject.identifier, signer: subject.signer,
                                   host: subject.host, address: subject.address)
        if let address = subject.address {
            facts.network = owners.owner(address).map { ServiceSpeedCatalog.networks[$0] ?? $0 }
            facts.country = geo.country(address)?.name
        }
        if let path = subject.path {
            switch ProcessOwnership.kind(bundlePath: ProcessOwnership.outerApplication(in: path), executable: path) {
            case .system: facts.kind = String(localized: "Part of macOS, by its location", comment: "Explainer fact: the executable is in a macOS system folder")
            case .app: facts.kind = String(localized: "Inside an app", comment: "Explainer fact: the executable is inside an .app bundle")
            case .tool: facts.kind = String(localized: "A command-line tool someone installed", comment: "Explainer fact: the executable is a tool outside macOS and apps")
            }
        }
        return facts
    }

    /// Who signed the code at a path, read on this Mac with the Security framework: "Apple", the Developer ID team,
    /// "Signed, no team" or "Unsigned". Nil when the file isn't there.
    public static func signer(path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return String(localized: "Unsigned", comment: "Explainer fact: code without a signature") }
        var requirement: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess, let requirement,
           SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess { return "Apple" }
        guard dictionary[kSecCodeInfoIdentifier as String] != nil else { return String(localized: "Unsigned", comment: "Explainer fact: code without a signature") }
        if let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String {
            let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate]
            let summary = certificates?.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
            return summary.map { "\($0.replacingOccurrences(of: "Developer ID Application: ", with: "")) (\(team))" } ?? team
        }
        return String(localized: "Signed, no team", comment: "Explainer fact: signed ad hoc, without a developer team")
    }

    public static func normalizedHost(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = name.range(of: "://") { name = String(name[scheme.upperBound...]) }
        if let slash = name.firstIndex(of: "/") { name = String(name[..<slash]) }
        if name.hasPrefix("[") { return "" }
        if name.filter({ $0 == ":" }).count == 1, let colon = name.lastIndex(of: ":") { name = String(name[..<colon]) }
        while name.hasSuffix(".") { name.removeLast() }
        return name
    }

    /// A path in the database matches a running executable: exactly, with ~ for the home folder, or with <…> standing
    /// for one path component (/Applications/<App>.app/…).
    static func pathMatches(pattern: String, path: String) -> Bool {
        var pattern = pattern
        if pattern.hasPrefix("~/") { pattern = NSHomeDirectory() + pattern.dropFirst(1) }
        if !pattern.contains("<") { return pattern == path || path.hasPrefix(pattern + "/") }
        let expression = "^" + NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: #"<[^>]*>"#, with: "[^/]+", options: .regularExpression) + "$"
        return path.range(of: expression, options: .regularExpression) != nil
    }

    static func glob(_ pattern: String, _ text: String) -> Bool {
        let expression = "^" + NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: #"\*"#, with: ".+") + "$"
        return text.range(of: expression, options: .regularExpression) != nil
    }

    private func load() -> ExplainerDatabase? {
        lock.lock(); defer { lock.unlock() }
        if loaded { return database }
        loaded = true
        // KILOBAT_EXPLAINER names a copy to use instead, for a CLI built from source (Assets/Explainer/explainer.json).
        let override = ProcessInfo.processInfo.environment["KILOBAT_EXPLAINER"].flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
        let data = source ?? override ?? GeoIP.resources.lazy.compactMap { try? Data(contentsOf: $0.appendingPathComponent("explainer.json")) }.first
        database = data.flatMap { try? JSONDecoder().decode(ExplainerDatabase.self, from: $0) }
        return database
    }
}

/// One question for `kilobat explain`: a process (name, path, bundle ID or process:<name>), a host, or both.
public struct ExplainQuery: Equatable, Sendable {
    public var process: String?
    public var host: String?
    public init(process: String? = nil, host: String? = nil) { self.process = process; self.host = host }

    public static let usage = "Use explain <process|host…> [--process <name>] [--host <name>] [--json]."

    public struct ArgumentError: LocalizedError { public var errorDescription: String? { ExplainQuery.usage } }

    /// The questions on a command line (args[0] is the command). A bare word is a host when it looks like one, otherwise
    /// a process; --process and --host say which and pair up into one question, about one connection.
    public static func parse(_ args: [String], explainer: Explainer = .shared) throws -> (queries: [ExplainQuery], json: Bool) {
        var queries: [ExplainQuery] = [], json = false, paired = ExplainQuery()
        var index = 1
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--json": json = true; index += 1
            case "--process", "--host":
                guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else { throw ArgumentError() }
                if arg == "--process" { paired.process = args[index + 1] } else { paired.host = args[index + 1] }
                index += 2
            default:
                guard !arg.hasPrefix("--") else { throw ArgumentError() }
                queries.append(looksLikeHost(arg, explainer: explainer) ? ExplainQuery(host: arg) : ExplainQuery(process: arg))
                index += 1
            }
        }
        if paired.process != nil || paired.host != nil { queries.insert(paired, at: 0) }
        guard !queries.isEmpty else { throw ArgumentError() }
        return (queries, json)
    }

    /// gateway.icloud.com and https://example.com are hosts; nsurlsessiond, /usr/libexec/trustd, process:node and
    /// bundle IDs such as com.apple.cloudd or com.apple.WebKit.Networking are processes.
    public static func looksLikeHost(_ text: String, explainer: Explainer = .shared) -> Bool {
        if text.hasPrefix("/") || text.hasPrefix("process:") || text.contains(" ") { return false }
        if text.contains("://") { return true }
        guard text.contains(".") else { return false }
        if explainer.host(text) != nil { return true }
        if explainer.process(name: text, identifier: text) != nil { return false }
        let parts = text.split(separator: ".")
        // Reverse-DNS bundle IDs start with a top-level domain: com.apple.x, org.sparkle-project.x, us.zoom.xos.
        if parts.count >= 3, let first = parts.first, ["com", "org", "net", "io", "us", "co", "app", "dev"].contains(first.lowercased()) { return false }
        return true
    }

    /// What the question says about the subject.
    public var subject: ExplainSubject {
        guard let process else { return ExplainSubject(host: host) }
        let path = process.hasPrefix("/") || process.hasPrefix("~/") ? (process as NSString).expandingTildeInPath : nil
        return ExplainSubject(process: path == nil && !process.hasPrefix("process:") ? process : nil, path: path,
                              identifier: path == nil ? process : nil, host: host)
    }
}

/// The on-device best guess for a process or host the database doesn't know. Core builds the prompt and cleans the
/// answer; the app supplies the model (Apple's Foundation Models framework on macOS 26 and later), so tests can
/// supply a fake one. Only the facts above go in, and nothing leaves the Mac.
public protocol ExplainerModel: Sendable {
    /// Whether the model can answer now. False hides the guess; the facts still show.
    var isAvailable: Bool { get }
    func respond(instructions: String, prompt: String) async throws -> String
}

public enum ExplainerGuess {
    /// The longest answer kept, in characters: two or three short sentences.
    public static let limit = 320

    public static let instructions = """
        You explain to a Mac user, in plain English, what a process or internet host on their Mac probably is. \
        Use only the facts given. Answer in at most three short sentences. Start with the most likely identity. \
        Say "probably" or "likely" when you are not certain, and say "I can't tell" when the facts aren't enough. \
        Never claim it is safe or malicious. Never invent a company, product, setting or website. No lists, no markdown, no links.
        """

    /// The prompt for a subject: the facts only, one per line.
    public static func prompt(_ facts: ExplainerFacts) -> String {
        var lines: [String] = []
        if let value = facts.process { lines.append("Process name: \(value)") }
        if let value = facts.path { lines.append("Executable path: \(value)") }
        if let value = facts.identifier, !value.hasPrefix("process:") { lines.append("Bundle or signing identifier: \(value)") }
        if let value = facts.signer { lines.append("Code signature: \(value)") }
        if let value = facts.kind { lines.append("Location: \(value)") }
        if let value = facts.host { lines.append("Host it connects to: \(value)") }
        if let value = facts.address { lines.append("Remote address: \(value)") }
        if let value = facts.network { lines.append("Network that owns the address: \(value)") }
        if let value = facts.country { lines.append("Country the address is registered in: \(value)") }
        return "What is this?\n" + lines.joined(separator: "\n")
    }

    /// The model's answer as shown: plain text, no markdown or links, at most three sentences and `limit` characters.
    /// Nil when nothing useful is left.
    public static func clean(_ raw: String) -> String? {
        var text = raw.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[*_`#>]+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*[-•]\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 8 else { return nil }
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, stop in
            if let sentence = sentence?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty { sentences.append(sentence) }
            if sentences.count == 3 { stop = true }
        }
        var result = sentences.isEmpty ? text : sentences.joined(separator: " ")
        if result.count > limit {
            result = String(result.prefix(limit))
            if let space = result.lastIndex(of: " ") { result = String(result[..<space]) }
            result += "…"
        }
        return result
    }

    /// Asks the model, or returns nil when it's unavailable, fails or says nothing useful. Never throws: the popover
    /// shows the facts either way.
    public static func guess(_ facts: ExplainerFacts, model: ExplainerModel) async -> String? {
        guard model.isAvailable, !facts.isEmpty else { return nil }
        guard let answer = try? await model.respond(instructions: instructions, prompt: prompt(facts)) else { return nil }
        return clean(answer)
    }
}

extension String {
    fileprivate var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
