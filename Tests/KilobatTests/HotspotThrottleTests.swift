import Foundation
import Testing
@testable import KilobatCore

/// Hotspot throttling: a carrier's flat cap told apart from congestion, a weak signal and too little data; video held
/// near 1.5 Mbps; the carrier from the public address's network; the words; the CLI's arguments.
struct HotspotThrottleTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// 4 January 2027 at `hour`:`minute` UTC, `day` days later.
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2027, month: 1, day: 4, hour: hour, minute: minute))!.addingTimeInterval(Double(day) * 86_400)
    }
    private var now: Date { at(2, 12) }
    private let network = "hotspot-net"

    private func test(_ date: Date, _ mbps: Double, ping: Double = 45, network: String? = nil) -> SavedSpeedTest {
        let samples = (0..<5).map { _ in String(ping) }.joined(separator: ",")
        let result = #"{"date":\#(date.timeIntervalSinceReferenceDate),"downloadMbps":\#(mbps),"uploadMbps":2,"baseline":{"host":"t","samples":[\#(samples)],"lossPercent":0},"downloadLoaded":{"host":"t","samples":[90],"lossPercent":0},"uploadLoaded":{"host":"t","samples":[90],"lossPercent":0},"downloadSeconds":8,"uploadSeconds":8,"transferredBytes":10000000}"#
        let json = #"{"id":"\#(UUID().uuidString)","networkKey":"\#(network ?? self.network)","networkName":"Rita’s iPhone","result":\#(result)}"#
        return try! JSONDecoder().decode(SavedSpeedTest.self, from: Data(json.utf8))
    }
    private func download(_ date: Date, _ mbps: Double) -> ServiceTransfer {
        ServiceTransfer(date: date, seconds: 40, bytes: UInt64(mbps * 125_000 * 40), mbps: mbps, otherMbps: 0)
    }
    private func pings(_ dates: [Date], ms: Double = 48, jitter: Double = 6, loss: Double = 0) -> [HotspotLatency] {
        dates.map { HotspotLatency(date: $0.addingTimeInterval(120), ms: ms, jitterMs: jitter, lossPercent: loss) }
    }
    private func report(kind: HotspotKind? = .iPhone, tests: [SavedSpeedTest] = [], transfers: [String: [ServiceTransfer]] = [:],
                        latency: [HotspotLatency] = [], video: [HotspotVideoSession] = [], carrier: HotspotThrottleReport.Carrier? = nil) -> HotspotThrottleReport {
        HotspotThrottleReport(network: network, networkName: "Rita’s iPhone", kind: kind, transfers: transfers, speedTests: tests, latency: latency,
                              video: video, carrier: carrier, now: now)
    }

    /// Speed tests and downloads from two services, on two days, all within a few percent of 2.9 Mbps.
    private var capped: (tests: [SavedSpeedTest], transfers: [String: [ServiceTransfer]], dates: [Date]) {
        let dates = [at(0, 9), at(0, 15), at(1, 10), at(1, 19), at(2, 8), at(2, 11)]
        let tests = [test(dates[0], 2.91), test(dates[3], 2.86)]
        let transfers = ["github": [download(dates[1], 2.94), download(dates[4], 2.88)], "apple": [download(dates[2], 2.83), download(dates[5], 2.95)]]
        return (tests, transfers, dates)
    }

    // MARK: A flat cap

    @Test func flatLineAtACommonLimitIsACap() {
        let sample = capped
        let report = report(tests: sample.tests, transfers: sample.transfers, latency: pings(sample.dates))
        #expect(report.state == .cap)
        #expect(report.capMbps == 3 && report.atCeiling == 6 && report.showsFinding)
        #expect(report.headline == "Looks like your carrier’s hotspot cap: every download on this hotspot topped out near 3 Mbps.")
        #expect(report.detail.contains("6 measurements on 3 days") && report.detail.contains("not certain"))
        #expect(report.advice.count == 4 && report.advice[0].contains("hotspot data is left"))
        #expect(report.advice.contains { $0.contains("phone’s own browser") })
        // Never advice on hiding hotspot use.
        #expect(!report.advice.joined().lowercased().contains("ttl") && !report.advice.joined().lowercased().contains("vpn"))
        #expect(report.evidence.count == 7)
    }

    @Test func carrierNamesTheCapAndItsPage() {
        let sample = capped, carrier = HotspotThrottleReport.Carrier(HotspotCarriers.carrier("t-mobile")!, source: "lookup")
        let report = report(tests: sample.tests, transfers: sample.transfers, latency: pings(sample.dates), carrier: carrier)
        #expect(report.headline == "Looks like T-Mobile’s hotspot cap: every download on this hotspot topped out near 3 Mbps.")
        #expect(report.advice[0].contains("T-Mobile app"))
        #expect(report.carrier?.page.absoluteString == "https://kilobat.app/hotspot-limits/t-mobile")
        #expect(report.carrier?.sharedWith == ["mint-mobile"])
        #expect(report.text.contains("https://kilobat.app/hotspot-limits/t-mobile"))
    }

    @Test func slowCapsAreNamedInKilobits() {
        let dates = [at(0, 9), at(0, 14), at(1, 9), at(1, 16)]
        let tests = [test(dates[0], 0.57), test(dates[2], 0.58)]
        let transfers = ["npm": [download(dates[1], 0.56)], "github": [download(dates[3], 0.57)]]
        let report = report(tests: tests, transfers: transfers, latency: pings(dates))
        #expect(report.state == .cap && report.capMbps == 0.6)
        #expect(report.headline.hasSuffix("near 600 kbps."))
    }

    // MARK: Not a cap

    @Test func congestionIsNotACap() {
        // The same flat line, but the ping is up at 320 ms: a busy cell queues, a cap doesn't.
        let sample = capped
        let report = report(tests: sample.tests, transfers: sample.transfers, latency: pings(sample.dates, ms: 320, jitter: 60))
        #expect(report.state == .learning && !report.showsFinding)
        // Speeds that wander are a busy cell or the signal.
        let wandering = [at(0, 9): 2.1, at(0, 13): 7.8, at(1, 10): 4.4, at(1, 18): 11.2, at(2, 9): 3.0]
        let tests = wandering.map { test($0.key, $0.value) }
        let busy = self.report(tests: tests, latency: pings(Array(wandering.keys), ms: 140))
        #expect(busy.state == .noCap && busy.headline == "No sign of a hotspot cap")
        #expect(busy.detail.contains("ranged from 2.1 Mbps to 11 Mbps"))
    }

    @Test func weakSignalIsNotACap() {
        // A weak signal: jitter and loss, speeds that come and go.
        let dates = [at(0, 9), at(0, 15), at(1, 10), at(1, 19), at(2, 8)]
        let speeds = [0.9, 2.6, 1.4, 3.8, 0.7]
        let tests = zip(dates, speeds).map { test($0, $1, ping: 95) }
        let report = report(tests: tests, latency: pings(dates, ms: 95, jitter: 70, loss: 6))
        #expect(report.state == .noCap)
        // Flat but lossy: still not called.
        let sample = capped
        let lossy = self.report(tests: sample.tests, transfers: sample.transfers, latency: pings(sample.dates, loss: 5))
        #expect(lossy.state != .cap)
    }

    @Test func tooLittleDataWaits() {
        // Three measurements.
        let dates = [at(0, 9), at(1, 9), at(2, 9)]
        let few = report(tests: dates.map { test($0, 2.9) }, latency: pings(dates))
        #expect(few.state == .learning && few.detail.contains("So far: 3"))
        // Enough of them, but all within twenty minutes.
        let burst = [at(2, 9), at(2, 9, 5), at(2, 9, 10), at(2, 9, 20)]
        let once = report(tests: burst.prefix(2).map { test($0, 2.9) }, transfers: ["github": burst.suffix(2).map { download($0, 2.9) }], latency: pings(burst))
        #expect(once.state == .learning)
        // Enough, but from one source only: a slow server looks flat too.
        let one = report(transfers: ["github": capped.dates.map { download($0, 2.9) }], latency: pings(capped.dates))
        #expect(one.state == .learning)
        // No ping to go with them: downloads only (a speed test brings its own idle ping).
        var transfers = capped.transfers
        transfers["npm"] = [download(at(0, 20), 2.9), download(at(1, 7), 2.92)]
        let quiet = report(transfers: transfers)
        #expect(quiet.state == .learning && quiet.detail.contains("no normal ping"))
    }

    @Test func oneFasterDownloadMeansNoCap() {
        let sample = capped
        var transfers = sample.transfers
        transfers["steam"] = [download(at(1, 12), 9.5)]
        let report = report(tests: sample.tests, transfers: transfers, latency: pings(sample.dates))
        #expect(report.state != .cap)
    }

    @Test func aSpeedTestsOwnTrafficIsntCountedTwice() {
        // The speed test's download shows up in service speed too, 20 seconds later.
        let t = test(at(0, 9), 2.9)
        let report = report(tests: [t], transfers: ["net:cloudflare": [download(at(0, 9).addingTimeInterval(20), 2.9)]])
        #expect(report.measurements.count == 1)
    }

    @Test func onlyOnHotspots() {
        let sample = capped
        let home = report(kind: nil, tests: sample.tests, transfers: sample.transfers, latency: pings(sample.dates))
        #expect(home.state == .notHotspot && !home.showsFinding)
        let bluetooth = report(kind: .bluetooth, tests: sample.tests, transfers: sample.transfers, latency: pings(sample.dates))
        #expect(bluetooth.state == .noCap && bluetooth.headline.contains("Bluetooth"))
    }

    @Test func hotspotKinds() {
        #expect(HotspotKind.classify(metered: true, gateway: "172.20.10.1", service: "Wi-Fi") == .iPhone)
        #expect(HotspotKind.classify(metered: false, gateway: "172.20.10.1", service: "iPhone USB") == .iPhone)
        #expect(HotspotKind.classify(metered: false, gateway: "192.168.43.1", service: "Wi-Fi") == .android)
        #expect(HotspotKind.classify(metered: true, gateway: "172.20.10.1", service: "Bluetooth PAN") == .bluetooth)
        #expect(HotspotKind.classify(metered: true, gateway: "10.0.0.1", service: "Wi-Fi") == .metered)
        #expect(HotspotKind.classify(metered: false, gateway: "192.168.1.1", service: "Wi-Fi") == nil)
    }

    // MARK: Video

    private func video(_ date: Date, _ peak: Double, _ service: String = "youtube") -> HotspotVideoSession {
        HotspotVideoSession(date: date, service: service, seconds: 600, bytes: UInt64(peak * 125_000 * 600), peakMbps: peak)
    }

    @Test func videoHeldNearOneAndAHalfWhileTheRestIsFast() {
        let sessions = [video(at(0, 20), 1.46), video(at(1, 20), 1.41, "netflix"), video(at(1, 22), 1.49), video(at(2, 9), 1.44)]
        let fast = [at(0, 10): 12.4, at(1, 11): 14.1, at(2, 10): 11.8]
        let report = report(tests: fast.map { test($0.key, $0.value) }, transfers: ["apple": [download(at(1, 15), 3.1)]], latency: pings(Array(fast.keys)), video: sessions)
        #expect(report.state == .videoCap && report.showsFinding)
        #expect(report.headline.hasPrefix("Looks like your carrier’s video limit: video on this hotspot topped out near 1.5 Mbps while other downloads ran at 12 Mbps."))
        #expect(report.detail.contains("Netflix and YouTube"))
        #expect(report.advice[0].contains("480p"))
    }

    @Test func slowVideoOnASlowLineIsNotAVideoLimit() {
        let sessions = [video(at(0, 20), 1.46), video(at(1, 20), 1.41), video(at(2, 9), 1.44)]
        let report = report(tests: [test(at(1, 10), 2.0)], video: sessions)
        #expect(report.state != .videoCap)
        // Fast video is no limit either.
        let open = self.report(tests: [test(at(0, 10), 12), test(at(1, 10), 13)], video: [video(at(0, 20), 9), video(at(1, 20), 11), video(at(2, 9), 10)])
        #expect(open.state != .videoCap)
    }

    @Test func videoMeterTimesBusySeconds() {
        var meter = HotspotVideoMeter(), ended: [HotspotVideoSession] = []
        func sample(_ second: Int, _ received: UInt64) -> TrafficSnapshot {
            let connection = ConnectionTraffic(id: "tcp4 172.20.10.2:50000<->142.250.1.1:443", route: .internet, interface: "en0", received: received, sent: 1_000)
            return TrafficSnapshot(timestamp: at(0, 20).addingTimeInterval(Double(second)), processes: [ProcessTraffic(pid: 77, process: "Safari", received: 0, sent: 0, connections: [connection])])
        }
        // 1.5 Mbps (187.5 KB/s) for 100 seconds, then quiet.
        for second in 0...100 { ended += meter.ingest(sample(second, UInt64(second) * 187_500)) { _, _ in "youtube" } }
        for second in 101...140 { ended += meter.ingest(sample(second, 100 * 187_500)) { _, _ in "youtube" } }
        #expect(ended.count == 1)
        #expect(abs((ended.first?.peakMbps ?? 0) - 1.5) < 0.01 && ended.first?.seconds == 100)
        // Not video: nothing.
        var other = HotspotVideoMeter(), none: [HotspotVideoSession] = []
        for second in 0...140 { none += other.ingest(sample(second, UInt64(min(second, 100)) * 187_500)) { _, _ in nil } }
        #expect(none.isEmpty)
    }

    @Test func videoServicesByHostAndNetwork() {
        #expect(ServiceSpeedCatalog.video(host: "rr3---sn-abc.googlevideo.com", reverse: nil, owner: nil) == "youtube")
        #expect(ServiceSpeedCatalog.video(host: nil, reverse: nil, owner: "netflix") == "netflix")
        #expect(ServiceSpeedCatalog.video(host: "objects.githubusercontent.com", reverse: nil, owner: "netflix") == nil)
        #expect(ServiceSpeedCatalog.video(host: "audio-ak.spotifycdn.com", reverse: nil, owner: nil) == nil)
    }

    // MARK: Carriers

    @Test func carriersFromTheAddressesNetwork() {
        #expect(HotspotCarriers.match(asn: 21928, organization: nil, country: "US")?.id == "t-mobile")
        #expect(HotspotCarriers.match(asn: 22394, organization: "CELLCO - Cellco Partnership DBA Verizon Wireless", country: "US")?.id == "verizon")
        #expect(HotspotCarriers.match(asn: 99999, organization: "Vodafone Limited", country: "GB")?.id == "vodafone-uk")
        #expect(HotspotCarriers.match(asn: nil, organization: "Vodafone GmbH", country: "DE")?.id == "vodafone-de")
        #expect(HotspotCarriers.match(asn: nil, organization: "Hutchison 3G UK Limited", country: "GB")?.id == "three-uk")
        #expect(HotspotCarriers.match(asn: 7922, organization: "COMCAST-7922 - Comcast Cable Communications, LLC", country: "US") == nil)
        // MVNOs share their host's addresses: only ever picked.
        #expect(HotspotCarriers.all.filter { $0.asns.isEmpty }.map(\.id) == ["visible", "mint-mobile"])
        #expect(HotspotCarriers.find("TMobile")?.id == "t-mobile" && HotspotCarriers.find("Free Mobile")?.id == "free-mobile" && HotspotCarriers.find("nope") == nil)
        #expect(HotspotCarriers.choices(country: "gb").first?.country == "GB")
        #expect(Set(HotspotCarriers.all.map(\.id)).count == HotspotCarriers.all.count)
    }


    @Test func pickedCarrierWinsOverTheLookup() {
        var log = HotspotLog()
        log.seen(network, name: "Rita’s iPhone", kind: .iPhone, now: now)
        log.networks[network]?.lookup = HotspotLog.Lookup(carrier: "verizon", asn: 22394, organization: "Cellco", country: "US", date: now)
        #expect(log.carrier(for: network)?.id == "verizon" && log.carrier(for: network)?.source == "lookup")
        log.networks[network]?.carrier = "visible"
        #expect(log.carrier(for: network)?.id == "visible" && log.carrier(for: network)?.source == "you")
    }

    @Test func logKeepsTwoWeeksOfVideo() {
        var log = HotspotLog()
        log.add(video(at(-20, 9), 1.5), network: network, name: "Phone", now: now)
        log.add(video(at(1, 9), 1.5), network: network, name: "Phone", now: now)
        #expect(log.networks[network]?.video.count == 1)
    }

    // MARK: The CLI

    @Test func options() throws {
        #expect(try HotspotThrottleReport.Options.parse(["hotspot"]) == HotspotThrottleReport.Options())
        let parsed = try HotspotThrottleReport.Options.parse(["hotspot", "--all", "--carrier", "ee", "--json"])
        #expect(parsed.all && parsed.json && parsed.carrier == "ee" && !parsed.detect)
        #expect(try HotspotThrottleReport.Options.parse(["carriers", "--json"]).carriers)
        #expect(try HotspotThrottleReport.Options.parse(["--detect"]).detect)
        #expect(throws: DiagnosticError.self) { try HotspotThrottleReport.Options.parse(["--carrier"]) }
        #expect(throws: DiagnosticError.self) { try HotspotThrottleReport.Options.parse(["--carrier", "--json"]) }
        #expect(throws: DiagnosticError.self) { try HotspotThrottleReport.Options.parse(["--detect", "--carrier", "ee"]) }
        #expect(throws: DiagnosticError.self) { try HotspotThrottleReport.Options.parse(["carriers", "--all"]) }
        #expect(throws: DiagnosticError.self) { try HotspotThrottleReport.Options.parse(["--verbose"]) }
    }

    @Test func reportRoundTripsAsJSON() throws {
        let sample = capped
        let report = report(tests: sample.tests, transfers: sample.transfers, latency: pings(sample.dates))
        let data = try JSONEncoder().encode(report)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["state"] as? String == "cap" && object?["capMbps"] as? Double == 3 && object?["kind"] as? String == "iPhone")
        #expect((object?["carriersPage"] as? String)?.hasSuffix("/hotspot-limits") == true)
    }
}
