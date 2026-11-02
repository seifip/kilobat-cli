import Foundation

/// The cloud gaming services Kilobat recognises, and what it can see of each from the Mac: a Mac app by its name, or a
/// browser tab by the hosts the browser talks to while a heavy, one-way UDP stream (WebRTC) comes in. Kilobat never sees
/// the video, the game or the account; only which process moves how many bytes to which address.
public struct CloudGamingService: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// The Mac app's name, lowercased with only letters and digits; a process or app whose name starts with one is it.
    /// Empty for services played only in a browser.
    let apps: [String]
    /// A name that must match exactly rather than as a prefix ("shadow" alone, so Shadowsocks never counts).
    let exact: [String]
    /// Bundle-ID prefixes, where known.
    let bundles: [String]
    /// Hosts a browser connects to while it plays the service, matched as the host itself or a subdomain of it.
    let hosts: [String]

    public var browserOnly: Bool { apps.isEmpty && exact.isEmpty }

    /// Every service, in the order the app lists them. Hosts marked official are in the service's own pages; the rest
    /// are service domains used as conservative signals. Their media sockets may use other hosts.
    public static let all: [CloudGamingService] = [
        // play.geforcenow.com is the browser client NVIDIA documents; nvidiagrid.net carries its session setup (CloudMatch).
        .init(id: "geforcenow", name: "GeForce NOW", apps: ["geforcenow"], exact: [], bundles: ["com.nvidia.gfnpc"],
              hosts: ["play.geforcenow.com", "nvidiagrid.net"]),
        // Xbox documents no streaming host; its web client's sessions run through the gssv-play hosts under xboxlive.com.
        .init(id: "xbox", name: "Xbox Cloud Gaming", apps: [], exact: [], bundles: [],
              hosts: ["gssv-play-prod.xboxlive.com", "gssv-play-prodxhome.xboxlive.com"]),
        // cloud.boosteroid.com is the browser client Boosteroid documents.
        .init(id: "boosteroid", name: "Boosteroid", apps: ["boosteroid"], exact: [], bundles: ["com.boosteroid"],
              hosts: ["cloud.boosteroid.com"]),
        // Luna launches at luna.amazon.com; country domains can also serve its browser client.
        .init(id: "luna", name: "Amazon Luna", apps: [], exact: [], bundles: [],
              hosts: []),
        // Shadow PC: a Mac app, or pc.shadow.tech in a Chromium browser.
        .init(id: "shadow", name: "Shadow PC", apps: ["shadowpc"], exact: ["shadow"], bundles: ["com.shadow."],
              hosts: ["pc.shadow.tech"]),
    ]
    public static func service(_ id: String) -> CloudGamingService? { all.first { $0.id == id } }

    static func normalized(_ name: String) -> String { name.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// The service whose Mac app this is, by bundle ID, app or process name, or the .app it lives in.
    public static func app(id: String, name: String, path: String? = nil) -> CloudGamingService? {
        let bundle = id.hasPrefix("process:") ? nil : id.lowercased()
        // AppTraffic can give us an executable inside the bundle, rather than the bundle URL itself.
        let appName = path.flatMap { URL(fileURLWithPath: $0).pathComponents.first { $0.lowercased().hasSuffix(".app") } }
            .map { String($0.dropLast(4)) } ?? ""
        let names = [name, id.hasPrefix("process:") ? String(id.dropFirst(8)) : "", appName]
            .map(normalized).filter { !$0.isEmpty }
        return all.first { service in
            if let bundle, service.bundles.contains(where: { bundle.hasPrefix($0.lowercased()) }) { return true }
            return names.contains { candidate in service.apps.contains { candidate.hasPrefix($0) } || service.exact.contains(candidate) }
        }
    }

    /// The browser an app row belongs to (its helpers and WebKit's networking process included), by CallDetector's table.
    public static func browser(id: String, path: String? = nil) -> String? {
        if let entry = CallDetector.apps.first(where: { $0.browser && $0.prefixes.contains { id.hasPrefix($0) } }) { return entry.name }
        // GeForce NOW names Opera GX among its browsers on macOS.
        if id.hasPrefix("com.operasoftware.OperaGX") { return "Opera GX" }
        if id.hasPrefix("com.operasoftware.Opera") { return "Opera" }
        guard let path else { return nil }
        let names: [(String, String)] = [("Google Chrome.app", "Chrome"), ("Microsoft Edge.app", "Edge"), ("Arc.app", "Arc"), ("Dia.app", "Dia"),
                                         ("Firefox.app", "Firefox"), ("Brave Browser.app", "Brave"), ("Safari.app", "Safari"), ("Opera GX.app", "Opera GX"), ("Opera.app", "Opera")]
        return names.first { path.hasSuffix("/" + $0.0) || path.contains("/" + $0.0 + "/") }?.1
    }

    /// Whether a browser talking to `host` is playing this service.
    public func matches(host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        switch id {
        case "xbox":
            return host.hasSuffix(".xboxlive.com") && host.split(separator: ".").contains { $0.hasPrefix("gssv-play") }
        case "luna":
            // Amazon's country hosts are under its own registrable domains. A substring check would also
            // accept luna.amazon.com.evil.example and name an unrelated browser stream as a Luna game.
            let amazonDomains = ["amazon.com", "amazon.co.uk", "amazon.ca", "amazon.de", "amazon.fr", "amazon.it",
                                 "amazon.es", "amazon.nl", "amazon.pl", "amazon.se", "amazon.pt", "amazon.be",
                                 "amazon.lu", "amazon.at"]
            return amazonDomains.contains { host == "luna.\($0)" || host.hasSuffix(".luna.\($0)") }
        default:
            return false
        }
    }

    /// The service any of these hosts belongs to, the most specific match first: a streaming host over a site's front page.
    public static func service(hosts: [String]) -> CloudGamingService? {
        for service in all where hosts.contains(where: service.matches) { return service }
        return nil
    }
}

