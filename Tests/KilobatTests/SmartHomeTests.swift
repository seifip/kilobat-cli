import Foundation
import Testing
@testable import KilobatCore

/// The smart-home check, from made-up Bonjour records shaped like the Thread, Matter and HomeKit specifications
/// describe. Names, IDs and addresses are invented (documentation ranges); none come from a real home.
struct SmartHomeTests {
    private func bytes(_ hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).map { UInt8(hex.dropFirst($0).prefix(2), radix: 16)! })
    }
    private func text(_ value: String) -> Data { Data(value.utf8) }
    /// sb: interface active (2 << 3), high availability (1 << 5), role leader or router (bits 9–10), ePSKc (bit 11).
    private func bitmap(active: Bool = true, role: UInt32 = 2, epskc: Bool = false) -> Data {
        let value: UInt32 = (active ? 2 << 3 : 1 << 3) | 1 << 5 | role << 9 | (epskc ? 1 << 11 : 0) | 1
        return withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
    private func borderRouter(_ name: String, vendor: String, model: String, network: String, xp: String, active: Bool = true, epskc: Bool = false,
                              addresses: [String] = ["fe80::1"]) -> BonjourInstance {
        let wire = TXTRecord.encode([("rv", text("1")), ("tv", text("1.3.0")), ("sb", bitmap(active: active, epskc: epskc)), ("nn", text(network)),
                                     ("xp", bytes(xp)), ("vn", text(vendor)), ("mn", text(model))])
        return BonjourInstance(type: SmartHomeServices.meshcop, name: name, host: name.replacingOccurrences(of: " ", with: "-") + ".local.", port: 49154,
                               txt: TXTRecord.parse(wire), addresses: addresses)
    }
    private func facts(linkLocal: Bool = true, prefixes: [IPv6Prefix] = [IPv6Prefix(prefix: "2001:db8:1::", length: 64, routers: ["fe80::1"])],
                       neighbours: Int = 4, peers: Int = 6, band: String? = "5 GHz", scan: [NearbyNetwork]? = nil) -> SmartHomeFacts {
        var facts = SmartHomeFacts()
        facts.interface = "en0"; facts.onWiFi = true
        facts.subnet = (0xC0A8_0164, 0xFFFF_FF00)   // 192.168.1.100/24
        facts.gateway = "192.168.1.1"; facts.gatewayMAC = "00:00:5e:00:53:01"; facts.routerVendor = "AVM Audiovisuelles Marketing und Computersysteme GmbH"
        facts.ipv6.linkLocal = linkLocal; facts.ipv6.global = !prefixes.isEmpty && !prefixes.allSatisfy(\.unique); facts.ipv6.uniqueLocal = prefixes.contains(where: \.unique)
        facts.ipv6.prefixes = prefixes
        facts.ipv6.neighbours = ["fe80::1": "00:00:5e:00:53:01", "fe80::aa": "00:00:5e:00:53:aa"]
        facts.neighbours = neighbours; facts.bonjourPeers = peers; facts.localNetwork = .allowed
        facts.ssid = "Example Home"; facts.band = band
        facts.scan = scan ?? [NearbyNetwork(id: "a", ssid: "Example Home", rssi: -50, noise: -95, channel: 6, band: "2.4 GHz", widthMHz: 20),
                              NearbyNetwork(id: "b", ssid: "Example Home", rssi: -55, noise: -95, channel: 36, band: "5 GHz", widthMHz: 80)]
        return facts
    }

    // MARK: TXT records

    @Test func txtRecordsParseBinaryAndText() {
        var wire = TXTRecord.encode([("nn", text("TestNet")), ("XP", bytes("dead00beef00cafe")), ("flag", Data()), ("nn", text("Second"))])
        wire.append(contentsOf: [0, 3, 0x3D, 0x61, 0x62])   // an empty string and one with no key: both skipped
        let txt = TXTRecord.parse(wire)
        #expect(TXTRecord.text(txt["nn"]) == "TestNet")   // the first of a repeated key wins
        #expect(txt["xp"] == bytes("dead00beef00cafe"))
        #expect(txt["flag"] == Data())
        #expect(txt.count == 3)
        // A truncated record keeps what came before it.
        #expect(TXTRecord.parse(Data([5, 0x61, 0x3D, 0x31])).isEmpty)
    }

    @Test func stateBitmapFollowsOpenThreadLayout() {
        let state = MeshCoPState(bitmap(active: true, role: 3, epskc: true))!
        #expect(state.interface == .active && state.role == .leader && state.credentialSharing && state.highAvailability && state.connectionMode == 1)
        let idle = MeshCoPState(bitmap(active: false, role: 0))!
        #expect(idle.interface == .initialized && idle.role == .detached && !idle.credentialSharing)
        #expect(MeshCoPState(Data([1, 2, 3])) == nil)
        #expect(MeshCoPState(bitmap: 0x0000_0031).interface == .active)
    }

    @Test func borderRoutersAreIdentified() {
        let apple = ThreadBorderRouter.parse(borderRouter("Kitchen", vendor: "Apple Inc.", model: "HomePod", network: "TestNet-A", xp: "1111222233334444"))
        #expect(apple.ecosystem == .apple && apple.networkName == "TestNet-A" && apple.extendedPANID == "1111222233334444")
        #expect(apple.threadVersion == "1.3.0" && apple.onNetwork && apple.label == "HomePod (Kitchen)")
        #expect(SmartHomeEcosystem.identify(vendor: "Google Inc.", model: "Google Nest Hub") == .google)
        #expect(SmartHomeEcosystem.identify(vendor: "eero", model: "eero Pro 6") == .amazon)
        #expect(SmartHomeEcosystem.identify(vendor: "Amazon", model: "Echo") == .amazon)
        #expect(SmartHomeEcosystem.identify(vendor: "Samsung", model: "SmartThings Station") == .samsung)
        #expect(SmartHomeEcosystem.identify(vendor: "HomeAssistant", model: "OpenThread Border Router") == .homeAssistant)
        let other = ThreadBorderRouter.parse(borderRouter("Hub", vendor: "Example Lighting", model: "Hub", network: "TestNet-C", xp: "5555666677778888"))
        #expect(other.ecosystem == .other && other.maker == "Example Lighting" && other.label == "Hub")
        // An extended PAN ID written as text by an older border agent.
        let record = BonjourInstance(type: SmartHomeServices.meshcop, name: "Old", txt: ["xp": text("ABCDEF0123456789"), "nn": text("TestNet-D")])
        #expect(ThreadBorderRouter.parse(record).extendedPANID == "abcdef0123456789")
    }

    @Test func extendedDiscoveryIsNotReadyToSetUp() {
        let closed = BonjourInstance(type: SmartHomeServices.matterCommissionable, name: "Closed", host: "closed.local.", txt: ["cm": text("0"), "dn": text("Example lamp")])
        let report = SmartHomeReport.build([closed], facts: facts())
        #expect(report.matter.commissionable.count == 1)
        #expect(report.matter.readyToSetUp.isEmpty)
        #expect(!report.headline.contains("ready to set up"))
    }

    // MARK: Thread networks

    @Test func oneNetworkWithThreeBorderRouters() {
        let records = ["Kitchen", "Lounge", "Study"].map { borderRouter($0, vendor: "Apple Inc.", model: "HomePod", network: "TestNet-A", xp: "1111222233334444") }
        let report = SmartHomeReport.build(records, facts: facts())
        #expect(report.threadNetworks.count == 1 && report.threadNetworks[0].borderRouters.count == 3)
        #expect(report.headline == "Thread: one network (TestNet-A) with 3 border routers")
        #expect(report.findings.isEmpty && report.healthIssue == nil)
    }

    @Test func separateNetworksFromTwoEcosystems() {
        let records = [borderRouter("Kitchen", vendor: "Apple Inc.", model: "HomePod", network: "TestNet-A", xp: "1111222233334444"),
                       borderRouter("Lounge", vendor: "Apple Inc.", model: "Apple TV", network: "TestNet-A", xp: "1111222233334444"),
                       borderRouter("Hall", vendor: "Google Inc.", model: "Google Nest Hub", network: "TestNet-B", xp: "9999aaaabbbbcccc", epskc: true),
                       // Not attached to a network: listed apart, never counted as a third network.
                       borderRouter("Spare", vendor: "Example", model: "Bridge", network: "TestNet-C", xp: "0000000000000001", active: false)]
        let report = SmartHomeReport.build(records, facts: facts())
        #expect(report.threadNetworks.count == 2 && report.idleBorderRouters.count == 1)
        #expect(report.threadNetworks[0].makers == ["Apple"] && report.threadNetworks[1].makers == ["Google"])
        #expect(report.headline == "Thread: 2 separate networks")
        let finding = try! #require(report.findings.first)
        #expect(finding.id == "separateThreadNetworks" && finding.title == "You have 2 separate Thread networks (Apple’s and Google’s)")
        #expect(finding.fix.contains("credential sharing") && finding.sources.contains(SmartHomeSources.thread14))
        #expect(report.healthIssue?.title == finding.title)
    }

    @Test func sameMakerTwiceIsStillTwoNetworks() {
        let records = [borderRouter("A", vendor: "Google Inc.", model: "Nest Wifi Pro", network: "TestNet-A", xp: "1111222233334444"),
                       borderRouter("B", vendor: "Google Inc.", model: "Google Nest Hub", network: "TestNet-B", xp: "2222333344445555")]
        let finding = SmartHomeReport.build(records, facts: facts()).findings.first
        #expect(finding?.title == "You have 2 separate Thread networks")
        #expect(finding?.fix.contains("credential sharing") == false)
    }

    // MARK: Matter and HomeKit

    @Test func matterDevicesAreCountedOncePerDevice() {
        let fabricA = "1A2B3C4D5E6F7081", fabricB = "0F0E0D0C0B0A0908"
        let operational = [
            BonjourInstance(type: SmartHomeServices.matter, name: "\(fabricA)-0000000000000001", host: "AABBCCDDEEFF.local.", addresses: ["192.168.1.40", "fe80::40"]),
            BonjourInstance(type: SmartHomeServices.matter, name: "\(fabricB)-0000000000000007", host: "AABBCCDDEEFF.local.", addresses: ["192.168.1.40"]),
            BonjourInstance(type: SmartHomeServices.matter, name: "\(fabricA)-0000000000000002", host: "0011223344556677.local.", addresses: ["fd12:3456:789a:1::2"]),
        ]
        let waiting = [BonjourInstance(type: SmartHomeServices.matterCommissionable, name: "8F7E6D5C4B3A2910", host: "112233445566.local.",
                                       txt: TXTRecord.parse(TXTRecord.encode([("D", text("3840")), ("VP", text("65521+32769")), ("CM", text("1")), ("DT", text("257")), ("DN", text("Desk lamp"))])))]
        let matter = MatterSummary.build(operational: operational, commissionable: waiting)
        #expect(matter.devices == 2 && matter.fabrics == 2 && matter.advertisements == 3)
        #expect(matter.overThread == 1 && matter.overWiFi == 1)
        let device = try! #require(matter.commissionable.first)
        #expect(device.name == "Desk lamp" && device.deviceType == "Dimmable light" && device.vendorID == 65521 && device.productID == 32769 && device.pairingMode)
        let report = SmartHomeReport.build(operational + waiting, facts: facts())
        #expect(report.headline == "Matter: 2 devices (1 ready to set up)")
    }

    @Test func homeKitAccessoriesAndBridges() {
        func hap(_ id: String, category: String, flags: String, type: String = SmartHomeServices.hap) -> BonjourInstance {
            BonjourInstance(type: type, name: "Accessory \(id)", host: "acc-\(id).local.",
                            txt: TXTRecord.parse(TXTRecord.encode([("c#", text("3")), ("id", text(id)), ("md", text("Model")), ("ci", text(category)), ("sf", text(flags)), ("s#", text("1"))])))
        }
        let records = [hap("AA:00:00:00:00:01", category: "2", flags: "0"), hap("AA:00:00:00:00:02", category: "5", flags: "1"),
                       hap("AA:00:00:00:00:02", category: "5", flags: "1"), hap("AA:00:00:00:00:03", category: "10", flags: "0", type: SmartHomeServices.hapThread)]
        let homeKit = HomeKitSummary.build(records)
        #expect(homeKit.accessories == 3 && homeKit.bridges == 1 && homeKit.unpaired == 1 && homeKit.overThread == 1)
        #expect(homeKit.categories == ["Bridge": 1, "Light": 1, "Sensor": 1])
        #expect(SmartHomeReport.build(records, facts: facts()).headline == "HomeKit: 3 accessories, 1 bridge")
    }

    @Test func thisMacsOwnAdvertisementsDontCount() {
        var facts = facts()
        facts.ownHosts = ["example-mac.local"]
        let own = BonjourInstance(type: SmartHomeServices.hap, name: "Mac", host: "Example-Mac.local.", txt: ["id": text("BB:00:00:00:00:01")])
        #expect(SmartHomeReport.build([own], facts: facts).homeKit.accessories == 0)
    }

    @Test func nothingFound() {
        let report = SmartHomeReport.build([], facts: facts())
        #expect(report.headline == "No Matter, Thread or HomeKit devices answered on this network.")
        #expect(!report.devicesFound && report.healthIssue == nil)
    }

    // MARK: Readiness

    private func check(_ kind: SmartHomeCheck.Kind, _ report: SmartHomeReport) -> SmartHomeCheck { report.checks.first { $0.kind == kind }! }
    private let lamp = BonjourInstance(type: SmartHomeServices.matter, name: "1A2B3C4D5E6F7081-0000000000000001", host: "AABBCCDDEEFF.local.", addresses: ["192.168.1.40"])

    @Test func ipv6Verdicts() {
        #expect(check(.ipv6, SmartHomeReport.build([lamp], facts: facts())).state == .ok)
        // No prefix observed: routed connectivity is uncertain; do not diagnose router settings from silence.
        let off = SmartHomeReport.build([lamp], facts: facts(prefixes: []))
        #expect(check(.ipv6, off).state == .unknown && check(.ipv6, off).summary.contains("unverified"))
        #expect(check(.ipv6, off).guide == "https://kilobat.app/routers/fritzbox" && check(.ipv6, off).fix?.contains("router guide") == true)
        #expect(off.healthIssue == nil)
        #expect(check(.ipv6, SmartHomeReport.build([], facts: facts(prefixes: []))).state == .unknown)
        // A ULA prefix from another device, such as a border router, and not the router.
        let ula = SmartHomeReport.build([lamp], facts: facts(prefixes: [IPv6Prefix(prefix: "fd12:3456:789a:1::", length: 64, routers: ["fe80::aa"])]))
        #expect(check(.ipv6, ula).state == .ok && check(.ipv6, ula).summary.contains("Thread border router") && check(.ipv6, ula).summary.contains("local (ULA)"))
        #expect(check(.ipv6, SmartHomeReport.build([lamp], facts: facts(linkLocal: false))).state == .problem)
    }

    @Test func bonjourAndIsolation() {
        #expect(check(.bonjour, SmartHomeReport.build([], facts: facts())).state == .ok)
        let alone = SmartHomeReport.build([], facts: facts(neighbours: 0, peers: 0))
        #expect(check(.bonjour, alone).state == .warning && check(.isolation, alone).state == .unknown)
        #expect(check(.isolation, alone).guide == "https://kilobat.app/routers/fritzbox")
        // Not a Health line without smart-home devices.
        #expect(alone.healthIssue == nil)
        var denied = facts(); denied.localNetwork = .denied
        let report = SmartHomeReport.build([], facts: denied)
        #expect(check(.bonjour, report).state == .unknown && check(.isolation, report).state == .unknown)
        #expect(report.findings.first?.id == "localNetworkDenied" && report.headline.contains("Local Network"))
    }

    @Test func subnetComparison() {
        #expect(check(.subnet, SmartHomeReport.build([lamp], facts: facts())).state == .ok)
        var away = lamp; away.addresses = ["192.168.20.15"]
        #expect(check(.subnet, SmartHomeReport.build([away], facts: facts())).state == .warning)
        var thread = lamp; thread.addresses = ["fd12:3456:789a:1::2"]
        #expect(check(.subnet, SmartHomeReport.build([thread], facts: facts())).state == .unknown)
        #expect(check(.subnet, SmartHomeReport.build([], facts: facts())).summary == "No smart-home devices to compare.")
    }

    @Test func twoPointFourGigahertz() {
        #expect(check(.wifi24, SmartHomeReport.build([], facts: facts())).state == .ok)
        #expect(check(.wifi24, SmartHomeReport.build([], facts: facts(band: "2.4 GHz", scan: []))).state == .ok)
        let five = [NearbyNetwork(id: "b", ssid: "Example Home", rssi: -55, noise: -95, channel: 36, band: "5 GHz", widthMHz: 80),
                    NearbyNetwork(id: "c", ssid: "Neighbour", rssi: -70, noise: -95, channel: 1, band: "2.4 GHz", widthMHz: 20)]
        #expect(check(.wifi24, SmartHomeReport.build([], facts: facts(scan: five))).state == .warning)
        var hidden = facts(); hidden.ssid = nil
        #expect(check(.wifi24, SmartHomeReport.build([], facts: hidden)).state == .unknown)
        var wired = facts(); wired.onWiFi = false
        #expect(check(.wifi24, SmartHomeReport.build([], facts: wired)).state == .unknown)
    }

    @Test func routerGuidesOnlyForOneLineMakers() {
        #expect(RouterGuides.slug(vendor: "ASUSTek COMPUTER INC.") == "asus")
        #expect(RouterGuides.slug(vendor: "eero inc.") == "eero")
        #expect(RouterGuides.slug(vendor: "NETGEAR") == nil)
        #expect(RouterGuides.slug(maker: "TP-Link") == nil)
        #expect(RouterGuides.slug(maker: "Ubiquiti Inc") == "ubiquiti-unifi")
        #expect(RouterGuides.firmware(maker: "AVM") == "https://kilobat.app/routers/fritzbox#firmware")
        #expect(RouterGuides.slug(vendor: nil) == nil)
        var unknown = facts(prefixes: []); unknown.routerVendor = nil
        let check = check(.ipv6, SmartHomeReport.build([lamp], facts: unknown))
        #expect(check.guide == nil && check.fix?.contains("router guide") == false)
    }

    // MARK: Parsing ndp and the command

    @Test func ndpOutput() {
        let prefixes = """
        2001:db8:1::/64 if=en0
        flags=LAD vltime=86400, pltime=14400, expire=23h59m50s, ref=2
          advertised by
            fe80::1%en0 (reachable)
        fd12:3456:789a:1::/64 if=en0
        flags=LAD vltime=1800, pltime=1800, expire=29m, ref=0
          advertised by
            fe80::aa%en0 (reachable)
        fe80::%en0/64 if=en0
        flags=AILSO vltime=infinity, pltime=infinity, expire=Never, ref=0
          No advertising router
        fd00:1::/64 if=utun3
        flags=LAD vltime=1800, pltime=1800, expire=29m, ref=0
          No advertising router
        """
        let parsed = IPv6Facts.prefixes(prefixes, interface: "en0")
        #expect(parsed == [IPv6Prefix(prefix: "2001:db8:1::", length: 64, routers: ["fe80::1"]), IPv6Prefix(prefix: "fd12:3456:789a:1::", length: 64, routers: ["fe80::aa"])])
        #expect(parsed[1].unique && !parsed[0].unique)
        let routers = "fe80::%utun0 if=utun0, flags=IST, pref=medium, expire=Never\nfe80::1%en0 if=en0, flags=, pref=low, expire=1h55m54s\n"
        #expect(IPv6Facts.defaultRouters(routers, interface: "en0") == ["fe80::1"])
        let neighbours = """
        Neighbor                             Linklayer Address  Netif Expire    1s 5s
        fe80::1%en0                          0:0:5e:0:53:1        en0 23h59m58s S  R
        fe80::aa%en0                         (incomplete)         en0 expired   N
        2001:db8:1::9                        0:0:5e:0:53:9        en0 permanent R
        """
        #expect(IPv6Facts.neighbours(neighbours, interface: "en0") == ["fe80::1": "00:00:5e:00:53:01", "2001:db8:1::9": "00:00:5e:00:53:09"])
        #expect(IPv6Facts.kind("fe80::1%en0") == .linkLocal && IPv6Facts.kind("fd12::1") == .unique && IPv6Facts.kind("2001:db8::1") == .global)
    }

    @Test func commandArguments() throws {
        #expect(try SmartHomeCommand.parse(["smarthome"]) == .report(json: false))
        #expect(try SmartHomeCommand.parse(["smarthome", "--json"]) == .report(json: true))
        #expect(throws: DiagnosticError.self) { try SmartHomeCommand.parse(["smarthome", "commission"]) }
    }

    @Test @MainActor func rememberedNetworksUsePropertyListArraysAndStayBounded() throws {
        let suite = "kilobat-smarthome-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let watch = SmartHomeWatch(defaults: defaults)
        for index in 0..<25 { watch.remember("example-network-\(index)", found: true) }
        let remembered = try #require(defaults.stringArray(forKey: SmartHomeWatch.rememberedKey))
        #expect(remembered.count == 20)
        let removed = try #require(remembered.first)
        watch.remember(removed, found: false)
        #expect(defaults.stringArray(forKey: SmartHomeWatch.rememberedKey)?.contains(removed) == false)
        watch.remember(nil, found: true)
        #expect(defaults.stringArray(forKey: SmartHomeWatch.rememberedKey)?.count == 19)
    }

    @Test func reportEncodesCompactly() throws {
        let records = [borderRouter("Kitchen", vendor: "Apple Inc.", model: "HomePod", network: "TestNet-A", xp: "1111222233334444")]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(SmartHomeReport.build(records, facts: facts())), as: UTF8.self)
        #expect(json.contains("\"extendedPANID\":\"1111222233334444\"") && json.contains("\"interface\":\"active\"") && json.contains("\"ecosystem\":\"apple\""))
        let decoded = try { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return try decoder.decode(SmartHomeReport.self, from: Data(json.utf8)) }()
        #expect(decoded.threadNetworks.first?.borderRouters.first?.state?.interface == .active)
    }
}
