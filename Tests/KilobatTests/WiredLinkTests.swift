import Foundation
import Testing
@testable import KilobatCore

/// `ifconfig -v -m -a` and IORegistry paths as macOS 27 prints them: this Mac's own ports, a USB gigabit adapter held
/// to 100 Mbps, a 10GbE port at 2.5G, an unplugged port and a half-duplex link.
enum WiredFixtures {
    /// Abridged from a MacBook Pro (M4) on macOS 27.2: Wi-Fi, a Thunderbolt port and the Mac's own USB-C port in device mode.
    static let thisMac = """
    en4: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500 index 7
    \teflags=400008c1<AUTOCONFIGURING,ACCEPT_RTADV,TXSTART,ARPLL,FASTLN_ON>
    \toptions=404<VLAN_MTU,CHANNEL_IO>
    \tether ee:e9:8e:c7:2c:bf
    \tinet6 fe80::1802:a9b:f41d:619b%en4 prefixlen 64 secured scopeid 0x7
    \tinet 169.254.1.226 netmask 0xffff0000 broadcast 169.254.255.255
    \tnd6 options=201<PERFORMNUD,DAD>
    \tmedia: 100baseTX <full-duplex>
    \tstatus: active
    \tsupported media:
    \t\tmedia 100baseTX mediaopt full-duplex
    \t\tmedia none
    \tmax mtu: 16000
    \ttype: USB Ethernet
    \tlink quality: 100 (good)
    \tlink rate: 100.00 Mbps
    en1: flags=8963<UP,BROADCAST,SMART,RUNNING,PROMISC,SIMPLEX,MULTICAST> mtu 1500 index 8
    \toptions=460<TSO4,TSO6,CHANNEL_IO>
    \tether 36:2f:fe:54:bd:c0
    \tmedia: autoselect <full-duplex>
    \tstatus: inactive
    \tsupported media:
    \t\tmedia autoselect mediaopt full-duplex
    en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500 index 11
    \tether ce:3e:80:2e:8e:92
    \tinet6 fe80::c95:1ff:7b6:a3f2%en0 prefixlen 64 secured scopeid 0xb
    \tinet 192.168.33.162 netmask 0xffffff00 broadcast 192.168.33.255
    \tmedia: autoselect
    \tstatus: active
    \tsupported media:
    \t\tmedia autoselect
    \ttype: Wi-Fi
    \tuplink rate: 1200.95 Mbps
    \tdownlink rate: 1200.95 Mbps
    """

    /// A Realtek RTL8153 USB adapter behind a dock, negotiated at 100 Mbps.
    static let usbAt100 = """
    en7: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500 index 21
    \teflags=412080<TXSTART,NOACKPRI,ECN_ENABLE,FASTLN_ON>
    \toptions=6467<RXCSUM,TXCSUM,VLAN_MTU,TSO4,TSO6,CHANNEL_IO,PARTIAL_CSUM,ZEROINVERT_CSUM>
    \tether 00:e0:4c:68:01:23
    \tinet6 fe80::1c2b:3a4d:5e6f:7081%en7 prefixlen 64 secured scopeid 0x15
    \tinet 192.168.1.42 netmask 0xffffff00 broadcast 192.168.1.255
    \tinet6 2a02:8109:b6c0:1d00:4c1:2b3c:4d5e:6f70 prefixlen 64 autoconf secured
    \tnd6 options=201<PERFORMNUD,DAD>
    \tmedia: autoselect (100baseTX <full-duplex,flow-control>)
    \tstatus: active
    \tsupported media:
    \t\tmedia autoselect
    \t\tmedia 10baseT/UTP mediaopt half-duplex
    \t\tmedia 10baseT/UTP mediaopt full-duplex
    \t\tmedia 10baseT/UTP mediaopt full-duplex,flow-control
    \t\tmedia 100baseTX mediaopt half-duplex
    \t\tmedia 100baseTX mediaopt full-duplex
    \t\tmedia 100baseTX mediaopt full-duplex,flow-control
    \t\tmedia 1000baseT mediaopt full-duplex
    \t\tmedia 1000baseT mediaopt full-duplex,flow-control
    \ttype: USB Ethernet
    \tlink rate: 100.00 Mbps
    """

