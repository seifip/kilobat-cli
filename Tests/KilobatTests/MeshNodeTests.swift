import Foundation
import Testing
@testable import KilobatCore

/// Stuck on the far mesh node: grouping radios into nodes, the link-rate estimate, the sticky rules over time,
/// the store, the call cause and the CLI's arguments. Addresses are from the documentation range (00-00-5E-00-53-xx).
@MainActor struct MeshNodeTests {
    private let start = Date(timeIntervalSinceReferenceDate: 820_000_000)
    private func radio(_ last: String, _ rssi: Int, _ channel: Int, _ band: String = "5 GHz", width: Int = 80, first: String = "00") -> NodeRadio {
        NodeRadio(bssid: "\(first):00:5e:00:53:\(last)", rssi: rssi, channel: channel, band: band, widthMHz: width)
    }
    /// Living room (…:10–12), Office (…:20–21), Upstairs (…:30 and a locally administered …:30 on 6 GHz).
    private func house(livingRoom: Int = -78, office: Int = -52, upstairs: Int = -70, officeBand: String = "5 GHz") -> [NodeRadio] {
        [radio("10", livingRoom + 6, 6, "2.4 GHz", width: 20), radio("11", livingRoom, 36), radio("12", livingRoom - 3, 149),
         radio("20", office + 5, 1, "2.4 GHz", width: 20), radio("21", office, officeBand == "5 GHz" ? 44 : 6, officeBand, width: officeBand == "5 GHz" ? 80 : 20),
         radio("30", upstairs, 157), radio("30", upstairs - 2, 37, "6 GHz", width: 160, first: "02")]
    }
    private func reading(_ seconds: Double, current: NodeRadio? = nil, scan: [NodeRadio]? = nil, tx: Double? = nil, bands: Set<String> = ["2.4 GHz", "5 GHz"]) -> NodeReading {
        let scan = scan ?? house()
        return NodeReading(date: start.addingTimeInterval(seconds), ssid: "Example Home", current: current ?? scan.first { $0.bssid.hasSuffix(":11") }, transmitMbps: tx, scan: scan, supportedBands: bands)
    }

    // MARK: Nodes

    @Test func radiosGroupIntoNodesByAddress() {
        let nodes = MeshNodes.nodes(house(), current: "00:00:5e:00:53:11", names: ["00:00:5e:00:53:20": "Office"])
        #expect(nodes.count == 3)
        #expect(nodes[0].name == "Office" && nodes[0].radios.count == 2 && nodes[0].id == "00:00:5e:00:53:20")
        #expect(nodes.first(where: \.current)?.radios.map(\.bssid).sorted() == ["00:00:5e:00:53:10", "00:00:5e:00:53:11", "00:00:5e:00:53:12"])
        // The 6 GHz radio's locally administered address belongs with its box.
        #expect(nodes.contains { Set($0.radios.map(\.bssid)) == ["00:00:5e:00:53:30", "02:00:5e:00:53:30"] })
    }

    @Test func farApartOrSameChannelRadiosAreSeparateNodes() {
        // Eight apart: the next box's block of addresses.
        #expect(!MeshNodes.sameNode(radio("10", -60, 36), radio("18", -60, 44)))
        #expect(MeshNodes.sameNode(radio("10", -60, 6, "2.4 GHz"), radio("17", -60, 44)))
        // A mesh shares one channel between its nodes; one radio can't have two addresses on one network.
        #expect(!MeshNodes.sameNode(radio("10", -60, 36), radio("11", -50, 36)))
        // Another maker's prefix, even with the same tail.
        #expect(!MeshNodes.sameNode(radio("10", -60, 36), NodeRadio(bssid: "00:00:5f:00:53:11", rssi: -60, channel: 44, band: "5 GHz", widthMHz: 80)))
    }

