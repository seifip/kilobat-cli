import Foundation
import Testing
@testable import KilobatCore

struct UsageComparisonTests {
    static let utc: Calendar = { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!; return calendar }()
    static func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    static let now = at("2026-10-29T12:00:00Z")
    static func entry(_ time: String, _ network: String?, received: UInt64, sent: UInt64 = 0, local: UInt64? = nil, unattributed: UInt64? = nil, apps: [String: UInt64] = [:], appsSent: [String: UInt64]? = nil) -> UsageEntry {
        UsageEntry(date: at(time), received: received, sent: sent, apps: apps, networkKey: network, appsSent: appsSent, localBytes: local, unattributed: unattributed)
    }
    /// Home in hours 0, 1 and 4, a café in hour 3, nothing in hours 2 and 5.
    static var history: [UsageEntry] { [entry("2026-10-20T09:00:00Z", "home", received: 1)] + ["00", "01", "04"].map {
        entry("2026-10-28T\($0):00:00Z", "home", received: 5_000_000_000, sent: 1_000_000_000, local: 200_000_000, unattributed: 300_000_000,
              apps: ["Safari": 4_000_000_000], appsSent: ["Safari": 500_000_000])
    } + [entry("2026-10-28T03:00:00Z", "cafe", received: 2_000_000_000)] }
    static let morning = DateInterval(start: at("2026-10-28T00:00:00Z"), end: at("2026-10-28T06:00:00Z"))
    static let names = ["home": "Home", "cafe": "Café"]

    func compare(_ total: Double, _ unit: UsageComparison.Unit, _ direction: UsageComparison.Direction = .both, scope: Set<String>? = ["home"],
                 usage: [UsageEntry] = history, period: DateInterval = morning, sleeps: [DateInterval] = [], calendar: Calendar = utc) -> UsageComparison {
        UsageComparison.make(usage, period: period, scope: scope, names: Self.names, total: total, unit: unit, direction: direction, sleeps: sleeps, now: Self.now, calendar: calendar)
    }

    @Test func testKilobatLowerShowsTotalsCoverageAndGaps() throws {
        let result = compare(40, .gb)
        #expect(result.externalBytes == 40_000_000_000 && result.alternateUnit == .gib && result.alternateBytes == 42_949_672_960)
        #expect(result.kilobatBytes == 18_000_000_000 && result.downloadBytes == 15_000_000_000 && result.uploadBytes == 3_000_000_000)
        #expect(result.kilobatAmount == 18 && result.differenceBytes == 22_000_000_000 && abs((result.differencePercent ?? 0) - 55) < 1e-9)
        #expect(result.localBytes == 600_000_000 && result.unattributedBytes == 900_000_000 && result.otherNetworkBytes == 2_000_000_000)
        #expect(result.periodHours == 6 && result.recordedHours == 3 && result.coverage == 0.5)
        #expect(result.gaps.map(\.reason) == [.notRecorded, .otherNetwork, .notRecorded])
        #expect(result.gaps.map(\.hours) == [1, 1, 1] && result.gaps[0].start == Self.at("2026-10-28T02:00:00Z"))
        #expect(result.gaps[1].detail.contains("Café"))
        #expect(result.networks.map(\.name) == ["Home", "Café"] && result.networks.map(\.counted) == [true, false])
        #expect(result.topApps == [UsageComparison.App(name: "Safari", bytes: 12_000_000_000)])
        let ids = result.reasons.map(\.id)
        #expect(ids.first == "coverage")
        #expect(["otherDevices", "otherNetworks", "units", "local", "overhead", "timing"].allSatisfy(ids.contains))
        // Counting one way only would lower the figure further, so direction isn't offered as a reason.
        #expect(!ids.contains("direction") && !ids.contains("planRules"))
        #expect(result.summary.contains("18 GB") && result.summary.contains("22 GB less") && result.summary.contains("40 GB"))
        // It explains; it never blames the provider.
        let text = (result.reasons.map(\.text) + [result.summary]).joined(separator: " ").lowercased()
        for word in ["wrong", "error", "overcharg", "incorrect", "mistake", "fraud", "bug"] { #expect(!text.contains(word), "\(word)") }
    }

    @Test func testSleepNamesTheHoursItCovers() {
        // Asleep for most of hour 2 and ten minutes of hour 5: hour 2 is asleep, hour 5 still nothing recorded.
        let sleeps = [DateInterval(start: Self.at("2026-10-28T01:50:00Z"), end: Self.at("2026-10-28T02:50:00Z")),
                      DateInterval(start: Self.at("2026-10-28T05:00:00Z"), end: Self.at("2026-10-28T05:10:00Z"))]
        let result = compare(40, .gb, sleeps: sleeps)
        #expect(result.gaps.map(\.reason) == [.asleep, .otherNetwork, .notRecorded])
        #expect(result.gaps[0].detail == "The Mac was asleep" && result.gaps[2].detail.hasPrefix("Nothing recorded and not asleep"))
        let coverage = result.reasons.first { $0.id == "coverage" }?.text ?? ""
        #expect(coverage.contains("1 hour asleep") && coverage.contains("(off, offline or Kilobat not running)"))
        // Without recorded sleep, an empty hour still lists sleep among its causes.
        #expect(compare(40, .gb).gaps[0].detail.contains("asleep, off or offline"))
    }

    @MainActor @Test func testTrafficStoreKeepsSleepsAcrossLaunches() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = TrafficStore(directory: folder, startMonitoring: false)
        store.woke(at: Self.now)
        #expect(store.sleeps.isEmpty)
        // A sleep older than the history window is dropped on a later wake.
        store.slept(at: Self.at("2024-01-01T00:00:00Z")); store.woke(at: Self.at("2024-01-01T01:00:00Z"))
        store.slept(at: Self.at("2026-10-29T01:00:00Z")); store.woke(at: Self.at("2026-10-29T07:00:00Z"))
        #expect(TrafficStore(directory: folder, startMonitoring: false).sleeps == [DateInterval(start: Self.at("2026-10-29T01:00:00Z"), end: Self.at("2026-10-29T07:00:00Z"))])
    }

