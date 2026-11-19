import Foundation

/// A rules file: every saved rule, readable as JSON, to keep a copy or move rules to another Mac. It holds each
/// profile's app and destination rules, the person's own profiles and names, sites blocked or allowed for every app,
/// blocklist exceptions, profile schedules and how new apps are treated. Timed rules are left out, since they end on
/// their own, and so are the Wi-Fi networks each profile was remembered for, whose names don't belong in a file
/// someone may share. Usage, history and destination history are never in it.
public struct RuleBackup: Codable, Equatable, Sendable {
    public static let formatName = "kilobat-rules"
    public static let currentVersion = 1
    /// Larger files are refused before they're read.
    public static let maxBytes = 2_000_000

    public var format: String
    public var version: Int
    public var exported: Date?
    /// "allow", "ask" or "block".
    public var newApps: String?
    /// Alert mode: with `newApps` "allow", new apps are also listed for review. Kept apart so a Kilobat that doesn't
    /// know it still reads the file and allows new apps.
    public var alertNewApps: Bool?
    /// Apps that ask before reaching a destination their rules don't cover.
    public var askDestinations: [String]?
    public var allowApple: Bool?
    public var profiles: [Profile]
    public var everyApp: EveryApp?
    public var schedules: [Schedule]?

    public struct Profile: Codable, Equatable, Sendable {
        /// "essentials", "work", "unrestricted", or the id of a profile the person added ("Custom-…").
        public var id: String
        /// The person's own name: always for their profiles, and for a built-in one they renamed.
        public var name: String?
        public var symbol: String?
        public var apps: [AppRule]?
        public var destinations: [DestinationRule]?
        public init(id: String, name: String? = nil, symbol: String? = nil, apps: [AppRule]? = nil, destinations: [DestinationRule]? = nil) {
            self.id = id; self.name = name; self.symbol = symbol; self.apps = apps; self.destinations = destinations
        }
    }
    public struct AppRule: Codable, Equatable, Sendable {
        /// A bundle ID, or process:<name>.
        public var app: String
        public var allow: Bool
        public init(app: String, allow: Bool) { self.app = app; self.allow = allow }
    }
    public struct DestinationRule: Codable, Equatable, Sendable {
        public var app: String
        public var host: String
        public var port: String?
        /// "any", "outgoing" or "incoming".
        public var direction: String?
        public var allow: Bool
        /// "tcp" or "udp"; absent for either. Files written before protocols existed have none.
        public var networkProtocol: String?
        /// True for the exact host only; absent (as in older files) for the domain and its subdomains.
        public var exact: Bool?
        public init(app: String, host: String, port: String? = nil, direction: String? = nil, allow: Bool, networkProtocol: String? = nil, exact: Bool? = nil) {
            self.app = app; self.host = host; self.port = port; self.direction = direction; self.allow = allow
            self.networkProtocol = networkProtocol; self.exact = exact
        }
        private enum CodingKeys: String, CodingKey { case app, host, port, direction, allow, networkProtocol = "protocol", exact }
    }
    public struct EveryApp: Codable, Equatable, Sendable {
        public var blocked: [String]?
        /// Sites no Protection list or rule applies to.
        public var allowedSites: [String]?
        /// Domains an app may reach despite the blocklist.
        public var exceptions: [Exception]?
        public init(blocked: [String]? = nil, allowedSites: [String]? = nil, exceptions: [Exception]? = nil) {
            self.blocked = blocked; self.allowedSites = allowedSites; self.exceptions = exceptions
        }
    }
    public struct Exception: Codable, Equatable, Sendable {
        public var app: String
        public var domains: [String]
        public init(app: String, domains: [String]) { self.app = app; self.domains = domains }
    }
    public struct Schedule: Codable, Equatable, Sendable {
        public var profile: String
        /// "mon" … "sun".
        public var days: [String]
        /// "09:00", 24-hour.
        public var start: String
        public var end: String
        public var on: Bool?
        public init(profile: String, days: [String], start: String, end: String, on: Bool? = nil) {
            self.profile = profile; self.days = days; self.start = start; self.end = end; self.on = on
        }
    }

