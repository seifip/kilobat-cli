import Foundation
import Testing
@testable import KilobatCore

/// The game-server table, ping parsing, the best-region choice and the overlay's game targets.
struct GameServerTests {
    private func region(_ id: String, _ samples: [Double?], group: String = "Europe") -> GameRegionPing {
        GameRegionPing(region: id, name: id.uppercased(), group: group, host: "192.0.2.1", method: .icmp, samples: samples)
    }

    // MARK: Table

    @Test func bundledTableDecodesWithUniqueRegionsAndHosts() throws {
        let table = GameServerTable.bundled
        #expect(table.games.map(\.id) == ["cs2", "dota2", "deadlock", "fortnite"])
        for game in table.games {
            #expect(!game.regions.isEmpty)
            #expect(Set(game.regions.map(\.id)).count == game.regions.count)
            #expect(game.regions.allSatisfy { !$0.hosts.isEmpty && !$0.name.isEmpty && !$0.group.isEmpty })
        }
        #expect(table.game("fortnite")?.tcpPort == 22222 && table.game("cs2")?.tcpPort == nil)
        #expect(table.game("CS2")?.region("fra")?.name == "Frankfurt")
        // Valve's three games share relays; each lists only the POPs in its own relay config.
        #expect(table.game("dota2")?.region("fra")?.hosts == table.game("cs2")?.region("fra")?.hosts)
        #expect(GameServerTable.aliases["dota"] == "dota2" && GameServerTable.aliases["lol"] == "league")
        // The games without a public target stay out of the table, with a reason.
        for id in ["valorant", "league", "apex"] { #expect(table.game(id) == nil && GameServerTable.unsupported[id] != nil) }
    }

    @Test func tableRejectsDuplicateRegionsAndEmptyHosts() {
        let duplicate = #"{"updated":"2026-10-30","games":[{"id":"x","name":"X","short":"X","target":"t","source":"s","regions":[{"id":"a","name":"A","group":"G","hosts":["1.1.1.1"]},{"id":"a","name":"B","group":"G","hosts":["1.0.0.1"]}]}]}"#
        let empty = #"{"updated":"2026-10-30","games":[{"id":"x","name":"X","short":"X","target":"t","source":"s","regions":[{"id":"a","name":"A","group":"G","hosts":[]}]}]}"#
        #expect(throws: DecodingError.self) { try GameServerTable.decode(Data(duplicate.utf8)) }
        #expect(throws: DecodingError.self) { try GameServerTable.decode(Data(empty.utf8)) }
        #expect(throws: DecodingError.self) { try GameServerTable.decode(Data(#"{"updated":"x"}"#.utf8)) }
    }

    @Test func gameTargetsParseButHostsAndIPv6DoNot() {
        let table = GameServerTable.bundled
        #expect(table.target("cs2:fra")?.region.name == "Frankfurt")
        #expect(table.target("Fortnite:DE")?.game.id == "fortnite")
        #expect(table.target("cs2:nowhere") == nil)
        #expect(table.target("2606:4700::1111") == nil)
        #expect(table.target("fe80::1") == nil)
        #expect(table.target("internet") == nil && table.target("example.com") == nil)
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
        let report = GamePingReport(game: GameServerTable.bundled.game("cs2")!, date: Date(timeIntervalSinceReferenceDate: 0), regions: [region("fra", [30, nil, 31])])
        let decoded = try JSONDecoder().decode(GamePingReport.self, from: try JSONEncoder().encode(report))
        #expect(decoded == report)
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
