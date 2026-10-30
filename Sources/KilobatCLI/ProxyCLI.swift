import Foundation
import KilobatCore

/// `kilobat proxy` and `kilobat vpn`: what proxy apps and VPNs do with this Mac's traffic. Read-only.
enum ProxyCLI {
    static let usage = "Use proxy [routes [--app <name>] | test] [--controller host:port] [--secret <secret>] [--json], or vpn [--json]."
    /// An API Kilobat didn't find on its own, such as a core started by hand.
    nonisolated(unsafe) static var manual: ClashAPI?

    static func run(_ args: [String]) async throws {
        var args = args
        if let index = args.firstIndex(of: "--controller") {
            guard index + 1 < args.count else { throw CLIError(usage) }
            var secret: String?
            if let s = args.firstIndex(of: "--secret"), s + 1 < args.count { secret = args[s + 1]; args.removeSubrange(s...(s + 1)) }
            let controllerIndex = args.firstIndex(of: "--controller")!
            manual = ClashAPI(controller: args[controllerIndex + 1], secret: secret)
            args.removeSubrange(controllerIndex...(controllerIndex + 1))
        }
        let json = args.contains("--json"), rest = args.filter { $0 != "--json" }
        if rest.first == "vpn" { try await vpn(json: json); return }
        switch rest.dropFirst().first {
        case nil: try await status(json: json)
        case "routes":
            var app: String?
            if let index = rest.firstIndex(of: "--app") {
                guard index + 1 < rest.count else { throw CLIError(usage) }
                app = rest[index + 1]
            }
            try await routes(app: app, json: json)
        case "test": try await test(json: json)
        default: throw CLIError(usage)
        }
    }

    // MARK: Status

    static func status(json: Bool) async throws {
        let check = await TunnelCheck.run()
        let env = check.proxy
        if json { print(String(decoding: try DiagnosticsCLI.encode(statusObject(check)), as: UTF8.self)); return }
        let system = env.system
        print(system.any ? "System proxy: " + [system.http.map { "HTTP \($0)" }, system.https.map { "HTTPS \($0)" }, system.socks.map { "SOCKS \($0)" }, system.pac.map { "PAC \($0)" }].compactMap { $0 }.joined(separator: " · ") + (system.dead ? "  (nothing answers there)" : "") : "System proxy: off")
        if env.clients.isEmpty { print("No proxy apps found.") }
        for client in env.clients {
            var parts = [client.running ? "running" : "not running"]
            if let mode = client.mode { parts.append(mode + " mode") }
            if let tun = client.tun { parts.append(tun ? "TUN on" : "TUN off") }
            if !client.ports.isEmpty { parts.append("ports " + client.ports.joined(separator: ", ")) }
            if let api = client.controller { parts.append("API " + api) }
            if let version = client.version { parts.append(version) }
            print("\(client.name): " + parts.joined(separator: " · "))
        }
        let carriers = env.carriers.map { "\($0.name) (\($0.kind))" }
        if !carriers.isEmpty { print("Carries other apps’ traffic: " + Array(Set(carriers)).sorted().joined(separator: ", ")) }
        print("")
        for finding in check.findings where finding.id != "ok" || check.findings.count == 1 { print("\(mark(finding.level)) \(finding.title). \(finding.detail)") }
    }

    struct StatusOutput: Encodable {
        let system: ProxyEnvironment.SystemProxy
        let clients: [ProxyEnvironment.Client]
        let carriers: [ProxyEnvironment.Carrier]
        let findings: [TunnelCheck.Finding]
    }
    static func statusObject(_ check: TunnelCheck) -> StatusOutput {
        StatusOutput(system: check.proxy.system, clients: check.proxy.clients, carriers: check.proxy.carriers, findings: check.findings)
    }

    static func mark(_ level: TunnelCheck.Finding.Level) -> String { level == .problem ? "✗" : level == .warning ? "!" : "✓" }

