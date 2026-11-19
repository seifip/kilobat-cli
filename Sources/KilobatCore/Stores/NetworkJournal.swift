import Foundation
import Observation
import CryptoKit
import UserNotifications

public extension DiagnosticSnapshot {
    /// A wired link names the network by its service and gateway, the same whether Wi-Fi is joined alongside or not.
    var networkKey: String {
        let wifi = wiredInterface == nil ? radio : nil
        guard networkIdentified else { return "unknown" }
        var components = [wifi?.ssid ?? "SSID unavailable", physicalGateway ?? gateway ?? "no gateway", wifi?.interface ?? networkService ?? "unknown"]
        if let wiredInterface { components += [wiredInterface, gatewayMAC ?? ""] }
        let identity = components.joined(separator: "|")
        return SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    var networkName: String { (wiredInterface == nil ? radio.ssid : nil) ?? networkService ?? String(localized: "Unknown network") }
    /// Wi-Fi without its name (macOS hides it without Location) looks the same as any network behind the same router address.
    var networkIdentified: Bool {
        if wiredInterface != nil { return gatewayMAC != nil && (physicalGateway ?? gateway) != nil }
        return radio.ssid != nil && (tunneledRoute != true || physicalGateway != nil) && (physicalGateway ?? gateway) != nil
    }
}
public struct NetworkEvent: Codable, Identifiable, Sendable, Equatable {
    public var id = UUID()
    public let start: Date
    public var end: Date?
    public let network: String
    public var networkKey: String? = nil
    public let kind: String
    public var detail: String
    /// For an outage: Kilobat's checks while it lasted and how many of them the router answered, which says whether
    /// it broke beyond the router. Nil on outages recorded before Kilobat kept them.
    public var routerChecks: Int? = nil
    public var routerAnswered: Int? = nil
    var lastObserved: Date? = nil

