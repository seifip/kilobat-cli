import Foundation
import Testing
@testable import KilobatCore

/// Device types: reading them from Bonjour, UPnP, names and makers, how sure each reading is, the person's override,
/// the CLI's and MCP's fields, the alert's wording, and camera upload with and without a router's counters. Every
/// address, name and model here is made up or a public model name.
struct DeviceTypeTests {
    private let day0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func txt(_ pairs: [String: String]) -> [String: Data] { pairs.mapValues { Data($0.utf8) } }
    private func service(_ type: String, _ txt: [String: String] = [:], address: String = "10.0.0.40") -> BonjourService {
        BonjourService(type: type, name: "Sample", host: "sample.local.", port: 80, addresses: [address], txt: self.txt(txt))
    }
    private func classify(_ services: [BonjourService] = [], upnp: UPnPDescription? = nil, targets: [String] = [], vendor: String? = nil, hostname: String? = nil) -> DeviceGuess {
        DeviceClassifier.classify(signals: DeviceSignals.from(services: services, upnp: upnp, targets: targets), vendor: vendor, hostname: hostname)
    }

    // MARK: Signals

    @Test func aHomeKitCategoryIsSureAndTagged() {
        let camera = classify([service("_hap._tcp", ["ci": "17", "md": "Sample Cam"])], vendor: "Wyze Labs")
        #expect(camera.type == .camera)
        #expect(camera.confidence == .high)
        #expect(camera.label == "Camera (Wyze)")
        #expect(DeviceSignals.from(services: [service("_hap._tcp", ["ci": "17"])])?.tags == [.homeKit])
        #expect(classify([service("_hap._tcp", ["ci": "18"])]).type == .doorbell)
        #expect(classify([service("_hap._tcp", ["ci": "2"])]).type == .hub)
        #expect(classify([service("_hap._tcp", ["ci": "7"])]).type == .plug)
        // A lightbulb is HomeKit but none of the types.
        #expect(classify([service("_hap._tcp", ["ci": "5"])]).type == .unknown)
    }

    @Test func castReceiversAreCastingDevicesSpeakersOrTVs() {
        #expect(classify([service("_googlecast._tcp", ["md": "Chromecast", "ca": "201221", "fn": "Living room"])]).type == .casting)
        let mini = classify([service("_googlecast._tcp", ["md": "Google Nest Mini", "ca": "199172"])])
        #expect(mini.type == .speaker && mini.confidence == .high && mini.brand == "Google")
        // Audio out without video out, and no model Kilobat knows.
        #expect(classify([service("_googlecast._tcp", ["md": "Sample Speaker", "ca": "4"])]).type == .speaker)
        #expect(classify([service("_googlecast._tcp", ["md": "BRAVIA 4K VH2", "ca": "4101"])]).type == .tv)
        // A speaker group is announced by one member and says nothing about it.
        #expect(DeviceSignals.from(services: [service("_googlecast._tcp", ["md": "Google Cast Group", "ca": "4132"])]) == nil)
        #expect(classify([service("_googlecast._tcp", ["md": "Google Cast Group", "ca": "4132"])]) == .unknown)
        // The friendly name the person gave it is never kept.
        let signals = DeviceSignals.from(services: [service("_googlecast._tcp", ["md": "Chromecast", "fn": "Rita’s room"])])
        #expect(signals?.models == ["Chromecast"])
        #expect(String(decoding: try! JSONEncoder().encode(signals), as: UTF8.self).contains("Rita") == false)
    }

    @Test func appleModelIdentifiersSayExactlyWhatItIs() {
        #expect(classify([service("_airplay._tcp", ["model": "AppleTV14,1"])]).label == "TV or streaming stick (Apple)")
        #expect(classify([service("_airplay._tcp", ["model": "AudioAccessory6,1"])]).type == .speaker)
        #expect(classify([service("_companion-link._tcp", ["rpMd": "iPhone15,2"])]).type == .phone)
        #expect(classify([service("_device-info._tcp", ["model": "MacBookPro18,3"])]).type == .computer)
        // Samba on a NAS calls itself an Xserve: a hint, not proof.
        let nas = classify([service("_device-info._tcp", ["model": "Xserve"])])
        #expect(nas.type == .nas && nas.confidence == .medium)
    }

