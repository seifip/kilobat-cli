import Testing
import Foundation
@testable import KilobatCore

/// Fixtures shaped like this Mac's own readings on macOS 27.2 (November 2026), with made-up products and accounts.
enum PathSoftwareFixtures {
    /// A keyed archive laid out like /Library/Preferences/com.apple.networkextension.plist: NEConfiguration objects for
    /// TripMode's and Kilobat's filters, Tailscale's VPN, NextDNS's encrypted DNS (off) and Little Snitch's DNS proxy,
    /// plus Apple's application firewall and Local Network privacy rules. Filter providers carry a vendor configuration
    /// and a user name, which must never be read. Made by a script with Python's plistlib.
    static let configurations = Data(base64Encoded: "YnBsaXN0MDDUAAEAAgADAAQABQAGAP4BEFkkYXJjaGl2ZXJYJG9iamVjdHNUJHRvcFgkdmVyc2lvbl8QD05TS2V5ZWRBcmNoaXZlcq8QOgAHAAgADgARABQAFwAbAB4AIQAiACMAMAA3ADgAOQA6ADsAIQAiAGEAZQBnAGgAaQBqAGsAfQCBAIIAgwCBAIQAlgCXAJ0AoQCiAKMApAC2ALcAuAC5ALoAuwAhACIAzQDRANMA1ADVANUA1gDoAOoA6wDsVSRudWxs0gAJAAoACwAMWCRjbGFzc2VzWiRjbGFzc25hbWWiAAwADV8QD05FQ29uZmlndXJhdGlvblhOU09iamVjdNIACQAKAA8AEKIAEAANXxAPTkVDb250ZW50RmlsdGVy0gAJAAoAEgATogATAA1VTkVWUE7SAAkACgAVABaiABYADV8QE05FRE5TU2V0dGluZ3NCdW5kbGXSAAkACgAYABmjABkAGgANXxAWTkVETlNPdmVySFRUUFNTZXR0aW5nc11ORUROU1NldHRpbmdz0gAJAAoAHAAdogAdAA1fEB1ORUZpbHRlclByb3ZpZGVyQ29uZmlndXJhdGlvbtIACQAKAB8AIKIAIAANXxAQTkVQYXRoQ29udHJvbGxlclxTRUNSRVQtUlVMRVNfEBNzb21lb25lQGV4YW1wbGUuY29t1gAkACUAJgAnACgAKQAqACsALAAtAC4AL1YkY2xhc3NdRmlsdGVyUGFja2V0c11GaWx0ZXJTb2NrZXRzWFBhc3N3b3JkWFVzZXJuYW1lXxATVmVuZG9yQ29uZmlndXJhdGlvboAGCAmAAIAJgAjUACQAMQAyADMANAAsADUANldFbmFibGVkW0ZpbHRlckdyYWRlWFByb3ZpZGVygAIQAYAKXxAPVHJpcE1vZGUgZmlsdGVyXxAkOWVhMTYyMzMtYWY5Yi00Yjg4LThjYjAtZTBmOTU5OGNlY2QxXxAUY2gudHJpcG1vZGUuVHJpcE1vZGVYVHJpcE1vZGXfEBQAJAA8AD0APgA/AEAAQQBCAEMARABFAEYARwBIAEkASgBLAEwATQBOAE8AUABRAFIAUwBUAFUAVgBXAFgANQBZAFoAKwBbAFwAXQBeAF8AYFtBbHdheXNPblZQTldBcHBQdXNoVkFwcFZQTltBcHBsaWNhdGlvbl8QD0FwcGxp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EAwSAAGGoAAIABkAIwAsADEAOgBMAMMAyQDSANsA5gDrAP0BBgEPARQBJgEvATQBOgFDAUgBXgFnAW4BhwGVAZ4BowHDAcwB0QHkAfECBwIgAicCNQJDAkwCVQJrAm0CbgJvAnECcwJ1AoYCjgKaAqMCpQKnAqkCuwLiAvkDAgNVA2EDaQNwA3wDjgOcA6UDsQPMA9ID2gPlA/gD/QQMBBgEHgQoBCwELgQwBDIENAQ2BDgEOgQ8BD4EQARCBEQERgRIBEoETAROBFAEaQRrBG0EbwSABIIEnQTEBNcE3wUyBTQFNgU4BToFPAU+BUAFQgVEBUYFSAVKBUwFTgVQBVIFVAVlBXcFggWEBY4FtQXPBiIGJAYmBigGKgYsBi4GMAYyBjQGNgY4BjoGPAY+BkAGQgZEBmQGcQZ7BoMGhQaHBokGlgafBqEGowarBtIG5wc6BzwHPgdAB0IHRAdGB0gHSgdMB04HUAdSB1QHVgdYB1oHXAdlB3kHoAe4B8YIGQgbCB0IHwghCCMIJQgnCCkIKwgtCC8IMQgzCDUINwg5CDsIVAhWCFgIWghrCG0ImgjBCOUJOAk6CTwJPglACUIJRAlGCUgJSglMCU4JUAlSCVQJVglYCVoJYwllCZUJvAoPChEKEwoVChcKGQobCh0KHwohCiMKJQonCikKKwotCi8KMQpWClkKXApfCmIKZQpoCmsKdgp+CoAKggqECoYKiAqKCowKjgAAAAAAAAICAAAAAAAAAREAAAAAAAAAAAAAAAAAAAqT")!