    /// Preserve the existing CLI/MCP event shape; the stable identity is only for local correlation.
    public var withoutNetworkKey: NetworkEvent {
        var copy = self
        copy.networkKey = nil
        copy.lastObserved = nil
        return copy
    }
}
public extension NetworkEvent {
    init(start: Date, end: Date?, network: String, kind: String, detail: String, routerChecks: Int?, routerAnswered: Int?, networkKey: String? = nil) {
        self.start = start; self.end = end; self.network = network; self.kind = kind; self.detail = detail
        self.networkKey = networkKey; self.routerChecks = routerChecks; self.routerAnswered = routerAnswered
    }
}
public struct SavedSpeedTest: Codable, Identifiable, Sendable {
    public var id = UUID()
    public let networkKey: String
    public let networkName: String
    public var networkChanged: Bool? = nil
    public var reservedAttempt: Bool? = nil
    public let result: SpeedTestResult
    /// Started by Kilobat on a schedule (a plan check or Scheduled speed tests), not by you. Nil for tests you ran.
    public var scheduled: Bool? = nil
    /// The macOS version the test ran on, such as "27.2". Nil on tests saved before Kilobat recorded it.
    public var macOS: String? = nil
}
@MainActor @Observable public final class NetworkJournal {
    public var events: [NetworkEvent] = []
    public private(set) var samples: [DiagnosticSnapshot] = []
    public private(set) var persistenceError: String?
    public var speedTests: [SavedSpeedTest] = []
    /// Each hour's checks per network, kept 120 days: the record a macOS upgrade is compared against.
    public private(set) var hourly: [HourlyCheck] = []
    /// Each macOS version Kilobat has run on, and when it first did.
    public private(set) var macOSSeen: [MacOSRelease] = []
    public var alerts = false { didSet { UserDefaults.standard.set(alerts, forKey: "networkAlerts") } }
    public private(set) var targetStatus = "Checking independent targets"
    public private(set) var planAttempts: [PlanCheck.Attempt] = []
    /// Each wake's stage timing: when the link, the address, DNS and the first web request came back (wakes.json).
    public private(set) var wakes: [WakeRecord] = []
    private var failures = 0
    private var degraded = 0
    private var successes = 0
    private var failureStart: Date?
    /// Checks since the first failure, and how many the router answered, until an outage opens and takes them over.
    private var pendingChecks = 0
    private var pendingAnswered = 0
    private var lastDate: Date?
    private var lastBSSID: String?
    private var lastNetwork: String?
    private var lastAlert = Date.distantPast
    @ObservationIgnored private var samplesRewritten = Date.distantPast
    @ObservationIgnored private var sampleTailRows = 0
    private static let samplesRewriteEvery: TimeInterval = 3600, sampleTailLimit = 120
    private let directory: URL
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        samples = HealthSampleFile.read(self.directory); events = read("events.json") ?? []; speedTests = read("speed-tests.json") ?? []
        planAttempts = read("plan-attempts.json") ?? []
        hourly = read("hourly-checks.json") ?? []; macOSSeen = read("macos-versions.json") ?? []
        wakes = read("wakes.json") ?? []
        alerts = UserDefaults.standard.object(forKey: "networkAlerts") as? Bool ?? true
        // A previous process may have stopped mid-incident. Do not count unobserved time.
        for i in events.indices where events[i].end == nil { events[i].end = max(events[i].start, events[i].lastObserved ?? events[i].start); events[i].detail += " · " + String(localized: "monitoring interrupted") }
    }
    private func read<T: Decodable>(_ name: String) -> T? { StoredJSON.read(directory.appendingPathComponent(name)) }
    private func save<T: Encodable>(_ value: T, _ name: String) {
        do { try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(name), options: .atomic); persistenceError = nil }
        catch { persistenceError = error.localizedDescription }
    }
    public func suspend(at date: Date = Date()) {
        finish(at: date, reason: String(localized: "Monitoring paused"))
        failures = 0; successes = 0; degraded = 0; failureStart = nil; lastDate = nil
    }
    private func finish(at date: Date, reason: String) {
        if let index = events.lastIndex(where: { $0.end == nil }) {
            events[index].end = date; events[index].detail += " · " + reason; save(events, "events.json")
        }
    }
    /// `interval` is the expected time between checks; a gap well beyond it means monitoring was paused.
    public func ingest(_ sample: DiagnosticSnapshot, secondary: PingResult, httpReachable: Bool?, interval: TimeInterval = 60, date: Date = Date()) {
        let eventsBefore = events
        if let previous = lastDate, date.timeIntervalSince(previous) > max(180, 3 * interval + 30) { suspend(at: previous) }
        let sameNetwork = lastNetwork == sample.networkKey
        if !sameNetwork {
            finish(at: lastDate ?? date, reason: String(localized: "Network changed"))
            if lastNetwork != nil { events.append(NetworkEvent(start: date, end: date, network: sample.networkName, networkKey: sample.networkKey, kind: "Network changed", detail: String(localized: "New network baseline"))) }
            lastNetwork = sample.networkKey; failures = 0; successes = 0; failureStart = nil; degraded = 0
        }
        noteMacOS(at: date)
        if !sameNetwork || (samples.last.map({ date.timeIntervalSince($0.date) >= 60 }) ?? true) {
            samples.append(sample); samples = Array(samples.suffix(HealthSampleFile.limit))
            // The new sample is all that's new: the whole file about once an hour, on a new network, and first thing after launch.
            if !sameNetwork || abs(date.timeIntervalSince(samplesRewritten)) >= Self.samplesRewriteEvery || sampleTailRows >= Self.sampleTailLimit {
                save(samples, HealthSampleFile.name)
                if persistenceError == nil { HealthSampleFile.removeTail(directory: directory); samplesRewritten = date; sampleTailRows = 0 }
            } else {
                do { try HealthSampleFile.append(sample, directory: directory); sampleTailRows += 1; persistenceError = nil }
                catch { persistenceError = error.localizedDescription }
            }
        }
        summarizeHours(before: date)
        if sameNetwork, let previous = lastBSSID, let current = sample.radio.bssid, previous != current {
            events.append(NetworkEvent(start: date, end: date, network: sample.networkName, networkKey: sample.networkKey, kind: "Wi-Fi roam", detail: String(localized: "Access point changed from \(previous) to \(current)")))
        }
        lastBSSID = sample.radio.bssid
        lastDate = date
        let reachable = sample.internet.average != nil || secondary.average != nil || httpReachable == true
        targetStatus = "1.1.1.1: \(sample.internet.average == nil ? "no ICMP reply" : "reachable") · 8.8.8.8: \(secondary.average == nil ? "no ICMP reply" : "reachable")" + (httpReachable.map { " · HTTPS: \($0 ? "reachable" : "failed")" } ?? "")
        if reachable {
            failures = 0; failureStart = nil; successes += 1
            if successes >= 2 { finish(at: date, reason: String(localized: "Recovered after two successful checks")) }
        } else {
            successes = 0; failures += 1
            if failureStart == nil { failureStart = date; pendingChecks = 0; pendingAnswered = 0 }
            let answered = sample.router?.average != nil
            if let open = events.lastIndex(where: { $0.end == nil && $0.kind == "Unreachable" }) {
                events[open].routerChecks = (events[open].routerChecks ?? 0) + 1
                events[open].routerAnswered = (events[open].routerAnswered ?? 0) + (answered ? 1 : 0)
            } else { pendingChecks += 1; pendingAnswered += answered ? 1 : 0 }
            if failures == 3 && !events.contains(where: { $0.end == nil }) && sample.setupNetwork != nil {
                // A printer's, camera's or drone's own Wi-Fi: no internet by design, so logged once and never counted or alerted.
                events.append(NetworkEvent(start: failureStart ?? date, end: nil, network: sample.networkName, networkKey: sample.networkKey, kind: "Device Wi-Fi",
                                           detail: sample.setupNetwork!.headline))
            } else if failures == 3 && !events.contains(where: { $0.end == nil }) && sample.captivePortal == true {
                // The Wi-Fi's sign-in page, not an outage: logged, not counted against the provider, no alert (PortalWatch has its own).
                events.append(NetworkEvent(start: failureStart ?? date, end: nil, network: sample.networkName, networkKey: sample.networkKey, kind: "Wi-Fi sign-in",
                                           detail: sample.portalLoggedOut == true ? String(localized: "The Wi-Fi’s sign-in page logged this Mac out.") : String(localized: "The Wi-Fi’s sign-in page is waiting for you to sign in.")))
            } else if failures == 3 && !events.contains(where: { $0.end == nil }) {
                events.append(NetworkEvent(start: failureStart ?? date, end: nil, network: sample.networkName, kind: "Unreachable", detail: String(localized: "Both independent ping targets and HTTPS fallback failed. This is reachability evidence, not proof of ISP failure."),
                                           routerChecks: pendingChecks, routerAnswered: pendingAnswered, networkKey: sample.networkKey))
                notify(String(localized: "Connection unreachable"), String(localized: "Three consecutive checks failed on \(sample.networkName)."))
            }
        }
        if !reachable, let open = events.lastIndex(where: { $0.end == nil }) {
            events[open].lastObserved = date
        }
        let slow = sample.setupNetwork == nil && ((sample.internet.average ?? 0) > 150 || (sample.internet.lossPercent ?? 0) >= 5 || sample.activeRadioHealth == .poor)
        degraded = slow ? degraded + 1 : 0
        if degraded == 3 { notify(String(localized: "Connection quality dropped"), String(localized: "Sustained latency, packet loss or weak Wi-Fi signal on \(sample.networkName).")) }
        events = Array(events.suffix(500))
        if events != eventsBefore { save(events, "events.json") }
    }
    /// Made-up history for screenshots, in memory only: nothing is saved.
    public func preview(samples: [DiagnosticSnapshot], events: [NetworkEvent], speedTests: [SavedSpeedTest], hourly: [HourlyCheck]? = nil, macOS: [MacOSRelease]? = nil) {
        self.samples = samples; self.events = events; self.speedTests = speedTests
        if let hourly { self.hourly = hourly }
        if let macOS { macOSSeen = macOS; previewTimeline = macOS }
    }
    @ObservationIgnored private var previewTimeline: [MacOSRelease]?

    // MARK: macOS upgrades

    /// The macOS versions this Mac has run, oldest first: the installer's log, filled in with what Kilobat saw.
    public var macOSTimeline: [MacOSRelease] {
        previewTimeline ?? MacOSVersion.timeline(installed: installHistory, seen: macOSSeen)
    }
    @ObservationIgnored private lazy var installHistory = MacOSVersion.readInstallHistory()

    /// The latest upgrade in the last 30 days against the week before it, on `network` when it has checks both sides.
    public func macOSComparison(network: String? = nil, now: Date = Date()) -> MacOSUpgradeComparison? {
        MacOSUpgradeComparison.make(timeline: macOSTimeline, hourly: hourly, events: events, speedTests: speedTests, network: network, now: now)
    }

    /// The first check on a new macOS version records it, and an event in History. The very first sighting dates
    /// itself from the installer's log, or from the oldest check still kept, so the last day's checks count as on it.
    func noteMacOS(at date: Date, version: String = MacOSVersion.current) {
        guard macOSSeen.last?.version != version else { return }
        let previous = macOSSeen.last
        if previous == nil {
            let installed = installHistory.last { $0.version == version }?.date
            macOSSeen = [MacOSRelease(version: version, date: installed ?? samples.first?.date ?? date)]
        } else {
            macOSSeen.append(MacOSRelease(version: version, date: date))
            installHistory = MacOSVersion.readInstallHistory()
        }
        save(macOSSeen, "macos-versions.json")
        guard let previous else { return }
        let newer = MacOSVersion.isNewer(version, than: previous.version)
        // When the installer says, the change happened then; Kilobat wasn't running while the Mac restarted.
        let when = installHistory.last { $0.version == version && $0.date > previous.date && $0.date <= date }?.date ?? date
        record(kind: newer ? "macOS upgraded" : "macOS changed",
               detail: String(localized: "macOS \(previous.version) → \(version). History compares the week before with the days since.", comment: "History event: the Mac moved to another macOS version"),
               network: samples.last?.networkName ?? String(localized: "This Mac"), date: when)
    }

    /// Hours that ended get one summary per network. The samples cover a day, so hours missed while the app was
    /// closed are caught up on the next check.
    private func summarizeHours(before date: Date, calendar: Calendar = .current) {
        guard let current = calendar.dateInterval(of: .hour, for: date)?.start else { return }
        let done = hourly.last?.hour ?? .distantPast
        let pending = samples.filter { sample in
            guard let hour = calendar.dateInterval(of: .hour, for: sample.date)?.start else { return false }
            return hour > done && hour < current
        }
        guard !pending.isEmpty else { return }
        let timeline = MacOSVersion.timeline(installed: [], seen: macOSSeen)
        hourly += HourlyCheck.summarize(pending, macOS: { MacOSVersion.version(at: $0, in: timeline) }, calendar: calendar)
        let cutoff = date.addingTimeInterval(-120 * 86_400)
        hourly = Array(hourly.drop { $0.hour < cutoff }.suffix(8_000))
        save(hourly, "hourly-checks.json")
    }
    /// One wake's timing. A wake that was slow, or where a step never came, also gets a line in the event log.
    public func addWake(_ record: WakeRecord) {
        wakes.append(record); wakes = Array(wakes.suffix(200)); save(wakes, "wakes.json")
        guard record.problem != .none else { return }
        events.append(NetworkEvent(start: record.woke, end: record.woke.addingTimeInterval(record.internet ?? record.watched), network: record.network ?? String(localized: "Unknown network"),
                                   networkKey: record.networkKey, kind: "Slow wake", detail: record.title + " · " + record.stagesLine))
        events = Array(events.suffix(500)); save(events, "events.json")
    }
    /// The latest wake on a network, within `within` seconds of now.
    public func recentWake(within: TimeInterval = 900, now: Date = Date()) -> WakeRecord? {
        wakes.last.flatMap { now.timeIntervalSince($0.woke) <= within ? $0 : nil }
    }
    /// Made-up wakes for screenshots, in memory only.
    public func previewWakes(_ wakes: [WakeRecord]) { self.wakes = wakes }
    /// A change worth a line in the event log, such as a VPN going on or off. Never an alert.
    public func record(kind: String, detail: String, network: String, date: Date = Date()) {
        events.append(NetworkEvent(start: date, end: date, network: network, kind: kind, detail: detail))
        events = Array(events.suffix(500)); save(events, "events.json")
    }
    public func add(_ test: SpeedTestResult, network: DiagnosticSnapshot?, networkChanged: Bool = false, scheduled: Bool = false, reservedAttempt: Bool? = nil) {
        speedTests.append(SavedSpeedTest(networkKey: network?.networkKey ?? "unknown", networkName: network?.networkName ?? String(localized: "Unknown network"), networkChanged: networkChanged, reservedAttempt: reservedAttempt, result: test, scheduled: scheduled ? true : nil, macOS: MacOSVersion.current))
        speedTests = Array(speedTests.suffix(200)); save(speedTests, "speed-tests.json")
    }
    /// Reserve the full transfer allowance before starting. A failure or cancellation may have spent it.
    public func reservePlanCheck(network: String, maximumBytes: Int, now: Date = Date()) -> Bool {
        let attempts = planAttempts.filter { now.timeIntervalSince($0.date) < 7 * 86_400 }
            + [PlanCheck.Attempt(network: network, date: now, reservedBytes: maximumBytes)]
        save(attempts, "plan-attempts.json")
        guard persistenceError == nil else { return false }
        planAttempts = attempts
        return true
    }

    /// The newest test that ran start to finish on this network, for the This place card.
    public func latestSpeedTest(onNetwork key: String?) -> SpeedTestResult? {
        guard let key, key != "unknown" else { return nil }
        return speedTests.last { $0.networkKey == key && $0.networkChanged != true }?.result
    }
    public func requestAlerts() async {
        do { alerts = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        catch { alerts = false }
    }
    /// An alert for something other than an outage, under the same Connection alerts setting.
    public func alert(_ title: String, _ body: String) { notify(title, body) }
    private func notify(_ title: String, _ body: String) {
        // Notifications need an app bundle; macOS asks for permission the first time there is something to say.
        guard alerts, Bundle.main.bundleIdentifier != nil, Date().timeIntervalSince(lastAlert) > 900 else { return }
        lastAlert = Date(); let content = UNMutableNotificationContent(); content.title = title; content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }
    public static func httpFallback() async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            for endpoint in ["https://www.apple.com/library/test/success.html", "https://www.cloudflare.com/cdn-cgi/trace"] {
                group.addTask {
                    var request = URLRequest(url: URL(string: endpoint)!); request.httpMethod = "HEAD"; request.timeoutInterval = 4; request.cachePolicy = .reloadIgnoringLocalCacheData
                    do { let (_, response) = try await URLSession.shared.data(for: request); return (response as? HTTPURLResponse).map { (200..<400).contains($0.statusCode) } ?? false } catch { return false }
                }
            }
            var reachable = false
            for await result in group { reachable = reachable || result }
            return reachable
        }
    }
}

