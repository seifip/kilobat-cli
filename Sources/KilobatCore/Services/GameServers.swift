import AppKit
import Foundation
import Observation

/// The games and data centers Kilobat can ping, from GameServerData.swift (script/update_game_servers.py writes it).
/// Each region is the game's own public ping target (Valve's relay in the data center, Epic's ping server in the
/// subregion, a maker's published test host) or, where the maker hosts in a cloud, that cloud's latency target in the
/// region the game uses (PlayFab's beacon in an Azure region, GameLift's beacon in an AWS region). What is measured is
/// the ping to that data center, never to a match server.
public struct GameServerTable: Codable, Sendable, Equatable {
    public struct Game: Codable, Sendable, Equatable, Identifiable {
        /// Where the targets come from, for the picker's label.
        public enum Kind: String, Codable, Sendable { case valve, epic, azure, aws, official }
        public let id: String
        public let name: String
        /// For tight spaces: the overlay and the game picker.
        public let short: String
        /// Order by how many play it, 1 first.
        public let rank: Int
        public let kind: Kind
        /// The bundled icon, `game-<icon>.png`; nil shows a monogram.
        public let icon: String?
        /// What each region's host is, in words.
        public let target: String
        /// Where the game's maker hosts matches and how that's known.
        public let hosting: String
        public let source: String
        /// A TCP port the hosts accept, for networks that block ping.
        public let tcpPort: Int?
        public let regions: [Region]
        public func region(_ id: String) -> Region? { regions.first { $0.id == id.lowercased() } }
    }
    public struct Region: Codable, Sendable, Equatable, Identifiable {
        public struct Endpoint: Codable, Sendable, Equatable {
            public let host: String
            public let port: Int
            /// Hex bytes the datagram starts with; PlayFab's beacons want ffff and answer 0000.
            public let prefix: String?
            public init(host: String, port: Int, prefix: String? = nil) { self.host = host; self.port = port; self.prefix = prefix }
        }
        public let id: String
        public let name: String
        public let group: String
        /// For cloud regions, "Azure westeurope" or "AWS eu-central-1".
        public let cloud: String?
        /// Pinged in order; the first that answers is measured.
        public let hosts: [String]
        /// A UDP echo, tried first: what PlayFab and GameLift games measure.
        public let udp: Endpoint?
        /// TCP connect time, where nothing above answers.
        public let tcp: Endpoint?
        public init(id: String, name: String, group: String, cloud: String? = nil, hosts: [String], udp: Endpoint? = nil, tcp: Endpoint? = nil) {
            self.id = id; self.name = name; self.group = group; self.cloud = cloud; self.hosts = hosts; self.udp = udp; self.tcp = tcp
        }
        /// What the overlay pings: the UDP beacon, the first host, else the TCP endpoint.
        public var primaryHost: String { udp?.host ?? hosts.first ?? tcp?.host ?? "" }
    }
    /// A game with nothing reliable to ping, and why; the current match covers it.
    public struct NotMeasured: Codable, Sendable, Equatable, Identifiable {
        public enum Why: String, Codable, Sendable {
            /// No public ping target or region list.
            case none
            /// A player hosts the match.
            case peer
            /// Players join servers others run.
            case community
            /// The address answers at a CDN's edge, not the data center.
            case edge
        }
        public let id: String
        public let name: String
        public let why: Why
        /// English, for the CLI and MCP.
        public let reason: String
        public let aliases: [String]
        public let icon: String?
    }
    /// The day the table was made and its targets checked.
    public let updated: String
    public let games: [Game]
    public let notMeasured: [NotMeasured]

