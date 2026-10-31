import Foundation
import Testing
@testable import KilobatCore

/// The game-server table, ping parsing, the best-region choice, the UDP beacons, the current match and the overlay's game targets.
struct GameServerTests {
    private func region(_ id: String, _ samples: [Double?], group: String = "Europe") -> GameRegionPing {
        GameRegionPing(region: id, name: id.uppercased(), group: group, host: "192.0.2.1", method: .icmp, samples: samples)
    }
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    // MARK: Table

    @Test func bundledTableDecodesWithUniqueRegionsAndTargets() throws {
        let table = GameServerTable.bundled
        #expect(Set(["cs2", "dota2", "deadlock", "tf2", "fortnite", "apex", "r6", "dbd", "aoe2", "aoe3", "aoe4", "aom", "brawlhalla", "hunt", "marathon"]).isSubset(of: Set(table.games.map(\.id))))
        #expect(table.popular.first?.id == "cs2" && Set(table.games.map(\.rank)).count == table.games.count)
        for game in table.games {
            #expect(!game.regions.isEmpty && !game.target.isEmpty && !game.hosting.isEmpty && !game.source.isEmpty)
            #expect(Set(game.regions.map(\.id)).count == game.regions.count)
            #expect(game.regions.allSatisfy { !$0.name.isEmpty && !$0.group.isEmpty && !$0.primaryHost.isEmpty })
        }
        #expect(table.game("fortnite")?.tcpPort == 22222 && table.game("cs2")?.tcpPort == nil)
        #expect(table.game("CS2")?.region("fra")?.name == "Frankfurt")
        // Valve's games share relays; each lists only the POPs in its own relay config.
        #expect(table.game("dota2")?.region("fra")?.hosts == table.game("cs2")?.region("fra")?.hosts)
        // Cloud games name their region and measure the cloud's own latency beacon.
        for game in table.games where game.kind == .aws {
            #expect(game.regions.allSatisfy { $0.cloud?.hasPrefix("AWS ") == true && $0.udp?.port == 7770 && $0.udp?.host == "gamelift-ping.\($0.id).api.aws" })
        }
        for game in table.games where game.kind == .azure {
            #expect(game.regions.allSatisfy { $0.cloud == "Azure \($0.id)" && ($0.udp.map { $0.port == 3075 && $0.prefix == "ffff" } ?? ($0.tcp?.port == 443)) })
        }
        #expect(table.game("aoe4")?.region("westeurope")?.udp?.host == "mpsqosprod.westeurope.cloudapp.azure.com")
        #expect(table.game("brawlhalla")?.regions.allSatisfy { $0.hosts.isEmpty && $0.tcp?.port == 443 } == true)
        // The games without a public target stay out of the table, with a reason.
        let skipped = Set(table.notMeasured.map(\.id))
        #expect(skipped.isDisjoint(with: table.games.map(\.id)))
        for id in ["valorant", "league", "overwatch", "cod", "pubg", "roblox", "minecraft"] {
            #expect(table.game(id) == nil && skipped.contains(id) && GameServerTable.unsupported[id] != nil)
        }
    }

