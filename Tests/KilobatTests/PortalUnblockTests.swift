import Foundation
import Testing
@testable import KilobatCore

/// Fix it's sign-in step when this Mac's own DNS, encrypted DNS, VPN or Private Relay hides the Wi-Fi's page. Simulated
/// readings only: nothing here changes DNS or touches a network.
struct PortalUnblockTests {
    private func snapshot(gateway: String? = "10.0.0.1", router: [Double] = [3, 3], internet: [Double] = [], dns: Double? = nil, portal: Bool? = nil,
                          security: String? = "WPA2 Personal", wired: String? = nil) -> DiagnosticSnapshot {
        var radio = RadioSample.basic(ssid: "Hotel", interface: "en0", rssi: -55, noise: -92, transmitMbps: 400, channel: 36, band: "5 GHz")
        radio.security = security
        var value = DiagnosticSnapshot(date: Date(), radio: radio, gateway: gateway, router: PingResult(host: "r", samples: router, lossPercent: router.isEmpty ? 100 : 0),
                                       internet: PingResult(host: "i", samples: internet, lossPercent: internet.isEmpty ? 100 : 0), dnsMilliseconds: dns,
                                       dnsServers: ["1.1.1.1"], captivePortal: portal, networkService: "Wi-Fi")
        value.wiredInterface = wired
        return value
    }
    private let ownDNS = PortalBlockers(ownDNS: ["1.1.1.1", "1.0.0.1"])
    private func cause(_ snapshot: DiagnosticSnapshot, blockers: PortalBlockers, seen: Bool = true, vpn: ExitPath.VPN = .off) -> FixCause? {
        FixPlanner.cause(FixSituation(snapshot: snapshot, vpn: vpn, vpnName: vpn == .off ? nil : "Example VPN", portalPlace: "Lobby", portalBlockers: blockers, portalSeenHere: seen))
    }

    // MARK: Reading the blockers

    @Test func theirOwnDNSIsABlockerAndKilobatsIsNot() {
        let own = PortalBlockers.read(serviceServers: ["1.1.1.1", "not-an-address"], kilobatServers: nil, managed: false, vpn: .off, vpnName: nil)
        #expect(own.ownDNS == ["1.1.1.1"] && own.switchesDNS)
        // Fastest DNS goes back by itself on a sign-in page, so its switch isn't the person's.
        let kilobats = PortalBlockers.read(serviceServers: ["9.9.9.9", "149.112.112.112"], kilobatServers: ["149.112.112.112", "9.9.9.9"], managed: false, vpn: .off, vpnName: nil)
        #expect(kilobats.ownDNS.isEmpty && !kilobats.switchesDNS)
        let automatic = PortalBlockers.read(serviceServers: [], kilobatServers: nil, managed: false, vpn: .off, vpnName: nil)
        #expect(automatic.ownDNS.isEmpty)
        let unread = PortalBlockers.read(serviceServers: nil, kilobatServers: nil, managed: false, vpn: .off, vpnName: nil)
        #expect(unread.ownDNS.isEmpty)
    }
    @Test func onlyAFullVPNIsInTheWay() {
        let full = PortalBlockers.read(serviceServers: [], kilobatServers: nil, managed: false, vpn: .full, vpnName: "Example VPN")
        #expect(full.vpn && full.vpnName == "Example VPN" && !full.isEmpty)
        let partial = PortalBlockers.read(serviceServers: [], kilobatServers: nil, managed: false, vpn: .partial, vpnName: "Office")
        #expect(!partial.vpn && partial.vpnName == nil && partial.isEmpty)
    }
    @Test func whatThePersonTurnsOff() {
        #expect(PortalBlockers(vpn: true, vpnName: "Example VPN").forPerson == [.vpn("Example VPN")])
        // Unknown Private Relay is only a maybe, and not with a VPN carrying everything.
        #expect(PortalBlockers().forPerson == [.privateRelay(sure: false)])
        #expect(PortalBlockers(encryptedDNS: true, privateRelay: false).forPerson == [.encryptedDNS])
        #expect(PortalBlockers(privateRelay: true).forPerson == [.privateRelay(sure: true)])
        #expect(PortalBlockers(ownDNS: ["1.1.1.1"], encryptedDNS: true, vpn: true).forPerson == [.vpn(nil), .encryptedDNS])
        // Kilobat switches DNS itself, so it's never on the person's list.
        #expect(!ownDNS.forPerson.contains { if case .vpn = $0 { true } else { false } })
    }
    @Test func theTitleNamesWhatsInTheWay() {
        #expect(FixCause.signIn(place: nil, blockers: ownDNS).title == "Your DNS settings may hide the sign-in page")
        #expect(FixCause.signIn(place: nil, blockers: PortalBlockers(vpn: true, vpnName: "Example VPN")).title == "Example VPN may hide the sign-in page")
        #expect(FixCause.signIn(place: nil, blockers: PortalBlockers(encryptedDNS: true)).title == "Encrypted DNS may hide the sign-in page")
        #expect(FixCause.signIn(place: nil).title == "Wi-Fi sign-in expired")
    }

