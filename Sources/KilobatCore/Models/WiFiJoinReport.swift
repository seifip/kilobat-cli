import CryptoKit
import Foundation

/// One click on Join, including any alternate access point CoreWLAN tried. The stored error is a
/// domain and number only. A report never needs the password, NSError userInfo or a complete BSSID.
public struct WiFiJoinAttempt: Codable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let started: Date
    var steps: [Step] = []
    var checks: [Check] = []

    enum Stage: String, Codable {
        case seen, scanFailed, unavailable, joining, joinFailed, joined, unconfirmed
        var title: String {
            switch self {
            case .seen: String(localized: "Network seen in the Wi-Fi menu")
            case .scanFailed: String(localized: "Wi-Fi scan failed")
            case .unavailable: String(localized: "Network unavailable on rescan")
            case .joining: String(localized: "Joining access point")
            case .joinFailed: String(localized: "Join failed")
            case .joined: String(localized: "Joined Wi-Fi")
            case .unconfirmed: String(localized: "Wi-Fi join unconfirmed")
            }
        }
    }
    struct Step: Codable, Sendable {
        let date: Date
        let stage: Stage
        var ap: String?
        var suffix: String?
        var signal: Int?
        var channel: Int?
        var domain: String?
        var code: Int?
    }
    struct Check: Codable, Equatable, Sendable {
        let date: Date
        let address: LinkAddressState?
        let gateway: Bool
        let dns: Bool?
        let portal: Bool?
        let internet: Bool?
    }
    init(name: String, started: Date = Date()) { id = UUID(); self.name = name; self.started = started }
    public var problem: Bool {
        steps.contains { $0.stage == .joinFailed } || steps.last?.stage != .joined || checks.contains { $0.address == LinkAddressState.none || $0.address == .selfAssigned || $0.dns == false || $0.portal == true || $0.internet == false }
    }
    static func accessPoint(_ bssid: String?) -> String? {
        guard let address = bssid?.lowercased(), address.count == 17,
              address.split(separator: ":").count == 6, address != "00:00:00:00:00:00",
              address.split(separator: ":").allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return SHA256.hash(data: Data(address.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    public func matches(_ choice: WiFiChoice) -> Bool {
        name == choice.name && choice.accessPoint.map { accessPoints.contains($0) } == true
    }
    var accessPoints: Set<String> { Set(steps.compactMap(\.ap)) }
    mutating func observe(_ sample: DiagnosticSnapshot, startedAt: Date, probesRan: Bool = true) -> Bool {
        // macOS can finish associating after CoreWLAN has returned an error. Keep both observations.
        guard let last = steps.last, [.joined, .joinFailed, .unconfirmed].contains(last.stage),
              startedAt >= last.date, sample.date >= startedAt, sample.date.timeIntervalSince(last.date) <= 600,
              sample.radio.ssid == name, sample.wiredInterface == nil, sample.tunneledRoute != true,
              let point = Self.accessPoint(sample.radio.bssid) else { return false }
        let joinedRadio = last.stage == .joined ? last.ap == point : steps.contains { $0.stage == .joining && $0.ap == point }
        guard joinedRadio else { return false }
        let internet: Bool? = switch sample.reachability { case .up: true; case .down: false; case .unknown: nil }
        let check = Check(date: sample.date, address: sample.radioAddress, gateway: (sample.physicalGateway ?? sample.gateway) != nil,
                          dns: probesRan ? sample.dnsMilliseconds != nil : nil, portal: sample.captivePortal, internet: probesRan ? internet : nil)
        if let last = checks.last, last.address == check.address && last.gateway == check.gateway &&
            last.dns == check.dns && last.portal == check.portal && last.internet == check.internet { return false }
        guard checks.count < 20 else { return false }
        checks.append(check)
        return true
    }
}

/// A frozen guest summary followed by local timestamps, access-point suffixes and the OS errors.
public struct WiFiJoinReport: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let started: Date
    public let summary: String
    public let lines: [String]
    public var guestText: String { name + " · " + started.formatted(date: .abbreviated, time: .shortened) + "\n" + summary }
    public var text: String { guestText + "\n\n" + lines.joined(separator: "\n") }
    public var html: String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let rows = lines.map { "<tr><td>" + escape($0) + "</td></tr>" }.joined()
        return """
        <!doctype html><html dir="auto"><head><meta charset="utf-8"><style>\(SupportReport.css)</style></head><body><main>
        <header><div class="brand">\(SupportReport.batSVG)<span>kilobat</span></div></header>
        <h1>\(escape(name))</h1><p>\(escape(summary))</p>
        <section><h2>\(escape(String(localized: "Timeline")))</h2><table>\(rows)</table></section>
        </main></body></html>
        """
    }

    init(attempt: WiFiJoinAttempt, history: [WiFiJoinAttempt], tests: [SavedSpeedTest]) {
        id = attempt.id
        name = attempt.name.components(separatedBy: .controlCharacters).joined(separator: " ")
        // Join retries close in time must share a radio. The same SSID alone can identify another property.
        let related = history.filter { $0.id == attempt.id || ($0.name == attempt.name && $0.started <= attempt.started &&
            attempt.started.timeIntervalSince($0.started) <= 1800 && !$0.accessPoints.isDisjoint(with: attempt.accessPoints)) }
            .sorted { $0.started < $1.started }
        let end = (attempt.checks.last?.date ?? attempt.steps.last?.date ?? attempt.started).addingTimeInterval(600)
        let start = related.first?.started ?? attempt.started
        self.started = start
        let points = Set(related.flatMap(\.steps).filter { $0.stage == .joining || $0.stage == .joined }.compactMap(\.ap))
        let speeds = tests.filter { test in
            guard let ap = test.verifiedAccessPoint, let began = test.verifiedStart else { return false }
            return points.contains(ap) && test.networkName == attempt.name && test.networkChanged == false &&
                began >= start && test.result.date <= end && test.result.date >= began
        }
        let outcome: String
        if let check = attempt.checks.last {
            if check.address == LinkAddressState.none || check.address == .selfAssigned {
                outcome = String(localized: "This Mac joined Wi-Fi but had no usable network address.")
            } else if check.portal == true {
                outcome = String(localized: "This Mac joined Wi-Fi and reached a sign-in page.")
            } else if check.dns == false && check.internet == true {
                outcome = String(localized: "This Mac joined Wi-Fi and the internet responded.") + " " + String(localized: "DNS isn’t answering") + "."
            } else if check.internet == true {
                outcome = String(localized: "This Mac joined Wi-Fi and the internet responded.")
            } else {
                outcome = String(localized: "This Mac joined Wi-Fi. Internet access could not be confirmed.")
            }
        } else if attempt.steps.last?.stage == .joined {
            outcome = String(localized: "This Mac joined Wi-Fi. Internet access could not be confirmed.")
        } else {
            outcome = String(localized: "The network appeared in the Wi-Fi menu. This Mac could not confirm a connection.")
        }
        var findings = [outcome]
        if (attempt.steps.last?.stage == .joined || !attempt.checks.isEmpty) && related.flatMap(\.steps).contains(where: { $0.stage == .joinFailed }) {
            findings.insert(String(localized: "Join failed") + ".", at: 0)
        }
        if let speed = speeds.last?.result {
            let down = String(format: "%.1f", locale: Locale.current, speed.downloadMbps)
            let up = String(format: "%.1f", locale: Locale.current, speed.uploadMbps)
            findings.append(String(localized: "Speed: \(down) Mbps down / \(up) Mbps up"))
        } else {
            findings.append(String(localized: "No speed measurement was verified on this network during the incident."))
        }
        summary = findings.joined(separator: " ")
        let timestamp = Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: .current)
        func time(_ d: Date) -> String { d.formatted(timestamp) }
        var rows: [(Date, String)] = []
        for item in related {
            for step in item.steps {
                var parts = [time(step.date), step.stage.title]
                if let suffix = step.suffix { parts.append("BSSID …:" + suffix) }
                if let signal = step.signal { parts.append("\(signal) dBm") }
                if let channel = step.channel { parts.append(String(localized: "channel \(channel)")) }
                if let domain = step.domain, let code = step.code { parts.append("\(domain) (\(code))") }
                rows.append((step.date, parts.joined(separator: " · ")))
            }
            for check in item.checks {
                func reading(_ state: Bool?) -> String {
                    switch state { case .some(true): String(localized: "Yes"); case .some(false): String(localized: "No"); default: String(localized: "Unknown") }
                }
                let address = check.address.map { $0 == .assigned }
                rows.append((check.date, [time(check.date), String(localized: "Usable address") + " " + reading(address),
                             "IPv4 " + String(localized: "Gateway") + " " + reading(check.gateway),
                             "DNS " + reading(check.dns),
                             String(localized: "Sign-in page") + " " + reading(check.portal),
                             String(localized: "Internet reachable") + " " + reading(check.internet)].joined(separator: " · ")))
            }
        }
        for speed in speeds {
            rows.append((speed.result.date, [time(speed.result.date), "↓ " + SupportReport.mbps(speed.result.downloadMbps),
                         "↑ " + SupportReport.mbps(speed.result.uploadMbps)].joined(separator: " · ")))
        }
        lines = rows.sorted { $0.0 < $1.0 }.map(\.1)
    }
}


/// A generation changes even if the default route switches away and comes back to the same radio.
struct WiFiSpeedPath: Equatable {
    let name: String
    let accessPoint: String
    let revision: UInt64

    func verified(endingOn end: Self?, context: SpeedTestContext?) -> String? {
        guard self == end, context?.kind == "Wi-Fi", context?.ssid == name else { return nil }
        return accessPoint
    }
}
