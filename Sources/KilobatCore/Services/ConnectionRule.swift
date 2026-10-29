import Foundation

public struct ConnectionRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var app: String
    public var host: String
    public var port: String
    public var direction: String
    public var allowed: Bool
    public var profile: String
    public var expires: Date?
    public init(app: String, host: String, port: String = "", direction: String = "any", allowed: Bool, profile: String, expires: Date? = nil) {
        self.id = UUID(); self.app = app; self.host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")); self.port = port; self.direction = direction; self.allowed = allowed; self.profile = profile; self.expires = expires
    }
    public func matches(app: String, process: String, host: String?, address: String?, port: String?, direction: String, now: Date = Date()) -> Bool {
        guard self.app == app || ProcessRuleKey.keys("process:" + process).contains(self.app),
              expires == nil || expires! > now,
              self.port.isEmpty || self.port == port,
              self.direction == "any" || self.direction == direction else { return false }
        if address?.lowercased() == self.host { return true }
        guard let host = host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) else { return false }
        return host == self.host || host.hasSuffix("." + self.host)
    }
}

public enum ProcessRuleKey {
    /// Rule keys for an app ID, newest first. Rules saved before full executable names were
    /// resolved use nettop's 15-character truncation.
    public static func keys(_ id: String) -> [String] {
        guard id.hasPrefix("process:"), id.count > 23 else { return [id] }
        return [id, String(id.prefix(23))]
    }
}

/// An app rule that lapses back to the profile default.
public struct TemporaryRule: Codable, Equatable, Sendable {
    public let allowed: Bool
    public let expires: Date
    public init(allowed: Bool, expires: Date) { self.allowed = allowed; self.expires = expires }
}