    @Test func addressesAreNormalized() {
        #expect(MeshNodes.normalize("0:0:5E:0:53:A") == "00:00:5e:00:53:0a")
        #expect(MeshNodes.normalize("not a mac") == nil)
        #expect(MeshNodes.normalize("00:00:5e:00:53") == nil)
        #expect(NodeRadio(bssid: "0:0:5E:0:53:A", rssi: -50, channel: 1, band: "2.4 GHz", widthMHz: 20).bssid == "00:00:5e:00:53:0a")
    }

    @Test func nodeNamesFollowMostRadios() {
        let names = ["00:00:5e:00:53:10": "Lounge", "00:00:5e:00:53:11": "Living room", "00:00:5e:00:53:12": "Living room"]
        #expect(MeshNodes.nodes(house(), current: nil, names: names).first { $0.id == "00:00:5e:00:53:10" }?.name == "Living room")
    }

    // MARK: Link rate

    @Test func linkRateRisesWithSignalAndWidth() {
        let far = MeshNodes.estimatedMbps(rssi: -78, band: "5 GHz", widthMHz: 80)
        let near = MeshNodes.estimatedMbps(rssi: -50, band: "5 GHz", widthMHz: 80)
        #expect(far > 20 && far < 60)
        #expect(near > 900)
        #expect(MeshNodes.estimatedMbps(rssi: -60, band: "5 GHz", widthMHz: 80) > MeshNodes.estimatedMbps(rssi: -60, band: "5 GHz", widthMHz: 20))
        // 2.4 GHz counts 40 MHz at most, with its airtime discount.
        #expect(MeshNodes.estimatedMbps(rssi: -45, band: "2.4 GHz", widthMHz: 80) == MeshNodes.estimatedMbps(rssi: -45, band: "2.4 GHz", widthMHz: 40))
        #expect(MeshNodes.estimatedMbps(rssi: -95, band: "5 GHz", widthMHz: 80) == 0)
    }

    // MARK: One reading

    @Test func aMuchStrongerNodeIsACandidate() throws {
        let found = try #require(StickyDetector.candidate(reading(0)))
        #expect(found.better.id == "00:00:5e:00:53:20" && found.radio.rssi == -52 && found.radio.band == "5 GHz")
        #expect(found.node.current)
    }

    @Test func thresholds() {
        // 14 dB is under the 15 dB line.
        #expect(StickyDetector.candidate(reading(0, scan: house(livingRoom: -70, office: -56))) == nil)
        #expect(StickyDetector.candidate(reading(0, scan: house(livingRoom: -70, office: -55))) != nil)
        // At -65 dBm or better, the current node is good enough, whatever is nearby.
        #expect(StickyDetector.candidate(reading(0, scan: house(livingRoom: -65, office: -40))) == nil)
        // One node heard.
        #expect(StickyDetector.candidate(reading(0, scan: Array(house().prefix(3)))) == nil)
    }

    @Test func bandSteeringToFiveGigahertzIsLeftAlone() {
        // On 5 GHz at -68 with a good rate; the "stronger" radio is the office's 2.4 GHz one.
        let scan = [radio("11", -68, 36), radio("20", -50, 1, "2.4 GHz", width: 20), radio("21", -71, 44)]
        #expect(StickyDetector.candidate(reading(0, current: scan[0], scan: scan)) == nil)
        // The same 2.4 GHz radio does help a Mac barely holding on to 5 GHz.
        let weak = [radio("11", -79, 36), radio("20", -50, 1, "2.4 GHz", width: 20), radio("21", -71, 44)]
        #expect(StickyDetector.candidate(reading(0, current: weak[0], scan: weak))?.radio.band == "2.4 GHz")
        // A link already running fast says the signal undersells it.
        #expect(StickyDetector.candidate(reading(0, scan: house(livingRoom: -70, office: -54), tx: 866)) == nil)
    }

