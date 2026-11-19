import Foundation
import Testing
@testable import KilobatCore

/// Watching a route: options, the compact watch record, the per-hop timeline, alerts and the early-stopping trace.
struct RouteWatchTests {
    static let start = Date(timeIntervalSince1970: 1_000_000)

    /// A three-hop route where the destination 198.51.100.7 answers in `dest` ms (nil: lost); hop 2 sometimes skips.
    static func hops(dest: Double?, skip2: Bool = false, hop2: String = "10.0.0.1") -> [RouteHop] {
        [RouteHop(ttl: 1, addresses: ["192.168.1.1"], samples: [2], probes: 1),
         RouteHop(ttl: 2, addresses: skip2 ? [] : [hop2], samples: skip2 ? [] : [12], probes: 1),
         RouteHop(ttl: 3, addresses: dest == nil ? [] : ["198.51.100.7"], samples: dest.map { [$0] } ?? [], probes: 1)]
    }
    static func watch(_ rounds: [Double?], interval: Double = 5, skip2: (Int) -> Bool = { _ in false }) -> WatchedRoute {
        var watch = WatchedRoute(host: "example.com", started: start, interval: interval, duration: 900, options: .standard)
        watch.address = "198.51.100.7"
        for (index, dest) in rounds.enumerated() { watch.append(hops(dest: dest, skip2: skip2(index)), at: start.addingTimeInterval(Double(index) * interval)) }
        return watch
    }

    @Test func optionsBuildTracerouteArguments() throws {
        #expect(TraceOptions.standard.arguments(host: "1.1.1.1", queries: 1) == ["-n", "-m", "30", "-q", "1", "-w", "1", "1.1.1.1"])
        #expect(TraceOptions(method: .icmp, maxHops: 20, packetSize: 1000).arguments(host: "a.b", queries: 3) == ["-n", "-I", "-m", "20", "-q", "3", "-w", "1", "a.b", "1000"])
        #expect(TraceOptions(maxHops: 200, packetSize: 10).maxHops == 64)
        #expect(TraceOptions(maxHops: 200, packetSize: 10).packetSize == 60)
        #expect(TraceOptions.background.maxHops == 12)
        #expect(try TraceOptions.parse(protocol: "ICMP", maxHops: "16", size: nil).get() == TraceOptions(method: .icmp, maxHops: 16))
        #expect(throws: TraceOptionError.tcpNeedsRoot) { try TraceOptions.parse(protocol: "tcp", maxHops: nil, size: nil).get() }
        #expect(throws: TraceOptionError.maxHops) { try TraceOptions.parse(protocol: nil, maxHops: "0", size: nil).get() }
        #expect(throws: TraceOptionError.size) { try TraceOptions.parse(protocol: nil, maxHops: nil, size: "9000").get() }
    }

    @Test func watchKeepsRoundsCompactlyAndGivesThemBack() throws {
        let watch = Self.watch([20, nil, 22])
        #expect(watch.routers == ["192.168.1.1", "10.0.0.1", "198.51.100.7"])
        #expect(watch.rounds.count == 3 && watch.rounds[1].ms == [2, 12, nil] && watch.rounds[1].via == [0, 1, nil])
        #expect(watch.hops(watch.rounds[0]) == Self.hops(dest: 20))
        #expect(watch.destinationMs(watch.rounds[0]) == 20 && watch.destinationMs(watch.rounds[1]) == nil)
        #expect(watch.destinationAnswers)
        let decoded = try JSONDecoder().decode(WatchedRoute.self, from: JSONEncoder().encode(watch))
        #expect(decoded == watch)
        let csv = watch.csv.split(separator: "\n")
        #expect(csv.first == "time,host,ttl,router,ms,lost" && csv.count == 1 + 9)
        #expect(csv.contains { $0.hasSuffix(",example.com,3,,,1") })
        #expect(csv.contains { $0.hasSuffix(",example.com,3,198.51.100.7,20.0,0") })
    }

    @Test func roundsAreBoundedSoAForgottenWatchStopsGrowing() {
        var watch = WatchedRoute(host: "x", started: Self.start, interval: 2, duration: nil, options: .standard)
        for index in 0..<(WatchedRoute.roundLimit + 5) { watch.append(Self.hops(dest: 1), at: Self.start.addingTimeInterval(Double(index))) }
        #expect(watch.rounds.count == WatchedRoute.roundLimit && watch.rounds.first?.t == 5)
    }