    public static func decode(_ data: Data) throws -> GameServerTable {
        let table = try JSONDecoder().decode(GameServerTable.self, from: data)
        for game in table.games {
            guard !game.regions.isEmpty, Set(game.regions.map(\.id)).count == game.regions.count,
                  game.regions.allSatisfy({ !$0.hosts.isEmpty || $0.udp != nil || $0.tcp != nil }) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "\(game.id): every region needs a unique id and a target"))
            }
        }
        return table
    }
    public static let bundled: GameServerTable = {
        do { return try decode(Data(bundledJSON.utf8)) }
        catch { preconditionFailure("GameServerData.swift doesn't decode: \(error)") }
    }()

    public func game(_ id: String) -> Game? { games.first { $0.id == id.lowercased() } }
    /// Games by how many play them.
    public var popular: [Game] { games.sorted { $0.rank < $1.rank } }

    /// "cs2:fra" → CS2's Frankfurt. Anything else, an IPv6 address included, is not a game target.
    public func target(_ text: String) -> (game: Game, region: Region)? {
        let parts = text.lowercased().split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let game = game(String(parts[0])), let region = game.region(String(parts[1])) else { return nil }
        return (game, region)
    }

    public enum Lookup: Equatable { case game(Game), notMeasured(NotMeasured) }
    /// A game by id, alias or name, measured or not.
    public func lookup(_ name: String) -> Lookup? {
        let key = name.lowercased().filter { !$0.isWhitespace && $0 != ":" && $0 != "'" && $0 != "’" }
        let id = Self.aliases[key] ?? key
        if let game = game(id) ?? games.first(where: { Self.key($0.name) == key || Self.key($0.short) == key }) { return .game(game) }
        if let skipped = notMeasured.first(where: { $0.id == id || $0.aliases.contains(key) || Self.key($0.name) == key }) { return .notMeasured(skipped) }
        return nil
    }
    private static func key(_ name: String) -> String { name.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" } }

    /// Games people ask for that have no public target that answers a ping, and why. English: CLI and MCP only.
    public static var unsupported: [String: String] {
        Dictionary(uniqueKeysWithValues: bundled.notMeasured.map { ($0.id, "\($0.name) isn't measured: \($0.reason)") })
    }
    public static let aliases = ["cs": "cs2", "csgo": "cs2", "counter-strike": "cs2", "counterstrike": "cs2", "counter-strike2": "cs2",
                                 "fn": "fortnite", "dota": "dota2", "dota-2": "dota2", "apex-legends": "apex", "apexlegends": "apex",
                                 "teamfortress2": "tf2", "team-fortress-2": "tf2", "tf": "tf2",
                                 "siege": "r6", "r6s": "r6", "rainbowsix": "r6", "rainbow-six-siege": "r6", "rainbowsixsiege": "r6", "rainbowsixsiegex": "r6",
                                 "deadbydaylight": "dbd", "dead-by-daylight": "dbd", "huntshowdown": "hunt", "hunt-showdown": "hunt", "huntshowdown1896": "hunt",
                                 "aoe": "aoe2", "age2": "aoe2", "aoe2de": "aoe2", "ageofempires2": "aoe2", "ageofempiresii": "aoe2", "age-of-empires-2": "aoe2",
                                 "age4": "aoe4", "ageofempires4": "aoe4", "ageofempiresiv": "aoe4", "age-of-empires-4": "aoe4",
                                 "age3": "aoe3", "aoe3de": "aoe3", "ageofempires3": "aoe3", "ageofempiresiii": "aoe3",
                                 "aomr": "aom", "athens": "aom", "ageofmythology": "aom", "ageofmythologyretold": "aom", "age-of-mythology": "aom",
                                 "bh": "brawlhalla"]
}

/// One data center, pinged a few times.
public struct GameRegionPing: Codable, Sendable, Equatable, Identifiable {
    public enum Method: String, Codable, Sendable { case icmp, tcp, udp }
    public var id: String { region }
    public let region: String
    public let name: String
    public let group: String
    /// "AWS eu-central-1" for a cloud region.
    public let cloud: String?
    /// The address or name that was measured; empty when nothing answered.
    public let host: String
    public let method: Method
    /// Milliseconds per probe in send order; nil for no reply.
    public let samples: [Double?]
    public var replies: [Double] { samples.compactMap { $0 } }
    public var median: Double? { StutterTest.percentile(replies.sorted(), 50) }
    /// The mean change between one reply and the next, as the overlay shows it.
    public var jitter: Double? { GamePing.jitter(replies) }
    public var lossPercent: Double { samples.isEmpty ? 100 : Double(samples.count - replies.count) / Double(samples.count) * 100 }
    public init(region: String, name: String, group: String, cloud: String? = nil, host: String, method: Method, samples: [Double?]) {
        self.region = region; self.name = name; self.group = group; self.cloud = cloud; self.host = host; self.method = method; self.samples = samples
    }
}

/// One game's regions, fastest first.
public struct GamePingReport: Codable, Sendable, Equatable {
    public let game: String
    public let name: String
    public let short: String
    public let date: Date
    public let regions: [GameRegionPing]
    public init(game: GameServerTable.Game, date: Date = Date(), regions: [GameRegionPing]) {
        self.game = game.id; self.name = game.name; self.short = game.short; self.date = date; self.regions = GamePing.sorted(regions)
    }
    public var best: GameRegionPing? { GamePing.best(regions) }
    /// What `kilobat overlay --target` and the app's overlay take.
    public var overlayTarget: String? { best.map { "\(game):\($0.region)" } }
    /// Every region was silent: ping is likely blocked on this network, not every data center down.
    public var noReplies: Bool { regions.allSatisfy { $0.replies.isEmpty } }
}

