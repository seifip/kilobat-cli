import Foundation
import Observation

/// One list Protection can download. Lists are fetched on this Mac from their own sites, never bundled with Kilobat.
public struct ProtectionList: Sendable, Identifiable, Equatable {
    public enum Group: String, Sendable { case threats, trackers }
    public let id: String
    public let name: String
    public let url: URL
    public let homepage: URL
    public let licence: String
    public let category: ProtectionCategory
    public let group: Group
    /// Fewer entries than this means the download is broken (an error page, a truncated file): the last good copy stays.
    public let minimum: Int
}

/// The lists, checked on 2026-11-01.
public enum ProtectionLists {
    private static func list(_ id: String, _ name: String, _ url: String, _ homepage: String, _ licence: String, _ category: ProtectionCategory,
                             _ group: ProtectionList.Group, minimum: Int) -> ProtectionList {
        ProtectionList(id: id, name: name, url: URL(string: url)!, homepage: URL(string: homepage)!, licence: licence, category: category, group: group, minimum: minimum)
    }
    static let hagezi = "https://github.com/hagezi/dns-blocklists"
    static let hageziRaw = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/"

    /// On with Pro: all four together.
    public static let threats: [ProtectionList] = [
        list("hagezi-tif-mini", "HaGeZi Threat Intelligence Feeds", hageziRaw + "wildcard/tif.mini-onlydomains.txt", hagezi, "GPL-3.0", .threat, .threats, minimum: 50_000),
        list("hagezi-tif-ips", "HaGeZi Threat Intelligence Feeds (IPs)", hageziRaw + "ips/tif.txt", hagezi, "GPL-3.0", .threat, .threats, minimum: 5_000),
        list("urlhaus", "URLhaus", "https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-domains.txt",
             "https://gitlab.com/malware-filter/urlhaus-filter", "CC0-1.0 (URLhaus data, CC0)", .malware, .threats, minimum: 1_000),
        list("hagezi-fake", "HaGeZi Fake", hageziRaw + "wildcard/fake-onlydomains.txt", hagezi, "GPL-3.0", .scam, .threats, minimum: 2_000),
    ]
    /// Off until turned on; one at a time, Light by default.
    public static let trackers: [ProtectionList] = [
        list("hagezi-light", "HaGeZi Multi Light", hageziRaw + "wildcard/light-onlydomains.txt", hagezi, "GPL-3.0", .tracker, .trackers, minimum: 20_000),
        list("hagezi-normal", "HaGeZi Multi Normal", hageziRaw + "wildcard/multi-onlydomains.txt", hagezi, "GPL-3.0", .tracker, .trackers, minimum: 50_000),
        list("oisd-small", "OISD small", "https://small.oisd.nl/domainswild2", "https://oisd.nl", "GPL-3.0", .tracker, .trackers, minimum: 20_000),
        list("stevenblack", "StevenBlack hosts", "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts", "https://github.com/StevenBlack/hosts", "MIT", .tracker, .trackers, minimum: 20_000),
    ]
    public static let defaultTracker = "hagezi-light"
    public static var all: [ProtectionList] { threats + trackers }
    public static func tracker(_ id: String?) -> ProtectionList { trackers.first { $0.id == id } ?? trackers[0] }
}

/// Hosts, domains-only and AdBlock (`||domain^`) lists, with comments. Hosts files are matched like domain lists:
/// an entry covers its subdomains.
public enum BlocklistParser {
    public struct Parsed: Equatable, Sendable {
        public var domains: [String] = []
        public var addresses: [String] = []
        /// Lines that held something but no usable domain or address (exception rules, paths, cosmetic filters).
        public var skipped = 0
        public var count: Int { domains.count + addresses.count }
    }
    static let ignored: Set<String> = ["localhost", "localhost.localdomain", "local", "broadcasthost", "ip6-localhost", "ip6-loopback", "ip6-localnet",
                                       "ip6-mcastprefix", "ip6-allnodes", "ip6-allrouters", "ip6-allhosts", "0.0.0.0"]

