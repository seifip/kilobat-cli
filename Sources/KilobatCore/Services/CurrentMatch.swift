import AppKit
import Foundation

/// The server of the match being played, for any game: the game is the app in front (or the last game that was), by
/// CallMode's rule (App Store category, a Steam library, Wine or CrossOver), and its server is the busiest UDP
/// connection it has open, labelled with the country DB-IP gives the address and pinged like a data center.
/// A game that sends from a socket without a remote (`*:*` in nettop) can't be read this way, and says so.
public struct MatchServer: Codable, Sendable, Equatable {
    /// The game's name, as macOS shows it ("Counter-Strike 2", or the .exe's name under Wine).
    public let game: String
    public let pid: Int32
    public let address: String
    public let port: String
    /// UDP, or TCP for games that play over it.
    public let transport: String
    /// ISO country code from DB-IP: where the address is registered.
    public let country: String?
    /// Bytes on this connection since it opened.
    public let bytes: UInt64
    /// "Valve relay · Frankfurt" when the address is in one of the table's data centers.
    public let known: String?
    public init(game: String, pid: Int32, address: String, port: String, transport: String, country: String?, bytes: UInt64, known: String?) {
        self.game = game; self.pid = pid; self.address = address; self.port = port; self.transport = transport
        self.country = country; self.bytes = bytes; self.known = known
    }
    /// "Germany", for the panel and the overlay.
    public var countryName: String? { country.map { GeoIP.Country(code: $0).name } }
    /// Where it is, in words: the data center when it's one Kilobat knows, else the country.
    public var place: String? { known ?? countryName }
}

/// What a check found: the server and its ping, or why there is none.
public struct MatchCheck: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case found
        /// No game is open.
        case noGame
        /// A game is open but has no connection to a server; between matches, or offline.
        case noServer
        /// The game sends from a socket that names no server, so it can't be read.
        case hidden
    }
    public let state: State
    /// The game found, for every state but noGame.
    public let game: String?
    public let server: MatchServer?
    /// ICMP, five probes; nil for no reply.
    public let samples: [Double?]
    public let date: Date
    public init(state: State, game: String?, server: MatchServer? = nil, samples: [Double?] = [], date: Date = Date()) {
        self.state = state; self.game = game; self.server = server; self.samples = samples; self.date = date
    }
    public var replies: [Double] { samples.compactMap { $0 } }
    public var median: Double? { StutterTest.percentile(replies.sorted(), 50) }
    public var jitter: Double? { GamePing.jitter(replies) }
    /// Many game servers drop ping; that's not loss, and the panel says so instead.
    public var answersPing: Bool { !replies.isEmpty }
    public var lossPercent: Double? { answersPing ? Double(samples.count - replies.count) / Double(samples.count) * 100 : nil }
}

public enum CurrentMatch {
    /// What the overlay and `kilobat overlay --target` take for the match being played.
    public static let overlayTarget = "match"

    public struct Candidate: Sendable, Equatable {
        public let pid: Int32
        public let name: String
        public init(pid: Int32, name: String) { self.pid = pid; self.name = name }
    }

    /// DNS, HTTPS and QUIC, time, discovery and STUN: never the match.
    static let ignoredPorts: Set<String> = ["53", "80", "443", "123", "5353", "1900", "3478", "3479", "3480", "3481", "19302", "5228"]
    /// Below this a connection is a lookup or a ping, not a match.
    static let minimumBytes: UInt64 = 4_096

    /// Every running game, the frontmost first, then `preferring` (the last game in front), then the rest.
    @MainActor public static func candidates(preferring: Int32? = nil) -> [Candidate] {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let games = NSWorkspace.shared.runningApplications.filter { app in
            !app.isTerminated && CallMode.gameInFront(bundleURL: app.bundleURL, executable: app.executableURL?.lastPathComponent)
        }
        let ordered = games.sorted { rank($0.processIdentifier, front, preferring) < rank($1.processIdentifier, front, preferring) }
        return ordered.map { Candidate(pid: $0.processIdentifier, name: name($0.localizedName ?? $0.executableURL?.lastPathComponent ?? "Game")) }
    }
    private static func rank(_ pid: Int32, _ front: Int32?, _ preferred: Int32?) -> Int { pid == front ? 0 : pid == preferred ? 1 : 2 }

