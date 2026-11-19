import Foundation
import Testing
@testable import KilobatCore

struct HistoryFilterTests {
    @Test func repeatedNamesIncludeEverySavedIdentityExactlyOnce() {
        let sessions = [
            "wifi-a": NetworkSession(name: "Wi-Fi", identified: false),
            "wifi-b": NetworkSession(name: "Wi-Fi", identified: false),
            "hassi-a": NetworkSession(name: "Hassi Appart"),
            "hassi-b": NetworkSession(name: "Hassi Appart"),
            "usb": NetworkSession(name: "iPhone USB")
        ]
        let groups = HistoryNetworkGroup.groups(sessions.mapValues(\.name))
        #expect(groups.count == 3)
        #expect(groups.first { $0.name == "Hassi Appart" }?.keys == ["hassi-a", "hassi-b"])
        #expect(groups.first { $0.name == "Wi-Fi" }?.keys == ["wifi-a", "wifi-b"])
        #expect(groups.flatMap(\.keys).count == sessions.count)
        #expect(Set(groups.flatMap(\.keys)) == Set(sessions.keys))
    }

    @Test func namesRemainExactAndSortForPeople() {
        let groups = HistoryNetworkGroup.groups(["z": "Room 10", "a": "Room 2", "b": "all"])
        #expect(groups.map(\.name) == ["all", "Room 2", "Room 10"])
        #expect(HistoryNetworkGroup.groups([:]).isEmpty)
    }

    @Test func journalOnlyNamesJoinWithoutKeys() {
        let groups = HistoryNetworkGroup.groups(["home": "Home"], extra: ["Café", "Home"])
        #expect(groups.map(\.name) == ["Café", "Home"])
        #expect(groups.first { $0.name == "Café" }?.keys == [])
        #expect(groups.first { $0.name == "Home" }?.keys == ["home"])
    }

    @Test func periodsCoverRollingWindowsAndCalendarMonths() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z"))
        #expect(HistoryPeriod.hour.interval(now: now)?.duration == 3_600)
        #expect(HistoryPeriod.week.interval(now: now)?.end == now)
        #expect(HistoryPeriod.year.interval(now: now)?.start == now.addingTimeInterval(-365 * 86_400))
        let last = try #require(HistoryPeriod.lastMonth.interval(now: now, calendar: utc))
        #expect(last.start == ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        #expect(last.end == ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
        // A cycle needs a budget; custom dates include their last day and refuse to run backwards.
        #expect(HistoryPeriod.cycle.interval(now: now) == nil)
        let custom = try #require(HistoryPeriod.custom.interval(now: now, calendar: utc, from: "2026-10-01", to: "2026-10-31"))
        #expect(custom.end == ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
        #expect(HistoryPeriod.custom.interval(now: now, calendar: utc, from: "2026-10-31", to: "2026-10-01") == nil)
        #expect(HistoryPeriod.custom.interval(now: now, calendar: utc, from: "October", to: "2026-10-01") == nil)
    }
}
