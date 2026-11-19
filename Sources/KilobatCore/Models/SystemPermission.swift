import UserNotifications

/// What macOS says about one permission, reduced to what the interface needs.
public enum SystemPermission: Equatable, Sendable {
    case notAsked, allowed, denied

    /// Provisional and ephemeral grants deliver notifications, so they count as allowed.
    public init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notAsked
        case .denied: self = .denied
        default: self = .allowed
        }
    }

    /// A feature the person switched on only counts as set up once macOS allows what it needs.
    public func confirms(enabled: Bool) -> Bool { enabled && self == .allowed }
    /// Only an explicit refusal is worth a warning; "not asked yet" is answered by the first prompt.
    public var needsSettings: Bool { self == .denied }
}
