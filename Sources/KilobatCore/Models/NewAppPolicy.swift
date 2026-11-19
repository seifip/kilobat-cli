import Foundation

/// What a profile does with apps that have no rule: allow, alert (allow, and list them quietly for review), ask, or
/// block. Stored as `askNewApps`, `defaultAllow` and `alertNewApps`, so a Kilobat that predates alert mode reads an
/// alert profile as allow.
public enum NewAppPolicy {
    public enum Mode: String, CaseIterable, Sendable {
        case allow, alert, ask, block

        public var title: String {
            switch self {
            case .allow: String(localized: "Allow new apps")
            case .alert: String(localized: "Allow and list new apps", comment: "New-app mode: let them connect and list them for review")
            case .ask: String(localized: "Ask about new apps")
            case .block: String(localized: "Block new apps")
            }
        }
        public func apply(to preferences: inout SavedPreferences) {
            preferences.askNewApps = self == .ask ? true : nil
            preferences.alertNewApps = self == .alert ? true : nil
            if self != .ask { preferences.defaultAllow = self == .allow || self == .alert }
        }
    }

    /// Whether the filter needs someone polling for prompts: new apps are asked about, or an app asks about destinations.
    public static func asks(_ preferences: SavedPreferences) -> Bool {
        preferences.profile != .unrestricted && (preferences.askNewApps == true || !(preferences.askDestinations ?? []).isEmpty)
    }

    public static func mode(_ preferences: SavedPreferences) -> Mode {
        if preferences.askNewApps == true { return .ask }
        guard preferences.defaultAllow else { return .block }
        return preferences.alertNewApps == true ? .alert : .allow
    }
}

/// Apps marked "Ask for new destinations" (Pro to turn on; turning off is always free). Off for every app by default.
public enum AskDestinations {
    public static func on(_ app: String, in preferences: SavedPreferences) -> Bool { (preferences.askDestinations ?? []).contains(app) }
    public static func set(_ app: String, on: Bool, in preferences: inout SavedPreferences) {
        var apps = Set(preferences.askDestinations ?? [])
        if on { apps.insert(app) } else { apps.remove(app) }
        preferences.askDestinations = apps.isEmpty ? nil : apps.sorted()
    }
}