    /// A Mac Studio's 10GbE port at 2.5G, a dock port with no cable, and a link stuck at half duplex.
    static let others = """
    en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500 index 6
    \tether 3c:a6:f6:01:02:03
    \tinet 10.0.0.12 netmask 0xffffff00 broadcast 10.0.0.255
    \tmedia: autoselect (2500Base-T <full-duplex,flow-control,energy-efficient-ethernet>)
    \tstatus: active
    \tsupported media:
    \t\tmedia autoselect mediaopt flow-control
    \t\tmedia autoselect
    \t\tmedia 10Gbase-T mediaopt full-duplex,flow-control
    \t\tmedia 5000Base-T mediaopt full-duplex
    \t\tmedia 2500Base-T mediaopt full-duplex
    \t\tmedia 1000baseT mediaopt full-duplex
    \t\tmedia 100baseTX mediaopt full-duplex
    \t\tmedia 10baseT/UTP mediaopt full-duplex
    \ttype: Ethernet
    \tlink rate: 2.50 Gbps
    en8: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500 index 19
    \tether 64:4b:f0:11:22:33
    \tmedia: autoselect (none)
    \tstatus: inactive
    \tsupported media:
    \t\tmedia autoselect
    \t\tmedia 100baseTX mediaopt full-duplex
    \t\tmedia 1000baseT mediaopt full-duplex
    \ttype: USB Ethernet
    en9: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500 index 20
    \tether 00:0e:c6:aa:bb:cc
    \tinet 169.254.77.9 netmask 0xffff0000 broadcast 169.254.255.255
    \tmedia: 100baseTX <half-duplex>
    \tstatus: active
    \tsupported media:
    \t\tmedia 100baseTX mediaopt half-duplex
    \t\tmedia 100baseTX mediaopt full-duplex
    \t\tmedia 1000baseT mediaopt full-duplex
    \ttype: USB Ethernet
    """

    static func node(_ className: String, _ name: String = "", strings: [String: String] = [:], numbers: [String: Int] = [:]) -> RegistryNode {
        RegistryNode(className: className, name: name.isEmpty ? className : name, strings: strings, numbers: numbers)
    }
    /// The Mac's own USB-C port acting as a device: listed as "Ethernet Adapter (en4)" in Network settings with no service.
    static let deviceMode = [node("IOEthernetInterface", "en4", strings: ["BSD Name": "en4"]), node("AppleUSBDeviceNCM11Data"),
                             node("IOUSBDeviceInterface", "AppleUSBNCMData@1"), node("AppleUSBDeviceNCM11Control", "AppleUSBDeviceNCM11Control@0")]
    static let thunderboltBridge = [node("IOEthernetInterface", "en1", strings: ["BSD Name": "en1"]), node("AppleThunderboltIPPort"),
                                    node("AppleThunderboltIPService"), node("IOThunderboltXDomainServiceClientManager"), node("IOThunderboltLocalNode")]
    static let wifi = [node("IOSkywalkLegacyEthernetInterface", "en0", strings: ["BSD Name": "en0"]), node("IOSkywalkLegacyEthernet"),
                       node("IOUserNetworkWLAN", "AppleBCMWLANSkywalkInterface")]
    static let realtek = [node("IOEthernetInterface", "en7", strings: ["BSD Name": "en7"]),
                          node("IOUserEthernetController", "AppleUserECMData", strings: ["IOUserClass": "AppleUserECMData", "CFBundleIdentifier": "com.apple.DriverKit-AppleUserECM"]),
                          node("IOUSBHostInterface", "USB 10/100/1000 LAN@1"),
                          node("IOUSBHostDevice", "USB 10/100/1000 LAN@01100000", strings: ["USB Vendor Name": "Realtek", "USB Product Name": "USB 10/100/1000 LAN"],
                               numbers: ["idVendor": 0x0BDA, "idProduct": 0x8153, "USBSpeed": 3, "UsbLinkSpeed": 5_000_000_000]),
                          node("AppleUSB30XHCIPort", "Port-USB-C@1")]
    /// ASIX's own driver, on a USB 2 port of a keyboard hub.
    static let asixOnUSB2 = [node("IOEthernetInterface", "en9", strings: ["BSD Name": "en9"]),
                             node("IOUserEthernetController", "AX88179A", strings: ["IOUserClass": "AX88179A", "CFBundleIdentifier": "com.asix.dext.ax88179a"]),
                             node("IOUSBHostInterface", "AX88179A@0"),
                             node("IOUSBHostDevice", "AX88179A@01121000", strings: ["kUSBVendorString": "ASIX", "kUSBProductString": "AX88179A"],
                                  numbers: ["idVendor": 0x0B95, "idProduct": 0x1790, "USBSpeed": 2])]
    static let thunderboltDock = [node("IOEthernetInterface", "en11", strings: ["BSD Name": "en11"]),
                                  node("AppleEthernetAquantiaAqtion", "AppleEthernetAquantiaAqtion"),
                                  node("IOPCIDevice", "pci1d6a,7"), node("IOPCI2PCIBridge"), node("IOThunderboltSwitchType5"), node("IOThunderboltPort")]
    static let builtIn = [node("IOEthernetInterface", "en0", strings: ["BSD Name": "en0"]),
                          node("AppleBCM5701Ethernet", "ethernet", strings: ["IOVendor": "Broadcom", "IOModel": "BCM57762"]),
                          node("IOPCIDevice", "ethernet@0"), node("AppleT6000PCIeC")]
}

