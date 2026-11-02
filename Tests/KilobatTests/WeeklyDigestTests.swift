import Foundation
import Testing
@testable import KilobatCore

/// The weekly digest: which facts make it and in what order, the calm week, no zeros, the week before, the schedule
/// with its catch-up after sleep, the first week, what Pro adds, and the command line.
struct WeeklyDigestTests {
    private let utc: Calendar = { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!; return calendar }()
    /// 2 November 2026 is a Monday; the digest that goes out then covers 26 October to 1 November.
    private func at(_ day: Int, _ hour: Int = 12, _ minute: Int = 0, month: Int = 11) -> Date {
        utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }
    private var week: DateInterval { DateInterval(start: at(26, 0, month: 10), end: at(2, 0)) }
    private var now: Date { at(2, 9, 5) }

    private func outage(_ start: Date, minutes: Double, router: Bool = true) -> NetworkEvent {
        NetworkEvent(start: start, end: start.addingTimeInterval(minutes * 60), network: "Home", kind: "Unreachable", detail: "",
                     routerChecks: 20, routerAnswered: router ? 20 : 0)
    }
    /// A call of `minutes`, with freezes at the seconds in `spikes`, caused by Dropbox uploading when `dropbox`, else weak Wi-Fi.
    private func call(_ start: Date, spikes: [Int] = [], dropbox: Bool = true) -> CallReport {
        var samples = CallSamples()
        samples.internet = (0..<600).map { i in .init(at: Double(i), ms: spikes.contains { i >= $0 && i < $0 + 3 } ? nil : 28 + Double(i % 5)) }
        samples.router = (0..<600).map { i in .init(at: Double(i), ms: !dropbox && spikes.contains { i >= $0 && i < $0 + 3 } ? nil : 3) }
        if dropbox { samples.traffic = spikes.map { .init(at: Double($0), app: "Dropbox", upload: 900_000, download: 0) } }
        else { samples.weakSignal = spikes.map(Double.init) }
        return CallAnalysis.report(app: "Zoom", browser: false, start: start, end: start.addingTimeInterval(600), network: nil, samples: samples)
    }
    private func usage(_ date: Date, gb: Double, network: String = "home", metered: Bool? = nil) -> UsageEntry {
        let bytes = UInt64(gb * 1e9)
        return UsageEntry(date: date, received: bytes * 4 / 5, sent: bytes - bytes * 4 / 5, apps: ["com.apple.Safari": bytes], networkKey: network, metered: metered)
    }
    /// History from four weeks back, a few GB a day at home.
    private func base() -> DigestInput {
        var input = DigestInput()
        input.networkNames = ["home": "Home Wi-Fi", "phone": "Rita’s iPhone"]
        input.homeNetworks = ["home"]
        var day = at(5, 12, month: 10)
        while day < at(2, 0) { input.usage.append(usage(day, gb: 5)); day = day.addingTimeInterval(86_400) }
        return input
    }
    private func busy() -> DigestInput {
        var input = base()
        input.events = [outage(at(27, 9, month: 10), minutes: 30), outage(at(29, 20, month: 10), minutes: 11),
                        outage(at(19, 9, month: 10), minutes: 20), outage(at(20, 9, month: 10), minutes: 20), outage(at(21, 9, month: 10), minutes: 20), outage(at(22, 9, month: 10), minutes: 20)]
        input.calls = [call(at(27, 15, month: 10), spikes: [100, 300]), call(at(28, 15, month: 10), spikes: [200]), call(at(30, 15, month: 10), spikes: [50], dropbox: false),
                       call(at(31, 15, month: 10)), call(at(1, 15))]
        input.usage += [usage(at(28, 18, month: 10), gb: 2.5, network: "phone", metered: true), usage(at(30, 18, month: 10), gb: 1.7, network: "phone", metered: true)]
        input.ledger = DigestLedger(days: ["2026-10-27": .init(trackers: 300), "2026-10-28": .init(trackers: 260)])
        return input
    }
    private func digest(_ input: DigestInput, pro: Bool = true) -> WeeklyDigest { WeeklyDigest.make(input, week: week, pro: pro, now: now, calendar: utc) }

    // MARK: Facts and ranking

