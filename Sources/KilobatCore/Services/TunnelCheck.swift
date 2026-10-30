import Foundation

/// What can go wrong with a VPN or a proxy on a Mac, checked from routes, resolvers and the proxy settings:
/// DNS or IPv6 that skip the VPN, a system proxy nobody answers, a proxy and a VPN both taking traffic, a slow node.
/// Each finding says what was seen and what to try. Nothing is changed.
public struct TunnelCheck: Codable, Sendable, Equatable {
    public struct Finding: Codable, Sendable, Equatable, Identifiable {
        public enum Level: String, Codable, Sendable { case info, warning, problem }
        public let id: String
        public let level: Level
        public let title: String
        public let detail: String
    }

    public let date: Date
    /// The VPN carrying the default route, by name when macOS lists exactly one.
    public let vpn: String?
    public let vpnState: String
    /// The first resolver's address and the interface it's reached on, such as 172.20.10.1 on en0.
    public let dnsServer: String?
    public let dnsInterface: String?
    /// The interface IPv6 traffic leaves through, or nil without an IPv6 default route.
    public let ipv6Interface: String?
    public let proxy: ProxyEnvironment
    public let findings: [Finding]

    public static func run(exit: ExitPath? = nil, proxy: ProxyEnvironment? = nil, filterActive: Bool = false) async -> TunnelCheck {
        async let exitPath = exit == nil ? ExitPath.current() : exit!
        async let environment = proxy == nil ? ProxyEnvironment.current() : proxy!
        async let dns = CommandRunner.run("/usr/sbin/scutil", ["--dns"])
        async let v6 = CommandRunner.run("/sbin/route", ["-n", "get", "-inet6", "default"])
        let (path, env, dnsOutput, v6Output) = await (exitPath, environment, dns.output, v6.output)
        let resolver = firstResolver(dnsOutput)
        let ipv6 = v6Output.contains("interface:") ? DiagnosticProbe.matches("interface:\\s+([^\\s]+)", in: v6Output).first : nil
        var proxyNow = env
        await refreshClients(&proxyNow)
        return make(exit: path, proxy: proxyNow, dnsServer: resolver.server, dnsInterface: resolver.interface, ipv6Interface: ipv6, filterActive: filterActive)
    }

    /// Fills in each running client's live mode and TUN from its API, which can differ from its config file.
    static func refreshClients(_ environment: inout ProxyEnvironment) async {
        for index in environment.clients.indices where environment.clients[index].running {
            guard let api = ClashAPI(environment.clients[index]), let configs = try? await api.configs() else { continue }
            environment.clients[index].mode = configs.mode ?? environment.clients[index].mode
            environment.clients[index].tun = configs.tun ?? environment.clients[index].tun
            environment.clients[index].version = try? await api.version()
        }
    }

