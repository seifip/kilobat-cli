import Foundation

/// A change to what the network filter enforces, as the app's controls make them.
public enum LooseningChange: Equatable, Sendable {
    /// How apps without a rule are treated, from strictest to loosest.
    public enum NewApps: Int, Comparable, Sendable {
        case block, ask, allow
        public static func < (a: NewApps, b: NewApps) -> Bool { a.rawValue < b.rawValue }
    }
    case profile(to: NetworkProfile)
    /// A saved or timed rule for one app, set to allow or block.
    case appRule(allowed: Bool)
    /// Taking a rule away; `allowed` is what the rule said.
    case removeRule(allowed: Bool)
    case newApps(from: NewApps, to: NewApps)
    case allowApple(Bool)
    case filter(on: Bool)
    /// An app asking before it reaches a new destination: turning it on holds connections, turning it off lets them go.
    case askDestinations(on: Bool)
}

/// Pro gates tightening only. Whatever Kilobat still enforces after a trial or license ends, the person can relax.
public enum RuleLoosening {
    /// Whether the change can only let more through.
    public static func loosens(_ change: LooseningChange) -> Bool {
        switch change {
        case .profile(let to): to == .unrestricted
        case .appRule(let allowed): allowed
        case .removeRule(let allowed): !allowed
        case .newApps(let from, let to): to > from
        case .allowApple(let on): on
        case .filter(let on): !on
        case .askDestinations(let on): !on
        }
    }
    public static func permitted(_ change: LooseningChange, hasPro: Bool) -> Bool { hasPro || loosens(change) }

    /// Without Pro, whether saved rules are being enforced right now: the filter is on and the profile filters.
    public static func enforcedWithoutPro(_ preferences: SavedPreferences, filterActive: Bool, hasPro: Bool) -> Bool {
        !hasPro && filterActive && preferences.profile != .unrestricted
    }
}
