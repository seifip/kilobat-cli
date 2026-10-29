import Foundation

public enum DomainPolicy {
    public static func parseList(_ data: Data) throws -> [String] {
        func invalid(_ message: String) -> NSError { NSError(domain: "Kilobat", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        guard data.count <= 5_000_000 else { throw invalid("List is larger than 5 MB.") }
        var domains = Set<String>()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let clean = (line.split(separator: "#", omittingEmptySubsequences: false).first ?? "").trimmingCharacters(in: .whitespaces)
            if clean.isEmpty { continue }
            if clean.contains("|") || clean.hasPrefix("!") || clean.hasPrefix("[") { throw invalid("Use a plain domains or hosts list; Adblock syntax is not supported.") }
            // Hosts files map addresses to names; only the names after them are blocked. A line with only an
            // address or range blocks that address.
            let all = clean.split(whereSeparator: \.isWhitespace).map(String.init)
            let words = all.count == 1 ? all : Array(all.drop(while: isAddress))
            for word in words {
                guard let entry = entry(word) else { continue }
                domains.insert(entry)
                guard domains.count <= 10000 else { throw invalid("Use at most 10,000 domains.") }
            }
        }
        guard !domains.isEmpty else { throw invalid("No domains found in list.") }
        return domains.sorted()
    }

    /// One blocklist entry: a domain (a leading `*.` is accepted and means the same), an IP address or a CIDR range.
    public static func entry(_ word: String) -> String? {
        var domain = word.lowercased().trimmingCharacters(in: .whitespaces)
        if domain.hasPrefix("*.") { domain.removeFirst(2) }
        domain = domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let range = AddressRange(domain) {
            // Hosts files point names at 0.0.0.0 or loopback; those addresses are not themselves worth blocking.
            let local = range.bytes.allSatisfy { $0 == 0 } || range.bytes.first == 127 || range.bytes == [UInt8](repeating: 0, count: 15) + [1]
            return range.isEverything || local ? nil : range.description
        }
        if ["localhost", "localhost.localdomain", "broadcasthost", "ip6-localhost", "ip6-loopback"].contains(domain) { return nil }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard domain.count <= 253, labels.count > 1,
              domain.contains(where: { $0.isLetter }), labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" && $0.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 } }) else { return nil }
        return domain
    }

    static func isAddress(_ word: String) -> Bool {
        word.contains(":") || (!word.isEmpty && word.allSatisfy { $0.isNumber || $0 == "." })
    }

    public static func matches(_ host: String, domain: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let domain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return !domain.isEmpty && (host == domain || host.hasSuffix("." + domain))
    }
    /// The entry that blocks a connection, matching the hostname against domains and the remote address
    /// against IPs and ranges. An app's exceptions win.
    public static func blocked(_ host: String?, address: String? = nil, app: String, domains: [String], exceptions: [String: [String]]) -> String? {
        let ip = address.flatMap(AddressRange.parse) ?? host.flatMap(AddressRange.parse)
        func hit(_ entry: String) -> Bool {
            if let range = AddressRange(entry) { return ip.map(range.contains) ?? false }
            return host.map { matches($0, domain: entry) } ?? false
        }
        guard !(exceptions[app] ?? []).contains(where: hit) else { return nil }
        return domains.first(where: hit)
    }
}

/// An IPv4 or IPv6 address, or a CIDR range of them.
struct AddressRange: CustomStringConvertible {
    let bytes: [UInt8]
    let prefix: Int
    init?(_ text: String) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2, let bytes = Self.parse(String(parts[0])) else { return nil }
        let bits = bytes.count * 8
        if parts.count == 2 { guard let prefix = Int(parts[1]), (0...bits).contains(prefix) else { return nil }; self.prefix = prefix } else { prefix = bits }
        self.bytes = bytes
    }
    var isEverything: Bool { prefix == 0 }
    var description: String {
        let address: String
        if bytes.count == 4 { address = bytes.map(String.init).joined(separator: ".") }
        else {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN)), raw = bytes
            address = inet_ntop(AF_INET6, &raw, &buffer, socklen_t(buffer.count)) != nil ? String(cString: buffer) : ""
        }
        return prefix == bytes.count * 8 ? address : address + "/\(prefix)"
    }
    func contains(_ other: [UInt8]) -> Bool {
        guard other.count == bytes.count else { return false }
        var remaining = prefix
        for index in bytes.indices where remaining > 0 {
            let take = min(8, remaining), mask = UInt8(truncatingIfNeeded: 0xFF << (8 - take))
            if bytes[index] & mask != other[index] & mask { return false }
            remaining -= take
        }
        return true
    }
    static func parse(_ text: String) -> [UInt8]? {
        var v4 = in_addr(), v6 = in6_addr()
        let clean = text.split(separator: "%").first.map(String.init) ?? text
        if inet_pton(AF_INET, clean, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        if inet_pton(AF_INET6, clean, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            // IPv4-mapped IPv6 addresses match IPv4 entries.
            return bytes.prefix(12) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF] ? Array(bytes.suffix(4)) : bytes
        }
        return nil
    }
}