struct WiredLinkTests {
    @Test func readsANegotiatedLinkBelowWhatTheAdapterOffers() throws {
        let reading = try #require(WiredLink.parseIfconfig(WiredFixtures.usbAt100)["en7"])
        #expect(reading.active)
        #expect(reading.media == "100baseTX")
        #expect(reading.options == ["full-duplex", "flow-control"])
        #expect(reading.duplex == .full)
        #expect(reading.speedMbps == 100)
        #expect(reading.bestMbps == 1000)
        #expect(reading.linkRateMbps == 100)
        #expect(reading.type == "USB Ethernet")
        #expect(reading.ipv4 == ["192.168.1.42"])
        #expect(reading.ipv6 == ["2a02:8109:b6c0:1d00:4c1:2b3c:4d5e:6f70"])
        #expect(reading.hasAddress)
    }

    @Test func readsMultiGigNamesAndUnpluggedPorts() throws {
        let readings = WiredLink.parseIfconfig(WiredFixtures.others)
        let tenGig = try #require(readings["en0"])
        #expect(tenGig.speedMbps == 2500)
        #expect(tenGig.bestMbps == 10_000)
        #expect(tenGig.linkRateMbps == 2500)
        let unplugged = try #require(readings["en8"])
        #expect(!unplugged.active)
        #expect(unplugged.media == nil)
        #expect(unplugged.speedMbps == nil)
        #expect(unplugged.bestMbps == 1000)
        let half = try #require(readings["en9"])
        #expect(half.duplex == .half)
        // Only a self-assigned address: nothing on the cable answered.
        #expect(!half.hasAddress)
    }

    @Test func readsThisMacsOwnPortsWithoutConfusingWiFiRates() throws {
        let readings = WiredLink.parseIfconfig(WiredFixtures.thisMac)
        #expect(Set(readings.keys) == ["en4", "en1", "en0"])
        #expect(readings["en4"]?.speedMbps == 100)
        #expect(readings["en4"]?.supported == ["100baseTX"])
        #expect(readings["en1"]?.active == false)
        // Wi-Fi's "uplink rate" isn't an Ethernet link rate.
        #expect(readings["en0"]?.linkRateMbps == nil)
        #expect(readings["en0"]?.media == nil)
    }

    @Test func namesMediaSpeeds() {
        #expect(WiredLink.mbps("10baseT/UTP") == 10)
        #expect(WiredLink.mbps("100baseTX") == 100)
        #expect(WiredLink.mbps("1000baseT") == 1000)
        #expect(WiredLink.mbps("2500Base-T") == 2500)
        #expect(WiredLink.mbps("5000Base-T") == 5000)
        #expect(WiredLink.mbps("10Gbase-T") == 10_000)
        #expect(WiredLink.mbps("autoselect") == nil)
        #expect(WiredLink.mbps("none") == nil)
        #expect(WiredLink.speed(100) == "100 Mbps")
        #expect(WiredLink.speed(1000) == "1 Gbps")
        #expect(WiredLink.speed(2500) == "2.5 Gbps")
        #expect(WiredLink.speed(10_000) == "10 Gbps")
    }

