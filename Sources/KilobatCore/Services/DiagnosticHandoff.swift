import Foundation

/// Explicit expert operations; no capture or scan runs as part of background monitoring.
public enum DiagnosticHandoff {
    public static func httpTiming(url: String) async throws -> String {
        guard let endpoint = URL(string: url), ["http", "https"].contains(endpoint.scheme), endpoint.host != nil, endpoint.user == nil, endpoint.password == nil else { throw DiagnosticError("Use an HTTP or HTTPS URL without credentials.") }
        let format = "HTTP %{http_code}\nDNS %{time_namelookup}s\nConnect %{time_connect}s\nTLS %{time_appconnect}s\nFirst byte %{time_starttransfer}s\nTotal %{time_total}s\n"
        let result = await CommandRunner.run("/usr/bin/curl", ["--head", "--silent", "--show-error", "--max-time", "10", "--output", "/dev/null", "--write-out", format, "--", url], timeout: 12)
        guard result.status == 0 else { throw DiagnosticError(result.output) }
        return result.output + "Cumulative request timings; no decryption proxy or response body captured."
    }
    public static func browseBonjour(type: String) async throws -> String {
        guard type.range(of: #"^_[a-zA-Z0-9-]+\._(tcp|udp)$"#, options: .regularExpression) != nil else { throw DiagnosticError("Use a Bonjour service type such as _ipp._tcp.") }
        let result = await CommandRunner.run("/usr/bin/dns-sd", ["-B", type, "local."], timeout: 6)
        return result.output.isEmpty ? "No service instances observed. Check Local Network permission." : result.output
    }
    public static func signature(pid: Int32) async throws -> String {
        guard pid > 0 else { throw DiagnosticError("Invalid process ID.") }
        let files = await CommandRunner.run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "txt", "-Fn"], timeout: 4)
        guard let executable = files.output.split(separator: "\n").first(where: { $0.hasPrefix("n/") }) else { throw DiagnosticError("Executable path unavailable; the process may have exited.") }
        let path = String(executable.dropFirst())
        let result = await CommandRunner.run("/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", path], timeout: 8)
        let details = await CommandRunner.run("/usr/bin/codesign", ["-d", "--verbose=2", path], timeout: 8)
        return "\(path)\nVerification: \(result.status == 0 ? "passed" : "failed or unsigned")\n\(result.output)\n\(details.output)\nA valid signature identifies signed code; it does not establish that its network activity is safe."
    }
    public static func discoverHosts(target: String) async throws -> String {
        // Deliberately restrict discovery to private IPv4 ranges, with at most 256 addresses.
        let pieces = target.split(separator: "/", omittingEmptySubsequences: false)
        let octets = pieces.first?.split(separator: ".").compactMap { Int($0) } ?? []
        guard pieces.count <= 2, octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }),
              octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 172 && (16...31).contains(octets[1])),
              pieces.count == 1 || Int(pieces[1]).map({ (24...32).contains($0) }) == true else { throw DiagnosticError("Enter a private IPv4 address or a /24…/32 private subnet.") }
        guard let binary = ["/opt/homebrew/bin/nmap", "/usr/local/bin/nmap"].first(where: FileManager.default.isExecutableFile) else { throw DiagnosticError("Install nmap separately to use host discovery. No scanner is bundled.") }
        let result = await CommandRunner.run(binary, ["-sn", "-n", "--max-retries", "1", "--host-timeout", "3s", target], timeout: 30)
        return result.output.isEmpty ? "No discovery output. Check local network access." : result.output
    }
    public static func capture(interface: String, destination: URL) async throws {
        guard ExpertTools.interfaces().contains(where: { $0.name == interface }), destination.isFileURL else { throw DiagnosticError("Select an existing interface and a local output file.") }
        // Bounded packet count plus an independent 15-second deadline. Payloads are
        // truncated to 96 bytes; even headers may contain private information.
        let quote = DNSService.shellQuote
        let command = """
        capture_file=$(/usr/bin/mktemp /private/tmp/kilobat-capture.XXXXXX) || exit 1
        trap '/bin/rm -f "$capture_file"' EXIT
        /usr/sbin/tcpdump -i \(quote(interface)) -n -s 96 -c 1000 -w "$capture_file" >/dev/null 2>&1 & capture_pid=$!
        ( /bin/sleep 15; /bin/kill -INT $capture_pid 2>/dev/null ) & timer_pid=$!
        wait $capture_pid; capture_status=$?
        /bin/kill $timer_pid 2>/dev/null
        if [ "$capture_status" -ne 0 ]; then echo "Packet capture failed"; exit 1; fi
        /usr/bin/base64 -i "$capture_file"
        """
        let encoded = try await NetworkTools.administrator(command)
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), data.count >= 24 else { throw DiagnosticError("Capture produced no valid file.") }
        try data.write(to: destination, options: .atomic)
    }
}
