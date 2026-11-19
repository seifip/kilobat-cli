import Foundation
import os

/// A profile: one of the three built in (Essentials, stored as "Travel"; Work; Unrestricted) or one the person added.
/// Rules, timed rules and destination rules are kept per profile under `rawValue`, and the filter is sent only the
/// current profile's, so a profile the person added needs nothing new from the filter. Unrestricted alone has no rules.
public struct NetworkProfile: RawRepresentable, Codable, Hashable, Identifiable, Sendable, CaseIterable {
    public let rawValue: String

    /// A built-in profile, or one the catalog lists; nil for anything else, such as a profile since removed.
    public init?(rawValue: String) {
        guard Self.builtIn.contains(where: { $0.rawValue == rawValue }) || ProfileCatalog.definition(rawValue)?.custom == true else { return nil }
        self.rawValue = rawValue
    }
    /// Without checking the catalog, for code that has checked the preferences' own definitions.
    init(stored: String) { rawValue = stored }

    /// Read as stored, without the catalog: preferences are decoded before the catalog they carry is known.
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }

    public static let travel = NetworkProfile(stored: "Travel")
    public static let work = NetworkProfile(stored: "Work")
    public static let unrestricted = NetworkProfile(stored: "Unrestricted")
    public static let builtIn: [NetworkProfile] = [.travel, .work, .unrestricted]
    /// The built-in three, then the person's own in the order they were added.
    public static var allCases: [NetworkProfile] { builtIn + ProfileCatalog.custom.map { NetworkProfile(stored: $0.id) } }
    /// Every profile that keeps rules: all but Unrestricted.
    public static var withRules: [NetworkProfile] { allCases.filter(\.keepsRules) }

    public var id: String { rawValue }
    public var isBuiltIn: Bool { Self.builtIn.contains(self) }
    public var keepsRules: Bool { self != .unrestricted }

    /// The CLI's and agents' name: Travel is shown as Essentials, and both names select it. A profile the person added
    /// goes by its name in lower case, with dashes for spaces.
    public var cliName: String {
        if self == .travel { return "essentials" }
        if isBuiltIn { return rawValue.lowercased() }
        return Self.slug(title)
    }
    /// A profile by the name people type: essentials, travel (its stored name), work or unrestricted, or a profile's
    /// own name, as shown or as `cliName` gives it.
    public static func named(_ name: String) -> NetworkProfile? {
        let name = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return nil }
        if name == "essentials" { return .travel }
        if let builtIn = builtIn.first(where: { $0.rawValue.lowercased() == name }) { return builtIn }
        return allCases.first { $0.cliName == name || $0.title.lowercased() == name || slug($0.title) == slug(name) }
    }
    static func slug(_ name: String) -> String {
        name.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: "-")
    }

    /// The name as shown: the person's own, or the built-in one. `rawValue` is what rules and preferences store, so it stays "Travel".
    public var title: String {
        if let name = ProfileCatalog.definition(rawValue)?.name, !name.isEmpty { return name }
        return defaultTitle ?? rawValue
    }
    /// The built-in name, nil for a profile the person added.
    public var defaultTitle: String? {
        switch rawValue {
        case Self.travel.rawValue: String(localized: "Essentials", comment: "Profile name")
        case Self.work.rawValue: String(localized: "Work", comment: "Profile name")
        case Self.unrestricted.rawValue: String(localized: "Unrestricted", comment: "Profile name")
        default: nil
        }
    }
    public var symbol: String {
        if let symbol = ProfileCatalog.definition(rawValue)?.symbol, ProfileSymbols.choices.contains(symbol) { return symbol }
        return defaultSymbol
    }
    public var defaultSymbol: String {
        switch rawValue {
        case Self.travel.rawValue: "checklist"
        case Self.work.rawValue: "laptopcomputer"
        case Self.unrestricted.rawValue: "globe"
        default: "house"
        }
    }
    public var subtitle: String {
        switch rawValue {
        case Self.travel.rawValue: String(localized: "Only the apps you allow can connect.")
        case Self.work.rawValue: String(localized: "Keep your work flowing. Pause distractions.")
        case Self.unrestricted.rawValue: String(localized: "No rules. Every app connects freely.")
        default: String(localized: "Your own rules.", comment: "Subtitle of a profile the person added")
        }
    }
}

/// The person's own name and icon for a built-in profile, or a profile they added (`custom`).
public struct ProfileDefinition: Codable, Equatable, Identifiable, Sendable {
    /// The profile's `rawValue`: "Travel", "Work" or "Unrestricted" for an edit, "Custom-…" for one the person added.
    public var id: String
    /// Nil keeps a built-in profile's own name.
    public var name: String?
    /// One of `ProfileSymbols.choices`; nil keeps the built-in icon.
    public var symbol: String?
    public var custom: Bool { !NetworkProfile.builtIn.contains { $0.rawValue == id } }
    public init(id: String, name: String? = nil, symbol: String? = nil) { self.id = id; self.name = name; self.symbol = symbol }
}

