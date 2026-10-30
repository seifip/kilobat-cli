import Foundation

/// Proxy clients on this Mac and the system proxy: Clash and its forks (mihomo, Clash Verge, ClashX, Mihomo Party,
/// FlClash), Surge, sing-box, Stash, V2Ray and Xray, Shadowsocks and the like. Kilobat only reads them: it never
/// routes traffic, changes a client's settings or turns a proxy on or off.
public struct ProxyEnvironment: Codable, Sendable, Equatable {
    /// One client, from its running process and, where Kilobat knows where it keeps it, its config.
    public struct Client: Codable, Sendable, Equatable {
        public var name: String
        public var running: Bool
        /// Where its Clash-compatible API listens, such as 127.0.0.1:9097. The secret is never part of any output.
        public var controller: String?
        var secret: String?
        /// Its local HTTP/SOCKS ports, such as 7897.
        public var ports: [String]
        /// From the client's config or API: rule, global or direct.
        public var mode: String?
        /// Whether it captures all traffic through a virtual interface rather than acting as a proxy apps opt into.
        public var tun: Bool?
        public var version: String?
        enum CodingKeys: String, CodingKey { case name, running, controller, ports, mode, tun, version }
        public init(name: String, running: Bool, controller: String? = nil, secret: String? = nil, ports: [String] = [], mode: String? = nil, tun: Bool? = nil, version: String? = nil) {
            self.name = name; self.running = running; self.controller = controller; self.secret = secret; self.ports = ports; self.mode = mode; self.tun = tun; self.version = version
        }
    }
    public struct SystemProxy: Codable, Sendable, Equatable {
        public var http: String?
        public var https: String?
        public var socks: String?
        public var pac: String?
        /// Set when the proxy points at this Mac and nothing listens there, so every app that uses it fails.
        public var dead: Bool = false
        public var any: Bool { http != nil || https != nil || socks != nil || pac != nil }
        /// "127.0.0.1:7897" for each local proxy, so traffic to it can be told apart from other local traffic.
        public var localPorts: [String] {
            [http, https, socks].compactMap { $0 }.filter { $0.hasPrefix("127.0.0.1:") || $0.hasPrefix("localhost:") || $0.hasPrefix("[::1]:") }
                .compactMap { $0.split(separator: ":").last.map(String.init) }
        }
    }

    public var date: Date
    public var system: SystemProxy
    public var clients: [Client]
    /// Processes that carry other apps' traffic, a proxy core or a VPN's tunnel process: pid and name.
    public var carriers: [Carrier]
    public struct Carrier: Codable, Sendable, Equatable { public var pid: Int32; public var name: String; public var kind: String }

    public var running: [Client] { clients.filter(\.running) }
    /// Local ports that lead to a proxy: the system proxy's and every running client's.
    public var proxyPorts: Set<String> { Set(system.localPorts + running.flatMap(\.ports)) }

    // MARK: Reading

    public static func current(home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> ProxyEnvironment {
        async let proxy = CommandRunner.run("/usr/sbin/scutil", ["--proxy"])
        async let processes = CommandRunner.run("/bin/ps", ["-axo", "pid=,comm="])
        async let listening = CommandRunner.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN"], timeout: 5)
        var system = systemProxy(await proxy.output)
        let table = Self.processes(await processes.output)
        let listeners = Self.listeners(await listening.output)
        var clients = known.compactMap { client($0, home: home, processes: table) }
        // A client that runs but whose config Kilobat doesn't know is still found by the ports it listens on.
        for (port, process) in listeners where system.localPorts.contains(port) && !clients.contains(where: { $0.ports.contains(port) }) {
            clients.append(Client(name: process, running: true, controller: nil, secret: nil, ports: [port], mode: nil, tun: nil, version: nil))
        }
        // A system proxy on this Mac with nobody listening breaks every app that follows it.
        if !system.localPorts.isEmpty {
            var reachable = false
            for port in system.localPorts where await Self.listens(port: port) { reachable = true }
            system.dead = !reachable
        }
        return ProxyEnvironment(date: Date(), system: system, clients: clients, carriers: carriers(table))
    }

    /// `scutil --proxy`: HTTPEnable, HTTPProxy, HTTPPort and the same for HTTPS and SOCKS, plus a PAC URL.
    public static func systemProxy(_ output: String) -> SystemProxy {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        func proxy(_ kind: String) -> String? {
            guard values[kind + "Enable"] == "1", let host = values[kind + "Proxy"], let port = values[kind + "Port"] else { return nil }
            return host + ":" + port
        }
        let pac = values["ProxyAutoConfigEnable"] == "1" ? values["ProxyAutoConfigURLString"] : nil
        return SystemProxy(http: proxy("HTTP"), https: proxy("HTTPS"), socks: proxy("SOCKS"), pac: pac)
    }

    /// `ps -axo pid=,comm=`: the pid and the executable's path.
    static func processes(_ output: String) -> [(pid: Int32, path: String)] {
        output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { return nil }
            return (pid, trimmed[space...].trimmingCharacters(in: .whitespaces))
        }
    }

