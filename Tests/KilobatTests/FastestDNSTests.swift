import Foundation
import Testing
@testable import KilobatCore

/// Fastest DNS on synthetic runs: the decision rule and its hysteresis, the CDN penalty, the guards, the watchdog,
/// when runs happen, the command line and the helper's request.
struct FastestDNSTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// 4 January 2027 at `hour`:00 UTC, `day` days later.
    private func at(_ day: Int, _ hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2027, month: 1, day: 4, hour: hour))!.addingTimeInterval(Double(day) * 86_400)
    }
    /// A resolver's part of a run: ten first lookups around `ms` (p90 a little higher), repeats at half.
    private func resolver(_ id: String, _ ms: Double, failures: Int = 0, rewrites: Bool = false, cdn: Double? = nil, spread: Double = 4) -> DNSResolverRun {
        let first = (0..<10).map { ms + Double($0 % 5) * spread / 4 - spread / 2 }
        return DNSResolverRun(id: id, server: id == "network" ? "192.168.1.1" : "1.1.1.1", firstMs: Array(first.dropLast(failures)), repeatMs: first.map { $0 / 2 },
                              queries: 20, failures: failures, rewritesMissing: rewrites, cdnExcessMs: cdn)
    }
    private func run(_ day: Int, hour: Int = 10, network: Double, _ others: [(String, Double)], cdn: [String: Double] = [:]) -> DNSRun {
        DNSRun(date: at(day, hour), resolvers: [resolver("network", network)] + others.map { resolver($0.0, $0.1, cdn: cdn[$0.0]) })
    }
    private func decide(_ runs: [DNSRun], incumbent: String = "network", excluded: Set<String> = [], now: Date? = nil) -> FastestDNS.Verdict {
        FastestDNS.decide(runs: runs, incumbent: incumbent, excluded: excluded, now: now ?? (runs.map(\.date).max() ?? at(0)).addingTimeInterval(60), calendar: calendar)
    }

    // MARK: The decision rule

    @Test func clearWinnerOnThreeDaysIsPicked() {
        let runs = (0..<3).map { run($0, network: 48, [("cloudflare", 14), ("quad9", 12), ("google", 19)]) }
        let verdict = decide(runs)
        #expect(verdict.state == .faster && verdict.choice == "quad9")
        #expect(verdict.choiceMs.map { abs($0 - 12) < 2 } == true && verdict.networkMs.map { abs($0 - 48) < 2 } == true)
        #expect(FastestDNS.headline(verdict) == "Fastest here: Quad9 (12 ms vs your network’s 48 ms)")
    }

    @Test func twoDaysAreStillLearning() {
        // Three runs, but on two days: not enough.
        let runs = [run(0, network: 48, [("quad9", 12)]), run(0, hour: 16, network: 48, [("quad9", 12)]), run(1, network: 48, [("quad9", 12)])]
        let verdict = decide(runs)
        #expect(verdict.state == .learning && verdict.choice == "network" && verdict.days == 2 && verdict.leader == "quad9")
        #expect(FastestDNS.headline(verdict)?.hasPrefix("So far Quad9 at 12 ms · 2 of 3 days") == true)
    }

    @Test func aSmallLeadKeepsTheNetworksOwn() {
        // 15 ms faster isn't clearly faster.
        let verdict = decide((0..<5).map { run($0, network: 30, [("cloudflare", 15)]) })
        #expect(verdict.state == .network && verdict.choice == "network")
    }

    @Test func aWorseP90KeepsTheNetworksOwn() {
        // Faster at the median but with a long tail: not better.
        let runs = (0..<4).map { day in
            DNSRun(date: at(day), resolvers: [resolver("network", 50, spread: 2), resolver("cloudflare", 30, spread: 50)])
        }
        let verdict = decide(runs)
        #expect(runs[0]["cloudflare"]!.p90! > runs[0]["network"]!.p90!)
        #expect(verdict.choice == "network")
    }

    @Test func oneLosingRunBreaksTheStreak() {
        // Wins on days 0, 1 and 3, loses on day 2: the streak back from day 3 is one day.
        let runs = [run(0, network: 48, [("quad9", 12)]), run(1, network: 48, [("quad9", 12)]), run(2, network: 20, [("quad9", 25)]), run(3, network: 48, [("quad9", 12)])]
        #expect(decide(runs).choice == "network")
        // Two more winning days make three in a row.
        #expect(decide(runs + [run(4, network: 48, [("quad9", 12)]), run(5, network: 48, [("quad9", 12)])]).choice == "quad9")
    }

    @Test func hysteresisKeepsAPickThatIsStillAhead() {
        // Quad9 won; later it's only 5 ms ahead. Not enough to enter, enough to stay.
        let later = (3..<8).map { run($0, network: 25, [("quad9", 20)]) }
        let verdict = decide(later, incumbent: "quad9")
        #expect(verdict.state == .faster && verdict.choice == "quad9")
        // Without the incumbent it would never have been picked.
        #expect(decide(later).choice == "network")
    }

    @Test func aPickBehindOnThreeDaysGoesBack() {
        let behind = (0..<3).map { run($0, network: 20, [("quad9", 24)]) }
        #expect(decide(behind, incumbent: "quad9").choice == "network")
        // Behind on two days only: it stays.
        #expect(decide(Array(behind.prefix(2)) + [run(2, network: 30, [("quad9", 24)])], incumbent: "quad9").choice == "quad9")
    }

    @Test func noFlappingAroundTheMargin() {
        // Alternating 19 and 21 ms leads over two weeks: one decision, and it holds.
        let runs = (0..<14).map { run($0, network: 40, [("cloudflare", $0 % 2 == 0 ? 21 : 19)]) }
        var choice = "network", changes = 0
        for count in 1...runs.count {
            let next = decide(Array(runs.prefix(count)), incumbent: choice).choice
            if next != choice { changes += 1; choice = next }
        }
        #expect(changes <= 1)
    }

    @Test func aChallengerMustBeatTheCurrentPickNotJustTheNetwork() {
        // Google is 10 ms faster than Quad9, the current pick: not a clear win, so Quad9 stays.
        let runs = (0..<4).map { run($0, network: 60, [("quad9", 25), ("google", 15)]) }
        #expect(decide(runs, incumbent: "quad9").choice == "quad9")
        // 25 ms faster than the pick is.
        #expect(decide((0..<4).map { run($0, network: 60, [("quad9", 40), ("google", 15)]) }, incumbent: "quad9").choice == "google")
    }

    @Test func excludedResolversAreNeverPicked() {
        let runs = (0..<3).map { run($0, network: 48, [("quad9", 12), ("cloudflare", 14)]) }
        #expect(decide(runs, excluded: ["quad9"]).choice == "cloudflare")
        #expect(decide(runs, excluded: ["quad9", "cloudflare"]).choice == "network")
        // An incumbent the person excludes goes at once.
        #expect(decide(runs, incumbent: "quad9", excluded: ["quad9", "cloudflare"]).choice == "network")
    }

    @Test func anUnreliablePickGoesAtOnce() {
        var runs = (0..<3).map { run($0, network: 48, [("quad9", 12)]) }
        runs.append(DNSRun(date: at(3), resolvers: [resolver("network", 48), resolver("quad9", 12, failures: 5)]))
        #expect(decide(runs, incumbent: "quad9").choice == "network")
        // A resolver that rewrites missing names is never picked, however fast.
        let rewriting = (0..<3).map { DNSRun(date: at($0), resolvers: [resolver("network", 48), resolver("quad9", 5, rewrites: true)]) }
        #expect(decide(rewriting).choice == "network")
    }

    @Test func oldRunsDontCount() {
        let old = (0..<3).map { run($0, network: 48, [("quad9", 12)]) }
        #expect(decide(old, now: at(40)).state == .learning)
    }

    @Test func networkRewritingIsReported() {
        let runs = [DNSRun(date: at(0), resolvers: [resolver("network", 30, rewrites: true), resolver("quad9", 25)])]
        #expect(decide(runs).networkRewrites)
    }

    // MARK: CDN answers

    @Test func cdnExcessIsTheMedianPerName() {
        let candidate = ["a": 40.0, "b": 12, "c": 60], network = ["a": 10.0, "b": 12, "c": 15]
        #expect(FastestDNS.cdnExcess(candidate: candidate, network: network) == 30)
        // Names only one side answered don't count; same addresses, no difference.
        #expect(FastestDNS.cdnExcess(candidate: ["a": 10], network: ["b": 10]) == nil)
        #expect(FastestDNS.cdnExcess(candidate: network, network: network) == 0)
    }

    @Test func farCDNAnswersArePenalisedPerRoundTrip() {
        #expect(FastestDNS.cdnPenalty(excess: nil) == 0)
        #expect(FastestDNS.cdnPenalty(excess: 8) == 0)
        #expect(FastestDNS.cdnPenalty(excess: 30) == 90)
    }

    @Test func fasterLookupsWithFarCDNsLose() {
        // Google answers 25 ms faster but sends you to a CDN node 30 ms further: 90 ms worse per connection.
        let runs = (0..<4).map { run($0, network: 45, [("google", 20), ("quad9", 22)], cdn: ["google": 30, "quad9": 2]) }
        let verdict = decide(runs)
        #expect(verdict.choice == "quad9" && verdict.penalized == ["google"])
        // Without the penalty Google would have won.
        #expect(decide((0..<4).map { run($0, network: 45, [("google", 20), ("quad9", 22)]) }).choice == "google")
    }

    @Test func meterComparesCDNAddressesAgainstTheNetworksOwn() async {
        let probe = FakeProbe(lookups: ["192.168.1.1": 40, "9.9.9.9": 12, "8.8.8.8": 10],
                              cdn: ["192.168.1.1": "10.0.0.1", "9.9.9.9": "10.0.0.1", "8.8.8.8": "10.9.9.9"],
                              connects: ["10.0.0.1": 8, "10.9.9.9": 48])
        let candidates = [DNSResolverChoice.network, .quad9, .google]
        let result = await FastestDNSMeter.run(candidates: candidates, networkServers: ["192.168.1.1"], probe: probe, date: at(0), missingName: "nx.example", pause: .zero)
        #expect(result.resolvers.map(\.id) == ["network", "quad9", "google"])
        #expect(result["quad9"]?.cdnExcessMs == 0 && result["google"]?.cdnExcessMs == 40 && result["network"]?.cdnExcessMs == nil)
        #expect(result["quad9"]?.firstMs.count == 10 && result["quad9"]?.repeatMs.count == 10 && result["quad9"]?.queries == 20)
        #expect(result["google"]?.penaltyMs == 120)
    }

    @Test func meterCatchesRewrittenMissingNames() async {
        let probe = FakeProbe(lookups: ["192.168.1.1": 30, "1.1.1.1": 20], rewriting: ["192.168.1.1"])
        let result = await FastestDNSMeter.run(candidates: [.network, .cloudflare], networkServers: ["192.168.1.1"], probe: probe, date: at(0), missingName: "nx.example", pause: .zero)
        #expect(result["network"]?.rewritesMissing == true && result["cloudflare"]?.rewritesMissing == false)
        // Without the network's servers there's nothing to ask for it.
        let none = await FastestDNSMeter.run(candidates: [.network, .cloudflare], networkServers: [], probe: probe, date: at(0), missingName: "nx.example", pause: .zero)
        #expect(none.resolvers.map(\.id) == ["cloudflare"])
    }

    // MARK: When to measure

    @Test func meteredHotspotsAreNeverMeasured() {
        #expect(FastestDNS.wait(.init(network: "phone", metered: true), runs: []) == .metered)
        #expect(FastestDNS.wait(.init(network: "home"), runs: []) == nil)
    }

    @Test func runsWaitForTheRightMoment() {
        #expect(FastestDNS.wait(.init(network: nil), runs: []) == .network)
        #expect(FastestDNS.wait(.init(network: "home", identified: false), runs: []) == .network)
        #expect(FastestDNS.wait(.init(network: "home", vpn: true), runs: []) == .vpn)
        #expect(FastestDNS.wait(.init(network: "cafe", portal: true), runs: []) == .portal)
        #expect(FastestDNS.wait(.init(network: "home", busy: true), runs: []) == .busy)
        #expect(FastestDNS.wait(.init(network: "home", lowPower: true), runs: []) == .lowPower)
        let now = at(1, 20)
        #expect(FastestDNS.wait(.init(network: "home"), runs: [run(1, hour: 18, network: 30, [])], now: now) == .recent)
        let three = [run(1, hour: 2, network: 30, []), run(1, hour: 8, network: 30, []), run(1, hour: 14, network: 30, [])]
        #expect(FastestDNS.wait(.init(network: "home"), runs: three, now: now) == .enough)
        #expect(FastestDNS.wait(.init(network: "home"), runs: Array(three.prefix(2)), now: now) == nil)
    }

    // MARK: Guards

    private var faster: FastestDNS.Verdict { decide((0..<3).map { run($0, network: 48, [("quad9", 12)]) }) }
    private func applied(_ resolver: String = "quad9", network: String = "home") -> DNSApplied {
        DNSApplied(network: network, networkName: "Home", service: "Wi-Fi", resolver: resolver, servers: DNSResolverChoice.from(id: resolver)!.servers, gateway: "192.168.1.1", date: at(3))
    }
    /// Everything allowing a switch at home, with the given differences. Plain arguments, since #expect can't take
    /// closures that change their argument.
    private func situation(network: String? = "home", enabled: Bool = true, pro: Bool = true, helper: Bool = true, vpn: Bool = false,
                           managed: Bool = false, portal: Bool = false, verdict: FastestDNS.Verdict? = nil, failed: Set<String> = [],
                           applied: DNSApplied? = nil, serviceServers: [String] = []) -> FastestDNS.Situation {
        FastestDNS.Situation(network: network, enabled: enabled, pro: pro, helper: helper, vpn: vpn, managed: managed, portal: portal,
                             serviceServers: serviceServers, applied: applied, verdict: verdict ?? faster, failed: failed)
    }

    @Test func switchesWhenEverythingAllows() {
        #expect(FastestDNS.plan(situation()) == .apply(.quad9))
        #expect(FastestDNS.plan(situation(applied: applied(), serviceServers: DNSResolverChoice.quad9.servers)) == .hold(.applied))
    }

    @Test func aVPNGetsItsOwnDNS() {
        #expect(FastestDNS.plan(situation(vpn: true)) == .hold(.vpn))
        #expect(FastestDNS.plan(situation(vpn: true, applied: applied(), serviceServers: DNSResolverChoice.quad9.servers)) == .revert(.vpn))
    }

    @Test func aSignInPageGetsTheNetworksDNS() {
        #expect(FastestDNS.plan(situation(portal: true)) == .hold(.portal))
        #expect(FastestDNS.plan(situation(portal: true, applied: applied(), serviceServers: DNSResolverChoice.quad9.servers)) == .revert(.portal))
    }

    @Test func aProfileManagesDNS() {
        #expect(FastestDNS.plan(situation(managed: true)) == .hold(.profile))
        #expect(FastestDNS.plan(situation(managed: true, applied: applied(), serviceServers: DNSResolverChoice.quad9.servers)) == .revert(.profile))
    }

    @Test func dnsThePersonSetIsNeverTouched() {
        #expect(FastestDNS.plan(situation(serviceServers: ["94.140.14.14"])) == .hold(.ownDNS))
        // Changed by someone else since Kilobat switched: Kilobat forgets its change and touches nothing.
        #expect(FastestDNS.plan(situation(applied: applied(), serviceServers: ["94.140.14.14"])) == .forget)
        #expect(FastestDNS.plan(situation(applied: applied(), serviceServers: [])) == .forget)
    }

    @Test func anotherNetworkGetsItsOwnDNSBack() {
        #expect(FastestDNS.plan(situation(network: "cafe", applied: applied(), serviceServers: DNSResolverChoice.quad9.servers)) == .revert(.leftNetwork))
        #expect(FastestDNS.plan(situation(network: nil, applied: applied(), serviceServers: DNSResolverChoice.quad9.servers)) == .revert(.leftNetwork))
    }

    @Test func offProAndHelperGates() {
        #expect(FastestDNS.plan(situation(enabled: false)) == .hold(.off))
        #expect(FastestDNS.plan(situation(pro: false)) == .hold(.pro))
        #expect(FastestDNS.plan(situation(helper: false)) == .hold(.needsHelper))
        #expect(FastestDNS.plan(situation(enabled: false, applied: applied(), serviceServers: DNSResolverChoice.quad9.servers)) == .revert(.off))
        #expect(FastestDNS.plan(situation(verdict: decide([run(0, network: 48, [("quad9", 12)])]))) == .hold(.learning))
    }

    @Test func theNetworksOwnCatchingUpSwitchesBack() {
        let network = decide((0..<3).map { run($0, network: 20, [("quad9", 24)]) }, incumbent: "quad9")
        #expect(FastestDNS.plan(situation(verdict: network, applied: applied(), serviceServers: DNSResolverChoice.quad9.servers)) == .revert(.networkFaster))
        #expect(FastestDNS.plan(situation(verdict: network)) == .hold(.networkBest))
        #expect(FastestDNS.plan(situation(failed: ["quad9"])) == .hold(.failedRecently))
    }

    // MARK: Watchdog

    @Test func watchdogRevertsAfterTwoFailedChecks() {
        var dog = FastestDNS.Watchdog()
        // Each check's answer, in order (a mutating call can't sit inside #expect).
        let checks: [(lookup: Bool, resolver: Bool?)] = [(false, false), (false, false), (false, nil), (true, nil), (false, nil)]
        let reverts = checks.map { dog.observe(applied: true, lookupWorked: $0.lookup, resolverAnswered: $0.resolver, networkUp: true) }
        // The second failure in a row reverts; a success in between starts over.
        #expect(reverts == [false, true, false, false, false])
    }

    @Test func watchdogIgnoresANetworkThatIsDown() {
        var dog = FastestDNS.Watchdog()
        let down = (0..<5).map { _ in dog.observe(applied: true, lookupWorked: false, resolverAnswered: nil, networkUp: false) }
        #expect(!down.contains(true))
        // And there's nothing to watch while Kilobat hasn't switched.
        let off = (0..<5).map { _ in dog.observe(applied: false, lookupWorked: false, resolverAnswered: false, networkUp: true) }
        #expect(!off.contains(true))
    }

    @MainActor @Test func watchSwitchesThenWatchdogRevertsAndPausesTheResolver() async throws {
        let system = FakeSystem()
        let applier = FakeApplier(system: system)
        let watch = FastestDNSWatch(directory: nil, system: system, probe: FakeProbe(lookups: [:]), calendar: calendar)
        var preferences = SavedPreferences(); preferences.setFastestDNS(true, network: nil)
        // Four days of runs at home already: Quad9 is clearly faster.
        var record = DNSNetworkRecord(network: "home", name: "Home", lastSeen: at(3))
        record.runs = (0..<4).map { run($0, network: 48, [("quad9", 12)]) }
        watch.preview(record)
        watch.allowed = { true }; watch.preferences = { preferences }; watch.applier = applier
        var logged: [DNSSwitch.Reason] = []
        watch.onSwitch = { logged.append($0.reason) }

        let now = at(3, 12)
        await watch.observe(context(lookupWorked: true), now: now)
        #expect(system.servers == DNSResolverChoice.quad9.servers && watch.applied?.resolver == "quad9" && logged == [.fastest])

        // Lookups fail twice while the router answers: back to automatic, and Quad9 waits a day here.
        await watch.observe(context(lookupWorked: false), now: now.addingTimeInterval(60))
        #expect(watch.applied != nil)
        await watch.observe(context(lookupWorked: false), now: now.addingTimeInterval(120))
        #expect(system.servers.isEmpty && watch.applied == nil && logged == [.fastest, .watchdog])
        #expect(watch.record?.failed(at: now.addingTimeInterval(180)).contains("quad9") == true)
        await watch.observe(context(lookupWorked: true), now: now.addingTimeInterval(180))
        #expect(system.servers.isEmpty && watch.hold == .failedRecently)

        // A day later it may switch again.
        await watch.observe(context(lookupWorked: true), now: now.addingTimeInterval(86_400 + 300))
        #expect(watch.applied?.resolver == "quad9")
    }

    @MainActor @Test func watchPutsDNSBackForAVPNAndOnUndo() async throws {
        let system = FakeSystem()
        let applier = FakeApplier(system: system)
        let watch = FastestDNSWatch(directory: nil, system: system, probe: FakeProbe(lookups: [:]), calendar: calendar)
        var preferences = SavedPreferences(); preferences.setFastestDNS(true, network: nil)
        var record = DNSNetworkRecord(network: "home", name: "Home", lastSeen: at(3))
        record.runs = (0..<4).map { run($0, network: 48, [("quad9", 12)]) }
        watch.preview(record)
        watch.allowed = { true }; watch.preferences = { preferences }; watch.applier = applier
        watch.disable = { preferences.setFastestDNS(false, network: $0) }
        let now = at(3, 12)
        await watch.observe(context(lookupWorked: true), now: now)
        #expect(watch.applied != nil)
        await watch.observe(context(lookupWorked: true, vpn: true), now: now.addingTimeInterval(60))
        #expect(watch.applied == nil && system.servers.isEmpty && watch.switches.last?.reason == .vpn)
        await watch.observe(context(lookupWorked: true), now: now.addingTimeInterval(120))
        #expect(watch.applied != nil)
        await watch.undo()
        #expect(watch.applied == nil && system.servers.isEmpty && preferences.fastestDNSEnabled(on: "home") == false)
        await watch.observe(context(lookupWorked: true), now: now.addingTimeInterval(180))
        #expect(watch.applied == nil && watch.hold == .off)
    }

    private func context(lookupWorked: Bool, vpn: Bool = false) -> FastestDNSWatch.Context {
        FastestDNSWatch.Context(network: "home", name: "Home", service: "Wi-Fi", interface: "en0", gateway: "192.168.1.1", resolvers: ["192.168.1.1"],
                                lookupWorked: lookupWorked, networkUp: true,
                                // Busy keeps the watch from starting a run of its own mid-test.
                                moment: .init(network: "home", vpn: vpn, busy: true))
    }

    // MARK: Parsing

    @Test func digAnswersAreRead() {
        let output = """
        ;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 25657
        ;; flags: qr rd ra; QUERY: 1, ANSWER: 4, AUTHORITY: 0, ADDITIONAL: 1

        ;; ANSWER SECTION:
        www.apple.com.\t\t265\tIN\tCNAME\twww-apple-com.v.aaplimg.com.
        e6858.dsce9.akamaiedge.net. 5\tIN\tA\t23.14.136.246

        ;; Query time: 58 msec
        """
        let lookup = DNSLookup.parse(dig: output)
        #expect(lookup == DNSLookup(ms: 58, status: "NOERROR", addresses: ["23.14.136.246"]) && lookup.answered)
        let missing = DNSLookup.parse(dig: ";; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 1\n;; Query time: 20 msec\n")
        #expect(missing.status == "NXDOMAIN" && !missing.answered)
        #expect(DNSLookup.parse(dig: ";; connection timed out; no servers could be reached", exitStatus: 9) == DNSLookup(ms: nil, status: nil))
    }

    @Test func dhcpServersAreRead() {
        #expect(SystemDNS.dhcpServers("yiaddr = 192.168.1.61\ndomain_name_server (ip_mult): {192.168.1.1, 192.168.1.2}\n") == ["192.168.1.1", "192.168.1.2"])
        #expect(SystemDNS.dhcpServers("nothing here").isEmpty)
    }

    @Test func commandLineIsParsed() throws {
        #expect(try FastestDNSCommand.parse(["fastest"]) == .fastest(all: false, json: false))
        #expect(try FastestDNSCommand.parse(["fastest", "--json", "--all"]) == .fastest(all: true, json: true))
        #expect(try FastestDNSCommand.parse(["auto", "on"]) == .auto(on: true, network: nil, json: false))
        #expect(try FastestDNSCommand.parse(["auto", "off", "--network", "Café Wi-Fi"]) == .auto(on: false, network: "Café Wi-Fi", json: false))
        #expect(try FastestDNSCommand.parse(["auto", "--network", "Home", "on", "--json"]) == .auto(on: true, network: "Home", json: true))
        #expect(try FastestDNSCommand.parse(["exclude", "google"]) == .exclude(.google))
        #expect(try FastestDNSCommand.parse(["include", "9.9.9.9"]) == .include(.quad9))
        #expect(try FastestDNSCommand.parse(["include", "94.140.14.14"]) == .include(DNSResolverChoice(id: "custom:94.140.14.14", name: "94.140.14.14", servers: ["94.140.14.14"])))
        // Other dns commands aren't these.
        #expect(try FastestDNSCommand.parse([]) == nil)
        #expect(try FastestDNSCommand.parse(["quad9"]) == nil)
        for bad in [["auto"], ["auto", "maybe"], ["auto", "on", "--network"], ["auto", "on", "--network", "--json"], ["fastest", "now"], ["exclude", "network"], ["exclude", "not-an-ip"], ["include"]] {
            #expect(throws: FastestDNSCommand.CommandError.self) { try FastestDNSCommand.parse(bad) }
        }
    }

    @Test func preferencesFollowTheCommands() {
        var preferences = SavedPreferences()
        #expect(!preferences.fastestDNSEnabled(on: "home"))
        preferences.setFastestDNS(true, network: nil)
        preferences.setFastestDNS(false, network: "cafe")
        #expect(preferences.fastestDNSEnabled(on: "home") && !preferences.fastestDNSEnabled(on: "cafe"))
        preferences.setDNSExcluded(.google, excluded: true)
        preferences.setDNSExcluded(DNSResolverChoice.custom("94.140.14.14")!, excluded: false)
        #expect(preferences.dnsCandidates().map(\.id) == ["network", "cloudflare", "quad9", "custom:94.140.14.14"])
        preferences.setDNSExcluded(DNSResolverChoice.custom("94.140.14.14")!, excluded: true)
        preferences.setDNSExcluded(.google, excluded: false)
        #expect(preferences.dnsExtra == nil && preferences.dnsExcluded == nil)
        // Turning it off everywhere clears the per-network ones too.
        preferences.setFastestDNS(false, network: nil)
        #expect(preferences.fastestDNS == nil && preferences.networkFastestDNS == nil)
    }

    // MARK: The helper and profiles

    @Test func helperRequestsAreOnlyEverDNSServers() {
        let services = DNSHelperRequest.services("An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n*Thunderbolt Bridge\nUSB 10/100/1000 LAN\n")
        #expect(services == ["Wi-Fi", "Thunderbolt Bridge", "USB 10/100/1000 LAN"])
        #expect(DNSHelperRequest(service: "Wi-Fi", servers: ["9.9.9.9", "2620:fe::fe"]).arguments(services: services) == ["-setdnsservers", "Wi-Fi", "9.9.9.9", "2620:fe::fe"])
        #expect(DNSHelperRequest(service: "Wi-Fi", servers: []).arguments(services: services) == ["-setdnsservers", "Wi-Fi", "Empty"])
        #expect(DNSHelperRequest(service: "Nope", servers: ["9.9.9.9"]).arguments(services: services) == nil)
        #expect(DNSHelperRequest(service: "Wi-Fi", servers: ["9.9.9.9; rm -rf /"]).arguments(services: services) == nil)
        #expect(DNSHelperRequest(service: "Wi-Fi", servers: ["-setairportpower"]).arguments(services: services) == nil)
        #expect(DNSHelperRequest(service: "-setairportpower", servers: []).arguments(services: services + ["-setairportpower"]) == nil)
        #expect(DNSHelperRequest(service: "Wi-Fi", servers: Array(repeating: "1.1.1.1", count: 5)).arguments(services: services) == nil)
        #expect(DNSHelperRequest.servers("There aren't any DNS Servers set on Wi-Fi.\n") == [])
        #expect(DNSHelperRequest.servers("1.1.1.1\n1.0.0.1\n") == ["1.1.1.1", "1.0.0.1"])
    }

    @Test func profilesAndDNSAppsAreFound() throws {
        func archive(_ objects: [Any]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["$archiver": "NSKeyedArchiver", "$objects": objects, "$top": [:], "$version": 100000], format: .binary, options: 0)
        }
        let none = try archive(["$null", ["DNSSettings": ["CF$UID": 0], "DNSProxy": ["CF$UID": 0], "Name": "Kilobat"]])
        #expect(!ManagedDNS.present(archive: none))
        let encrypted = try archive(["$null", ["DNSSettings": ["CF$UID": 2], "Name": "Profile"], ["ServerURL": "https://dns.example/dns-query"]])
        #expect(ManagedDNS.present(archive: encrypted))
        let off = try archive(["$null", ["DNSSettings": ["CF$UID": 2], "Enabled": false], ["ServerURL": "https://dns.example/dns-query"]])
        #expect(!ManagedDNS.present(archive: off))
        #expect(!ManagedDNS.present(archive: Data("not a plist".utf8)))
    }

    @Test func reportSaysWhatTheAppSaved() throws {
        var record = DNSNetworkRecord(network: "home", name: "Home", lastSeen: at(3))
        record.runs = (0..<3).map { run($0, network: 48, [("quad9", 12)]) }
        var preferences = SavedPreferences(); preferences.setFastestDNS(true, network: "home")
        let saved = FastestDNSWatch.Saved(current: "home", networks: [record], switches: [], applied: nil)
        let report = FastestDNSReport(saved: saved, preferences: preferences, current: nil, all: false, now: at(3), calendar: calendar)
        #expect(report.networks.count == 1 && report.networks[0].state == "faster" && report.networks[0].choice == "quad9" && report.networks[0].auto)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
        #expect(json?["applied"] is NSNull)
    }
}