    public static func parse(_ text: String) -> Parsed {
        var parsed = Parsed()
        var domains = Set<String>(), addresses = Set<String>()
        func add(_ word: Substring) -> Bool {
            var word = word
            if word.hasPrefix("*.") { word = word.dropFirst(2) }
            guard !ignored.contains(String(word)), let host = HostName.normalize(String(word)) else { return false }
            if HostName.isAddress(host) {
                // Hosts files point names at 0.0.0.0 or loopback; the local network is never blocked either.
                guard !HostName.isLocal(nil, address: host), host != "::" else { return false }
                addresses.insert(host); return true
            }
            guard host.contains("."), !ignored.contains(host) else { return false }
            domains.insert(host); return true
        }
        text.enumerateLines { raw, _ in
            var line = Substring(raw).trimmingCharacters(in: .whitespaces)[...]
            guard let first = line.first, first != "#", first != "!", first != "[" else { return }
            if let hash = line.firstIndex(of: "#") { line = line[..<hash] }
            line = line.trimmingCharacters(in: .whitespaces)[...]
            guard !line.isEmpty else { return }
            if line.hasPrefix("@@") { parsed.skipped += 1; return }
            if line.hasPrefix("||") {
                let rule = line.dropFirst(2)
                let end = rule.firstIndex { $0 == "^" || $0 == "$" } ?? rule.endIndex
                let options = rule[end...].drop { $0 == "^" }
                // Only whole-domain rules: paths, wildcards inside a name and modifiers other than $important don't map onto a domain.
                guard !rule[..<end].contains(where: { $0 == "/" || $0 == "*" || $0 == ":" }), options.isEmpty || options == "$important",
                      add(rule[..<end]) else { parsed.skipped += 1; return }
                return
            }
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if words.count > 1, AddressRange.parse(String(words[0])) != nil {
                for word in words.dropFirst() where !add(word) { if !ignored.contains(String(word)) { parsed.skipped += 1 } }
            } else if words.count == 1 {
                if !add(words[0]) { parsed.skipped += 1 }
            } else { parsed.skipped += 1 }
        }
        parsed.domains = domains.sorted(); parsed.addresses = addresses.sorted()
        return parsed
    }
}

/// What Protection keeps about each list: the cache validators, when it last checked and changed, and how it went.
public struct ProtectionListState: Codable, Equatable, Sendable {
    public var etag: String?
    public var lastModified: String?
    public var checked: Date?
    /// When a download last replaced the copy kept.
    public var updated: Date?
    public var entries: Int = 0
    public var bytes: Int = 0
    /// Why the last check failed; the copy from `updated` is still used.
    public var error: String?
    public init() {}
}

public struct ProtectionState: Codable, Equatable, Sendable {
    public var lists: [String: ProtectionListState] = [:]
    public var built: Date?
    public init() {}
}

/// Downloads lists with their cache validators, checks each download and keeps the last good copy, then compiles the
/// lists in use into the index the filter maps. Shared by the app and `kilobat protect update`.
public struct ProtectionUpdater: Sendable {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public let directory: URL
    public let fetch: Fetch
    public static let interval: TimeInterval = 86_400
    public static let maximumBytes = 64 << 20

