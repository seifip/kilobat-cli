import Foundation
import Testing
@testable import KilobatCore

/// Channel plan and advice, the watch session, band steering and sticky clients, and the scan CSV.
@MainActor struct WiFiAnalyzerTests {
    static func network(_ ssid: String, _ bssid: String, rssi: Int, channel: Int, band: String, width: Int = 20, center: Int? = nil) -> NearbyNetwork {
        var details: AccessPointDetails?
        if let center { details = AccessPointDetails(); details?.centerChannel = center; details?.widthMHz = width }
        return NearbyNetwork(id: bssid, ssid: ssid, rssi: rssi, noise: -92, channel: channel, band: band, widthMHz: width, details: details)
    }
    static func radio(ssid: String = "Home", bssid: String? = "00:00:5e:00:53:10", rssi: Int, channel: Int, band: String, width: Int = 20, transmit: Double? = nil) -> RadioSample {
        var sample = RadioSample.basic(bssid: bssid, ssid: ssid, interface: "en0", rssi: rssi, noise: -92, transmitMbps: transmit, channel: channel, band: band)
        sample.widthMHz = width
        return sample
    }

    // MARK: Channel plan

    @Test func frequenciesAndSpans() {
        #expect(ChannelPlan.frequency(channel: 1, band: "2.4 GHz") == 2412)
        #expect(ChannelPlan.frequency(channel: 14, band: "2.4 GHz") == 2484)
        #expect(ChannelPlan.frequency(channel: 36, band: "5 GHz") == 5180)
        #expect(ChannelPlan.frequency(channel: 1, band: "6 GHz") == 5955)
        #expect(ChannelPlan.frequency(channel: 70, band: "2.4 GHz") == nil)
        // Standard blocks when the beacon didn't say.
        #expect(ChannelPlan.blockCenter(channel: 44, band: "5 GHz", width: 80) == 42)
        #expect(ChannelPlan.blockCenter(channel: 157, band: "5 GHz", width: 80) == 155)
        #expect(ChannelPlan.blockCenter(channel: 112, band: "5 GHz", width: 160) == 114)
        #expect(ChannelPlan.blockCenter(channel: 37, band: "6 GHz", width: 320) == 31)
        #expect(ChannelPlan.blockCenter(channel: 37, band: "6 GHz", width: 160) == 47)
        #expect(ChannelPlan.blockCenter(channel: 11, band: "2.4 GHz", width: 40) == 9)
        let span = ChannelPlan.span(channel: 36, band: "5 GHz", widthMHz: 80)
        #expect(span.low == 5170 && span.high == 5250)
        // The beacon's centre wins: a 320 MHz channel on the second 320 MHz plan.
        let wide = ChannelPlan.span(channel: 37, band: "6 GHz", widthMHz: 320, center: 63)
        #expect(wide.center == 6265 && wide.width == 320)
        // 1, 6 and 11 don't overlap; 1 and 3 do, by 10 MHz.
        let one = ChannelPlan.span(channel: 1, band: "2.4 GHz", widthMHz: 20)
        #expect(one.overlap(ChannelPlan.span(channel: 6, band: "2.4 GHz", widthMHz: 20)) == 0)
        #expect(one.overlap(ChannelPlan.span(channel: 3, band: "2.4 GHz", widthMHz: 20)) == 10)
    }

    @Test func dfsChannels() {
        #expect(!ChannelPlan.isDFS(channel: 48, band: "5 GHz"))
        #expect(ChannelPlan.isDFS(channel: 52, band: "5 GHz"))
        #expect(ChannelPlan.isDFS(channel: 144, band: "5 GHz"))
        #expect(!ChannelPlan.isDFS(channel: 149, band: "5 GHz"))
        #expect(!ChannelPlan.isDFS(channel: 52, band: "6 GHz"))
        // 160 MHz on 36 reaches into 52–64.
        #expect(ChannelPlan.touchesDFS(ChannelPlan.span(channel: 36, band: "5 GHz", widthMHz: 160), band: "5 GHz"))
        #expect(!ChannelPlan.touchesDFS(ChannelPlan.span(channel: 36, band: "5 GHz", widthMHz: 80), band: "5 GHz"))
        #expect(ChannelPlan.candidates(band: "5 GHz", width: 80) == [36, 52, 100, 116, 132, 149])
        #expect(ChannelPlan.candidates(band: "6 GHz", width: 320) == [1, 65, 129])
    }

