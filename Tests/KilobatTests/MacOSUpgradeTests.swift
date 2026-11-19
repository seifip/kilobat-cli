import Foundation
import Testing
@testable import KilobatCore

struct MacOSUpgradeTests {
    /// The shape of /Library/Receipts/InstallHistory.plist: macOS updates among app and data installs, betas repeating
    /// their release's version.
    static let installHistory = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><array>
    <dict><key>date</key><date>2026-05-23T18:31:03Z</date><key>displayName</key><string>macOS 26.5</string><key>displayVersion</key><string>26.5</string><key>processName</key><string>softwareupdated</string></dict>
    <dict><key>date</key><date>2026-05-30T09:00:00Z</date><key>displayName</key><string>XProtectPlistConfigData</string><key>displayVersion</key><string>5328</string><key>processName</key><string>softwareupdated</string></dict>
    <dict><key>date</key><date>2026-06-05T20:27:03Z</date><key>displayName</key><string>macOS 26.5.1</string><key>displayVersion</key><string>26.5.1</string><key>processName</key><string>softwareupdated</string></dict>
    <dict><key>date</key><date>2026-06-18T19:59:16Z</date><key>displayName</key><string>macOS 27.0</string><key>displayVersion</key><string>27.0</string><key>processName</key><string>softwareupdated</string></dict>
    <dict><key>date</key><date>2026-06-23T12:13:14Z</date><key>displayName</key><string>macOS 27.0</string><key>displayVersion</key><string>27.0</string><key>processName</key><string>softwareupdated</string></dict>
    <dict><key>date</key><date>2026-07-02T10:00:00Z</date><key>displayName</key><string>Xcode</string><key>displayVersion</key><string>27.0</string><key>processName</key><string>appstoreagent</string></dict>
    <dict><key>date</key><date>2026-09-22T13:07:26Z</date><key>displayName</key><string>macOS 27.2</string><key>processName</key><string>softwareupdated</string></dict>
    </array></plist>
    """

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    @Test func readsTheInstallersLogOnePerVersion() {
        let releases = MacOSVersion.installHistory(Data(Self.installHistory.utf8))
        #expect(releases.map(\.version) == ["26.5", "26.5.1", "27.0", "27.2"])
        // The first 27.0 beta is when the Mac moved to it; later betas don't move the date.
        #expect(releases[2].date == date("2026-06-18T19:59:16Z"))
        // No displayVersion: the version comes from the name.
        #expect(releases[3].version == "27.2")
        #expect(MacOSVersion.installHistory(Data("not a plist".utf8)).isEmpty)
    }

    @Test func versionsCompareNumerically() {
        #expect(MacOSVersion.isNewer("27.10", than: "27.9"))
        #expect(MacOSVersion.isNewer("27.0.1", than: "27.0"))
        #expect(!MacOSVersion.isNewer("26.7", than: "27.0"))
    }

    @Test func kilobatsSightingsFillGapsInTheLog() {
        let installed = [MacOSRelease(version: "27.0", date: date("2026-06-18T00:00:00Z"))]
        let seen = [MacOSRelease(version: "27.0", date: date("2026-08-01T00:00:00Z")), MacOSRelease(version: "27.2", date: date("2026-09-22T14:00:00Z"))]
        let timeline = MacOSVersion.timeline(installed: installed, seen: seen)
        #expect(timeline.map(\.version) == ["27.0", "27.2"])
        #expect(timeline[0].date == date("2026-06-18T00:00:00Z"))
        #expect(MacOSVersion.version(at: date("2026-09-01T00:00:00Z"), in: timeline) == "27.0")
        #expect(MacOSVersion.version(at: date("2026-10-01T00:00:00Z"), in: timeline) == "27.2")
        #expect(MacOSVersion.version(at: date("2026-01-01T00:00:00Z"), in: timeline) == nil)
    }

    private func snapshot(_ at: Date, internet: Double, dns: Double, network: String = "Home", gateway: String = "192.168.1.1") -> DiagnosticSnapshot {
        let json = #"{"date":\#(at.timeIntervalSinceReferenceDate),"radio":{"ssid":"\#(network)","interface":"en0","rssi":-55,"noise":-92,"transmitMbps":720,"channel":149,"band":"5 GHz","bssid":"aa:bb"},"gateway":"\#(gateway)","router":{"host":"router","samples":[3,4],"lossPercent":0},"internet":{"host":"1.1.1.1","samples":[\#(internet),\#(internet)],"lossPercent":0},"dnsMilliseconds":\#(dns),"dnsServers":[],"captivePortal":false,"networkService":"Wi-Fi"}"#
        return try! JSONDecoder().decode(DiagnosticSnapshot.self, from: Data(json.utf8))
    }

    @Test func summarizesEachHourPerNetworkWithMedians() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let hour = date("2026-11-03T10:00:00Z")
        let samples = [snapshot(hour.addingTimeInterval(60), internet: 20, dns: 15), snapshot(hour.addingTimeInterval(120), internet: 22, dns: 18),
                       snapshot(hour.addingTimeInterval(180), internet: 400, dns: 16),
                       snapshot(hour.addingTimeInterval(240), internet: 50, dns: 30, network: "Café", gateway: "10.0.0.1"),
                       snapshot(hour.addingTimeInterval(3_700), internet: 25, dns: 14)]
        let hours = HourlyCheck.summarize(samples, macOS: { $0 < hour.addingTimeInterval(3_600) ? "27.0" : "27.2" }, calendar: calendar)
        #expect(hours.count == 3)
        let home = try #require(hours.first { $0.hour == hour && $0.networkName == "Home" })
        #expect(home.checks == 3)
        // One slow check can't move the hour.
        #expect(home.internetMs == 22)
        #expect(home.dnsMs == 16)
        #expect(home.macOS == "27.0")
        #expect(hours.last?.macOS == "27.2")
    }

    // MARK: Comparison

    private let now = ISO8601DateFormatter().date(from: "2026-11-10T12:00:00Z")!
    private var upgraded: Date { now.addingTimeInterval(-4 * 86_400) }
    private var timeline: [MacOSRelease] { [MacOSRelease(version: "27.0", date: now.addingTimeInterval(-90 * 86_400)), MacOSRelease(version: "27.2", date: upgraded)] }

    private func hours(_ key: String = "home", from: Double, to: Double, internet: Double, dns: Double, loss: Double = 0, macOS: String? = nil) -> [HourlyCheck] {
        stride(from: from, to: to, by: 1).map { hoursAgo in
            HourlyCheck(hour: now.addingTimeInterval(-hoursAgo * 3_600), networkKey: key, networkName: key == "home" ? "Home" : "Office", checks: 60,
                        internetMs: internet, routerMs: 3, dnsMs: dns, lossPercent: loss, macOS: macOS)
        }
    }
    private func test(_ daysAgo: Double, down: Double, up: Double = 40, key: String = "home", kind: String? = "Wi-Fi", macOS: String? = nil) -> SavedSpeedTest {
        let ping = #"{"host":"x","samples":[14],"lossPercent":0}"#
        let context = kind.map { #","context":{"kind":"\#($0)"}"# } ?? ""
        let json = #"{"id":"\#(UUID().uuidString)","networkKey":"\#(key)","networkName":"Home","result":{"date":\#(now.addingTimeInterval(-daysAgo * 86_400).timeIntervalSinceReferenceDate),"downloadMbps":\#(down),"uploadMbps":\#(up),"baseline":\#(ping),"downloadLoaded":\#(ping),"uploadLoaded":\#(ping),"downloadSeconds":8,"uploadSeconds":8,"transferredBytes":1\#(context)}}"#
        var saved = try! JSONDecoder().decode(SavedSpeedTest.self, from: Data(json.utf8))
        saved.macOS = macOS
        return saved
    }
    private func drop(_ daysAgo: Double, key: String = "home") -> NetworkEvent {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        return NetworkEvent(start: start, end: start.addingTimeInterval(120), network: "Home", kind: "Unreachable", detail: "", routerChecks: 2, routerAnswered: 2, networkKey: key)
    }

    @Test func namesWhatGotWorseSinceTheUpgrade() throws {
        // Before: hours 96…168 ago (days 4–7); after: the last 96 hours.
        let hourly = hours(from: 97, to: 168, internet: 22, dns: 18) + hours(from: 1, to: 96, internet: 24, dns: 95, loss: 0.4)
        let tests = [test(6, down: 480), test(5, down: 470), test(2, down: 120), test(1, down: 135)]
        let comparison = try #require(MacOSUpgradeComparison.make(timeline: timeline, hourly: hourly, events: [drop(6), drop(3), drop(2.5), drop(2), drop(1)], speedTests: tests, network: "home", now: now))
        #expect(comparison.from == "27.0")
        #expect(comparison.to == "27.2")
        #expect(comparison.networkName == "Home")
        #expect(comparison.before.speedTests == 2)
        #expect(comparison.after.drops == 4)
        let worse = Set(comparison.worse.map(\.metric))
        #expect(worse == [.download, .dns, .drops])
        // Latency barely moved, so it isn't blamed.
        #expect(comparison.changes.first { $0.metric == .latency }?.worse == false)
        #expect(comparison.summary.contains("download"))
        #expect(comparison.summary.contains("DNS lookups 18 ms → 95 ms"))
        #expect(comparison.summary.hasPrefix("Since macOS 27.2"))
    }

    @Test func aboutTheSameSaysSo() throws {
        let hourly = hours(from: 97, to: 168, internet: 22, dns: 18) + hours(from: 1, to: 96, internet: 23, dns: 19)
        let comparison = try #require(MacOSUpgradeComparison.make(timeline: timeline, hourly: hourly, events: [], speedTests: [test(5, down: 480), test(1, down: 470)], now: now))
        #expect(comparison.comparable)
        #expect(comparison.worse.isEmpty)
        #expect(comparison.summary.contains("about the same"))
    }

    @Test func tooLittleDataOnOneSideIsntAVerdict() throws {
        let hourly = hours(from: 97, to: 99, internet: 22, dns: 18) + hours(from: 1, to: 96, internet: 80, dns: 95)
        let comparison = try #require(MacOSUpgradeComparison.make(timeline: timeline, hourly: hourly, events: [], speedTests: [], now: now))
        #expect(!comparison.comparable)
        #expect(comparison.summary.contains("Not enough checks"))
    }

    @Test func onlyARecentUpgradeCounts() {
        let old = [MacOSRelease(version: "27.0", date: now.addingTimeInterval(-90 * 86_400)), MacOSRelease(version: "27.2", date: now.addingTimeInterval(-45 * 86_400))]
        #expect(MacOSUpgradeComparison.make(timeline: old, hourly: [], events: [], speedTests: [], now: now) == nil)
        #expect(MacOSUpgradeComparison.make(timeline: [MacOSRelease(version: "27.2", date: upgraded)], hourly: [], events: [], speedTests: [], now: now) == nil)
    }

    @Test func comparesOneNetworkThePreferredOneWhenItCan() throws {
        let hourly = hours("home", from: 97, to: 168, internet: 22, dns: 18) + hours("home", from: 1, to: 96, internet: 22, dns: 18)
            + hours("office", from: 97, to: 110, internet: 10, dns: 10) + hours("office", from: 1, to: 20, internet: 90, dns: 10)
        let preferred = try #require(MacOSUpgradeComparison.make(timeline: timeline, hourly: hourly, events: [], speedTests: [], network: "office", now: now))
        #expect(preferred.networkKey == "office")
        #expect(preferred.worse.map(\.metric) == [.latency])
        // A network with nothing on one side can't be chosen; the one with most data is.
        let fallback = try #require(MacOSUpgradeComparison.make(timeline: timeline, hourly: hourly, events: [], speedTests: [], network: "café", now: now))
        #expect(fallback.networkKey == "home")
    }

    @Test func keepsTestsOnTheSameKindOfLinkAndVersion() throws {
        // Ethernet before, Wi-Fi after would be a different comparison; a test tagged 27.2 before the date is out.
        let tests = [test(6, down: 900, kind: "Ethernet"), test(5, down: 480), test(5.5, down: 10, macOS: "27.2"), test(1, down: 470), test(2, down: 460, kind: nil)]
        let comparison = try #require(MacOSUpgradeComparison.make(timeline: timeline, hourly: [], events: [], speedTests: tests, now: now))
        #expect(comparison.before.speedTests == 1)
        #expect(comparison.before.downloadMbps == 480)
        #expect(comparison.after.speedTests == 2)
        #expect(comparison.worse.isEmpty)
    }

    @Test func theReportCarriesItWithoutTheNetwork() throws {
        let hourly = hours(from: 97, to: 168, internet: 22, dns: 18) + hours(from: 1, to: 96, internet: 22, dns: 95)
        let comparison = try #require(MacOSUpgradeComparison.make(timeline: timeline, hourly: hourly, events: [], speedTests: [], now: now))
        let sample = snapshot(now.addingTimeInterval(-600), internet: 22, dns: 95)
        // The report's network is the latest check's: the comparison counts only when it's the same one.
        var matching = comparison; matching.networkKey = sample.networkKey
        let report = SupportReport.make(samples: [sample], events: [], speedTests: [], hours: 24, macOSUpgrade: matching, mac: "Mac · macOS 27.2", now: now)
        let upgrade = try #require(report.macOSUpgrade)
        #expect(upgrade.networkName == nil)
        #expect(upgrade.networkKey == nil)
        #expect(report.findings.contains { $0.hasPrefix("Since macOS 27.2") })
        #expect(report.text.contains("Before and after macOS 27.0 → 27.2"))
        #expect(report.markdown.contains("| DNS lookups | 18 ms | **95 ms** |"))
        #expect(report.html.contains("class=\"bad\""))
        #expect(!report.text.contains("Home"))
        let other = SupportReport.make(samples: [sample], events: [], speedTests: [], hours: 24, macOSUpgrade: comparison, mac: "Mac", now: now)
        #expect(other.macOSUpgrade == nil)
    }

    @MainActor @Test func theJournalRecordsAnUpgradeOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-macos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = NetworkJournal(directory: folder)
        let first = Date()
        journal.noteMacOS(at: first, version: "27.0")
        // The first sighting is the start of the record, not an upgrade.
        #expect(journal.events.isEmpty)
        journal.noteMacOS(at: first.addingTimeInterval(60), version: "27.0")
        journal.noteMacOS(at: first.addingTimeInterval(3_600), version: "27.2")
        #expect(journal.events.map(\.kind) == ["macOS upgraded"])
        #expect(journal.events.first?.detail.contains("27.0 → 27.2") == true)
        #expect(journal.macOSSeen.map(\.version) == ["27.0", "27.2"])
        // Saved, so the next launch doesn't record it again.
        let again = NetworkJournal(directory: folder)
        again.noteMacOS(at: first.addingTimeInterval(7_200), version: "27.2")
        #expect(again.events.count == 1)
    }
}
