import Foundation
import Darwin
import SystemConfiguration

/// Watches the connection come back after a wake, twice a second for up to 90 seconds: the link from macOS's network
/// state, the address from the interface, then a name lookup and one web request to Apple's connectivity page (the
/// same check the outage log uses), and a ping beside them. Nothing is sent before the Mac has an address.
public enum WakeProbe {
    public static let limit: TimeInterval = 90
    public static let every: TimeInterval = 0.5

    /// `State:/Network/Interface/<name>/Link` has `Active` true while Wi-Fi is joined or the cable has a link.
    public static func linkActive(_ value: [String: Any]?) -> Bool? {
        guard let value else { return nil }
        return (value["Active"] as? Bool) ?? (value["Active"] as? NSNumber)?.boolValue
    }
    /// An IPv4 address macOS didn't make up for itself (169.254.x.x).
    public static func usableAddress(_ address: String) -> Bool {
        AddressRange.parse(address) != nil && !address.hasPrefix("169.254.") && !address.hasPrefix("0.")
    }
    /// A lookup that answered with a record.
    public static func dnsAnswered(dig output: String) -> Bool {
        output.contains("status: NOERROR") && output.contains("ANSWER SECTION")
    }

    static func link(_ interface: String) -> Bool? {
        linkActive(SCDynamicStoreCopyValue(nil, "State:/Network/Interface/\(interface)/Link" as CFString) as? [String: Any])
    }
    static func primaryInterface() -> String? {
        (SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any])?["PrimaryInterface"] as? String
    }
    static func hasAddress(_ interface: String) -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard String(cString: entry.pointee.ifa_name) == interface, let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            if usableAddress(String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) { return true }
        }
        return false
    }
    static func lookup() async -> Bool {
        dnsAnswered(dig: await CommandRunner.run("/usr/bin/dig", ["+time=1", "+tries=1", "apple.com", "A"], timeout: 2).output)
    }
    static func webRequest() async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://www.apple.com/library/test/success.html")!)
        request.httpMethod = "HEAD"; request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse).map { (200..<400).contains($0.statusCode) } ?? false
    }

    /// One wake. `interface` is the one the Mac used before sleeping; without one, whichever macOS makes primary.
    public static func watch(woke: Date, slept: Date?, interface: String?, wired: Bool, limit: TimeInterval = limit) async -> WakeRecord {
        var watch = WakeWatch(woke: woke, slept: slept, interface: interface, wired: wired)
        func now() -> Double { Date().timeIntervalSince(woke) }
        while now() < limit, !Task.isCancelled, !watch.done(at: now()) {
            let name = interface ?? primaryInterface()
            watch.observe(at: now(), link: name.flatMap(link), address: name.map(hasAddress))
            guard watch.record.address != nil else { try? await Task.sleep(for: .seconds(every)); continue }
            let needsPing = watch.record.ping == nil
            async let ping = needsPing ? DiagnosticProbe.ping("1.1.1.1", count: 1) : nil
            if watch.record.dns == nil {
                if await lookup() { watch.dnsAnswered(at: now()) }
            } else if watch.record.internet == nil {
                if await webRequest() { watch.internetAnswered(at: now()) }
            } else { try? await Task.sleep(for: .seconds(every)) }
            if let reply = await ping, reply.average != nil { watch.pingAnswered(at: now()) }
        }
        let path = await ExitPath.current()
        watch.tunnel(vpn: path.vpnName, full: path.vpn == .full)
        watch.observe(at: now(), link: nil, address: nil)
        return watch.record
    }
}
