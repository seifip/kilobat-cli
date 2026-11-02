import Foundation

/// One SSH, Mosh or remote desktop session as Kilobat saw it from outside: how the line to the host behaved, when
/// typing lagged or the screen froze, and why. Built by the call report engine, with the host's own round trip added.
public struct RemoteSessionReport: Codable, Identifiable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case ssh, mosh, screenSharing, parsec, jump, windowsApp, anyDesk, teamViewer, rustDesk
        public var name: String {
            switch self {
            case .ssh: "SSH"
            case .mosh: "Mosh"
            case .screenSharing: String(localized: "Screen Sharing", comment: "macOS's Screen Sharing app")
            case .parsec: "Parsec"
            case .jump: "Jump Desktop"
            case .windowsApp: "Windows App"
            case .anyDesk: "AnyDesk"
            case .teamViewer: "TeamViewer"
            case .rustDesk: "RustDesk"
            }
        }
        /// Typed into in a terminal, rather than watched as a screen.
        public var terminal: Bool { self == .ssh || self == .mosh }
    }

    /// Why typing lagged or the screen froze. The call report's causes, said for a session, plus two of the host's own.
    public struct Cause: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable {
            case app, otherDevice, wifi, airDrop, starlink, beyondRouter
            /// The Wi-Fi's sign-in page logged the Mac out: nothing past the router answered until it signed in again.
            case portal
            /// The internet answered fine but the host didn't: the delay was on the way to it, past the provider.
            case remotePath
            /// Input went unanswered while the host answered pings promptly: the server itself was slow.
            case remoteSlow
        }
        public let kind: Kind
        public var app: String? = nil
        public var uploading: Bool? = nil
        public var weakSignal: Bool? = nil
        public var dish: String? = nil
        public var device: String? = nil
        /// The device is a paired Mac running Kilobat that reported what it moved at the time, for `otherDevice`.
        public var kilobat: Bool? = nil
        /// That Mac's busiest app at the time: "Steam".
        public var deviceApp: String? = nil
        /// Named from the paired Mac's report alone, without the router's counters; a service outage outranks it.
        public var unconfirmed: Bool? = nil
        public init(kind: Kind, app: String? = nil, uploading: Bool? = nil, weakSignal: Bool? = nil, dish: String? = nil, device: String? = nil,
                    kilobat: Bool? = nil, deviceApp: String? = nil, unconfirmed: Bool? = nil) {
            self.kind = kind; self.app = app; self.uploading = uploading; self.weakSignal = weakSignal; self.dish = dish; self.device = device
            self.kilobat = kilobat; self.deviceApp = deviceApp; self.unconfirmed = unconfirmed
        }
        init(_ call: CallReport.Cause) {
            let kind: Kind = switch call.kind {
            case .app: .app
            case .otherDevice: .otherDevice
            case .wifi: .wifi
            case .airDrop: .airDrop
            case .starlink: .starlink
            case .beyondRouter: .beyondRouter
            case .portal: .portal
            }
            self.init(kind: kind, app: call.app, uploading: call.uploading, weakSignal: call.weakSignal, dish: call.dish, device: call.device,
                      kilobat: call.kilobat, deviceApp: call.deviceApp, unconfirmed: call.unconfirmed)
        }
        /// A delay on the line rather than something on this Mac or the server: what Mosh rides out.
        var unstable: Bool { [.wifi, .airDrop, .starlink, .beyondRouter, .remotePath].contains(kind) }

        /// Reads on from "Typing lagged 4 times:" — "jitter on your Wi-Fi or router".
        public func phrase(host: String) -> String {
            switch kind {
            case .app: uploading == true ? String(localized: "your upload was saturated by \(app ?? "another app")", comment: "Remote session report: why typing lagged or the screen froze; the argument is an app")
                                         : String(localized: "your download was saturated by \(app ?? "another app")", comment: "Remote session report: why typing lagged or the screen froze; the argument is an app")
            case .otherDevice:
                if let device, let deviceApp {
                    uploading == true ? String(localized: "\(device) was uploading on your network (\(deviceApp))", comment: "Remote session report: a paired Mac was uploading; the arguments are its name and busiest app, such as “Anna’s MacBook” and “Dropbox”")
                                      : String(localized: "\(device) was downloading on your network (\(deviceApp))", comment: "Remote session report: a paired Mac was downloading; the arguments are its name and busiest app, such as “Anna’s MacBook” and “Steam”")
                } else if let device {
                    uploading == true ? String(localized: "\(device) was uploading on your network", comment: "Remote session report; the argument is a device's name, such as “Rita’s iPad”")
                                      : String(localized: "\(device) was downloading on your network", comment: "Remote session report; the argument is a device's name, such as “Rita’s iPad”")
                } else {
                    uploading == true ? String(localized: "another device on your network was uploading", comment: "Remote session report: a TV, phone or console on the same network")
                                      : String(localized: "another device on your network was downloading", comment: "Remote session report: a TV, phone or console on the same network")
                }
            case .wifi: weakSignal == true ? String(localized: "weak Wi-Fi", comment: "Remote session report: why typing lagged")
                                           : String(localized: "jitter on your Wi-Fi or router", comment: "Remote session report: why typing lagged")
            case .airDrop: String(localized: "AirDrop scanning on your Wi-Fi", comment: "Remote session report: AirDrop's radio hopping channels")
            case .portal: String(localized: "the Wi-Fi’s sign-in page logged you out", comment: "Remote session report: a hotel or café Wi-Fi's sign-in ran out")
            case .starlink:
                switch dish {
                case "obstructed": String(localized: "something blocked the Starlink dish’s view of the sky", comment: "Remote session report")
                case "noSatellites": String(localized: "no Starlink satellite was in view", comment: "Remote session report")
                case "reboot": String(localized: "the Starlink dish restarted", comment: "Remote session report")
                default: String(localized: "the Starlink dish was offline", comment: "Remote session report")
                }
            case .beyondRouter: String(localized: "delay beyond your router, at your provider or further", comment: "Remote session report: where the lag came from")
            case .remotePath: String(localized: "delay on the way to \(host), past your provider", comment: "Remote session report; the argument is a server such as build.example.com")
            case .remoteSlow: String(localized: "\(host) was slow to answer, but your line was fine", comment: "Remote session report; the argument is a server such as build.example.com")
            }
        }

        /// What to try before the next session.
        public func advice(host: String) -> String {
            switch kind {
            case .app: String(localized: "Pause \(app ?? "that app") while you work on \(host), or block it with a profile.", comment: "Remote session advice; the arguments are an app and a server")
            case .otherDevice where kilobat == true && device != nil:
                deviceApp.map { String(localized: "\(device ?? "") was busy with \($0) at the time, as Kilobat on that Mac reported. Pause it there while you work remotely.", comment: "Remote session advice; a paired Mac's name and an app, such as “Anna’s MacBook” and “Steam”") }
                ?? String(localized: "\(device ?? "") was busy at the time, as Kilobat on that Mac reported. Pause its downloads or uploads while you work remotely.", comment: "Remote session advice; a paired Mac's name")
            case .otherDevice: device.map { String(localized: "\($0) joined your network just before, while your router saw another device busy. Pause its downloads or streams, or turn on your router’s QoS.", comment: "Remote session advice; the argument is a device's name") }
                ?? String(localized: "A TV, console or phone on your network was busy. Pause its download or stream, or turn on your router’s QoS.", comment: "Remote session advice")
            case .wifi: weakSignal == true ? String(localized: "Move closer to the router, or use Radar to find a stronger spot.", comment: "Remote session advice")
                                           : String(localized: "Try a cable or the 5 GHz band, or restart the router.", comment: "Remote session advice")
            case .airDrop: String(localized: "Turn on low latency while you work remotely; it pauses AirDrop until you turn it off.", comment: "Remote session advice")
            case .portal: String(localized: "Sign in again on the Wi-Fi’s page. Once Kilobat has seen how long sign-ins last here, it warns you five minutes before the next one runs out.", comment: "Remote session advice after a hotel or café Wi-Fi's sign-in ran out")
            case .starlink: CallSamples.Dish.advice(dish)
            case .beyondRouter: String(localized: "If it keeps happening, the report for your provider shows it over time.", comment: "Remote session advice")
            case .remotePath: String(localized: "Your own line was fine; the delay was near \(host) or on its network. A server or region closer to you would help.", comment: "Remote session advice; the argument is a server")
            case .remoteSlow: String(localized: "Check what \(host) was busy with (uptime, top): it answered pings at once but kept your input waiting.", comment: "Remote session advice; the argument is a server")
            }
        }
    }

    public struct Lag: Codable, Sendable, Equatable {
        /// Seconds from the start of the session.
        public let at: Double
        public let seconds: Double
        /// The worst round trip in ms; nil when every ping was lost, or for a slow server, which answered pings fine.
        public let peak: Double?
        public let cause: Cause
    }

    /// What the lag line measured: the host itself, or the internet when the host doesn't answer ping.
    public enum Measured: String, Codable, Sendable { case host, internet }

    public var id = UUID()
    public let kind: Kind
    /// The host as typed (build.example.com), or the address when nothing better is known.
    public let host: String?
    public let address: String?
    public let port: String?
    public let start: Date
    public let end: Date
    public let networkKey: String?
    public let networkName: String?
    public let measured: Measured
    /// Round trip on the measured line.
    public let median: Double?
    public let jitter: Double?
    public let lossPercent: Double
    /// The fastest and slowest replies: how far the round trip swung.
    public let low: Double?
    public let peak: Double?
    /// The host's usual round trip: its ping, or the connection's own TCP round trip when it ignores ping.
    public let base: Double?
    public let lags: [Lag]
    public let strain: [CallReport.Strain]
    public var household: Bool? = nil
    /// The measured round trip, at most 240 points, each the worst of its stretch.
    public let line: [Double?]
    /// What the remote service's status page said, when the session lagged past the router and Kilobat knows its page.
    public var service: ServiceStatus? = nil

    /// Base round trip from which every keystroke feels late, even on a clean line.
    public static let farAway = 150.0

    public var seconds: Double { end.timeIntervalSince(start) }
    /// The host, the address, or a plain stand-in.
    public var place: String { host ?? address ?? (kind.terminal ? String(localized: "the server", comment: "Remote session report: stands in for an unknown host") : String(localized: "the remote computer", comment: "Remote session report: stands in for an unknown host")) }
    public var far: Bool { (base ?? 0) >= Self.farAway }
    public var clean: Bool { lags.isEmpty && strain.isEmpty && !far }
    public var title: String { String(localized: "\(kind.name) to \(place)", comment: "Remote session report title, such as “SSH to build.example.com”") }

    /// The lags' causes, most frequent first.
    public var causes: [(cause: Cause, count: Int)] {
        var order: [Cause] = [], counts: [Cause: Int] = [:]
        for lag in lags { if counts[lag.cause] == nil { order.append(lag.cause) }; counts[lag.cause, default: 0] += 1 }
        return order.map { ($0, counts[$0]!) }.sorted { $0.count > $1.count }
    }

    /// "Typing lagged 4 times", "Screen froze twice", "No lag" — without the cause, for Kilobat without Pro.
    public var count: String {
        let n = lags.count
        if n == 0 {
            if far, let base { return String(localized: "Every keystroke waited \(Int(base.rounded())) ms", comment: "Remote session report: the server's base round trip") }
            if !strain.isEmpty { return String(localized: "Mac overloaded", comment: "Remote session report: the line was fine but the Mac struggled") }
            return kind.terminal ? String(localized: "No lag", comment: "Remote session report: typing never lagged") : String(localized: "No freezes", comment: "Remote session report: the screen never froze")
        }
        if kind.terminal {
            return n == 1 ? String(localized: "Typing lagged once", comment: "Remote session report") : n == 2 ? String(localized: "Typing lagged twice", comment: "Remote session report")
                : String(localized: "Typing lagged \(n) times", comment: "Remote session report; the argument is a count over 2")
        }
        return n == 1 ? String(localized: "Screen froze once", comment: "Remote session report") : n == 2 ? String(localized: "Screen froze twice", comment: "Remote session report")
            : String(localized: "Screen froze \(n) times", comment: "Remote session report; the argument is a count over 2")
    }

    /// "RTT to build.example.com swung 40→600 ms", when it swung far enough to feel.
    public var swing: String? {
        guard let low, let peak, peak - low >= 150 else { return nil }
        return measured == .host ? String(localized: "RTT to \(place) swung \(Int(low.rounded()))→\(Int(peak.rounded())) ms", comment: "Remote session report; a server, then the lowest and highest round trip")
                                 : String(localized: "RTT to the internet swung \(Int(low.rounded()))→\(Int(peak.rounded())) ms", comment: "Remote session report; the lowest and highest round trip")
    }

    /// One line: "Typing lagged 4 times: jitter on your Wi-Fi or router (RTT to build.example.com swung 40→600 ms)".
    public var verdict: String {
        let causes = causes
        guard let first = causes.first else {
            if far, let base { return String(localized: "Every keystroke waited about \(Int(base.rounded())) ms: \(place) is far away", comment: "Remote session report verdict; a round trip and a server") }
            if !strain.isEmpty { return String(localized: "No network lag, but the Mac was overloaded", comment: "Remote session report verdict") }
            return count
        }
        if causes.count == 1 {
            let line = String(localized: "\(count): \(first.cause.phrase(host: place))", comment: "Remote session report verdict: how often it lagged, then why")
            guard first.cause.unstable, let swing else { return line }
            return line + " (\(swing))"
        }
        let parts = causes.prefix(2).map { "\($0.cause.phrase(host: place)) (\($0.count))" }
        return String(localized: "\(count): \(parts.formatted(.list(type: .and)))", comment: "Remote session report verdict with mixed causes; each part ends with its count in brackets")
    }

    /// What to try first: for the most frequent cause, the distance, or the Mac.
    public var advice: String? {
        if let first = causes.first?.cause {
            // The service's own page owned up to it: there's nothing to fix on this side.
            if [.beyondRouter, .remotePath].contains(first.kind), let service, service.outage {
                return String(localized: "That was \(service.service)’s own trouble, not your line, so there’s nothing to change here.", comment: "Remote session advice when the service's status page reported an outage; the argument is a service such as Tailscale")
            }
            if first.kind == .beyondRouter, household != true {
                return String(localized: "If others share this network, a TV or console may be the cause; Kilobat sees other devices only when your router shares its traffic counters (UPnP).", comment: "Remote session advice")
            }
            return first.advice(host: place)
        }
        if far { return String(localized: "\(place) is far from you, so every keystroke makes the round trip. A server or region closer to you would help.", comment: "Remote session advice; the argument is a server") }
        return strain.first.map { $0.sessionAdvice(terminal: kind.terminal) }
    }

    /// SSH on a line that jitters, drops packets or is far away: Mosh echoes typing at once and survives all three.
    /// Not when the lag was an app, another device, the Mac or the server, where Mosh would only hide the cause.
    public var suggestsMosh: Bool {
        guard kind == .ssh else { return false }
        if let first = causes.first?.cause { return first.unstable && service?.outage != true }
        return far || (jitter ?? 0) >= 30 || lossPercent >= 2
    }
    public var mosh: String? {
        suggestsMosh ? String(localized: "Try Mosh for this server: it echoes your typing at once and rides out jitter, lost packets and Wi-Fi changes. Install it on both ends (brew install mosh), then run mosh \(host ?? "your-server").", comment: "Remote session advice; the argument is a server") : nil
    }

    public var macDetail: String? { strain.isEmpty ? nil : strain.prefix(2).map(\.sentence).joined(separator: " ") }

    /// Worth asking the service's status page: it lagged past the router, or only a paired Mac's own report was blamed.
    public var needsStatusCheck: Bool { lags.contains { [.beyondRouter, .remotePath].contains($0.cause.kind) || $0.cause.unconfirmed == true } }

    /// The report as the CLI and MCP give it: the stored fields plus the sentences and whether Mosh would help.
    public struct Exported: Encodable, Sendable {
        public let report: RemoteSessionReport
        public init(_ report: RemoteSessionReport) { self.report = report }
        private enum Keys: String, CodingKey { case title, verdict, advice, mosh, suggestsMosh, far, clean }
        public func encode(to encoder: Encoder) throws {
            try report.encode(to: encoder)
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(report.title, forKey: .title)
            try container.encode(report.verdict, forKey: .verdict)
            try container.encodeIfPresent(report.advice, forKey: .advice)
            try container.encodeIfPresent(report.mosh, forKey: .mosh)
            try container.encode(report.suggestsMosh, forKey: .suggestsMosh)
            try container.encode(report.far, forKey: .far)
            try container.encode(report.clean, forKey: .clean)
        }
    }
}

