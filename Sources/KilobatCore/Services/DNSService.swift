import Foundation

public enum DNSService {
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    /// What `networksetup -setdnsservers` is given: the resolver's addresses, or "Empty" for Network DNS, the network's own.
    public static func arguments(_ choice: DNSResolverChoice) -> [String] { choice.isNetwork ? ["Empty"] : choice.servers }
    /// The person's own switch from Health or the command line, with macOS's administrator prompt. Kilobat's automatic
    /// switching goes through its helper instead (FastestDNSWatch).
    public static func set(_ choice: DNSResolverChoice, service: String) async throws {
        guard !service.isEmpty, !service.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DiagnosticError("The network service name is invalid.")
        }
        guard choice.isNetwork || (!choice.servers.isEmpty && choice.servers.allSatisfy(DNSAddress.valid)) else {
            throw DiagnosticError("That isn’t a resolver’s IP address.")
        }
        // User-initiated only. Administrator credentials are handled by macOS,
        // never read by the app. All shell arguments are quoted separately.
        let command = (["/usr/sbin/networksetup", "-setdnsservers", service] + arguments(choice)).map(shellQuote).joined(separator: " ")
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let result = await CommandRunner.run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"], timeout: 120)
        guard result.status == 0 else { throw DiagnosticError(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let check = await CommandRunner.run("/usr/sbin/networksetup", ["-getdnsservers", service])
        guard check.status == 0 else { throw DiagnosticError("DNS was applied, but the new configuration could not be read. Check System Settings.") }
        if !choice.isNetwork && !choice.servers.allSatisfy({ check.output.contains($0) }) {
            throw DiagnosticError("The DNS setting did not match the requested servers. Check System Settings.")
        }
    }
}