    @Test func onlyBandsTheMacSupportsCount() {
        let scan = [radio("11", -78, 36), radio("20", -80, 1, "2.4 GHz", width: 20), radio("21", -50, 37, "6 GHz", width: 160)]
        #expect(StickyDetector.candidate(reading(0, current: scan[0], scan: scan)) == nil)
        #expect(StickyDetector.candidate(reading(0, current: scan[0], scan: scan, bands: ["2.4 GHz", "5 GHz", "6 GHz"])) != nil)
    }

    // MARK: Over time

    @Test func stuckNeedsTwoMinutesAndThreeReadings() {
        var detector = StickyDetector()
        #expect(detector.observe(reading(0)) == .watching)
        #expect(detector.observe(reading(60)) == .watching)
        #expect(detector.observe(reading(119)) == .watching)
        #expect(detector.observe(reading(125)) == .stuck)
        #expect(detector.stuck?.since == start && detector.stuck?.difference == 26)
        // Two readings two minutes apart aren't enough.
        var sparse = StickyDetector()
        sparse.observe(reading(0)); #expect(sparse.observe(reading(150)) == .watching)
        #expect(sparse.observe(reading(200)) == .stuck)
    }

    @Test func aStuckEpisodeHoldsOnTheKeepMarginAndEndsBelowIt() {
        var detector = StickyDetector()
        for t in [0.0, 60, 120] { detector.observe(reading(t)) }
        #expect(detector.state == .stuck)
        // 13 dB keeps it going…
        #expect(detector.observe(reading(180, scan: house(livingRoom: -70, office: -57))) == .stuck)
        #expect(detector.stuck?.since == start)
        // …11 dB ends it, and starting again takes 15.
        #expect(detector.observe(reading(240, scan: house(livingRoom: -70, office: -59))) == .fine)
        #expect(detector.stuck == nil)
        #expect(detector.observe(reading(300, scan: house(livingRoom: -70, office: -57))) == .fine)
    }

    @Test func aRoamWaitsAMinuteAndStartsOver() {
        var detector = StickyDetector()
        detector.observe(reading(0)); detector.observe(reading(60))
        // macOS moved to the Upstairs node's radio: still far from the office, but a new start.
        let upstairs = house().first { $0.bssid == "00:00:5e:00:53:30" }!
        #expect(detector.observe(reading(90, current: NodeRadio(bssid: upstairs.bssid, rssi: -74, channel: 157, band: "5 GHz", widthMHz: 80))) == .settling)
        #expect(detector.lastRoam == start.addingTimeInterval(90))
        #expect(detector.observe(reading(120, current: NodeRadio(bssid: upstairs.bssid, rssi: -74, channel: 157, band: "5 GHz", widthMHz: 80))) == .settling)
        let current = NodeRadio(bssid: upstairs.bssid, rssi: -74, channel: 157, band: "5 GHz", widthMHz: 80)
        #expect(detector.observe(reading(150, current: current)) == .watching)
        #expect(detector.observe(reading(210, current: current)) == .watching)
        #expect(detector.observe(reading(270, current: current)) == .stuck)
        // Leaving Wi-Fi ends everything.
        #expect(detector.observe(NodeReading(date: start.addingTimeInterval(300), ssid: nil, current: nil, transmitMbps: nil, scan: [])) == .notJoined)
        #expect(detector.stuck == nil)
    }

    @Test func aMovingMacIsNotStuck() {
        var detector = StickyDetector()
        // Carried around the house: the current signal swings 16 dB.
        for (t, rssi) in [(0.0, -70), (60, -86), (120, -72), (180, -84)] {
            let scan = house(livingRoom: rssi, office: -50)
            detector.observe(reading(t, current: scan.first { $0.bssid.hasSuffix(":11") }, scan: scan))
        }
        #expect(detector.state == .watching)
        #expect(detector.stuck == nil)
    }

    @Test func sleepAndMissingScansDontCount() {
        var detector = StickyDetector()
        detector.observe(reading(0)); detector.observe(reading(60))
        // No scan this time: no evidence either way.
        #expect(detector.observe(reading(90, current: house()[1], scan: [])) == .watching)
        // Eight minutes asleep: start over.
        detector.observe(reading(570))
        #expect(detector.observe(reading(630)) == .watching)
        #expect(detector.observe(reading(700)) == .stuck)
        #expect(detector.stuck?.since == start.addingTimeInterval(570))
    }

