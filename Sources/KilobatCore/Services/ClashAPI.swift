import Foundation

/// Read-only access to a Clash-compatible API (mihomo, Clash Verge, ClashX, Mihomo Party, FlClash, sing-box's
/// clash_api): which rule and proxy each connection took, the proxy groups, and how fast a node answers.
public struct ClashAPI: Sendable {
    public let controller: String
    let secret: String?

    public init(controller: String, secret: String?) { self.controller = controller; self.secret = secret }
    public init?(_ client: ProxyEnvironment.Client) {
        guard let controller = client.controller else { return nil }
        self.init(controller: controller, secret: client.secret)
    }

    public struct Connection: Sendable, Equatable {
        public let host: String
        public let destination: String
        public let sourcePort: String
        public let processPath: String
        public let rule: String
        public let rulePayload: String
        /// Outermost first, as Clash lists them: the node actually used, then the groups that chose it.
        public let chains: [String]
        public let upload: UInt64
        public let download: UInt64
        public var node: String { chains.first ?? "" }
        public var direct: Bool { node == "DIRECT" }
        public var rejected: Bool { node.hasPrefix("REJECT") }
    }

    public struct Group: Codable, Sendable, Equatable {
        public let name: String
        public let type: String
        /// The node the group uses now.
        public let now: String?
        public let size: Int
    }

    func request(_ path: String, timeout: TimeInterval = 4) async throws -> Data {
        guard let url = URL(string: "http://" + controller + path) else { throw DiagnosticError("The proxy app's API address isn't valid.") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let secret, !secret.isEmpty { request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw DiagnosticError("The proxy app's API wants a secret Kilobat couldn't read.") }
        guard (200..<300).contains(status) else { throw DiagnosticError("The proxy app's API answered HTTP \(status).") }
        return data
    }

    public func version() async throws -> String {
        let value = try JSONSerialization.jsonObject(with: try await request("/version")) as? [String: Any]
        return (value?["version"] as? String) ?? "unknown"
    }

    /// Mode and TUN as the running core reports them, which may differ from its config file.
    public func configs() async throws -> (mode: String?, tun: Bool?) {
        let value = try JSONSerialization.jsonObject(with: try await request("/configs")) as? [String: Any]
        let tun = (value?["tun"] as? [String: Any])?["enable"] as? Bool
        return ((value?["mode"] as? String)?.lowercased(), tun)
    }

    /// The core's own HTTP and SOCKS ports, for matching connections to apps.
    public func ports() async throws -> [String] {
        let value = try JSONSerialization.jsonObject(with: try await request("/configs")) as? [String: Any] ?? [:]
        return ["mixed-port", "port", "socks-port"].compactMap { (value[$0] as? NSNumber)?.intValue }.filter { $0 > 0 }.map(String.init)
    }

    public func connections() async throws -> [Connection] {
        try Self.connections(try await request("/connections"))
    }

    public static func connections(_ data: Data) throws -> [Connection] {
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((value?["connections"] as? [[String: Any]]) ?? []).map { item in
            let meta = item["metadata"] as? [String: Any] ?? [:]
            func string(_ key: String) -> String { (meta[key] as? String) ?? (meta[key] as? NSNumber)?.stringValue ?? "" }
            let host = string("host").isEmpty ? string("sniffHost") : string("host")
            let destination = [string("remoteDestination"), string("destinationIP")].first { !$0.isEmpty } ?? ""
            return Connection(host: host.isEmpty ? destination : host, destination: destination, sourcePort: string("sourcePort"),
                              processPath: string("processPath"), rule: (item["rule"] as? String) ?? "", rulePayload: (item["rulePayload"] as? String) ?? "",
                              chains: (item["chains"] as? [String]) ?? [],
                              upload: (item["upload"] as? NSNumber)?.uint64Value ?? 0, download: (item["download"] as? NSNumber)?.uint64Value ?? 0)
        }
    }

    /// Selector and automatic groups with the node each uses now; single nodes are left out.
    public func groups() async throws -> [Group] {
        let value = try JSONSerialization.jsonObject(with: try await request("/proxies")) as? [String: Any]
        let proxies = value?["proxies"] as? [String: [String: Any]] ?? [:]
        let kinds: Set<String> = ["Selector", "URLTest", "Fallback", "LoadBalance", "Relay"]
        return proxies.compactMap { name, item in
            guard let type = item["type"] as? String, kinds.contains(type), name != "GLOBAL" || proxies.count < 3 else { return nil }
            return Group(name: name, type: type, now: item["now"] as? String, size: (item["all"] as? [Any])?.count ?? 0)
        }.sorted { $0.name < $1.name }
    }

    /// Milliseconds for one request through `node` to a small, fast page; nil when it times out.
    public func delay(_ node: String, url: String = "https://www.gstatic.com/generate_204", timeout: Int = 5000) async -> Int? {
        let name = node.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? node
        let target = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?:/"))) ?? url
        guard let data = try? await request("/proxies/\(name)/delay?url=\(target)&timeout=\(timeout)", timeout: Double(timeout) / 1000 + 2),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (value["delay"] as? NSNumber)?.intValue
    }
}

/// Which app took which route through a proxy: Clash's connections, matched to apps by executable path or, for a
/// system-proxy connection where the core can't see the app, by the local port the app connected from.
public struct ProxyRoute: Codable, Sendable, Equatable {
    public let app: String
    public let host: String
    public let rule: String
    public let node: String
    public let group: String?
    public let upload: UInt64
    public let download: UInt64