    @Test func adviceOn24GHzLeavesOwnNetworkOut() {
        let networks = [Self.network("Home", "00:00:5e:00:53:10", rssi: -40, channel: 6, band: "2.4 GHz"),
                        Self.network("Neighbour", "00:00:5e:00:53:a0", rssi: -50, channel: 6, band: "2.4 GHz"),
                        Self.network("Other", "00:00:5e:00:53:a1", rssi: -55, channel: 1, band: "2.4 GHz"),
                        Self.network("Far", "00:00:5e:00:53:a2", rssi: -85, channel: 11, band: "2.4 GHz")]
        let advice = ChannelPlan.advice(band: "2.4 GHz", networks: networks, ssid: "Home", channel: 6, width: 20)
        #expect(advice.rows.map(\.channel) == [1, 6, 11])
        #expect(advice.recommended == 11)
        #expect(advice.overlappingCurrent == 1)
        #expect(advice.networksSeen == 3)
        #expect(advice.sentence.contains("Try channel 11"))
        // Its own network on 6 counts for nothing, so staying on an empty 6 is right.
        let alone = ChannelPlan.advice(band: "2.4 GHz", networks: [networks[0], networks[2]], ssid: "Home", channel: 6, width: 20)
        #expect(alone.recommended == 6)
        #expect(alone.sentence.contains("Keep it"))
        let wide = ChannelPlan.advice(band: "2.4 GHz", networks: networks, ssid: "Home", channel: 6, width: 40)
        #expect(wide.widthMHz == 20)
        #expect(wide.sentence.contains("40 MHz"))
    }

    @Test func adviceOn5GHzPrefersNonDFSUnlessClearlyQuieter() {
        let busy = [Self.network("A", "00:00:5e:00:53:a0", rssi: -50, channel: 36, band: "5 GHz", width: 80),
                    Self.network("B", "00:00:5e:00:53:a1", rssi: -55, channel: 149, band: "5 GHz", width: 80)]
        let advice = ChannelPlan.advice(band: "5 GHz", networks: busy, ssid: "Home", channel: 44, width: 80)
        #expect(advice.current == 36)
        #expect(advice.overlappingCurrent == 1)
        // 52 and 100 are empty and far quieter than both non-DFS blocks.
        #expect(advice.recommended == 52)
        #expect(advice.rows.first { $0.channel == 52 }?.dfs == true)
        #expect(advice.sentence.contains("DFS"))
        // A faint neighbour on 149 keeps the advice off DFS.
        let faint = [busy[0], Self.network("B", "00:00:5e:00:53:a1", rssi: -88, channel: 149, band: "5 GHz", width: 80)]
        let calm = ChannelPlan.advice(band: "5 GHz", networks: faint, ssid: "Home", channel: 44, width: 80)
        #expect(calm.recommended == 149)
        #expect(!calm.sentence.contains("DFS"))
        // Off this band: advice for a common width, no current channel.
        let elsewhere = ChannelPlan.advice(band: "5 GHz", networks: faint, ssid: nil, channel: nil, width: nil)
        #expect(elsewhere.widthMHz == 80 && elsewhere.current == nil)
        #expect(elsewhere.sentence.hasPrefix("On 5 GHz"))
        // Nothing else heard.
        let empty = ChannelPlan.advice(band: "6 GHz", networks: [], ssid: "Home", channel: 37, width: 160)
        #expect(empty.networksSeen == 0 && empty.sentence.contains("No other networks"))
    }

    @Test func spansUseTheBeaconsCenter() {
        // A 160 MHz neighbour centred on 50 overlaps 36–64; without the beacon's centre it would sit on its block anyway.
        let wide = Self.network("Wide", "00:00:5e:00:53:a0", rssi: -50, channel: 60, band: "5 GHz", width: 160, center: 50)
        #expect(wide.span.low == 5170 && wide.span.high == 5330)
        let cost = ChannelPlan.cost(ChannelPlan.span(channel: 36, band: "5 GHz", widthMHz: 20), networks: [wide])
        #expect(cost == 50)
        let summary = ChannelPlan.advice(band: "6 GHz", networks: [Self.network("N", "00:00:5e:00:53:a3", rssi: -60, channel: 5, band: "6 GHz", width: 20)], ssid: "Home", channel: 37, width: 20).summary
        #expect(summary.count <= 6)
        #expect(summary.contains { $0.channel == 37 })
    }

    // MARK: Watch session

