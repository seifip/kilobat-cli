import Foundation
import Testing
@testable import KilobatCore

struct LeakTestTests {
    private let mullvad = ExitPath(interface: "utun4", connected: ["Mullvad"])

    /// Mullvad up, nothing leaking: DNS on the tunnel, IPv6 through it, UDP out as the exit.
    private func clean() -> LeakTest.Observations {
        var seen = LeakTest.Observations(exit: mullvad)
        seen.resolvers = [LeakTest.Resolver(servers: ["10.64.0.1"]), LeakTest.Resolver(servers: ["224.0.0.251"], domain: "local")]
        seen.resolverRoutes = ["10.64.0.1": "utun4"]
        seen.exitAddress = "198.51.100.7"
        seen.exitSeen = .init(address: "198.51.100.7", asn: "AS39351", org: "31173 Services AB", country: "se")
        seen.dnsSeen = [.init(address: "198.51.100.53", asn: "AS39351", org: "31173 Services AB", country: "se")]
        seen.ipv6Interface = "utun4"
        seen.physical = "en0"; seen.physicalPort = "Wi-Fi"
        seen.udpAsked = true; seen.udpDefault = "198.51.100.7:40211"
        return seen
    }
    private func status(_ result: LeakTest, _ id: String) -> LeakTest.Status? { result.checks.first { $0.id == id }?.status }

    @Test func cleanTunnelPasses() {
        let result = LeakTest.evaluate(clean())
        #expect(result.passed && result.checks.map(\.status) == [.pass, .pass, .pass])
        #expect(result.summary.hasPrefix("No leaks found"))
        #expect(result.services == ["bash.ws", "www.cloudflare.com", "stun.l.google.com", "stun.cloudflare.com"])
        // Cloudflare or Google answering through the tunnel is a choice, not a leak.
        var publicDNS = clean(); publicDNS.dnsSeen = [.init(address: "162.159.125.13", asn: "AS13335", org: "CloudFlare Inc", country: "fr")]
        #expect(status(LeakTest.evaluate(publicDNS), "dns") == .pass)
    }

    @Test func dnsLeaksThroughTheLocalRouterOrTheProvider() {
        var local = clean()
        local.resolvers = [LeakTest.Resolver(servers: ["192.168.1.1"], interface: "en0")]; local.resolverRoutes = ["192.168.1.1": "en0"]
        let routed = LeakTest.evaluate(local)
        #expect(status(routed, "dns") == .fail && routed.checks[0].detail.contains("192.168.1.1 over en0"))
        #expect(routed.checks[0].fix?.contains("Mullvad") == true)
        // Split DNS for a company domain only answers that domain.
        var split = clean(); split.resolvers.append(LeakTest.Resolver(servers: ["192.168.1.1"], domain: "corp.example")); split.resolverRoutes["192.168.1.1"] = "en0"
        #expect(status(LeakTest.evaluate(split), "dns") == .pass)
        var isp = clean(); isp.dnsSeen = [.init(address: "197.253.204.10", asn: "AS36925", org: "Meditelecom", country: "ma")]
        let provider = LeakTest.evaluate(isp)
        #expect(status(provider, "dns") == .fail && provider.checks[0].detail.contains("Meditelecom"))
        // Without bash.ws only the local check runs, and it says so.
        var offline = clean(); offline.dnsSeen = nil
        let unseen = LeakTest.evaluate(offline)
        #expect(status(unseen, "dns") == .pass && unseen.checks[0].detail.contains("bash.ws didn’t answer") && !unseen.services.contains("bash.ws"))
    }

    @Test func ipv6AroundTheTunnel() {
        var bare = clean(); bare.ipv6Interface = "en0"; bare.ipv6Address = "2001:db8::5"
        let leak = LeakTest.evaluate(bare)
        #expect(status(leak, "ipv6") == .fail && leak.checks[1].detail.contains("2001:db8::5") && leak.checks[1].detail.contains("198.51.100.7"))
        #expect(leak.checks[1].fix?.contains("In-tunnel IPv6") == true && leak.checks[1].fix?.contains("Network › Wi-Fi › Details › TCP/IP") == true)
        var unreachable = bare; unreachable.ipv6Address = nil
        #expect(status(LeakTest.evaluate(unreachable), "ipv6") == .warning)
        var none = clean(); none.ipv6Interface = nil
        #expect(status(LeakTest.evaluate(none), "ipv6") == .pass)
    }

    @Test func udpAroundTheTunnelOrOutAnotherWay() {
        var bare = clean(); bare.udpPhysical = "197.253.204.229:31204"
        let around = LeakTest.evaluate(bare)
        #expect(status(around, "udp") == .fail && around.checks[2].detail.contains("197.253.204.229") && around.checks[2].fix?.contains("Lockdown mode") == true)
        #expect(around.checks[2].fix?.contains("media.peerconnection.enabled") == true)
        var other = clean(); other.udpDefault = "203.0.113.9:5000"
        #expect(status(LeakTest.evaluate(other), "udp") == .fail)
        // A neighbouring address of the same provider isn't another way out.
        var neighbour = clean(); neighbour.udpDefault = "198.51.7.20:5000"
        #expect(status(LeakTest.evaluate(neighbour), "udp") == .pass)
        var silent = clean(); silent.udpDefault = nil
        #expect(status(LeakTest.evaluate(silent), "udp") == .skipped)
    }