    @Test func aMacSharingAPrinterStaysAComputer() {
        let shared = classify([service("_ipp._tcp", ["ty": "Brother HL-L2350DW series"]), service("_device-info._tcp", ["model": "Mac14,2"])])
        #expect(shared.type == .computer)
        let printer = classify([service("_ipp._tcp", ["ty": "Brother HL-L2350DW series"])], vendor: "Brother Industries")
        #expect(printer.type == .printer && printer.confidence == .high && printer.brand == "Brother")
    }

    @Test func matterAndThreadAreTagged() {
        let plug = classify([service("_matterc._udp", ["DT": "266", "VP": "4874+77"])])
        #expect(plug.type == .plug && plug.confidence == .high)
        #expect(DeviceSignals.from(services: [service("_matter._tcp")])?.tags == [.matter])
        let homePod = DeviceSignals.from(services: [service("_meshcop._udp", ["nn": "Sample-Thread", "vn": "Apple Inc.", "mn": "HomePod"]), service("_airplay._tcp", ["model": "AudioAccessory5,1"])])
        #expect(homePod?.tags == [.threadBorderRouter])
        #expect(DeviceClassifier.classify(signals: homePod, vendor: nil, hostname: nil).type == .speaker)
    }

    @Test func threadBorderAgentsReadTheirBinaryFields() {
        var meshcop = service("_meshcop._udp", ["nn": "Sample-Thread", "vn": "Google Inc.", "mn": "Nest Hub", "tv": "1.3.0"])
        meshcop.txt["xp"] = Data([0xde, 0xad, 0x00, 0xbe, 0xef, 0x00, 0xca, 0xfe])
        let agent = ThreadBorderAgent(meshcop)
        #expect(agent?.networkName == "Sample-Thread")
        #expect(agent?.extendedPANID == "dead00beef00cafe")
        #expect(agent?.model == "Nest Hub" && agent?.threadVersion == "1.3.0")
        #expect(agent?.addresses == ["10.0.0.40"])
        #expect(ThreadBorderAgent(service("_hap._tcp")) == nil)
    }

    @Test func parsesTXTRecords() {
        let data = BonjourTXT.encode([("MD", Data("Chromecast".utf8)), ("md", Data("second".utf8)), ("xp", Data([0, 1, 2, 61]))]) + Data([4]) + Data("flag".utf8) + Data([9, 0x61])
        let parsed = BonjourTXT.parse(data)
        #expect(parsed["md"] == Data("Chromecast".utf8))
        #expect(parsed["xp"] == Data([0, 1, 2, 61]))
        #expect(parsed["flag"] == Data())
        #expect(parsed.count == 3)
        #expect(BonjourTXT.parse(Data()) == [:])
        #expect(BonjourBrowse.normalized("_GoogleCast._tcp.local.") == "_googlecast._tcp")
        let byAddress = BonjourBrowse.byAddress([service("_sonos._tcp", address: "10.0.0.7"), service("_airplay._tcp", address: "10.0.0.7")])
        #expect(byAddress["10.0.0.7"]?.count == 2)
    }

    @Test func readsUPnPDescriptionsAndSSDPReplies() {
        let xml = """
        <?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device>
        <deviceType>urn:schemas-upnp-org:device:ZonePlayer:1</deviceType><friendlyName>Kitchen</friendlyName>
        <manufacturer>Sonos, Inc.</manufacturer><modelName>Sonos One</modelName>
        <deviceList><device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType><modelName>Nested</modelName></device></deviceList>
        </device></root>
        """
        let description = UPnPDescription.parse(Data(xml.utf8))
        #expect(description == UPnPDescription(deviceType: "urn:schemas-upnp-org:device:ZonePlayer:1", manufacturer: "Sonos, Inc.", modelName: "Sonos One"))
        #expect(description?.shortType == "ZonePlayer")
        #expect(classify(upnp: description).label == "Speaker (Sonos)")
        #expect(UPnPDescription.parse(Data("not xml".utf8)) == nil)
        let reply = SSDPDiscovery.parse("HTTP/1.1 200 OK\r\nST: roku:ecp\r\nLOCATION: http://10.0.0.9:8060/\r\n\r\n", from: "10.0.0.9")
        #expect(reply == SSDPDiscovery.Reply(address: "10.0.0.9", location: "http://10.0.0.9:8060/", target: "roku:ecp"))
        #expect(classify(targets: ["roku:ecp"]).label == "TV or streaming stick (Roku)")
    }

