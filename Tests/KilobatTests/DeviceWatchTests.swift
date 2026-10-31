import Foundation
import Testing
@testable import KilobatCore

/// New-device alerts: learning a network, telling devices apart, private addresses, what gets a notification,
/// the CLI's arguments and the call report naming a device. Every address and name here is made up.
struct DeviceWatchTests {
    private let day0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let router = DeviceSighting(mac: "0:11:22:33:44:55", address: "10.0.0.1")
    private let tv = DeviceSighting(mac: "a4:5e:60:01:02:03", address: "10.0.0.20")
    private func home(_ book: inout DeviceBook) { book.setHome(true, network: "net", name: "Sample Home") }
    private func observe(_ book: inout DeviceBook, _ sightings: [DeviceSighting], at offset: TimeInterval) -> [KnownDevice] {
        book.observe(sightings, network: "net", name: "Sample Home", router: router.mac, vendor: { $0.hasPrefix("a4:5e:60") ? "Sample Maker" : nil }, now: day0.addingTimeInterval(offset))
    }

    @Test func readsMACAddressesAsArpPrintsThem() {
        #expect(MACAddress.normalized("0:1a:2B:3:4:5") == "00:1a:2b:03:04:05")
        #expect(MACAddress.normalized("00-1A-2B-03-04-05") == "00:1a:2b:03:04:05")
        #expect(MACAddress.normalized("00:1a:2b:03:04") == nil)
        #expect(MACAddress.normalized("00:1a:2b:03:04:zz") == nil)
        #expect(MACAddress.locallyAdministered("da:a1:19:00:00:01"))
        #expect(MACAddress.locallyAdministered("3a:00:00:00:00:01"))
        #expect(!MACAddress.locallyAdministered("a4:5e:60:01:02:03"))
        #expect(!MACAddress.unicast("ff:ff:ff:ff:ff:ff"))
        #expect(!MACAddress.unicast("01:00:5e:00:00:fb"))
        #expect(!MACAddress.unicast("0:0:0:0:0:0"))
        #expect(MACAddress.oui("a4:5e:60:01:02:03") == 0xA45E60)
    }

    @Test func theFirstScanOfAHomeNetworkLearnsEverythingSilently() {
        var book = DeviceBook(); home(&book)
        let newcomers = observe(&book, [router, tv], at: 0)
        #expect(newcomers.isEmpty)
        let net = book.networks["net"]
        #expect(net?.baseline == day0)
        #expect(net?.router == "00:11:22:33:44:55")
        #expect(net?.devices.count == 2)
        #expect(net?.devices.allSatisfy { $0.learned == true && $0.status == .known } == true)
        #expect(book.device(mac: tv.mac, network: "net")?.vendor == "Sample Maker")
    }

    @Test func aDeviceThatJoinsLaterIsNewOnce() {
        var book = DeviceBook(); home(&book)
        _ = observe(&book, [router, tv], at: 0)
        let laptop = DeviceSighting(mac: "f0:18:98:aa:bb:cc", address: "10.0.0.31", hostname: "Sample-Laptop.local.")
        let newcomers = observe(&book, [router, tv, laptop], at: 300)
        #expect(newcomers.map(\.mac) == ["f0:18:98:aa:bb:cc"])
        #expect(newcomers.first?.status == .new)
        #expect(newcomers.first?.label == "Sample-Laptop")
        #expect(observe(&book, [router, laptop], at: 600).isEmpty)
        #expect(book.device(mac: laptop.mac, network: "net")?.lastSeen == day0.addingTimeInterval(600))
    }

    @Test func aNetworkThatIsntHomeNeverAlerts() {
        var book = DeviceBook()
        _ = observe(&book, [router], at: 0)
        #expect(observe(&book, [router, tv], at: 300).isEmpty)
        #expect(book.networks["net"]?.baseline == nil)
        #expect(book.device(mac: tv.mac, network: "net")?.status == .known)
        // Marking it home later learns what came meanwhile instead of alerting about all of it.
        home(&book)
        #expect(observe(&book, [router, tv, DeviceSighting(mac: "f0:18:98:00:00:01", address: "10.0.0.40")], at: 600).isEmpty)
        #expect(observe(&book, [router, DeviceSighting(mac: "f0:18:98:00:00:02", address: "10.0.0.41")], at: 900).count == 1)
    }