    @Test func historyCombinesWatchesWithSavedTracesAndNamesTheHop() {
        let watch = Self.watch([80, 82, 81, 79])
        let saved = SavedRoute(date: Self.start.addingTimeInterval(-60), host: "example.com", output: " 1  192.168.1.1  2 ms  2 ms  2 ms\n 2  10.0.0.1  11 ms  12 ms  12 ms\n 3  198.51.100.7  80 ms  81 ms  82 ms")
        let history = RouteHistory(host: "example.com", routes: [saved], watches: [watch])
        #expect(history.runs == 5 && history.watchedRuns == 4)
        #expect(history.hops[2].replies == 7 && history.hops[2].probes == 7)
        #expect(history.troubleTTL == 3 && history.verdict.contains("hop 3"))
        #expect(RouteHistory(watch: watch).troubleTTL == 3)
        // Saved traces alone keep their old reading.
        #expect(RouteHistory(host: "example.com", routes: [saved]).runs == 1)
    }

    @Test func timelineRowsBucketsAndChanges() {
        // Hop 2 flips to a new router in round 3, then back: one change, the new router's first appearance.
        var watch = Self.watch([20, 21, nil, 22, 200])
        watch.append(Self.hops(dest: 23, hop2: "10.0.0.2"), at: Self.start.addingTimeInterval(25))
        watch.append(Self.hops(dest: 24), at: Self.start.addingTimeInterval(30))
        watch.append(Self.hops(dest: 25, hop2: "10.0.0.2"), at: Self.start.addingTimeInterval(35))
        let timeline = RouteTimeline(watch: watch)
        #expect(timeline.rows.map(\.ttl) == [1, 2, 3] && timeline.rounds == 8)
        #expect(timeline.rows[2].isDestination && !timeline.rows[1].isDestination)
        #expect(timeline.rows[1].routers == ["10.0.0.1", "10.0.0.2"])
        #expect(timeline.changes == [Self.start.addingTimeInterval(25)])
        #expect(RouteTimeline.changes(in: watch).count == 1)
        #expect(abs(timeline.rows[2].lossPercent - 12.5) < 0.01)
        // The lost destination round marks the hops before it too.
        #expect(timeline.rows[0].points[2].destinationLost && !timeline.rows[0].points[1].destinationLost)
        let buckets = timeline.buckets(timeline.rows[2], count: 4)
        #expect(buckets.count == 4 && buckets.reduce(0) { $0 + $1.probes } == 8)
        #expect(buckets.reduce(0) { $0 + $1.lost } == 1)
        #expect(buckets.contains { $0.high == 200 })
        #expect(timeline.nearest(Self.start.addingTimeInterval(11)) == 2)
        #expect(timeline.nearest(Self.start.addingTimeInterval(-50)) == 0 && timeline.nearest(Self.start.addingTimeInterval(500)) == 7)
        #expect(timeline.summary(timeline.rows[2]).contains("Hop 3, 198.51.100.7") && timeline.summary(timeline.rows[2]).contains("destination"))
        #expect(timeline.ceilingMs >= 20)
    }

    @Test func timelineFromSavedTraces() {
        let a = SavedRoute(date: Self.start, host: "1.1.1.1", output: " 1  192.168.1.1  2 ms  2 ms  2 ms\n 2  1.1.1.1  12 ms  * 14 ms")
        let b = SavedRoute(date: Self.start.addingTimeInterval(60), host: "1.1.1.1", output: " 1  192.168.1.1  3 ms  2 ms  2 ms\n 2  * * *")
        let timeline = RouteTimeline(host: "1.1.1.1", routes: [b, a])
        #expect(timeline.rows.count == 2 && timeline.rows[1].isDestination)
        #expect(timeline.rows[1].points.map(\.ms) == [13, nil])
        #expect(timeline.rows[0].points[1].destinationLost)
        #expect(abs(timeline.rows[1].lossPercent - 4.0 / 6 * 100) < 0.01)
    }

    @Test func alertsNeedSustainedTroubleAtTheDestination() {
        let rule = RouteAlertRule.standard
        // One lost probe in 30 s isn't enough; two are.
        #expect(rule.trouble(in: Self.watch([20, 20, nil, 20, 20, 20, 20])) == nil)
        #expect(rule.trouble(in: Self.watch([20, nil, 20, nil, 20, 20, 20])) == .loss(percent: 2.0 / 6 * 100))
        // Latency is the window's median: one spike isn't trouble, a high half is.
        #expect(rule.trouble(in: Self.watch([20, 20, 400, 20, 20, 20, 20])) == nil)
        #expect(rule.trouble(in: Self.watch([20, 20, 20, 160, 170, 180, 190])) == .latency(ms: 165))
        // Not before the window has filled.
        #expect(rule.trouble(in: Self.watch([nil, nil, nil])) == nil)
        // A destination that never answers can't raise loss alerts.
        var silent = Self.watch(Array(repeating: nil, count: 8)); silent.address = "203.0.113.9"
        #expect(rule.trouble(in: silent) == nil)
        // Intermediate hops skipping replies don't count.
        #expect(rule.trouble(in: Self.watch(Array(repeating: 20, count: 8), skip2: { _ in true })) == nil)
    }