    @Test func needsAVPNCarryingEverything() {
        let off = LeakTest.evaluate(LeakTest.Observations(exit: ExitPath(interface: "en0")))
        #expect(off.checks.allSatisfy { $0.status == .skipped } && off.passed && off.summary.contains("Connect your VPN"))
        let split = LeakTest.evaluate(LeakTest.Observations(exit: ExitPath(interface: "en0", connected: ["Tailscale"])))
        #expect(split.vpnState == "partial" && split.summary.contains("default route doesn’t use it"))
    }

    @Test func fixesNameEachAppsSetting() {
        #expect(VPNApp("NordVPN NordLynx").dnsFix.contains("Custom DNS"))
        #expect(VPNApp("Proton VPN").dnsFix.contains("10.2.0.1"))
        #expect(VPNApp("Tailscale").dnsFix.contains("Use Tailscale DNS settings"))
        #expect(VPNApp("Office WireGuard").ipv6Fix.contains("::/0"))
        #expect(VPNApp("Cisco Secure Client").dnsFix.contains("IT team"))
        #expect(VPNApp("GlobalProtect").ipv6Fix.contains("IT team"))
        #expect(VPNApp("ExpressVPN").ipv6Fix.contains("Prevent IPv6 address detection"))
        #expect(VPNApp(nil).udpFix.contains("kill switch"))
    }

    @Test func readsResolversServiceAndSTUN() throws {
        let scutil = """
        DNS configuration

        resolver #1
          nameserver[0] : 10.64.0.1
          if_index : 21 (utun4)
          flags    : Request A records

        resolver #2
          domain   : local
          options  : mdns

        resolver #3
          domain   : corp.example
          nameserver[0] : 192.168.1.1
          nameserver[1] : 192.168.1.2

        DNS configuration (for scoped queries)

        resolver #1
          nameserver[0] : 192.168.1.1
          if_index : 14 (en0)
          flags    : Scoped, Request A records
        """
        #expect(LeakTest.resolvers(scutil) == [LeakTest.Resolver(servers: ["10.64.0.1"], interface: "utun4"),
                                               LeakTest.Resolver(servers: ["192.168.1.1", "192.168.1.2"], domain: "corp.example")])
        // bash.ws's answer as it came on 31 October 2026.
        let answer = #"[{"ip":"197.253.204.229","country":"ma","country_name":"Morocco","asn":"AS36925 Meditelecom","org":"Meditelecom","type":"ip"},{"ip":"162.159.125.13","country":"fr","country_name":"France","asn":"AS13335 CloudFlare Inc","org":"CloudFlare Inc","type":"dns"},{"ip":"DNS may be leaking.","country":"","country_name":"","asn":"","org":"","type":"conclusion"}]"#
        let parsed = try #require(LeakTest.bashWS(Data(answer.utf8)))
        #expect(parsed.exit == .init(address: "197.253.204.229", asn: "AS36925", org: "Meditelecom", country: "ma"))
        #expect(parsed.dns == [.init(address: "162.159.125.13", asn: "AS13335", org: "CloudFlare Inc", country: "fr")])
        #expect(LeakTest.bashWS(Data("<html>".utf8)) == nil)
        // A Binding Success Response from stun.cloudflare.com, 31 October 2026, to transaction 01…0c.
        let transaction: [UInt8] = Array(1...12)
        #expect(LeakTest.stunRequest(transaction) == [0, 1, 0, 0, 0x21, 0x12, 0xA4, 0x42] + transaction)
        let response = hex("0101000c2112a4420102030405060708090a0b0c0020000800015bf6e4ef68a7")
        #expect(LeakTest.stunMapped(response, transaction: transaction) == "197.253.204.229:31460")
        #expect(LeakTest.stunMapped(response, transaction: Array(repeating: 9, count: 12)) == nil)
        // MAPPED-ADDRESS from an older server, unmasked.
        let plain = hex("0101000c2112a4420102030405060708090a0b0c0001000800011f90c0000207")
        #expect(LeakTest.stunMapped(plain, transaction: transaction) == "192.0.2.7:8080")
    }

    @Test func jsonCarriesEveryCheck() throws {
        let result = LeakTest.evaluate(clean(), date: Date(timeIntervalSince1970: 1_800_000_000))
        let value = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        #expect((value["checks"] as? [[String: Any]])?.map { $0["id"] as? String } == ["dns", "ipv6", "udp"] && value["vpnState"] as? String == "full")
        #expect(LeakTest.servicesNote.contains("bash.ws") && LeakTest.browserNote.contains("Brave"))
    }

    private func hex(_ text: String) -> [UInt8] {
        stride(from: 0, to: text.count, by: 2).map { UInt8(text.dropFirst($0).prefix(2), radix: 16)! }
    }
}