    public init(directory: URL = ProtectionUpdater.defaultDirectory, fetch: @escaping Fetch = { request in try await URLSession.shared.data(for: request) }) {
        self.directory = directory; self.fetch = fetch
    }
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat/Protection")
    }
    public var stateURL: URL { directory.appendingPathComponent("lists.json") }
    public var indexURL: URL { directory.appendingPathComponent("protection.index") }
    func fileURL(_ list: ProtectionList) -> URL { directory.appendingPathComponent(list.id + ".txt") }

    public func loadState() -> ProtectionState {
        guard let data = try? Data(contentsOf: stateURL) else { return ProtectionState() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ProtectionState.self, from: data)) ?? ProtectionState()
    }
    func save(_ state: ProtectionState) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? encoder.encode(state).write(to: stateURL, options: [.atomic])
    }

    /// Checks each list not checked in the last day (all of them with `force`). A list that fails to download or
    /// doesn't check out keeps its previous copy and records why.
    public func update(_ lists: [ProtectionList], force: Bool = false, now: Date = Date()) async -> ProtectionState {
        var state = loadState()
        for list in lists {
            var entry = state.lists[list.id] ?? ProtectionListState()
            let present = FileManager.default.fileExists(atPath: fileURL(list).path)
            if !force, present, let checked = entry.checked, now.timeIntervalSince(checked) < Self.interval - 600 { continue }
            var request = URLRequest(url: list.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            request.setValue("Kilobat (+https://kilobat.app)", forHTTPHeaderField: "User-Agent")
            if present {
                if let etag = entry.etag, !etag.isEmpty { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
                if let modified = entry.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
            }
            entry.checked = now
            do {
                let (data, response) = try await fetch(request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 304 && present { entry.error = nil }
                else if status == 200 {
                    let parsed = try Self.validate(data, list: list, previous: present ? entry.entries : 0)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try data.write(to: fileURL(list), options: [.atomic])
                    let http = response as? HTTPURLResponse
                    entry.etag = http?.value(forHTTPHeaderField: "ETag"); entry.lastModified = http?.value(forHTTPHeaderField: "Last-Modified")
                    entry.updated = now; entry.entries = parsed.count; entry.bytes = data.count; entry.error = nil
                } else { entry.error = "HTTP \(status)" }
            } catch let failure as Failure { entry.error = failure.message }
            catch { entry.error = error.localizedDescription }
            state.lists[list.id] = entry
        }
        save(state)
        return state
    }

    public struct Failure: Error, Equatable { public let message: String }

    /// A sane size, parseable, and not a sudden collapse: at least the list's minimum and half its last count.
    public static func validate(_ data: Data, list: ProtectionList, previous: Int) throws -> BlocklistParser.Parsed {
        guard data.count <= maximumBytes else { throw Failure(message: "larger than 64 MB") }
        guard !data.isEmpty else { throw Failure(message: "empty download") }
        let parsed = BlocklistParser.parse(String(decoding: data, as: UTF8.self))
        guard parsed.count >= list.minimum else { throw Failure(message: "only \(parsed.count) entries, expected at least \(list.minimum)") }
        guard previous == 0 || parsed.count * 2 >= previous else { throw Failure(message: "\(parsed.count) entries, down from \(previous)") }
        guard parsed.skipped <= max(1_000, parsed.count / 10) else { throw Failure(message: "\(parsed.skipped) lines that aren't domains") }
        return parsed
    }

    /// Compiles the downloaded lists (and the hosts agents already used) into the index, written next to them.
    /// Returns the index, or nil when no list has been downloaded yet.
    @discardableResult public func build(_ lists: [ProtectionList], known: [String] = [], now: Date = Date()) -> ProtectionIndex? {
        let state = loadState()
        var input: [(slot: ProtectionIndex.Slot, entries: [String])] = []
        for (offset, list) in lists.enumerated() {
            guard let data = try? Data(contentsOf: fileURL(list)) else { continue }
            let parsed = BlocklistParser.parse(String(decoding: data, as: UTF8.self))
            input.append((ProtectionIndex.Slot(slot: UInt8(offset + 1), id: list.id, name: list.name, category: list.category, entries: parsed.count,
                                               updated: state.lists[list.id]?.updated), parsed.domains + parsed.addresses))
        }
        guard !input.isEmpty else { return nil }
        let hosts = Array(Set(known.compactMap(HostName.normalize)))
        if !hosts.isEmpty { input.append((ProtectionIndex.Slot(slot: 250, id: "agent-known", name: "Hosts agents used before", category: .known, entries: hosts.count), hosts)) }
        let data = ProtectionIndex.build(input, built: now)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? data.write(to: indexURL, options: [.atomic])) != nil else { return ProtectionIndex(data: data) }
        var saved = state; saved.built = now; save(saved)
        return ProtectionIndex(contentsOf: indexURL)
    }

    public func loadIndex() -> ProtectionIndex? { ProtectionIndex(contentsOf: indexURL) }
}

/// Protection's settings as the person chose them, with Pro applied: what the filter gets.
public enum ProtectionPreferences {
    public static func threats(_ preferences: SavedPreferences, pro: Bool) -> Bool { pro && preferences.protectThreats != false }
    public static func trackers(_ preferences: SavedPreferences) -> Bool { preferences.protectTrackers == true }
    public static func agentGuard(_ preferences: SavedPreferences, pro: Bool) -> Bool { pro && preferences.agentGuard == true }

    /// The lists to download: threats for Threats or the agent guard, the chosen tracker list for Trackers.
    public static func lists(_ preferences: SavedPreferences, pro: Bool) -> [ProtectionList] {
        (threats(preferences, pro: pro) || agentGuard(preferences, pro: pro) ? ProtectionLists.threats : [])
            + (trackers(preferences) ? [ProtectionLists.tracker(preferences.trackerList)] : [])
    }
    public static func settings(_ preferences: SavedPreferences, pro: Bool, digest: String? = nil) -> ProtectionSettings {
        ProtectionSettings(threats: threats(preferences, pro: pro), trackers: trackers(preferences), agentGuard: agentGuard(preferences, pro: pro),
                           uploadLimit: UInt64(max(1, min(10_000, preferences.agentGuardUploadMB ?? 10))) * 1_000_000,
                           allowed: (preferences.allowedSites ?? []).compactMap(HostName.normalize), digest: digest)
    }

    /// "Allow this site" for a host or domain; returns the normalised name, or nil when it isn't one.
    @discardableResult public static func allow(_ site: String, in preferences: inout SavedPreferences) -> String? {
        guard let host = HostName.normalize(site.hasPrefix("*.") ? String(site.dropFirst(2)) : site) else { return nil }
        var sites = preferences.allowedSites ?? []
        if !sites.contains(host) { sites.append(host) }
        preferences.allowedSites = sites.sorted()
        return host
    }
    @discardableResult public static func unallow(_ site: String, in preferences: inout SavedPreferences) -> Bool {
        guard let host = HostName.normalize(site.hasPrefix("*.") ? String(site.dropFirst(2)) : site), var sites = preferences.allowedSites, sites.contains(host) else { return false }
        sites.removeAll { $0 == host }
        preferences.allowedSites = sites.isEmpty ? nil : sites
        return true
    }
}

/// What `kilobat protect check`, `check_host_reputation` and the app say about one host.
public struct ProtectionCheckResult: Codable, Equatable, Sendable {
    public struct Listing: Codable, Equatable, Sendable {
        public let list: String
        public let id: String
        public let category: String
        public let licence: String?
    }
    public let host: String
    /// The listed name: the host or the parent domain that covers it.
    public let entry: String?
    public let listed: Bool
    public let lists: [Listing]
    /// "malware", "phishing", "scam", "threat" or "tracker".
    public let category: String?
    public let allowedByYou: Bool
    public let localNetwork: Bool
    /// Whether the filter would block it for every app with the current settings (before app and destination rules).
    public let wouldBlock: Bool
    public let indexBuilt: Date?
    public let note: String

    public static func check(_ raw: String, index: ProtectionIndex?, settings: ProtectionSettings) -> ProtectionCheckResult? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: text), let host = url.host, url.scheme != nil { text = host }
        guard let host = HostName.normalize(text) else { return nil }
        let local = HostName.isLocal(host, address: nil), allowed = settings.allows(host)
        let match = index?.match(host: host, in: Set(ProtectionCategory.allCases).subtracting([.known]))
        let licences = Dictionary(ProtectionLists.all.map { ($0.id, $0.licence) }, uniquingKeysWith: { first, _ in first })
        let lists = match?.lists.map { Listing(list: $0.name, id: $0.id, category: $0.category.rawValue, licence: licences[$0.id]) } ?? []
        let flow = FilterPolicy.Flow(app: nil, process: "", host: host)
        let detail = ProtectionCheck.threat(flow, settings: ProtectionSettings(threats: settings.threats, allowed: settings.allowed), index: index, agent: { nil })
            ?? ProtectionCheck.tracker(flow, settings: settings, index: index)
        let category = detail?.kind.rawValue ?? match.map { ProtectionCheck.detail($0, agent: nil).kind.rawValue }
        let note: String
        if index == nil { note = "No lists downloaded yet. Run kilobat protect update, or turn on Protection in the Kilobat app." }
        else if local { note = "The local network is never blocked." }
        else if allowed { note = "You allowed this site, so Protection leaves it alone." }
        else if match == nil { note = "Not on any list Kilobat has. Lists cover known malicious destinations only; that a host is missing doesn't make it safe." }
        else if detail != nil { note = "Kilobat blocks this for every app." }
        else { note = "Listed, but the matching protection is off." }
        return ProtectionCheckResult(host: host, entry: match?.entry, listed: match != nil, lists: lists, category: category, allowedByYou: allowed, localNetwork: local,
                                     wouldBlock: detail != nil, indexBuilt: index?.built, note: note)
    }
}