    @Test func testDirectionCountsOneWay() {
        let download = compare(15, .gb, .download)
        #expect(download.kilobatBytes == 15_000_000_000 && download.agrees && download.reasons.first?.id == "close")
        #expect(download.topApps.first?.bytes == 10_500_000_000)
        #expect(compare(3, .gb, .upload).kilobatBytes == 3_000_000_000)
        #expect(compare(20, .gb, .download).reasons.contains { $0.id == "direction" && $0.text.contains("18 GB") })
        #expect(compare(10, .gb).reasons.contains { $0.id == "direction" && $0.text.contains("15 GB") })
    }

    @Test func testBinaryUnitThatExplainsAHigherKilobatTotalComesFirst() {
        let usage = [Self.entry("2026-10-28T01:00:00Z", "home", received: 16_100_000_000)]
        let result = compare(15, .gb, .download, usage: usage)
        #expect(result.differenceBytes < 0 && result.summary.contains("more than"))
        #expect(result.reasons.first?.id == "units" && result.reasons.first?.text.contains("15 GiB") == true)
        #expect(result.reasons.contains { $0.id == "planRules" } && !result.reasons.contains { $0.id == "otherDevices" })
        let gib = compare(15, .gib, .download, usage: usage)
        #expect(gib.externalBytes == 16_106_127_360 && gib.kilobatAmount < 15 && gib.agrees)
    }

    @Test func testAllNetworksAndNetworksWithTheSameName() {
        let all = compare(40, .gb, scope: nil)
        #expect(all.allNetworks && all.kilobatBytes == 20_000_000_000 && all.otherNetworkBytes == 0 && all.networks.allSatisfy(\.counted))
        #expect(all.reasons.contains { $0.id == "allNetworks" } && !all.gaps.contains { $0.reason == .otherNetwork })
        let twins = UsageComparison.make(Self.history, period: Self.morning, scope: ["home"], names: ["home": "Home", "cafe": "Home"],
                                         total: 40, unit: .gb, direction: .both, now: Self.now, calendar: Self.utc)
        #expect(twins.reasons.contains { $0.id == "sameName" && $0.text.contains("2 recorded networks are named Home") })
    }

    @Test func testHistoryStartAndAPeriodNotOverYet() {
        let usage = [Self.entry("2026-10-29T11:10:00Z", "home", received: 1_000)]
        let result = compare(1, .mb, usage: usage, period: DateInterval(start: Self.at("2026-10-29T10:00:00Z"), end: Self.at("2026-10-29T14:00:00Z")))
        #expect(result.periodHours == 2 && result.recordedHours == 1)
        #expect(result.gaps.map(\.reason) == [.beforeHistory, .notYet] && result.gaps[1].start == Self.now && result.gaps[1].hours == 2)
        #expect(result.reasons.contains { $0.id == "notYet" })
    }