public enum GamePing {
    public static let count = 5
    public static let interval = 0.2
    /// Pings at once; enough to finish CS2's regions in a few seconds without a burst that skews the line.
    public static let parallel = 6

    static func jitter(_ replies: [Double]) -> Double? {
        replies.count > 1 ? zip(replies, replies.dropFirst()).map { abs($1 - $0) }.reduce(0, +) / Double(replies.count - 1) : nil
    }

    /// Answered regions by median, then jitter, then loss; silent ones last in table order.
    public static func sorted(_ regions: [GameRegionPing]) -> [GameRegionPing] {
        let order = Dictionary(uniqueKeysWithValues: regions.enumerated().map { ($1.region, $0) })
        return regions.sorted { a, b in
            switch (a.median, b.median) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                if (a.jitter ?? 0) != (b.jitter ?? 0) { return (a.jitter ?? 0) < (b.jitter ?? 0) }
                if a.lossPercent != b.lossPercent { return a.lossPercent < b.lossPercent }
                return order[a.region, default: 0] < order[b.region, default: 0]
            }
        }
    }
    /// The lowest median among regions that answered at least half the probes, else among any that answered.
    /// Within 2 ms, lower jitter wins: a steadier line beats a millisecond.
    public static func best(_ regions: [GameRegionPing]) -> GameRegionPing? {
        let answered = regions.filter { $0.median != nil }
        let steady = answered.filter { $0.lossPercent <= 50 }
        let pool = steady.isEmpty ? answered : steady
        guard let fastest = pool.compactMap(\.median).min() else { return nil }
        return pool.filter { $0.median! <= fastest + 2 }.min { ($0.jitter ?? 0, $0.median!) < ($1.jitter ?? 0, $1.median!) }
    }

    /// Pings every region of a game: the UDP echo the game itself uses where there is one, then ICMP, then TCP connect time.
    public static func run(_ game: GameServerTable.Game, progress: @escaping @Sendable (Int) -> Void = { _ in }) async -> GamePingReport {
        var results: [GameRegionPing] = []
        await withTaskGroup(of: GameRegionPing.self) { group in
            var pending = game.regions[...]
            for _ in 0..<min(parallel, pending.count) {
                let region = pending.removeFirst()
                group.addTask { await measure(region, port: game.tcpPort) }
            }
            for await result in group {
                results.append(result); progress(results.count)
                if let region = pending.popFirst() { group.addTask { await measure(region, port: game.tcpPort) } }
            }
        }
        return GamePingReport(game: game, regions: results)
    }

    static func measure(_ region: GameServerTable.Region, port: Int?) async -> GameRegionPing {
        func result(_ host: String, _ method: GameRegionPing.Method, _ samples: [Double?]) -> GameRegionPing {
            GameRegionPing(region: region.id, name: region.name, group: region.group, cloud: region.cloud, host: host, method: method, samples: samples)
        }
        if let udp = region.udp, let address = await resolve(udp.host) {
            let samples = await echo(address, udp)
            if samples.contains(where: { $0 != nil }) { return result(udp.host, .udp, samples) }
        }
        for host in region.hosts {
            let samples = await ping(host)
            if samples.contains(where: { $0 != nil }) { return result(host, .icmp, samples) }
        }
        let tcp = region.tcp ?? port.flatMap { port in region.hosts.first.map { .init(host: $0, port: port) } }
        if let tcp, let address = await resolve(tcp.host) {
            let samples = await connect(address, port: tcp.port)
            if samples.contains(where: { $0 != nil }) { return result(tcp.host, .tcp, samples) }
        }
        return result("", .icmp, Array(repeating: nil, count: count))
    }

    public static func ping(_ host: String) async -> [Double?] {
        let output = await CommandRunner.run("/sbin/ping", ["-n", "-c", String(count), "-i", String(interval), "-W", "1000", host],
                                             timeout: Double(count) * interval + 3)
        return StutterTest.parse(output.output, count: count)
    }

    /// The first IPv4 address, so connect times don't include a lookup.
    static func resolve(_ host: String) async -> String? {
        await Task.detached {
            var hints = addrinfo(), list: UnsafeMutablePointer<addrinfo>?
            hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM
            guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return nil }
            defer { freeaddrinfo(list) }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            return String(cString: buffer)
        }.value
    }

    /// TCP handshakes, one after another: a connect or a refusal both take one round trip.
    static func connect(_ address: String, port: Int) async -> [Double?] {
        var samples: [Double?] = []
        for _ in 0..<count {
            let attempt = await ConnectionProbe.open(host: address, port: port, timeout: 2)
            samples.append([.connected, .refused].contains(attempt.outcome) ? Double(attempt.ms) : nil)
        }
        return samples
    }

    /// UDP echoes, `interval` apart, each from a fresh port: GameLift allows 3 a second per sender port.
    static func echo(_ address: String, _ endpoint: GameServerTable.Region.Endpoint) async -> [Double?] {
        var samples: [Double?] = []
        for index in 0..<count {
            if index > 0 { try? await Task.sleep(for: .seconds(interval)) }
            samples.append(await echoOnce(address, endpoint))
        }
        return samples
    }

    /// One datagram and its reply in milliseconds; nil after a second without the right reply.
    public static func echoOnce(_ address: String, _ endpoint: GameServerTable.Region.Endpoint) async -> Double? {
        let prefix = endpoint.prefix.map(hexBytes) ?? []
        return await Task.detached(priority: .userInitiated) { () -> Double? in
            let payload = prefix + (0..<8).map { _ in UInt8.random(in: 0...255) }
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var target = sockaddr_in()
            target.sin_family = sa_family_t(AF_INET); target.sin_port = in_port_t(UInt16(endpoint.port).bigEndian)
            guard inet_pton(AF_INET, address, &target.sin_addr) == 1 else { return nil }
            let connected = withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard connected == 0 else { return nil }
            let start = DispatchTime.now().uptimeNanoseconds
            guard payload.withUnsafeBytes({ send(fd, $0.baseAddress, $0.count, 0) }) == payload.count else { return nil }
            var buffer = [UInt8](repeating: 0, count: 512)
            while DispatchTime.now().uptimeNanoseconds - start < 1_000_000_000 {
                let read = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                guard read > 0 else { return nil }
                if echoMatches(Array(buffer[0..<read]), sent: payload, prefixed: !prefix.isEmpty) {
                    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                }
            }
            return nil
        }.value
    }

    /// GameLift echoes the datagram as sent; PlayFab flips the first two bytes to zero and keeps the rest.
    static func echoMatches(_ reply: [UInt8], sent: [UInt8], prefixed: Bool) -> Bool {
        guard reply.count == sent.count else { return false }
        return prefixed ? reply.prefix(2).allSatisfy { $0 == 0 } && reply.dropFirst(2).elementsEqual(sent.dropFirst(2)) : reply == sent
    }

    static func hexBytes(_ text: String) -> [UInt8] {
        stride(from: 0, to: text.count - 1, by: 2).compactMap { UInt8(String(Array(text)[$0...$0 + 1]), radix: 16) }
    }
}

