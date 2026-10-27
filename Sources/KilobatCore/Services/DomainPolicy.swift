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
            var words = clean.split(whereSeparator: \.isWhitespace).map(String.init)
            if let first = words.first, ["0.0.0.0", "127.0.0.1", "::1", "::"].contains(first) { words.removeFirst() }
            for word in words {
                let domain = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if ["localhost", "localhost.localdomain", "broadcasthost", "ip6-localhost", "ip6-loopback"].contains(domain) { continue }
                let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
                guard domain.count <= 253, labels.count > 1,
                      domain.contains(where: { $0.isLetter }), labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" && $0.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 } }) else { throw invalid("Invalid domain in list: \(word)") }
                domains.insert(domain)
                guard domains.count <= 10000 else { throw invalid("Use at most 10,000 domains.") }
            }
        }
        guard !domains.isEmpty else { throw invalid("No domains found in list.") }
        return domains.sorted()
    }

    public static func matches(_ host: String, domain: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let domain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return !domain.isEmpty && (host == domain || host.hasSuffix("." + domain))
    }
    public static func blocked(_ host: String, app: String, domains: [String], exceptions: [String: [String]]) -> String? {
        guard !(exceptions[app] ?? []).contains(where: { matches(host, domain: $0) }) else { return nil }
        return domains.first { matches(host, domain: $0) }
    }
}