/// The icons a profile can have; every one is already in the app's symbol set.
public enum ProfileSymbols {
    public static let choices = ["checklist", "laptopcomputer", "globe", "house", "building.2", "moon", "gamecontroller", "cup.and.saucer",
                                 "airplane", "headphones", "lightbulb", "star", "shield", "flame"]
}

/// The profiles the current preferences define, for `NetworkProfile`'s names and the list of profiles. Every store that
/// loads preferences (the app's and the CLI's) keeps it current.
public enum ProfileCatalog {
    private static let definitions = OSAllocatedUnfairLock<[ProfileDefinition]>(initialState: [])
    public static func update(_ list: [ProfileDefinition]?) {
        let list = list ?? []
        definitions.withLock { if $0 != list { $0 = list } }
    }
    public static func definition(_ id: String) -> ProfileDefinition? { definitions.withLock { $0.first { $0.id == id } } }
    static var custom: [ProfileDefinition] { definitions.withLock { $0.filter(\.custom) } }
}

/// Why a profile couldn't be added, renamed or removed.
public enum ProfileEditError: Error, Equatable, LocalizedError {
    case emptyName, nameTooLong, nameTaken(String), tooMany, notCustom, unknown
    public var errorDescription: String? {
        switch self {
        case .emptyName: String(localized: "Give the profile a name.")
        case .nameTooLong: String(localized: "Use a name of \(ProfileEditing.maxName) characters or fewer.")
        case .nameTaken(let name): String(localized: "There’s already a profile called \(name).")
        case .tooMany: String(localized: "You can add up to \(ProfileEditing.maxCustom) profiles of your own.")
        case .notCustom: String(localized: "The built-in profiles can be renamed but not removed.")
        case .unknown: String(localized: "That profile no longer exists.")
        }
    }
}

public enum ProfileEditing {
    public static let maxCustom = 8
    public static let maxName = 30

    /// The trimmed name, if it's free: no other profile has it, as shown or by its built-in or command-line name.
    static func validName(_ raw: String, for id: String?, in definitions: [ProfileDefinition]) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProfileEditError.emptyName }
        guard name.count <= maxName else { throw ProfileEditError.nameTooLong }
        let wanted = NetworkProfile.slug(name)
        // Built-in names stay reserved, so `kilobat profile work` always means Work.
        let reserved = ["essentials", "travel", "work", "unrestricted"].filter { builtIn in NetworkProfile.builtIn.first { $0.cliName == builtIn || $0.rawValue.lowercased() == builtIn }?.rawValue != id }
        if reserved.contains(wanted) { throw ProfileEditError.nameTaken(name) }
        for profile in NetworkProfile.builtIn where profile.rawValue != id {
            let shown = definitions.first { $0.id == profile.rawValue }?.name ?? profile.defaultTitle ?? profile.rawValue
            if NetworkProfile.slug(shown) == wanted { throw ProfileEditError.nameTaken(shown) }
        }
        for definition in definitions where definition.custom && definition.id != id {
            if let other = definition.name, NetworkProfile.slug(other) == wanted { throw ProfileEditError.nameTaken(other) }
        }
        return name
    }
}

extension SavedPreferences {
    /// Adds a profile of the person's own, starting with a copy of `copying`'s saved app and destination rules.
    @discardableResult public mutating func addProfile(named raw: String, symbol: String? = nil, copying source: NetworkProfile? = nil,
                                                       id: String = "Custom-" + String(UUID().uuidString.prefix(8))) throws -> NetworkProfile {
        var definitions = profileDefinitions ?? []
        guard definitions.filter(\.custom).count < ProfileEditing.maxCustom else { throw ProfileEditError.tooMany }
        let name = try ProfileEditing.validName(raw, for: nil, in: definitions)
        definitions.append(ProfileDefinition(id: id, name: name, symbol: symbol.flatMap { ProfileSymbols.choices.contains($0) ? $0 : nil }))
        profileDefinitions = definitions
        if let source, source.keepsRules {
            if let saved = rules[source.rawValue], !saved.isEmpty { rules[id] = saved }
            let copies = (connectionRules ?? []).filter { $0.profile == source.rawValue && $0.expires == nil }.map {
                $0.copy(profile: id)
            }
            if !copies.isEmpty { connectionRules = (connectionRules ?? []) + copies }
        }
        return NetworkProfile(stored: id)
    }

