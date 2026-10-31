import Foundation
import Testing
@testable import KilobatCore

struct CaptivePortalProbeTests {
    private let appleSuccess = "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"

    @Test func applesSuccessPageIsOpen() {
        #expect(CaptivePortal.classify(.apple, status: 200, body: appleSuccess, location: nil) == .success)
    }

    @Test func aRedirectIsASignInPageAtItsLocation() {
        let answer = CaptivePortal.classify(.apple, status: 302, body: "", location: "https://login.example.net/portal?mac=aa:bb&ip=10.0.0.5")
        #expect(answer == .intercepted(URL(string: "https://login.example.net/portal?mac=aa:bb&ip=10.0.0.5")))
    }

    @Test func aPageOfItsOwnIsASignInPageAndItsMetaRefreshOrScriptNamesIt() {
        let meta = #"<html><head><meta http-equiv="refresh" content="0; url=http://192.168.3.1:8080/login.html?res=notyet"></head></html>"#
        #expect(CaptivePortal.classify(.apple, status: 200, body: meta, location: nil) == .intercepted(URL(string: "http://192.168.3.1:8080/login.html?res=notyet")))
        let script = #"<script>window.location.href = "/guest/login";</script>"#
        #expect(CaptivePortal.classify(.apple, status: 200, body: script, location: nil) == .intercepted(URL(string: "http://captive.apple.com/guest/login")))
        // A page that says nothing about where to go is still a sign-in page in the way.
        #expect(CaptivePortal.classify(.apple, status: 200, body: "<html>Welcome to Hotel Wi-Fi</html>", location: nil) == .intercepted(nil))
        // Only web addresses count.
        #expect(CaptivePortal.signInPage(location: "javascript:alert(1)", body: "", base: CaptivePortal.Endpoint.apple.url) == nil)
    }

    @Test func googlesCheckIsAnEmpty204OrAnEmpty200() {
        #expect(CaptivePortal.classify(.google, status: 204, body: "", location: nil) == .success)
        #expect(CaptivePortal.classify(.google, status: 200, body: "  \n", location: nil) == .success)
        #expect(CaptivePortal.classify(.google, status: 200, body: "<html>Sign in</html>", location: nil) == .intercepted(nil))
        #expect(CaptivePortal.classify(.google, status: 302, body: "", location: "http://portal.example/") == .intercepted(URL(string: "http://portal.example/")))
    }

    @Test func noAnswerIsNoNetworkNotASignInPage() {
        #expect(CaptivePortal.classify(.apple, status: nil, body: "", location: nil) == .failed)
        #expect(CaptivePortal.classify(.google, status: nil, body: "", location: nil) == .failed)
    }

    @Test func aLengthThePageStatesIsReadOnlyWhenItIsTheOnlyOne() {
        #expect(CaptivePortal.hint(in: "<p>Enjoy <b>1 hour</b> of free Wi-Fi with your coffee.</p>") == 60)
        #expect(CaptivePortal.hint(in: "Internet access is limited to 90 minutes per session.") == 90)
        // A price list names several lengths: no hint.
        #expect(CaptivePortal.hint(in: "Internet access: 1 hour $5 · 24 hours $12") == nil)
        // A length with nothing about access around it isn't one.
        #expect(CaptivePortal.hint(in: "Our kitchen closes 2 hours before midnight.") == nil)
        #expect(CaptivePortal.hint(in: "Welcome! Please accept the terms.") == nil)
    }
}

@MainActor struct PortalWatchTests {
    private func watch() -> PortalWatch {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-portal-\(UUID().uuidString)")
        let watch = PortalWatch(directory: folder, notifies: false)
        watch.allowed = { true }
        return watch
    }
    private let page = URL(string: "http://login.example.net/")!
    private var portal: PortalCheck { PortalCheck(state: .portal, url: page) }
    private let open = PortalCheck(state: .open)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    /// Signed in at `from`, checks every minute through `through`, then the sign-in page comes back a minute later.
    private func session(_ watch: PortalWatch, from: Double, through: Double) {
        var time = from
        while time <= through { watch.observe(open, network: "cafe", name: "Café Wi-Fi", now: at(time)); time += 60 }
        watch.observe(portal, network: "cafe", name: "Café Wi-Fi", now: at(through + 60))
    }

    @Test func aSignInIsLearnedFromWhenTheCheckGoesThroughToWhenThePageComesBack() {
        let watch = watch()
        watch.observe(portal, network: "cafe", name: "Café Wi-Fi", now: at(0))
        #expect(watch.status == .signInNeeded)
        session(watch, from: 60, through: 3660)
        #expect(watch.status == .loggedOut(since: at(3660)))
        #expect(watch.record?.sessions.first?.seconds == 3600 && watch.record?.sessions.first?.measured == true)
        // One sign-in isn't enough to warn by.
        #expect(watch.record?.typicalSeconds == nil)
        session(watch, from: 3780, through: 7320)
        #expect(watch.record?.measured == [3600, 3540])
        #expect(watch.record?.typicalSeconds == 3570)
    }