    @Test func alertLatchFiresOnceUntilTroubleClears() {
        var latch = RouteAlertLatch()
        let rule = RouteAlertRule.standard, trouble = RouteAlertRule.Trouble.loss(percent: 50)
        // Back within the window it's still the same episode; clear for a whole window, it can fire again.
        let steps: [(RouteAlertRule.Trouble?, Double)] = [(trouble, 30), (trouble, 35), (nil, 40), (trouble, 50), (nil, 55), (nil, 80), (nil, 85), (trouble, 90)]
        var fired: [Bool] = []
        for (state, t) in steps { fired.append(latch.update(state, at: t, rule: rule)) }
        #expect(fired == [true, false, false, false, false, false, false, true])
    }

    @Test func traceStopsAfterFiveSilentHops() {
        let head = "traceroute to example.com (93.184.216.34), 30 hops max, 40 byte packets\n"
        let answering = " 1  192.168.1.1  2.1 ms\n 2  10.0.0.1  9.0 ms\n"
        let silent = (3...7).map { " \($0)  *\n" }.joined()
        #expect(TraceRunner.quiet(head + answering + silent))
        #expect(!TraceRunner.quiet(head + answering + (3...6).map { " \($0)  *\n" }.joined()))
        // The last line isn't complete yet.
        #expect(!TraceRunner.quiet(head + answering + (3...6).map { " \($0)  *\n" }.joined() + " 7  *"))
        #expect(TraceRunner.destination(head) == "93.184.216.34")
        #expect(TraceRunner.destination("traceroute: unknown host x") == nil)
        #expect(ExpertTools.isAddress("2606:4700::1111") && ExpertTools.isAddress("1.1.1.1") && !ExpertTools.isAddress("one.one"))
    }

    @Test func presetsComeFromWhatTheAppKnows() {
        let game = RouteTarget(host: "155.133.248.34", label: "Counter-Strike 2 · Frankfurt", kind: .game)
        let presets = RouteTarget.presets(router: "192.168.1.1", games: [game, RouteTarget(host: "1.1.1.1", label: "dup")])
        #expect(presets.first?.kind == .router && presets.contains(game))
        #expect(presets.filter { $0.host == "1.1.1.1" }.count == 1)
        #expect(presets.contains { $0.kind == .call })
        #expect(RouteTarget.presets(router: nil, games: []).first?.kind == .internet)
    }

    @Test func providerReportGetsARouteSection() {
        // Delay rises at hop 3 and stays; the router's private address must not reach the report.
        let watch = Self.watch([80, 82, nil, 81, 79, 84])
        let base = SupportReport.make(samples: [], events: [], speedTests: [], hours: 24, mac: "Mac", now: Self.start.addingTimeInterval(60))
        #expect(base.with(route: nil).route == nil)
        let report = base.with(route: watch)
        let route = report.route
        #expect(route?.rounds == 6 && route?.troubleTTL == 3 && route?.destinationLossPercent.map { abs($0 - 100.0 / 6) < 0.01 } == true)
        #expect(route?.hops.first?.router == "a local address" && route?.hops.last?.destination == true)
        #expect(report.findings.last?.contains("Watching the route to example.com") == true)
        #expect(report.text.contains("Route to example.com") && report.text.contains("← delay starts"))
        #expect(report.markdown.contains("| Hop | Router | Median | Worst | No reply |"))
        #expect(report.html.contains("<svg") && !report.html.contains("192.168.1.1") && !report.text.contains("192.168.1.1"))
        // Without site names, the host and its address read "the host watched".
        let private_ = report.withoutSiteNames()
        #expect(private_.route?.host == "the host watched" && !private_.text.contains("example.com") && !private_.text.contains("198.51.100.7"))
        #expect(private_.findings.last.map { !$0.contains("example.com") && !$0.contains("198.51.100.7") } == true)
        // A watch with fewer than two rounds adds nothing.
        #expect(base.with(route: Self.watch([20])).route == nil)
    }

    @MainActor @Test func journalKeepsWatchesApartFromSavedRoutes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = SurveyJournal(directory: folder)
        var running = Self.watch([20, 21])
        journal.saveWatch(running)
        running.append(Self.hops(dest: 22), at: Self.start.addingTimeInterval(10))
        journal.saveWatch(running)
        #expect(journal.watches.count == 1 && journal.watches[0].rounds.count == 3 && journal.routes.isEmpty)
        // Reopened after a quit mid-watch, it reads as cut off at its last round.
        let reopened = SurveyJournal(directory: folder)
        #expect(reopened.watches.first?.end == .quit && reopened.watches.first?.ended == Self.start.addingTimeInterval(10))
        for index in 0..<25 { journal.saveWatch(WatchedRoute(host: "h\(index)", started: Self.start.addingTimeInterval(Double(index + 1)), interval: 5, duration: nil, options: .standard)) }
        #expect(journal.watches.count == SurveyJournal.watchLimit)
        journal.removeWatch(journal.watches[0].id)
        #expect(journal.watches.count == SurveyJournal.watchLimit - 1)
    }
}
