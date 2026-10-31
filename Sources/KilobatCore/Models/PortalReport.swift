import Foundation

/// `kilobat portal` and the get_captive_portal tool: a check now, this network's sign-ins, and every network's history.
public enum PortalReport {
    public enum Command: Equatable, Sendable { case status(json: Bool), open }
    public struct UsageError: LocalizedError, Sendable { public var errorDescription: String? { "Use portal [--json] or portal open." } }

    /// The words after `portal`.
    public static func parse(_ args: [String]) throws -> Command {
        switch args {
        case []: return .status(json: false)
        case ["--json"]: return .status(json: true)
        case ["open"]: return .open
        default: throw UsageError()
        }
    }

    /// The network a check is about: the app's current one when it answered, else one whose sign-in page this is,
    /// else the one seen in the last 15 minutes.
    public static func network(_ networks: [PortalNetwork], appKey: String?, check: PortalCheck, now: Date = Date()) -> PortalNetwork? {
        if let appKey { return networks.first { $0.id == appKey } }
        if let host = check.host, let match = networks.filter({ $0.host == host }).max(by: { $0.lastSeen < $1.lastSeen }) { return match }
        return networks.max { $0.lastSeen < $1.lastSeen }.flatMap { now.timeIntervalSince($0.lastSeen) < 900 ? $0 : nil }
    }

    public static func json(check: PortalCheck, network: PortalNetwork?, networks: [PortalNetwork], now: Date = Date()) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        func date(_ value: Date?) -> Any { value.map { iso.string(from: $0) } ?? NSNull() }
        func minutes(_ seconds: TimeInterval?) -> Any { seconds.map { Int(($0 / 60).rounded()) } ?? NSNull() }
        let status = PortalWatch.status(of: network, check: check, now: now)
        var value: [String: Any] = ["state": check.state.rawValue, "checkedAt": iso.string(from: check.date),
                                    "signInPage": check.url.map(ConnectionProbe.redacted) ?? NSNull(), "host": check.host ?? NSNull(),
                                    "hintMinutes": check.hintMinutes ?? NSNull(),
                                    "network": network?.name ?? NSNull(), "place": network?.place ?? NSNull(),
                                    "typicalMinutes": minutes(network?.typicalSeconds)]
        switch status {
        case .none: value["status"] = "none"
        case .signInNeeded: value["status"] = "signInNeeded"
        case .loggedOut(let since): value["status"] = "loggedOut"; value["loggedOutSince"] = iso.string(from: since)
        case .signedIn(let since):
            value["status"] = "signedIn"; value["signedInSince"] = iso.string(from: since)
            if let typical = network?.typicalSeconds {
                let end = since.addingTimeInterval(typical)
                value["expectedEnd"] = iso.string(from: end); value["minutesLeft"] = max(0, Int((end.timeIntervalSince(now) / 60).rounded()))
            }
        }
        value["networks"] = networks.sorted { $0.lastSeen > $1.lastSeen }.map { network -> [String: Any] in
            ["name": network.name, "place": network.place ?? NSNull(), "host": network.host ?? NSNull(),
             "sessions": network.sessions.count, "measuredSessions": network.measured.count,
             "typicalMinutes": minutes(network.typicalSeconds), "hintMinutes": network.hintMinutes ?? NSNull(),
             "signedIn": network.openSession != nil, "firstSeen": date(network.firstSeen), "lastSeen": date(network.lastSeen)]
        }
        return value
    }

    /// The same as text, for a terminal.
    public static func text(check: PortalCheck, network: PortalNetwork?, networks: [PortalNetwork], now: Date = Date()) -> String {
        let name = network.map { $0.place.map { "\($0) (\(network!.name))" } ?? $0.name }
        var lines: [String] = []
        switch PortalWatch.status(of: network, check: check, now: now) {
        case .none:
            lines.append(check.state == .offline ? "Offline: neither check page answered, so this isn't a sign-in page." : "No sign-in page in the way" + (network?.openSession == nil ? "." : ": signed in."))
        case .signInNeeded: lines.append("This Wi-Fi wants you to sign in. Run kilobat portal open.")
        case .loggedOut(let since):
            lines.append("Logged out by \(name ?? "the Wi-Fi")’s sign-in page (last through at \(since.formatted(date: .omitted, time: .shortened))). The internet isn’t down. Run kilobat portal open.")
        case .signedIn(let since):
            var line = "Signed in to \(name ?? "this Wi-Fi") since \(since.formatted(date: .omitted, time: .shortened))"
            if let typical = network?.typicalSeconds {
                let left = since.addingTimeInterval(typical).timeIntervalSince(now)
                line += left > 60 ? " · about \(PortalWatch.length(left)) left" : " · it usually runs out about now"
            }
            lines.append(line + ".")
        }
        if check.state == .portal { lines.append("Sign-in page: " + (check.url.map(ConnectionProbe.redacted) ?? "the page didn’t say where")) }
        if let typical = network?.typicalSeconds { lines.append("Sign-ins here last about \(PortalWatch.length(typical)) (\(network!.measured.count) seen whole).") }
        else if network != nil { lines.append("How long sign-ins last here: not learned yet; it takes two sign-ins seen from start to end.") }
        if !networks.isEmpty {
            lines.append("\nNetworks with a sign-in page")
            for network in networks.sorted(by: { $0.lastSeen > $1.lastSeen }) {
                let label = network.place.map { "\($0) (\(network.name))" } ?? network.name
                let typical = network.typicalSeconds.map { "about \(PortalWatch.length($0))" } ?? "length not learned"
                lines.append("  \(label)  \(network.host ?? "unknown page") · \(network.sessions.count) sign-ins · \(typical) · last \(network.lastSeen.formatted(date: .abbreviated, time: .shortened))")
            }
        } else { lines.append("\nNo network with a sign-in page yet. The Kilobat app records them while it runs.") }
        return lines.joined(separator: "\n")
    }
}
