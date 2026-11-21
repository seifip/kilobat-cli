import Foundation
import Testing
@testable import KilobatCore

/// Fix it's decisions, on made-up readings: nothing here touches a network.
struct FixItTests {
    private func radio(rssi: Int? = -55, noise: Int? = -92, interface: String? = "en0") -> RadioSample {
        RadioSample.basic(ssid: "Home", interface: interface, rssi: rssi, noise: noise, transmitMbps: 400, channel: 36, band: "5 GHz")
    }
    private func ping(_ ms: [Double], loss: Double? = 0) -> PingResult { PingResult(host: "x", samples: ms, lossPercent: loss) }
    private func snapshot(radio: RadioSample? = nil, gateway: String? = "192.168.1.1", router: [Double] = [3, 3], routerLoss: Double? = 0, internet: [Double] = [20, 21], loss: Double? = 0,
                          dns: Double? = 20, portal: Bool? = nil, wired: String? = nil, address: LinkAddressState? = nil) -> DiagnosticSnapshot {
        var value = DiagnosticSnapshot(date: Date(), radio: radio ?? self.radio(), gateway: gateway, router: ping(router, loss: routerLoss), internet: ping(internet, loss: loss), dnsMilliseconds: dns,
                                       dnsServers: ["192.168.1.1"], captivePortal: portal, networkService: "Wi-Fi")
        value.wiredInterface = wired
        value.radioAddress = address
        return value
    }
    private func cause(_ snapshot: DiagnosticSnapshot, _ edit: (inout FixSituation) -> Void = { _ in }) -> FixCause? {
        var situation = FixSituation(snapshot: snapshot); edit(&situation)
        return FixPlanner.cause(situation)
    }

    // MARK: Causes