    @Test func theWarningComesOnceAboutFiveMinutesBeforeTheUsualEnd() {
        let watch = watch()
        watch.observe(portal, network: "cafe", name: "Café Wi-Fi", now: at(0))
        session(watch, from: 60, through: 3660)
        session(watch, from: 3780, through: 7320)
        watch.observe(open, network: "cafe", name: "Café Wi-Fi", now: at(7440))
        #expect(watch.status == .signedIn(since: at(7440)))
        #expect(watch.expectedEnd == at(7440 + 3570))
        #expect(watch.tick(now: at(7440 + 3000)) == nil)
        let warning = watch.tick(now: at(7440 + 3570 - 290))
        #expect(warning?.kind == .warning && warning?.title == "Café Wi-Fi will log you out in 5 min")
        #expect(warning?.url == page)
        #expect(watch.tick(now: at(7440 + 3570 - 200)) == nil)
    }

    @Test func noWarningWithoutProOrWithTheSettingOff() {
        let watch = watch()
        watch.observe(portal, network: "cafe", name: "Café Wi-Fi", now: at(0))
        session(watch, from: 60, through: 3660)
        session(watch, from: 3780, through: 7320)
        watch.observe(open, network: "cafe", name: "Café Wi-Fi", now: at(7440))
        watch.allowed = { false }
        #expect(watch.tick(now: at(7440 + 3570 - 290)) == nil)
    }

    @Test func theWarningKeepsToItsWindowAndIsRateLimited() {
        let now = Date()
        #expect(PortalWatch.warning(remaining: 300, warned: false, lastAlert: .distantPast, now: now) == 5)
        #expect(PortalWatch.warning(remaining: 130, warned: false, lastAlert: .distantPast, now: now) == 2)
        #expect(PortalWatch.warning(remaining: 400, warned: false, lastAlert: .distantPast, now: now) == nil)
        #expect(PortalWatch.warning(remaining: 20, warned: false, lastAlert: .distantPast, now: now) == nil)
        #expect(PortalWatch.warning(remaining: 300, warned: true, lastAlert: .distantPast, now: now) == nil)
        #expect(PortalWatch.warning(remaining: 300, warned: false, lastAlert: now.addingTimeInterval(-600), now: now) == nil)
        #expect(PortalWatch.warning(remaining: 300, warned: false, lastAlert: now.addingTimeInterval(-1200), now: now) == 5)
    }

    @Test func aSignInNotSeenWholeTeachesNothing() {
        let watch = watch()
        watch.observe(portal, network: "cafe", name: "Café Wi-Fi", now: at(0))
        watch.observe(open, network: "cafe", name: "Café Wi-Fi", now: at(60))
        // The Mac slept: the next check, two hours later, finds the page back.
        watch.observe(portal, network: "cafe", name: "Café Wi-Fi", now: at(7260))
        #expect(watch.status == .loggedOut(since: at(60)))
        #expect(watch.record?.sessions.first?.measured == false)
        // Left the network and came back: the page on rejoining says nothing about how long the sign-in lasted.
        watch.observe(open, network: "cafe", name: "Café Wi-Fi", now: at(7320))
        watch.observe(open, network: "cafe", name: "Café Wi-Fi", now: at(7380))
        watch.observe(open, network: "home", name: "Home", now: at(7440))
        watch.observe(portal, network: "cafe", name: "Café Wi-Fi", now: at(7500))
        #expect(watch.record?.sessions.last?.measured == false)
        #expect(watch.record?.measured.isEmpty == true)
    }

