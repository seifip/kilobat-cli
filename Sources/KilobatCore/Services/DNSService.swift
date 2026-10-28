import Foundation

public enum DNSProvider: String, CaseIterable, Sendable {
    case automatic = "Automatic", cloudflare = "Cloudflare", google = "Google", quad9 = "Quad9"
    public var addresses: [String] {
        switch self { case .automatic: ["Empty"]; case .cloudflare: ["1.1.1.1", "1.0.0.1"]; case .google: ["8.8.8.8", "8.8.4.4"]; case .quad9: ["9.9.9.9", "149.112.112.112"] }
    }
}
public enum DNSService {
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func set(_ provider: DNSProvider, service: String) async throws {
        guard !service.isEmpty, !service.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DiagnosticError("The network service name is invalid.")
        }
        // User-initiated only. Administrator credentials are handled by macOS,
        // never read by the app. All shell arguments are quoted separately.
        let command = (["/usr/sbin/networksetup", "-setdnsservers", service] + provider.addresses).map(shellQuote).joined(separator: " ")
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let result = await CommandRunner.run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"], timeout: 120)
        guard result.status == 0 else { throw DiagnosticError(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let check = await CommandRunner.run("/usr/sbin/networksetup", ["-getdnsservers", service])
        guard check.status == 0 else { throw DiagnosticError("DNS was applied, but the new configuration could not be read. Check System Settings.") }
        if provider != .automatic && !provider.addresses.allSatisfy({ check.output.contains($0) }) {
            throw DiagnosticError("The DNS setting did not match the requested servers. Check System Settings.")
        }
    }
}
