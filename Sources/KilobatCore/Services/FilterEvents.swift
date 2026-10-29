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
    /// The system service that made the connection for `app`, such as com.apple.nsurlsessiond. Nil when the app made it.
    public let via: String?
    public init(id: UUID = UUID(), date: Date = Date(), app: String, endpoint: String, direction: String, reason: String, via: String? = nil) {
        self.id = id; self.date = date; self.app = app; self.endpoint = endpoint; self.direction = direction; self.reason = reason; self.via = via
    }
}

/// Connections one process made for another app, as the filter saw them: com.apple.nsurlsessiond for com.apple.Music.
/// The filter sees a connection when it opens, not the bytes after it, so these are counts.
public struct DelegatedFlows: Codable, Sendable, Equatable, Identifiable {
    /// Signing identifiers of the process that connected and the app it connected for.
    public let process: String
    public let app: String
    public var allowed: Int
    public var blocked: Int
    public var last: Date
    public var id: String { process + "|" + app }
    public init(process: String, app: String, allowed: Int = 0, blocked: Int = 0, last: Date = Date()) {
        self.process = process; self.app = app; self.allowed = allowed; self.blocked = blocked; self.last = last
    }
}

/// An app with no rule whose connections the filter is holding until the user allows or blocks it.
public struct PendingApproval: Codable, Identifiable, Sendable, Equatable {
    public struct Destination: Codable, Sendable, Equatable, Hashable {
        public let host: String?
        public let address: String?
        public let port: String?
        public init(host: String?, address: String?, port: String?) { self.host = host; self.address = address; self.port = port }
        public var label: String { (host ?? address ?? "Unknown") + (port.map { ":" + $0 } ?? "") }
    }
    /// The rule key: a bundle or signing identifier.
    public let app: String
    public let process: String
    public let path: String?
    public let signer: String?
    public let signatureValid: Bool
    public let pid: Int32
    public let uid: UInt32
    public var requests: Int
    public var waiting: Int
    public var destinations: [Destination]
    public let first: Date
    public var last: Date
    public var id: String { app }
    public init(app: String, process: String, path: String?, signer: String?, signatureValid: Bool, pid: Int32, uid: UInt32,
                requests: Int = 1, waiting: Int = 1, destinations: [Destination], first: Date = Date(), last: Date = Date()) {
        self.app = app; self.process = process; self.path = path; self.signer = signer; self.signatureValid = signatureValid
        self.pid = pid; self.uid = uid; self.requests = requests; self.waiting = waiting; self.destinations = destinations; self.first = first; self.last = last
    }
}

@objc public protocol FilterEventService {
    func recentEvents(reply: @escaping (Data) -> Void)
    /// Apps waiting for a decision. Asking also tells the filter someone is there to answer.
    func pendingApprovals(reply: @escaping (Data) -> Void)
    /// Releases an app's held connections, letting them through or dropping them.
    func decide(_ app: String, allowed: Bool, reply: @escaping (Bool) -> Void)
    /// Recently seen hostnames by remote address, so open connections can be named.
    func hostnames(reply: @escaping (Data) -> Void)
    /// Connections system services made for other apps, as encoded `[DelegatedFlows]`.
    func delegatedFlows(reply: @escaping (Data) -> Void)
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