/// Notifications at most once per app, host and day, remembered across launches.
public struct ProtectionNoticeLimiter: Codable, Equatable, Sendable {
    public var sent: [String: Date] = [:]
    public init() {}
    public mutating func allow(app: String, host: String, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        sent = sent.filter { now.timeIntervalSince($0.value) < 2 * 86_400 }
        let key = app.lowercased() + "|" + host.lowercased()
        if let last = sent[key], calendar.isDate(last, inSameDayAs: now) { return false }
        sent[key] = now
        return true
    }
}

/// Protection's status as the app, `kilobat protect status` and `get_protection_status` report it.
public struct ProtectionStatus: Codable, Equatable, Sendable {
    public struct List: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let category: String
        public let licence: String
        public let url: String
        public let entries: Int
        public let updated: Date?
        public let checked: Date?
        public let error: String?
    }
    public let threats: Bool
    public let trackers: Bool
    public let agentGuard: Bool
    public let trackerList: String
    public let uploadLimitMB: Int
    /// Threats and the agent guard are Pro; nil when the app didn't say.
    public let pro: Bool?
    /// Whether the network filter that enforces it is on; nil when the app didn't say.
    public let filterActive: Bool?
    public let threatEntries: Int
    public let trackerEntries: Int
    public let updated: Date?
    public let allowedSites: [String]
    public let lists: [List]

    public static func make(_ preferences: SavedPreferences, pro: Bool?, filterActive: Bool?, state: ProtectionState, index: ProtectionIndex?) -> ProtectionStatus {
        let lists = ProtectionPreferences.lists(preferences, pro: pro ?? true)
        let rows = lists.map { list in
            let entry = state.lists[list.id]
            return List(id: list.id, name: list.name, category: list.category.rawValue, licence: list.licence, url: list.url.absoluteString,
                        entries: entry?.entries ?? 0, updated: entry?.updated, checked: entry?.checked, error: entry?.error)
        }
        let threatIDs = Set(ProtectionLists.threats.map(\.id))
        return ProtectionStatus(threats: preferences.protectThreats != false && pro != false, trackers: preferences.protectTrackers == true,
                                agentGuard: preferences.agentGuard == true && pro != false, trackerList: ProtectionLists.tracker(preferences.trackerList).id,
                                uploadLimitMB: preferences.agentGuardUploadMB ?? 10, pro: pro, filterActive: filterActive,
                                threatEntries: rows.filter { threatIDs.contains($0.id) }.reduce(0) { $0 + $1.entries },
                                trackerEntries: rows.filter { !threatIDs.contains($0.id) }.reduce(0) { $0 + $1.entries },
                                updated: rows.compactMap(\.updated).min(), allowedSites: preferences.allowedSites ?? [], lists: rows)
    }
}