    // MARK: Sentences

    @Test func sentencesUseNamesWhenKnown() {
        var detector = StickyDetector()
        let names = ["00:00:5e:00:53:11": "Living room", "00:00:5e:00:53:20": "Office", "00:00:5e:00:53:21": "Office"]
        for t in [0.0, 60, 120] { detector.observe(reading(t), names: names) }
        let named = NodeReport(date: start, ssid: "Example Home", network: "home", state: .stuck, stuck: detector.stuck, repeats: 1)
        #expect(named.detail == "You’re on the Living room node at -78 dBm; the Office node is at -52 dBm.")
        #expect(named.short == "On the far node · Office is 26 dB stronger")
        #expect(named.advice?.contains("mesh system") == false)
        var plain = StickyDetector()
        for t in [0.0, 60, 120] { plain.observe(reading(t)) }
        let unnamed = NodeReport(date: start, ssid: "Example Home", network: "home", state: .stuck, stuck: plain.stuck, repeats: 3)
        #expect(unnamed.detail == "You’re on a node at -78 dBm; a node about 26 dB stronger is in range.")
        #expect(unnamed.advice?.contains("steering or roaming settings") == true)
    }

    // MARK: The store

    @Test func theWatchNamesNodesKeepsEpisodesAndNotifiesOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-nodes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let watch = NodeWatch(directory: folder)
        var alerts = 0
        watch.onStuck = { _ in alerts += 1 }
        watch.ingest(reading(0), network: "home")
        #expect(watch.report?.state == .watching && watch.report?.nodes.count == 3)
        // Named by any of its radios; the box's other radio takes the name too.
        #expect(watch.name("00:00:5e:00:53:21", as: "Office")?.name == "Office")
        #expect(watch.name("current", as: " Living room ")?.name == "Living room")
        #expect(watch.place("home")?.names["00:00:5e:00:53:20"] == "Office")
        for t in stride(from: 60.0, through: 600, by: 60) { watch.ingest(reading(t), network: "home") }
        #expect(watch.report?.state == .stuck)
        #expect(watch.report?.detail == "You’re on the Living room node at -78 dBm; the Office node is at -52 dBm.")
        #expect(alerts == 1)
        #expect(watch.place("home")?.episodes.count == 1)
        // A new radio on the named box learns its name.
        watch.ingest(reading(660, scan: house() + [radio("22", -55, 149)]), network: "home")
        #expect(watch.place("home")?.names["00:00:5e:00:53:22"] == "Office")
        // The episode ends, a second starts within six hours: no second notification.
        watch.ingest(reading(720, scan: house(livingRoom: -64)), network: "home")
        #expect(watch.place("home")?.episodes.last?.end != nil)
        for t in stride(from: 780.0, through: 1500, by: 60) { watch.ingest(reading(t), network: "home") }
        #expect(watch.place("home")?.episodes.count == 2 && watch.report?.repeats == 2)
        #expect(alerts == 1)
        // Names and episodes are on disk for the next launch.
        let again = NodeWatch(directory: folder)
        #expect(again.place("home")?.names["00:00:5e:00:53:11"] == "Living room")
        #expect(again.place("home")?.episodes.count == 2)
        // Clearing a name.
        #expect(watch.name("Office", as: "")?.name == nil)
        #expect(watch.place("home")?.names["00:00:5e:00:53:20"] == nil)
        #expect(NodeWatch.find("nowhere", in: watch.report?.nodes ?? []) == nil)
    }

    @Test func theJSONSaysWhatTheAppSees() throws {
        #expect(NodeJSON.report(nil, locationAllowed: false)["state"] as? String == "noLocation")
        #expect(NodeJSON.report(nil, locationAllowed: true)["state"] as? String == "checking")
        var detector = StickyDetector()
        for t in [0.0, 60, 120] { detector.observe(reading(t)) }
        let nodes = MeshNodes.nodes(house(), current: "00:00:5e:00:53:11")
        let json = NodeJSON.report(NodeReport(date: start.addingTimeInterval(300), ssid: "Example Home", network: "home", state: .stuck, nodes: nodes, stuck: detector.stuck), locationAllowed: true)
        let stuck = try #require(json["stuck"] as? [String: Any])
        #expect(stuck["differenceDB"] as? Int == 26 && stuck["minutes"] as? Int == 5 && stuck["betterNode"] as? String == "00:00:5e:00:53:20")
        #expect(json["current"] as? String == "00:00:5e:00:53:10")
        #expect((json["nodes"] as? [[String: Any]])?.count == 3)
        _ = try JSONSerialization.data(withJSONObject: json)
    }

    // MARK: Calls

    @Test func aFreezeOnTheFarNodeSaysSo() {
        var samples = CallSamples()
        samples.router = (0..<60).map { .init(at: Double($0), ms: (20...22).contains($0) ? 480 : 3) }
        samples.weakSignal = [21]
        samples.farNode = Array(stride(from: 0.0, through: 59, by: 1))
        samples.farNodes = .init(node: "Living room", better: "Office", rssi: -78, betterRSSI: -52)
        let cause = CallAnalysis.cause(from: 20, to: 22, samples: samples)
        #expect(cause.kind == .wifi && cause.farNode == true && cause.weakSignal == true)
        #expect(cause.phrase == "on the far Wi-Fi node")
        #expect(cause.advice.hasPrefix("You were on the Living room node at -78 dBm while the Office node was at -52 dBm."))
        // Unnamed nodes still give the gap.
        samples.farNodes = .init(node: nil, better: nil, rssi: -78, betterRSSI: -52)
        #expect(CallAnalysis.cause(from: 20, to: 22, samples: samples).advice.hasPrefix("You were on a node at -78 dBm while another was 26 dB stronger."))
        // Not on the far node at the time: plain weak Wi-Fi.
        samples.farNode = [200]
        let plain = CallAnalysis.cause(from: 20, to: 22, samples: samples)
        #expect(plain.farNode == nil && plain.phrase == "on weak Wi-Fi")
        // Far node but the freeze was past the router: not the Wi-Fi's doing.
        samples.farNode = [21]
        samples.router = (0..<60).map { .init(at: Double($0), ms: 3) }
        #expect(CallAnalysis.cause(from: 20, to: 22, samples: samples).kind == .beyondRouter)
    }

    @Test func oldReportsWithoutTheFieldStillRead() throws {
        let json = #"{"kind":"wifi","weakSignal":true}"#
        let cause = try JSONDecoder().decode(CallReport.Cause.self, from: Data(json.utf8))
        #expect(cause.farNode == nil && cause.phrase == "on weak Wi-Fi")
    }

    // MARK: CLI

    @Test func cliArguments() throws {
        #expect(try WiFiNodesCommand.parse(["nodes"]) == .list)
        #expect(try WiFiNodesCommand.parse(["reconnect"]) == .reconnect)
        #expect(try WiFiNodesCommand.parse(["nodes", "name", "00:00:5e:00:53:20", "Home", "office"]) == .name(node: "00:00:5e:00:53:20", name: "Home office"))
        #expect(try WiFiNodesCommand.parse(["nodes", "name", "current", ""]) == .name(node: "current", name: ""))
        #expect(throws: DiagnosticError.self) { try WiFiNodesCommand.parse(["nodes", "name", "current"]) }
        #expect(throws: DiagnosticError.self) { try WiFiNodesCommand.parse(["nodes", "forget"]) }
        #expect(throws: DiagnosticError.self) { try WiFiNodesCommand.parse(["reconnect", "now"]) }
    }
}