    static let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    /// The file's name for a stored profile.
    static func fileID(_ raw: String) -> String {
        raw == NetworkProfile.travel.rawValue ? "essentials" : NetworkProfile.builtIn.contains { $0.rawValue == raw } ? raw.lowercased() : raw
    }
    /// The stored profile a file's id names: built-in names in any case, "travel" too.
    static func storedID(_ id: String) -> String {
        switch id.lowercased() {
        case "essentials", "travel": NetworkProfile.travel.rawValue
        case "work": NetworkProfile.work.rawValue
        case "unrestricted": NetworkProfile.unrestricted.rawValue
        default: id
        }
    }
    static func time(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
    static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, parts[0].count <= 2, parts[1].count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]),
              (0..<24).contains(hours), (0..<60).contains(minutes) else { return nil }
        return hours * 60 + minutes
    }

    // MARK: Export

    /// Every saved rule in `preferences`, timed ones aside.
    public init(_ preferences: SavedPreferences, now: Date = Date()) {
        format = Self.formatName; version = Self.currentVersion; exported = now
        newApps = preferences.askNewApps == true ? "ask" : preferences.defaultAllow ? "allow" : "block"
        alertNewApps = NewAppPolicy.mode(preferences) == .alert ? true : nil
        askDestinations = (preferences.askDestinations ?? []).isEmpty ? nil : preferences.askDestinations?.sorted()
        allowApple = preferences.allowApple == true
        let definitions = preferences.profileDefinitions ?? []
        profiles = preferences.definedProfiles.map { profile in
            let definition = definitions.first { $0.id == profile.rawValue }
            let apps = (preferences.rules[profile.rawValue] ?? [:]).sorted { $0.key < $1.key }.map { AppRule(app: $0.key, allow: $0.value) }
            let destinations = (preferences.connectionRules ?? []).filter { $0.profile == profile.rawValue && $0.expires == nil }.map {
                DestinationRule(app: $0.app, host: $0.host, port: $0.port.isEmpty ? nil : $0.port, direction: $0.direction == "any" ? nil : $0.direction, allow: $0.allowed,
                                networkProtocol: $0.transport, exact: $0.exact == true ? true : nil)
            }
            return Profile(id: Self.fileID(profile.rawValue), name: definition?.name, symbol: definition?.symbol,
                           apps: apps.isEmpty ? nil : apps, destinations: destinations.isEmpty ? nil : destinations)
        }
        let exceptions = (preferences.domainExceptions ?? [:]).filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }.map { Exception(app: $0.key, domains: $0.value.sorted()) }
        let blocked = (preferences.blockedHosts ?? []).sorted(), allowed = (preferences.allowedSites ?? []).sorted()
        everyApp = blocked.isEmpty && allowed.isEmpty && exceptions.isEmpty ? nil
            : EveryApp(blocked: blocked.isEmpty ? nil : blocked, allowedSites: allowed.isEmpty ? nil : allowed, exceptions: exceptions.isEmpty ? nil : exceptions)
        let schedules = (preferences.profileSchedules ?? []).filter(\.valid).map {
            Schedule(profile: Self.fileID($0.profile), days: $0.days.sorted().map { Self.dayNames[$0 - 1] }, start: Self.time($0.start), end: Self.time($0.end), on: $0.enabled)
        }
        self.schedules = schedules.isEmpty ? nil : schedules
    }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// "Kilobat rules 2026-11-10.json".
    public static func fileName(now: Date = Date(), calendar: Calendar = .current) -> String {
        "Kilobat rules \(DestinationHistory.day(now, calendar: calendar)).json"
    }

    // MARK: Import

    /// Reads and checks a rules file, naming the first thing wrong with it.
    public static func parse(_ data: Data) throws -> RuleBackup {
        guard data.count <= maxBytes else { throw RuleBackupError.tooLarge }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let backup: RuleBackup
        do { backup = try decoder.decode(RuleBackup.self, from: data) }
        catch {
            // A file that isn't even ours says so, rather than which key is missing.
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["format"] as? String == formatName { throw RuleBackupError.unreadable }
            throw RuleBackupError.notRules
        }
        guard backup.format == formatName else { throw RuleBackupError.notRules }
        guard backup.version >= 1, backup.version <= currentVersion else { throw RuleBackupError.newerVersion }
        try backup.validate()
        return backup
    }

    func validate() throws {
        for app in askDestinations ?? [] where !Self.validApp(app) { throw RuleBackupError.invalid(String(localized: "“\(app)” isn’t an app ID.", comment: "Rules file error")) }
        if let newApps, !["allow", "ask", "block", "alert"].contains(newApps) { throw RuleBackupError.invalid(String(localized: "“\(newApps)” isn’t a choice for new apps.", comment: "Rules file error")) }
        var ids = Set<String>(), names = Set<String>(), custom = 0
        var destinations = 0
        for profile in profiles {
            let stored = Self.storedID(profile.id)
            guard !stored.isEmpty, stored.count <= 64, !stored.contains("|") else { throw RuleBackupError.invalid(String(localized: "A profile has no usable id.", comment: "Rules file error")) }
            guard ids.insert(stored).inserted else { throw RuleBackupError.invalid(String(localized: "Profile “\(profile.id)” appears twice.", comment: "Rules file error")) }
            let builtIn = NetworkProfile.builtIn.contains { $0.rawValue == stored }
            if !builtIn {
                custom += 1
                guard profile.name?.trimmingCharacters(in: .whitespaces).isEmpty == false else { throw RuleBackupError.invalid(String(localized: "Profile “\(profile.id)” has no name.", comment: "Rules file error")) }
            }
            if let name = profile.name {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count <= ProfileEditing.maxName, !trimmed.contains("\n") else { throw RuleBackupError.invalid(String(localized: "Profile name “\(name)” is too long.", comment: "Rules file error")) }
                if !trimmed.isEmpty, !names.insert(NetworkProfile.slug(trimmed)).inserted { throw RuleBackupError.invalid(String(localized: "Two profiles are called “\(trimmed)”.", comment: "Rules file error")) }
            }
            if let symbol = profile.symbol, !ProfileSymbols.choices.contains(symbol) { throw RuleBackupError.invalid(String(localized: "Profile “\(profile.id)” has an icon Kilobat doesn’t know.", comment: "Rules file error")) }
            if stored == NetworkProfile.unrestricted.rawValue, !(profile.apps ?? []).isEmpty || !(profile.destinations ?? []).isEmpty {
                throw RuleBackupError.invalid(String(localized: "Unrestricted can’t have rules.", comment: "Rules file error"))
            }
            let apps = profile.apps ?? []
            guard apps.count <= 10_000 else { throw RuleBackupError.invalid(String(localized: "Profile “\(profile.id)” has too many app rules.", comment: "Rules file error")) }
            var seen = Set<String>()
            for rule in apps {
                guard Self.validAppRule(rule.app) else { throw RuleBackupError.invalid(String(localized: "“\(rule.app)” isn’t an app ID.", comment: "Rules file error")) }
                guard seen.insert(rule.app).inserted else { throw RuleBackupError.invalid(String(localized: "Profile “\(profile.id)” has two rules for \(rule.app).", comment: "Rules file error")) }
            }
            for rule in profile.destinations ?? [] {
                destinations += 1
                guard Self.validApp(rule.app) else { throw RuleBackupError.invalid(String(localized: "“\(rule.app)” isn’t an app ID.", comment: "Rules file error")) }
                guard Self.destinationHost(rule.host) != nil else { throw RuleBackupError.invalid(String(localized: "“\(rule.host)” isn’t a domain or IP address.", comment: "Rules file error")) }
                if let port = rule.port, !port.isEmpty, Int(port).map({ (1...65535).contains($0) }) != true { throw RuleBackupError.invalid(String(localized: "“\(port)” isn’t a port from 1 to 65535.", comment: "Rules file error")) }
                if let direction = rule.direction, !["any", "outgoing", "incoming"].contains(direction) { throw RuleBackupError.invalid(String(localized: "“\(direction)” isn’t a direction.", comment: "Rules file error")) }
                if let proto = rule.networkProtocol, !["any", "tcp", "udp"].contains(proto.lowercased()) { throw RuleBackupError.invalid(String(localized: "“\(proto)” isn’t a protocol; use tcp or udp.", comment: "Rules file error")) }
            }
        }
        guard custom <= ProfileEditing.maxCustom else { throw RuleBackupError.invalid(String(localized: "The file has more than \(ProfileEditing.maxCustom) profiles of your own.", comment: "Rules file error")) }
        guard destinations <= 5_000 else { throw RuleBackupError.invalid(String(localized: "The file has too many destination rules.", comment: "Rules file error")) }
        if let everyApp {
            let hosts = (everyApp.blocked ?? []) + (everyApp.allowedSites ?? [])
            guard hosts.count <= 20_000 else { throw RuleBackupError.invalid(String(localized: "The file has too many sites.", comment: "Rules file error")) }
            for host in everyApp.blocked ?? [] where DomainPolicy.entry(host) == nil { throw RuleBackupError.invalid(String(localized: "“\(host)” isn’t a domain, IP address or range.", comment: "Rules file error")) }
            for site in everyApp.allowedSites ?? [] where HostName.normalize(site) == nil { throw RuleBackupError.invalid(String(localized: "“\(site)” isn’t a site.", comment: "Rules file error")) }
            for exception in everyApp.exceptions ?? [] {
                guard Self.validApp(exception.app) else { throw RuleBackupError.invalid(String(localized: "“\(exception.app)” isn’t an app ID.", comment: "Rules file error")) }
                for domain in exception.domains where DomainPolicy.entry(domain) == nil { throw RuleBackupError.invalid(String(localized: "“\(domain)” isn’t a domain.", comment: "Rules file error")) }
            }
        }
        let schedules = schedules ?? []
        guard schedules.count <= 50 else { throw RuleBackupError.invalid(String(localized: "The file has too many schedules.", comment: "Rules file error")) }
        for schedule in schedules {
            let stored = Self.storedID(schedule.profile)
            guard ids.contains(stored) || NetworkProfile.builtIn.contains(where: { $0.rawValue == stored }) else {
                throw RuleBackupError.invalid(String(localized: "A schedule names “\(schedule.profile)”, which isn’t in the file.", comment: "Rules file error"))
            }
            guard !schedule.days.isEmpty, schedule.days.allSatisfy({ Self.dayNames.contains($0.lowercased()) }) else { throw RuleBackupError.invalid(String(localized: "A schedule has days Kilobat can’t read.", comment: "Rules file error")) }
            guard let start = Self.minutes(schedule.start), let end = Self.minutes(schedule.end), start != end else {
                throw RuleBackupError.invalid(String(localized: "A schedule needs a start and an end time such as 09:00 and 18:00.", comment: "Rules file error"))
            }
        }
    }

    /// An app rule's key may also name a developer (`team:<Team ID>`).
    public static func validAppRule(_ id: String) -> Bool { validApp(id) || DeveloperRule.team(id) != nil }
    public static func validApp(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 300 && (id.contains(".") || id.hasPrefix("process:")) && !id.contains(where: { $0.isWhitespace || $0 == "|" })
    }
    /// A destination rule's host as it's stored: a lower-case domain, an IP address or a CIDR range.
    static func destinationHost(_ raw: String) -> String? {
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if host.contains("/") { return ConnectionRule.validDestination(host) }
        guard ExpertTools.validHost(host) else { return nil }
        if HostName.isAddress(host) { return host }
        return DomainPolicy.entry(host) == host ? host : nil
    }
    /// The file's protocol as a rule keeps it: nil for either.
    static func transport(_ raw: String?) -> String? {
        raw.flatMap { ["tcp", "udp"].contains($0.lowercased()) ? $0.lowercased() : nil }
    }
}