    /// `systemextensionsctl list` on macOS 27.2, with an endpoint security section and an extension being replaced.
    static let extensions = """
    5 extension(s)
    --- com.apple.system_extension.network_extension (Go to 'System Settings > General > Login Items & Extensions > Network Extensions' to modify these system extension(s))
    enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
    *\t*\tHAR874R67J\tco.seifi.kilobat.filter (1.40.11/197)\tKilobat Network Filter\t[activated enabled]
    *\t*\tW5364U7YZB\tio.tailscale.ipn.macsys.network-extension (1.92.3/101.92.3)\tTailscale Network Extension\t[activated enabled]
    *\t*\t78UFGP42EU\tch.tripmode.TripMode.FilterExtension (3.2.0/1385)\tFilterExtension\t[activated enabled]
    \t\tMLZF7K7B5R\tat.obdev.littlesnitch.networkextension (6.0/6000)\tLittle Snitch Network Extension\t[terminated waiting to uninstall on reboot]
    --- com.apple.system_extension.endpoint_security
    enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
    *\t*\tX9E956P446\tcom.crowdstrike.falcon.Agent (7.20/20104)\tFalcon Sensor\t[activated enabled]
    """

    /// `scutil --dns` with Tailscale connected without an exit node: its resolver for the tailnet and its reverse zone.
    static let tailscaleDNS = """
    DNS configuration

    resolver #1
      search domain[0] : lan
      nameserver[0] : 192.168.1.1
      if_index : 11 (en0)
      flags    : Request A records
      reach    : 0x00020002 (Reachable,Directly Reachable Address)

    resolver #2
      domain   : local
      options  : mdns
      timeout  : 5
      flags    : Request A records
      reach    : 0x00000000 (Not Reachable)
      order    : 300000

    resolver #3
      domain   : tail1234.ts.net
      nameserver[0] : 100.100.100.100
      if_index : 23 (utun4)
      flags    : Supplemental, Request A records, Request AAAA records
      reach    : 0x00000003 (Reachable,Transient Connection)
      order    : 102400

    resolver #4
      domain   : 100.100.in-addr.arpa
      nameserver[0] : 100.100.100.100
      if_index : 23 (utun4)
      flags    : Supplemental, Request A records, Request AAAA records
      reach    : 0x00000003 (Reachable,Transient Connection)
      order    : 102401

    DNS configuration (for scoped queries)

    resolver #1
      search domain[0] : lan
      nameserver[0] : 192.168.1.1
      if_index : 11 (en0)
      flags    : Scoped, Request A records
      reach    : 0x00020002 (Reachable,Directly Reachable Address)
    """