    @Test func deviceDescriptionsRejectNonLocalOrMismatchedLocations() async {
        for (location, address) in [
            ("https://example.com/device.xml", "10.0.0.9"),
            ("http://10.0.0.8/device.xml", "10.0.0.9"),
            ("file:///tmp/device.xml", "10.0.0.9"),
            ("http://user:password@10.0.0.9/device.xml", "10.0.0.9"),
            ("http://203.0.113.9/device.xml", "203.0.113.9")
        ] {
            #expect(await SSDPDiscovery.describe(location, address: address) == nil)
        }
    }

    // MARK: Names and makers

    @Test func makersAloneNeverClaimMoreThanProbably() {
        let wyze = classify(vendor: "Wyze Labs")
        #expect(wyze.type == .camera && wyze.confidence == .medium)
        #expect(wyze.label == "Probably a camera (Wyze)")
        #expect(classify(vendor: "Espressif").label == "Maybe a smart plug or switch (Espressif)")
        #expect(classify(vendor: "SZ DJI TECHNOLOGY CO.,LTD").label == "Probably a drone or action camera (DJI)")
        #expect(classify(vendor: "Arashi Vision").brand == "Insta360")
        #expect(classify(vendor: "Synology").type == .nas)
        // Makers of everything say nothing about the type.
        #expect(classify(vendor: "Apple") == .unknown)
        #expect(classify(vendor: "Amazon Technologies") == .unknown)
        #expect(classify().label == "Unknown type")
        // "Ring" exactly, not every maker whose name starts with it.
        #expect(classify(vendor: "RingCube").type == .unknown)
    }

    @Test func namesItGoesBy() {
        let ipad = classify(hostname: "Ritas-iPad.local.")
        #expect(ipad.type == .phone && ipad.confidence == .medium && ipad.brand == "Apple")
        #expect(classify(hostname: "DESKTOP-AB12CDE").type == .computer)
        #expect(classify(hostname: "WYZE_CAKP2JFUS").label == "Probably a camera (Wyze)")
        #expect(classify(hostname: "RingDoorbell-5a").type == .doorbell)
        #expect(classify(hostname: "BRN3C2AF4112233").type == .printer)
        #expect(classify(hostname: "Living-Room-TV").confidence == .low)
        #expect(classify(hostname: "Sample-Mac-mini").type == .computer)
        #expect(classify(hostname: "PS5-123").type == .console)
        #expect(classify(hostname: "dji-mini-4-pro").type == .drone)
    }

    @Test func disagreementLowersTheConfidence() {
        // A camera maker's address on something that calls itself a TV: neither wins outright.
        let guess = classify(vendor: "Wyze Labs", hostname: "Sample-Roku")
        #expect(guess.confidence == .low)
        // A declared type beats a maker's guess without being lowered.
        #expect(classify([service("_sonos._tcp")], vendor: "Wyze Labs").confidence == .high)
        // Related types agree: a doorbell is a camera.
        #expect(classify(vendor: "Ring", hostname: "RingDoorbell-5a").confidence == .medium)
    }

    @Test func theGatewayIsARouter() {
        let guess = DeviceClassifier.classify(signals: nil, vendor: "eero", hostname: nil, router: true)
        #expect(guess.label == "Router or mesh node (eero)")
    }

    // MARK: The device book

    private let router = DeviceSighting(mac: "0:11:22:33:44:55", address: "10.0.0.1")
    private func cameraSighting(_ last: String = "01", signals: DeviceSignals? = nil) -> DeviceSighting {
        DeviceSighting(mac: "7c:78:b2:00:00:\(last)", address: "10.0.0.\(Int(last, radix: 16)! + 50)", signals: signals)
    }
    private func book(_ sightings: [DeviceSighting], watching: Bool = true) -> DeviceBook {
        var book = DeviceBook()
        book.setHome(true, network: "net", name: "Sample Home")
        if watching { book.observe([router], network: "net", name: "Sample Home", router: router.mac, now: day0) }
        book.observe(sightings, network: "net", name: "Sample Home", router: router.mac, vendor: { $0.hasPrefix("7c:78:b2") ? "Wyze Labs" : nil }, now: day0.addingTimeInterval(300))
        return book
    }