/// The app's Protection: keeps the lists current, builds the index and says how it stands.
@MainActor @Observable public final class ProtectionStore {
    public private(set) var state: ProtectionState
    public private(set) var index: ProtectionIndex?
    public private(set) var updating = false
    public var limiter: ProtectionNoticeLimiter
    @ObservationIgnored public let updater: ProtectionUpdater
    @ObservationIgnored private let limiterKey = "protection.notices"

    public init(updater: ProtectionUpdater = ProtectionUpdater()) {
        self.updater = updater
        state = updater.loadState()
        index = updater.loadIndex()
        limiter = (UserDefaults.standard.data(forKey: limiterKey).flatMap { try? JSONDecoder().decode(ProtectionNoticeLimiter.self, from: $0) }) ?? ProtectionNoticeLimiter()
    }

    /// Whether a notification about this app and host may go out today; remembers that it did.
    public func notify(app: String, host: String, now: Date = Date()) -> Bool {
        guard limiter.allow(app: app, host: host, now: now) else { return false }
        if let data = try? JSONEncoder().encode(limiter) { UserDefaults.standard.set(data, forKey: limiterKey) }
        return true
    }

    /// Clears a period or forgets a site in the memory of which notifications went out.
    @discardableResult public func erase(_ action: HistoryAction, now: Date = Date()) throws -> Int {
        if let saved = UserDefaults.standard.data(forKey: limiterKey) { _ = try JSONDecoder().decode(ProtectionNoticeLimiter.self, from: saved) }
        let removed = HistoryEraser.apply(action, to: &limiter, now: now)
        if removed > 0 { UserDefaults.standard.set(try JSONEncoder().encode(limiter), forKey: limiterKey) }
        return removed
    }