/// The streams coming into each cloud gaming client, from nettop's per-connection rows once a second: a Mac app's own
/// UDP (and non-web TCP) traffic, or a browser's UDP that isn't QUIC on port 443. Ordinary video plays over TCP or QUIC
/// on 443 and ordinarily does not count; most calls fail the one-way test. A busy tab in a browser can still affect the estimate.
public struct CloudGamingFlows: Sendable {
    public enum Client: Hashable, Sendable {
        /// A cloud gaming service's Mac app, by service id.
        case app(String)
        /// A browser, by name; which service it plays is decided from its hosts.
        case browser(String)
    }
    /// One second of a client's stream, in bytes a second.
    public struct Second: Sendable, Equatable {
        public let at: Date
        public let down: Double
        public let up: Double
        /// The remote address of its busiest labelled flow; nil when the socket names no address (`*:*`).
        public let server: String?
        public init(at: Date, down: Double, up: Double, server: String?) { self.at = at; self.down = down; self.up = up; self.server = server }
    }
    /// A client that streams like a cloud game right now.
    public struct Media: Sendable, Equatable {
        public let client: Client
        public let down: Double
        public let up: Double
        public let server: String?
    }

    /// A stream starts when, in the last ten seconds, eight carried 2 Mbps or more, they averaged 3 Mbps, and four times
    /// as much came in as went out. GeForce NOW, Xbox, Boosteroid, Luna and Shadow all ask for 10 Mbps or more.
    public static let window = 10, enough = 8
    public static let activeRate = 250_000.0, startRate = 375_000.0, ratio = 4.0
    /// A second under 1 Mbps is the stream paused or gone; twenty in a row end the session.
    public static let aliveRate = 125_000.0
    public static let quietSeconds: TimeInterval = 20

    /// Ports that never carry a game stream: DNS, web and QUIC, time, discovery.
    static let ignoredPorts: Set<String> = ["53", "80", "443", "123", "5353", "1900"]

    struct Flow { var received: UInt64; var sent: UInt64; var seen: Date }
    var flows: [String: Flow] = [:]
    public private(set) var history: [Client: [Second]] = [:]
    public private(set) var lastActive: [Client: Date] = [:]
    var last: Date?
    public init() {}

    /// Whether a connection row can carry a client's stream. `id` is nettop's `udp4 192.168.1.20:5000<->203.0.113.7:49004`.
    static func counts(_ connection: ConnectionTraffic, browser: Bool) -> (count: Bool, remote: String?) {
        guard connection.route != .local else { return (false, nil) }
        let udp = connection.id.hasPrefix("udp"), tcp = connection.id.hasPrefix("tcp")
        let endpoint = ServiceFlowTracker.endpoint(connection.id)
        if let port = endpoint?.port, ignoredPorts.contains(port) { return (false, nil) }
        if browser { return (udp, endpoint?.address) }
        // A Mac app streams over UDP, or TCP away from the web ports (Shadow's "Prefer reliability" mode).
        return (udp || (tcp && endpoint != nil), endpoint?.address)
    }

    /// One nettop sample. `client` says which client a process belongs to. Returns each client's second.
    @discardableResult
    public mutating func ingest(_ snapshot: TrafficSnapshot, client: (ProcessTraffic) -> Client?) -> [Client: Second] {
        let now = snapshot.timestamp
        defer { last = now }
        guard let previous = last, now > previous, now.timeIntervalSince(previous) <= 5 else {
            // The first sample, or one after sleep: only a baseline.
            flows = [:]; history = [:]
            for process in snapshot.processes where client(process) != nil {
                for connection in process.connections { flows["\(process.pid)|\(connection.id)"] = Flow(received: connection.received, sent: connection.sent, seen: now) }
            }
            return [:]
        }
        let elapsed = now.timeIntervalSince(previous)
        var totals: [Client: (down: UInt64, up: UInt64, server: String?, best: UInt64)] = [:]
        for process in snapshot.processes {
            guard let owner = client(process) else { continue }
            var entry = totals[owner] ?? (0, 0, nil, 0)
            for connection in process.connections {
                let key = "\(process.pid)|\(connection.id)"
                let before = flows[key]
                flows[key] = Flow(received: connection.received, sent: connection.sent, seen: now)
                let (count, remote) = Self.counts(connection, browser: { if case .browser = owner { true } else { false } }())
                guard count else { continue }
                // A flow first seen now opened since the last sample: all its bytes are new.
                let down = before.map { connection.received >= $0.received ? connection.received - $0.received : connection.received } ?? connection.received
                let up = before.map { connection.sent >= $0.sent ? connection.sent - $0.sent : connection.sent } ?? connection.sent
                entry.down += down; entry.up += up
                if let remote, down > entry.best { entry.best = down; entry.server = remote }
            }
            totals[owner] = entry
        }
        // A flow gone for a minute is closed; one that comes back within it keeps its baseline.
        flows = flows.filter { now.timeIntervalSince($0.value.seen) < 60 }
        var seconds: [Client: Second] = [:]
        for (owner, total) in totals {
            let second = Second(at: now, down: Double(total.down) / elapsed, up: Double(total.up) / elapsed, server: total.server)
            seconds[owner] = second
            history[owner, default: []].append(second)
            if history[owner]!.count > 30 { history[owner]!.removeFirst(history[owner]!.count - 30) }
            if second.down >= Self.aliveRate { lastActive[owner] = now }
        }
        // A client that stopped running has no rows: its history ends.
        for owner in history.keys where totals[owner] == nil { history[owner] = nil }
        lastActive = lastActive.filter { now.timeIntervalSince($0.value) < 3600 }
        return seconds
    }