    // MARK: Routes

    /// The running clients that have an API Kilobat can read, with their live mode and TUN.
    static func apis() async throws -> [(client: ProxyEnvironment.Client, api: ClashAPI)] {
        if let manual {
            let ports = (try? await manual.ports()) ?? []
            return [(ProxyEnvironment.Client(name: "Proxy at " + manual.controller, running: true, controller: manual.controller, ports: ports), manual)]
        }
        let env = await ProxyEnvironment.current()
        let found = env.running.compactMap { client in ClashAPI(client).map { (client, $0) } }
        if found.isEmpty {
            throw CLIError(env.running.isEmpty ? "No proxy app is running." : "\(env.running.map(\.name).joined(separator: ", ")) runs, but Kilobat can’t find its API. Clash-based apps set it as external-controller in their config.")
        }
        return found
    }

    static func makeRoutes(app filter: String? = nil) async throws -> [ProxyRoute] {
        var all: [ProxyRoute] = []
        for (client, api) in try await apis() {
            let connections = try await api.connections()
            let lsof = await CommandRunner.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:ESTABLISHED"], timeout: 6)
            let owners = ProxyRoute.owners(lsof.output, proxyPorts: Set(client.ports))
            all += ProxyRoute.routes(connections, owners: owners)
        }
        if let filter { all = all.filter { $0.app.localizedCaseInsensitiveContains(filter) } }
        return all
    }

    static func routes(app: String?, json: Bool) async throws {
        let routes = try await makeRoutes(app: app)
        if json { print(String(decoding: try DiagnosticsCLI.encode(routes), as: UTF8.self)); return }
        guard !routes.isEmpty else { print(app == nil ? "No connections go through the proxy right now." : "No connections from \(app!) go through the proxy right now."); return }
        for (name, list) in Dictionary(grouping: routes, by: \.app).sorted(by: { $0.key < $1.key }) {
            print(name)
            for route in list.sorted(by: { $0.download + $0.upload > $1.download + $1.upload }).prefix(12) {
                let via = route.node == "DIRECT" ? "Direct" : route.node.hasPrefix("REJECT") ? "Blocked" : route.node + (route.group.map { " (\($0))" } ?? "")
                print("  \(KilobatCLI.pad(route.host, 34)) \(KilobatCLI.pad(via, 26)) \(route.rule)")
            }
        }
    }

    // MARK: Node test

    struct NodeDelay: Encodable { let client: String; let group: String; let node: String; let delayMs: Int? }

    static func test(json: Bool) async throws {
        var results: [NodeDelay] = []
        for (client, api) in try await apis() {
            for group in try await api.groups() {
                guard let node = group.now else { continue }
                results.append(NodeDelay(client: client.name, group: group.name, node: node, delayMs: await api.delay(node)))
            }
        }
        if json { print(String(decoding: try DiagnosticsCLI.encode(results), as: UTF8.self)); return }
        guard !results.isEmpty else { print("No proxy groups to test."); return }
        for result in results {
            print("\(KilobatCLI.pad(result.group, 22)) \(KilobatCLI.pad(result.node, 28)) \(result.delayMs.map { "\($0) ms" } ?? "no answer")")
        }
    }

    // MARK: VPN

    static func vpn(json: Bool) async throws {
        let check = await TunnelCheck.run()
        if json { print(String(decoding: try DiagnosticsCLI.encode(check), as: UTF8.self)); return }
        print("VPN: \(check.vpnState)" + (check.vpn.map { " · \($0)" } ?? ""))
        print("DNS: \(check.dnsServer ?? "unknown")" + (check.dnsInterface.map { " on \($0)" } ?? ""))
        print("IPv6: " + (check.ipv6Interface.map { "leaves through \($0)" } ?? "no IPv6 route"))
        print("")
        for finding in check.findings { print("\(mark(finding.level)) \(finding.title). \(finding.detail)") }
    }
}