    @Test func oneSignInBesideTheStatedLengthIsEnoughAndTheShorterCounts() {
        let network = PortalNetwork(id: "x", name: "Hotel", hintMinutes: 60, sessions: [PortalSession(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3480), measured: true)],
                                    firstSeen: Date(), lastSeen: Date())
        #expect(network.typicalSeconds == 3480)
        var stated = network; stated.sessions[0].end = Date(timeIntervalSince1970: 3900)
        #expect(stated.typicalSeconds == 3600)
        var unstated = network; unstated.hintMinutes = nil
        #expect(unstated.typicalSeconds == nil)
    }

    @Test func theMedianOfOddAndEvenCounts() {
        #expect(PortalWatch.median([3600, 1800, 3000]) == 3000)
        #expect(PortalWatch.median([3600, 3000]) == 3300)
        #expect(PortalWatch.median([]) == nil)
        #expect(PortalWatch.length(45 * 60) == "45 min" && PortalWatch.length(3600) == "1 h" && PortalWatch.length(5_420) == "1 h 30 min")
    }

    @Test func itLooksOnJoiningWhenTheInternetFailsAndOtherwiseRarely() {
        let watch = watch()
        #expect(watch.due(network: "cafe", internetFailed: false, now: at(0)))
        watch.observe(open, network: "cafe", name: "Café Wi-Fi", now: at(0))
        #expect(!watch.due(network: "cafe", internetFailed: false, now: at(60)))
        #expect(watch.due(network: "cafe", internetFailed: true, now: at(60)))
        #expect(watch.due(network: "cafe", internetFailed: false, now: at(900)))
        #expect(watch.due(network: "other", internetFailed: false, now: at(61)))
        watch.observe(portal, network: "cafe", name: "Café Wi-Fi", now: at(100))
        // While the page is in the way, every check looks, to see the sign-in go through.
        #expect(watch.due(network: "cafe", internetFailed: false, now: at(112)))
    }

    @Test func wifiWithoutItsNameLearnsNothing() {
        let watch = watch()
        watch.observe(portal, network: "hidden", name: "Wi-Fi", identified: false, now: at(0))
        #expect(watch.status == .signInNeeded && watch.networks.isEmpty)
    }

    @Test func theHistoryIsKeptOnDiskForTheCLI() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-portal-\(UUID().uuidString)")
        let watch = PortalWatch(directory: folder, notifies: false)
        watch.observe(portal, network: "cafe", name: "Café Wi-Fi", now: at(0))
        watch.observe(open, network: "cafe", name: "Café Wi-Fi", now: at(60))
        let stored = PortalWatch.load(directory: folder)
        #expect(stored.first?.host == "login.example.net" && stored.first?.openSession?.start == at(60))
        #expect(PortalWatch.status(of: stored.first, check: portal, now: at(600)) == .loggedOut(since: at(60)))
        #expect(PortalWatch.status(of: stored.first, check: open, now: at(600)) == .signedIn(since: at(60)))
        #expect(PortalWatch.status(of: nil, check: portal, now: at(600)) == .signInNeeded)
        #expect(PortalWatch.status(of: stored.first, check: PortalCheck(state: .offline), now: at(600)) == .none)
    }
}

struct PortalDiagnosisTests {
    private func sample(portal: Bool?, loggedOut: Bool? = nil) -> DiagnosticSnapshot {
        DiagnosticSnapshot(date: Date(), radio: RadioSample(ssid: "Café Wi-Fi", interface: "en0", rssi: -80, noise: -90, transmitMbps: 20, channel: 1, band: "2.4 GHz"),
                           gateway: "10.0.0.1", router: PingResult(host: "10.0.0.1", samples: [40, 45], lossPercent: 0),
                           internet: PingResult(host: "1.1.1.1", samples: [], lossPercent: 100), dnsMilliseconds: 400, dnsServers: [],
                           captivePortal: portal, networkService: "Wi-Fi", portalLoggedOut: loggedOut)
    }

    @Test func theSignInPageIsTheOnlyCauseWhileItIsInTheWay() {
        #expect(sample(portal: true).advice == ["This network may require a login. Open the login page before testing again."])
        #expect(sample(portal: true, loggedOut: true).advice == ["The Wi-Fi’s sign-in page logged you out. Sign in again; the internet isn’t down."])
        // Without it, the weak signal, slow router, slow DNS and lost pings all show.
        #expect(sample(portal: false).advice.count >= 4)
    }

