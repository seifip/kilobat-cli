import Foundation
import Testing
@testable import KilobatCore

struct LocalReachTests {
    private func peers(_ edit: (inout LocalPeers) -> Void = { _ in }) -> LocalPeers {
        var value = LocalPeers(); edit(&value); return value
    }
    private func check(_ services: [LocalService] = [], peers: LocalPeers = LocalPeers(), access: LocalNetworkAccess = .allowed, portal: Bool = false) -> LocalReachCheck {
        LocalReachCheck(network: "Hotel Guest", services: services, peers: peers, access: access, portal: portal)
    }
    private let tv = LocalService(kind: .cast, name: "Living Room TV", model: "Chromecast")
    private let printer = LocalService(kind: .printer, name: "HP LaserJet", model: "HP LaserJet Pro M404-M405")

    // MARK: Bonjour records

    @Test func namesDevicesTheWayTheirRecordsDo() {
        // Chromecast's instance is a model and an id; the name people gave it is in fn.
        let cast = LocalServiceCatalog.service(type: "_googlecast._tcp", instance: "Chromecast-Ultra-1a2b3c4d5e6f", txt: ["fn": "Living Room TV", "md": "Chromecast Ultra"])
        #expect(cast == LocalService(kind: .cast, name: "Living Room TV", model: "Chromecast Ultra"))
        #expect(LocalServiceCatalog.service(type: "_googlecast._tcp", instance: "Chromecast-1a2b", txt: [:])?.name == "Chromecast-1a2b")
        // AirPlay audio: MAC@name.
        #expect(LocalServiceCatalog.service(type: "_raop._tcp", instance: "A1B2C3D4E5F6@Kitchen", txt: ["am": "AudioAccessory5,1"])?.name == "Kitchen")
        #expect(LocalServiceCatalog.service(type: "_airplay._tcp", instance: "Bedroom", txt: ["model": "AppleTV14,1"]) == LocalService(kind: .airPlay, name: "Bedroom", model: "AppleTV14,1"))
        // Printers: the bracketed id goes, the make and model come from ty.
        let ipp = LocalServiceCatalog.service(type: "_ipps._tcp", instance: "HP LaserJet Pro M404dn [5A1B2C]", txt: ["ty": "HP LaserJet Pro M404-M405"])
        #expect(ipp == LocalService(kind: .printer, name: "HP LaserJet Pro M404dn", model: "HP LaserJet Pro M404-M405"))
        #expect(LocalServiceCatalog.service(type: "_printer._tcp", instance: "Brother HL-L2350DW series (A1B2C3)", txt: [:])?.name == "Brother HL-L2350DW series")
        #expect(LocalServiceCatalog.service(type: "_ipp._tcp", instance: "EPSON L3150 Series @ iMac", txt: ["ty": "Unknown"])?.model == nil)
        #expect(LocalServiceCatalog.service(type: "_companion-link._tcp", instance: "Rita’s iPhone", txt: [:])?.kind == .companion)
        #expect(LocalServiceCatalog.service(type: "_ssh._tcp", instance: "server", txt: [:]) == nil)
    }

    @Test func mergesOneRowPerDeviceWithoutThisMac() {
        let services = [
            LocalService(kind: .airPlay, name: "Alex’s MacBook Pro", model: "MacBookPro18,1"),
            LocalService(kind: .companion, name: "Alex’s MacBook Pro"),
            LocalService(kind: .airPlay, name: "Office iMac", model: "iMac21,1"),
            LocalService(kind: .airPlay, name: "Bedroom"),
            LocalService(kind: .airPlay, name: "Bedroom", model: "AppleTV14,1"),
            printer, LocalService(kind: .printer, name: "HP LaserJet"), tv,
        ]
        let merged = LocalServiceCatalog.merge(services, own: "Alex’s MacBook Pro")
        // Chromecast first, then AirPlay with the TV before the Mac, then printers; this Mac is gone, duplicates collapse keeping the model.
        #expect(merged.map(\.name) == ["Living Room TV", "Bedroom", "Office iMac", "HP LaserJet"])
        #expect(merged[1].model == "AppleTV14,1")
        #expect(merged[3].model == "HP LaserJet Pro M404-M405")
    }