    /// Clients streaming like a cloud game now, the heaviest first.
    public var media: [Media] {
        history.compactMap { client, seconds in Self.media(client, seconds) }.sorted { $0.down > $1.down }
    }

    static func media(_ client: Client, _ seconds: [Second]) -> Media? {
        let recent = seconds.suffix(window)
        guard recent.count >= enough else { return nil }
        let down = recent.reduce(0) { $0 + $1.down } / Double(recent.count), up = recent.reduce(0) { $0 + $1.up } / Double(recent.count)
        guard recent.filter({ $0.down >= activeRate }).count >= enough, down >= startRate, down >= ratio * up else { return nil }
        let server = recent.reversed().compactMap(\.server).first
        return Media(client: client, down: down, up: up, server: server)
    }

    /// Whether a client's stream has carried nothing for `quietSeconds`, or the client is gone.
    public func ended(_ client: Client, now: Date) -> Bool {
        guard let active = lastActive[client] else { return true }
        return now.timeIntervalSince(active) >= Self.quietSeconds
    }
    public func lastActive(_ client: Client) -> Date? { lastActive[client] }
}

/// Something on the Mac that makes cloud games stutter, seen while one plays.
public struct CloudGamingIssue: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// AirDrop's link (AWDL) is busy: the Wi-Fi radio hops off channel to scan.
        case airDrop
        /// The Mac's Wi-Fi is on 2.4 GHz.
        case band24
        /// The Wi-Fi signal is weak.
        case weakSignal
        /// Another app or a macOS service is moving a lot.
        case app
    }
    public let kind: Kind
    public var app: String? = nil
    public var uploading: Bool? = nil
    /// Kilobat can pause it: a sync, backup or download app call mode knows. Apple's own services can't be.
    public var pausable: Bool? = nil
    public init(kind: Kind, app: String? = nil, uploading: Bool? = nil, pausable: Bool? = nil) {
        self.kind = kind; self.app = app; self.uploading = uploading; self.pausable = pausable
    }

    /// "AirDrop is scanning", "iCloud Photos is uploading".
    public var phrase: String {
        switch kind {
        case .airDrop: String(localized: "AirDrop is scanning", comment: "Cloud gaming: live culprit")
        case .band24: String(localized: "Wi-Fi is on 2.4 GHz", comment: "Cloud gaming: live culprit")
        case .weakSignal: String(localized: "The Wi-Fi signal is weak", comment: "Cloud gaming: live culprit")
        case .app: uploading == true ? String(localized: "\(app ?? "An app") is uploading", comment: "Cloud gaming: live culprit; the argument is an app such as iCloud Photos")
                                     : String(localized: "\(app ?? "An app") is downloading", comment: "Cloud gaming: live culprit; the argument is an app such as Steam")
        }
    }
    /// What to do about it now.
    public var advice: String {
        switch kind {
        case .airDrop: String(localized: "Pause AirDrop while you play: its scans make the stream stutter every few seconds.", comment: "Cloud gaming: live advice")
        case .band24: String(localized: "Join your router’s 5 GHz network or use Ethernet. Cloud gaming services ask for one or the other.", comment: "Cloud gaming: live advice")
        case .weakSignal: String(localized: "Move closer to the router, or use Ethernet.", comment: "Cloud gaming: live advice")
        case .app where pausable == true: String(localized: "Kilobat can pause \(app ?? "it") until you stop playing.", comment: "Cloud gaming: live advice; the argument is an app")
        case .app: CloudGamingNames.pauseAdvice(app)
        }
    }
}

/// Friendlier names for the macOS services that upload and download in the background, and how to pause them by hand.
public enum CloudGamingNames {
    static let services: [String: String] = [
        "cloudphotod": "iCloud Photos", "photolibraryd": "iCloud Photos", "bird": "iCloud Drive", "cloudd": "iCloud",
        "softwareupdated": "macOS Software Update", "appstored": "App Store", "storedownloadd": "App Store", "appstoreagent": "App Store",
        "backupd": "Time Machine", "mobileassetd": "macOS downloads", "nsurlsessiond": "Background downloads",
    ]
    /// The name to show for an app row: "iCloud Photos" for cloudphotod, else the name the traffic list uses.
    public static func name(id: String, name: String) -> String {
        let process = id.hasPrefix("process:") ? String(id.dropFirst(8)) : name
        return services[process] ?? services[name] ?? name
    }
    /// How to pause a service Kilobat won't suspend.
    static func pauseAdvice(_ app: String?) -> String {
        switch app {
        case "iCloud Photos": String(localized: "Pause iCloud Photos from the bottom of your Photos library while you play.", comment: "Cloud gaming advice")
        case "iCloud Drive", "iCloud": String(localized: "iCloud sync isn’t something Kilobat pauses. Let it finish, or play on Ethernet so it can’t crowd the Wi-Fi.", comment: "Cloud gaming advice")
        case "macOS Software Update", "App Store", "macOS downloads", "Background downloads":
            String(localized: "Let the update finish before you play, or turn on Pause updaters on metered networks in Kilobat.", comment: "Cloud gaming advice")
        case "Time Machine": String(localized: "Skip this Time Machine backup from its menu, or back up after you play.", comment: "Cloud gaming advice")
        default: String(localized: "Pause \(app ?? "that app") before you play.", comment: "Cloud gaming advice; the argument is an app")
        }
    }
}