    /// The same on the app's saved copy, for the command line while the app isn't running.
    @discardableResult public nonisolated static func erase(_ action: HistoryAction, defaults: UserDefaults, now: Date = Date()) throws -> Int {
        let key = "protection.notices"
        guard let data = defaults.data(forKey: key) else { return 0 }
        var limiter = try JSONDecoder().decode(ProtectionNoticeLimiter.self, from: data)
        let removed = HistoryEraser.apply(action, to: &limiter, now: now)
        if removed > 0 { defaults.set(try JSONEncoder().encode(limiter), forKey: key) }
        return removed
    }

    /// Downloads what's due and rebuilds the index when a list changed, the lists in use changed, or the known hosts did.
    public func refresh(_ lists: [ProtectionList], known: [String], force: Bool = false) async {
        guard !updating, !lists.isEmpty else { return }
        updating = true
        let updater = updater
        let before = state
        let next = await Task.detached(priority: .utility) { await updater.update(lists, force: force) }.value
        let ids = Set(lists.map(\.id))
        let built = index.map { Set($0.slots.map(\.id)).subtracting(["agent-known"]) }
        let knownCount = index?.slots.first { $0.id == "agent-known" }?.entries ?? 0
        let changed = index == nil || built != ids || lists.contains { next.lists[$0.id]?.updated != before.lists[$0.id]?.updated }
            || Set(known.compactMap(HostName.normalize)).count != knownCount
        if changed { index = await Task.detached(priority: .utility) { updater.build(lists, known: known) }.value ?? index }
        state = updater.loadState()
        updating = false
    }

    #if DEBUG
    /// Sample list state for screenshots; nothing is downloaded.
    public func preview(_ state: ProtectionState) { self.state = state }
    #endif