    @Test func aRotatedPrivateAddressWithItsOwnNameIsTheSameDevice() {
        var book = DeviceBook(); home(&book)
        let before = DeviceSighting(mac: "da:a1:19:00:00:01", address: "10.0.0.50", hostname: "Sams-iPad.local.")
        _ = observe(&book, [router, before], at: 0)
        _ = book.rename(mac: before.mac, to: "Sam’s iPad", network: "net")
        let after = DeviceSighting(mac: "3e:22:91:00:00:02", address: "10.0.0.51", hostname: "Sams-iPad-2.local.")
        #expect(observe(&book, [router, after], at: 86_400).isEmpty)
        let device = book.device(mac: after.mac, network: "net")
        #expect(device?.name == "Sam’s iPad")
        #expect(device?.aliases == ["da:a1:19:00:00:01"])
        #expect(book.device(mac: before.mac, network: "net")?.mac == after.mac)
        #expect(book.networks["net"]?.devices.count == 2)
    }

    @Test func aGenericNameOrTwoDevicesAtOnceStayApart() {
        var book = DeviceBook(); home(&book)
        let phone = DeviceSighting(mac: "da:a1:19:00:00:01", address: "10.0.0.50", hostname: "iPhone.local.")
        _ = observe(&book, [router, phone], at: 0)
        // "iPhone" is every iPhone's name, so a new private address that uses it is a new device.
        #expect(observe(&book, [router, DeviceSighting(mac: "3e:22:91:00:00:02", address: "10.0.0.51", hostname: "iPhone.local.")], at: 300).count == 1)
        // The same specific name on two private addresses at the same time is two devices.
        let tablet = DeviceSighting(mac: "da:a1:19:00:00:09", address: "10.0.0.60", hostname: "Sample-Tab.lan")
        _ = observe(&book, [router, tablet], at: 600)
        #expect(observe(&book, [router, tablet, DeviceSighting(mac: "3e:22:91:00:00:09", address: "10.0.0.61", hostname: "Sample-Tab.lan")], at: 900).count == 1)
        // A maker-assigned address never takes over a private one's record.
        #expect(observe(&book, [router, DeviceSighting(mac: "f0:18:98:00:00:09", address: "10.0.0.62", hostname: "Sample-Tab.lan")], at: 1200).count == 1)
    }

    @Test func namesThatTellDevicesApart() {
        #expect(DeviceNames.readable("Ritas-iPad.local.") == "Ritas-iPad")
        #expect(DeviceNames.readable("living-room-tv.home.arpa") == "living-room-tv")
        #expect(DeviceNames.readable("10.0.0.5") == nil)
        #expect(DeviceNames.readable("fe80::1c2b:3d4e") == nil)
        #expect(DeviceNames.readable("  ") == nil)
        #expect(DeviceNames.stable("Ritas-iPad-2.local") == "ritas-ipad")
        #expect(DeviceNames.stable("Ritas iPad (3)") == "ritas-ipad")
        #expect(DeviceNames.stable("iPhone.local.") == nil)
        #expect(DeviceNames.stable("android") == nil)
        #expect(DeviceNames.stable("tv") == nil)
    }

    @Test func comingBackAfterAnHourIsAnArrival() {
        var book = DeviceBook(); home(&book)
        _ = observe(&book, [router, tv], at: 0)
        _ = observe(&book, [router], at: 300)
        _ = observe(&book, [router, tv], at: 1800)
        #expect(book.device(mac: tv.mac, network: "net")?.arrived == day0)
        _ = observe(&book, [router, tv], at: 1800 + 3700)
        #expect(book.device(mac: tv.mac, network: "net")?.arrived == day0.addingTimeInterval(5500))
        let window = book.arrivals(network: "net", from: day0.addingTimeInterval(5000), to: day0.addingTimeInterval(6000))
        #expect(window.map(\.mac) == [MACAddress.normalized(tv.mac)!])
        // The router, and what the first scan learned, never count as arrivals.
        #expect(book.arrivals(network: "net", from: day0.addingTimeInterval(-60), to: day0.addingTimeInterval(60)).isEmpty)
    }