    @Test func onlyAddressAndDNSFixesOfferTheHelper() {
        #expect(FixCause.wifiStuck.usesHelper && FixCause.dnsSlow.usesHelper && FixCause.dnsFailing.usesHelper)
        #expect(!FixCause.router.usesHelper && !FixCause.provider.usesHelper && !FixCause.signIn(place: nil).usesHelper)
    }
    @Test func theAirDropPauseRunsInItsOwnSession() {
        let command = LowLatencyHold.detached("echo 'hi'")
        #expect(command.contains("setsid") && !command.contains("nohup") && command.hasSuffix("2>&1 &"))
    }
    @MainActor @Test func theAgentPromptKeepsTheLimitsAndLeavesOutThePlace() {
        let actions = FixRunner.Actions(plan: { [] }, measure: { FixReading() }, apply: { _ in nil }, undo: { _ in }, wait: { _ in })
        let runner = FixRunner(cause: .signIn(place: "Hotel Example"), live: nil, actions: actions)
        let prompt = runner.agentPrompt(appVersion: "1.0", system: "macOS 27")
        #expect(prompt.contains("kilobat diagnose --json") && prompt.contains("Ask before changing anything") && prompt.contains("Never remove VPN profiles"))
        #expect(!prompt.contains("Hotel Example"))
    }
    @Test func noCauseOnAHealthyLine() { #expect(cause(snapshot()) == nil) }
    @Test func oneLostReplyDoesNotBlameTheProvider() {
        let saved = snapshot(internet: [20, 21, 22], loss: 25)
        var s = saved; s.secondary = ping([18, 19])
        #expect(cause(s) == nil)
        // A sample saved before the second target was kept is judged as it was then.
        #expect(cause(saved) == .provider)
    }
    @Test func aTargetThatDropsPingsIsNotAnOutage() {
        var s = snapshot(internet: [], loss: 100); s.secondary = ping([18, 19])
        #expect(cause(s) == nil)
        s.secondary = ping([], loss: 100); s.httpReachable = false
        #expect(cause(s) == .provider)
    }
    @Test func aVPNThatDropsPingsCanClear() {
        var s = snapshot(internet: [], loss: 100); s.secondary = ping([], loss: 100); s.httpReachable = true
        #expect(cause(s) { $0.vpn = .full } == nil)
        #expect(FixCause.vpnBroken(nil).metric(FixReading(s)).good == true)
        var dead = snapshot(internet: [], loss: 100, dns: nil); dead.secondary = ping([], loss: 100); dead.httpReachable = false
        #expect(cause(dead) { $0.vpn = .full } == .vpnBroken(nil))
        #expect(FixCause.vpnBroken(nil).metric(FixReading(dead)).good == false)
    }
    @Test func noCauseWithoutAReading() { #expect(FixPlanner.cause(FixSituation(snapshot: nil)) == nil) }
    @Test func signInComesFirst() {
        #expect(cause(snapshot(gateway: nil, dns: nil, portal: true)) { $0.portalPlace = "Hotel" } == .signIn(place: "Hotel"))
    }
    @Test func noAddressOnWiFi() {
        #expect(cause(snapshot(gateway: nil, router: [], internet: [], dns: nil)) == .wifiStuck)
        #expect(cause(snapshot(gateway: "169.254.1.1", router: [], internet: [], dns: nil)) == .wifiStuck)
        #expect(cause(snapshot(gateway: "link#12", router: [], internet: [], dns: nil)) == .wifiStuck)
    }
    @Test func anUnknownRouterWithAnAddressIsNoCause() {
        // The docked Mac behind a full-tunnel VPN: no router to name, but internet and lookups answer.
        #expect(cause(snapshot(gateway: nil, router: [], address: .assigned)) == nil)
    }
    @Test func aSelfAssignedAddressIsStuckWiFiWhateverTheRouter() {
        #expect(cause(snapshot(gateway: nil, router: [], internet: [], dns: nil, address: .selfAssigned)) == .wifiStuck)
        #expect(cause(snapshot(gateway: nil, router: [], internet: [], dns: nil, address: LinkAddressState.none)) == .wifiStuck)
        // The interface's own reading wins over a usable router address.
        #expect(cause(snapshot(address: .selfAssigned)) == .wifiStuck)
    }
    @Test func aDeadVPNOnADockedMacIsTheVPNNotTheWiFi() {
        let s = snapshot(gateway: nil, router: [], internet: [], loss: 100, dns: nil, address: .assigned)
        #expect(cause(s) { $0.vpn = .full; $0.vpnName = "Work" } == .vpnBroken("Work"))
    }
    @Test func offlineWithAnAddressAndNoRouterIsNoCause() {
        // IPv6-only Wi-Fi that is down: nothing Fix it can honestly try.
        #expect(cause(snapshot(gateway: nil, router: [], internet: [], loss: 100, dns: nil, address: .assigned)) == nil)
    }
    @Test func theWizardsReadingUsesTheInterface() {
        #expect(FixReading(snapshot(gateway: nil, address: .assigned)).hasAddress == true)
        #expect(FixReading(snapshot(gateway: "192.168.1.1", address: .selfAssigned)).hasAddress == false)
    }
    @Test func addressesClassify() {
        #expect(LinkAddressState.classify(ipv4: ["192.168.1.20"], routableIPv6: false) == .assigned)
        #expect(LinkAddressState.classify(ipv4: ["169.254.10.2"], routableIPv6: false) == .selfAssigned)
        #expect(LinkAddressState.classify(ipv4: [], routableIPv6: true) == .assigned)
        #expect(LinkAddressState.classify(ipv4: [], routableIPv6: false) == LinkAddressState.none)
        #expect(LinkAddressState.classify(ipv4: ["169.254.10.2", "10.0.0.5"], routableIPv6: false) == .assigned)
    }
    @Test func oldSamplesStillDecode() throws {
        let saved = try JSONDecoder().decode(DiagnosticSnapshot.self, from: JSONEncoder().encode(snapshot(address: .selfAssigned)))
        #expect(saved.radioAddress == .selfAssigned)
        let data = try JSONEncoder().encode(snapshot(address: nil))
        #expect(!String(decoding: data, as: UTF8.self).contains("radioAddress"))
        #expect(try JSONDecoder().decode(DiagnosticSnapshot.self, from: data).radioAddress == nil)
    }
    @Test func routerSilentAndNothingBeyondIsStuckWiFi() {
        #expect(cause(snapshot(router: [], routerLoss: 100, internet: [], loss: 100, dns: nil)) == .wifiStuck)
    }
    @Test func routerThatBlocksPingIsNotStuck() {
        #expect(cause(snapshot(router: [], routerLoss: 100)) == nil)
    }
    @Test func wiredIsNeverStuckWiFi() {
        #expect(cause(snapshot(radio: radio(rssi: nil), router: [], routerLoss: 100, internet: [], loss: 100, dns: nil, wired: "en5")) != .wifiStuck)
    }
    @Test func deadInternetBehindAWorkingRouter() {
        #expect(cause(snapshot(internet: [], loss: 100, dns: nil)) == .provider)
    }
    @Test func deadTunnelIsTheVPN() {
        #expect(cause(snapshot(internet: [], loss: 100, dns: nil)) { $0.vpn = .full; $0.vpnName = "Mullvad" } == .vpnBroken("Mullvad"))
        #expect(cause(snapshot(dns: nil)) { $0.vpn = .full; $0.vpnName = "Mullvad" } == .vpnBroken("Mullvad"))
    }
    @Test func dnsFailingAndSlow() {
        #expect(cause(snapshot(dns: nil)) == .dnsFailing)
        #expect(cause(snapshot(dns: 340)) == .dnsSlow)
        #expect(cause(snapshot(dns: 150)) == nil)
    }
    @Test func aVPNsSlowDNSIsNotForUsToChange() {
        #expect(cause(snapshot(dns: 340)) { $0.vpn = .partial } == nil)
        #expect(cause(snapshot(dns: nil)) { $0.vpn = .partial } == nil)
    }
    @Test func farNode() {
        let near = MeshNode(id: "aa", name: "Upstairs", radios: [], current: false), far = MeshNode(id: "bb", name: nil, radios: [], current: true)
        let stuck = StuckNode(since: Date(), node: far, better: near, rssi: -78, betterRSSI: -50, betterBand: "5 GHz", currentMbps: 20, betterMbps: 200)
        #expect(cause(snapshot()) { $0.stuck = stuck } == .farNode(better: "Upstairs"))
    }
    @Test func airDropOnlyDuringASession() {
        #expect(cause(snapshot()) { $0.airDropBusy = true } == nil)
        #expect(cause(snapshot()) { $0.airDropBusy = true; $0.live = .call("Zoom") } == .airDrop(.call("Zoom")))
    }
    @Test func uploadOnlyWhenTheLineSuffers() {
        #expect(cause(snapshot()) { $0.upload = ("k", "Dropbox") } == nil)
        #expect(cause(snapshot(internet: [240, 250])) { $0.upload = ("k", "Dropbox") } == .upload(key: "k", name: "Dropbox"))
        #expect(cause(snapshot(internet: [50, 120, 40, 130], dns: 340)) { $0.upload = ("k", "Dropbox") } == .upload(key: "k", name: "Dropbox"))
    }
    @Test func anOrdinaryWiFiRouterReadingIsNoCause() { #expect(cause(snapshot(router: [24, 26])) == nil) }
    @Test func routerAndProvider() {
        #expect(cause(snapshot()) { $0.routerSlowing = true } == .router)
        #expect(cause(snapshot(router: [60, 70])) == .router)
        #expect(cause(snapshot(internet: [240, 250])) == .provider)
        #expect(cause(snapshot(loss: 30)) == .provider)
    }
    @Test func weakSignalStaysWithRadar() {
        let weak = radio(rssi: -82, noise: -70)
        #expect(cause(snapshot(radio: weak, router: [60, 70])) == nil)
    }
    @Test func setupNetworkIsNoProblem() {
        var value = snapshot(internet: [], loss: 100, dns: nil)
        value.setupNetwork = SetupNetworkMatch(kind: .printer, maker: nil, rule: "test")
        #expect(cause(value) == nil)
    }

    // MARK: Plans

    @Test func wifiPlanKeepsPasswordsAway() {
        #expect(FixPlanner.steps(for: .wifiStuck, helper: false).map(\.action) == [.reconnectWiFi])
        #expect(FixPlanner.steps(for: .wifiStuck, helper: true).map(\.action) == [.renewAddress, .reconnectWiFi])
        #expect(FixPlanner.steps(for: .wifiStuck, helper: true).allSatisfy { !$0.asksPassword })
    }
    @Test func dnsAsksForPasswordOnlyWithoutHelper() {
        #expect(FixPlanner.steps(for: .dnsSlow, helper: false, dns: [.cloudflare])[0].asksPassword)
        #expect(!FixPlanner.steps(for: .dnsSlow, helper: true, dns: [.cloudflare])[0].asksPassword)
        #expect(FixPlanner.steps(for: .dnsSlow, helper: true, dns: [.cloudflare, .quad9, .google]).count == 2)
    }
    @Test func providerPlanIsHonest() { #expect(FixPlanner.steps(for: .provider, helper: true).isEmpty) }
    @Test func dnsCandidatesMustBeatWhatsInUse() {
        let timed: [(choice: DNSResolverChoice, ms: Double?)] = [(.cloudflare, 20), (.quad9, 310), (.google, nil), (.network, 5)]
        #expect(FixPlanner.dnsCandidates(inUse: ["192.168.1.1"], currentMs: 340, timed: timed) == [.cloudflare])
        // Failing DNS: anything that answers is worth trying, and the one already in use is left out.
        #expect(FixPlanner.dnsCandidates(inUse: ["1.1.1.1"], currentMs: nil, timed: timed) == [.quad9])
    }

    // MARK: Judging

    @Test func verdicts() {
        let before = FixReading(dnsMs: 340)
        #expect(FixJudge.verdict(.dnsSlow, before: before, after: FixReading(dnsMs: 30)) == .cleared)
        #expect(FixJudge.verdict(.dnsSlow, before: before, after: FixReading(dnsMs: 200)) == .better)
        #expect(FixJudge.verdict(.dnsSlow, before: before, after: FixReading(dnsMs: 300)) == .same)
        #expect(FixJudge.verdict(.dnsSlow, before: before, after: FixReading(dnsMs: 500)) == .worse)
        #expect(FixJudge.verdict(.dnsSlow, before: before, after: FixReading(dnsMs: nil)) == .worse)
        #expect(FixJudge.verdict(.dnsFailing, before: FixReading(dnsMs: nil), after: FixReading(dnsMs: 400)) == .better)
        #expect(FixJudge.verdict(.dnsFailing, before: FixReading(dnsMs: nil), after: FixReading(dnsMs: nil)) == .same)
    }
    @Test func signalVerdict() {
        let before = FixReading(stuckNode: true, rssi: -78)
        #expect(FixJudge.verdict(.farNode(better: nil), before: before, after: FixReading(stuckNode: false, rssi: -55)) == .cleared)
        #expect(FixJudge.verdict(.farNode(better: nil), before: before, after: FixReading(stuckNode: false, rssi: -70)) == .better)
        #expect(FixJudge.verdict(.farNode(better: nil), before: before, after: FixReading(stuckNode: true, rssi: -76)) == .same)
    }

    // MARK: The engine

    private var dnsSteps: [FixStep] { FixPlanner.steps(for: .dnsSlow, helper: true, dns: [.cloudflare, .google]) }
    private let bad = FixReading(dnsMs: 340), good = FixReading(dnsMs: 20), half = FixReading(dnsMs: 200)

    @Test func nothingIsTriedOnAGoodLine() {
        let engine = FixEngine(cause: .dnsSlow, steps: dnsSteps, baseline: good)
        #expect(engine.command == .finish(.noIssue))
    }
    @Test func fixedOnlyAfterSteadyReadings() {
        var engine = FixEngine(cause: .dnsSlow, steps: dnsSteps, baseline: bad)
        engine.applied()
        engine.measured(good)
        #expect(engine.command == .steady(dnsSteps[0], passed: 1))
        engine.measured(good)
        #expect(engine.command == .steady(dnsSteps[0], passed: 2))
        engine.measured(good)
        #expect(engine.command == .finish(.fixed))
        #expect(engine.kept == [dnsSteps[0]])
    }
    @Test func aFixThatDoesntLastIsUndone() {
        var engine = FixEngine(cause: .dnsSlow, steps: dnsSteps, baseline: bad)
        engine.applied()
        engine.measured(good)
        engine.measured(bad)
        #expect(engine.command == .undo(dnsSteps[0]))
        #expect(engine.decision == .undo)
        engine.undone()
        #expect(engine.command == .apply(dnsSteps[1]))
    }
    @Test func aFixThatPartlyLastsIsBetter() {
        var engine = FixEngine(cause: .dnsSlow, steps: Array(dnsSteps.prefix(1)), baseline: bad)
        engine.applied()
        engine.measured(good)
        engine.measured(half)
        #expect(engine.decision == .keep)
        #expect(engine.command == .finish(.better))
    }
    @Test func undoThenNextThenNotYourMac() {
        var engine = FixEngine(cause: .dnsSlow, steps: dnsSteps, baseline: bad)
        engine.applied(); engine.measured(bad)
        #expect(engine.command == .undo(dnsSteps[0]))
        engine.undone(); engine.applied(); engine.measured(FixReading(dnsMs: 500))
        #expect(engine.command == .undo(dnsSteps[1]))
        engine.undone()
        #expect(engine.command == .finish(.notYourMac(.provider)))
        #expect(engine.kept.isEmpty)
    }
    @Test func keptStepThenNextStepClears() {
        var engine = FixEngine(cause: .dnsSlow, steps: dnsSteps, baseline: bad)
        engine.applied(); engine.measured(half)
        #expect(engine.command == .apply(dnsSteps[1]))
        #expect(engine.reference == half)
        engine.applied(); engine.measured(good); engine.measured(good); engine.measured(good)
        #expect(engine.command == .finish(.fixed))
        #expect(engine.kept == dnsSteps)
    }
    @Test func nothingWorkingWithAHelpedStepIsBetter() {
        var engine = FixEngine(cause: .dnsSlow, steps: dnsSteps, baseline: bad)
        engine.applied(); engine.measured(half)
        engine.applied(); engine.measured(half)
        #expect(engine.command == .undo(dnsSteps[1]))
        engine.undone()
        #expect(engine.command == .finish(.better))
    }
    @Test func undoableStepsGetUndoneOthersDont() {
        var engine = FixEngine(cause: .wifiStuck, steps: FixPlanner.steps(for: .wifiStuck, helper: true), baseline: FixReading(hasAddress: false))
        engine.applied(); engine.measured(FixReading(hasAddress: false))
        #expect(engine.decision == .noEffect)
        #expect(engine.command == .apply(FixStep(id: 1, action: .reconnectWiFi)))
    }
    @Test func askBeforeDroppingWiFiDuringACall() {
        let steps = FixPlanner.steps(for: .wifiStuck, helper: false)
        var engine = FixEngine(cause: .wifiStuck, steps: steps, baseline: FixReading(hasAddress: false), live: .call("Zoom"))
        #expect(engine.command == .ask(steps[0], .call("Zoom")))
        engine.allowed()
        #expect(engine.command == .apply(steps[0]))
    }
    @Test func decliningSkipsTheStepAndClaimsNothing() {
        let steps = FixPlanner.steps(for: .wifiStuck, helper: false)
        var engine = FixEngine(cause: .wifiStuck, steps: steps, baseline: FixReading(hasAddress: false), live: .game(nil))
        engine.declined()
        #expect(engine.command == .finish(.stopped(nil)))
    }
    @Test func listeningNeverAsks() {
        let steps = FixPlanner.steps(for: .wifiStuck, helper: false)
        let engine = FixEngine(cause: .wifiStuck, steps: steps, baseline: FixReading(hasAddress: false), live: .listening)
        #expect(engine.command == .apply(steps[0]))
    }
    @Test func aRenewThatFailsMovesOnToReconnect() {
        let steps = FixPlanner.steps(for: .wifiStuck, helper: true)
        var engine = FixEngine(cause: .wifiStuck, steps: steps, baseline: FixReading(hasAddress: false))
        engine.failed("Old helper")
        #expect(engine.command == .apply(steps[1]))
    }
    @Test func nothingCouldRunSaysSo() {
        var engine = FixEngine(cause: .dnsSlow, steps: Array(dnsSteps.prefix(1)), baseline: bad)
        engine.failed("Password cancelled")
        #expect(engine.command == .finish(.stopped("Password cancelled")))
    }
    @Test func aPersonStepIsWaitedFor() {
        let steps = FixPlanner.steps(for: .signIn(place: nil), helper: false)
        var engine = FixEngine(cause: .signIn(place: nil), steps: steps, baseline: FixReading(portal: true))
        #expect(engine.command == .person(steps[0]))
        engine.acted()
        #expect(engine.command == .measure(steps[0], after: 0))
    }
    @Test func providerIsNotYourMacAtOnce() {
        let engine = FixEngine(cause: .provider, steps: [], baseline: FixReading(internetMs: 300))
        #expect(engine.command == .finish(.notYourMac(.provider)))
    }
    @Test func stepsAreCapped() {
        let many = (0..<5).map { FixStep(id: $0, action: .renewAddress) }
        #expect(FixEngine(cause: .wifiStuck, steps: many, baseline: FixReading(hasAddress: false)).steps.count == FixPolicy.mostSteps)
    }
    @Test func undoTokensOnlyForChanges() {
        #expect(FixAction.switchDNS(.cloudflare).undoable)
        #expect(FixAction.pauseAirDrop.undoable)
        #expect(!FixAction.reconnectWiFi.undoable)
        #expect(FixAction.reconnectWiFi.dropsWiFi && FixAction.closerNode.dropsWiFi && !FixAction.renewAddress.dropsWiFi)
    }
    @Test func aLockedButtonNeverSellsWhatsFree() {
        #expect(FixCause.signIn(place: nil).alreadyFree && FixCause.farNode(better: nil).alreadyFree && FixCause.airDrop(.call(nil)).alreadyFree)
        #expect(!FixCause.dnsSlow.alreadyFree && !FixCause.wifiStuck.alreadyFree && !FixCause.upload(key: "k", name: "n").alreadyFree && !FixCause.provider.alreadyFree)
    }
    @Test func accessIsOneSwitch() {
        #expect(FixPolicy.allowed(hasPro: true))
        #expect(FixPolicy.allowed(hasPro: false) == !FixPolicy.needsPro)
    }

    // MARK: The runner, on simulated readings

    @MainActor final class Bench {
        var readings: [FixReading]
        var applied: [FixAction] = [], undone: [FixUndo] = []
        var failing: Set<Int> = []
        var undoFails = false
        init(_ readings: [FixReading]) { self.readings = readings }
        func actions(steps: [FixStep], undo: FixUndo? = .dns(service: "Wi-Fi", previous: [], applied: [], tracked: true)) -> FixRunner.Actions {
            FixRunner.Actions(plan: { steps }, measure: { self.readings.count > 1 ? self.readings.removeFirst() : self.readings[0] }, apply: { step in
                self.applied.append(step.action)
                if self.failing.contains(step.id) { throw DiagnosticError("no") }
                return step.action.undoable ? undo : nil
            }, undo: { if self.undoFails { throw DiagnosticError("stuck") }; self.undone.append($0) }, wait: { _ in })
        }
    }

    @MainActor @Test func runsToFixedAndLogsOneLine() async {
        let bench = Bench([bad, good, good, good])
        let runner = FixRunner(cause: .dnsSlow, live: nil, actions: bench.actions(steps: dnsSteps))
        await runner.run()
        #expect(runner.outcome == .fixed)
        #expect(bench.applied == [dnsSteps[0].action])
        #expect(bench.undone.isEmpty)
        #expect(runner.log.count == 1 && runner.log[0].status == .kept)
        #expect(runner.undoable.count == 1)
        #expect(runner.before?.text == "340 ms" && runner.after?.good == true)
    }
    @MainActor @Test func undoesAndTriesNext() async {
        let bench = Bench([bad, bad, good, good, good])
        let runner = FixRunner(cause: .dnsSlow, live: nil, actions: bench.actions(steps: dnsSteps))
        await runner.run()
        #expect(runner.outcome == .fixed)
        #expect(bench.applied == dnsSteps.map(\.action))
        #expect(bench.undone.count == 1)
        #expect(runner.log.map(\.status) == [.undone, .kept])
    }
    @MainActor @Test func exhaustedIsNotYourMac() async {
        let bench = Bench([bad])
        let runner = FixRunner(cause: .dnsSlow, live: nil, actions: bench.actions(steps: dnsSteps))
        await runner.run()
        #expect(runner.outcome == .notYourMac(.provider))
        #expect(bench.undone.count == 2)
    }
    @MainActor @Test func alreadyFineTriesNothing() async {
        let bench = Bench([good])
        let runner = FixRunner(cause: .dnsSlow, live: nil, actions: bench.actions(steps: dnsSteps))
        await runner.run()
        #expect(runner.outcome == .noIssue)
        #expect(bench.applied.isEmpty)
    }
    @MainActor @Test func aFailedStepIsLogged() async {
        let bench = Bench([bad]); bench.failing = [0, 1]
        let runner = FixRunner(cause: .dnsSlow, live: nil, actions: bench.actions(steps: dnsSteps))
        await runner.run()
        #expect(runner.outcome == .stopped("no"))
        #expect(runner.log.map(\.status) == [.failed("no"), .failed("no")])
    }
    @MainActor @Test func undoPutsAKeptChangeBack() async {
        let bench = Bench([bad, good, good, good])
        let runner = FixRunner(cause: .dnsSlow, live: nil, actions: bench.actions(steps: dnsSteps))
        await runner.run()
        await runner.undo(runner.log[0])
        #expect(bench.undone.count == 1)
        #expect(runner.log[0].status == .undone)
        #expect(runner.undoable.isEmpty)
    }
    @MainActor @Test func stoppingPutsChangesBack() async {
        let bench = Bench([bad, half, half])
        var actions = bench.actions(steps: dnsSteps)
        // Stopped at the Wi-Fi question for the second step, with the first step kept.
        actions.plan = { [FixStep(id: 0, action: .switchDNS(.cloudflare)), FixStep(id: 1, action: .reconnectWiFi)] }
        let runner = FixRunner(cause: .dnsSlow, live: .call("Zoom"), actions: actions)
        let task = Task { await runner.run() }
        while true {
            if case .asking = runner.phase { break }
            await Task.yield()
        }
        runner.stop()
        await task.value
        #expect(runner.outcome == .stopped(nil))
        #expect(bench.undone.count == 1)
        #expect(runner.log.map(\.status) == [.undone])
    }
    @MainActor @Test func aFailedUndoStopsTheRunAndStaysRetryable() async {
        let bench = Bench([bad, bad, good, good, good]); bench.undoFails = true
        let runner = FixRunner(cause: .dnsSlow, live: nil, actions: bench.actions(steps: dnsSteps))
        await runner.run()
        #expect(runner.outcome == .stopped("stuck"))
        #expect(bench.applied == [dnsSteps[0].action])
        #expect(runner.log.map(\.status) == [.undoFailed("stuck")])
        #expect(runner.undoable.count == 1)
        bench.undoFails = false
        await runner.undo(runner.log[0])
        #expect(runner.log[0].status == .undone)
        #expect(runner.undoable.isEmpty)
        #expect(bench.undone.count == 1)
    }
    @MainActor @Test func aFailedUndoFromTheLogCanBeTriedAgain() async {
        let bench = Bench([bad, good, good, good])
        let runner = FixRunner(cause: .dnsSlow, live: nil, actions: bench.actions(steps: dnsSteps))
        await runner.run()
        #expect(runner.outcome == .fixed)
        bench.undoFails = true
        await runner.undo(runner.log[0])
        #expect(runner.log[0].status == .undoFailed("stuck"))
        #expect(runner.undoable.count == 1)
        bench.undoFails = false
        await runner.undo(runner.log[0])
        #expect(runner.log[0].status == .undone)
    }
    @MainActor @Test func stoppingReportsAChangeItCouldNotPutBack() async {
        let bench = Bench([bad, half, half]); bench.undoFails = true
        var actions = bench.actions(steps: dnsSteps)
        actions.plan = { [FixStep(id: 0, action: .switchDNS(.cloudflare)), FixStep(id: 1, action: .reconnectWiFi)] }
        let runner = FixRunner(cause: .dnsSlow, live: .call("Zoom"), actions: actions)
        let task = Task { await runner.run() }
        while true {
            if case .asking = runner.phase { break }
            await Task.yield()
        }
        runner.stop()
        await task.value
        #expect(runner.outcome == .stopped("stuck"))
        #expect(runner.log.first?.status == .undoFailed("stuck"))
        #expect(runner.log.first?.canUndo == true)
    }
    @Test func logNotesNameAFailedUndo() {
        var entry = FixLogEntry(id: 0, action: .switchDNS(.cloudflare), date: Date(), status: .undoFailed("stuck"), undo: .resumeAirDrop)
        #expect(entry.note == "Couldn’t undo: stuck")
        entry.status = .undoFailed(nil)
        #expect(entry.note == "Couldn’t undo")
        #expect(entry.canUndo)
        entry.undo = nil
        #expect(!entry.canUndo)
    }
    @MainActor @Test func theWiFiQuestionAndAPersonStepWaitForAnAnswer() async {
        let signedIn = FixReading(dnsMs: 20, portal: false)
        let bench = Bench([FixReading(portal: true), signedIn, signedIn, signedIn])
        let steps = FixPlanner.steps(for: .signIn(place: nil), helper: false)
        let runner = FixRunner(cause: .signIn(place: nil), live: nil, actions: bench.actions(steps: steps))
        let task = Task { await runner.run() }
        while runner.phase != .person(steps[0], acted: false) { await Task.yield() }
        #expect(bench.applied.isEmpty)
        runner.proceed()
        await task.value
        #expect(runner.outcome == .fixed)
        #expect(bench.applied == [.openSignIn])
    }
}