    // MARK: Who answers

    @Test func readsTheNeighbourCache() {
        let rows = [
            LANDevice(address: "10.0.0.1", mac: "0:11:22:33:44:55", interface: "en0", name: "router"),
            LANDevice(address: "10.0.0.7", mac: "0:11:22:33:44:55", interface: "en0", name: "?"),
            LANDevice(address: "10.0.0.8", mac: "00:11:22:33:44:55", interface: "en0", name: "?"),
            LANDevice(address: "10.0.0.9", mac: "a4:83:e7:1:2:3", interface: "en0", name: "?"),
            LANDevice(address: "10.0.0.10", mac: "a4:83:e7:01:02:03", interface: "en0", name: "?"),
            LANDevice(address: "10.0.0.11", mac: "f0:18:98:aa:bb:cc", interface: "en0", name: "this mac"),
            LANDevice(address: "10.0.0.255", mac: "ff:ff:ff:ff:ff:ff", interface: "en0", name: "broadcast"),
            LANDevice(address: "224.0.0.251", mac: "1:0:5e:0:0:fb", interface: "en0", name: "mdns"),
            LANDevice(address: "192.168.64.2", mac: "de:ad:be:ef:00:01", interface: "bridge100", name: "vm"),
        ]
        let seen = LocalPeers.from(rows: rows, interface: "en0", gateway: "10.0.0.1", own: ["f0:18:98:aa:bb:cc"])
        // One real neighbour (two addresses, one MAC), and two addresses answering as the router: proxy ARP.
        #expect(seen.neighbours == ["10.0.0.9"])
        #expect(seen.routerAliases == 2)
        #expect(LocalPeers.hosts(prefix: 24) == 254 && LocalPeers.hosts(prefix: 22) == 1022 && LocalPeers.hosts(prefix: 32) == 0)
    }

    // MARK: Verdict

    @Test func findingATVOrPrinterMeansItWorks() {
        let both = check([tv, printer])
        #expect(both.verdict == .works)
        #expect(both.headline == "Casting and printing should work: found Living Room TV, HP LaserJet")
        #expect(check([printer]).headline == "Printing should work: found HP LaserJet")
        #expect(check([tv]).headline == "Casting should work: found Living Room TV")
        let many = check([tv, LocalService(kind: .airPlay, name: "Bedroom"), LocalService(kind: .airPlay, name: "Kitchen"), printer])
        #expect(many.headline.hasSuffix("found Living Room TV, Bedroom, Kitchen and 1 more"))
        // Continuity alone is someone's iPhone, not a TV.
        #expect(check([LocalService(kind: .companion, name: "Rita’s iPhone")], peers: peers { $0.bonjourDevices = 1 }).verdict == .noneSeen)
        // Found despite a denied browse of some types: what answered still counts.
        #expect(check([tv], access: .denied).verdict == .works)
    }