/// Answers every lookup from a table: a server's time, its CDN address, and NXDOMAIN unless it rewrites.
private struct FakeProbe: DNSProbing {
    var lookups: [String: Double]
    var cdn: [String: String] = [:]
    var connects: [String: Double] = [:]
    var rewriting: Set<String> = []
    func lookup(_ name: String, server: String) async -> DNSLookup {
        guard let ms = lookups[server] else { return DNSLookup(ms: nil, status: nil) }
        if name == "nx.example" { return rewriting.contains(server) ? DNSLookup(ms: ms, status: "NOERROR", addresses: ["10.10.10.10"]) : DNSLookup(ms: ms, status: "NXDOMAIN") }
        if FastestDNS.cdnDomains.contains(name) { return DNSLookup(ms: ms, status: "NOERROR", addresses: [cdn[server] ?? "10.0.0.1"]) }
        return DNSLookup(ms: ms, status: "NOERROR", addresses: ["10.1.1.1"])
    }
    func connect(_ address: String) async -> Double? { connects[address] }
}

/// The Mac's DNS setting as a variable, shared with the fake applier.
private final class FakeSystem: DNSSystem, @unchecked Sendable {
    var servers: [String] = []
    func serviceServers(_ service: String) async -> [String] { servers }
    func dhcpServers(interface: String) async -> [String] { ["192.168.1.1"] }
    func managed() async -> Bool { false }
    func gateway() async -> String? { "192.168.1.1" }
}

@MainActor private final class FakeApplier: DNSApplying {
    let system: FakeSystem
    init(system: FakeSystem) { self.system = system }
    var available: Bool { true }
    func apply(servers: [String], service: String) async throws { system.servers = servers }
}