    /// `nettop -L 1 -n -x -J bytes_in,bytes_out`: Safari with a QUIC connection to a Relay entry address, written
    /// uncompressed differently from the resolver's answer, and networkserviceproxy talking to another Apple address.
    static let nettopRelay = """
    ,bytes_in,bytes_out,
    Safari.812,48211,9921,
    udp6 2001:db8:1::5.61234<->2403:300:a41:9:0:0:0:b.443,48211,9921,
    networkservicep.845,5873,9395,
    udp4 192.168.33.162:55882<->17.248.225.14:443,5873,9395,
    """
}

struct PathSoftwareTests {
    @Test func readsConfigurationsAndSkipsApplesOwnAndPrivateFields() throws {
        let found = PathSoftware.configurations(PathSoftwareFixtures.configurations)
        #expect(found.count == 5)
        #expect(found.contains { $0.application == "ch.tripmode.TripMode" && $0.kind == .contentFilter && $0.enabled == true && $0.applicationName == "TripMode" })
        #expect(found.contains { $0.application == "co.seifi.kilobat" && $0.kind == .contentFilter })
        #expect(found.contains { $0.application == "io.tailscale.ipn.macsys" && $0.kind == .vpn && $0.name == "Tailscale" })
        #expect(found.contains { $0.application == "io.nextdns.NextDNS" && $0.kind == .encryptedDNS && $0.enabled == false && $0.server == "https://dns.nextdns.io/abc123" })
        #expect(found.contains { $0.application == "at.obdev.littlesnitch" && $0.kind == .dnsProxy && $0.enabled == true })
        #expect(!found.contains { $0.application?.hasPrefix("com.apple.") == true || $0.name.hasPrefix("com.apple.") })
        let text = "\(found)"
        #expect(!text.contains("SECRET") && !text.contains("someone@example.com"))
        #expect(PathSoftware.configurations(Data("not a plist".utf8)).isEmpty)
    }

    @Test func readsActivatedSystemExtensionsByCategory() {
        let found = PathSoftware.systemExtensions(PathSoftwareFixtures.extensions)
        #expect(found.map(\.bundleID) == ["co.seifi.kilobat.filter", "io.tailscale.ipn.macsys.network-extension", "ch.tripmode.TripMode.FilterExtension", "com.crowdstrike.falcon.Agent"])
        #expect(found.last?.category == .endpointSecurity && found.last?.teamID == "X9E956P446")
        #expect(found.allSatisfy { $0.enabled && $0.active })
    }

    @Test func mergesOneListWithKilobatNamedAndVPNsByConnection() {
        let items = PathSoftware.merge(configurations: PathSoftware.configurations(PathSoftwareFixtures.configurations),
                                       extensions: PathSoftware.systemExtensions(PathSoftwareFixtures.extensions),
                                       connected: ["Tailscale"], processes: "launchd\nfalcond\nvpnagentd\nSafari\n")
        // Extensions covered by a configuration aren't listed twice; CrowdStrike's extension and its daemon count once.
        #expect(items.filter { $0.name == "TripMode" }.count == 1)
        #expect(items.filter { $0.name == "CrowdStrike Falcon" }.count == 1)
        #expect(items.first { $0.name == "CrowdStrike Falcon" }?.kind == .securityAgent)
        #expect(items.contains { $0.name == "Cisco Secure Client" && $0.source == .process })
        #expect(items.first { $0.kind == .vpn }?.on == true)
        let own = items.first(where: \.kilobat)
        #expect(own?.name == "Kilobat" && own?.kind == .contentFilter)
        let disconnected = PathSoftware.merge(configurations: PathSoftware.configurations(PathSoftwareFixtures.configurations), extensions: [], connected: [], processes: "")
        #expect(disconnected.first { $0.kind == .vpn }?.on == false)
    }