    // MARK: Gating

    @Test func switchingDNSIsFixItsOwnSoItsPro() {
        #expect(!FixCause.signIn(place: nil, blockers: ownDNS).alreadyFree)
        #expect(FixCause.signIn(place: nil, blockers: ownDNS).usesHelper)
        // Opening the page and naming a VPN are free in Health already.
        #expect(FixCause.signIn(place: nil, blockers: PortalBlockers(vpn: true)).alreadyFree)
        #expect(!FixCause.signIn(place: nil, blockers: PortalBlockers(vpn: true)).usesHelper)
    }

    // MARK: The cause

    @Test func aPortalInTheWayCarriesItsBlockers() {
        #expect(cause(snapshot(portal: true), blockers: ownDNS) == .signIn(place: "Lobby", blockers: ownDNS))
    }
    @Test func aPageTheirDNSHidesIsTheSignInNotDNS() {
        // A network that showed a sign-in page before, nothing answering, and the person's own DNS on.
        #expect(cause(snapshot(), blockers: ownDNS) == .signIn(place: "Lobby", blockers: ownDNS))
        // Lookups fail while ping goes through: still the page.
        #expect(cause(snapshot(internet: [30, 31]), blockers: ownDNS) == .signIn(place: "Lobby", blockers: ownDNS))
        // Nothing of this Mac's in the way: the network's own problem, as before.
        #expect(cause(snapshot(internet: [30, 31]), blockers: PortalBlockers()) == .dnsFailing)
        // A maybe about Private Relay is no reason on its own.
        #expect(cause(snapshot(internet: [30, 31]), blockers: PortalBlockers(privateRelay: nil)) == .dnsFailing)
    }
    @Test func aNetworkWithNoSignInHistoryNeedsOpenWiFi() {
        #expect(cause(snapshot(internet: [30, 31]), blockers: ownDNS, seen: false) == .dnsFailing)
        #expect(cause(snapshot(internet: [30, 31], security: "Open"), blockers: ownDNS, seen: false) == .signIn(place: "Lobby", blockers: ownDNS))
    }
    @Test func aVPNBehindASignInPageIsntABrokenVPN() {
        let vpn = PortalBlockers(vpn: true, vpnName: "Example VPN")
        #expect(cause(snapshot(), blockers: vpn, vpn: .full) == .signIn(place: "Lobby", blockers: vpn))
        // On a network that never showed a page, a dead tunnel stays the VPN's.
        #expect(cause(snapshot(), blockers: vpn, seen: false, vpn: .full) == .vpnBroken("Example VPN"))
    }
    @Test func aWorkingLineOrWiredMacIsntAHiddenPage() {
        #expect(cause(snapshot(internet: [20, 21], dns: 20), blockers: ownDNS) == nil)
        #expect(cause(snapshot(wired: "en5"), blockers: ownDNS) != .signIn(place: "Lobby", blockers: ownDNS))
    }

    // MARK: Steps and readings

    @Test func theirDNSMakesOneStepThatAsksOnce() {
        let withHelper = FixPlanner.steps(for: .signIn(place: nil, blockers: ownDNS), helper: true)
        #expect(withHelper.map(\.action) == [.signInOnNetworkDNS] && !withHelper[0].asksPassword)
        #expect(FixPlanner.steps(for: .signIn(place: nil, blockers: ownDNS), helper: false)[0].asksPassword)
        #expect(FixPlanner.steps(for: .signIn(place: nil, blockers: PortalBlockers(vpn: true)), helper: true).map(\.action) == [.openSignIn])
        let action = FixAction.signInOnNetworkDNS
        #expect(action.needsPerson && action.undoable && action.restoresAfter && !FixAction.switchDNS(.cloudflare).restoresAfter)
        #expect(action.patience > FixAction.openSignIn.patience)
    }
    @Test func signedInMeansSomethingAnswers() {
        let cause = FixCause.signIn(place: nil, blockers: ownDNS)
        #expect(!cause.metric(FixReading(portal: true)).good)
        // No page seen and nothing answering is a hidden page, not a sign-in.
        #expect(!cause.metric(FixReading(portal: false)).good)
        #expect(cause.metric(FixReading(portal: false)).text == "Signed out")
        #expect(cause.metric(FixReading(dnsMs: 30, portal: false)).good)
        #expect(cause.metric(FixReading(internetMs: 40, portal: false)).text == "Signed in")
    }

    // MARK: The run, on simulated readings

    @MainActor final class Bench {
        var readings: [FixReading]
        var applied: [FixAction] = [], undone: [FixUndo] = []
        var fail = false
        init(_ readings: [FixReading]) { self.readings = readings }
        let undo = FixUndo.dns(service: "Wi-Fi", previous: ["1.1.1.1"], tracked: false)
        var actions: FixRunner.Actions {
            FixRunner.Actions(plan: { FixPlanner.steps(for: .signIn(place: nil, blockers: PortalBlockers(ownDNS: ["1.1.1.1"])), helper: true) },
                              measure: { self.readings.count > 1 ? self.readings.removeFirst() : self.readings[0] },
                              apply: { step in
                                  self.applied.append(step.action)
                                  if self.fail { throw DiagnosticError("Password cancelled") }
                                  return self.undo
                              }, undo: { self.undone.append($0) }, wait: { _ in await Task.yield() })
        }
    }
    private let hidden = FixReading(portal: false), signedIn = FixReading(dnsMs: 25, internetMs: 30, portal: false)