    @Test func testDailyHistoryCoversItsDayAndPartialHoursClip() {
        let usage = [Self.entry("2026-09-01T00:00:00Z", "home", received: 5_000)]
        let day = compare(1, .kb, usage: usage, period: DateInterval(start: Self.at("2026-09-01T00:00:00Z"), end: Self.at("2026-09-02T00:00:00Z")))
        #expect(day.recordedHours == 24 && day.gaps.isEmpty && day.kilobatBytes == 5_000)
        let half = compare(1, .gb, period: DateInterval(start: Self.at("2026-10-28T00:30:00Z"), end: Self.at("2026-10-28T02:00:00Z")))
        #expect(half.periodHours == 1.5 && half.recordedHours == 1.5 && half.reasons.contains { $0.id == "boundary" })
    }

    @Test func testClockChangeIsNamed() {
        var berlin = Calendar(identifier: .gregorian); berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let start = UsageComparison.date("2026-10-24", calendar: berlin)!, end = UsageComparison.date("2026-10-25", end: true, calendar: berlin)!
        let result = compare(1, .gb, usage: [], period: DateInterval(start: start, end: end), calendar: berlin)
        #expect(result.periodHours == 49 && result.timeZone == "Europe/Berlin")
        #expect(result.reasons.contains { $0.id == "clockChange" && $0.text.contains("49 hours") })
        #expect(result.gaps.count == 1 && result.gaps[0].reason == .beforeHistory)
    }

    @Test func testParsesTotalsDatesAndPresets() {
        #expect(UsageComparison.total("40GB").map { $0.amount == 40 && $0.unit == .gb } == true)
        #expect(UsageComparison.total(" 40 gib ").map { $0.amount == 40 && $0.unit == .gib } == true)
        #expect(UsageComparison.total("1,5 TB").map { $0.amount == 1.5 && $0.unit == .tb } == true)
        #expect(UsageComparison.total("1,234.5 MB").map { $0.amount == 1_234.5 && $0.unit == .mb } == true)
        #expect(UsageComparison.total("12").map { $0.amount == 12 && $0.unit == nil } == true)
        #expect(UsageComparison.total("abc") == nil && UsageComparison.total("40 GX") == nil && UsageComparison.total("-4 GB") == nil)
        #expect(UsageComparison.date("2026-10-31", calendar: Self.utc) == Self.at("2026-10-31T00:00:00Z"))
        #expect(UsageComparison.date("2026-10-31", end: true, calendar: Self.utc) == Self.at("2026-11-01T00:00:00Z"))
        #expect(UsageComparison.date("2026-10-01 18:30", calendar: Self.utc) == Self.at("2026-10-01T18:30:00Z"))
        #expect(UsageComparison.date("2026-10-01T18:30:00+02:00", calendar: Self.utc) == Self.at("2026-10-01T16:30:00Z"))
        #expect(UsageComparison.date("2026-13-01", calendar: Self.utc) == nil && UsageComparison.date("yesterday", calendar: Self.utc) == nil)
        #expect(UsageComparison.Preset.lastMonth.interval(now: Self.now, calendar: Self.utc) == DateInterval(start: Self.at("2026-09-01T00:00:00Z"), end: Self.at("2026-10-01T00:00:00Z")))
        #expect(UsageComparison.Preset.last7Days.interval(now: Self.now, calendar: Self.utc).start == Self.at("2026-10-23T00:00:00Z"))
    }

    @Test func testExportsCarryScopeAndGaps() throws {
        let result = compare(40, .gb)
        let csv = result.csv()
        #expect(csv.hasPrefix("kind,name,value,unit,start,end,hours,detail\n"))
        #expect(csv.contains("period,comparison,,,2026-10-28T00:00:00Z,2026-10-28T06:00:00Z,6,\(Self.utc.timeZone.identifier)"))
        #expect(csv.contains("scope,networks,Home,,,,,both") && csv.contains("network,Café,2000000000,B,,,,not counted · cafe"))
        #expect(csv.contains("gap,otherNetwork,,,2026-10-28T03:00:00Z,2026-10-28T04:00:00Z,1,On another network: Café"))
        #expect(csv.contains("coverage,recorded,3,hours,,,6,50% of the period so far") && csv.contains("external,total,40,GB"))
        let json = try #require(try JSONSerialization.jsonObject(with: result.json()) as? [String: Any])
        #expect(json["coverage"] as? Double == 0.5 && json["timeZone"] as? String == Self.utc.timeZone.identifier && json["start"] as? String == "2026-10-28T00:00:00Z")
        #expect((json["gaps"] as? [[String: Any]])?.count == 3 && (json["reasons"] as? [[String: Any]])?.isEmpty == false)
        #expect(try JSONDecoder().decode(UsageComparison.self, from: JSONEncoder().encode(result)) == result)
    }
}