public enum RuleBackupError: Error, Equatable, LocalizedError {
    case tooLarge, notRules, unreadable, newerVersion, invalid(String)
    public var errorDescription: String? {
        switch self {
        case .tooLarge: String(localized: "This file is too large to be a Kilobat rules file.")
        case .notRules: String(localized: "This isn’t a Kilobat rules file.")
        case .unreadable: String(localized: "This rules file is damaged or incomplete.")
        case .newerVersion: String(localized: "This rules file comes from a newer Kilobat. Update Kilobat to import it.")
        case .invalid(let reason): String(localized: "Nothing was imported. \(reason)", comment: "Rules file error; the reason follows")
        }
    }
}

/// How an import treats rules that aren't in the file.
public enum RuleImportMode: String, CaseIterable, Sendable {
    /// Adds the file's rules and updates matching ones; everything else stays.
    case merge
    /// Makes the rules match the file: rules, sites, schedules and profiles of your own that aren't in it go.
    case replace
}

/// One line of an import's preview.
public struct RuleImportLine: Equatable, Identifiable, Sendable {
    public enum Kind: Sendable { case added, changed, removed }
    public let id: Int
    public let kind: Kind
    public let text: String
}

/// What an import would do, worked out before anything changes. `result` is the preferences after it.
public struct RuleImportPlan: Equatable {
    public let result: SavedPreferences
    public let lines: [RuleImportLine]
    /// Profiles of the file's that couldn't be added, past the limit.
    public let skipped: [String]
    /// The local profile each of the file's profiles became, by the file's stored id; a settings file's per-network
    /// profiles follow it.
    public let profileMap: [String: String]
    public var added: Int { lines.filter { $0.kind == .added }.count }
    public var changed: Int { lines.filter { $0.kind == .changed }.count }
    public var removed: Int { lines.filter { $0.kind == .removed }.count }
    public var isEmpty: Bool { lines.isEmpty }

