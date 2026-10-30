import Foundation
import Testing
@testable import KilobatCore

struct ProxyTests {
    @Test func readsTheSystemProxy() {
        let output = """
        <dictionary> {
          HTTPEnable : 1
          HTTPPort : 7897
          HTTPProxy : 127.0.0.1
          HTTPSEnable : 1
          HTTPSPort : 7897
          HTTPSProxy : 127.0.0.1
          SOCKSEnable : 0
        }
        """
        let proxy = ProxyEnvironment.systemProxy(output)
        #expect(proxy.http == "127.0.0.1:7897")
        #expect(proxy.socks == nil)
        #expect(proxy.localPorts == ["7897", "7897"])
        #expect(ProxyEnvironment.systemProxy("<dictionary> {\n  FTPPassive : 1\n}").any == false)
    }

    @Test func readsWhereAClashCoreListens() {
        let yaml = """
        mixed-port: 7897
        socks-port: 7898
        port: 0
        mode: Rule
        external-controller: 127.0.0.1:9097
        secret: "s3cret"
        tun:
          enable: true
          stack: system
        dns:
          enable: false
        """
        let settings = ProxyEnvironment.clashSettings(yaml)
        #expect(settings.controller == "127.0.0.1:9097")
        #expect(settings.secret == "s3cret")
        #expect(settings.ports == ["7897", "7898"])
        #expect(settings.mode == "rule")
        #expect(settings.tun == true)
        #expect(ProxyEnvironment.clashSettings("external-controller: :9090").controller == "127.0.0.1:9090")
    }

    @Test func neverReturnsTheSecret() throws {
        let client = ProxyEnvironment.Client(name: "Clash Verge", running: true, controller: "127.0.0.1:9097", secret: "s3cret", ports: ["7897"])
        let json = String(decoding: try JSONEncoder().encode(client), as: UTF8.self)
        #expect(!json.contains("s3cret"))
        #expect(json.contains("9097"))
    }

    @Test func findsProxyCoresAndTunnelsButNotOtherExtensions() {
        let processes: [(pid: Int32, path: String)] = [
            (10, "/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo"),
            (11, "/Library/SystemExtensions/ABC/io.tailscale.ipn.macsys.network-extension.systemextension/Contents/MacOS/io.tailscale.ipn.macsys.network-extension"),
            (12, "/Applications/NordVPN.app/Contents/PlugIns/VpnSettingsIntents.appex/Contents/MacOS/VpnSettingsIntents"),
            (13, "/Applications/Safari.app/Contents/MacOS/Safari"),
        ]
        let carriers = ProxyEnvironment.carriers(processes)
        #expect(carriers.map(\.pid) == [10, 11])
        #expect(carriers.first?.kind == "proxy")
        #expect(carriers.last?.kind == "vpn")
    }

    @Test func trafficToALocalProxyIsTheAppsInternetTraffic() {
        let environment = ProxyEnvironment(date: Date(), system: ProxyEnvironment.SystemProxy(http: "127.0.0.1:17897"), clients: [], carriers: [])
        ProxyRouting.shared.update(environment)
        defer { ProxyRouting.shared.update(ProxyEnvironment(date: Date(), system: .init(), clients: [], carriers: [])) }
        #expect(TrafficRoute.route(address: "127.0.0.1", port: "17897", localPort: "50000", interface: "lo0") == .internet)
        #expect(TrafficRoute.route(address: "127.0.0.1", port: "631", localPort: "50001", interface: "lo0") == .local)
    }

    @Test func matchesSystemProxyConnectionsToAppsBySourcePort() throws {
        let lsof = """
        COMMAND     PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        Telegram   4242 seifip   31u  IPv4 0x1234      0t0  TCP 127.0.0.1:56759->127.0.0.1:7897 (ESTABLISHED)
        verge-mih  5000 seifip   12u  IPv4 0x5678      0t0  TCP 127.0.0.1:7897->127.0.0.1:56759 (ESTABLISHED)
        """
        let owners = ProxyRoute.owners(lsof, proxyPorts: ["7897"])
        #expect(owners["56759"]?.pid == 4242)
        #expect(owners["7897"] == nil)
        let data = Data("""
        {"connections":[{"metadata":{"host":"telegram.org","sourcePort":"56759","processPath":"","remoteDestination":"149.154.167.99"},
         "upload":100,"download":2000,"chains":["HK-01","Proxy"],"rule":"DomainSuffix","rulePayload":"telegram.org"},
        {"metadata":{"host":"apple.com","sourcePort":"1","processPath":"/Applications/Safari.app/Contents/MacOS/Safari"},"chains":["DIRECT"],"rule":"Match","rulePayload":""}]}
        """.utf8)
        let routes = ProxyRoute.routes(try ClashAPI.connections(data), owners: owners, name: { ProxyRoute.appName(path: $0) })
        #expect(routes.first?.node == "HK-01")
        #expect(routes.first?.group == "Proxy")
        #expect(routes.first?.rule == "DomainSuffix,telegram.org")
        #expect(routes.last?.app == "Safari")
        #expect(routes.last?.node == "DIRECT")
        #expect(ProxyRoute.appName(path: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper") == "Claude")
    }

    private let fullVPN = ExitPath(interface: "utun4", tunnel: true, connected: ["NordVPN"])

    @Test func catchesDNSAndIPv6ThatSkipTheVPN() {
        let none = ProxyEnvironment(date: Date(), system: .init(), clients: [], carriers: [])
        let check = TunnelCheck.make(exit: fullVPN, proxy: none, dnsServer: "192.168.1.1", dnsInterface: "en0", ipv6Interface: "en0")
        #expect(check.findings.map(\.id) == ["dnsOutsideVPN", "ipv6OutsideVPN"])
        let clean = TunnelCheck.make(exit: fullVPN, proxy: none, dnsServer: "10.8.0.1", dnsInterface: "utun4", ipv6Interface: "utun4")
        #expect(clean.findings.map(\.id) == ["ok"])
    }

    @Test func flagsADeadProxyAConflictAndHiddenApps() {
        var system = ProxyEnvironment.SystemProxy(http: "127.0.0.1:7897"); system.dead = true
        let dead = TunnelCheck.make(exit: ExitPath(interface: "en0"), proxy: ProxyEnvironment(date: Date(), system: system, clients: [], carriers: []),
                                    dnsServer: nil, dnsInterface: nil, ipv6Interface: nil)
        #expect(dead.findings.first?.id == "deadProxy")
        let clash = ProxyEnvironment.Client(name: "Clash Verge", running: true, ports: ["7897"], mode: "global", tun: false)
        let live = ProxyEnvironment(date: Date(), system: .init(http: "127.0.0.1:7897"), clients: [clash], carriers: [])
        let both = TunnelCheck.make(exit: fullVPN, proxy: live, dnsServer: nil, dnsInterface: nil, ipv6Interface: nil, filterActive: true)
        #expect(both.findings.map(\.id) == ["proxyAndVPN", "blockingBypassed", "globalMode-Clash Verge"])
    }

    @Test func readsTheFirstResolver() {
        let output = "DNS configuration\n\nresolver #1\n  nameserver[0] : 172.20.10.1\n  if_index : 11 (en0)\n\nresolver #2\n  domain   : local\n"
        let resolver = TunnelCheck.firstResolver(output)
        #expect(resolver.server == "172.20.10.1")
        #expect(resolver.interface == "en0")
    }
}