extension CallReport.Strain {
    /// The call's advice, said for a session.
    func sessionAdvice(terminal: Bool) -> String {
        switch kind {
        case .cpu: top.map { String(localized: "Quit \($0) or other heavy apps while you work remotely.", comment: "Remote session advice; the argument is a process") }
            ?? String(localized: "Quit heavy apps while you work remotely.", comment: "Remote session advice")
        case .memory: String(localized: "Quit apps and close browser tabs you don’t need.", comment: "Remote session advice")
        case .thermal: String(localized: "Keep the Mac on a hard surface and out of the sun, with fewer heavy apps open.", comment: "Remote session advice")
        case .gpu: terminal ? String(localized: "Quit apps drawing heavy graphics while you work remotely.", comment: "Remote session advice")
                            : String(localized: "Lower the remote screen’s resolution or frame rate.", comment: "Remote session advice")
        }
    }
}

/// What a session's lags are measured from: the call engine's samples, a ping a second to the host, the connection's
/// own TCP round trip every few seconds, and what the session's process moved each second.
public struct RemoteSamples: Sendable {
    public var line = CallSamples()
    /// ICMP to the host, once a second.
    public var remote: [CallSamples.Ping] = []
    /// The session's TCP round trip as macOS measures it, every few seconds; empty for UDP.
    public var connection: [CallSamples.Ping] = []
    public var seconds: [RemoteSessionDetector.Second] = []
    public init() {}
}