    @Test func isolationNeedsEvidence() {
        // Proxy ARP: addresses answering with the router's own hardware address.
        let proxy = check(peers: peers { $0.swept = true; $0.routerAliases = 40; $0.subnetHosts = 254 })
        #expect(proxy.verdict == .isolated && proxy.evidence == .proxyARP)
        #expect(proxy.headline == "This network may keep devices apart. Casting and AirPrint might not work here.")
        #expect(proxy.advice != nil && proxy.detail.contains("does not prove"))
        // Nobody at all on a /22 after a sweep is still not proof of isolation.
        let empty = check(peers: peers { $0.swept = true; $0.subnetHosts = 1022 })
        #expect(empty.verdict == .noneSeen && empty.evidence == nil)
        // The same on a /24 is a quiet home as likely as a hotel: no claim…
        let home = check(peers: peers { $0.swept = true; $0.subnetHosts = 254 })
        #expect(home.verdict == .noneSeen && home.headline == "No casting devices seen")
        #expect(home.detail.contains("can’t tell"))
        // A sign-in page also cannot prove client isolation.
        #expect(check(peers: peers { $0.swept = true; $0.subnetHosts = 254 }, portal: true).verdict == .noneSeen)
        // Without a sweep an empty cache proves nothing.
        #expect(check(peers: peers { $0.subnetHosts = 1022 }).verdict == .noneSeen)
        // Devices present but silent: said as a maybe, never as isolation.
        let silent = check(peers: peers { $0.swept = true; $0.neighbours = 12; $0.pinged = 6; $0.subnetHosts = 1022 })
        #expect(silent.verdict == .noneSeen && silent.detail.contains("may keep devices apart"))
        // Anyone answering, by ping or Bonjour, rules it out.
        let heard = check(peers: peers { $0.swept = true; $0.routerAliases = 40; $0.bonjourDevices = 1 })
        #expect(heard.verdict == .noneSeen && heard.evidence == nil && heard.detail.contains("lets devices talk"))
        #expect(check(peers: peers { $0.swept = true; $0.subnetHosts = 1022; $0.neighbours = 1; $0.pinged = 1; $0.answered = 1 }).verdict == .noneSeen)
    }

    @Test func saysWhenItCouldNotLook() {
        #expect(check(access: .denied).verdict == .noAccess)
        #expect(check(peers: peers { $0.routerAliases = 10 }, access: .denied).evidence == nil)
        #expect(LocalReachCheck(network: nil, services: [], peers: peers { $0.routerAliases = 10 }, connected: false).evidence == nil)
        #expect(LocalReachCheck(network: nil, services: [], peers: LocalPeers(), connected: false).verdict == .offline)
        #expect(check([tv]).short == "Casting should work · Living Room TV")
        #expect(check(peers: peers { $0.routerAliases = 3 }).short == "May keep devices apart · casting uncertain")
    }

