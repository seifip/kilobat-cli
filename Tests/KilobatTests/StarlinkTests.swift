import Foundation
import Testing
@testable import KilobatCore

/// Starlink support without a dish: protobuf answers written by script/starlink_mock.py from the published field
/// numbers. The online status mirrors a real recording (faeton/dishwatch, MIT, API 42, firmware 2026.08.10).
struct StarlinkTests {
    private func message(_ base64: String) throws -> ProtoMessage { try #require(ProtoMessage(Data(base64Encoded: base64)!)) }
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func theRecordedStatusDecodes() throws {
        let status = try #require(StarlinkStatus(response: try message(StarlinkFixtures.statusOnline)))
        #expect(status.state == .online && status.online)
        #expect(status.software == "2026.08.10.mr84226" && status.hardware == "rev3_proto2")
        #expect(status.uptimeSeconds == 3900)
        #expect(abs((status.popLatencyMs ?? 0) - 44.466) < 0.01)
        #expect(abs((status.downlinkBps ?? 0) - 7_415_655.5) < 1)
        #expect(abs((status.fractionObstructed ?? 0) - 0.001236) < 0.00001)
        #expect(status.currentlyObstructed == false)
        // The recording's interval is NaN: no prolonged obstructions to report.
        #expect(status.obstructionIntervalSeconds == nil && status.obstructionDurationSeconds == nil)
        // obstruction_map_reset is set, and isn't something to show.
        #expect(status.alerts.isEmpty)
        #expect(status.update == .idle && !status.updatePending)
        // int32 −1 travels as a ten-byte varint.
        #expect(status.secondsUntilUpdateReboot == -1)
        #expect(status.mobility == "mobile" && status.ethernetMbps == 1000)
        #expect(abs((status.azimuth ?? 0) + 173.2) < 0.01)
    }

    @Test func anObstructedDishWithAlertsDecodes() throws {
        let status = try #require(StarlinkStatus(response: try message(StarlinkFixtures.statusObstructed), now: now))
        #expect(status.state == .obstructed && !status.online)
        #expect(status.outage?.cause == .obstructed && status.outage?.seconds == 8)
        #expect(Set(status.alerts) == [.thermalThrottle, .heating, .updatePending])
        #expect(status.updatePending && status.rebootReady == true && status.update == .rebootRequired)
        #expect(status.currentlyObstructed == true)
        #expect(abs((status.obstructionDurationSeconds ?? 0) - 2.4) < 0.001 && status.obstructionIntervalSeconds == 290)
        #expect(status.stateTitle == "Obstructed")
    }

    @Test func theHistoryRingUnwrapsOldestFirst() throws {
        let history = try #require(StarlinkHistory(response: try message(StarlinkFixtures.history), now: now))
        // 25 samples written into 20 slots: the oldest kept is the 6th, 20 + 5 ms.
        #expect(history.latencyMs.count == 20)
        #expect(history.latencyMs.first == 25 && history.latencyMs.last == 44)
        // The third-newest lost every ping, so it has no latency.
        #expect(history.latencyMs[17] == nil && history.latencyMs[16] == 41)
        #expect(history.bytes.down == 20 * 8e6 / 8)
        #expect(history.outages.map(\.cause) == [.noSatellites, .obstructed])
        #expect(history.outages[0].seconds == 4.5 && history.outages[0].didSwitch == true && history.outages[0].side == .network)
        #expect(history.outages[1].side == .setup)
        #expect(abs(history.outages[0].start.timeIntervalSince(now) + 300) < 0.01)
    }

    @Test func aRingStillFillingKeepsOnlyWhatWasWritten() throws {
        let floats = [10, 11, 12, 0, 0].flatMap { (value: Float) -> [UInt8] in withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) } }
        let body = ProtoWriter.field(1, varint: 3) + ProtoWriter.field(1002, message: floats) + ProtoWriter.field(1001, message: Array(repeating: 0, count: 20))
        let response = try #require(ProtoMessage(ProtoWriter.field(2006, message: body)))
        let history = try #require(StarlinkHistory(response: response, now: now))
        #expect(history.latencyMs == [10, 11, 12])
    }

    @Test func theSkyMapSaysWhichWayIsBlocked() throws {
        let map = try #require(StarlinkSkyMap(response: try message(StarlinkFixtures.skyMap)))
        #expect(map.rows == 41 && map.columns == 41 && map.earthFrame)
        #expect(map.mapped)
        let worst = try #require(map.blockedSectors.first)
        #expect(worst.index == 1)
        #expect((worst.elevation ?? 90) < 45)
        #expect(!map.blockedSectors.contains { [3, 4, 5, 6].contains($0.index) })
        let advice = map.advice()
        #expect(advice.contains("north-east") && advice.contains("low in the sky"))
        #expect(map.advice(mobile: true).contains("Park"))
    }

    @Test func anEmptyOrClearMapSaysSo() {
        let clear = StarlinkSkyMap(rows: 21, columns: 21, snr: Array(repeating: 1, count: 441))
        #expect(clear.blockedSectors.isEmpty && clear.advice().hasPrefix("Clear"))
        let empty = StarlinkSkyMap(rows: 21, columns: 21, snr: Array(repeating: -1, count: 441))
        #expect(!empty.mapped && empty.advice().contains("still mapping"))
    }

    @Test func outageTimesReadAsUnixOrGPSWhicheverIsPlausible() {
        let when = now.addingTimeInterval(-600)
        let unix = Int64(when.timeIntervalSince1970 * 1e9)
        #expect(StarlinkOutage.date(nanoseconds: unix, now: now) == when)
        let gps = Int64((when.timeIntervalSince1970 - 315_964_800 + 18) * 1e9)
        #expect(abs(StarlinkOutage.date(nanoseconds: gps, now: now)!.timeIntervalSince(when)) < 0.001)
        #expect(StarlinkOutage.date(nanoseconds: 5, now: now) == nil)
    }

    @Test func causesSplitIntoYourSetupAndTheirNetwork() {
        #expect(StarlinkOutage.Cause(code: 6).side == .setup)
        #expect(StarlinkOutage.Cause(code: 5).side == .network && StarlinkOutage.Cause(code: 4).side == .network && StarlinkOutage.Cause(code: 8).side == .network)
        #expect(StarlinkOutage.Cause(code: 1).side == .dish)
        #expect(StarlinkOutage.Cause(code: 99) == .unknown)
    }

    @Test func spikesOnTheFifteenSecondScheduleAreHandovers() {
        let minute = Date(timeIntervalSince1970: 1_790_000_040) // :00 past a minute
        #expect(Starlink.nearHandover(minute.addingTimeInterval(12.4)))
        #expect(Starlink.nearHandover(minute.addingTimeInterval(56.2)))
        #expect(!Starlink.nearHandover(minute.addingTimeInterval(20)))
        #expect(Starlink.alignedWithHandovers([12.3, 27.6, 42.1, 57.9].map { minute.addingTimeInterval($0) }))
        #expect(!Starlink.alignedWithHandovers([5, 20, 35, 50].map { minute.addingTimeInterval($0) }))
        // One handover twice over (its start and its end) isn't a pattern yet.
        #expect(!Starlink.alignedWithHandovers([12.3, 12.9].map { minute.addingTimeInterval($0) }))
        #expect(Starlink.alignedWithHandovers([12.3, 27.6].map { minute.addingTimeInterval($0) }))
    }

    @Test func theStutterVerdictNamesStarlinkHandovers() {
        // A 20-second test from :10 spans the handovers at :12 and :27.
        let start = Date(timeIntervalSince1970: 1_790_000_050)
        var samples = [Double?](repeating: 40, count: 400)
        func spike(_ second: Double) { for offset in 0..<4 { samples[Int(second / 0.05) + offset] = 210 } }
        spike(2.2); spike(17.3); spike(8)
        let more = StutterTest.analyze(samples, target: "internet", host: "1.1.1.1", started: start, starlink: true)
        #expect(more.spikes.count == 3 && more.handoverAligned)
        #expect(more.verdict.contains("Starlink"))
        spike(5)
        #expect(!StutterTest.analyze(samples, target: "internet", host: "1.1.1.1", started: start, starlink: true).handoverAligned) // two of four
        samples[Int(5 / 0.05)..<Int(5 / 0.05) + 4] = [40, 40, 40, 40]
        #expect(!StutterTest.analyze(samples, target: "internet", host: "1.1.1.1", started: start, starlink: false).verdict.contains("Starlink"))
        #expect(!StutterTest.analyze(samples, target: "router", host: "192.168.1.1", started: start, starlink: true).verdict.contains("Starlink"))
    }

    @Test func aCallFreezeDuringADishOutageBlamesStarlink() {
        var samples = CallSamples()
        samples.internet = (0..<600).map { .init(at: Double($0), ms: (300..<304).contains($0) ? nil : 30) }
        samples.router = (0..<600).map { .init(at: Double($0), ms: 3) }
        samples.traffic = [.init(at: 300, app: "Dropbox", upload: 900_000, download: 0)]
        samples.dish = [CallSamples.Dish(at: 299, seconds: 4, reason: "obstructed")]
        let report = CallAnalysis.report(app: "Zoom", browser: false, start: now, end: now.addingTimeInterval(600), network: nil, samples: samples)
        let cause = report.freezes.first?.cause
        #expect(cause?.kind == .starlink && cause?.dish == "obstructed")
        #expect(report.verdict.contains("blocked the Starlink dish"))
        #expect(report.advice?.contains("Starlink") == true)
        samples.dish = [CallSamples.Dish(at: 301, seconds: 10, reason: "noSatellites")]
        #expect(CallAnalysis.report(app: "Zoom", browser: false, start: now, end: now.addingTimeInterval(600), network: nil, samples: samples).freezes.first?.cause.dish == "noSatellites")
        // The router stalling too still points at the Wi-Fi.
        samples.router = (0..<600).map { .init(at: Double($0), ms: (300..<304).contains($0) ? nil : 3) }
        #expect(CallAnalysis.report(app: "Zoom", browser: false, start: now, end: now.addingTimeInterval(600), network: nil, samples: samples).freezes.first?.cause.kind == .wifi)
    }

    @Test func dishSamplesComeFromOutagesAndObstructions() throws {
        let outage = StarlinkOutage(cause: .booting, start: now.addingTimeInterval(30), seconds: 40)
        let sample = try #require(CallSamples.Dish(outage: outage, start: now))
        #expect(sample.at == 30 && sample.seconds == 40 && sample.reason == "reboot")
        #expect(CallSamples.Dish(outage: StarlinkOutage(cause: .noPings, start: now.addingTimeInterval(-100), seconds: 5), start: now) == nil)
        var status = StarlinkStatus(state: .online)
        status.date = now.addingTimeInterval(60); status.currentlyObstructed = true
        #expect(CallSamples.Dish(status: status, start: now)?.reason == "obstructed")
        // Old calls still decode: the new fields are optional.
        let old = #"{"kind":"beyondRouter"}"#
        #expect(try JSONDecoder().decode(CallReport.Cause.self, from: Data(old.utf8)).dish == nil)
    }

    @Test func theProviderReportSeparatesYourSetupFromTheirNetwork() {
        let outages = [StarlinkOutage(cause: .noSatellites, start: now.addingTimeInterval(-3600), seconds: 90),
                       StarlinkOutage(cause: .obstructed, start: now.addingTimeInterval(-1800), seconds: 30),
                       StarlinkOutage(cause: .booting, start: now.addingTimeInterval(-900), seconds: 60),
                       StarlinkOutage(cause: .noPings, start: now.addingTimeInterval(-90_000), seconds: 600)]
        let evidence = StarlinkEvidence.make(outages: outages, status: nil, since: now.addingTimeInterval(-86_400), now: now)
        #expect(evidence.outages.count == 3)
        #expect(evidence.networkSeconds == 90 && evidence.setupSeconds == 30 && evidence.dishSeconds == 60)
        let finding = evidence.finding ?? ""
        #expect(finding.contains("3 outages") && finding.contains("no satellite") && finding.contains("obstructions"))
        let report = SupportReport.make(samples: [], events: [], speedTests: [], hours: 24, starlink: evidence, mac: "Mac", now: now)
        #expect(report.findings == [finding])
        #expect(report.text.contains("Starlink dish log") && report.text.contains("Starlink’s network"))
        #expect(report.markdown.contains("## Starlink dish log") && report.html.contains("Starlink dish log"))
        #expect(report.leftOut.contains { $0.contains("serial number") })
        // Without a dish, nothing changes.
        let plain = SupportReport.make(samples: [], events: [], speedTests: [], hours: 24, mac: "Mac", now: now)
        #expect(plain.starlink == nil && !plain.text.contains("Starlink"))
    }

    @Test func theJournalKeepsEachOutageOnceAtItsLongest() {
        var journal = StarlinkJournal()
        let start = Date().addingTimeInterval(-60)
        journal.merge([StarlinkOutage(cause: .obstructed, start: start, seconds: 2)])
        journal.merge([StarlinkOutage(cause: .obstructed, start: start.addingTimeInterval(0.5), seconds: 6), StarlinkOutage(cause: .noSatellites, start: start, seconds: 1)])
        #expect(journal.outages.count == 2)
        #expect(journal.outages.first { $0.cause == .obstructed }?.seconds == 6)
        journal.network = "net"; journal.lastSeen = Date()
        #expect(journal.evidence(network: "net", hours: 24)?.outages.count == 2)
        #expect(journal.evidence(network: "other", hours: 24) == nil)
    }

    @Test func gRPCWebFramesSplitIntoMessageAndTrailer() {
        let body = StarlinkWire.frame([1, 2, 3]) + [0x80, 0, 0, 0, 15] + Array("grpc-status: 0\r\n".utf8.prefix(15))
        let parts = StarlinkWire.unframe(body)
        #expect(parts?.messages == [[1, 2, 3]] && parts?.status == 0)
        #expect(StarlinkWire.unframe([0, 0, 0, 0, 9, 1]) == nil)
        #expect(ProtoMessage([0x0a, 0x05, 0x01]) == nil)
    }

    @Test func theHTTP2ReaderGathersStreamOneAndAnswersSettings() {
        var reader = H2C.Reader()
        let settings = H2C.frame(type: 4, flags: 0, stream: 0, payload: [0, 3, 0, 0, 0, 100])
        let headers = H2C.frame(type: 1, flags: 4, stream: 1, payload: [0x88])
        let grpc = StarlinkWire.frame([8, 1])
        // DATA split in two, the first padded.
        let first = H2C.frame(type: 0, flags: 0x8, stream: 1, payload: [2] + Array(grpc.prefix(3)) + [0, 0])
        let second = H2C.frame(type: 0, flags: 0, stream: 1, payload: Array(grpc.dropFirst(3)))
        let trailers = H2C.frame(type: 1, flags: 5, stream: 1, payload: [0x40])
        let bytes = settings + headers + first + second + trailers
        // Fed a byte at a time, as TCP may deliver it.
        var replies: [UInt8] = []
        for byte in bytes { replies += reader.feed([byte]) }
        #expect(replies == H2C.frame(type: 4, flags: 1, stream: 0, payload: []))
        #expect(reader.ended && reader.message == [8, 1])
    }

    @Test func theOpeningIsAValidPrefaceAndHeaders() {
        let opening = H2C.opening(host: "192.168.100.1", port: 9200, path: StarlinkWire.path, message: StarlinkWire.frame([0xe2, 0x3e, 0]))
        #expect(Array(opening.prefix(24)) == H2C.preface)
        #expect(H2C.integer(10, prefix: 7) == [10])
        #expect(H2C.integer(300, prefix: 7) == [127, 173, 1])
        // The request for get_status: field 1004, an empty message.
        #expect(ProtoWriter.field(1004, message: []) == [0xe2, 0x3e, 0])
    }
}