/// One cloud gaming session as Kilobat saw it: which service, the stream's bitrate and data, the line, and each stretch
/// that stuttered with what was going on at the Mac then.
public struct CloudGamingReport: Codable, Identifiable, Sendable, Equatable {
    /// Something that was true during a stutter. A stutter can have several: "2.4 GHz Wi-Fi while iCloud Photos uploaded".
    public struct Factor: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable { case band24, weakSignal, airDrop, farNode, wifi, app, otherDevice, starlink, portal, beyondRouter }
        public let kind: Kind
        public var app: String? = nil
        public var uploading: Bool? = nil
        public var device: String? = nil
        /// What the Starlink dish logged, for `starlink`: obstructed, noSatellites, reboot or other.
        public var dish: String? = nil
        public init(kind: Kind, app: String? = nil, uploading: Bool? = nil, device: String? = nil, dish: String? = nil) {
            self.kind = kind; self.app = app; self.uploading = uploading; self.device = device; self.dish = dish
        }
        /// The Mac's own radio and Wi-Fi, as opposed to what was moving data.
        var local: Bool { [.band24, .weakSignal, .airDrop, .farNode, .wifi, .starlink, .portal].contains(kind) }

        /// "2.4 GHz Wi-Fi", "AirDrop scanning": a condition, for the start of a phrase.
        var condition: String {
            switch kind {
            case .band24: String(localized: "2.4 GHz Wi-Fi", comment: "Cloud gaming report: a condition during a stutter")
            case .weakSignal: String(localized: "weak Wi-Fi", comment: "Cloud gaming report: a condition during a stutter")
            case .airDrop: String(localized: "AirDrop scanning", comment: "Cloud gaming report: a condition during a stutter")
            case .farNode: String(localized: "a far mesh node", comment: "Cloud gaming report: the Mac stayed on a distant mesh Wi-Fi node")
            case .wifi: String(localized: "the Wi-Fi or router stalling", comment: "Cloud gaming report: a condition during a stutter")
            case .portal: String(localized: "the Wi-Fi’s sign-in page logging you out", comment: "Cloud gaming report: a hotel or café Wi-Fi's sign-in ran out")
            case .starlink:
                switch dish {
                case "obstructed": String(localized: "something blocking the Starlink dish’s view", comment: "Cloud gaming report")
                case "noSatellites": String(localized: "no Starlink satellite in view", comment: "Cloud gaming report")
                case "reboot": String(localized: "the Starlink dish restarting", comment: "Cloud gaming report")
                default: String(localized: "the Starlink dish dropping out", comment: "Cloud gaming report")
                }
            default: clause
            }
        }
        /// "iCloud Photos uploaded": what was moving, to follow "while".
        var clause: String {
            switch kind {
            case .app: uploading == true ? String(localized: "\(app ?? "another app") uploaded", comment: "Cloud gaming report: follows “while”; the argument is an app such as iCloud Photos")
                                         : String(localized: "\(app ?? "another app") downloaded", comment: "Cloud gaming report: follows “while”; the argument is an app such as Steam")
            case .otherDevice: device.map { String(localized: "\($0) was busy on your network", comment: "Cloud gaming report; the argument is a device such as “Rita’s iPad”") }
                ?? String(localized: "another device on your network was busy", comment: "Cloud gaming report")
            case .beyondRouter: String(localized: "beyond your router: your provider or the path to the game’s server", comment: "Cloud gaming report: where a stutter came from")
            default: condition
            }
        }

