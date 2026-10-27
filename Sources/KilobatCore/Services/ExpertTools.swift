import Foundation
import Observation
import Darwin

public struct SocketDestination: Codable, Identifiable, Sendable {
    public var id: String { "\(pid):\(transport):\(endpoint)" }
    public let pid: Int32
    public let process: String
    public let transport: String
    public let endpoint: String
    public let state: String
    public let date: Date
    public var remoteHostAndPort: (String, String)? {
        guard endpoint.contains("->"), let remote = endpoint.components(separatedBy: "->").last, let colon = remote.lastIndex(of: ":") else { return nil }
        let host = String(remote[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let port = String(remote[remote.index(after: colon)...])
        guard ExpertTools.validHost(host), Int(port).map({ (1...65535).contains($0) }) == true else { return nil }
        return (host, port)
    }
}
public struct LANDevice: Codable, Identifiable, Sendable {
    public var id: String { address }
    public let address: String
    public let mac: String
    public let interface: String
    public var name: String
}
public struct ResolverTiming: Codable, Identifiable, Sendable {
    public var id: String { resolver }
    public let resolver: String
    public let milliseconds: Double?
    public let replies: Int
}
public struct InterfaceReading: Codable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let received: UInt64
    public let sent: UInt64
    public let up: Bool
    public var vpn: Bool { name.hasPrefix("utun") || name.hasPrefix("ppp") || name.hasPrefix("ipsec") }
}
public enum ExpertTools {
    public static func destinations(pid: Int32? = nil) async throws -> [SocketDestination] {
        var args = ["+c", "0", "-nP", "-iTCP", "-iUDP", "-FpcPfnT"]
        if let pid { args += ["-a", "-p", String(pid)] }
        let result = await CommandRunner.run("/usr/sbin/lsof", args, timeout: 8)
        guard result.status == 0 || result.status == 1 else { throw DiagnosticError("Socket inventory unavailable: \(result.output)") }
        return parseSockets(result.output)
    }
    public static func parseSockets(_ output: String, date: Date = Date()) -> [SocketDestination] {
        var pid: Int32 = 0, process = "", proto = "", endpoint = "", state = ""
        var rows: [SocketDestination] = []
        func flush() {
            if !endpoint.isEmpty { rows.append(SocketDestination(pid: pid, process: process, transport: proto, endpoint: endpoint, state: state, date: date)) }
            endpoint = ""; state = ""
        }
        for line in output.split(separator: "\n") {
            guard let code = line.first else { continue }; let value = String(line.dropFirst())
            switch code {
            case "p": flush(); pid = Int32(value) ?? 0
            case "c": process = value
            case "f": flush()
            case "P": proto = value
            case "n": endpoint = value
            case "T": if value.hasPrefix("ST=") { state = String(value.dropFirst(3)) }
            default: break
            }
        }
        flush(); return Array(Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }).values).sorted { $0.id < $1.id }
    }
    public static func reverseName(for endpoint: String) async -> String {
        let remote = endpoint.components(separatedBy: "->").last ?? endpoint
        let address: String
        if remote.hasPrefix("["), let end = remote.firstIndex(of: "]") { address = String(remote[remote.index(after: remote.startIndex)..<end]) }
        else if remote.filter({ $0 == ":" }).count == 1 { address = remote.components(separatedBy: ":").first ?? remote }
        else { address = remote }
        guard validHost(address), address != "*" else { return "No remote address to resolve." }
        let result = await CommandRunner.run("/usr/bin/dig", ["-x", address, "+short", "+tries=1", "+time=2"], timeout: 3)
        let name = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "No reverse DNS name. IP ownership is unknown." : "Reverse DNS: " + name + " (not proof of ownership or the requested domain)"
    }
    public static func devices() async -> [LANDevice] {
        let result = await CommandRunner.run("/usr/sbin/arp", ["-an"], timeout: 5)
        return result.output.split(separator: "\n").compactMap { line in
            let s = String(line)
            guard let address = DiagnosticProbe.matches(#"\(([^)]+)\)"#, in: s).first,
                  let mac = DiagnosticProbe.matches(#" at ([0-9a-f:]+) "#, in: s).first,
                  let interface = DiagnosticProbe.matches(#" on (\S+)"#, in: s).first else { return nil }
            let name = s.components(separatedBy: " (").first ?? "Unknown"
            return LANDevice(address: address, mac: mac, interface: interface, name: name == "?" ? address : name)
        }
    }
    public static func bonjour() async -> String {
        let result = await CommandRunner.run("/usr/bin/dns-sd", ["-B", "_services._dns-sd._udp", "local."], timeout: 5)
        return result.output.isEmpty ? "No Bonjour service types observed. Local Network permission may be required." : result.output
    }
    public static func route(to host: String) async throws -> String {
        guard validHost(host) else { throw DiagnosticError("Enter a hostname or IP address, without a URL or options.") }
        let result = await CommandRunner.run("/usr/sbin/traceroute", ["-n", "-m", "12", "-q", "1", "-w", "1", host], timeout: 18)
        return result.output + "\nIntermediate routers may ignore probes; * alone is not evidence of packet loss."
    }
    public static func validHost(_ host: String) -> Bool {
        !host.isEmpty && host.count <= 253 && host.first != "-" && host.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:").contains($0) }
    }
    public static func benchmarkDNS() async -> [ResolverTiming] { await ResolverBenchmark.run() }
    public static func interfaces() -> [InterfaceReading] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var rows: [InterfaceReading] = []; var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            let item = pointer.pointee; cursor = item.ifa_next
            guard item.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), let data = item.ifa_data else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            rows.append(InterfaceReading(name: String(cString: item.ifa_name), received: UInt64(counters.ifi_ibytes), sent: UInt64(counters.ifi_obytes), up: item.ifa_flags & UInt32(IFF_UP) != 0))
        }
        return rows.sorted { $0.name < $1.name }
    }
    public static func lanSpeed(host: String, reverse: Bool = false) async throws -> String {
        guard validHost(host) else { throw DiagnosticError("Enter the local iperf3 server hostname or IP.") }
        guard let executable = ["/opt/homebrew/bin/iperf3", "/usr/local/bin/iperf3"].first(where: FileManager.default.isExecutableFile) else { throw DiagnosticError("Install iperf3 (brew install iperf3), then run iperf3 -s on a second LAN device. Nothing is installed automatically.") }
        let result = await CommandRunner.run(executable, ["-c", host, "-t", "5", "--connect-timeout", "3000", "-J"] + (reverse ? ["-R"] : []), timeout: 12)
        guard result.status == 0 else { throw DiagnosticError(result.output.isEmpty ? "LAN test failed. Check the server and firewall." : result.output) }
        return result.output
    }
    public static func encryptedDNSProfile(url: String) throws -> Data {
        guard let endpoint = URL(string: url), endpoint.scheme == "https", endpoint.host != nil, endpoint.user == nil, endpoint.password == nil else { throw DiagnosticError("Enter an HTTPS DNS-over-HTTPS endpoint.") }
        let payload: [String: Any] = ["PayloadType": "com.apple.dnsSettings.managed", "PayloadVersion": 1, "PayloadIdentifier": "co.seifi.kilobat.dns.settings", "PayloadUUID": UUID().uuidString, "PayloadDisplayName": "Kilobat encrypted DNS", "DNSSettings": ["DNSProtocol": "HTTPS", "ServerURL": url]]
        let profile: [String: Any] = ["PayloadType": "Configuration", "PayloadVersion": 1, "PayloadIdentifier": "co.seifi.kilobat.dns", "PayloadUUID": UUID().uuidString, "PayloadDisplayName": "Kilobat encrypted DNS", "PayloadDescription": "DNS-over-HTTPS. Review and install in System Settings. Remove this profile to restore previous DNS behavior. VPN/split DNS and captive portals may require disabling it.", "PayloadContent": [payload]]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }
}