    /// `lsof -iTCP -sTCP:LISTEN`: loopback ports and the process listening, for this user's processes.
    static func listeners(_ output: String) -> [(port: String, process: String)] {
        output.split(separator: "\n").dropFirst().compactMap { line in
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 9, let name = columns.dropLast().last ?? columns.last else { return nil }
            let address = String(name)
            guard address.hasPrefix("127.0.0.1:") || address.hasPrefix("[::1]:") || address.hasPrefix("localhost:"),
                  let port = address.split(separator: ":").last else { return nil }
            return (String(port), String(columns[0]).replacingOccurrences(of: "\\x20", with: " "))
        }
    }

    static func listens(port: String) async -> Bool {
        await CommandRunner.run("/usr/bin/nc", ["-z", "-G", "1", "127.0.0.1", port], timeout: 3).status == 0
    }

    // MARK: Known clients

    struct Known: Sendable {
        let name: String
        /// Executable names (the last path component) that mean it runs.
        let processes: [String]
        /// Config files relative to the home folder, first found wins: Clash YAML, or a Surge profile folder.
        let configs: [String]
        var surge = false
    }

    static let known: [Known] = [
        Known(name: "Clash Verge", processes: ["clash-verge", "verge-mihomo", "verge-mihomo-alpha"],
              configs: ["Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/config.yaml"]),
        Known(name: "ClashX", processes: ["ClashX", "ClashX Pro"], configs: [".config/clash/config.yaml"]),
        Known(name: "Mihomo Party", processes: ["mihomo-party", "Mihomo Party"], configs: ["Library/Application Support/mihomo-party/work/config.yaml"]),
        Known(name: "Clash Nyanpasu", processes: ["clash-nyanpasu"], configs: ["Library/Application Support/moe.elaina.clash.nyanpasu/config/clash-config.yaml"]),
        Known(name: "FlClash", processes: ["FlClash", "FlClashCore"], configs: ["Library/Application Support/com.follow.clash/config.yaml"]),
        Known(name: "mihomo", processes: ["mihomo", "clash", "clash-meta"], configs: [".config/mihomo/config.yaml", ".config/clash.meta/config.yaml"]),
        Known(name: "Surge", processes: ["Surge", "Surge Mac"], configs: ["Library/Application Support/com.nssurge.surge-mac/Profiles"], surge: true),
        Known(name: "Stash", processes: ["Stash"], configs: []),
        Known(name: "sing-box", processes: ["sing-box", "SFM"], configs: []),
        Known(name: "V2Ray or Xray", processes: ["v2ray", "xray", "V2rayU", "V2RayX"], configs: []),
        Known(name: "Shadowsocks", processes: ["ss-local", "sslocal", "ShadowsocksX-NG"], configs: []),
        Known(name: "Shadowrocket", processes: ["Shadowrocket"], configs: []),
        Known(name: "Hiddify", processes: ["Hiddify", "HiddifyCli"], configs: []),
    ]