    @Test func answersAndNames() {
        var book = DeviceBook(); home(&book)
        _ = observe(&book, [router], at: 0)
        _ = observe(&book, [router, tv], at: 300)
        #expect(book.device(mac: tv.mac, network: "net")?.status == .new)
        let changed1 = book.setVerdict(.unknown, mac: "A4-5E-60-01-02-03")
        #expect(changed1)
        #expect(book.device(mac: tv.mac, network: "net")?.status == .unknown)
        let changed2 = book.setVerdict(.ignored, mac: tv.mac, network: "net")
        #expect(changed2)
        #expect(book.device(mac: tv.mac, network: "net")?.status == .ignored)
        let changed3 = book.setVerdict(.mine, mac: tv.mac)
        #expect(changed3)
        #expect(book.device(mac: tv.mac, network: "net")?.status == .known)
        let changed4 = book.setVerdict(.mine, mac: "02:00:00:00:00:99")
        #expect(!changed4)
        let changed5 = book.rename(mac: tv.mac, to: "  Living room TV ")
        #expect(changed5)
        #expect(book.device(mac: tv.mac, network: "net")?.label == "Living room TV")
        #expect(book.device(mac: tv.mac, network: "net")?.callName == "Living room TV")
        _ = book.rename(mac: tv.mac, to: "")
        #expect(book.device(mac: tv.mac, network: "net")?.label == "Sample Maker device")
        #expect(book.network(router: "00:11:22:33:44:55") == "net")
        #expect(book.network(router: "00:11:22:33:44:56") == nil)
    }

    @Test func oneNotificationForOneDeviceAndOneForAFlood() {
        let device = KnownDevice(mac: "f0:18:98:00:00:01", address: "10.0.0.40", firstSeen: day0)
        #expect(DeviceAlert.decide([], allowed: true) == nil)
        #expect(DeviceAlert.decide([device], allowed: false) == nil)
        #expect(DeviceAlert.decide([device], allowed: true) == .one(device))
        var second = device; second.mac = "f0:18:98:00:00:02"
        #expect(DeviceAlert.decide([device, second], allowed: true) == .several(2))
        var told = device; told.alerted = day0
        #expect(DeviceAlert.decide([told], allowed: true) == nil)
        var answered = device; answered.verdict = .mine
        #expect(DeviceAlert.decide([answered, second], allowed: true) == .one(second))
        #expect(DeviceAlert.title(network: "Sample Home") == "A new device joined Sample Home")
        #expect(DeviceAlert.title(network: "Sample Home", count: 3) == "3 new devices joined Sample Home")
        #expect(DeviceAlert.body(device).hasPrefix("Unnamed device · 10.0.0.40 · first seen"))
    }

    @Test func parsesTheDevicesCommand() throws {
        #expect(try DeviceCommand.parse(["devices"]) == .list(all: false, bonjour: false, json: false))
        #expect(try DeviceCommand.parse(["devices", "--all", "--json"]) == .list(all: true, bonjour: false, json: true))
        #expect(try DeviceCommand.parse(["devices", "name", "A4:5E:60:1:2:3", "Living", "room", "TV", "--json"]) == .name(mac: "a4:5e:60:01:02:03", name: "Living room TV"))
        #expect(try DeviceCommand.parse(["devices", "name", "a4:5e:60:01:02:03", ""]) == .name(mac: "a4:5e:60:01:02:03", name: ""))
        #expect(try DeviceCommand.parse(["devices", "mark", "a4:5e:60:01:02:03", "Mine"]) == .mark(mac: "a4:5e:60:01:02:03", verdict: .mine))
        #expect(try DeviceCommand.parse(["devices", "mark", "a4:5e:60:01:02:03", "unknown", "--json"]) == .mark(mac: "a4:5e:60:01:02:03", verdict: .unknown))
        #expect(throws: DiagnosticError.self) { try DeviceCommand.parse(["devices", "mark", "a4:5e:60:01:02:03", "yes"]) }
        #expect(throws: DiagnosticError.self) { try DeviceCommand.parse(["devices", "mark", "not-a-mac", "mine"]) }
        #expect(throws: DiagnosticError.self) { try DeviceCommand.parse(["devices", "name", "a4:5e:60:01:02:03"]) }
        #expect(throws: DiagnosticError.self) { try DeviceCommand.parse(["devices", "--everything"]) }
    }