    public static func make(exit: ExitPath, proxy: ProxyEnvironment, dnsServer: String?, dnsInterface: String?, ipv6Interface: String?,
                            filterActive: Bool = false, date: Date = Date()) -> TunnelCheck {
        var findings: [Finding] = []
        let tunnel = exit.tunnel
        func physical(_ name: String?) -> Bool { name.map { $0.hasPrefix("en") } ?? false }
        if proxy.system.dead {
            let detail = (proxy.system.http ?? proxy.system.https ?? proxy.system.socks).map {
                String(localized: "macOS sends web traffic to a proxy at \($0), and nothing answers there, so browsers and most apps can’t connect. Open the proxy app again, or turn the proxy off in System Settings › Network › Details › Proxies.", comment: "A proxy address, such as 127.0.0.1:7890")
            } ?? String(localized: "macOS sends web traffic to a proxy on this Mac, and nothing answers there, so browsers and most apps can’t connect. Open the proxy app again, or turn the proxy off in System Settings › Network › Details › Proxies.")
            findings.append(Finding(id: "deadProxy", level: .problem, title: String(localized: "The system proxy isn’t running"), detail: detail))
        }
        let vpnName = exit.vpnName ?? String(localized: "the VPN", comment: "Stands in for a VPN’s name mid-sentence")
        if tunnel, physical(dnsInterface), let server = dnsServer, TrafficRoute.isPrivate(server) {
            findings.append(Finding(id: "dnsOutsideVPN", level: .warning, title: String(localized: "DNS skips the VPN"),
                                    detail: String(localized: "Traffic goes through \(vpnName), but name lookups go to \(server) on \(dnsInterface!), your local network. That network can see which sites you look up. Turn on the VPN app’s own DNS option, or its leak protection.", comment: "A VPN name, a DNS server address and an interface such as en0")))
        }
        if tunnel, physical(ipv6Interface) {
            findings.append(Finding(id: "ipv6OutsideVPN", level: .warning, title: String(localized: "IPv6 skips the VPN"),
                                    detail: String(localized: "IPv4 goes through \(vpnName), but IPv6 leaves through \(ipv6Interface!) directly, so sites reached over IPv6 see your real address. Turn on the VPN app’s IPv6 or leak protection, or turn IPv6 off for this network in System Settings.", comment: "A VPN name and an interface such as en0")))
        }
        let tunProxy = proxy.running.contains { $0.tun == true }
        let systemProxy = !proxy.system.localPorts.isEmpty && !proxy.system.dead
        if (tunProxy || systemProxy) && (tunnel || !exit.connected.isEmpty) {
            let which = proxy.running.first?.name ?? String(localized: "A proxy", comment: "Stands in for a proxy app’s name at the start of a sentence")
            findings.append(Finding(id: "proxyAndVPN", level: .warning, title: String(localized: "A proxy and a VPN both take traffic"),
                                    detail: String(localized: "\(which) and \(exit.vpnName ?? String(localized: "a VPN", comment: "Stands in for a VPN’s name mid-sentence")) are both on. Traffic may go through one, the other or both, and a rule in one can undo the other. If something fails only with both on, turn one off, or route the VPN’s addresses DIRECT in the proxy’s rules.", comment: "A proxy app’s name, such as Clash Verge, and a VPN’s name. DIRECT is the proxy rule’s keyword.")))
        }
        // macOS content filters never see connections to 127.0.0.1, only the proxy's own connection out.
        if filterActive && systemProxy && !tunProxy {
            let which = proxy.running.first?.name ?? String(localized: "the proxy", comment: "Stands in for a proxy app’s name mid-sentence")
            findings.append(Finding(id: "blockingBypassed", level: .warning, title: String(localized: "Blocking can’t see apps that use the proxy"),
                                    detail: String(localized: "Apps that follow the system proxy reach the Internet through \(which), so Kilobat’s filter sees only \(which)’s connection, not theirs. Turn on TUN mode in \(which) so the filter sees each app, or block the app in \(which)’s rules.", comment: "A proxy app’s name, such as Clash Verge, four times")))
        }
        for client in proxy.running where client.mode == "global" {
            findings.append(Finding(id: "globalMode-\(client.name)", level: .info, title: String(localized: "\(client.name) sends everything through one proxy", comment: "A proxy app’s name, such as Clash Verge, in global mode"),
                                    detail: String(localized: "Global mode ignores your rules, so local and domestic sites go through the proxy too. Switch back to rule mode if they feel slow.", comment: "Global and rule are a proxy app’s modes")))
        }
        if findings.isEmpty {
            let detail = tunnel ? String(localized: "DNS and IPv6 follow \(vpnName).", comment: "A VPN’s name") : !proxy.running.isEmpty ? String(localized: "The proxy answers, and no VPN competes with it.") : String(localized: "No VPN or proxy carries traffic.")
            findings.append(Finding(id: "ok", level: .info, title: String(localized: "No problems found"), detail: detail))
        }
        return TunnelCheck(date: date, vpn: exit.vpnName, vpnState: exit.vpn.rawValue, dnsServer: dnsServer, dnsInterface: dnsInterface,
                           ipv6Interface: ipv6Interface, proxy: proxy, findings: findings)
    }

    /// `scutil --dns`: resolver #1's first nameserver and the interface named on its if_index line.
    public static func firstResolver(_ output: String) -> (server: String?, interface: String?) {
        guard let start = output.range(of: "resolver #1") else { return (nil, nil) }
        let block = output[start.upperBound...].components(separatedBy: "resolver #").first ?? ""
        let server = DiagnosticProbe.matches("nameserver\\[0\\]\\s*:\\s*([^\\s]+)", in: block).first
        let interface = DiagnosticProbe.matches("if_index\\s*:\\s*\\d+\\s*\\(([^)]+)\\)", in: block).first
        return (server, interface)
    }
}