    /// Newest last update among the lists in use, and their entries.
    public func summary(_ lists: [ProtectionList]) -> (entries: Int, updated: Date?, errors: [String]) {
        let rows = lists.compactMap { state.lists[$0.id] }
        return (rows.reduce(0) { $0 + $1.entries }, rows.compactMap(\.updated).min(), lists.compactMap { list in state.lists[list.id]?.error.map { list.name + ": " + $0 } })
    }
}

/// Protection in words, for the app, the notifications and the doctor.
public enum ProtectionText {
    public static func kind(_ kind: ProtectionDetail.Kind) -> String {
        switch kind {
        case .malware: String(localized: "malware", comment: "Protection: what a blocked host is known for")
        case .phishing: String(localized: "phishing", comment: "Protection: what a blocked host is known for")
        case .scam: String(localized: "scam", comment: "Protection: what a blocked host is known for")
        case .threat: String(localized: "known threat", comment: "Protection: a host on a threat list that doesn't say malware, phishing or scam")
        case .tracker: String(localized: "tracker", comment: "Protection: a tracker or ad host")
        case .agentGuard: String(localized: "agent guard", comment: "Protection: the stricter rules for AI agents")
        }
    }

    /// The agent guard's rule in words: paste site, file share, tunnel, request catcher, raw IP address, large upload.
    public static func rule(_ list: String) -> String {
        switch list {
        case "paste site": String(localized: "paste site", comment: "Agent guard rule")
        case "file share": String(localized: "file share", comment: "Agent guard rule")
        case "tunnel": String(localized: "tunnel", comment: "Agent guard rule")
        case "request catcher": String(localized: "request catcher", comment: "Agent guard rule")
        case "raw IP address": String(localized: "raw IP address", comment: "Agent guard rule")
        case "large upload to a new host": String(localized: "large upload to a new host", comment: "Agent guard rule")
        default: list
        }
    }

    /// "npm (started by Claude Code)", or the app's name.
    public static func who(_ detail: ProtectionDetail, app: String) -> String {
        if let agent = detail.agent, let process = detail.process, process.lowercased() != agent.lowercased() {
            return String(localized: "\(process) (started by \(agent))", comment: "Protection notification: a process and the agent that started it, e.g. npm (started by Claude Code)")
        }
        return detail.agent ?? app
    }

    /// The notification's title.
    public static func title(_ detail: ProtectionDetail, app: String) -> String {
        let who = who(detail, app: app)
        switch detail.kind {
        case .malware: return String(localized: "Blocked: \(who) tried to reach a known malware host", comment: "Notification title")
        case .phishing: return String(localized: "Blocked: \(who) tried to reach a known phishing site", comment: "Notification title")
        case .scam: return String(localized: "Blocked: \(who) tried to reach a known scam site", comment: "Notification title")
        case .threat: return String(localized: "Blocked: \(who) tried to reach a known malicious host", comment: "Notification title")
        case .tracker: return String(localized: "Blocked a tracker in \(who)", comment: "Notification title")
        case .agentGuard: return String(localized: "Blocked: \(who) tried to reach a \(rule(detail.list))", comment: "Notification title; the second argument is a paste site, tunnel, raw IP address and so on")
        }
    }

    public static func body(_ detail: ProtectionDetail) -> String {
        if detail.kind == .agentGuard {
            return String(localized: "\(detail.host) · The agent guard keeps agents away from it. Allow this site in Kilobat if you meant it.", comment: "Notification body")
        }
        return String(localized: "\(detail.host) · Listed by \(detail.list). Allow this site in Kilobat if it’s a mistake.", comment: "Notification body")
    }

    public static func doctor(_ detail: ProtectionDetail) -> String {
        if detail.kind == .agentGuard {
            return String(localized: "Kilobat’s agent guard blocks agents from reaching \(detail.host) (\(rule(detail.list))). Allow the site in Settings › Protection if you meant it.")
        }
        return String(localized: "\(detail.host) is a \(kind(detail.kind)) destination on \(detail.list), and Kilobat’s Protection blocks it. Allow the site in Settings › Protection if it’s a mistake.")
    }
}