    @Test func ranksProviderOutagesThenCallsThenMeteredData() {
        let digest = digest(busy())
        #expect(digest.facts.map(\.topic) == [.outages, .calls, .metered, .trackers])
        #expect(!digest.calm && digest.summary == nil)
        let outages = digest.facts[0]
        #expect(outages.line.contains("2 outages on your provider’s side") && outages.line.contains("41"))
        #expect(outages.days?.count == 7 && outages.tab == .history)
        #expect(digest.facts[1].line.hasPrefix("3 of 5 calls froze"))
        #expect(digest.facts[2].line.contains("Rita’s iPhone") && digest.facts[2].line.contains("4.2 GB"))
        // The notification carries the top three.
        #expect(digest.headline.hasPrefix("2 outages on your provider’s side") && digest.headline.contains("calls froze") && digest.headline.contains("4.2 GB"))
        #expect(!digest.headline.contains("trackers"))
    }

    @Test func showsAtMostFourFacts() {
        var input = busy()
        input.remote = []
        input.ledger.days["2026-10-29"] = .init(threats: 2, agentGuard: 1, agents: 3)
        input.starlink = (0..<5).map { StarlinkOutage(cause: .obstructed, start: at(30, 10 + $0, month: 10), seconds: 40) }
        let digest = digest(input)
        #expect(digest.facts.count == WeeklyDigest.shown)
        #expect(digest.facts.map(\.score) == digest.facts.map(\.score).sorted(by: >))
    }

    @Test func agentBlocksRankAboveAPlainFigure() {
        var input = base()
        input.usage += [usage(at(28, 18, month: 10), gb: 3, network: "phone", metered: true)]
        input.ledger = DigestLedger(days: ["2026-10-29": .init(threats: 2, agentGuard: 1, agents: 3)])
        input.blocked = [FilterEvent(date: at(29, 10, month: 10), app: "node", endpoint: "paste.example:443", direction: "outgoing", reason: "",
                                     protection: ProtectionDetail(kind: .agentGuard, list: "paste site", host: "paste.example", agent: "Claude Code"))]
        let digest = digest(input)
        #expect(digest.facts.map(\.topic) == [.protection, .metered])
        #expect(digest.facts[0].line.contains("3 risky connections, 3 from AI agents") || digest.facts[0].line.contains("Claude Code"))
        #expect(digest.facts[0].tab == .connections)
    }

    @Test func outagesAtTheRouterRankBelowCallsAndSaySo() {
        var input = base()
        input.events = [outage(at(27, 9, month: 10), minutes: 12, router: false)]
        input.calls = [call(at(28, 15, month: 10), spikes: [200])]
        let digest = digest(input)
        #expect(digest.facts.map(\.topic) == [.calls, .outages])
        #expect(digest.facts[1].line.contains("at your router or Wi-Fi"))
    }

    // MARK: Calm weeks and zeros

    @Test func aCalmWeekSaysSoInOneSentence() {
        var input = base()
        input.calls = [call(at(27, 15, month: 10)), call(at(29, 15, month: 10))]
        let digest = digest(input)
        #expect(digest.calm && digest.facts.isEmpty)
        let summary = try! #require(digest.summary)
        #expect(summary.hasPrefix("A calm week: no outages, every call clean"))
        #expect(summary.contains("35 GB at home"))
        #expect(digest.headline == summary)
    }

    @Test func aCalmWeekStillMentionsAFigureWorthKnowing() {
        var input = base()
        input.usage += [usage(at(28, 18, month: 10), gb: 1.2, network: "phone", metered: true)]
        input.homeNetworks = []
        let digest = digest(input)
        #expect(digest.calm && digest.facts.map(\.topic) == [.metered])
        #expect(digest.summary?.contains("on Home Wi-Fi") == true)
        #expect(digest.headline.contains("Also:") && digest.headline.contains("1.2 GB"))
    }

    @Test func neverListsZeros() {
        var input = base()
        input.calls = [call(at(27, 15, month: 10))]
        input.ledger = DigestLedger(days: ["2026-10-27": .init(trackers: 3)])
        input.usage += [usage(at(28, 18, month: 10), gb: 0.01, network: "phone", metered: true)]
        input.events = [outage(at(20, 9, month: 10), minutes: 40)]
        let digest = digest(input)
        #expect(digest.facts.isEmpty)
        for text in digest.facts.map(\.line) + [digest.headline] {
            #expect(!text.contains(" 0 ") && !text.hasPrefix("0 "))
        }
        #expect(digest.summary?.contains("your call was clean") == true)
    }