    @Test func suspectsPutOtherProductsFirstAndKilobatLast() {
        let software = PathSoftware(items: PathSoftware.merge(configurations: PathSoftware.configurations(PathSoftwareFixtures.configurations),
                                                              extensions: [], connected: ["Tailscale"], processes: ""))
        let suspects = software.filterSuspects
        #expect(suspects.map(\.name) == ["TripMode", "Little Snitch", "Kilobat"])
        #expect(!suspects.contains { $0.kind == .vpn })
        #expect(software.suspects.contains { $0.kind == .vpn })
        // Encrypted DNS that's off is listed but never a suspect.
        #expect(!software.suspects.contains { $0.kind == .encryptedDNS })
        #expect(software.others.map(\.name) == ["TripMode", "Little Snitch"])
    }

    @Test func failureAdviceNamesASuspectAndATestNeverAVerdict() throws {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        var software = PathSoftware(items: [
            PathItem(kind: .contentFilter, name: "Kilobat", bundleID: "co.seifi.kilobat", on: true, kilobat: true, source: .configuration),
            PathItem(kind: .contentFilter, name: "TripMode", bundleID: "ch.tripmode.TripMode", on: true, source: .configuration),
        ], macOSVersion: "27.2", macOSUpdated: now.addingTimeInterval(-3 * 86400))
        let advice = try #require(software.failureAdvice(now: now, major: 27))
        #expect(advice.detail.hasPrefix("TripMode’s filter and Kilobat’s filter also handle"))
        #expect(advice.detail.contains("macOS was updated to 27.2"))
        #expect(advice.test.contains("turn off TripMode in System Settings › Network › Filters"))
        #expect(advice.test.contains("To rule out Kilobat"))
        // Weeks later the update isn't news.
        #expect(software.failureAdvice(now: now.addingTimeInterval(30 * 86400), major: 27)?.detail.contains("updated") == false)
        // Kilobat alone is still named honestly.
        software.items.removeLast()
        #expect(software.failureAdvice(now: now, major: 27)?.detail.hasPrefix("Kilobat’s filter also handles") == true)
        software.items = []
        #expect(software.failureAdvice(now: now) == nil)
        #expect(PathSoftware.filtersPane(major: 14).contains("VPN & Filters"))
        #expect(PathSoftware.test(for: PathItem(kind: .securityAgent, name: "Zscaler", bundleID: nil, on: true, source: .process)).contains("Ask whoever manages it"))
    }

    @Test func readsTheLatestMacOSInstall() throws {
        let entries: [[String: Any]] = [
            ["date": Date(timeIntervalSince1970: 1_790_000_000), "displayName": "macOS 27.1", "displayVersion": "27.1", "processName": "softwareupdated"],
            ["date": Date(timeIntervalSince1970: 1_791_000_000), "displayName": "RosettaUpdateAuto", "displayVersion": " ", "processName": "softwareupdated"],
            ["date": Date(timeIntervalSince1970: 1_792_000_000), "displayName": "macOS 27.2", "displayVersion": "27.2", "processName": "softwareupdated"],
            ["date": Date(timeIntervalSince1970: 1_792_500_000), "displayName": "XProtectPlistConfigData", "displayVersion": "5330", "processName": "softwareupdated"],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0)
        let found = try #require(PathSoftware.lastMacOSInstall(data))
        #expect(found.version == "27.2" && found.date == Date(timeIntervalSince1970: 1_792_000_000))
    }

    private func failing(at layer: String) -> DoctorReport {
        DoctorReport(target: "example.com", host: "example.com", app: nil, verdict: "The server can’t be reached.", next: "Try another network.",
                     steps: [DoctorStep(layer: "Network", status: .ok, detail: "Online."), DoctorStep(layer: layer, status: .failed, detail: "x")], date: Date())
    }