    /// A new name or icon. For a built-in profile, an empty name (or its own) and its own icon go back to the original.
    public mutating func editProfile(_ profile: NetworkProfile, name raw: String, symbol: String?) throws {
        var definitions = profileDefinitions ?? []
        guard profile.isBuiltIn || definitions.contains(where: { $0.id == profile.rawValue }) else { throw ProfileEditError.unknown }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var name: String?
        if profile.isBuiltIn && (trimmed.isEmpty || trimmed == profile.defaultTitle) { name = nil }
        else { name = try ProfileEditing.validName(trimmed, for: profile.rawValue, in: definitions) }
        let icon = symbol.flatMap { ProfileSymbols.choices.contains($0) && !(profile.isBuiltIn && $0 == profile.defaultSymbol) ? $0 : nil }
        let keep = !profile.isBuiltIn || name != nil || icon != nil
        let entry = ProfileDefinition(id: profile.rawValue, name: name, symbol: icon)
        if let at = definitions.firstIndex(where: { $0.id == profile.rawValue }) {
            if keep { definitions[at] = entry } else { definitions.remove(at: at) }
        } else if keep { definitions.append(entry) }
        profileDefinitions = definitions.isEmpty ? nil : definitions
    }

    /// Removes a profile the person added, with its rules, schedules and network choices. If it was in use, Work takes over.
    public mutating func removeProfile(_ profile: NetworkProfile) throws {
        guard !profile.isBuiltIn else { throw ProfileEditError.notCustom }
        guard profileDefinitions?.contains(where: { $0.id == profile.rawValue }) == true else { throw ProfileEditError.unknown }
        let id = profile.rawValue
        profileDefinitions?.removeAll { $0.id == id }
        if profileDefinitions?.isEmpty == true { profileDefinitions = nil }
        rules[id] = nil
        connectionRules?.removeAll { $0.profile == id }
        for key in (temporaryRules ?? [:]).keys where key.hasPrefix(id + "|") { temporaryRules?[key] = nil }
        networkProfiles = networkProfiles?.filter { $0.value != id }
        profileSchedules?.removeAll { $0.profile == id }
        if profileSchedules?.isEmpty == true { profileSchedules = nil }
        if profileScheduleState?.previous == id { profileScheduleState?.previous = nil }
        if autoProfileFrom == id { autoProfileFrom = NetworkProfile.work.rawValue }
        if self.profile == profile { self.profile = .work }
    }

    /// As written to preferences.json: a profile of the person's own is kept in `customProfile`, with Work in `profile`
    /// for earlier versions, which know only the built-in three. `settleProfiles()` reads it back.
    public var forDisk: SavedPreferences {
        var stored = self
        stored.schema = Self.currentSchema
        if profile.isBuiltIn { stored.customProfile = nil } else { stored.customProfile = profile.rawValue; stored.profile = .work }
        return stored
    }

    /// The JSON keys this version writes: each stored property's name (the Codable conformance is synthesised).
    static let knownKeys: Set<String> = Set(Mirror(reflecting: SavedPreferences()).children.compactMap(\.label))

    /// The bytes to write. Top-level keys of `existing` (the file being replaced) that this version doesn't know are
    /// carried over untouched: a newer Kilobat put them there, and this copy must not drop them by saving.
    func dataForDisk(over existing: Data?) throws -> Data {
        let own = try JSONEncoder().encode(forDisk)
        guard let existing, let old = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else { return own }
        let foreign = old.filter { !Self.knownKeys.contains($0.key) }
        guard !foreign.isEmpty, var merged = try JSONSerialization.jsonObject(with: own) as? [String: Any] else { return own }
        merged.merge(foreign) { mine, _ in mine }
        return try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
    }

    /// The profile stored as `raw`, if these preferences define it; unlike `NetworkProfile(rawValue:)`, it doesn't
    /// depend on which preferences were loaded last.
    public func knownProfile(_ raw: String) -> NetworkProfile? {
        if let builtIn = NetworkProfile.builtIn.first(where: { $0.rawValue == raw }) { return builtIn }
        return (profileDefinitions ?? []).contains { $0.custom && $0.id == raw } ? NetworkProfile(stored: raw) : nil
    }
    /// Every profile these preferences define: the built-in three, then the person's own.
    public var definedProfiles: [NetworkProfile] {
        NetworkProfile.builtIn + (profileDefinitions ?? []).filter(\.custom).map { NetworkProfile(stored: $0.id) }
    }
    /// A profile's name as these preferences give it.
    public func title(of raw: String) -> String {
        if let name = profileDefinitions?.first(where: { $0.id == raw })?.name, !name.isEmpty { return name }
        return NetworkProfile.builtIn.first { $0.rawValue == raw }?.defaultTitle ?? raw
    }

    /// After preferences load or change: a current profile, remembered previous one or network choice that names a
    /// profile no longer defined falls back to Work, so nothing points at rules that are gone.
    public mutating func settleProfiles() {
        schema = nil
        let known = Set(NetworkProfile.builtIn.map(\.rawValue) + (profileDefinitions ?? []).filter(\.custom).map(\.id))
        if let custom = customProfile {
            if known.contains(custom), profile == .work { profile = NetworkProfile(stored: custom) }
            customProfile = nil
        }
        if !known.contains(profile.rawValue) { profile = .work }
        if let from = autoProfileFrom, !known.contains(from) { autoProfileFrom = NetworkProfile.work.rawValue }
        if let networks = networkProfiles, networks.values.contains(where: { !known.contains($0) }) { networkProfiles = networks.filter { known.contains($0.value) } }
    }
}