/// The Speed tab's game-server panel: one game at a time, measured when asked, and the match being played.
@MainActor @Observable public final class GameServerStore {
    public let table: GameServerTable
    public var game: String {
        didSet {
            UserDefaults.standard.set(game, forKey: "games.game")
            recent = [game] + recent.filter { $0 != game }.prefix(4)
            UserDefaults.standard.set(recent, forKey: "games.recent")
        }
    }
    /// The games picked last, newest first, for the top of the picker.
    public private(set) var recent: [String]
    public private(set) var reports: [String: GamePingReport] = [:]
    public private(set) var running: String?
    public private(set) var done = 0
    public private(set) var match: MatchCheck?
    public private(set) var checkingMatch = false
    /// The game that was in front last, so the check still finds it while Kilobat is in front.
    @ObservationIgnored private var lastGame: Int32?
    @ObservationIgnored private var observer: NSObjectProtocol?
    public init(table: GameServerTable = .bundled) {
        self.table = table
        let saved = UserDefaults.standard.string(forKey: "games.game")
        game = saved.flatMap { table.game($0)?.id } ?? table.popular.first?.id ?? ""
        recent = (UserDefaults.standard.stringArray(forKey: "games.recent") ?? []).filter { table.game($0) != nil }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  CallMode.gameInFront(bundleURL: app.bundleURL, executable: app.executableURL?.lastPathComponent) else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.lastGame = pid }
        }
    }
    /// A game is open, so checking the match can find something.
    public var gameRunning: Bool { !CurrentMatch.candidates(preferring: lastGame).isEmpty }
    public var current: GameServerTable.Game? { table.game(game) }
    public var report: GamePingReport? { reports[game] }
    public func run() async {
        guard running == nil, let current else { return }
        running = current.id; done = 0
        defer { running = nil }
        reports[current.id] = await GamePing.run(current) { count in Task { @MainActor in self.done = max(self.done, count) } }
    }
    /// Finds the game's busiest server connection and pings it.
    public func checkMatch() async {
        guard !checkingMatch else { return }
        checkingMatch = true
        defer { checkingMatch = false }
        match = await CurrentMatch.check(preferring: lastGame)
    }
    /// Sample results for screenshots and previews.
    public func preview(_ report: GamePingReport) { reports[report.game] = report }
    public func preview(_ check: MatchCheck?) { match = check }
}