    @Test func aWeekWithNothingRecordedIsEmpty() {
        var input = DigestInput()
        input.usage = [usage(at(1, 12, month: 9), gb: 1)]
        let digest = digest(input)
        #expect(digest.empty)
    }

    // MARK: The week before

    @Test func comparesWithTheWeekBeforeWhenItSaysSomething() {
        let digest = digest(busy())
        let outages = digest.facts.first { $0.topic == .outages }
        #expect(outages?.comparison == "half last week’s" && outages?.previous == 4)
        #expect(digest.compared)
        // Metered data was none the week before; no calls the week before says nothing about calls.
        #expect(digest.facts.first { $0.topic == .metered }?.comparison == "none the week before")
        #expect(digest.facts.first { $0.topic == .calls }?.comparison == nil)
    }

    @Test func comparisonWords() {
        #expect(WeeklyDigest.comparison(2, 4) == "half last week’s")
        #expect(WeeklyDigest.comparison(6, 3) == "twice last week’s")
        #expect(WeeklyDigest.comparison(1, 6) == "down from 6 last week")
        #expect(WeeklyDigest.comparison(9, 2) == "up from 2 last week")
        #expect(WeeklyDigest.comparison(3, 0) == "none the week before")
        #expect(WeeklyDigest.comparison(4, 5) == nil)
        #expect(WeeklyDigest.comparison(1, 1) == nil)
        #expect(WeeklyDigest.comparison(0, 5) == nil)
        #expect(WeeklyDigest.comparison(5e9, 1e9, bytes: true)?.hasPrefix("up from 1") == true)
    }

    @Test func noComparisonWithoutTheWeekBefore() {
        var input = busy()
        input.usage = input.usage.filter { $0.date >= at(25, 0, month: 10) }
        input.events = input.events.filter { $0.start >= at(25, 0, month: 10) }
        let digest = digest(input)
        #expect(!digest.compared && !digest.partial)
        #expect(digest.facts.allSatisfy { $0.comparison == nil && $0.previous == nil })
    }

    // MARK: Free and Pro

    @Test func freeShowsCountsWithOneProLine() {
        let free = digest(busy(), pro: false)
        let outages = try! #require(free.facts.first { $0.topic == .outages })
        #expect(outages.line.hasPrefix("2 outages (") && !outages.line.contains("provider"))
        let calls = try! #require(free.facts.first { $0.topic == .calls })
        #expect(calls.line == "3 of 5 calls froze")
        // One Pro line, on the first fact a Pro feature explains.
        #expect(free.facts.compactMap(\.proHint).count == 1)
        #expect(free.facts[0].proHint?.contains("whose side") == true)
        #expect(free.proHint != nil && !free.headline.contains("Pro"))
    }

    @Test func proShowsWhy() {
        let pro = digest(busy())
        let calls = try! #require(pro.facts.first { $0.topic == .calls })
        #expect(calls.line == "3 of 5 calls froze, 2 because of Dropbox")
        #expect(calls.detail?.contains("Dropbox") == true)
        #expect(pro.proHint == nil)
    }

    @Test func noProLineWhenNothingAProFeatureExplainsHappened() {
        var input = base()
        input.usage += [usage(at(28, 18, month: 10), gb: 3, network: "phone", metered: true)]
        let free = digest(input, pro: false)
        #expect(free.facts.map(\.topic) == [.metered] && free.proHint == nil)
    }

    @Test func freeRouterSlowdownIsTheSymptomNotTheCause() {
        var input = base()
        var record = RouterRecord(network: "home", mac: "f4:92:bf:10:20:30", name: "Home", lastSeen: at(1, 18))
        // Two weeks at 4 ms, then a slowdown through the week.
        let start = at(12, 0, month: 10)
        for day in 0..<21 {
            for hour in 9...16 {
                let rtt = day < 14 ? 4.0 : [9.0, 11, 13, 15, 17, 19, 20][day - 14]
                record.hours.append(RouterHour(start: start.addingTimeInterval(Double(day) * 86_400 + Double(hour) * 3600), checks: 40, rtt: rtt, rtt90: rtt * 1.4, sent: 160, rssi: -55, band: "5 GHz"))
            }
        }
        record.update(now: at(29, 20, month: 10), calendar: utc)
        input.routers = [record]
        let free = digest(input, pro: false), pro = digest(input)
        let freeFact = try! #require(free.facts.first { $0.topic == .router })
        #expect(freeFact.line.hasPrefix("Your connection was slower than usual on") && !freeFact.line.contains("router"))
        #expect(freeFact.proHint?.contains("router") == true)
        #expect(pro.facts.first { $0.topic == .router }?.line.hasPrefix("Your router slowed down") == true)
    }