    /// Wine shows a Windows game by its .exe.
    static func name(_ raw: String) -> String {
        raw.lowercased().hasSuffix(".exe") ? String(raw.dropLast(4)) : raw
    }

    /// The first candidate's busiest UDP connection off this network (TCP when it has no UDP one), skipping DNS,
    /// web and STUN traffic. A candidate whose UDP goes only through unlabelled sockets makes the result `hidden`.
    public static func pick(_ candidates: [Candidate], _ connections: [Int32: ProcessConnections],
                            country: (String) -> String? = { GeoIP.shared.country($0)?.code }) -> MatchCheck {
        guard let first = candidates.first else { return MatchCheck(state: .noGame, game: nil) }
        func busiest(_ list: [OpenDestination], _ transport: String) -> OpenDestination? {
            list.filter { $0.protocols.contains(transport) && $0.total >= minimumBytes && !$0.ports.isSubset(of: ignoredPorts)
                && !TrafficRoute.isLinkLocalOrLoopback($0.address) && !isPrivate($0.address) }.max { $0.total < $1.total }
        }
        for candidate in candidates {
            let list = connections[candidate.pid]?.destinations ?? []
            for transport in ["UDP", "TCP"] {
                guard let flow = busiest(list, transport) else { continue }
                let port = flow.ports.subtracting(ignoredPorts).sorted().first ?? flow.ports.sorted().first ?? ""
                let server = MatchServer(game: candidate.name, pid: candidate.pid, address: flow.address, port: port, transport: transport,
                                         country: country(flow.address), bytes: flow.total, known: known(flow.address))
                return MatchCheck(state: .found, game: candidate.name, server: server)
            }
        }
        if let hidden = candidates.first(where: { (connections[$0.pid]?.unlabelledUDP ?? 0) >= minimumBytes }) {
            return MatchCheck(state: .hidden, game: hidden.name)
        }
        return MatchCheck(state: .noServer, game: first.name)
    }

    /// Finds the game and its server, then pings the server five times (unless `ping` is false).
    public static func check(preferring: Int32? = nil, ping: Bool = true) async -> MatchCheck {
        let candidates = await MainActor.run { Self.candidates(preferring: preferring) }
        guard !candidates.isEmpty else { return MatchCheck(state: .noGame, game: nil) }
        let found = pick(candidates, await OpenConnections.sampleByProcess(pids: Set(candidates.map(\.pid))))
        guard ping, let server = found.server else { return found }
        return MatchCheck(state: .found, game: found.game, server: server, samples: await GamePing.ping(server.address))
    }

    /// The data center an address belongs to, when its /24 holds one of the table's IPv4 targets: Valve relays, Hunt's test hosts.
    public static func known(_ address: String) -> String? { knownPrefixes[prefix(address) ?? ""] }
    private static let knownPrefixes: [String: String] = {
        var map: [String: String] = [:]
        for game in GameServerTable.bundled.popular {
            for region in game.regions {
                for host in region.hosts { if let key = prefix(host), map[key] == nil {
                    map[key] = game.kind == .valve ? "Valve relay · \(region.name)" : "\(game.short) · \(region.name)"
                } }
            }
        }
        return map
    }()
    static func prefix(_ address: String) -> String? {
        let parts = address.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return nil }
        return parts.prefix(3).joined(separator: ".")
    }
    static func isPrivate(_ address: String) -> Bool {
        guard let bytes = AddressRange.parse(address) else { return false }
        return GeoIP.isPrivate(bytes)
    }
}