public enum RemoteAnalysis {
    /// The status pages a session can be checked against: the host's service (a Tailscale or GitHub host, say), and for
    /// a viewer its own app's.
    public static func services(host: String?, app: String?) -> [StatusService] {
        var found = host.map(ServiceCatalog.services(forHost:)) ?? []
        for service in app.map(ServiceCatalog.services(forApp:)) ?? [] where !found.contains(service) { found.append(service) }
        return found
    }

    /// A round trip this much over the median, or lost, is a bad second; two in a row is a lag you feel while typing.
    static let spike = 150.0
    /// Input left unanswered this long is a stall.
    static let unanswered = 2.0
    /// A slow server is claimed only when it happened at least this often, each time with the line to it fine.
    static let slowStalls = 2
    /// A lag counts for a terminal when input was sent this close to it.
    static let typingWindow = 15.0

    public static func report(kind: RemoteSessionReport.Kind, host: String?, address: String?, port: String?, start: Date, end: Date,
                              network: (key: String, name: String)?, samples all: RemoteSamples) -> RemoteSessionReport {
        // A session that went quiet ends at its last input; what was measured after is left out.
        let limit = end.timeIntervalSince(start)
        var samples = all
        samples.remote = all.remote.filter { $0.at < limit }
        samples.connection = all.connection.filter { $0.at < limit }
        samples.seconds = all.seconds.filter { $0.at < limit }
        samples.line.internet = all.line.internet.filter { $0.at < limit }
        samples.line.router = all.line.router.filter { $0.at < limit }
        samples.line.load = all.line.load.filter { $0.at < limit }
        let answered = samples.remote.filter { $0.ms != nil }.count
        let measured: RemoteSessionReport.Measured = samples.remote.count >= 10 && answered * 2 >= samples.remote.count ? .host : .internet
        let pings = measured == .host ? samples.remote : samples.line.internet
        let replies = pings.compactMap(\.ms)
        let median = StutterTest.percentile(replies.sorted(), 50)
        let loss = pings.isEmpty ? 0 : Double(pings.count - replies.count) / Double(pings.count) * 100
        var lags = CallAnalysis.runs(pings, median: median, spike: spike).map { run -> RemoteSessionReport.Lag in
            let from = run.first!.at, to = run.last!.at
            var cause = RemoteSessionReport.Cause(CallAnalysis.cause(from: from, to: to, samples: samples.line))
            if cause.kind == .beyondRouter, measured == .host, internetFine(from: from, to: to, samples.line.internet) { cause = .init(kind: .remotePath) }
            return .init(at: from, seconds: to - from + 1, peak: run.compactMap(\.ms).max(), cause: cause)
        }
        // Typing lagged only if someone was typing: a lag while the terminal sat unread isn't one.
        let inputs = samples.seconds.filter(\.input).map(\.at)
        if kind.terminal, !inputs.isEmpty {
            lags = lags.filter { lag in inputs.contains { $0 >= lag.at - typingWindow && $0 <= lag.at + lag.seconds + typingWindow } }
        }
        if kind == .ssh {
            let slow = stalls(samples.seconds).filter { stall in
                !lags.contains { $0.at <= stall.to + 1 && $0.at + $0.seconds >= stall.from - 1 } && serverSlow(from: stall.from, to: stall.to, samples: samples)
            }
            if slow.count >= slowStalls {
                lags += slow.map { .init(at: $0.from, seconds: $0.to - $0.from, peak: nil, cause: .init(kind: .remoteSlow)) }
                lags.sort { $0.at < $1.at }
            }
        }
        let connection = samples.connection.compactMap(\.ms)
        let base = measured == .host ? median : connection.count >= 3 ? connection.min() : nil
        var card = RemoteSessionReport(kind: kind, host: host, address: address, port: port, start: start, end: end, networkKey: network?.key, networkName: network?.name,
                                       measured: measured, median: median, jitter: CallAnalysis.jitter(replies), lossPercent: loss,
                                       low: replies.min(), peak: replies.max(), base: base, lags: lags, strain: CallAnalysis.strain(samples.line.load),
                                       line: CallAnalysis.line(pings, points: 240))
        card.household = samples.line.household != nil
        return card
    }