    // MARK: Schedule

    @Test func goesOutOnMondayAtNineForTheWeekBefore() {
        let schedule = DigestSchedule()
        let history = at(1, 0, month: 9)
        #expect(schedule.decide(now: at(2, 8, 59), last: at(26, 9, month: 10), historyStart: history, calendar: utc) == .wait)
        #expect(schedule.decide(now: at(2, 9, 0), last: at(26, 9, month: 10), historyStart: history, calendar: utc) == .send(slot: at(2, 9), week: week))
        // Sent: nothing more until next Monday.
        #expect(schedule.decide(now: at(4, 9), last: at(2, 9), historyStart: history, calendar: utc) == .wait)
        #expect(schedule.decide(now: at(9, 9, 1), last: at(2, 9), historyStart: history, calendar: utc)
                == .send(slot: at(9, 9), week: DateInterval(start: at(2, 0), end: at(9, 0))))
        // Off: nothing.
        #expect(DigestSchedule(enabled: false).decide(now: at(2, 9, 5), last: nil, historyStart: history, calendar: utc) == .wait)
    }

    @Test func catchesUpOnceAfterSleepInTheDaytime() {
        let schedule = DigestSchedule(), history = at(1, 0, month: 9)
        // Asleep at nine; the first wake Tuesday at 3 am waits for the morning, 7:30 sends.
        #expect(schedule.decide(now: at(3, 3), last: at(26, 9, month: 10), historyStart: history, calendar: utc) == .wait)
        #expect(schedule.decide(now: at(3, 7, 30), last: at(26, 9, month: 10), historyStart: history, calendar: utc) == .send(slot: at(2, 9), week: week))
        // Once.
        #expect(schedule.decide(now: at(3, 8), last: at(2, 9), historyStart: history, calendar: utc) == .wait)
        // Asleep for three weeks: only the latest week, and only within three days.
        #expect(schedule.decide(now: at(17, 10), last: at(26, 9, month: 10), historyStart: history, calendar: utc)
                == .send(slot: at(16, 9), week: DateInterval(start: at(9, 0), end: at(16, 0))))
        #expect(schedule.decide(now: at(20, 10), last: at(26, 9, month: 10), historyStart: history, calendar: utc) == .skip(slot: at(16, 9), .stale))
    }

    @Test func neverTwoInARow() {
        let history = at(1, 0, month: 9)
        // Sent Monday, then the day changed to Wednesday: Wednesday's is skipped, the next one goes out.
        let wednesday = DigestSchedule(weekday: 4, hour: 9)
        #expect(wednesday.decide(now: at(4, 9, 5), last: at(2, 9), historyStart: history, calendar: utc) == .skip(slot: at(4, 9), .tooSoon))
        #expect(wednesday.decide(now: at(11, 9, 5), last: at(4, 9), historyStart: history, calendar: utc)
                == .send(slot: at(11, 9), week: DateInterval(start: at(4, 0), end: at(11, 0))))
    }

    @Test func skipsTheFirstWeek() {
        let schedule = DigestSchedule()
        // Installed Wednesday: the Monday after has only five days.
        #expect(schedule.decide(now: at(2, 9, 5), last: nil, historyStart: at(28, 14, month: 10), calendar: utc) == .skip(slot: at(2, 9), .firstWeek))
        #expect(schedule.decide(now: at(2, 9, 5), last: nil, historyStart: nil, calendar: utc) == .skip(slot: at(2, 9), .firstWeek))
        // A week later it has the whole week.
        #expect(schedule.decide(now: at(9, 9, 5), last: at(2, 9), historyStart: at(28, 14, month: 10), calendar: utc)
                == .send(slot: at(9, 9), week: DateInterval(start: at(2, 0), end: at(9, 0))))
        // Set up that Monday morning still counts.
        #expect(schedule.decide(now: at(2, 9, 5), last: nil, historyStart: at(26, 8, month: 10), calendar: utc) == .send(slot: at(2, 9), week: week))
        var input = DigestInput()
        input.usage = [usage(at(28, 14, month: 10), gb: 2)]
        #expect(digest(input).partial)
    }

    @Test func otherDaysAndHours() {
        let sunday = DigestSchedule(weekday: 1, hour: 18)
        #expect(sunday.slot(atOrBefore: at(2, 9), calendar: utc) == at(1, 18))
        #expect(DigestSchedule.week(for: at(1, 18), calendar: utc) == DateInterval(start: at(25, 0, month: 10), end: at(1, 0)))
        #expect(DigestSchedule.week(for: at(2, 9), weeksAgo: 2, calendar: utc) == DateInterval(start: at(12, 0, month: 10), end: at(19, 0, month: 10)))
    }

    @Test func scheduleSettingsRoundTrip() {
        let defaults = UserDefaults(suiteName: "digest-tests-\(UUID().uuidString)")!
        #expect(DigestSchedule.load(defaults) == DigestSchedule())
        DigestSchedule(enabled: false, weekday: 6, hour: 17).save(defaults)
        #expect(DigestSchedule.load(defaults) == DigestSchedule(enabled: false, weekday: 6, hour: 17))
        defaults.set(42, forKey: DigestSchedule.hourKey)
        #expect(DigestSchedule.load(defaults).hour == 9)
    }

    // MARK: Ledger

    @Test func theLedgerKeepsADayAfterTheFilterForgetsIt() {
        let day = at(27, 10, month: 10)
        let events = (0..<3).map { FilterEvent(date: day.addingTimeInterval(Double($0) * 60), app: "node", endpoint: "x.example:443", direction: "outgoing", reason: "",
                                               protection: ProtectionDetail(kind: .malware, list: "URLhaus", host: "x.example", agent: $0 == 0 ? "Codex" : nil)) }
            + [FilterEvent(date: day, app: "com.example.App", endpoint: "t.example:443", direction: "outgoing", reason: "", protection: ProtectionDetail(kind: .tracker, list: "HaGeZi", host: "t.example")),
               FilterEvent(date: day, app: "com.example.App", endpoint: "r.example:443", direction: "outgoing", reason: "App block rule")]
        var ledger = DigestLedger()
        let changed = ledger.record(events, now: day, calendar: utc)
        #expect(changed)
        #expect(ledger.days["2026-10-27"] == .init(threats: 3, trackers: 1, agentGuard: 0, agents: 1))
        // The same log again counts nothing twice; a log that has forgotten some keeps the day's count.
        let again = ledger.record(events, now: day, calendar: utc)
        #expect(!again)
        ledger.record(Array(events.prefix(1)), now: day, calendar: utc)
        #expect(ledger.days["2026-10-27"]?.threats == 3)
        #expect(ledger.counts(in: week, calendar: utc)[1].threats == 3)
        // Old days go.
        ledger.record([], now: day.addingTimeInterval(70 * 86_400), calendar: utc)
        #expect(ledger.days.isEmpty)
    }

    // MARK: Command line

    @Test func parsesWeekOptions() throws {
        #expect(try WeekOptions.parse(["week"]) == WeekOptions())
        #expect(try WeekOptions.parse(["week", "--json"]) == WeekOptions(json: true))
        #expect(try WeekOptions.parse(["week", "--weeks-ago", "2", "--json"]) == WeekOptions(json: true, weeksAgo: 2))
        for bad in [["week", "--weeks-ago"], ["week", "--weeks-ago", "13"], ["week", "--weeks-ago", "-1"], ["week", "--weeks-ago", "two"], ["week", "--free"], ["week", "last"]] {
            #expect(throws: DiagnosticError.self) { try WeekOptions.parse(bad) }
        }
        #expect(WeekOptions(weeksAgo: 1).week(schedule: DigestSchedule(), now: at(4, 12), calendar: utc) == DateInterval(start: at(19, 0, month: 10), end: at(26, 0, month: 10)))
    }

    @Test func encodesForScripts() throws {
        let digest = digest(busy())
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .sortedKeys
        let object = try JSONSerialization.jsonObject(with: encoder.encode(digest)) as! [String: Any]
        #expect(object["calm"] as? Bool == false && (object["facts"] as? [[String: Any]])?.first?["topic"] as? String == "outages")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(digest)
        #expect(try encoder.encode(decoder.decode(WeeklyDigest.self, from: data)) == data)
    }
}