    static func client(_ known: Known, home: URL, processes: [(pid: Int32, path: String)]) -> Client? {
        let running = processes.contains { process in known.processes.contains { process.path.hasSuffix("/" + $0) || process.path == $0 } }
        let config = known.configs.lazy.map { home.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
        guard running || config != nil else { return nil }
        var client = Client(name: known.name, running: running, controller: nil, secret: nil, ports: [], mode: nil, tun: nil, version: nil)
        guard let config else { return client }
        if known.surge { surge(config, into: &client) } else if let text = try? String(contentsOf: config, encoding: .utf8) { clash(text, into: &client) }
        return client
    }

    /// The top-level keys of a Clash config that say where it listens; enough YAML for that, no more.
    public static func clashSettings(_ yaml: String) -> (controller: String?, secret: String?, ports: [String], mode: String?, tun: Bool?) {
        var controller: String?, secret: String?, ports: [String] = [], mode: String?, tun: Bool?, inTun = false
        for raw in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if inTun, line.trimmingCharacters(in: .whitespaces).hasPrefix("enable:") { tun = line.contains("true") }
                continue
            }
            inTun = line.hasPrefix("tun:")
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch parts[0] {
            case "external-controller" where !value.isEmpty: controller = value.hasPrefix(":") ? "127.0.0.1" + value : value.replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1")
            case "secret" where !value.isEmpty: secret = value
            case "mixed-port", "port", "socks-port", "redir-port": if Int(value).map({ $0 > 0 }) == true { ports.append(value) }
            case "mode": mode = value.lowercased()
            default: break
            }
        }
        return (controller, secret, ports, mode, tun)
    }

    static func clash(_ yaml: String, into client: inout Client) {
        let settings = clashSettings(yaml)
        client.controller = settings.controller; client.secret = settings.secret; client.ports = settings.ports
        client.mode = settings.mode; client.tun = settings.tun
    }

    /// A Surge profile's `http-listen`, `socks5-listen` and `http-api` (key@host:port) lines; the newest profile wins.
    static func surge(_ folder: URL, into client: inout Client) {
        let profiles = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard let newest = profiles.filter({ $0.pathExtension == "conf" }).max(by: {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }), let text = try? String(contentsOf: newest, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "http-listen", "socks5-listen": if let port = parts[1].split(separator: ":").last { client.ports.append(String(port)) }
            case "http-api":
                let api = parts[1].split(separator: "@", maxSplits: 1)
                if api.count == 2 { client.secret = String(api[0]); client.controller = String(api[1]).replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1") }
            case "enhanced-mode-by-rule": client.tun = parts[1] == "true"
            default: break
            }
        }
    }

    // MARK: Carriers

    static let carrierNames = ["mihomo", "verge-mihomo", "verge-mihomo-alpha", "clash", "clash-meta", "ClashX", "ClashX Pro", "FlClashCore", "sing-box",
                               "Surge", "xray", "v2ray", "ss-local", "sslocal", "trojan", "trojan-go", "hysteria", "tuic-client", "tun2socks",
                               "tailscaled", "wireguard-go", "openvpn", "nordvpnd", "Stash", "Shadowrocket"]

    /// Proxy cores and VPN tunnel processes: whatever they send is other apps' traffic, already counted for those apps.
    static func carriers(_ processes: [(pid: Int32, path: String)]) -> [Carrier] {
        processes.compactMap { process in
            let name = (process.path as NSString).lastPathComponent
            if carrierNames.contains(name) { return Carrier(pid: process.pid, name: name, kind: VPNNames.contains(name) ? "vpn" : "proxy") }
            let lower = process.path.lowercased()
            let extensionHost = lower.contains(".systemextension/") || lower.contains(".appex/")
            // Packet tunnels, not every extension of a VPN app (settings, widgets, intents).
            if extensionHost && (lower.contains("tunnel") || lower.contains("network-extension") || lower.contains("networkextension")) {
                return Carrier(pid: process.pid, name: name, kind: "vpn")
            }
            return nil
        }
    }
    static let VPNNames: Set<String> = ["tailscaled", "wireguard-go", "openvpn", "nordvpnd"]
}

/// The proxy ports and carriers the traffic sampler uses, refreshed from `ProxyEnvironment` while Kilobat runs.
public final class ProxyRouting: @unchecked Sendable {
    public static let shared = ProxyRouting()
    private let lock = NSLock()
    private var ports: Set<String> = []
    private var carrierPIDs: Set<Int32> = []

    public func update(_ environment: ProxyEnvironment) {
        lock.lock(); defer { lock.unlock() }
        ports = environment.proxyPorts
        carrierPIDs = Set(environment.carriers.map(\.pid))
    }
    public func isProxyPort(_ port: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ports.contains(port) }
    public func isCarrier(_ pid: Int32) -> Bool { lock.lock(); defer { lock.unlock() }; return carrierPIDs.contains(pid) }
}