        /// What to try before the next session.
        public func advice(service: String) -> String {
            switch kind {
            case .band24: String(localized: "Join your router’s 5 GHz network or use Ethernet before you play: \(service) asks for one or the other.", comment: "Cloud gaming advice; the argument is a service such as GeForce NOW")
            case .weakSignal: String(localized: "Move closer to the router or use Ethernet; Radar finds the strongest spot.", comment: "Cloud gaming advice")
            case .airDrop: String(localized: "Pause AirDrop while you play: Kilobat does it in one click during a session, until the session ends.", comment: "Cloud gaming advice")
            case .farNode: String(localized: "Reconnect Wi-Fi before you play so the Mac moves to the closer mesh node.", comment: "Cloud gaming advice")
            case .wifi: String(localized: "Restart the router, or use Ethernet: Wi-Fi stalls freeze a stream however fast the plan is.", comment: "Cloud gaming advice")
            case .portal: String(localized: "Sign in again on the Wi-Fi’s page before you start a session.", comment: "Cloud gaming advice")
            case .starlink: CallSamples.Dish.advice(dish)
            case .app where app.map { CallMode.known.map(\.name).contains($0) } == true:
                String(localized: "Pause \(app ?? "that app") while you play: Kilobat holds it in one click during a session, until the session ends.", comment: "Cloud gaming advice; the argument is an app such as Dropbox")
            case .app: CloudGamingNames.pauseAdvice(app)
            case .otherDevice: String(localized: "Pause downloads and streams on other devices while you play, or give this Mac priority in your router’s QoS settings.", comment: "Cloud gaming advice")
            case .beyondRouter: String(localized: "Your line was fine at the Mac. If it keeps happening, pick a closer server region in \(service), or play at a quieter hour.", comment: "Cloud gaming advice; the argument is a service")
            }
        }
    }

    public struct Stutter: Codable, Sendable, Equatable {
        /// Seconds from the start of the session.
        public let at: Double
        public let seconds: Double
        /// The worst ping in it, in ms; nil when every ping was lost or the ping was steady.
        public let peak: Double?
        /// The stream's lowest bitrate in it, in Mbps.
        public let low: Double?
        public let factors: [Factor]
        public init(at: Double, seconds: Double, peak: Double?, low: Double?, factors: [Factor]) {
            self.at = at; self.seconds = seconds; self.peak = peak; self.low = low; self.factors = factors
        }

        /// "2.4 GHz Wi-Fi while iCloud Photos uploaded", "Dropbox was uploading", "beyond your router…".
        public var phrase: String { CloudGamingReport.phrase(factors) }
    }

    public var id = UUID()
    /// The service's id and name: geforcenow, xbox, boosteroid, luna, shadow.
    public let service: String
    public let name: String
    /// The browser it played in; nil for the service's Mac app.
    public let browser: String?
    public let start: Date
    public let end: Date
    public let networkKey: String?
    public let networkName: String?
    /// What the ping was measured to: the stream's server when it answered, else the internet (1.1.1.1).
    public let measured: Measured
    public enum Measured: String, Codable, Sendable { case server, internet }
    public let median: Double?
    public let jitter: Double?
    public let lossPercent: Double
    /// The stream's bitrate in Mbps: its average and its low (the 5th percentile second).
    public let averageMbps: Double?
    public let lowMbps: Double?
    /// Bytes the stream brought in.
    public let bytes: UInt64
    /// The network was metered: a hotspot, or marked so.
    public let metered: Bool
    public let stutters: [Stutter]
    public let strain: [CallReport.Strain]
    public var household: Bool? = nil
    /// The apps Kilobat held during the session, and whether it paused AirDrop.
    public var held: [String]? = nil
    public var airDropPaused: Bool? = nil
    /// The ping, at most 240 points, each the worst of its stretch.
    public let line: [Double?]
    /// The bitrate in Mbps, at most 240 points, each the lowest of its stretch.
    public let bitrate: [Double?]

    public var seconds: Double { end.timeIntervalSince(start) }
    public var clean: Bool { stutters.isEmpty }
    public var title: String {
        browser.map { String(localized: "\(name) in \($0)", comment: "Cloud gaming report title in a browser; the arguments are a service and a browser, such as “Xbox Cloud Gaming in Chrome”") } ?? name
    }
    /// Bytes an hour at the session's average.
    public var bytesPerHour: Double? { seconds >= 60 ? Double(bytes) / seconds * 3600 : nil }

    /// "Smooth session", "Stuttered once", "Stuttered 3 times": without the cause, for Kilobat without Pro.
    public var count: String {
        switch stutters.count {
        case 0: String(localized: "Smooth session", comment: "Cloud gaming report: no stutters")
        case 1: String(localized: "Stuttered once", comment: "Cloud gaming report")
        default: String(localized: "Stuttered \(stutters.count) times", comment: "Cloud gaming report; the argument is a count")
        }
    }

    /// "21:14".
    public func clock(_ stutter: Stutter) -> String { start.addingTimeInterval(stutter.at).formatted(date: .omitted, time: .shortened) }
    static func length(_ seconds: Double) -> String {
        seconds < 90 ? Duration.seconds(max(1, seconds.rounded())).formatted(.units(allowed: [.seconds], width: .narrow))
            : Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
    /// "Stuttered at 21:14 for 40 s: 2.4 GHz Wi-Fi while iCloud Photos uploaded".
    public func sentence(_ stutter: Stutter) -> String {
        String(localized: "Stuttered at \(clock(stutter)) for \(Self.length(stutter.seconds)): \(stutter.phrase)",
               comment: "Cloud gaming report: when, for how long, then why; such as “Stuttered at 21:14 for 40 s: 2.4 GHz Wi-Fi while iCloud Photos uploaded”")
    }

    /// The stutters' causes, most frequent first, ties by the longest.
    public var causes: [(phrase: String, factors: [Factor], count: Int)] {
        var order: [String] = [], counts: [String: (factors: [Factor], count: Int, seconds: Double)] = [:]
        for stutter in stutters {
            let key = stutter.phrase
            if counts[key] == nil { order.append(key) }
            let entry = counts[key] ?? (stutter.factors, 0, 0)
            counts[key] = (entry.factors, entry.count + 1, entry.seconds + stutter.seconds)
        }
        return order.map { ($0, counts[$0]!.factors, counts[$0]!.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : counts[$0.phrase]!.seconds > counts[$1.phrase]!.seconds }
    }

    /// One line: "Smooth session", "Stuttered at 21:14 for 40 s: …", "Stuttered 3 times: AirDrop scanning",
    /// "Stuttered 3 times: AirDrop scanning (2) and Dropbox was uploading (1)".
    public var verdict: String {
        let causes = causes
        guard let first = causes.first else { return count }
        if stutters.count == 1 { return sentence(stutters[0]) }
        if causes.count == 1 { return String(localized: "\(count): \(first.phrase)", comment: "Cloud gaming verdict: how many stutters, then why") }
        let parts = causes.prefix(2).map { "\($0.phrase) (\($0.count))" }
        return String(localized: "\(count): \(parts.formatted(.list(type: .and)))", comment: "Cloud gaming verdict with mixed causes; each part ends with its count in brackets")
    }

    /// What to try first, for the most frequent cause's leading factor.
    public var advice: String? {
        guard let first = causes.first?.factors.first else { return strain.first?.advice }
        if first.kind == .beyondRouter, household != true {
            return first.advice(service: name) + " " + String(localized: "If others share this network, a TV or console may be the cause; Kilobat sees other devices only when your router shares its traffic counters (UPnP).", comment: "Cloud gaming advice")
        }
        return first.advice(service: name)
    }

    /// "Used 9.8 GB, about 7 GB an hour.", with a note on a metered network.
    public var data: String? {
        guard let perHour = bytesPerHour else { return nil }
        let used = CloudGamingData.format(Double(bytes)), hour = CloudGamingData.format(perHour)
        return metered ? String(localized: "Used \(used) of your metered data, about \(hour) an hour.", comment: "Cloud gaming report on a hotspot; amounts such as 9.8 GB and 7 GB")
                       : String(localized: "Used \(used), about \(hour) an hour.", comment: "Cloud gaming report; amounts such as 9.8 GB and 7 GB")
    }

    public var macDetail: String? { strain.isEmpty ? nil : strain.prefix(2).map(\.sentence).joined(separator: " ") }

    /// Joins a stutter's factors: the Mac's conditions first, then what was moving data after "while".
    static func phrase(_ factors: [Factor]) -> String {
        let conditions = factors.filter(\.local).map(\.condition), moving = factors.filter { !$0.local }.map(\.clause)
        switch (conditions.isEmpty, moving.isEmpty) {
        case (false, false):
            return String(localized: "\(conditions.formatted(.list(type: .and))) while \(moving.formatted(.list(type: .and)))",
                          comment: "Cloud gaming report: conditions, then what was moving at the time, such as “2.4 GHz Wi-Fi while iCloud Photos uploaded”")
        case (false, true): return conditions.formatted(.list(type: .and))
        case (true, false):
            // "Dropbox was uploading" reads better alone than "Dropbox uploaded".
            if factors.count == 1, let only = factors.first, only.kind == .app {
                return only.uploading == true ? String(localized: "\(only.app ?? "another app") was uploading", comment: "Cloud gaming report: the only cause; the argument is an app")
                                              : String(localized: "\(only.app ?? "another app") was downloading", comment: "Cloud gaming report: the only cause; the argument is an app")
            }
            return moving.formatted(.list(type: .and))
        case (true, true): return String(localized: "beyond your router: your provider or the path to the game’s server", comment: "Cloud gaming report: where a stutter came from")
        }
    }

    /// The report as `kilobat cloud-gaming reports --json` and MCP give it: a compact summary without the raw lines.
    public struct Exported: Encodable, Sendable {
        public let report: CloudGamingReport
        public init(_ report: CloudGamingReport) { self.report = report }
        private enum Keys: String, CodingKey {
            case service, name, browser, title, start, end, minutes, network, metered, measured, pingMs, jitterMs, lossPercent, averageMbps, lowMbps,
                 gigabytes, gigabytesPerHour, clean, verdict, advice, data, mac, held, airDropPaused, stutters
        }
        private enum StutterKeys: String, CodingKey { case at, clock, seconds, peakMs, lowMbps, factors, sentence }
        public func encode(to encoder: Encoder) throws {
            let r = report
            var c = encoder.container(keyedBy: Keys.self)
            func round(_ value: Double?) -> Double? { value.map { ($0 * 10).rounded() / 10 } }
            try c.encode(r.service, forKey: .service); try c.encode(r.name, forKey: .name); try c.encodeIfPresent(r.browser, forKey: .browser)
            try c.encode(r.title, forKey: .title)
            let iso = ISO8601DateFormatter()
            try c.encode(iso.string(from: r.start), forKey: .start); try c.encode(iso.string(from: r.end), forKey: .end)
            try c.encode(Int((r.seconds / 60).rounded()), forKey: .minutes)
            try c.encodeIfPresent(r.networkName, forKey: .network); try c.encode(r.metered, forKey: .metered); try c.encode(r.measured, forKey: .measured)
            try c.encodeIfPresent(round(r.median), forKey: .pingMs); try c.encodeIfPresent(round(r.jitter), forKey: .jitterMs)
            try c.encode(round(r.lossPercent), forKey: .lossPercent)
            try c.encodeIfPresent(round(r.averageMbps), forKey: .averageMbps); try c.encodeIfPresent(round(r.lowMbps), forKey: .lowMbps)
            try c.encode(((Double(r.bytes) / 1e8).rounded()) / 10, forKey: .gigabytes)
            try c.encodeIfPresent(r.bytesPerHour.map { ($0 / 1e8).rounded() / 10 }, forKey: .gigabytesPerHour)
            try c.encode(r.clean, forKey: .clean); try c.encode(r.verdict, forKey: .verdict)
            try c.encodeIfPresent(r.advice, forKey: .advice); try c.encodeIfPresent(r.data, forKey: .data); try c.encodeIfPresent(r.macDetail, forKey: .mac)
            try c.encodeIfPresent(r.held, forKey: .held); try c.encodeIfPresent(r.airDropPaused, forKey: .airDropPaused)
            var list = c.nestedUnkeyedContainer(forKey: .stutters)
            for stutter in r.stutters {
                var s = list.nestedContainer(keyedBy: StutterKeys.self)
                try s.encode(Int(stutter.at), forKey: .at); try s.encode(r.clock(stutter), forKey: .clock); try s.encode(Int(stutter.seconds.rounded()), forKey: .seconds)
                try s.encodeIfPresent(round(stutter.peak), forKey: .peakMs); try s.encodeIfPresent(round(stutter.low), forKey: .lowMbps)
                try s.encode(stutter.factors.map(\.kind.rawValue), forKey: .factors); try s.encode(r.sentence(stutter), forKey: .sentence)
            }
        }
    }
}

/// Data use while a cloud game plays: per hour at the stream's current rate, and where the session is heading.
public enum CloudGamingData {
    /// "9.8 GB", "740 MB".
    public static func format(_ bytes: Double) -> String {
        bytes >= 1e9 ? "\((bytes / 1e9).formatted(.number.precision(.fractionLength(bytes >= 1e10 ? 0 : 1)))) GB"
                     : "\(Int((bytes / 1e6).rounded()).formatted()) MB"
    }
    /// How long a session lasts here: the median of the service's last ten sessions (three or more), else an hour.
    public static func typical(_ reports: [CloudGamingReport], service: String) -> TimeInterval {
        let lengths = reports.filter { $0.service == service }.suffix(10).map(\.seconds).sorted()
        guard lengths.count >= 3 else { return 3600 }
        return max(1800, lengths[lengths.count / 2])
    }
    /// The session's projected total: what it used, plus the current rate until the typical length, or the next full
    /// hour once it has run past that.
    public static func projection(used: Double, rate: Double, elapsed: TimeInterval, typical: TimeInterval) -> (seconds: TimeInterval, bytes: Double) {
        let length = elapsed < typical ? typical : (elapsed / 3600).rounded(.up) * 3600
        return (length, used + max(0, length - elapsed) * max(0, rate))
    }
    /// Seconds until `left` bytes run out at `rate`; nil when nothing is moving.
    public static func runsOut(left: Double, rate: Double) -> TimeInterval? { rate > 1000 ? max(0, left) / rate : nil }
}

/// What a session is measured from: the call engine's line, the stream's own seconds, a ping to its server, and the
/// moments the Mac was on 2.4 GHz or AirDrop's link was busy.
public struct CloudGamingSamples: Sendable {
    public struct Second: Sendable, Equatable {
        public let at: Double, down: Double, up: Double
        public init(at: Double, down: Double, up: Double) { self.at = at; self.down = down; self.up = up }
    }
    public var line = CallSamples()
    public var server: [CallSamples.Ping] = []
    public var seconds: [Second] = []
    public var band24: [Double] = []
    public var airDrop: [Double] = []
    public init() {}
}

public enum CloudGamingAnalysis {
    /// A ping 100 ms over the session's median, or lost, is a bad second: a game feels half of what a call does.
    static let spike = 100.0
    /// A second below 40% of the stream's median bitrate is the service turning quality down or the video freezing.
    static let dip = 0.4
    /// The stream ramps up at the start and winds down at the end; dips there aren't stutters.
    static let settle = 30.0, windDown = 15.0

    public static func report(service: CloudGamingService, browser: String?, start: Date, end: Date, network: (key: String, name: String)?, metered: Bool,
                              samples: CloudGamingSamples) -> CloudGamingReport {
        let serverReplies = samples.server.compactMap(\.ms)
        let useServer = samples.server.count >= 30 && Double(serverReplies.count) >= Double(samples.server.count) / 2
        let pings = useServer ? samples.server : samples.line.internet
        let replies = pings.compactMap(\.ms)
        let median = StutterTest.percentile(replies.sorted(), 50)
        let loss = pings.isEmpty ? 0 : Double(pings.count - replies.count) / Double(pings.count) * 100
        let seconds = samples.seconds.sorted { $0.at < $1.at }
        let mbps = seconds.map { $0.down * 8 / 1_000_000 }
        let bytes = UInt64(max(0, seconds.reduce(0) { $0 + $1.down }))
        let active = mbps.filter { $0 >= CloudGamingFlows.aliveRate * 8 / 1_000_000 }.sorted()
        let average = seconds.count >= 2 ? Double(bytes) * 8 / 1_000_000 / max(1, end.timeIntervalSince(start)) : nil
        let stutters = windows(pings: pings, median: median, seconds: seconds, length: end.timeIntervalSince(start)).map { window in
            CloudGamingReport.Stutter(at: window.from, seconds: window.to - window.from + 1,
                                      peak: pings.filter { $0.at >= window.from && $0.at <= window.to }.compactMap(\.ms).max().flatMap { $0 > (median ?? 0) + spike ? $0 : nil },
                                      low: seconds.filter { $0.at >= window.from && $0.at <= window.to }.map { $0.down * 8 / 1_000_000 }.min(),
                                      factors: factors(from: window.from, to: window.to, samples: samples))
        }
        var card = CloudGamingReport(service: service.id, name: service.name, browser: browser, start: start, end: end, networkKey: network?.key, networkName: network?.name,
                                     measured: useServer ? .server : .internet, median: median, jitter: CallAnalysis.jitter(replies), lossPercent: loss,
                                     averageMbps: average, lowMbps: StutterTest.percentile(active, 5), bytes: bytes, metered: metered, stutters: stutters,
                                     strain: CallAnalysis.strain(samples.line.load), line: CallAnalysis.line(pings, points: 240),
                                     bitrate: line(seconds.map { CallSamples.Ping(at: $0.at, ms: $0.down * 8 / 1_000_000) }, points: 240))
        card.household = samples.line.household != nil
        return card
    }

    /// The lowest of each stretch, for the bitrate strip: a dip should show, not average away.
    static func line(_ values: [CallSamples.Ping], points: Int) -> [Double?] {
        guard values.count > points else { return values.map(\.ms) }
        let size = Double(values.count) / Double(points)
        return (0..<points).map { index in
            values[Int(Double(index) * size)..<min(values.count, Int(Double(index + 1) * size))].compactMap(\.ms).min()
        }
    }

    /// Stretches that stuttered: two or more bad pings in a row (as calls count them, at a lower bar), or three seconds
    /// or more of the stream's bitrate under 40% of its median. Overlapping or nearly touching ones join.
    static func windows(pings: [CallSamples.Ping], median: Double?, seconds: [CloudGamingSamples.Second], length: TimeInterval) -> [(from: Double, to: Double)] {
        var found: [(from: Double, to: Double)] = CallAnalysis.runs(pings, median: median, spike: spike).compactMap { run in
            guard let first = run.first, let last = run.last else { return nil }
            return (from: first.at, to: last.at)
        }
        let rates = seconds.map { $0.down * 8 / 1_000_000 }.filter { $0 >= CloudGamingFlows.aliveRate * 8 / 1_000_000 }.sorted()
        if let typical = StutterTest.percentile(rates, 50), typical >= 3 {
            var current: (from: Double, to: Double)?
            func close() { if let window = current, window.to - window.from >= 2 { found.append(window) }; current = nil }
            for second in seconds where second.at >= settle && second.at <= length - windDown {
                if second.down * 8 / 1_000_000 < typical * dip {
                    if let window = current, second.at - window.to <= 2 { current = (window.from, second.at) } else { close(); current = (second.at, second.at) }
                } else if let window = current, second.at - window.to > 1 { close() }
            }
            close()
        }
        var merged: [(from: Double, to: Double)] = []
        for window in found.sorted(by: { $0.0 < $1.0 }) {
            if let last = merged.last, window.0 <= last.to + 2 { merged[merged.count - 1].to = max(last.to, window.1) } else { merged.append((window.0, window.1)) }
        }
        return merged
    }

    /// What was true during a stutter. The call engine names the first cause (a sign-in page, the Wi-Fi when the router
    /// stalled too, Starlink, a busy app, another device, or beyond the router); for the Wi-Fi it's split into the Mac's
    /// own conditions then (2.4 GHz, weak signal, AirDrop, a far node), and an app moving a lot at the time is added.
    static func factors(from start: Double, to end: Double, samples: CloudGamingSamples) -> [CloudGamingReport.Factor] {
        let base = CallAnalysis.cause(from: start, to: end, samples: samples.line)
        let busy = busiest(from: start, to: end, samples.line.traffic)
        switch base.kind {
        case .portal: return [.init(kind: .portal)]
        case .wifi, .airDrop:
            var found: [CloudGamingReport.Factor] = []
            if samples.band24.contains(where: { $0 >= start - 30 && $0 <= end + 5 }) { found.append(.init(kind: .band24)) }
            if samples.line.weakSignal.contains(where: { abs($0 - start) < 60 }) { found.append(.init(kind: .weakSignal)) }
            if samples.airDrop.contains(where: { $0 >= start - 30 && $0 <= end + 30 }) || base.kind == .airDrop { found.append(.init(kind: .airDrop)) }
            if base.farNode == true { found.append(.init(kind: .farNode)) }
            if found.isEmpty { found.append(.init(kind: .wifi)) }
            if let busy { found.append(busy) }
            return found
        case .starlink: return [.init(kind: .starlink, dish: base.dish)] + (busy.map { [$0] } ?? [])
        case .app: return [busy ?? .init(kind: .app, app: base.app.map { CloudGamingNames.name(id: "", name: $0) }, uploading: base.uploading)]
        case .otherDevice: return [.init(kind: .otherDevice, uploading: base.uploading, device: base.device)]
        case .beyondRouter: return [.init(kind: .beyondRouter)]
        }
    }

    /// The app moving the most around a stutter, when it moved enough to matter, by its friendlier name.
    static func busiest(from start: Double, to end: Double, _ traffic: [CallSamples.Traffic]) -> CloudGamingReport.Factor? {
        let load = { (t: CallSamples.Traffic) in t.upload / CallAnalysis.uploadLoad + t.download / CallAnalysis.downloadLoad }
        let near = traffic.filter { $0.at >= start - 5 && $0.at <= end + 1 && ($0.upload >= CallAnalysis.uploadLoad || $0.download >= CallAnalysis.downloadLoad) }
        guard let top = near.max(by: { load($0) < load($1) }) else { return nil }
        return .init(kind: .app, app: CloudGamingNames.name(id: "", name: top.app), uploading: top.upload / CallAnalysis.uploadLoad >= top.download / CallAnalysis.downloadLoad)
    }

    /// What is in the way right now, for the live card: AirDrop, 2.4 GHz, a weak signal, and apps moving a lot (other
    /// than the session's own), the busiest two.
    public static func issues(airDrop: Bool, band: String?, weak: Bool, apps: [(id: String, name: String, up: Double, down: Double)]) -> [CloudGamingIssue] {
        var issues: [CloudGamingIssue] = []
        if airDrop { issues.append(.init(kind: .airDrop)) }
        if band == "2.4 GHz" { issues.append(.init(kind: .band24)) }
        if weak { issues.append(.init(kind: .weakSignal)) }
        let busy = apps.filter { $0.up >= CallAnalysis.uploadLoad || $0.down >= CallAnalysis.downloadLoad }
            .sorted { $0.up / CallAnalysis.uploadLoad + $0.down / CallAnalysis.downloadLoad > $1.up / CallAnalysis.uploadLoad + $1.down / CallAnalysis.downloadLoad }
        for app in busy.prefix(2) {
            issues.append(.init(kind: .app, app: CloudGamingNames.name(id: app.id, name: app.name), uploading: app.up / CallAnalysis.uploadLoad >= app.down / CallAnalysis.downloadLoad,
                                pausable: CallMode.name(of: app.id) != nil))
        }
        return issues
    }
}

/// `kilobat cloud-gaming`'s options: the session now, or the reports.
public struct CloudGamingQuery: Equatable, Sendable {
    public enum Command: String, Sendable { case status, reports }
    public var command = Command.status
    public var limit = 10
    public var json = false
    public init() {}
    public static let usage = "Use cloud-gaming [status|reports] [--limit 1…200] [--json]."
    public struct Invalid: Error, Equatable { public let message: String }

    /// `args` starts with `cloud-gaming`.
    public static func parse(_ args: [String]) throws -> CloudGamingQuery {
        var query = CloudGamingQuery(), index = 1
        if index < args.count, let command = Command(rawValue: args[index]) { query.command = command; index += 1 }
        while index < args.count {
            switch args[index] {
            case "--json": query.json = true
            case "--limit":
                guard index + 1 < args.count, let value = Int(args[index + 1]), (1...200).contains(value) else { throw Invalid(message: usage) }
                query.limit = value; index += 1
            default: throw Invalid(message: usage)
            }
            index += 1
        }
        return query
    }
}