    @Test func theListingAddsWhatKilobatRemembers() throws {
        var book = DeviceBook(); home(&book)
        _ = observe(&book, [router], at: 0)
        _ = observe(&book, [router, tv], at: 300)
        let live = try JSONDecoder().decode([LANDevice].self, from: Data(#"[{"address":"10.0.0.1","mac":"0:11:22:33:44:55","interface":"en0","name":"10.0.0.1"},{"address":"10.0.0.99","mac":"2:0:0:0:0:7","interface":"en0","name":"10.0.0.99"}]"#.utf8))
        let rows = DeviceListing.rows(live: live, network: book.networks["net"], names: ["02:00:00:00:00:07": "Sample Plug"])
        #expect(rows.count == 2)
        #expect(rows[0].mac == "00:11:22:33:44:55" && rows[0].status == .known && rows[0].present)
        #expect(rows[1].name == "Sample Plug" && rows[1].status == nil && rows[1].privateAddress)
        let everything = DeviceListing.rows(live: live, network: book.networks["net"], names: [:], all: true)
        #expect(everything.count == 3)
        #expect(everything.last?.status == .new && everything.last?.present == false && everything.last?.vendor == "Sample Maker")
    }

    @Test func sweepsOnlyTheMacsOwnPrivateSubnet() {
        let address: UInt32 = 0xC0A8_0117 // 192.168.1.23
        let hosts = LANScan.hosts(address: address, mask: 0xFFFF_FF00)
        #expect(hosts.count == 253)
        #expect(hosts.first == "192.168.1.1" && hosts.last == "192.168.1.254" && !hosts.contains("192.168.1.23"))
        // A /16 is swept only in the /24 around the Mac.
        #expect(LANScan.hosts(address: 0x0A00_0505, mask: 0xFFFF_0000).count == 253)
        #expect(LANScan.hosts(address: 0xAC10_0002, mask: 0xFFFF_FFF0).count == 13)
        // Never a public address, nor a point-to-point link.
        #expect(LANScan.hosts(address: 0x0808_0808, mask: 0xFFFF_FF00).isEmpty)
        #expect(LANScan.hosts(address: address, mask: 0xFFFF_FFFF).isEmpty)
    }

    @Test func sightingsLeaveOutThisMacAndBroadcasts() throws {
        let rows = try JSONDecoder().decode([LANDevice].self, from: Data(#"""
        [{"address":"10.0.0.1","mac":"0:11:22:33:44:55","interface":"en0","name":"x"},
         {"address":"10.0.0.255","mac":"ff:ff:ff:ff:ff:ff","interface":"en0","name":"x"},
         {"address":"224.0.0.251","mac":"1:0:5e:0:0:fb","interface":"en0","name":"x"},
         {"address":"10.0.0.7","mac":"3c:22:fb:0:0:1","interface":"en0","name":"x"},
         {"address":"172.16.0.3","mac":"a4:5e:60:1:2:3","interface":"bridge100","name":"x"}]
        """#.utf8))
        let sightings = LANScan.sightings(rows, interface: "en0", own: ["3c:22:fb:00:00:01"])
        #expect(sightings == [DeviceSighting(mac: "00:11:22:33:44:55", address: "10.0.0.1")])
    }

    @Test func looksUpTheMakerInThePackedTable() throws {
        var raw = Data("KBOUI1".utf8)
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { raw.append(contentsOf: $0) } }
        let names = ["Sample Maker", "Other Maker"]
        u32(UInt32(names.count)); u32(2)
        for name in names { raw.append(UInt8(name.utf8.count)); raw.append(contentsOf: Array(name.utf8)) }
        raw.append(contentsOf: [0x00, 0x11, 0x22, 1, 0]); raw.append(contentsOf: [0xA4, 0x5E, 0x60, 0, 0])
        let packed = try (raw as NSData).compressed(using: .zlib) as Data
        let vendors = DeviceVendors(packed: packed)
        #expect(vendors.available)
        #expect(vendors.vendor(for: "a4:5e:60:01:02:03") == "Sample Maker")
        #expect(vendors.vendor(for: "0:11:22:33:44:55") == "Other Maker")
        #expect(vendors.vendor(for: "a4:5e:61:01:02:03") == nil)
        // A private address has no maker, whatever its first bytes.
        #expect(vendors.vendor(for: "a6:5e:60:01:02:03") == nil)
        #expect(DeviceVendors.unpack(Data("KBOUI1".utf8)) == nil)
    }

    @MainActor @Test func theRegistryKeepsAnswersOnDiskAndRereadsTheCLIsChanges() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-devices-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = DeviceRegistry(directory: folder)
        app.setHome(true, network: "net", name: "Sample Home")
        app.observe([router], network: "net", name: "Sample Home", vendor: { _ in nil }, now: day0)
        let newcomers = app.observe([router, tv], network: "net", name: "Sample Home", vendor: { _ in nil }, now: day0.addingTimeInterval(300))
        #expect(newcomers.count == 1)
        // The CLI, a separate process, answers for it.
        let cli = DeviceRegistry(directory: folder)
        #expect(cli.isHome("net"))
        #expect(cli.setVerdict(.mine, mac: tv.mac))
        // Modification dates can match within a filesystem's granularity; make the change visible.
        let file = folder.appendingPathComponent("devices.json")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        app.reload()
        #expect(app.device(mac: tv.mac, network: "net")?.verdict == .mine)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func aFreezeNamesTheOneDeviceThatJustJoined() {
        func pings(_ values: [Double?]) -> [CallSamples.Ping] { values.enumerated().map { .init(at: Double($0.offset), ms: $0.element) } }
        var samples = CallSamples()
        samples.internet = pings(Array(repeating: 30, count: 100) + [nil, 600, nil] + Array(repeating: 30, count: 100))
        samples.router = pings(Array(repeating: 3, count: 203))
        samples.household = [.init(at: 95, upload: 20_000, download: 4_000_000)]
        samples.arrivals = [.init(at: -120, name: "Rita’s iPad")]
        func report() -> CallReport { CallAnalysis.report(app: "Zoom", browser: false, start: day0, end: day0.addingTimeInterval(600), network: nil, samples: samples) }
        #expect(report().verdict == "1 freezes, caused by Rita’s iPad downloading")
        #expect(report().advice?.hasPrefix("Rita’s iPad joined your network just before the freeze") == true)
        // Two devices joining, one that joined long before, or one Kilobat knows nothing about: the generic wording.
        samples.arrivals = [.init(at: -120, name: "Rita’s iPad"), .init(at: 30, name: "Sample TV")]
        #expect(report().verdict == "1 freezes, caused by another device on your network downloading")
        samples.arrivals = [.init(at: -900, name: "Rita’s iPad")]
        #expect(report().verdict == "1 freezes, caused by another device on your network downloading")
        samples.arrivals = [.init(at: 10, name: nil)]
        #expect(report().verdict == "1 freezes, caused by another device on your network downloading")
        // Without the router seeing another device busy, a device joining is no evidence.
        samples.arrivals = [.init(at: -120, name: "Rita’s iPad")]
        samples.household = nil
        #expect(report().freezes.first?.cause.kind == .beyondRouter)
    }
}