    @MainActor private func run(_ bench: Bench) async -> FixRunner {
        let runner = FixRunner(cause: .signIn(place: nil, blockers: ownDNS), live: nil, actions: bench.actions)
        let task = Task { await runner.run() }
        while true {
            if case .person(_, false) = runner.phase { break }
            if runner.finished { break }
            await Task.yield()
        }
        // Nothing changes until the person says yes.
        #expect(bench.applied.isEmpty)
        runner.proceed()
        await task.value
        return runner
    }

    @MainActor @Test func signedInPutsTheirDNSBack() async {
        let bench = Bench([hidden, signedIn, signedIn, signedIn, signedIn])
        let runner = await run(bench)
        #expect(runner.outcome == .fixed)
        #expect(bench.applied == [.signInOnNetworkDNS])
        #expect(bench.undone == [bench.undo])
        #expect(runner.log.map(\.status) == [.restored])
        #expect(runner.undoable.isEmpty && !runner.restoreBroke)
    }
    @MainActor @Test func theirDNSFailingHereAfterwardIsSaid() async {
        // Signed in on the Wi-Fi's DNS, then nothing answers once theirs is back.
        let bench = Bench([hidden, signedIn, signedIn, signedIn, hidden])
        let runner = await run(bench)
        #expect(runner.outcome == .fixed && runner.restoreBroke)
        #expect(bench.undone.count == 1)
    }
    @MainActor @Test func noSignInPutsTheirDNSBackToo() async {
        let bench = Bench([hidden])
        let runner = await run(bench)
        #expect(runner.outcome == .notYourMac(.network(nil)))
        #expect(bench.undone == [bench.undo])
        #expect(runner.log.map(\.status) == [.undone])
    }
    @MainActor @Test func aCancelledSwitchDoesntWaitForASignIn() async {
        let bench = Bench([hidden]); bench.fail = true
        let runner = await run(bench)
        #expect(runner.outcome == .stopped("Password cancelled"))
        #expect(bench.undone.isEmpty)
        #expect(runner.log.map(\.status) == [.failed("Password cancelled")])
    }
    @MainActor @Test func stoppingWhileWaitingPutsTheirDNSBack() async {
        let bench = Bench([hidden])
        let runner = FixRunner(cause: .signIn(place: nil, blockers: ownDNS), live: nil, actions: bench.actions)
        let task = Task { await runner.run() }
        while runner.phase != .person(FixStep(id: 0, action: .signInOnNetworkDNS), acted: false) { await Task.yield() }
        runner.proceed()
        while runner.phase != .person(FixStep(id: 0, action: .signInOnNetworkDNS), acted: true) { await Task.yield() }
        runner.stop()
        await task.value
        #expect(runner.outcome == .stopped(nil))
        #expect(bench.undone == [bench.undo])
    }
    @MainActor @Test func theAgentPromptNamesTheBlockersWithoutAddresses() {
        let runner = FixRunner(cause: .signIn(place: "Hotel", blockers: PortalBlockers(ownDNS: ["1.1.1.1"], vpn: true, vpnName: "Example VPN")), live: nil, actions: Bench([hidden]).actions)
        let prompt = runner.agentPrompt(appVersion: "1.0", system: "macOS 27")
        #expect(prompt.contains("custom DNS servers") && prompt.contains("a VPN"))
        #expect(!prompt.contains("1.1.1.1") && !prompt.contains("Hotel") && !prompt.contains("Example VPN"))
    }

    // MARK: The saved DNS to put back

    @Test func theHoldSurvivesAndOnlyRestoresOverTheWiFisDNS() throws {
        let defaults = try #require(UserDefaults(suiteName: "kilobat-portal-hold-\(UUID().uuidString)"))
        #expect(PortalDNSHold.load(defaults) == nil)
        let hold = PortalDNSHold(service: "Wi-Fi", servers: ["1.1.1.1"], date: Date(timeIntervalSince1970: 0))
        hold.save(defaults)
        #expect(PortalDNSHold.load(defaults) == hold)
        #expect(hold.shouldRestore(current: []))
        // The person set something else since, or it couldn't be read: theirs stands.
        #expect(!hold.shouldRestore(current: ["8.8.8.8"]) && !hold.shouldRestore(current: nil))
        PortalDNSHold.clear(defaults)
        #expect(PortalDNSHold.load(defaults) == nil)
    }
    @Test func thePlainPageIsPlainHTTPOnAppleCheckHost() {
        #expect(PortalBlockers.plainPage.scheme == "http" && PortalBlockers.plainPage.host == CaptivePortal.Endpoint.apple.url.host)
    }
}