    /// The internet answered every ping on time around this moment, so a delay to the host was further along.
    static func internetFine(from start: Double, to end: Double, _ internet: [CallSamples.Ping]) -> Bool {
        let median = StutterTest.percentile(internet.compactMap(\.ms).sorted(), 50) ?? 0
        let near = internet.filter { $0.at >= start - 1 && $0.at <= end + 1 }
        return !near.isEmpty && near.allSatisfy { $0.ms.map { $0 <= median + 100 } ?? false }
    }

    /// Input sent in two or more seconds while nothing came back for at least two, then a reply: typing that waited.
    /// A command that runs quietly after Enter isn't one, since nothing more was typed while it ran.
    static func stalls(_ seconds: [RemoteSessionDetector.Second]) -> [(from: Double, to: Double)] {
        let ordered = seconds.sorted { $0.at < $1.at }
        var result: [(from: Double, to: Double)] = [], quiet: [RemoteSessionDetector.Second] = []
        for second in ordered {
            if second.down == 0 { quiet.append(second); continue }
            let typed = quiet.filter { $0.up > 0 }
            if typed.count >= 2, let first = typed.first, let last = quiet.last, last.at + 1 - first.at >= unanswered {
                result.append((first.at, last.at + 1))
            }
            quiet = []
        }
        return result
    }