    @Test func doctorAddsSuspectsOnlyWhereSoftwareCouldBeTheCause() {
        let software = PathSoftware(items: [PathItem(kind: .contentFilter, name: "TripMode", bundleID: "ch.tripmode.TripMode", on: true, source: .configuration)])
        let dns = ConnectionDoctor.withSoftware(failing(at: "IPv4"), software)
        #expect(dns.steps.last?.layer == "Network software" && dns.steps.last?.status == .warning)
        #expect(dns.verdict == "The server can’t be reached.")
        #expect(dns.next.hasPrefix("Try another network. To test it, turn off TripMode"))
        #expect(dns.software == software)
        // Kilobat's own rules, a server's own error or a passing check: listed in the JSON, no step.
        for layer in ["Kilobat rules", "Server", "Provider"] {
            let other = ConnectionDoctor.withSoftware(failing(at: layer), software)
            #expect(!other.steps.contains { $0.layer == "Network software" } && other.software != nil)
        }
        var passing = failing(at: "IPv4"); passing.steps.removeLast()
        #expect(!ConnectionDoctor.withSoftware(passing, software).steps.contains { $0.layer == "Network software" })
        #expect(!ConnectionDoctor.withSoftware(failing(at: "DNS"), PathSoftware(items: [])).steps.contains { $0.layer == "Network software" })
        // A refusal is the server's answer, and a Local Network block already explains it.
        var refused = failing(at: "IPv4"); refused.steps[1] = DoctorStep(layer: "IPv4", status: .failed, detail: "192.168.1.1 refused the connection on port 80.")
        #expect(!ConnectionDoctor.withSoftware(refused, software).steps.contains { $0.layer == "Network software" })
        var local = failing(at: "Secure connection"); local.steps.insert(DoctorStep(layer: "Local Network", status: .warning, detail: "x"), at: 1)
        #expect(!ConnectionDoctor.withSoftware(local, software).steps.contains { $0.layer == "Network software" })
    }

    private func snapshot(internet: String, dns: String) throws -> DiagnosticSnapshot {
        let json = #"{"date":0,"radio":{"interface":"en0","ssid":"Example Home","rssi":-52,"noise":-93,"transmitMbps":866,"channel":149,"band":"5 GHz"},"gateway":"192.168.1.1","router":{"host":"192.168.1.1","samples":[3,4,3],"lossPercent":0},"internet":{"host":"1.1.1.1","samples":"# + internet + #","lossPercent":0}"# + dns + #","dnsServers":["192.168.1.1"],"networkService":"Wi-Fi"}"#
        return try JSONDecoder().decode(DiagnosticSnapshot.self, from: Data(json.utf8))
    }

