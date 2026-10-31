import Foundation
import Testing
@testable import KilobatCore

struct YearInReviewTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    private func usage(_ date: Date, _ bytes: UInt64, apps: [String: UInt64] = [:], network: String? = "home") -> UsageEntry {
        UsageEntry(date: date, received: bytes * 3 / 4, sent: bytes - bytes * 3 / 4, apps: apps, networkKey: network)
    }
    private func test(_ date: Date, network: String, down: Double, up: Double = 20, changed: Bool = false) -> SavedSpeedTest {
        let ping = PingResult(host: "sample", samples: [20, 22], lossPercent: 0)
        let result = SpeedTestResult(date: date, downloadMbps: down, uploadMbps: up, baseline: ping, downloadLoaded: ping, uploadLoaded: ping,
                                     downloadSeconds: 8, uploadSeconds: 8, transferredBytes: 1)
        // The SSID is in the saved test; the card must never use it.
        return SavedSpeedTest(networkKey: network, networkName: "SSID-\(network)", networkChanged: changed, result: result)
    }
    private func call(_ start: Date, clean: Bool, network: String? = "home") -> CallReport {
        let freeze = CallReport.Freeze(at: 30, seconds: 3, peak: nil, cause: .init(kind: .wifi))
        return CallReport(app: "Zoom", browser: false, start: start, end: start.addingTimeInterval(1800), networkKey: network, networkName: nil,
                          median: 30, jitter: 2, lossPercent: 0, freezes: clean ? [] : [freeze], strain: [], line: [])
    }

    @Test func countsTheLongestRunOfCleanCallsInOrder() {
        let start = day(2026, 3, 1)
        let pattern = [true, true, false, true, true, true, false, true]
        // Shuffled on purpose: the streak follows when the calls happened, not the order they were saved in.
        let calls = pattern.enumerated().map { call(start.addingTimeInterval(Double($0.offset) * 86_400), clean: $0.element) }.reversed()
        #expect(YearInReview.longestCleanRun(Array(calls)) == 3)
        #expect(YearInReview.longestCleanRun([]) == 0)
        #expect(YearInReview.longestCleanRun([call(start, clean: false)]) == 0)
        let overloaded = CallReport(app: "Zoom", browser: false, start: start, end: start, networkKey: nil, networkName: nil, median: 30, jitter: 2,
                                    lossPercent: 0, freezes: [], strain: [.init(kind: .cpu, seconds: 120)], line: [])
        #expect(YearInReview.longestCleanRun([call(start, clean: true), overloaded, call(start.addingTimeInterval(60), clean: true)]) == 1)
    }

    @Test func picksTheFastestPlaceTheUserNamedNeverTheNetworkName() {
        let now = day(2026, 12, 3)
        let tests = [test(day(2026, 5, 1), network: "home", down: 900),
                     test(day(2026, 6, 1), network: "cafe", down: 140),
                     test(day(2026, 7, 1), network: "cowork", down: 310),
                     // The network changed during this one, so its number doesn't belong to the place.
                     test(day(2026, 7, 2), network: "library", down: 600, changed: true),
                     // Last year's best doesn't count.
                     test(day(2025, 7, 2), network: "cafe", down: 700)]
        let review = YearInReview(usage: [usage(day(2026, 1, 2), 1_000)], speedTests: tests,
                                  places: ["cafe": "Blue Bottle", "cowork": "  Hub Lisbon ", "library": "City Library", "home": "   "],
                                  calls: [], now: now, calendar: calendar)
        #expect(review.place == .init(name: "Hub Lisbon", downloadMbps: 310, uploadMbps: 20))

        let unnamed = YearInReview(usage: [usage(day(2026, 1, 2), 1_000)], speedTests: tests, places: [:], calls: [], now: now, calendar: calendar)
        #expect(unnamed.place?.name == nil)
        #expect(unnamed.place?.downloadMbps == 900)
        #expect(YearInReview(usage: [], speedTests: [], places: [:], calls: [], now: now, calendar: calendar).place == nil)
    }

    @Test func saysSinceWhenHistoryStartsAfterTheFirstWeek() {
        let now = day(2026, 12, 3)
        let partial = YearInReview(usage: [usage(day(2026, 8, 14), 5_000), usage(day(2026, 9, 2), 1_000)], speedTests: [], places: [:], calls: [], now: now, calendar: calendar)
        #expect(!partial.wholeYear)
        #expect(partial.since == day(2026, 8, 14, hour: 0))
        #expect(partial.year == 2026)

        let whole = YearInReview(usage: [usage(day(2026, 1, 5), 5_000)], speedTests: [], places: [:], calls: [], now: now, calendar: calendar)
        #expect(whole.wholeYear)

        // An older test reaches back further than usage history, so the card says since then.
        let earlierTest = YearInReview(usage: [usage(day(2026, 8, 14), 5_000)], speedTests: [test(day(2026, 3, 9), network: "home", down: 50)],
                                       places: [:], calls: [], now: now, calendar: calendar)
        #expect(earlierTest.since == day(2026, 3, 9, hour: 0))

        let empty = YearInReview(usage: [], speedTests: [], places: [:], calls: [], now: now, calendar: calendar)
        #expect(empty.isEmpty)
        #expect(!empty.wholeYear)
        #expect(empty.since == nil)
    }

    @Test func januaryLooksBackAtTheYearThatEnded() {
        let review = YearInReview(usage: [usage(day(2026, 6, 1), 9_000), usage(day(2027, 1, 4), 1_000)], speedTests: [], places: [:], calls: [],
                                  now: day(2027, 1, 6), calendar: calendar)
        #expect(review.year == 2026)
        #expect(review.total == 9_000)
        #expect(YearInReview.year(at: day(2026, 12, 31), calendar: calendar) == 2026)
        #expect(YearInReview.season(day(2026, 12, 1), calendar: calendar))
        #expect(!YearInReview.season(day(2026, 11, 30), calendar: calendar))
    }

    @Test func addsUpDataAppsNetworksAndTheBusiestMonth() {
        let usage = [usage(day(2026, 2, 3), 4_000, apps: ["com.apple.Safari": 3_000, "process:node": 500]),
                     usage(day(2026, 3, 1), 10_000, apps: ["com.apple.Safari": 1_000, "us.zoom.xos": 6_000], network: "cafe"),
                     usage(day(2026, 3, 20), 2_000, apps: ["us.zoom.xos": 1_500], network: nil),
                     usage(day(2025, 12, 30), 99_000, apps: ["old.app": 99_000], network: "old")]
        let review = YearInReview(usage: usage, speedTests: [test(day(2026, 4, 1), network: "hotel", down: 80), test(day(2026, 4, 2), network: "unknown", down: 10)],
                                  places: [:], calls: [call(day(2026, 5, 1), clean: true, network: "airport")], now: day(2026, 12, 10), calendar: calendar)
        #expect(review.total == 16_000)
        #expect(review.hungriest?.id == "us.zoom.xos")
        #expect(review.hungriest?.bytes == 7_500)
        #expect(review.hungriest?.share == 7_500.0 / 16_000.0)
        // home, cafe, hotel and airport; "unknown" and entries without a network don't count.
        #expect(review.networks == 4)
        #expect(review.busiest == .init(start: day(2026, 3, 1, hour: 0), bytes: 12_000, month: true))
        #expect(review.months == [0, 4_000, 12_000, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(review.cleanStreak == 1)
        #expect(review.calls == 1)

        let oneMonth = YearInReview(usage: [self.usage(day(2026, 11, 2), 300), self.usage(day(2026, 11, 9), 900), self.usage(day(2026, 11, 9, hour: 18), 50)],
                                    speedTests: [], places: [:], calls: [], now: day(2026, 12, 1), calendar: calendar)
        #expect(oneMonth.busiest == .init(start: day(2026, 11, 9, hour: 0), bytes: 950, month: false))
    }
}