    @Test func skipsPortsThatArentEthernetAdapters() {
        #expect(WiredIdentity.skip(WiredFixtures.deviceMode) == .macAsDevice)
        #expect(WiredIdentity.skip(WiredFixtures.thunderboltBridge) == .thunderboltBridge)
        #expect(WiredIdentity.skip(WiredFixtures.wifi) == .wifi)
        let phone = [WiredFixtures.node("IOEthernetInterface", "en5"), WiredFixtures.node("AppleUSBEthernetHost"),
                     WiredFixtures.node("IOUSBHostDevice", "iPhone@01100000", strings: ["USB Product Name": "iPhone"], numbers: ["idVendor": 0x05AC, "idProduct": 0x12A8])]
        #expect(WiredIdentity.skip(phone) == .phone)
        #expect(WiredIdentity.skip(WiredFixtures.realtek) == nil)
        #expect(WiredIdentity.skip(WiredFixtures.thunderboltDock) == nil)
        #expect(WiredIdentity.skip(WiredFixtures.builtIn) == nil)
    }

    @Test func identifiesAUSBAdapterItsChipAndApplesDriver() {
        let identity = WiredIdentity.read(WiredFixtures.realtek)
        #expect(identity.attachment == .usb)
        #expect(identity.label == "Realtek USB 10/100/1000 LAN")
        #expect(identity.chip == "Realtek RTL8153")
        #expect(identity.chipMbps == 1000)
        #expect(identity.driver == "AppleUserECMData")
        #expect(identity.appleDriver == true)
        #expect(identity.usbMbps == 5000)
    }

    @Test func identifiesAMakersDriverOnUSB2() {
        let identity = WiredIdentity.read(WiredFixtures.asixOnUSB2)
        #expect(identity.chip == "ASIX AX88179")
        #expect(identity.driver == "AX88179A")
        #expect(identity.appleDriver == false)
        #expect(identity.usbMbps == 480)
        #expect(identity.label == "ASIX AX88179A")
    }

    @Test func tellsThunderboltFromBuiltIn() {
        let dock = WiredIdentity.read(WiredFixtures.thunderboltDock)
        #expect(dock.attachment == .thunderbolt)
        #expect(dock.driver == "AppleEthernetAquantiaAqtion")
        #expect(dock.appleDriver == true)
        let own = WiredIdentity.read(WiredFixtures.builtIn)
        #expect(own.attachment == .builtIn)
        #expect(own.chip == "Broadcom BCM57762")
        #expect(own.label == nil)
    }

    private func adapter(_ fixture: String, _ name: String, chain: [RegistryNode] = WiredFixtures.realtek, service: String? = "USB 10/100/1000 LAN", enabled: Bool? = true) -> WiredAdapter {
        WiredAdapter(interface: name, name: "USB 10/100/1000 LAN", identity: WiredIdentity.read(chain), reading: WiredLink.parseIfconfig(fixture)[name],
                     service: service, serviceEnabled: enabled)
    }

    @Test func explainsALinkSlowerThanTheAdapter() throws {
        let slow = adapter(WiredFixtures.usbAt100, "en7")
        #expect(slow.belowBest)
        #expect(slow.linkLine == "100 Mbps · full duplex")
        let finding = try #require(WiredReport(adapters: [slow]).findings.first)
        #expect(finding.kind == .slowerThanAdapter)
        #expect(finding.level == .problem)
        #expect(finding.title == "Ethernet is running at 100 Mbps")
        #expect(finding.detail.contains("1 Gbps"))
        #expect(finding.detail.contains("cable"))
        #expect(finding.detail.contains("dock"))
        // 2.5G on a 10G port is worth a look, not an alarm.
        let multiGig = adapter(WiredFixtures.others, "en0", chain: WiredFixtures.builtIn, service: "Ethernet")
        #expect(WiredReport(adapters: [multiGig]).findings.map(\.level) == [.caution])
    }

    @Test func nothingToSayAboutAHealthyOrUnpluggedPort() {
        let unplugged = adapter(WiredFixtures.others, "en8")
        #expect(unplugged.linkLine == "No cable")
        #expect(WiredReport(adapters: [unplugged]).findings.isEmpty)
        let healthy = WiredAdapter(interface: "en7", name: "USB 10/100/1000 LAN", identity: WiredIdentity.read(WiredFixtures.realtek), service: "USB 10/100/1000 LAN",
                                   serviceEnabled: true, linked: true, speedMbps: 1000, duplex: .full, bestMbps: 1000, hasAddress: true)
        #expect(WiredReport(adapters: [healthy]).findings.isEmpty)
    }

