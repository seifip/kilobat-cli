import Foundation
import Observation

/// The games and data centers Kilobat can ping, from GameServerData.swift (script/update_game_servers.py writes it).
/// Each region is the game's own public ping target: Valve's relay in the data center for CS2, Dota 2 and Deadlock, Epic's ping server
/// in the subregion for Fortnite. What is measured is the ping to that data center, not to a match server.
public struct GameServerTable: Codable, Sendable, Equatable {
    public struct Game: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        /// For tight spaces: the overlay and the game picker.
        public let short: String
        /// What each region's host is, in words.
        public let target: String
        public let source: String
        /// A TCP port the hosts accept, for networks that block ping.
        public let tcpPort: Int?
        public let regions: [Region]
        public func region(_ id: String) -> Region? { regions.first { $0.id == id.lowercased() } }
    }
    public struct Region: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let group: String
        /// Tried in order; the first that answers is measured.
        public let hosts: [String]
    }
    /// The day the table was made and its targets checked.
    public let updated: String
    public let games: [Game]

    public static func decode(_ data: Data) throws -> GameServerTable {
        let table = try JSONDecoder().decode(GameServerTable.self, from: data)
        for game in table.games {
            guard !game.regions.isEmpty, Set(game.regions.map(\.id)).count == game.regions.count, game.regions.allSatisfy({ !$0.hosts.isEmpty }) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "\(game.id): every region needs a unique id and a host"))
            }
        }
        return table
    }
    public static let bundled: GameServerTable = {
        do { return try decode(Data(bundledJSON.utf8)) }
        catch { preconditionFailure("GameServerData.swift doesn't decode: \(error)") }
    }()

    public func game(_ id: String) -> Game? { games.first { $0.id == id.lowercased() } }

    /// "cs2:fra" → CS2's Frankfurt. Anything else, an IPv6 address included, is not a game target.
    public func target(_ text: String) -> (game: Game, region: Region)? {
        let parts = text.lowercased().split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let game = game(String(parts[0])), let region = game.region(String(parts[1])) else { return nil }
        return (game, region)
    }

    /// Games people ask for that have no public target that answers a ping, and why. English: CLI and MCP only.
    public static let unsupported: [String: String] = [
        "valorant": "Valorant isn't included: Riot publishes no ping target, and its server addresses don't answer ping or TCP from outside.",
        "league": "League of Legends isn't included: the Riot addresses players used to ping no longer answer, and Riot publishes no replacement.",
        "apex": "Apex Legends isn't included: EA and Respawn publish no data center list, and the addresses players share change and aren't confirmed.",
    ]
    public static let aliases = ["lol": "league", "leagueoflegends": "league", "league-of-legends": "league", "apex-legends": "apex", "apexlegends": "apex",
                                 "cs": "cs2", "csgo": "cs2", "counter-strike": "cs2", "counterstrike": "cs2", "fn": "fortnite", "dota": "dota2", "dota-2": "dota2"]
}

/// One data center, pinged a few times.
public struct GameRegionPing: Codable, Sendable, Equatable, Identifiable {
    public enum Method: String, Codable, Sendable { case icmp, tcp }
    public var id: String { region }
    public let region: String
    public let name: String
    public let group: String
    /// The address or name that was measured; empty when nothing answered.
    public let host: String
    public let method: Method
    /// Milliseconds per probe in send order; nil for no reply.
    public let samples: [Double?]
    public var replies: [Double] { samples.compactMap { $0 } }
    public var median: Double? { StutterTest.percentile(replies.sorted(), 50) }
    /// The mean change between one reply and the next, as the overlay shows it.
    public var jitter: Double? {
        let replies = replies
        return replies.count > 1 ? zip(replies, replies.dropFirst()).map { abs($1 - $0) }.reduce(0, +) / Double(replies.count - 1) : nil
    }
    public var lossPercent: Double { samples.isEmpty ? 100 : Double(samples.count - replies.count) / Double(samples.count) * 100 }
    public init(region: String, name: String, group: String, host: String, method: Method, samples: [Double?]) {
        self.region = region; self.name = name; self.group = group; self.host = host; self.method = method; self.samples = samples
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

    /// Pings every region of a game: ICMP first, then TCP connect time to the game's port where ICMP gets no reply.
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
            GameRegionPing(region: region.id, name: region.name, group: region.group, host: host, method: method, samples: samples)
        }
        for host in region.hosts {
            let samples = await ping(host)
            if samples.contains(where: { $0 != nil }) { return result(host, .icmp, samples) }
        }
        if let port, let host = region.hosts.first, let address = await resolve(host) {
            let samples = await connect(address, port: port)
            if samples.contains(where: { $0 != nil }) { return result(address, .tcp, samples) }
        }
        return result("", .icmp, Array(repeating: nil, count: count))
    }

    static func ping(_ host: String) async -> [Double?] {
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
}

/// The Speed tab's game-server panel: one game at a time, measured when asked.
@MainActor @Observable public final class GameServerStore {
    public let table: GameServerTable
    public var game: String {
        didSet { UserDefaults.standard.set(game, forKey: "games.game") }
    }
    public private(set) var reports: [String: GamePingReport] = [:]
    public private(set) var running: String?
    public private(set) var done = 0
    public init(table: GameServerTable = .bundled) {
        self.table = table
        let saved = UserDefaults.standard.string(forKey: "games.game")
        game = saved.flatMap { table.game($0)?.id } ?? table.games.first?.id ?? ""
    }
    public var current: GameServerTable.Game? { table.game(game) }
    public var report: GamePingReport? { reports[game] }
    public func run() async {
        guard running == nil, let current else { return }
        running = current.id; done = 0
        defer { running = nil }
        reports[current.id] = await GamePing.run(current) { count in Task { @MainActor in self.done = max(self.done, count) } }
    }
    /// Sample results for screenshots and previews.
    public func preview(_ report: GamePingReport) { reports[report.game] = report }
}