    @Test func healthNamesSuspectsWhenConnectedWithoutInternetOrSoonAfterAnUpdate() throws {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let items = [PathItem(kind: .contentFilter, name: "Little Snitch", bundleID: "at.obdev.littlesnitch", on: true, source: .configuration),
                     PathItem(kind: .contentFilter, name: "Kilobat", bundleID: "co.seifi.kilobat", on: true, kilobat: true, source: .configuration)]
        let old = PathSoftware(items: items, macOSVersion: "27.1", macOSUpdated: now.addingTimeInterval(-60 * 86400))
        let offline = try snapshot(internet: "[]", dns: "")
        let found = try #require(old.healthFinding(offline, now: now, major: 27))
        #expect(found.title == "Check other network software" && found.problem)
        #expect(found.detail == "Little Snitch’s filter and Kilobat’s filter also handle this Mac’s traffic. To test it, turn off Little Snitch in System Settings › Network › Filters, check again, then turn it back on.")
        #expect(found.advice.contains("To rule out Kilobat"))
        // A good line gets nothing, even right after an update; a struggling one soon after an update does.
        let good = try snapshot(internet: "[18,20,19]", dns: #","dnsMilliseconds":12"#)
        let fresh = PathSoftware(items: items, macOSVersion: "27.2", macOSUpdated: now.addingTimeInterval(-86400))
        #expect(fresh.healthFinding(good, now: now) == nil && old.healthFinding(good, now: now) == nil)
        let laggy = try snapshot(internet: "[180,420,260]", dns: #","dnsMilliseconds":420"#)
        #expect(laggy.health != .good)
        #expect(fresh.healthFinding(laggy, now: now, major: 27)?.detail.hasPrefix("macOS was updated to 27.2") == true)
        #expect(old.healthFinding(laggy, now: now) == nil)
        #expect(PathSoftware(items: []).healthFinding(offline, now: now) == nil)
    }

    @Test func fixItNotesOtherSoftwareBeforeBlamingSomeoneElse() {
        let software = PathSoftware(items: [PathItem(kind: .dnsProxy, name: "AdGuard", bundleID: "com.adguard.mac.adguard", on: true, source: .configuration),
                                            PathItem(kind: .contentFilter, name: "Kilobat", bundleID: "co.seifi.kilobat", on: true, kilobat: true, source: .configuration)])
        #expect(software.fixItNote(.provider, major: 27) == "Before calling anyone: AdGuard’s DNS proxy also handles this Mac’s traffic. To test it, turn off AdGuard in System Settings › Network › Filters, check again, then turn it back on.")
        #expect(software.fixItNote(.farNode(better: nil)) == nil)
        // Kilobat alone isn't "someone else": Fix it already ran with it on.
        #expect(PathSoftware(items: [software.items[1]]).fixItNote(.provider) == nil)
    }
}

struct DNSPathTests {
    @Test func readsDefaultAndPerDomainResolvers() {
        let found = DNSPath.resolvers(PathSoftwareFixtures.tailscaleDNS)
        #expect(found.defaults == ["192.168.1.1"])
        #expect(found.scoped == [DNSPath.Scoped(domain: "tail1234.ts.net", servers: ["100.100.100.100"], interface: "utun4")])
    }

    @Test func relayIsOnlyWhatConnectionsShow() {
        let entry: Set<String> = ["2403:300:a41:9::b", "2403:300:1363:1::8"]
        let seen = DNSPath.relay(nettop: PathSoftwareFixtures.nettopRelay, relayAddresses: entry, dnsWorks: true)
        #expect(seen.0 == .seen && seen.1 == ["Safari"])
        #expect(DNSPath.relay(nettop: PathSoftwareFixtures.nettopRelay, relayAddresses: ["2403:300:1363:1::8"], dnsWorks: true).0 == .notSeen)
        // No address for Relay's names while other lookups work is the network's way of turning it off; offline is unknown.
        #expect(DNSPath.relay(nettop: "", relayAddresses: [], dnsWorks: true).0 == .blockedByDNS)
        #expect(DNSPath.relay(nettop: "", relayAddresses: [], dnsWorks: false).0 == .unknown)
        #expect(DNSPath.usable(["0.0.0.0", "::", "17.1.2.3"]) == ["17.1.2.3"])
    }
}

struct LocalNetworkCheckTests {
    @Test func localAddressesFollowTheTechnote() {
        for address in ["192.168.1.20", "10.0.0.5", "172.20.1.1", "169.254.3.4", "fe80::1%en0", "fd7a:115c:a1e0::1", "224.0.0.251"] { #expect(LocalNetworkCheck.isLocal(address), "\(address)") }
        for address in ["100.101.102.103", "127.0.0.1", "::1", "8.8.8.8", "2606:4700::1111", "172.32.0.1", "printer.local"] { #expect(!LocalNetworkCheck.isLocal(address), "\(address)") }
    }

    @Test func recognisesNoRouteToHostAsAppsWriteIt() {
        for error in ["curl: (7) Failed to connect to 192.168.1.20 port 8080 after 2 ms: No route to host", "Error: connect EHOSTUNREACH 192.168.1.20:5432",
                      "OSError: [Errno 65] No route to host", "dial tcp 192.168.1.20:22: connect: no route to host", "Error Domain=NSPOSIXErrorDomain Code=65"] {
            #expect(LocalNetworkCheck.saysNoRoute(error), "\(error)")
        }
        #expect(!LocalNetworkCheck.saysNoRoute("connect ETIMEDOUT 192.168.1.20:5432"))
        #expect(!LocalNetworkCheck.saysNoRoute("Connection refused"))
        #expect(!LocalNetworkCheck.saysNoRoute(nil))
    }

    @Test func judgesFromThisChecksOwnAttemptAndTheAppsError() {
        func judge(denied: Bool = false, instant: Bool = false, connected: Bool = true, app: String? = "com.dbeaver.product", error: String? = nil, open: Bool = false,
                   local: String? = "192.168.1.20", gateway: Bool = false) -> LocalNetworkCheck.Finding? {
            LocalNetworkCheck.judge(local: local, isGateway: gateway, selfDenied: denied, selfInstant: instant, selfConnected: connected, app: app, appError: error, appOpen: open)
        }
        #expect(judge(denied: true, connected: false) == .selfDenied(address: "192.168.1.20", proven: true))
        #expect(judge(instant: true, connected: false) == .selfDenied(address: "192.168.1.20", proven: false))
        #expect(judge(instant: true, connected: false, gateway: true) == nil)
        #expect(judge(error: "connect EHOSTUNREACH 192.168.1.20:5432") == .appSuspect(address: "192.168.1.20"))
        #expect(judge(app: nil, error: "No route to host") == .appSuspect(address: "192.168.1.20"))
        #expect(judge() == .appHint(address: "192.168.1.20"))
        #expect(judge(app: nil) == nil)
        // The app already reaches it, or this check doesn't: nothing to say about the permission.
        #expect(judge(error: "No route to host", open: true) == nil)
        #expect(judge(connected: false, error: "No route to host") == nil)
        #expect(judge(error: "No route to host", local: nil) == nil)
    }

    @Test func wordsNameThePermissionAndATest() {
        let suspect = LocalNetworkCheck.words(.appSuspect(address: "192.168.1.20"), app: "DBeaver", host: "nas.lan", inApp: true)
        #expect(suspect.step.status == .warning && suspect.step.layer == "Local Network")
        #expect(suspect.verdict == "The network reaches nas.lan. macOS may be blocking DBeaver from your local network.")
        #expect(suspect.next.contains("Privacy & Security › Local Network, turn on DBeaver"))
        let own = LocalNetworkCheck.words(.selfDenied(address: "192.168.1.20", proven: true), app: nil, host: "nas.lan", inApp: false)
        #expect(own.step.status == .failed && own.verdict == "macOS is blocking this check from your local network.")
        #expect(own.next.contains("Apple’s Terminal doesn’t need it"))
        #expect(LocalNetworkCheck.words(.selfDenied(address: "192.168.1.20", proven: false), app: nil, host: "nas.lan", inApp: true).verdict?.contains("may be blocking Kilobat") == true)
        #expect(LocalNetworkCheck.words(.appHint(address: "192.168.1.20"), app: "DBeaver", host: "nas.lan", inApp: true).verdict == nil)
    }
}

struct LeakTestDNSPathTests {
    @Test func notesPerDomainResolversOutsideTheTunnelAndRelay() {
        var seen = LeakTest.Observations(exit: ExitPath(interface: "utun4", connected: ["Mullvad"]))
        seen.resolvers = LeakTest.resolvers(PathSoftwareFixtures.tailscaleDNS.replacingOccurrences(of: "100.100.100.100", with: "10.20.0.2"))
        seen.resolverRoutes = ["192.168.1.1": "utun4", "10.20.0.2": "en0"]
        seen.relay = .seen
        let notes = LeakTest.notes(seen)
        #expect(notes.count == 2)
        #expect(notes.first == "Lookups for names under tail1234.ts.net go to 10.20.0.2 over en0, outside Mullvad.")
        #expect(notes.last?.contains("Private Relay") == true)
        seen.resolverRoutes["10.20.0.2"] = "utun4"; seen.relay = .notSeen
        #expect(LeakTest.notes(seen).isEmpty)
        #expect(LeakTest.evaluate(seen).notes == nil)
    }
}