    @Test func halfDuplexWithoutAnAddressIsTwoProblems() {
        let stuck = adapter(WiredFixtures.others, "en9")
        let kinds = WiredReport(adapters: [stuck]).findings.map(\.kind)
        #expect(kinds.contains(.noAddress))
        #expect(kinds.contains(.halfDuplex))
        #expect(kinds.contains(.slowerThanAdapter))
    }

    @Test func anAdapterWithNoServiceSaysHowToAddOne() throws {
        let missing = adapter(WiredFixtures.usbAt100, "en7", service: nil, enabled: nil)
        let findings = WiredReport(adapters: [missing]).findings
        // With no service there's nothing else to judge.
        #expect(findings.count == 1)
        let finding = try #require(findings.first)
        #expect(finding.kind == .noService)
        #expect(finding.level == .problem)
        #expect(finding.opensNetworkSettings)
        #expect(finding.detail.contains("Add Service"))
        // No cable: still worth saying, less loudly.
        let idle = adapter(WiredFixtures.others, "en8", service: nil, enabled: nil)
        #expect(WiredReport(adapters: [idle]).findings.map(\.level) == [.caution])
    }

    @Test func anInactiveServiceMattersOnlyWithACable() {
        #expect(WiredReport(adapters: [adapter(WiredFixtures.usbAt100, "en7", enabled: false)]).findings.map(\.kind) == [.serviceOff])
        #expect(WiredReport(adapters: [adapter(WiredFixtures.others, "en8", enabled: false)]).findings.isEmpty)
    }

    @Test func aGigabitAdapterOnUSB2() {
        let usb2 = WiredAdapter(interface: "en9", name: "AX88179A", identity: WiredIdentity.read(WiredFixtures.asixOnUSB2), service: "AX88179A", serviceEnabled: true,
                                linked: true, speedMbps: 1000, duplex: .full, bestMbps: 1000, hasAddress: true)
        let findings = WiredReport(adapters: [usb2]).findings
        #expect(findings.map(\.kind) == [.usb2])
        #expect(findings.first?.detail.contains("300 Mbps") == true)
    }

    @Test func aKnownChipWithNoDriver() throws {
        let missing = WiredMissingDriver(vendorID: 0x0B95, productID: 0x1790, chip: "ASIX AX88179", product: "AX88179")
        let finding = try #require(WiredReport(adapters: [], missingDrivers: [missing]).findings.first)
        #expect(finding.kind == .noDriver)
        #expect(finding.title == "AX88179 has no driver")
        #expect(finding.detail.contains("ASIX AX88179"))
        #expect(WiredLink.chip(vendor: 0x0BDA, product: 0x8156)?.mbps == 2500)
        #expect(WiredLink.chip(vendor: 0x1234, product: 0x5678) == nil)
        #expect(WiredLink.chip(vendor: -1, product: 0x8153) == nil)
    }

    @Test func problemsComeFirst() {
        let slow = WiredAdapter(interface: "en10", name: "Ethernet", service: "Ethernet", serviceEnabled: true, linked: true, speedMbps: 2500, duplex: .full, bestMbps: 10_000, hasAddress: true)
        let missing = WiredAdapter(interface: "en7", name: "USB LAN", linked: true, speedMbps: 1000, bestMbps: 1000)
        #expect(WiredReport(adapters: [slow, missing]).findings.map(\.level) == [.problem, .caution])
    }

    @MainActor @Test func noAddressWaitsForDHCP() async {
        let watch = WiredWatch()
        let start = Date()
        let stuck = WiredAdapter(interface: "en7", name: "USB LAN", service: "USB LAN", serviceEnabled: true, linked: true, speedMbps: 1000, duplex: .full, bestMbps: 1000, hasAddress: false)
        watch.apply(WiredReport(date: start, adapters: [stuck]))
        #expect(watch.findings.isEmpty)
        watch.apply(WiredReport(date: start.addingTimeInterval(25), adapters: [stuck]))
        #expect(watch.findings.map(\.kind) == [.noAddress])
        // Once it has an address, the clock starts over.
        var fixed = stuck; fixed.hasAddress = true
        watch.apply(WiredReport(date: start.addingTimeInterval(30), adapters: [fixed]))
        watch.apply(WiredReport(date: start.addingTimeInterval(35), adapters: [stuck]))
        #expect(watch.findings.isEmpty)
    }
}