    /// An app's name for the preview without looking it up: process:<name> as the name, a bundle ID as it is.
    public static func plainName(_ id: String) -> String { id.hasPrefix("process:") ? String(id.dropFirst(8)) : id }

    /// `appName` names apps in the preview lines; the app passes one that reads installed apps' names.
    public init(_ backup: RuleBackup, into preferences: SavedPreferences, mode: RuleImportMode, appName: (String) -> String = RuleImportPlan.plainName,
                newID: () -> String = { "Custom-" + String(UUID().uuidString.prefix(8)) }) {
        var next = preferences
        var lines: [RuleImportLine] = []
        var skipped: [String] = []
        func line(_ kind: RuleImportLine.Kind, _ text: String) { lines.append(RuleImportLine(id: lines.count, kind: kind, text: text)) }
        func verdict(_ allow: Bool) -> String { allow ? String(localized: "Allow", comment: "Rule verdict") : String(localized: "Block", comment: "Rule verdict") }

        // Profiles: the file's own ids map to local ones by id, then by name; new ones are added.
        var map: [String: String] = [:]
        var definitions = next.profileDefinitions ?? []
        for profile in backup.profiles {
            let stored = RuleBackup.storedID(profile.id)
            if NetworkProfile.builtIn.contains(where: { $0.rawValue == stored }) {
                map[stored] = stored
                let current = definitions.first { $0.id == stored }
                let wanted = profile.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                if wanted != current?.name || profile.symbol != current?.symbol, wanted != nil || profile.symbol != nil || mode == .replace {
                    let old = next.title(of: stored)
                    definitions.removeAll { $0.id == stored }
                    if wanted != nil || profile.symbol != nil { definitions.append(ProfileDefinition(id: stored, name: wanted, symbol: profile.symbol)) }
                    next.profileDefinitions = definitions.isEmpty ? nil : definitions
                    let new = next.title(of: stored)
                    if new != old { line(.changed, String(localized: "Rename \(old) to \(new)", comment: "Rules import preview")) }
                    else { line(.changed, String(localized: "New icon for \(new)", comment: "Rules import preview")) }
                }
                continue
            }
            let name = profile.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? stored
            if let local = definitions.first(where: { $0.custom && ($0.id == stored || $0.name.map(NetworkProfile.slug) == NetworkProfile.slug(name)) }) {
                map[stored] = local.id
                if local.name != name || (profile.symbol != nil && profile.symbol != local.symbol), let at = definitions.firstIndex(where: { $0.id == local.id }) {
                    let old = local.name ?? local.id
                    definitions[at].name = name; definitions[at].symbol = profile.symbol ?? local.symbol
                    if old != name { line(.changed, String(localized: "Rename \(old) to \(name)", comment: "Rules import preview")) }
                }
            } else if definitions.filter(\.custom).count < ProfileEditing.maxCustom,
                      (try? ProfileEditing.validName(name, for: nil, in: definitions)) != nil {
                let id = definitions.contains(where: { $0.id == stored }) || stored.count > 40 ? newID() : stored
                definitions.append(ProfileDefinition(id: id, name: name, symbol: profile.symbol))
                map[stored] = id
                line(.added, String(localized: "New profile: \(name)", comment: "Rules import preview"))
            } else {
                skipped.append(name)
            }
            next.profileDefinitions = definitions.isEmpty ? nil : definitions
        }
        let fileProfiles = Set(map.values)
        if mode == .replace {
            for definition in definitions where definition.custom && !fileProfiles.contains(definition.id) {
                line(.removed, String(localized: "Remove profile: \(definition.name ?? definition.id)", comment: "Rules import preview"))
                try? next.removeProfile(NetworkProfile(stored: definition.id))
            }
            definitions = next.profileDefinitions ?? []
        }

        // App rules.
        for profile in backup.profiles {
            guard let id = map[RuleBackup.storedID(profile.id)] else { continue }
            let title = next.title(of: id)
            var rules = next.rules[id] ?? [:]
            let wanted = Dictionary((profile.apps ?? []).map { ($0.app, $0.allow) }, uniquingKeysWith: { _, last in last })
            for (app, allow) in wanted.sorted(by: { $0.key < $1.key }) {
                if let old = rules[app] {
                    if old != allow { line(.changed, String(localized: "\(verdict(allow)) \(appName(app)) in \(title), was \(verdict(old))", comment: "Rules import preview: verdict, app, profile, old verdict")) }
                } else { line(.added, String(localized: "\(verdict(allow)) \(appName(app)) in \(title)", comment: "Rules import preview: verdict, app, profile")) }
                rules[app] = allow
            }
            if mode == .replace {
                for (app, old) in rules.sorted(by: { $0.key < $1.key }) where wanted[app] == nil {
                    line(.removed, String(localized: "\(verdict(old)) \(appName(app)) in \(title)", comment: "Rules import preview: verdict, app, profile"))
                    rules[app] = nil
                }
            }
            next.rules[id] = rules.isEmpty ? nil : rules
        }
        if mode == .replace {
            for (id, rules) in next.rules.sorted(by: { $0.key < $1.key }) where !fileProfiles.contains(id) {
                for (app, old) in rules.sorted(by: { $0.key < $1.key }) { line(.removed, String(localized: "\(verdict(old)) \(appName(app)) in \(next.title(of: id))", comment: "Rules import preview: verdict, app, profile")) }
                next.rules[id] = nil
            }
        }

        // Destination rules, matched by profile, app, host, port and direction. Timed ones on this Mac are left alone.
        var connections = next.connectionRules ?? []
        func same(_ rule: ConnectionRule, _ profile: String, _ wanted: RuleBackup.DestinationRule, host: String) -> Bool {
            rule.expires == nil && rule.profile == profile && rule.app == wanted.app && rule.host == host && rule.port == (wanted.port ?? "") && rule.direction == (wanted.direction ?? "any")
                && rule.transport == RuleBackup.transport(wanted.networkProtocol) && (rule.exact == true) == (wanted.exact == true && !HostName.isAddress(host) && !host.contains("/"))
        }
        var keptIDs = Set<UUID>()
        for profile in backup.profiles {
            guard let id = map[RuleBackup.storedID(profile.id)] else { continue }
            let title = next.title(of: id)
            for wanted in profile.destinations ?? [] {
                guard let host = RuleBackup.destinationHost(wanted.host) else { continue }
                let target = host + (wanted.port.map { ":" + $0 } ?? "")
                if let at = connections.firstIndex(where: { same($0, id, wanted, host: host) }) {
                    if connections[at].allowed != wanted.allow {
                        line(.changed, String(localized: "\(verdict(wanted.allow)) \(target) for \(appName(wanted.app)) in \(title), was \(verdict(connections[at].allowed))", comment: "Rules import preview: verdict, destination, app, profile, old verdict"))
                        connections[at].allowed = wanted.allow
                    }
                    keptIDs.insert(connections[at].id)
                } else {
                    let rule = ConnectionRule(app: wanted.app, host: host, port: wanted.port ?? "", direction: wanted.direction ?? "any", allowed: wanted.allow, profile: id,
                                              transport: RuleBackup.transport(wanted.networkProtocol), exact: wanted.exact)
                    connections.append(rule); keptIDs.insert(rule.id)
                    line(.added, String(localized: "\(verdict(wanted.allow)) \(target) for \(appName(wanted.app)) in \(title)", comment: "Rules import preview: verdict, destination, app, profile"))
                }
            }
        }
        if mode == .replace {
            for rule in connections where rule.expires == nil && !keptIDs.contains(rule.id) {
                line(.removed, String(localized: "\(verdict(rule.allowed)) \(rule.host + (rule.port.isEmpty ? "" : ":" + rule.port)) for \(appName(rule.app)) in \(next.title(of: rule.profile))", comment: "Rules import preview: verdict, destination, app, profile"))
            }
            connections.removeAll { $0.expires == nil && !keptIDs.contains($0.id) }
        }
        next.connectionRules = connections.isEmpty ? nil : connections

        // Sites for every app.
        func sites(_ local: [String]?, _ file: [String]?, normalize: (String) -> String?, added: (String) -> String, removed: (String) -> String) -> [String]? {
            var set = local ?? []
            let wanted = (file ?? []).compactMap(normalize)
            for host in wanted where !set.contains(host) { set.append(host); line(.added, added(host)) }
            if mode == .replace { for host in set where !wanted.contains(host) { line(.removed, removed(host)) }; set.removeAll { !wanted.contains($0) } }
            return set.isEmpty ? nil : set.sorted()
        }
        next.blockedHosts = sites(next.blockedHosts, backup.everyApp?.blocked, normalize: DomainPolicy.entry,
                                  added: { String(localized: "Block \($0) for every app", comment: "Rules import preview") },
                                  removed: { String(localized: "Block \($0) for every app", comment: "Rules import preview") })
        next.allowedSites = sites(next.allowedSites, backup.everyApp?.allowedSites, normalize: { HostName.normalize($0) },
                                  added: { String(localized: "Allow \($0) past Protection", comment: "Rules import preview") },
                                  removed: { String(localized: "Allow \($0) past Protection", comment: "Rules import preview") })
        var exceptions = next.domainExceptions ?? [:]
        var wantedExceptions = Set<String>()
        for exception in backup.everyApp?.exceptions ?? [] {
            for domain in exception.domains.compactMap(DomainPolicy.entry) {
                wantedExceptions.insert(exception.app + "|" + domain)
                if exceptions[exception.app]?.contains(domain) != true {
                    exceptions[exception.app, default: []].append(domain)
                    line(.added, String(localized: "Let \(appName(exception.app)) reach \(domain) despite the blocklist", comment: "Rules import preview"))
                }
            }
        }
        if mode == .replace {
            for (app, domains) in exceptions.sorted(by: { $0.key < $1.key }) {
                for domain in domains where !wantedExceptions.contains(app + "|" + domain) {
                    line(.removed, String(localized: "Let \(appName(app)) reach \(domain) despite the blocklist", comment: "Rules import preview"))
                }
                exceptions[app] = domains.filter { wantedExceptions.contains(app + "|" + $0) }
            }
        }
        exceptions = exceptions.filter { !$0.value.isEmpty }.mapValues { $0.sorted() }
        next.domainExceptions = exceptions.isEmpty ? nil : exceptions

        // Schedules, matched by profile, days and times.
        var schedules = next.profileSchedules ?? []
        var keptSchedules = Set<UUID>()
        for schedule in backup.schedules ?? [] {
            guard let id = map[RuleBackup.storedID(schedule.profile)], let start = RuleBackup.minutes(schedule.start), let end = RuleBackup.minutes(schedule.end) else { continue }
            let days = Set(schedule.days.compactMap { RuleBackup.dayNames.firstIndex(of: $0.lowercased()).map { $0 + 1 } }).sorted()
            let on = schedule.on ?? true
            let wanted = ProfileSchedule(profile: id, days: days, start: start, end: end, enabled: on)
            let text = String(localized: "\(next.title(of: id)): \(wanted.summary())", comment: "Rules import preview: a profile and its schedule")
            if let at = schedules.firstIndex(where: { $0.profile == id && $0.days.sorted() == days && $0.start == start && $0.end == end }) {
                if schedules[at].enabled != on {
                    schedules[at].enabled = on
                    line(.changed, on ? String(localized: "Turn on \(text)", comment: "Rules import preview: a schedule") : String(localized: "Turn off \(text)", comment: "Rules import preview: a schedule"))
                }
                keptSchedules.insert(schedules[at].id)
            } else {
                schedules.append(wanted); keptSchedules.insert(wanted.id)
                line(.added, String(localized: "Schedule \(text)", comment: "Rules import preview: a schedule"))
            }
        }
        if mode == .replace {
            for schedule in schedules where !keptSchedules.contains(schedule.id) {
                line(.removed, String(localized: "Schedule \(next.title(of: schedule.profile)): \(schedule.summary())", comment: "Rules import preview: a schedule"))
            }
            schedules.removeAll { !keptSchedules.contains($0.id) }
        }
        next.profileSchedules = schedules.isEmpty ? nil : schedules

        // How new apps are treated.
        if let raw = backup.newApps, let newApps = NewAppPolicy.Mode(rawValue: raw == "allow" && backup.alertNewApps == true ? "alert" : raw) {
            if newApps != NewAppPolicy.mode(next) {
                newApps.apply(to: &next)
                line(.changed, newApps.title)
            }
        }
        if let wanted = backup.askDestinations {
            var apps = Set(next.askDestinations ?? [])
            for app in wanted.sorted() where !apps.contains(app) { apps.insert(app); line(.added, String(localized: "Ask before \(appName(app)) reaches a new destination", comment: "Rules import preview")) }
            if mode == .replace { for app in apps.sorted() where !wanted.contains(app) { apps.remove(app); line(.removed, String(localized: "Ask before \(appName(app)) reaches a new destination", comment: "Rules import preview")) } }
            next.askDestinations = apps.isEmpty ? nil : apps.sorted()
        } else if mode == .replace, let apps = next.askDestinations, !apps.isEmpty {
            for app in apps.sorted() { line(.removed, String(localized: "Ask before \(appName(app)) reaches a new destination", comment: "Rules import preview")) }
            next.askDestinations = nil
        }
        if let apple = backup.allowApple, apple != (next.allowApple == true) {
            next.allowApple = apple ? true : nil
            line(.changed, apple ? String(localized: "Allow Apple software", comment: "Rules import preview") : String(localized: "Stop allowing Apple software without a rule", comment: "Rules import preview"))
        }
        next.settleProfiles()
        result = next
        self.lines = lines
        self.skipped = skipped
        profileMap = map
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