    @Test @MainActor func theEventLogSaysSignInNotOutage() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-journal-\(UUID().uuidString)")
        let failed = PingResult(host: "8.8.8.8", samples: [], lossPercent: 100)
        let journal = NetworkJournal(directory: folder)
        for minute in 0..<3 { journal.ingest(sample(portal: true, loggedOut: true), secondary: failed, httpReachable: false, date: Date().addingTimeInterval(Double(minute) * 60)) }
        #expect(journal.events.last?.kind == "Wi-Fi sign-in")
        #expect(!journal.events.contains { $0.kind == "Unreachable" })
    }

    @Test func aFreezeAfterTheLogoutIsTheSignInPages() {
        var samples = CallSamples()
        samples.internet = (0..<120).map { .init(at: Double($0), ms: $0 >= 60 ? nil : 30) }
        samples.router = (0..<120).map { .init(at: Double($0), ms: 3) }
        samples.loggedOut = 55
        let report = CallAnalysis.report(app: "Zoom", browser: false, start: Date(), end: Date().addingTimeInterval(120), network: nil, samples: samples)
        #expect(report.freezes.first?.cause.kind == .portal)
        #expect(report.verdict.contains("sign-in page"))
        // Before the logout, the usual causes still apply.
        #expect(CallAnalysis.cause(from: 10, to: 12, samples: samples).kind == .beyondRouter)
    }

    @Test func theStutterTestPastTheRouterNamesTheSignInPage() {
        var result = StutterTest.analyze(Array(repeating: nil, count: 200), target: "internet", host: "1.1.1.1")
        result.portal = true
        #expect(result.verdict.contains("sign-in page"))
        var router = StutterTest.analyze(Array(repeating: 3.0, count: 200), target: "router", host: "10.0.0.1")
        router.portal = true
        #expect(!router.verdict.contains("sign-in page"))
    }

    @Test func theConnectionCheckBlamesTheSignInPageNotDNS() async {
        let failed = DoctorReport(target: "example.com", host: "example.com", app: nil, verdict: "Your DNS server can’t resolve it.", next: "Switch DNS.",
                                  steps: [DoctorStep(layer: "DNS", status: .failed, detail: "No answer")], date: Date())
        let report = await ConnectionDoctor.withPortal(failed, check: PortalCheck(state: .portal, url: URL(string: "http://login.example.net/")))
        #expect(report.verdict == "The Wi-Fi’s sign-in page is in the way." && report.steps.first?.layer == "Wi-Fi sign-in")
        let unchanged = await ConnectionDoctor.withPortal(failed, check: PortalCheck(state: .open))
        #expect(unchanged.verdict == failed.verdict)
    }
}

struct PortalCommandTests {
    @Test func parsesTheCommand() throws {
        #expect(try PortalReport.parse([]) == .status(json: false))
        #expect(try PortalReport.parse(["--json"]) == .status(json: true))
        #expect(try PortalReport.parse(["open"]) == .open)
        #expect(throws: PortalReport.UsageError.self) { try PortalReport.parse(["--hours", "3"]) }
        #expect(throws: PortalReport.UsageError.self) { try PortalReport.parse(["open", "--json"]) }
    }

    @Test func theJSONRedactsThePagesQueryAndGivesTheTimeLeft() {
        let now = Date()
        let sessions = [PortalSession(start: now.addingTimeInterval(-90_000), end: now.addingTimeInterval(-86_400), measured: true),
                        PortalSession(start: now.addingTimeInterval(-190_000), end: now.addingTimeInterval(-186_400), measured: true),
                        PortalSession(start: now.addingTimeInterval(-1_200))]
        let network = PortalNetwork(id: "cafe", name: "Café Wi-Fi", place: "The Long Table", host: "login.example.net", sessions: sessions, firstSeen: now, lastSeen: now)
        let signedIn = PortalReport.json(check: PortalCheck(state: .open), network: network, networks: [network], now: now)
        #expect(signedIn["status"] as? String == "signedIn" && signedIn["minutesLeft"] as? Int == 40 && signedIn["typicalMinutes"] as? Int == 60)
        let check = PortalCheck(state: .portal, url: URL(string: "https://login.example.net/auth?mac=aa:bb:cc&token=secret"))
        let loggedOut = PortalReport.json(check: check, network: network, networks: [network], now: now)
        #expect(loggedOut["status"] as? String == "loggedOut" && loggedOut["state"] as? String == "portal")
        #expect(loggedOut["signInPage"] as? String == "https://login.example.net/auth?mac=[redacted]&token=[redacted]")
        #expect(PortalReport.text(check: check, network: network, networks: [network], now: now).contains("Logged out by The Long Table"))
    }

    @Test func theCheckIsAboutTheAppsNetworkOrTheOneWithThisPage() {
        let now = Date()
        let cafe = PortalNetwork(id: "cafe", name: "Café", host: "login.example.net", firstSeen: now, lastSeen: now.addingTimeInterval(-7200))
        let hotel = PortalNetwork(id: "hotel", name: "Hotel", host: "hotel.example", firstSeen: now, lastSeen: now.addingTimeInterval(-60))
        let check = PortalCheck(state: .portal, url: URL(string: "http://login.example.net/"))
        #expect(PortalReport.network([cafe, hotel], appKey: "hotel", check: check, now: now)?.id == "hotel")
        #expect(PortalReport.network([cafe, hotel], appKey: nil, check: check, now: now)?.id == "cafe")
        #expect(PortalReport.network([cafe, hotel], appKey: nil, check: PortalCheck(state: .open), now: now)?.id == "hotel")
        #expect(PortalReport.network([cafe], appKey: nil, check: PortalCheck(state: .open), now: now) == nil)
    }
}
