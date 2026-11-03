import Foundation
import Darwin

// Compiled into Kilobat's helper too (KilobatPowerHelper, which runs as root), so Foundation and Darwin only.

/// IP address literals: the only thing Kilobat ever hands networksetup as a DNS server.
public enum DNSAddress {
    public static func valid(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 45, !text.hasPrefix("-") else { return false }
        var v4 = in_addr(), v6 = in6_addr()
        return text.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
}

/// What the app asks Kilobat's helper (root) to do: one network service's DNS, set to a few IP addresses or back to
/// automatic. The helper checks it again, so a request can never become anything else.
public struct DNSHelperRequest: Codable, Equatable, Sendable {
    public var service: String
    /// Empty puts automatic DNS back.
    public var servers: [String]
    public var expectedServers: [String]?
    public init(service: String, servers: [String], expectedServers: [String]? = nil) {
        self.service = service; self.servers = servers; self.expectedServers = expectedServers
    }

    /// networksetup's arguments, or nil unless the service exists and every server is an IP address (at most four).
    public func arguments(services: [String]) -> [String]? {
        guard !service.isEmpty, service.count <= 128, !service.hasPrefix("-"), services.contains(service),
              !service.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              servers.count <= 4, servers.allSatisfy(DNSAddress.valid) else { return nil }
        return ["-setdnsservers", service] + (servers.isEmpty ? ["Empty"] : servers)
    }

    /// `networksetup -listallnetworkservices`: one per line after the note, a leading * marks a disabled one.
    public static func services(_ output: String) -> [String] {
        output.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("An asterisk") && !$0.isEmpty }
            .map { $0.hasPrefix("*") ? String($0.dropFirst()) : $0 }
    }

    /// `networksetup -getdnsservers <service>`: the addresses, or none when DNS is automatic ("There aren't any…").
    public static func verifiedServers(_ output: String) -> [String]? {
        if output.hasPrefix("There aren't any DNS Servers set on ") { return [] }
        let parsed = servers(output)
        return parsed.isEmpty ? nil : parsed
    }

    public static func servers(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter(DNSAddress.valid)
    }
}

/// The helper's answer.
public struct DNSHelperReply: Codable, Equatable, Sendable {
    public var ok: Bool
    public var message: String
    public var rejectedBeforeWrite: Bool?
    public init(ok: Bool, message: String, rejectedBeforeWrite: Bool? = nil) {
        self.ok = ok; self.message = message; self.rejectedBeforeWrite = rejectedBeforeWrite
    }
}

/// The request was rejected before any DNS command could run.
public struct DNSWriteRejected: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
