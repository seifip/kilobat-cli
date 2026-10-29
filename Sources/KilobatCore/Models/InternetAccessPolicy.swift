import Foundation

/// What an app's developer says it connects to and why, from the `InternetAccessPolicy` file some apps ship
/// in their bundle (the format Little Snitch introduced). Read locally; nothing is fetched.
public struct InternetAccessPolicy: Sendable, Equatable {
    public struct Connection: Sendable, Equatable, Identifiable {
        public let hosts: [String]
        public let incoming: Bool
        public let networkProtocol: String?
        public let port: String?
        public let purpose: String
        public let denyConsequences: String?
        public let essential: Bool
        public var id: String { hosts.joined(separator: ",") + "|" + (port ?? "") + "|" + purpose }
    }
    public let description: String?
    public let developer: String?
    public let website: URL?
    public let connections: [Connection]

    public static func load(bundlePath: String) -> InternetAccessPolicy? {
        let resources = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Resources")
        for name in ["InternetAccessPolicy.plist", "InternetAccessPolicy.json"] {
            guard let data = try? Data(contentsOf: resources.appendingPathComponent(name)), data.count < 1_000_000 else { continue }
            let object = name.hasSuffix(".json") ? try? JSONSerialization.jsonObject(with: data) : try? PropertyListSerialization.propertyList(from: data, format: nil)
            if let root = object as? [String: Any], let policy = parse(root) { return policy }
        }
        return nil
    }

    static func parse(_ root: [String: Any]) -> InternetAccessPolicy? {
        func text(_ value: Any?) -> String? {
            (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        let connections = (root["Connections"] as? [[String: Any]] ?? []).compactMap { item -> Connection? in
            let hosts = (text(item["Host"]) ?? "").split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            guard !hosts.isEmpty, let purpose = text(item["Purpose"]) else { return nil }
            let port = text(item["Port"]) ?? (item["Port"] as? Int).map(String.init)
            return Connection(hosts: hosts, incoming: item["IsIncoming"] as? Bool ?? false, networkProtocol: text(item["NetworkProtocol"]),
                              port: port, purpose: purpose, denyConsequences: text(item["DenyConsequences"]),
                              essential: text(item["Relevance"])?.lowercased() == "essential")
        }
        let description = text(root["ApplicationDescription"])
        guard !connections.isEmpty || description != nil else { return nil }
        let website = text(root["Website"]).flatMap(URL.init(string:)).flatMap { ["https", "http"].contains($0.scheme?.lowercased()) ? $0 : nil }
        return InternetAccessPolicy(description: description, developer: text(root["DeveloperName"]), website: website, connections: connections)
    }

    /// The declared connection that covers a host, if any. `*.example.com` covers subdomains only, as in the format.
    public func connection(for host: String) -> Connection? {
        let host = host.lowercased()
        return connections.first { $0.hosts.contains { pattern in
            let pattern = pattern.lowercased()
            return pattern.hasPrefix("*.") ? host.hasSuffix(pattern.dropFirst()) : host == pattern
        } }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