enum StarlinkFixtures {
    static let statusOnline = "CAAYKqJ97AEKRgocdXQwMTAwMDAwMC0wMDAwMDAwMC0wMDAwZml4dBILcmV2M19wcm90bzIaEjIwMjYuMDguMTAubXI4NDIyNiICR0xAvwoSAwi8HtU+sg3VTuI+Fw1uBKI6JQDo10U9AADAf002EZI6UKQZ6j4DmAEB/T7PTuJKhT81Q6pHjT9g3TFCnT9UNC3DpT+nU6BCuj8ECAEQEcA/6AfIPwLQPwHgPwHoPwH4PwGAQAGIQAGSQAIIAbhA////////////AYJBH1JvdXRlci0wMTAwMDAwMDAwMDAwMDAwMDBFQzAwRTiCfQUIA8g+AQ=="
    static let statusObstructed = "CAAYKqJ9mQEKPgocdXQwMTAwMDAwMC0wMDAwMDAwMC0wMDAwZml4dBIKcmV2NF9wcm9kMRoSMjAyNi4xMC4wMi5tcjkwMDAxEgQIsMwL4j4WKAENlkMLPSUAwChHNZqZGUA9AACRQ+o+BhgBSAFAAbI/EggGEIDg8rik8NbrGBiAoNnmHd0+AACAP50/AABIQaU/AACAQug/BrBAAbhAkBw="
    static let history = "CAAYKrJ9+gIIGco+UAAAAAAAAAAAAACAPwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA0j5QAAAgQgAAJEIAAChCAAAsQgAAMEIAAMhBAADQQQAA2EEAAOBBAADoQQAA8EEAAPhBAAAAQgAABEIAAAhCAAAMQgAAEEIAABRCAAAYQgAAHELaPlAAJPRKACT0SgAk9EoAJPRKACT0SgAk9EoAJPRKACT0SgAk9EoAJPRKACT0SgAk9EoAJPRKACT0SgAk9EoAJPRKACT0SgAk9EoAJPRKACT0SuI+UAAkdEkAJHRJACR0SQAkdEkAJHRJACR0SQAkdEkAJHRJACR0SQAkdEkAJHRJACR0SQAkdEkAJHRJACR0SQAkdEkAJHRJACR0SQAkdEkAJHRJij8UCAUQgJC51OTn1usYGICa4uEQIAGKPxIIBhCAoJGbg+3W6xgYgKjWuQc="
    static let skyMap = "CAAYKsJ91zQIKRApGsQ0AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgD8AAIA/AACAPwAAgL8AAIA/AACAPwAAgL8AAIA/AACAPwAAgD8AAIA/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgD8AAIA/AACAPwAAgD8AAIA/AACAPwAAgL8AAIA/AACAPwAAgL8AAIA/AACAPwAAgD8AAIA/AAAAAAAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgD8AAIA/AACAvwAAgD8AAIA/AACAPwAAgD8AAIA/AACAPwAAgL8AAIA/AACAPwAAgL8AAIA/AACAPwAAgD8AAAAAAAAAAAAAAAAAAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIA/AACAvwAAgD8AAIA/AACAvwAAgD8AAIA/AACAPwAAgD8AAIA/AACAPwAAgL8AAIA/AACAPwAAgL8AAIA/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAPwAAgD8AAIA/AACAvwAAgD8AAIA/AACAvwAAgD8AAIA/AACAPwAAgD8AAIA/AACAPwAAgL8AAIA/AACAPwAAgL8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgD8AAIA/AACAPwAAgD8AAIA/AACAvwAAgD8AAIA/AACAvwAAgD8AAIA/AACAPwAAgD8AAIA/AACAPwAAgL8AAIA/AAAAAAAAgL8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAPwAAgD8AAIA/AACAPwAAgD8AAIA/AACAvwAAgD8AAIA/AACAvwAAgD8AAIA/AACAPwAAgD8AAIA/AACAPwAAgL8AAIA/AAAAAAAAgL8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgD8AAIC/AACAPwAAgD8AAIA/AACAPwAAgD8AAIA/AACAvwAAgD8AAIA/AACAvwAAgD8AAIA/AACAPwAAgD8AAIA/AACAPwAAgL8AAIA/AACAPwAAgL8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAPwAAgD8AAIC/AACAPwAAgD8AAIA/AACAPwAAgD8AAIA/AACAvwAAgD8AAIA/AACAvwAAgD8AAIA/AACAPwAAgD8AAIA/AACAPwAAgL8AAIA/AACAPwAAgL8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgD8AAIC/AACAPwAAgD8AAIC/AACAPwAAgD8AAIA/AACAPwAAgD8AAIA/AACAvwAAgD8AAIA/AACAvwAAgD8AAIA/AACAPwAAgD8AAIA/AACAPwAAgL8AAIA/AAAAAAAAgL8AAAAAAAAAAAAAAAAAAAAAAACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIA/AACAPwAAgD8AAIC/AACAPwAAgD8AAIC/AACAPwAAgD8AAIA/AACAPwAAgD8AAIA/AACAvwAAgD8AAIA/AACAvwAAgD8AAIA/AACAPwAAgD8AAIA/AACAPwAAgL8AAIA/AAAAAAAAgL8AAAAAAAAAAAAAAAAAAAAAAACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgD8AAIA/AACAPwAAgD8AAIC/AACAPwAAgD8AAIC/AACAPwAAgD8AAIA/AACAPwAAgD8AAIA/AACAvwAAgD8AAIA/AACAvwAAgD8AAIA/AACAPwAAgD8AAIA/AACAPwAAgL8AAAAAAAAAAAAAgL8AAAAAAAAAAAAAgD8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAPwAAgD8AAIA/AACAPwAAgD8AAIC/AACAPwAAgD8AAIC/AACAPwAAgD8AAIA/AACAPwAAgD8AAIA/AACAvwAAgD8AAIA/AACAvwAAgD8AAIA/AACAPwAAgD8AAIA/AACAPwAAgL8AAAAAAACAPwAAgL8AAIA/AACAPwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIA/AACAPwAAgD8AAIA/AACAPwAAgD8AAIC/AACAPwAAgD8AAIC/AACAPwAAgD8AAIA/AACAPwAAgD8AAIA/AACAvwAAgD8AAIA/AACAvwAAgD8AAIA/AACAPwAAgD8AAIA/AACAPwAAgL8AAIA/AACAPwAAgL8AAIA/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIA/AACAPwAAgD8AAIA/AACAPwAAgD8AAIC/AACAPwAAgD8AAIC/AACAPwAAgD8AAIA/AACAPwAAgD8AAIA/AACAvwAAgD8AAIA/AACAvwAAgD8AAIA/AACAPwAAgD8AAIA/AACAPwAAgL8AAIA/AACAPwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAPwAAgL8AAIA/AACAPwAAgD8AAIA/AACAPwAAgD8AAIC/AACAPwAAgD8AAIC/AACAPwAAgD8AAIA/AACAPwAAgD8AAIA/AACAvwAAgD8AAIA/AACAvwAAgD8AAIA/AACAPwAAgD8AAIA/AACAPwAAgL8AAIA/AACAPwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIA/AACAPwAAgL8AAIA/AACAPwAAgD8AAIA/AACAPwAAgD8AAIC/AACAPwAAgD8AAIC/AACAPwAAgD8AAIA/AACAPwAAgD8AAIA/AACAvwAAgD8AAIA/AACAvwAAgD8AAIA/AACAPwAAgD8AAIA/AACAPwAAgL8AAIA/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIA/AACAPwAAgL8AAIA/AACAPwAAgD8AAIA/AACAPwAAgD8AAIC/AACAPwAAgD8AAIC/AACAPwAAgD8AAIA/AACAPwAAgD8AAIA/AACAvwAAgD8AAIA/AACAvwAAgD8AAIA/AACAPwAAgD8AAIA/AACAPwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAPwAAgL8AAIA/AACAPwAAgL8AAIA/AACAPwAAgD8AAIA/AACAPwAAgD8AAIC/AACAPwAAgD8AAIC/AACAPwAAgD8AAIA/AACAPwAAgD8AAIA/AACAvwAAgD8AAIA/AACAvwAAgD8AAIA/AACAPwAAgD8AAIA/AACAPwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIA/AACAPwAAgL8AAIA/AACAPwAAgL8AAIA/AACAPwAAgD8AAIA/AACAPwAAgD8AAIC/AACAPwAAgD8AAIC/AACAPwAAgD8AAIA/AACAPwAAgD8AAIA/AACAvwAAgD8AAIA/AACAvwAAgD8AAIA/AACAPwAAgD8AAIA/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgD8AAIA/AACAPwAAgL8AAIA/AACAPwAAgL8AAIA/AACAPwAAgD8AAIA/AACAPwAAgD8AAIC/AACAPwAAgD8AAIC/AACAPwAAgD8AAIA/AACAPwAAgD8AAIA/AACAvwAAgD8AAIA/AACAvwAAgD8AAIA/AACAPwAAgD8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgD8AAIA/AACAPwAAgL8AAIA/AACAPwAAgL8AAIA/AACAPwAAgD8AAIA/AACAPwAAgD8AAIC/AACAPwAAgD8AAIC/AACAPwAAgD8AAIA/AACAPwAAgD8AAIA/AACAvwAAgD8AAIA/AACAvwAAgD8AAIA/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAPwAAgD8AAIA/AACAPwAAgL8AAIA/AACAPwAAgL8AAIA/AACAPwAAgD8AAIA/AACAPwAAgD8AAIC/AACAPwAAgD8AAIC/AACAPwAAgD8AAIA/AACAPwAAgD8AAIA/AACAvwAAgD8AAIA/AACAvwAAgD8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAPwAAgD8AAIA/AACAPwAAgL8AAIA/AACAPwAAgL8AAIA/AACAPwAAgD8AAIA/AACAPwAAgD8AAIC/AACAPwAAgD8AAIC/AACAPwAAgD8AAIA/AACAPwAAgD8AAIA/AACAvwAAgD8AAIA/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIA/AACAPwAAgD8AAIA/AACAPwAAgL8AAIA/AACAPwAAgL8AAIA/AACAPwAAgD8AAIA/AACAPwAAgD8AAIC/AACAPwAAgD8AAIC/AACAPwAAgD8AAIA/AACAPwAAgD8AAIA/AACAvwAAgD8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIA/AACAPwAAgD8AAIA/AACAPwAAgL8AAIA/AACAPwAAgL8AAIA/AACAPwAAgD8AAIA/AACAPwAAgD8AAIC/AACAPwAAgD8AAIC/AACAPwAAgD8AAIA/AACAPwAAgD8AAIA/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIA/AACAPwAAgD8AAIA/AACAPwAAgL8AAIA/AACAPwAAgL8AAIA/AACAPwAAgD8AAIA/AACAPwAAgD8AAIC/AACAPwAAgD8AAIC/AACAPwAAgD8AAIA/AACAPwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIA/AACAPwAAgD8AAIA/AACAPwAAgL8AAIA/AACAPwAAgL8AAIA/AACAPwAAgD8AAIA/AACAPwAAgD8AAIC/AACAPwAAgD8AAIC/AACAPwAAgD8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIA/AACAPwAAgD8AAIA/AACAPwAAgL8AAIA/AACAPwAAgL8AAIA/AACAPwAAgD8AAIA/AACAPwAAgD8AAIC/AACAPwAAgD8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAPwAAgD8AAIA/AACAPwAAgL8AAIA/AACAPwAAgL8AAIA/AACAPwAAgD8AAIA/AACAPwAAgD8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgD8AAIA/AACAPwAAgL8AAIA/AACAPwAAgL8AAIA/AACAPwAAgD8AAIA/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvyUAACBBLQAAoEIwAQ=="
}