    @Test func checkRoundTripsAsJSON() throws {
        let original = check([tv, printer], peers: peers { $0.swept = true; $0.neighbours = 3; $0.answered = 2; $0.pinged = 3 }, portal: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let relay = try decoder.decode(LocalReachRelay.self, from: encoder.encode(LocalReachRelay(check: original, setup: SetupNetworks.match(ssid: "GP24500702"), previous: "Home")))
        #expect(relay.check?.services == original.services && relay.check?.peers == original.peers && relay.check?.verdict == .works)
        #expect(relay.setup?.rule == "gopro" && relay.previous == "Home")
    }

    @Test func parsesTheCommand() throws {
        #expect(try LocalCommand.parse(["local"]) == .check(json: false, quick: false))
        #expect(try LocalCommand.parse(["local", "check", "--json"]) == .check(json: true, quick: false))
        #expect(try LocalCommand.parse(["local", "--quick", "--json"]) == .check(json: true, quick: true))
        #expect(throws: DiagnosticError.self) { try LocalCommand.parse(["local", "scan"]) }
    }

    // MARK: A device's own Wi-Fi

    @Test func recognisesDevicesOwnNetworks() {
        let cases: [(String, String, SetupDeviceKind)] = [
            ("DIRECT-72-HP OfficeJet Pro 6970", "hp-direct", .printer), ("HP-Print-3C-Deskjet 3520", "hp-print", .printer), ("HP-Setup>8A-OfficeJet 8020", "hp-setup", .printer),
            ("DIRECT-xyDCP-L2550DW_BR1234", "brother-direct", .printer), ("DIRECT-ab3F-GX6500series", "canon-direct", .printer), ("A1B2C3-TS8300series", "canon-ap", .printer),
            ("DIRECT-Ab12:ILCE-7M4", "sony-camera", .camera), ("EOSR6_Canon0A", "canon-camera", .camera), ("GP24500702", "gopro", .actionCamera),
            ("X3 7VMF4Q.OSC", "insta360", .camera360), ("ONE X2 ABC123", "insta360", .camera360), ("THETAYN00001017.OSC", "theta", .camera360), ("Pano 1A2B.OSC", "osc", .camera360),
            ("TELLO-5A1B2C", "tello", .drone), ("RMTT-ABCDEF", "tello", .drone), ("Spark-ABC123", "dji-spark", .drone),
            ("shellyplug-s-7C87CE", "shelly", .smartHome), ("ShellyPlus1-f008d1d8bd68", "shelly", .smartHome), ("tasmota_3D5E26-7718", "tasmota", .smartHome),
            ("TP-LINK_Smart Plug_1A2B", "kasa", .smartHome), ("Tapo_Cam_1A2B", "tapo", .smartHome), ("WiZConfig_1a2b", "wiz", .smartHome),
            ("DIRECT-Q7-EPSON-XP-3150", "wifi-direct", .directLink), ("DIRECT-roku-123", "wifi-direct", .directLink),
        ]
        for (ssid, rule, kind) in cases {
            let match = SetupNetworks.match(ssid: ssid)
            #expect(match?.rule == rule && match?.kind == kind, "\(ssid) → \(String(describing: match))")
        }
        for ordinary in ["Home", "Hotel Guest", "DIRECT", "Direct-TV Lounge", "GP1234567", "GoPro fans", "Spark", "Sparkle-Home", "shelly", "X3 house", "HP Office"] {
            #expect(SetupNetworks.match(ssid: ordinary) == nil, "\(ordinary)")
        }
        #expect(SetupNetworks.match(ssid: nil) == nil && SetupNetworks.match(ssid: "") == nil)
        #expect(SetupNetworks.rules.allSatisfy { $0.source.hasPrefix("https://") })
    }

    @Test func onlyWithoutTheInternet() {
        // A phone's Wi-Fi Direct sharing its connection, or a home network named DIRECT-…: the internet works, so nothing to say.
        #expect(SetupNetworks.judge(ssid: "DIRECT-72-HP OfficeJet", gateway: "192.168.223.1", internetReachable: true) == nil)
        #expect(SetupNetworks.judge(ssid: "DIRECT-72-HP OfficeJet", gateway: "192.168.223.1", internetReachable: false)?.kind == .printer)
        #expect(SetupNetworks.judge(ssid: "GP24500702", gateway: nil, internetReachable: true) == nil)
        #expect(SetupNetworks.judge(ssid: "GP24500702", gateway: nil, internetReachable: false)?.kind == .actionCamera)
        #expect(SetupNetworks.judge(ssid: "Home", gateway: nil, internetReachable: false) == nil)
    }

    @Test func saysWhatTheNetworkIs() {
        let printer = SetupNetworks.match(ssid: "DIRECT-72-HP OfficeJet Pro 6970")!
        #expect(printer.headline == "You’re on your HP printer’s own Wi-Fi; there’s no internet here, by design.")
        #expect(printer.detail(previous: "Home") == "Print or set it up from here. Go back to Home when you’re done. Kilobat doesn’t count this as an outage.")
        #expect(SetupNetworks.match(ssid: "TELLO-5A1B2C")!.headline == "You’re on your DJI Tello drone’s own Wi-Fi; there’s no internet here, by design.")
        #expect(SetupNetworks.match(ssid: "shellyplug-s-7C87CE")!.headline == "You’re on a Shelly smart device’s setup Wi-Fi; there’s no internet here, by design.")
        #expect(SetupNetworks.match(ssid: "DIRECT-Q7-Lounge")!.headline.hasPrefix("You’re on a device’s own Wi-Fi Direct network"))
    }

    private func sample(ssid: String, setup: SetupNetworkMatch?, internet: [Double] = []) -> DiagnosticSnapshot {
        var value = DiagnosticSnapshot(date: Date(), radio: RadioSample(ssid: ssid, interface: "en0", rssi: -45, noise: -92, transmitMbps: 144, channel: 6, band: "2.4 GHz"),
                                       gateway: "192.168.223.1", router: PingResult(host: "192.168.223.1", samples: [2], lossPercent: 0),
                                       internet: PingResult(host: "1.1.1.1", samples: internet, lossPercent: internet.isEmpty ? 100 : 0), dnsMilliseconds: nil, dnsServers: [],
                                       captivePortal: nil, networkService: "Wi-Fi")
        value.setupNetwork = setup
        return value
    }

    @Test func noAlarmOnADevicesOwnWiFi() {
        let setup = SetupNetworks.match(ssid: "DIRECT-72-HP OfficeJet Pro 6970")
        let on = sample(ssid: "DIRECT-72-HP OfficeJet Pro 6970", setup: setup)
        #expect(on.health == .unknown)
        #expect(on.advice == [setup!.headline])
        #expect(WidgetSnapshot.Status(connected: true, snapshot: on) == .checking)
    }

    @MainActor @Test func journalLogsItButNeverAsAnOutage() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: path) }
        let journal = NetworkJournal(directory: path); journal.alerts = false
        let ssid = "DIRECT-72-HP OfficeJet Pro 6970"
        let on = sample(ssid: ssid, setup: SetupNetworks.match(ssid: ssid))
        let noReply = PingResult(host: "8.8.8.8", samples: [], lossPercent: 100)
        let start = Date()
        for i in 0..<4 { journal.ingest(on, secondary: noReply, httpReachable: false, interval: 60, date: start.addingTimeInterval(Double(i) * 60)) }
        #expect(journal.events.map(\.kind) == ["Device Wi-Fi"])
        #expect(!journal.events.contains { $0.kind == "Unreachable" })
    }

    @MainActor @Test func remembersTheWiFiToGoBackTo() {
        let watch = LocalReachWatch()
        watch.observe(sample(ssid: "Home", setup: nil, internet: [12]), portal: false, automatic: false)
        #expect(watch.setup == nil && watch.previous == nil)
        let ssid = "GP24500702"
        watch.observe(sample(ssid: ssid, setup: SetupNetworks.match(ssid: ssid)), portal: false, automatic: false)
        #expect(watch.setup?.kind == .actionCamera && watch.previous == "Home")
        watch.observe(sample(ssid: "Home", setup: nil, internet: [12]), portal: false, automatic: false)
        #expect(watch.setup == nil && watch.previous == nil)
    }

    @MainActor @Test func quickCheckDoesNotReuseEarlierSweptResult() async {
        let watch = LocalReachWatch()
        watch.observe(sample(ssid: "Sample Home", setup: nil, internet: [12]), portal: false, automatic: false)
        var previous = LocalPeers(); previous.swept = true
        watch.preview(LocalReachCheck(network: "Sample Home", services: [], peers: previous))
        var sweeps: [Bool] = []
        watch.runProbe = { network, _, _, _, sweep in
            sweeps.append(sweep)
            var peers = LocalPeers(); peers.swept = sweep
            return LocalReachCheck(network: network, services: [], peers: peers)
        }
        let result = await watch.run(sweep: false)
        #expect(sweeps == [false])
        #expect(result?.peers.swept == false && watch.check?.peers.swept == false)
    }

    @MainActor @Test func networkChangeDoesNotReturnPreviousNetworksCheck() async {
        let watch = LocalReachWatch()
        watch.observe(sample(ssid: "Sample Home", setup: nil, internet: [12]), portal: false, automatic: false)
        watch.runProbe = { network, _, _, _, _ in
            watch.observe(sample(ssid: "Sample Guest", setup: nil, internet: [12]), portal: false, automatic: false)
            return LocalReachCheck(network: network, services: [], peers: LocalPeers())
        }
        #expect(await watch.run(sweep: false) == nil)
        #expect(watch.check == nil)
    }

    // MARK: Casting stutter

    @Test func detectsWhatIsObservable() {
        // The sound output is an AirPlay receiver: AirPlay, named.
        let airPlay = CastingActivity.detect(outputTransport: CastingActivity.airPlayTransport, outputName: "Living Room", local: [:])
        #expect(airPlay?.kind == .airPlay && airPlay?.target == "Living Room" && airPlay?.summary == "AirPlay to Living Room")
        // Mirroring without sound to the TV: macOS's AirPlay sender streaming on the local network.
        let mirror = CastingActivity.detect(outputTransport: 0x626C_746E, outputName: "MacBook Pro Speakers", local: ["AirPlayXPCHelper": 400_000])
        #expect(mirror?.kind == .airPlay && mirror?.target == nil && mirror?.sender == "AirPlayXPCHelper")
        // A tab cast: Chrome streaming to the local network.
        #expect(CastingActivity.detect(outputTransport: nil, outputName: nil, local: ["Google Chrome": 600_000])?.kind == .browserTab)
        #expect(CastingActivity.detect(outputTransport: nil, outputName: nil, local: ["Google Chrome": 600_000])?.summary == "Possible cast from Google Chrome")
        // Too little to be a stream, or not a browser.
        #expect(CastingActivity.detect(outputTransport: nil, outputName: nil, local: ["Google Chrome": 50_000, "AirPlayXPCHelper": 20_000]) == nil)
        #expect(CastingActivity.detect(outputTransport: nil, outputName: nil, local: ["Synology Drive": 5_000_000]) == nil)
    }

    @Test func localRatesFromTotals() {
        #expect(CastingWatch.localRates(previous: nil, current: ["A": 10], seconds: 5).isEmpty)
        let rates = CastingWatch.localRates(previous: ["A": 1_000, "B": 500, "C": 900], current: ["A": 6_000, "B": 500, "C": 100, "D": 9_000], seconds: 5)
        // New apps and counters that went back (a reset) don't count.
        #expect(rates == ["A": 1_000])
    }

    private func casting(_ edit: (inout CastingConditions) -> Void) -> CastingCheck {
        var conditions = CastingConditions()
        conditions.wifiBand = "5 GHz"; conditions.rssi = -55; conditions.airDropActive = false
        edit(&conditions)
        return CastingCheck(activity: CastingActivity(kind: .airPlay, target: "Living Room", sender: "AirPlayXPCHelper"), conditions: conditions)
    }

    @Test func flagsTheUsualCauses() {
        #expect(casting { _ in }.risks.isEmpty && !casting { _ in }.shows)
        let bad = casting { $0.wifiBand = "2.4 GHz"; $0.rssi = -74; $0.airDropActive = true; $0.airDropUsers = ["AirDrop"]
            $0.busiestApp = "Dropbox"; $0.busiestBytesPerSecond = 1_500_000; $0.busiestUploading = true; $0.busiestPausable = true }
        #expect(bad.risks == [.wifi24, .weakSignal, .airDrop, .heavyTraffic])
        #expect(bad.headline == "AirPlay to Living Room may stutter")
        #expect(bad.advice.map(\.action) == [nil, nil, .pauseAirDrop, .pauseBackground])
        #expect(bad.advice[3].text == "Dropbox is uploading a lot over the same Wi-Fi: pause it while you cast.")
        // AirPlay riding AirDrop's own link: pausing it would cut the stream.
        #expect(casting { $0.airDropActive = true; $0.airDropUsers = ["AirPlay"] }.risks.isEmpty)
        // A download needs more than an upload to count, and an app Kilobat can't pause gets no button.
        #expect(casting { $0.busiestBytesPerSecond = 1_500_000; $0.busiestUploading = false }.risks.isEmpty)
        let steam = casting { $0.busiestApp = "Steam"; $0.busiestBytesPerSecond = 4_000_000; $0.busiestUploading = false; $0.busiestPausable = false }
        #expect(steam.risks == [.heavyTraffic] && steam.advice.first?.action == nil)
        // A remembered 5 GHz network gets the join button.
        let faster = casting { $0.wifiBand = "2.4 GHz"; $0.fasterBand = FasterBand(name: "Home-5G", band: "5 GHz", rssi: -60, sameName: false, known: true) }
        #expect(faster.advice.first?.action == .joinFasterBand && faster.advice.first?.text.contains("Home-5G") == true)
    }
}