    /// `lsof -iTCP -sTCP:ESTABLISHED` lines from this Mac: the app process behind each 127.0.0.1 source port.
    public static func owners(_ lsof: String, proxyPorts: Set<String>) -> [String: (pid: Int32, command: String)] {
        var owners: [String: (pid: Int32, command: String)] = [:]
        for line in lsof.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 9, let pid = Int32(columns[1]) else { continue }
            let name = columns.count >= 10 ? columns[columns.count - 2] : columns[columns.count - 1]
            let parts = name.split(separator: "-").map(String.init)
            guard parts.count >= 2, let source = parts[0].split(separator: ":").last, let target = parts.last?.split(separator: ":").last else { continue }
            // The app's side of a connection to the proxy port, not the proxy's side of the same connection.
            if parts[0].hasPrefix("127.0.0.1:") || parts[0].hasPrefix("[::1]:"), proxyPorts.contains(String(target).replacingOccurrences(of: ">", with: "")) {
                owners[String(source)] = (pid, String(columns[0]).replacingOccurrences(of: "\\x20", with: " "))
            }
        }
        return owners
    }

    public static func routes(_ connections: [ClashAPI.Connection], owners: [String: (pid: Int32, command: String)],
                              name: (String) -> String = { ProxyRoute.appName(path: $0) }) -> [ProxyRoute] {
        connections.map { connection in
            let app: String
            if !connection.processPath.isEmpty { app = name(connection.processPath) }
            else if let owner = owners[connection.sourcePort] {
                app = ProcessOwnership.applicationPath(pid: owner.pid).map { name($0) } ?? owner.command
            } else { app = "Unknown app" }
            let rule = connection.rulePayload.isEmpty ? connection.rule : connection.rule + "," + connection.rulePayload
            return ProxyRoute(app: app, host: connection.host, rule: rule, node: connection.node,
                              group: connection.chains.count > 1 ? connection.chains.last : nil, upload: connection.upload, download: connection.download)
        }
    }

    /// "Telegram" from /Applications/Telegram.app/Contents/MacOS/Telegram; the file name for anything else.
    public static func appName(path: String) -> String {
        // The outermost bundle, so a helper inside an app counts as the app.
        if let range = path.range(of: ".app/") ?? path.range(of: ".app", options: [.backwards, .anchored]) {
            let bundle = String(path[..<range.lowerBound])
            return (bundle as NSString).lastPathComponent
        }
        return (path as NSString).lastPathComponent
    }
}
