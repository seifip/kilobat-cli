import Foundation
import Testing
@testable import KilobatCore

/// Destination history: off by default, browsers only by name, one row per app, site and day, 30 days, and part of
/// Clear and Forget this site.
struct DestinationHistoryTests {
    var calendar: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!; return calendar }
    func at(_ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }
    let slack = DestinationApp(name: "Slack", browser: false, system: false)
    let chrome = DestinationApp(name: "Google Chrome", browser: true, system: false)
    let daemon = DestinationApp(name: "nsurlsessiond", browser: false, system: true)

    @Test func offByDefaultAndBrowsersOnlyByName() {
        #expect(SavedPreferences().destinationHistory == nil)
        var settings = DestinationHistorySettings()
        #expect(!settings.isOn && !settings.keeps(slack))
        settings.allApps = true
        #expect(settings.keeps(slack) && !settings.keeps(chrome) && !settings.keeps(daemon), "every app but browsers and macOS")
        settings.set("Google Chrome", on: true, browser: true, system: false)
        #expect(settings.keeps(chrome) && settings.apps == ["Google Chrome"])
        settings.set("Slack", on: false, browser: false, system: false)
        #expect(!settings.keeps(slack) && settings.excluded == ["Slack"])
        settings.set("Slack", on: true, browser: false, system: false)
        #expect(settings.keeps(slack) && settings.excluded.isEmpty && settings.apps == ["Google Chrome"], "with all apps on, a regular app needs no entry")
        var chosen = DestinationHistorySettings()
        chosen.set("Slack", on: true, browser: false, system: false)
        #expect(chosen.isOn && chosen.keeps(slack) && !chosen.keeps(DestinationApp(name: "Zoom", browser: false, system: false)))
    }

    @Test func browsersAreKnownByTheirOwnOrTheirOwnersBundleID() {
        #expect(DestinationApp.isBrowser(["com.google.Chrome.helper"]))
        #expect(DestinationApp.isBrowser(["process:Google Chrome Helper", "com.google.Chrome"]))
        #expect(DestinationApp.isBrowser(["com.apple.WebKit.Networking", nil]))
        #expect(DestinationApp.isBrowser(["org.mozilla.firefox"]) && DestinationApp.isBrowser(["company.thebrowser.Browser"]))
        #expect(!DestinationApp.isBrowser(["com.tinyspeck.slackmacgap", nil]))
    }

    @Test func oneRowPerAppSiteAndDay() {
        var records: [DestinationRecord] = [], index: [String: Int] = [:]
        DestinationHistory.add(app: "Slack", host: "slack.com", address: "203.0.113.5", received: 1_000, sent: 100, at: at(9, 10), to: &records, index: &index, calendar: calendar)
        DestinationHistory.add(app: "Slack", host: "slack.com", address: "203.0.113.6", received: 2_000, sent: 200, at: at(9, 11), to: &records, index: &index, calendar: calendar)
        DestinationHistory.add(app: "Slack", host: "slack.com", address: nil, received: 5, sent: 5, at: at(10, 9), to: &records, index: &index, calendar: calendar)
        DestinationHistory.add(app: "Zoom", host: "slack.com", address: nil, received: 0, sent: 0, at: at(10, 9), to: &records, index: &index, calendar: calendar)
        #expect(records.count == 2, "zero bytes add nothing")
        #expect(records[0] == DestinationRecord(day: "2026-11-09", app: "Slack", host: "slack.com", address: "203.0.113.5", received: 3_000, sent: 300, last: at(9, 11)))
        let totals = DestinationHistory.totals(records, app: "Slack", now: at(10), calendar: calendar)
        #expect(totals.count == 1 && totals[0].total == 3_310 && totals[0].days == 2 && totals[0].last == at(10, 9))
        #expect(DestinationHistory.totals(records, app: "Slack", days: 1, now: at(10), calendar: calendar).first?.total == 10)
    }

    @Test func aDayPastItsLimitGoesToOtherSites() {
        var records: [DestinationRecord] = [], index: [String: Int] = [:]
        for host in 0..<(DestinationHistory.maxHostsPerDay + 5) {
            DestinationHistory.add(app: "scanner", host: "198.51.100.\(host % 250).\(host)", address: nil, received: 1, sent: 1, at: at(9), to: &records, index: &index, calendar: calendar)
        }
        #expect(records.count == DestinationHistory.maxHostsPerDay + 1)
        #expect(records.last?.host == "" && records.last?.total == 10)
    }

    @Test func keepsThirtyDays() {
        var records = [DestinationRecord(day: "2026-10-11", app: "Slack", host: "old.example", received: 1, sent: 1, last: at(1)),
                       DestinationRecord(day: "2026-10-12", app: "Slack", host: "kept.example", received: 1, sent: 1, last: at(1)),
                       DestinationRecord(day: "2026-11-10", app: "Slack", host: "today.example", received: 1, sent: 1, last: at(10))]
        #expect(DestinationHistory.prune(&records, now: at(10), calendar: calendar))
        #expect(records.map(\.host) == ["kept.example", "today.example"])
        #expect(!DestinationHistory.prune(&records, now: at(10), calendar: calendar))
    }

    @Test func clearAndForgetThisSite() throws {
        let now = at(10, 12)
        let base = [DestinationRecord(day: "2026-11-10", app: "Slack", host: "slack.com", address: "203.0.113.5", received: 1, sent: 1, last: now - 600),
                    DestinationRecord(day: "2026-11-10", app: "Zoom", host: "203.0.113.9", received: 1, sent: 1, last: now - 7_200),
                    DestinationRecord(day: "2026-11-09", app: "Slack", host: "files.slack.com", received: 1, sent: 1, last: now - 86_400),
                    DestinationRecord(day: "2026-11-09", app: "Slack", host: "", received: 1, sent: 1, last: now - 86_400)]
        var records = base
        #expect(HistoryEraser.apply(.clear(.hour), to: &records, now: now, calendar: calendar) == 1)
        #expect(records.map(\.host) == ["203.0.113.9", "files.slack.com", ""])
        records = base
        #expect(HistoryEraser.apply(.clear(.today), to: &records, now: now, calendar: calendar) == 2)
        records = base
        #expect(HistoryEraser.apply(.clear(.all), to: &records, now: now, calendar: calendar) == 4 && records.isEmpty)
        records = base
        #expect(HistoryEraser.apply(.forget(try #require(HostMatch("slack.com", subdomains: true))), to: &records, now: now) == 2)
        #expect(records.map(\.host) == ["203.0.113.9", ""])
        records = base
        #expect(HistoryEraser.apply(.forget(try #require(HostMatch("203.0.113.5"))), to: &records, now: now) == 1, "a named row is forgotten by its address too")
        records = base
        #expect(HistoryEraser.apply(.forget(try #require(HostMatch("203.0.113.9"))), to: &records, now: now) == 1)
    }

    @MainActor @Test func theFilesAreClearedWhileTheAppIsClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-destinations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = DestinationHistoryFile(records: [DestinationRecord(day: "2026-11-10", app: "Slack", host: "slack.com", received: 1, sent: 1, last: Date()),
                                                    DestinationRecord(day: "2026-11-10", app: "Slack", host: "example.org", received: 1, sent: 1, last: Date())])
        try file.data().write(to: directory.appendingPathComponent(DestinationHistory.fileName))
        let change = try HostHistoryFiles.erase(.forget(try #require(HostMatch("slack.com"))), kinds: [.destinations], directory: directory, appDefaults: nil)
        #expect(change.destinations == 1 && change.total == 1)
        #expect(DestinationHistoryFile.load(directory.appendingPathComponent(DestinationHistory.fileName))?.records.map(\.host) == ["example.org"])
        #expect(HostHistoryKind.allCases.contains(.destinations), "Clear site history covers it")
    }

    @Test func olderRepliesWithoutTheCountStillDecode() throws {
        let change = try JSONDecoder().decode(HistoryChange.self, from: Data(#"{"blockedAttempts":2,"agentLogHosts":1,"sessionDestinations":0,"notices":0}"#.utf8))
        #expect(change.total == 3 && change.destinations == 0)
    }
}

@MainActor struct DestinationHistoryStoreTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func connection(_ address: String, received: UInt64, sent: UInt64, route: TrafficRoute = .internet) -> ConnectionTraffic {
        ConnectionTraffic(id: "tcp4 192.168.1.20:50000<->\(address):443", route: route, interface: "en0", received: received, sent: sent)
    }
    func sample(_ at: TimeInterval, _ connections: [ConnectionTraffic], pid: Int32 = 501) -> TrafficSnapshot {
        TrafficSnapshot(timestamp: t0 + at, processes: [ProcessTraffic(pid: pid, process: "Slack", received: 0, sent: 0, connections: connections)])
    }
    func store(settings: DestinationHistorySettings?, allowed: Bool = true, app: DestinationApp = DestinationApp(name: "Slack", browser: false, system: false)) -> DestinationHistoryStore {
        let store = DestinationHistoryStore(now: t0)
        store.allowed = { allowed }
        store.settings = { settings }
        store.resolve = { _ in app }
        store.names = { ["203.0.113.5": "edge.slack.com"] }
        return store
    }

    @Test func recordsOnlyNewBytesAfterABaseline() {
        let store = store(settings: DestinationHistorySettings(allApps: true))
        store.consume(sample(0, [connection("203.0.113.5", received: 50_000, sent: 1_000)]))
        #expect(store.records.isEmpty, "the first sight of a process is only its baseline")
        store.consume(sample(1, [connection("203.0.113.5", received: 80_000, sent: 1_500), connection("198.51.100.7", received: 400, sent: 40),
                                 connection("192.168.1.1", received: 9_999, sent: 9_999, route: .local)]))
        let totals = store.totals(app: "Slack", now: t0 + 2)
        #expect(totals.map(\.host) == ["edge.slack.com", "198.51.100.7"], "named by the filter where it saw the name; the local network is left out")
        #expect(totals.first?.received == 30_000 && totals.first?.sent == 500)
        #expect(totals.last?.total == 440, "a connection opened since the last sample counts in full")
    }

    @Test func nothingIsKeptWhenOffWithoutProOrForABrowser() {
        for store in [store(settings: nil), store(settings: DestinationHistorySettings(allApps: true), allowed: false),
                      store(settings: DestinationHistorySettings(allApps: true), app: DestinationApp(name: "Safari", browser: true, system: false))] {
            store.consume(sample(0, [connection("203.0.113.5", received: 1, sent: 1)]))
            store.consume(sample(1, [connection("203.0.113.5", received: 5_000, sent: 5_000)]))
            #expect(store.records.isEmpty)
        }
        let named = store(settings: DestinationHistorySettings(apps: ["Safari"]), app: DestinationApp(name: "Safari", browser: true, system: false))
        named.consume(sample(0, [connection("203.0.113.5", received: 1, sent: 1)]))
        named.consume(sample(1, [connection("203.0.113.5", received: 5_000, sent: 5_000)]))
        #expect(named.records.count == 1, "a browser the person added by name")
    }

    @Test func eraseAndForgetAnApp() throws {
        let store = store(settings: DestinationHistorySettings(allApps: true))
        store.consume(sample(0, [connection("203.0.113.5", received: 1, sent: 1)]))
        store.consume(sample(1, [connection("203.0.113.5", received: 9, sent: 9), connection("198.51.100.7", received: 9, sent: 9)]))
        #expect(try store.erase(.forget(try #require(HostMatch("slack.com", subdomains: true))), now: t0 + 2) == 1)
        #expect(store.records.map(\.host) == ["198.51.100.7"])
        #expect(try store.forget(app: "Slack") == 1 && store.records.isEmpty)
    }
}
