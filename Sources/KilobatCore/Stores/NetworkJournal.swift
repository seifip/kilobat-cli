import Foundation
import Observation
import CryptoKit
import UserNotifications

public extension DiagnosticSnapshot {
    var networkKey: String {
        let identity = [radio.ssid ?? "SSID unavailable", gateway ?? "no gateway", radio.interface ?? networkService ?? "unknown"].joined(separator: "|")
        return SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    var networkName: String { radio.ssid ?? networkService ?? "Unknown network" }
}
public struct NetworkEvent: Codable, Identifiable, Sendable {
    public var id = UUID()
    public let start: Date
    public var end: Date?
    public let network: String
    public let kind: String
    public var detail: String
}
public struct SavedSpeedTest: Codable, Identifiable, Sendable {
    public var id = UUID()
    public let networkKey: String
    public let networkName: String
    public var networkChanged: Bool? = nil
    public let result: SpeedTestResult
}
@MainActor @Observable public final class NetworkJournal {
    public var events: [NetworkEvent] = []
    public private(set) var samples: [DiagnosticSnapshot] = []
    public private(set) var persistenceError: String?
    public var speedTests: [SavedSpeedTest] = []
    public var alerts = false { didSet { UserDefaults.standard.set(alerts, forKey: "networkAlerts") } }
    public private(set) var targetStatus = "Checking independent targets"
    private var failures = 0
    private var degraded = 0
    private var successes = 0
    private var failureStart: Date?
    private var lastDate: Date?
    private var lastBSSID: String?
    private var lastNetwork: String?
    private var lastAlert = Date.distantPast
    private let directory: URL
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        samples = read("health-samples.json") ?? []; events = read("events.json") ?? []; speedTests = read("speed-tests.json") ?? []
        alerts = UserDefaults.standard.bool(forKey: "networkAlerts")
        // A previous process may have stopped mid-incident. Do not count unobserved time.
        for i in events.indices where events[i].end == nil { events[i].end = events[i].start; events[i].detail += " · monitoring interrupted" }
    }
    private func read<T: Decodable>(_ name: String) -> T? { StoredJSON.read(directory.appendingPathComponent(name)) }
    private func save<T: Encodable>(_ value: T, _ name: String) {
        do { try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(name), options: .atomic); persistenceError = nil }
        catch { persistenceError = error.localizedDescription }
    }
    public func suspend(at date: Date = Date()) {
        finish(at: date, reason: "Monitoring paused")
        failures = 0; successes = 0; degraded = 0; failureStart = nil; lastDate = nil
    }
    private func finish(at date: Date, reason: String) {
        if let index = events.lastIndex(where: { $0.end == nil }) {
            events[index].end = date; events[index].detail += " · " + reason; save(events, "events.json")
        }
    }
    /// `interval` is the expected time between checks; a gap well beyond it means monitoring was paused.
    public func ingest(_ sample: DiagnosticSnapshot, secondary: PingResult, httpReachable: Bool?, interval: TimeInterval = 60, date: Date = Date()) {
        if let previous = lastDate, date.timeIntervalSince(previous) > max(180, 3 * interval + 30) { suspend(at: previous) }
        let sameNetwork = lastNetwork == sample.networkKey
        if !sameNetwork {
            finish(at: lastDate ?? date, reason: "Network changed")
            if lastNetwork != nil { events.append(NetworkEvent(start: date, end: date, network: sample.networkName, kind: "Network changed", detail: "New network baseline")) }
            lastNetwork = sample.networkKey; failures = 0; failureStart = nil; degraded = 0
        }
        if samples.last.map({ date.timeIntervalSince($0.date) >= 60 }) ?? true {
            samples.append(sample); samples = Array(samples.suffix(1440)); save(samples, "health-samples.json")
        }
        if sameNetwork, let previous = lastBSSID, let current = sample.radio.bssid, previous != current {
            events.append(NetworkEvent(start: date, end: date, network: sample.networkName, kind: "Wi-Fi roam", detail: "Access point changed from \(previous) to \(current)"))
        }
        lastBSSID = sample.radio.bssid
        lastDate = date
        let reachable = sample.internet.average != nil || secondary.average != nil || httpReachable == true
        targetStatus = "1.1.1.1: \(sample.internet.average == nil ? "no ICMP reply" : "reachable") · 8.8.8.8: \(secondary.average == nil ? "no ICMP reply" : "reachable")" + (httpReachable.map { " · HTTPS: \($0 ? "reachable" : "failed")" } ?? "")
        if reachable {
            failures = 0; failureStart = nil; successes += 1
            if successes >= 2 { finish(at: date, reason: "Recovered after two successful checks") }
        } else {
            successes = 0; failures += 1
            if failureStart == nil { failureStart = date }
            if failures == 3 && !events.contains(where: { $0.end == nil }) {
                events.append(NetworkEvent(start: failureStart ?? date, end: nil, network: sample.networkName, kind: "Unreachable", detail: "Both independent ping targets and HTTPS fallback failed. This is reachability evidence, not proof of ISP failure."))
                notify("Connection unreachable", "Three consecutive checks failed on \(sample.networkName).")
            }
        }
        let slow = (sample.internet.average ?? 0) > 150 || (sample.internet.lossPercent ?? 0) >= 5 || sample.radio.health == .poor
        degraded = slow ? degraded + 1 : 0
        if degraded == 3 { notify("Connection quality dropped", "Sustained latency, packet loss or weak Wi-Fi signal on \(sample.networkName).") }
        events = Array(events.suffix(500)); save(events, "events.json")
    }
    public func add(_ test: SpeedTestResult, network: DiagnosticSnapshot?, networkChanged: Bool = false) {
        speedTests.append(SavedSpeedTest(networkKey: network?.networkKey ?? "unknown", networkName: network?.networkName ?? "Unknown network", networkChanged: networkChanged, result: test))
        speedTests = Array(speedTests.suffix(200)); save(speedTests, "speed-tests.json")
    }
    public func requestAlerts() async {
        do { alerts = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        catch { alerts = false }
    }
    private func notify(_ title: String, _ body: String) {
        guard alerts, Date().timeIntervalSince(lastAlert) > 900 else { return }
        lastAlert = Date(); let content = UNMutableNotificationContent(); content.title = title; content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
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