    @Test func signalsAreKeptAndMergedOverScans() {
        let hap = DeviceSignals(services: ["_hap._tcp"], homeKitCategory: 17)
        var book = book([cameraSighting(signals: hap)])
        #expect(book.device(mac: "7c:78:b2:00:00:01", network: "net")?.guess().confidence == .high)
        // A later scan that hears something else adds to it; one that hears nothing keeps it.
        book.observe([cameraSighting(signals: DeviceSignals(services: ["_rtsp._tcp"]))], network: "net", name: "Sample Home", now: day0.addingTimeInterval(600))
        book.observe([cameraSighting()], network: "net", name: "Sample Home", now: day0.addingTimeInterval(900))
        let device = book.device(mac: "7c:78:b2:00:00:01", network: "net")
        #expect(device?.signals?.services == ["_hap._tcp", "_rtsp._tcp"])
        #expect(device?.signals?.homeKitCategory == 17)
        #expect(device?.tags == [.homeKit])
        #expect(DeviceSignals.merge(nil, DeviceSignals()) == nil)
    }

    @Test func thePersonsTypeWins() {
        var book = book([cameraSighting()])
        let set = book.setType(.plug, mac: "7c:78:b2:00:00:01", network: "net")
        #expect(set)
        let device = book.device(mac: "7c:78:b2:00:00:01", network: "net")!
        #expect(device.guess().type == .plug && device.guess().confidence == .set)
        #expect(device.guess().label == "Smart plug or switch")
        book.setType(.doorbell, mac: "7c:78:b2:00:00:01", network: "net")
        #expect(book.device(mac: "7c:78:b2:00:00:01", network: "net")?.guess().label == "Doorbell (Wyze)")
        // A person can suppress an incorrect camera guess by explicitly choosing Unknown type.
        book.setType(.unknown, mac: "7c:78:b2:00:00:01", network: "net")
        let unknown = book.device(mac: "7c:78:b2:00:00:01", network: "net")!
        #expect(unknown.guess().type == .unknown && unknown.guess().confidence == .set)
        #expect(CameraUpload.cameras([unknown]).isEmpty)
        book.setType(nil, mac: "7c:78:b2:00:00:01", network: "net")
        #expect(book.device(mac: "7c:78:b2:00:00:01", network: "net")?.guess().confidence == .medium)
        let missing = book.setType(.tv, mac: "aa:bb:cc:dd:ee:ff", network: "net")
        #expect(!missing)
    }

    @Test func alertsNameTheTypeOnlyWhenSure() {
        var sure = KnownDevice(mac: "7c:78:b2:00:00:01", vendor: "Wyze Labs", address: "10.0.0.51", firstSeen: day0)
        sure.signals = DeviceSignals(services: ["_hap._tcp"], homeKitCategory: 17)
        #expect(DeviceAlert.title(network: "Sample Home", device: sure) == "A new Wyze camera joined Sample Home")
        #expect(sure.callName == "a new Wyze camera")
        // The title said what it is; "Wyze Labs device" would only repeat it.
        #expect(DeviceAlert.body(sure).hasPrefix("10.0.0.51 · first seen"))
        let probable = KnownDevice(mac: "7c:78:b2:00:00:02", vendor: "Wyze Labs", address: "10.0.0.52", firstSeen: day0)
        #expect(DeviceAlert.title(network: "Sample Home", device: probable) == "A new device joined Sample Home")
        #expect(DeviceAlert.body(probable).hasPrefix("Probably a camera (Wyze) · 10.0.0.52"))
        // A device with its own name keeps it, with the guess after.
        let named = KnownDevice(mac: "7c:78:b2:00:00:03", hostname: "Porch.local.", vendor: "Wyze Labs", address: "10.0.0.53", firstSeen: day0)
        #expect(DeviceAlert.body(named).hasPrefix("Porch · Probably a camera (Wyze) · "))
        #expect(probable.callName == "a new Wyze Labs device")
    }