    /// The server kept input waiting while the line to it was fine: its ping (or, when it ignores ping, the connection's
    /// own TCP round trip) answered on time and the router did too. Without a measurement in the stall, nothing is claimed.
    static func serverSlow(from start: Double, to end: Double, samples: RemoteSamples) -> Bool {
        let routerMedian = StutterTest.percentile(samples.line.router.compactMap(\.ms).sorted(), 50) ?? 0
        let router = samples.line.router.filter { $0.at >= start && $0.at <= end }
        guard router.allSatisfy({ $0.ms.map { $0 <= routerMedian + 100 } ?? false }) else { return false }
        let remoteReplies = samples.remote.compactMap(\.ms)
        if !remoteReplies.isEmpty {
            let median = StutterTest.percentile(remoteReplies.sorted(), 50) ?? 0
            let near = samples.remote.filter { $0.at >= start && $0.at <= end }
            return !near.isEmpty && near.allSatisfy { $0.ms.map { $0 <= median + 50 } ?? false }
        }
        let connection = samples.connection.compactMap(\.ms)
        guard let floor = connection.min() else { return false }
        let near = samples.connection.filter { $0.at >= start - 3 && $0.at <= end + 3 }
        return !near.isEmpty && near.allSatisfy { $0.ms.map { $0 <= floor + 50 } ?? false }
    }
}