    @Test func watchSessionScansOnScheduleAndReadsTheLinkBetween() async {
        @MainActor final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000); var scans = 0 }
        let clock = Clock()

        let session = WiFiWatchSession(scan: {
            clock.scans += 1; let scans = clock.scans
            return [Self.network("Home", "00:00:5E:00:53:10", rssi: -60 - scans, channel: 36, band: "5 GHz", width: 80),
                    Self.network("Home", "00:00:5e:00:53:20", rssi: -45, channel: 149, band: "5 GHz", width: 80),
                    Self.network("Cafe", "00:00:5e:00:53:a0", rssi: scans % 2 == 0 ? -70 : -999 + 1000 - 1, channel: 1, band: "2.4 GHz")]
        }, link: { Self.radio(rssi: -60, channel: 36, band: "5 GHz", width: 80) }, pauseScans: { false },
           clock: { clock.now }, pause: { clock.now = clock.now.addingTimeInterval($0) })
        let recording = await session.record(duration: 120, interval: 15)
        #expect(recording.scans.count == 9)
        #expect(recording.link.count == 61)
        #expect(recording.joined == "00:00:5e:00:53:10")
        let series = recording.series()
        #expect(series.first?.own == true)
        #expect(series.first?.points.first == -61)
        #expect(series[1].sameNetwork && series[1].radio.channel == 149)
        // The café's radio is heard every other scan; a reading of 0 dBm (odd scans here) is never kept.
        #expect(series.first { $0.radio.ssid == "Cafe" }?.missed == 5)
        #expect(recording.summary.contains("steady"))
        #expect(recording.summary.contains("dB stronger"))
        let csvLines = recording.csv.split(separator: "\n").count
        #expect(csvLines == 84)
        #expect(session.progress == 1)
    }

    @Test func watchLimitsAndCallPause() async {
        #expect(WiFiWatchSession.clamp(duration: 3600) == 600)
        #expect(WiFiWatchSession.clamp(duration: 5) == 30)
        #expect(WiFiWatchSession.clamp(interval: 2) == 10)
        @MainActor final class Clock { var now = Date(timeIntervalSince1970: 0); var scans = 0 }
        let clock = Clock()

        let session = WiFiWatchSession(scan: { clock.scans += 1; return [] }, link: { Self.radio(rssi: -60, channel: 36, band: "5 GHz") }, pauseScans: { true },
                                       clock: { clock.now }, pause: { clock.now = clock.now.addingTimeInterval($0) })
        let recording = await session.record(duration: 30, interval: 1)
        #expect(clock.scans == 0)
        #expect(recording.interval == 10)
        #expect(recording.skipped == 4)
        #expect(recording.summary.contains("skipped"))
    }

    @Test func watchWithoutBSSIDsMatchesByNameAndChannel() {
        var recording = WiFiWatchRecording(start: Date(), duration: 60, interval: 15)
        recording.add(link: Self.radio(bssid: nil, rssi: -55, channel: 44, band: "5 GHz"), at: Date())
        recording.add(scan: [NearbyNetwork(id: "hidden-0", ssid: "Home", rssi: -56, noise: 0, channel: 44, band: "5 GHz", widthMHz: 80),
                             NearbyNetwork(id: "hidden-1", ssid: "Home", rssi: -70, noise: 0, channel: 1, band: "2.4 GHz", widthMHz: 20)], at: Date())
        let series = recording.series()
        #expect(series.first?.own == true && series.first?.radio.channel == 44)
        #expect(series[1].sameNetwork)
        #expect(!recording.csv.contains("hidden"))
    }

    // MARK: Band steering and sticky clients

    @Test func bandSteeringFromTheSameBox() {
        let networks = [Self.network("Home", "00:00:5e:00:53:10", rssi: -45, channel: 6, band: "2.4 GHz"),
                        Self.network("Home", "00:00:5e:00:53:11", rssi: -55, channel: 36, band: "5 GHz", width: 80)]
        let findings = SteeringReport.evaluate(radio: Self.radio(rssi: -45, channel: 6, band: "2.4 GHz"), networks: networks)
        #expect(findings.map(\.kind) == [.bandSteering])
        #expect(findings[0].detail.contains("same access point’s 5 GHz"))
        #expect(findings[0].better == "00:00:5e:00:53:11")
        // A weak 5 GHz radio, or one the Mac can't use, is not better.
        let weak = [networks[0], Self.network("Home", "00:00:5e:00:53:11", rssi: -78, channel: 36, band: "5 GHz", width: 80)]
        #expect(SteeringReport.evaluate(radio: Self.radio(rssi: -45, channel: 6, band: "2.4 GHz"), networks: weak).map(\.kind) == [.fine])
        let six = [networks[0], Self.network("Home", "00:00:5e:00:53:12", rssi: -50, channel: 37, band: "6 GHz", width: 160)]
        #expect(SteeringReport.evaluate(radio: Self.radio(rssi: -45, channel: 6, band: "2.4 GHz"), networks: six, supportedBands: ["2.4 GHz", "5 GHz"]).map(\.kind) == [.fine])
        #expect(SteeringReport.evaluate(radio: Self.radio(rssi: -45, channel: 6, band: "2.4 GHz"), networks: six, supportedBands: ["2.4 GHz", "5 GHz", "6 GHz"]).map(\.kind) == [.bandSteering])
        // Already on 5 GHz: nothing to steer.
        #expect(SteeringReport.evaluate(radio: Self.radio(bssid: "00:00:5e:00:53:11", rssi: -55, channel: 36, band: "5 GHz", width: 80), networks: networks).map(\.kind) == [.fine])
        // A fast 2.4 GHz link (macOS's own transmit rate) leaves no room for a gain.
        #expect(SteeringReport.evaluate(radio: Self.radio(rssi: -45, channel: 6, band: "2.4 GHz", transmit: 900), networks: networks).map(\.kind) == [.fine])
    }

    @Test func bandSteeringWithoutAddressesSaysNetworkNotAccessPoint() {
        let networks = [NearbyNetwork(id: "hidden-0", ssid: "Home", rssi: -45, noise: 0, channel: 6, band: "2.4 GHz", widthMHz: 20),
                        NearbyNetwork(id: "hidden-1", ssid: "Home", rssi: -55, noise: 0, channel: 36, band: "5 GHz", widthMHz: 80)]
        let findings = SteeringReport.evaluate(radio: Self.radio(bssid: nil, rssi: -45, channel: 6, band: "2.4 GHz"), networks: networks)
        #expect(findings.map(\.kind) == [.bandSteering])
        #expect(findings[0].detail.contains("This network’s 5 GHz"))
    }

    @Test func stickyClientOnAFarNode() {
        var joined = Self.network("Home", "00:00:5e:00:53:10", rssi: -77, channel: 36, band: "5 GHz", width: 80)
        joined.details = AccessPointDetails()
        let networks = [joined, Self.network("Home", "00:00:5e:00:53:a0", rssi: -55, channel: 149, band: "5 GHz", width: 80)]
        let findings = SteeringReport.evaluate(radio: Self.radio(rssi: -77, channel: 36, band: "5 GHz", width: 80), networks: networks)
        #expect(findings.map(\.kind) == [.stickyClient])
        #expect(findings[0].detail.contains("-77 dBm") || findings[0].detail.contains("−77 dBm"))
        #expect(findings[0].advice?.contains("802.11k") == true)
        // 11 dB louder isn't clearly better, and at −65 dBm nothing is weak.
        let close = [joined, Self.network("Home", "00:00:5e:00:53:a0", rssi: -66, channel: 149, band: "5 GHz", width: 80)]
        #expect(SteeringReport.evaluate(radio: Self.radio(rssi: -77, channel: 36, band: "5 GHz", width: 80), networks: close).map(\.kind) == [.fine])
        #expect(SteeringReport.evaluate(radio: Self.radio(rssi: -65, channel: 36, band: "5 GHz", width: 80), networks: networks).map(\.kind) == [.fine])
        // Another network's strong radio is not a reason.
        let stranger = [joined, Self.network("Cafe", "00:00:5e:00:53:a0", rssi: -40, channel: 149, band: "5 GHz", width: 80)]
        #expect(SteeringReport.evaluate(radio: Self.radio(rssi: -77, channel: 36, band: "5 GHz", width: 80), networks: stranger).map(\.kind) == [.fine])
    }

    @Test func mostlyOnLowBandFromRoamHistory() {
        var log = RoamLog()
        let start = Date().addingTimeInterval(-3 * 3600)
        let low = NodeRadio(bssid: "00:00:5e:00:53:10", rssi: -60, channel: 6, band: "2.4 GHz", widthMHz: 20)
        for minute in stride(from: 0.0, through: 120, by: 2) {
            log.observe(NodeReading(date: start.addingTimeInterval(minute * 60), ssid: "Home", current: low, transmitMbps: nil, scan: []), network: "home")
        }
        let summary = RoamSummary(log, network: "home", since: Date().addingTimeInterval(-86_400))
        // The 5 GHz radio is too weak now for band steering, but it exists.
        let networks = [Self.network("Home", "00:00:5e:00:53:10", rssi: -60, channel: 6, band: "2.4 GHz"),
                        Self.network("Home", "00:00:5e:00:53:11", rssi: -74, channel: 36, band: "5 GHz", width: 80)]
        let findings = SteeringReport.evaluate(radio: Self.radio(rssi: -60, channel: 6, band: "2.4 GHz"), networks: networks, roams: summary)
        #expect(findings.map(\.kind) == [.mostlyLowBand])
        #expect(findings[0].detail.contains("100%"))
        #expect(SteeringReport.evaluate(radio: RadioSample.basic(ssid: nil, interface: nil, rssi: nil, noise: nil, transmitMbps: nil, channel: nil, band: nil), networks: networks).isEmpty)
    }

    // MARK: Scan CSV and notes

    @Test func scanCSVCarriesEveryFieldAndDefusesFormulas() throws {
        var details = AccessPointDetails()
        details.generation = .wifi7; details.streams = 2; details.maxRateMbps = 5764.7; details.widthMHz = 320; details.centerChannel = 31
        details.radioMeasurement = true; details.bssTransition = true; details.fastRoaming = true; details.mobilityDomain = "abcd"
        details.country = "US"; details.beaconInterval = 100; details.dtimPeriod = 1; details.stations = 4; details.channelUtilization = 0.25
        var security = AccessPointDetails.SecurityDetails(summary: "WPA3 Personal")
        security.keyManagement = ["SAE"]; security.pairwiseCiphers = ["GCMP-256"]; security.pmf = .required
        details.security = security
        var multi = AccessPointDetails.MultiLink(); multi.mldAddress = "02:00:5e:00:53:01"; multi.links = [.init(channel: 36, band: "5 GHz", bssid: nil)]
        details.multiLink = multi
        details.rates = [6, 12, 24]; details.basicRates = [6]
        let networks = [NearbyNetwork(id: "00:00:5e:00:53:10", ssid: "=HYPERLINK(\"x\")", rssi: -50, noise: -92, channel: 37, band: "6 GHz", widthMHz: 320, security: "WPA3 Personal", details: details),
                        NearbyNetwork(id: "hidden-1", ssid: "Hidden network", rssi: -80, noise: 0, channel: 6, band: "2.4 GHz", widthMHz: 20)]
        let csv = WiFiScanExport.csv(networks, date: Date(timeIntervalSince1970: 0), note: "Kitchen, door shut")
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("scanned,ssid,bssid,vendor,rssi_dbm"))
        #expect(lines[0].split(separator: ",").count == WiFiScanExport.header.count)
        #expect(lines[1].contains("\"'=HYPERLINK(\"\"x\"\")\""))
        #expect(lines[1].contains(",Wi-Fi 7,802.11be,2,5764.7,WPA3 Personal,SAE,GCMP-256,,required,no,yes,yes,yes,abcd,US,100,1,4,25,yes,02:00:5e:00:53:01,5 GHz ch 36,"))
        #expect(lines[1].hasSuffix("\"Kitchen, door shut\""))
        // Without details the beacon columns stay empty rather than saying "no".
        #expect(lines[2].contains(",-80,,,2.4 GHz,6,20,,no," + String(repeating: ",", count: 28) + "\"Kitchen, door shut\""))
    }

    @Test func savedScanNotesPersist() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-scan-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = SurveyJournal(directory: folder)
        journal.saveScan([Self.network("Home", "00:00:5e:00:53:10", rssi: -50, channel: 36, band: "5 GHz")])
        let id = try #require(journal.scans.first?.id)
        journal.setNote("  Office, after moving the router  ", for: id)
        #expect(SurveyJournal(directory: folder).scans.first?.note == "Office, after moving the router")
        journal.setNote("", for: id)
        #expect(SurveyJournal(directory: folder).scans.first?.note == nil)
        // Scans saved before notes (and before beacon details) still load.
        let old = #"[{"id":"\#(UUID().uuidString)","date":0,"networks":[{"id":"a","ssid":"Old","rssi":-60,"noise":-90,"channel":1,"band":"2.4 GHz","widthMHz":20}]}]"#
        try Data(old.utf8).write(to: folder.appendingPathComponent("scans.json"))
        let loaded = SurveyJournal(directory: folder).scans
        #expect(loaded.count == 1 && loaded[0].note == nil && loaded[0].networks[0].details == nil)
        #expect(WiFiScanExport.csv(loaded).split(separator: "\n").count == 2)
    }
}