    @Test func theCLIParsesTypes() throws {
        #expect(try DeviceCommand.parse(["devices", "type", "7C:78:B2:0:0:1", "camera"]) == .type(mac: "7c:78:b2:00:00:01", type: .camera))
        #expect(try DeviceCommand.parse(["devices", "type", "7c:78:b2:00:00:01", "smart-plug", "--json"]) == .type(mac: "7c:78:b2:00:00:01", type: .plug))
        #expect(try DeviceCommand.parse(["devices", "type", "7c:78:b2:00:00:01", "auto"]) == .type(mac: "7c:78:b2:00:00:01", type: nil))
        #expect(throws: DiagnosticError.self) { try DeviceCommand.parse(["devices", "type", "7c:78:b2:00:00:01", "toaster"]) }
        #expect(throws: DiagnosticError.self) { try DeviceCommand.parse(["devices", "type", "7c:78:b2:00:00:01"]) }
        #expect(DeviceType.parse("Chromecast") == .casting)
        #expect(DeviceType.parse("unknown") == .unknown)
    }

    @Test func listingsCarryTypeAndConfidence() throws {
        var book = book([cameraSighting()])
        book.setType(nil, mac: "7c:78:b2:00:00:01", network: "net")
        let live = [LANDevice(address: "10.0.0.51", mac: "7c:78:b2:0:0:1", interface: "en0", name: "10.0.0.51"),
                    LANDevice(address: "10.0.0.1", mac: "0:11:22:33:44:55", interface: "en0", name: "10.0.0.1"),
                    LANDevice(address: "10.0.0.99", mac: "a4:5e:60:9:9:9", interface: "en0", name: "10.0.0.99")]
        let rows = DeviceListing.rows(live: live, network: book.networks["net"], names: [:])
        #expect(rows[0].type == .camera && rows[0].confidence == .medium && rows[0].typeLabel == "Probably a camera (Wyze)")
        #expect(rows[1].type == .router && rows[1].confidence == .high)
        #expect(rows[2].type == .unknown && rows[2].confidence == nil)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let json = try JSONSerialization.jsonObject(with: encoder.encode(rows[0])) as? [String: Any]
        #expect(json?["type"] as? String == "camera")
        #expect(json?["confidence"] as? String == "medium")
        #expect(json?["tags"] as? [String] == [])
    }

    // MARK: Camera upload

    private func cameras(_ count: Int) -> [KnownDevice] {
        (1...count).map { index in
            var device = KnownDevice(mac: "7c:78:b2:00:00:0\(index)", vendor: "Wyze Labs", firstSeen: day0)
            device.name = "Cam \(index)"
            return device
        }
    }

    @Test func findsTheCamerasButNotWeakHintsOrIgnoredOnes() {
        var devices = cameras(2)
        devices.append(KnownDevice(mac: "24:0a:c4:00:00:01", vendor: "Espressif", firstSeen: day0))
        devices[1].verdict = .ignored
        var doorbell = KnownDevice(mac: "a8:00:00:00:00:01", firstSeen: day0)
        doorbell.userType = .doorbell
        devices.append(doorbell)
        #expect(CameraUpload.cameras(devices).map(\.mac) == ["7c:78:b2:00:00:01", "a8:00:00:00:00:01"])
    }

    @Test func withARoutersCountersItSaysWhatTheCamerasSent() {
        let start = day0, end = day0.addingTimeInterval(7 * 86_400)
        let usage = DeviceUsageWindow(start: start, end: end, devices: [
            .init(mac: "7c:78:b2:00:00:01", sent: 20_000_000_000, received: 1_000_000_000),
            .init(mac: "7C:78:B2:0:0:2", sent: 15_000_000_000, received: 1_000_000_000),
            .init(mac: "7c:78:b2:00:00:03", sent: 6_000_000_000, received: 1_000_000_000),
            .init(mac: "f0:18:98:00:00:01", sent: 27_000_000_000, received: 90_000_000_000),
        ], totalSent: 68_333_333_333, source: "OpenWrt nlbwmon")
        let measured = CameraUpload.measured(cameras: cameras(3), usage: usage)
        #expect(measured?.cameras == 3)
        #expect(measured?.sent == 41_000_000_000)
        #expect(measured?.top?.name == "Cam 1")
        #expect(CameraUpload.sentence(measured!) == "Your 3 cameras sent 41 GB this week, 60% of your upload (OpenWrt nlbwmon’s counters).")
        let note = CameraUploadNote.make(cameras: cameras(3), usage: usage)
        #expect(note?.measured == true)
        // A partial client list is not a whole-home total.
        let partial = DeviceUsageWindow(start: start, end: start.addingTimeInterval(3600), devices: [.init(mac: "7c:78:b2:00:00:01", sent: 500_000_000, received: 0)], source: "UniFi")
        #expect(CameraUpload.sentence(CameraUpload.measured(cameras: cameras(1), usage: partial)!) == "Your camera sent 500 MB today (UniFi’s counters).")
        // A window without any of the cameras falls back to the makers' figures.
        let others = DeviceUsageWindow(start: start, end: end, devices: [.init(mac: "f0:18:98:00:00:01", sent: 1, received: 1)], source: "UniFi")
        #expect(CameraUploadNote.make(cameras: cameras(1), usage: others)?.measured == false)
    }