@MainActor @Observable public final class ToolsStore {
    public var section = "History"
    public var filter = ""
    public var socketKind = "All"
    public var favoritesOnly = false
    public var favorites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "destinationFavorites") ?? [])
    public func toggleFavorite(_ endpoint: String) {
        if favorites.contains(endpoint) { favorites.remove(endpoint) } else { favorites.insert(endpoint) }
        UserDefaults.standard.set(Array(favorites).sorted(), forKey: "destinationFavorites")
    }
    public var visibleSockets: [SocketDestination] {
        sockets.filter {
            (filter.isEmpty || "\($0.process) \($0.pid) \($0.endpoint) \($0.state)".localizedCaseInsensitiveContains(filter)) &&
            (!favoritesOnly || favorites.contains($0.endpoint)) &&
            (socketKind == "All" || (socketKind == "Listening" ? $0.state == "LISTEN" : $0.endpoint.contains("->")))
        }
    }
    public var sockets: [SocketDestination] = []
    public private(set) var currentSocketIDs: Set<String> = []
    public var devices: [LANDevice] = []
    public var resolverProgress = ResolverBenchmark.resolvers.map { ResolverProgress(resolver: $0) }
    public private(set) var benchmarking = false
    public private(set) var benchmarkCancelled = false
    private var benchmarkTask: Task<Void, Never>?
    public var resolverTimes: [ResolverTiming] = []
    public var output = ""
    public var busy = false
    public var names: [String: String] = UserDefaults.standard.dictionary(forKey: "deviceNames") as? [String: String] ?? [:]
    public func rename(_ device: LANDevice, to name: String) { names[device.mac] = name; UserDefaults.standard.set(names, forKey: "deviceNames") }
    public func refreshSockets() async {
        busy = true; defer { busy = false }
        do {
            let observed = try await ExpertTools.destinations()
            currentSocketIDs = Set(observed.map(\.id))
            let current = Dictionary(observed.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            var merged = Dictionary(sockets.filter { Date().timeIntervalSince($0.date) < 86400 }.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            merged.merge(current) { _, new in new }
            sockets = Array(merged.values.sorted { $0.date > $1.date }.prefix(1000))
        } catch { output = error.localizedDescription }
    }
    public func discover() async { busy = true; defer { busy = false }; devices = await ExpertTools.devices(); output = await ExpertTools.bonjour() }
    public func startBenchmark() {
        guard !benchmarking else { return }
        benchmarking = true; benchmarkCancelled = false; resolverTimes = []
        resolverProgress = ResolverBenchmark.resolvers.map { ResolverProgress(resolver: $0) }
        benchmarkTask = Task { [weak self] in
            let results = await ResolverBenchmark.run { [weak self] row in
                await self?.updateResolver(row)
            }
            guard let self else { return }
            self.resolverTimes = results; self.benchmarking = false; self.benchmarkTask = nil
        }
    }
    private func updateResolver(_ row: ResolverProgress) {
        if let i = resolverProgress.firstIndex(where: { $0.resolver == row.resolver }) { resolverProgress[i] = row }
    }
    public func cancelBenchmark() { benchmarkCancelled = true; benchmarkTask?.cancel() }

}
