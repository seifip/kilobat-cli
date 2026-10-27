import Foundation
import Security

/// Metadata only: no packet payloads, URLs, or DNS query contents.
public struct FilterEvent: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let app: String
    public let endpoint: String
    public let direction: String
    public let reason: String
    public init(id: UUID = UUID(), date: Date = Date(), app: String, endpoint: String, direction: String, reason: String) {
        self.id = id; self.date = date; self.app = app; self.endpoint = endpoint; self.direction = direction; self.reason = reason
    }
}

@objc public protocol FilterEventService {
    func recentEvents(reply: @escaping (Data) -> Void)
}

public enum FilterSigning {
    public static func team() -> String? {
        var code: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
        return team
    }
    public static func requirement(team: String, bundle: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(bundle)\""
    }
}