    @Test func cameraShareNeedsAConsistentWholeHomeTotal() {
        func window(total: UInt64?) -> DeviceUsageWindow {
            DeviceUsageWindow(start: day0, end: day0.addingTimeInterval(3600), devices: [
                .init(mac: "7c:78:b2:00:00:01", sent: 500, received: 0)
            ], totalSent: total, source: "Sample internet counters")
        }
        #expect(CameraUpload.measured(cameras: cameras(1), usage: window(total: nil))?.share == nil)
        #expect(CameraUpload.measured(cameras: cameras(1), usage: window(total: 0))?.share == nil)
        #expect(CameraUpload.measured(cameras: cameras(1), usage: window(total: 100))?.share == nil)
        #expect(CameraUpload.measured(cameras: cameras(1), usage: window(total: 1000))?.share == 0.5)
        // Whole-home-only sources have no per-client observations: never attribute any to cameras.
        let wholeHomeOnly = DeviceUsageWindow(start: day0, end: day0.addingTimeInterval(3600), devices: [], totalSent: 1000, source: "FRITZ!Box")
        #expect(CameraUploadNote.make(cameras: cameras(1), usage: wholeHomeOnly)?.measured == false)
    }

    @Test func invalidCameraCountersDoNotProduceMeasurements() {
        let camera = cameras(1)
        let duplicate = DeviceUsageWindow(start: day0, end: day0.addingTimeInterval(3600), devices: [
            .init(mac: camera[0].mac, sent: 500, received: 0), .init(mac: camera[0].mac, sent: 500, received: 0)
        ], source: "Sample counters")
        #expect(CameraUpload.measured(cameras: camera, usage: duplicate) == nil)
        let reversed = DeviceUsageWindow(start: day0, end: day0.addingTimeInterval(-3600), devices: [
            .init(mac: camera[0].mac, sent: 500, received: 0)
        ], source: "Sample counters")
        #expect(CameraUpload.measured(cameras: camera, usage: reversed) == nil)
        let overflow = DeviceUsageWindow(start: day0, end: day0.addingTimeInterval(3600), devices: [
            .init(mac: "7c:78:b2:00:00:01", sent: UInt64.max, received: 0),
            .init(mac: "7c:78:b2:00:00:02", sent: 1, received: 0)
        ], source: "Sample counters")
        #expect(CameraUpload.measured(cameras: cameras(2), usage: overflow) == nil)
    }

    @Test @MainActor func cameraUsageRequestsStayOnTheNamedNetworkAndWindow() {
        let previous = DeviceUsage.provider
        defer { DeviceUsage.provider = previous }
        var requested: [String] = []
        let end = day0.addingTimeInterval(3600)
        DeviceUsage.provider = { network, start, end in
            requested.append(network)
            guard network == "sample-home" else { return nil }
            return DeviceUsageWindow(start: start, end: end, devices: [
                .init(mac: "02:00:00:00:00:01", sent: 500, received: 0)
            ], source: "Sample internet counters")
        }
        #expect(DeviceUsage.window(network: "sample-home", from: day0, to: end) != nil)
        #expect(DeviceUsage.window(network: "another-home", from: day0, to: end) == nil)
        #expect(DeviceUsage.window(network: "unknown", from: day0, to: end) == nil)
        #expect(requested == ["sample-home", "another-home"])
        DeviceUsage.provider = { _, start, end in
            DeviceUsageWindow(start: start.addingTimeInterval(-1), end: end, devices: [], source: "Stale window")
        }
        #expect(DeviceUsage.window(network: "sample-home", from: day0, to: end) == nil)
    }