/// Health samples on disk: the last day in health-samples.json, rewritten about once an hour and whenever the network
/// changes, and each sample since then appended to a small tail, so a check doesn't rewrite a megabyte. Readers go
/// through `read`, which puts the two together. An older CLI reads only the whole file and sees it up to an hour behind.
enum HealthSampleFile {
    static let name = "health-samples.json", tail = "health-samples-tail.jsonl", limit = 1440
    /// `quarantine: false` for a reader that only visits (the digest): an unreadable file stays where it is.
    static func read(_ directory: URL, quarantine: Bool = LocalFiles.movesUnreadableAside) -> [DiagnosticSnapshot] {
        var rows: [DiagnosticSnapshot] = StoredJSON.read(directory.appendingPathComponent(name), quarantine: quarantine) ?? []
        // A crash between saving the whole file and clearing the tail leaves rows in both; the whole file wins.
        let newest = rows.map(\.date).max() ?? .distantPast
        rows += tailRows(directory).filter { $0.date > newest }
        return Array(rows.suffix(limit))
    }
    /// One JSON object per line. A line cut short by a crash is skipped; the rows before it are good.
    static func tailRows(_ directory: URL) -> [DiagnosticSnapshot] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(tail)) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(DiagnosticSnapshot.self, from: Data($0)) }
    }
    static func append(_ row: DiagnosticSnapshot, directory: URL) throws {
        let file = directory.appendingPathComponent(tail)
        var line = try JSONEncoder().encode(row)
        line.append(0x0A)
        guard FileManager.default.fileExists(atPath: file.path) else { try line.write(to: file, options: .atomic); return }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
    static func removeTail(directory: URL) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(tail)) }
}