    @Test func everyIconIsBundledWithItsSource() throws {
        let table = GameServerTable.bundled
        let sources = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.repository.appendingPathComponent("Assets/Games/sources.json"))) as? [String: Any]
        let icons = sources?["icons"] as? [String: [String: String]] ?? [:]
        let named = table.games.compactMap(\.icon) + table.notMeasured.compactMap(\.icon)
        #expect(named.count >= 40)
        for icon in named {
            #expect(FileManager.default.fileExists(atPath: Self.repository.appendingPathComponent("Assets/Games/game-\(icon).png").path), "app icon \(icon)")
            #expect(FileManager.default.fileExists(atPath: Self.repository.appendingPathComponent("site/public/assets/games/\(icon).webp").path), "site icon \(icon)")
            #expect(icons[icon]?["url"]?.hasPrefix("https://") == true, "source for \(icon)")
        }
    }

    @Test func lookupFindsGamesByIdAliasAndName() {
        let table = GameServerTable.bundled
        #expect(table.lookup("Age of Empires IV") == .game(table.game("aoe4")!))
        #expect(table.lookup("siege") == .game(table.game("r6")!))
        #expect(table.lookup("Rainbow Six Siege X") == .game(table.game("r6")!))
        #expect(table.lookup("apex") == .game(table.game("apex")!))
        #expect(table.lookup("CS:GO") == .game(table.game("cs2")!))
        if case .notMeasured(let league)? = table.lookup("lol") { #expect(league.id == "league" && !league.reason.isEmpty) } else { Issue.record("lol") }
        if case .notMeasured(let wow)? = table.lookup("World of Warcraft") { #expect(wow.id == "wow") } else { Issue.record("wow") }
        #expect(table.lookup("not a game") == nil)
    }

    @Test func tableRejectsDuplicateRegionsAndRegionsWithoutTargets() throws {
        let game = #""id":"x","name":"X","short":"X","rank":1,"kind":"azure","target":"t","hosting":"h","source":"s""#
        let duplicate = #"{"updated":"2026-10-30","notMeasured":[],"games":[{\#(game),"regions":[{"id":"a","name":"A","group":"G","hosts":["1.1.1.1"]},{"id":"a","name":"B","group":"G","hosts":["1.0.0.1"]}]}]}"#
        let empty = #"{"updated":"2026-10-30","notMeasured":[],"games":[{\#(game),"regions":[{"id":"a","name":"A","group":"G","hosts":[]}]}]}"#
        let udpOnly = #"{"updated":"2026-10-30","notMeasured":[],"games":[{\#(game),"regions":[{"id":"a","name":"A","group":"G","hosts":[],"udp":{"host":"b.example","port":7770}}]}]}"#
        #expect(throws: DecodingError.self) { try GameServerTable.decode(Data(duplicate.utf8)) }
        #expect(throws: DecodingError.self) { try GameServerTable.decode(Data(empty.utf8)) }
        #expect(throws: DecodingError.self) { try GameServerTable.decode(Data(#"{"updated":"x"}"#.utf8)) }
        let decoded = try GameServerTable.decode(Data(udpOnly.utf8))
        #expect(decoded.games[0].regions[0].primaryHost == "b.example" && decoded.games[0].icon == nil)
    }

    @Test func gameTargetsParseButHostsAndIPv6DoNot() {
        let table = GameServerTable.bundled
        #expect(table.target("cs2:fra")?.region.name == "Frankfurt")
        #expect(table.target("Fortnite:DE")?.game.id == "fortnite")
        #expect(table.target("aoe4:westeurope")?.region.cloud == "Azure westeurope")
        #expect(table.target("apex:eu-central-1")?.region.name == "Frankfurt")
        #expect(table.target("cs2:nowhere") == nil)
        #expect(table.target("2606:4700::1111") == nil)
        #expect(table.target("fe80::1") == nil)
        #expect(table.target("internet") == nil && table.target("example.com") == nil && table.target("match") == nil)
    }

    // MARK: Measurements

    @Test func pingOutputParsesIntoSlotsWithLoss() {
        let output = """
        PING 155.133.226.68 (155.133.226.68): 56 data bytes
        64 bytes from 155.133.226.68: icmp_seq=0 ttl=52 time=31.402 ms
        64 bytes from 155.133.226.68: icmp_seq=2 ttl=52 time=33.118 ms
        Request timeout for icmp_seq 1
        64 bytes from 155.133.226.68: icmp_seq=3 ttl=52 time=30.950 ms
        64 bytes from 155.133.226.68: icmp_seq=4 ttl=52 time=45.001 ms
        """
        let samples = StutterTest.parse(output, count: GamePing.count)
        #expect(samples == [31.402, nil, 33.118, 30.950, 45.001])
        let ping = region("fra", samples)
        #expect(ping.median == (31.402 + 33.118) / 2)
        #expect(ping.lossPercent == 20)
        // Mean change between consecutive replies: |33.118−31.402|, |30.950−33.118|, |45.001−30.950|.
        #expect(abs(ping.jitter! - (1.716 + 2.168 + 14.051) / 3) < 0.0001)
    }

    @Test func silentRegionHasNoMedianAndFullLoss() {
        let silent = region("syd", [nil, nil, nil, nil, nil])
        #expect(silent.median == nil && silent.jitter == nil && silent.lossPercent == 100)
        #expect(region("x", []).lossPercent == 100)
    }

    @Test func beaconRepliesMatchTheirProtocol() {
        let sent: [UInt8] = [0xFF, 0xFF, 1, 2, 3, 4]
        // PlayFab flips the first two bytes to zero and echoes the rest.
        #expect(GamePing.echoMatches([0, 0, 1, 2, 3, 4], sent: sent, prefixed: true))
        #expect(!GamePing.echoMatches([0xFF, 0xFF, 1, 2, 3, 4], sent: sent, prefixed: true))
        #expect(!GamePing.echoMatches([0, 0, 1, 2, 3, 9], sent: sent, prefixed: true))
        // GameLift echoes the datagram as sent.
        #expect(GamePing.echoMatches([7, 8, 9], sent: [7, 8, 9], prefixed: false))
        #expect(!GamePing.echoMatches([7, 8], sent: [7, 8, 9], prefixed: false))
        #expect(GamePing.hexBytes("ffff") == [0xFF, 0xFF] && GamePing.hexBytes("") == [])
    }

    // MARK: Best region

    @Test func bestIsTheLowestMedianAndSilentRegionsSortLast() {
        let regions = [region("lhr", [40, 41, 40, 42, 40]), region("syd", [nil, nil, nil, nil, nil]), region("fra", [30, 31, 30, 32, 30]), region("ams", [35, 36, 35, 35, 36])]
        let report = GamePingReport(game: GameServerTable.bundled.game("cs2")!, regions: regions)
        #expect(report.regions.map(\.region) == ["fra", "ams", "lhr", "syd"])
        #expect(report.best?.region == "fra")
        #expect(report.overlayTarget == "cs2:fra")
        #expect(!report.noReplies)
    }

    @Test func steadierRegionWinsWithinTwoMilliseconds() {
        let jumpy = region("fra", [20, 60, 21, 59, 22])     // median 22, jitter about 39
        let steady = region("ams", [23, 23, 24, 23, 23])    // median 23, jitter under 1
        #expect(GamePing.best([jumpy, steady])?.region == "ams")
        // Three or more milliseconds apart, the faster one wins whatever its jitter.
        let slower = region("lhr", [26, 26, 26, 26, 26])
        #expect(GamePing.best([jumpy, slower])?.region == "fra")
    }

    @Test func mostlyLostRegionLosesToOneThatAnswers() {
        let lossy = region("fra", [10, nil, nil, nil, nil])
        let solid = region("ams", [30, 31, 30, 30, 31])
        #expect(GamePing.best([lossy, solid])?.region == "ams")
        // When every region drops most probes, the fastest that answered still wins.
        #expect(GamePing.best([lossy, region("lhr", [50, nil, nil, nil, nil])])?.region == "fra")
    }

    @Test func noRepliesAnywhereHasNoBest() {
        let report = GamePingReport(game: GameServerTable.bundled.game("fortnite")!, regions: [region("de", [nil, nil]), region("gb", [nil, nil])])
        #expect(report.best == nil && report.overlayTarget == nil && report.noReplies)
        #expect(report.regions.map(\.region) == ["de", "gb"])
    }

    @Test func reportRoundTripsThroughJSON() throws {
        let cloud = GameRegionPing(region: "westeurope", name: "Netherlands", group: "Europe", cloud: "Azure westeurope", host: "mpsqosprod.westeurope.cloudapp.azure.com", method: .udp, samples: [18, nil, 19])
        let report = GamePingReport(game: GameServerTable.bundled.game("aoe4")!, date: Date(timeIntervalSinceReferenceDate: 0), regions: [region("fra", [30, nil, 31]), cloud])
        let decoded = try JSONDecoder().decode(GamePingReport.self, from: try JSONEncoder().encode(report))
        #expect(decoded == report && decoded.best?.cloud == "Azure westeurope")
    }

    // MARK: Current match

    private let nettop = """
    ,bytes_in,bytes_out,
    cs2.4242,6000000,900000,
    udp4 192.168.1.20:27005<->155.133.226.75:27026,4200000,600000,
    udp4 192.168.1.20:51000<->142.250.74.110:443,1500000,200000,
    tcp4 192.168.1.20:52000<->23.40.10.5:443,300000,20000,
    udp4 192.168.1.20:5353<->224.0.0.251:5353,9000,9000,
    udp4 *:61000<->*:*,800,800,
    wine64-preloader.5151,90000,90000,
    udp4 *:52344<->*:*,700000,300000,
    tcp4 192.168.1.20:52100<->137.221.106.19:3724,40000,30000,
    Safari.777,50000000,100000,
    udp4 192.168.1.20:52500<->17.253.144.10:3480,9000000,10000,
    """

    @Test func nettopSplitsConnectionsByProcessAndCountsUnlabelledUDP() {
        let parsed = OpenConnections.parseByProcess(nettop, pids: [4242, 5151])
        #expect(parsed[4242]?.destinations.first?.address == "155.133.226.75")
        #expect(parsed[4242]?.unlabelledUDP == 1_600)
        #expect(parsed[5151]?.unlabelledUDP == 1_000_000 && parsed[5151]?.destinations.map(\.address) == ["137.221.106.19"])
        #expect(parsed[777] == nil)
        // The merged view is unchanged for its other callers.
        #expect(OpenConnections.parse(nettop, pids: [4242]).map(\.address) == ["155.133.226.75", "142.250.74.110", "23.40.10.5", "224.0.0.251"])
    }

    @Test func matchIsTheGamesBusiestUDPConnectionSkippingWebAndLocalTraffic() {
        let connections = OpenConnections.parseByProcess(nettop, pids: [4242, 5151, 777])
        let check = CurrentMatch.pick([.init(pid: 4242, name: "Counter-Strike 2")], connections) { $0 == "155.133.226.75" ? "DE" : nil }
        #expect(check.state == .found && check.game == "Counter-Strike 2")
        #expect(check.server?.address == "155.133.226.75" && check.server?.port == "27026" && check.server?.transport == "UDP")
        #expect(check.server?.country == "DE" && check.server?.known == "Valve relay · Frankfurt" && check.server?.place == "Valve relay · Frankfurt")
        // A game that plays over TCP still has a server; QUIC on 443 and STUN never count.
        let tcp = CurrentMatch.pick([.init(pid: 5151, name: "World of Warcraft")], connections) { _ in "US" }
        #expect(tcp.state == .found && tcp.server?.transport == "TCP" && tcp.server?.port == "3724" && tcp.server?.known == nil)
        #expect(CurrentMatch.pick([.init(pid: 777, name: "Safari")], connections).state == .noServer)
    }

    @Test func matchExplainsWhenItCantSeeTheServer() {
        let hidden = OpenConnections.parseByProcess("""
        ,bytes_in,bytes_out,
        wine64-preloader.5151,90000,90000,
        udp4 *:52344<->*:*,700000,300000,
        """, pids: [5151])
        let check = CurrentMatch.pick([.init(pid: 5151, name: "VALORANT")], hidden)
        #expect(check.state == .hidden && check.game == "VALORANT" && check.server == nil)
        #expect(CurrentMatch.pick([.init(pid: 9, name: "Dota 2")], [:]).state == .noServer)
        #expect(CurrentMatch.pick([], [:]).state == .noGame)
        // The first candidate (the game in front) wins over a busier game behind it.
        let both = OpenConnections.parseByProcess(nettop, pids: [4242, 5151])
        #expect(CurrentMatch.pick([.init(pid: 5151, name: "WoW"), .init(pid: 4242, name: "CS2")], both).game == "WoW")
        #expect(CurrentMatch.name("RiotClientServices.exe") == "RiotClientServices" && CurrentMatch.name("Dota 2") == "Dota 2")
    }

    @Test func silentMatchServerIsNotLoss() {
        let server = MatchServer(game: "X", pid: 1, address: "203.0.113.9", port: "7777", transport: "UDP", country: "NL", bytes: 10_000, known: nil)
        let silent = MatchCheck(state: .found, game: "X", server: server, samples: [nil, nil, nil, nil, nil])
        #expect(!silent.answersPing && silent.lossPercent == nil && silent.median == nil)
        let answered = MatchCheck(state: .found, game: "X", server: server, samples: [20, nil, 22, 21, 20])
        #expect(answered.answersPing && answered.lossPercent == 20 && answered.median == 20.5)
    }

    // MARK: Overlay

    @Test func overlayResolvesGameTargetsToTheirDataCenter() async {
        let (host, label) = await LivePing.host(for: "cs2:fra")
        #expect(host == GameServerTable.bundled.target("cs2:fra")!.region.hosts[0])
        #expect(label == "CS2 · Frankfurt")
        let internet = await LivePing.host(for: "internet")
        #expect(internet.host == "1.1.1.1" && internet.label == nil)
    }
}