    @Test func withoutARouterItOnlyQuotesTheMakers() {
        let note = CameraUploadNote.make(cameras: cameras(3), usage: nil)
        #expect(note?.measured == false)
        #expect(note?.text.contains("Kilobat sees 3 cameras on this network.") == true)
        #expect(note?.text.contains("Ring: 1 Mbps at 720p") == true)
        #expect(note?.text.contains("can’t measure them") == true)
        #expect(note?.text.contains(" sent ") == false)
        // A brand Kilobat has a figure for gets only its own.
        var ring = KnownDevice(mac: "34:3e:a4:00:00:01", vendor: "Ring", firstSeen: day0)
        ring.name = "Porch"
        let ringNote = CameraUpload.estimateNote(cameras: [ring])
        #expect(ringNote.contains("Ring:") && !ringNote.contains("Google Nest:"))
        #expect(CameraUploadNote.make(cameras: [], usage: nil) == nil)
        #expect(CameraUpload.figures.allSatisfy { $0.source.scheme == "https" })
    }

    private func speed(uploadPing: Double, at date: Date) -> SpeedTestResult {
        SpeedTestResult(date: date, downloadMbps: 200, uploadMbps: 10, baseline: PingResult(host: "1.1.1.1", samples: [20, 21, 19, 20], lossPercent: 0),
                        downloadLoaded: PingResult(host: "1.1.1.1", samples: [30, 32], lossPercent: 0), uploadLoaded: PingResult(host: "1.1.1.1", samples: [uploadPing, uploadPing], lossPercent: 0),
                        downloadSeconds: 8, uploadSeconds: 8, transferredBytes: 1)
    }

    @Test func healthMentionsCamerasWhenTheUploadBacksUp() {
        let now = day0.addingTimeInterval(3600)
        #expect(speed(uploadPing: 120, at: day0).uploadCongested)
        #expect(!speed(uploadPing: 40, at: day0).uploadCongested)
        #expect(CameraUpload.healthNote(speed: speed(uploadPing: 120, at: day0), cameras: cameras(2), usage: nil, now: now)
                == "2 cameras here may be part of it: makers publish about 1–4 Mbps of upload for each HD camera.")
        #expect(CameraUpload.healthNote(speed: speed(uploadPing: 40, at: day0), cameras: cameras(2), usage: nil, now: now) == nil)
        #expect(CameraUpload.healthNote(speed: speed(uploadPing: 120, at: day0), cameras: [], usage: nil, now: now) == nil)
        // A day-old test isn't news.
        #expect(CameraUpload.healthNote(speed: speed(uploadPing: 120, at: day0), cameras: cameras(2), usage: nil, now: day0.addingTimeInterval(90_000)) == nil)
    }

    @Test func aCallFrozenByAnotherDevicesUploadMentionsTheCameras() {
        func pings(_ values: [Double?]) -> [CallSamples.Ping] { values.enumerated().map { .init(at: Double($0.offset), ms: $0.element) } }
        var samples = CallSamples()
        samples.internet = pings(Array(repeating: 30, count: 100) + [nil, 600, nil] + Array(repeating: 30, count: 100))
        samples.router = pings(Array(repeating: 3, count: 203))
        samples.household = [.init(at: 95, upload: 900_000, download: 10_000)]
        samples.cameras = cameras(2)
        let card = CallAnalysis.report(app: "Zoom", browser: false, start: day0, end: day0.addingTimeInterval(600), network: nil, samples: samples)
        #expect(card.freezes.first?.cause.uploading == true)
        #expect(card.cameras?.measured == false)
        #expect(card.cameras?.text.hasPrefix("Cameras may be part of it. Kilobat sees 2 cameras") == true)
        // Downloading isn't the cameras.
        samples.household = [.init(at: 95, upload: 20_000, download: 4_000_000)]
        #expect(CallAnalysis.report(app: "Zoom", browser: false, start: day0, end: day0.addingTimeInterval(600), network: nil, samples: samples).cameras == nil)
    }
}
