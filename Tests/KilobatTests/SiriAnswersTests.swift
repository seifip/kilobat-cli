import Foundation
import Testing
@testable import KilobatCore

struct SiriAnswersTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()
    /// 22:30 UTC on 30 October 2026.
    private let now = Date(timeIntervalSince1970: 1_793_399_400)

    private func snapshot(_ date: Date? = nil, rssi: Int? = -52, router: Double? = 3, internet: [Double] = [20, 21, 19], loss: Double = 0, dns: Double = 18,
                          gateway: String? = "192.168.1.1", portal: Bool = false, loggedOut: Bool? = nil) -> DiagnosticSnapshot {
        var sample = DiagnosticSnapshot(date: date ?? now, radio: RadioSample(ssid: "Home", interface: "en0", rssi: rssi, noise: rssi == nil ? nil : -92, transmitMbps: 600, channel: 149, band: "5 GHz"),
                                        gateway: gateway, router: router.map { PingResult(host: "router", samples: [$0, $0], lossPercent: 0) },
                                        internet: PingResult(host: "1.1.1.1", samples: internet, lossPercent: loss), dnsMilliseconds: dns, dnsServers: [], captivePortal: portal, networkService: "Wi-Fi")
        sample.portalLoggedOut = loggedOut
        return sample
    }
    private func input(_ snapshot: DiagnosticSnapshot?, history: [DiagnosticSnapshot] = [], outage: NetworkEvent? = nil, busy: [BusyApp] = [],
                       services: [ServiceStatus] = [], speed: SpeedTestResult? = nil) -> NetworkDiagnosisInput {
        NetworkDiagnosisInput(snapshot: snapshot, history: history, outage: outage, busy: busy, services: services, lastSpeed: speed, now: now)
    }
    private func diagnose(_ input: NetworkDiagnosisInput, pro: Bool = true) -> (answer: SiriAnswer, cause: NetworkCause) {
        SiriAnswers.diagnosis(input, pro: pro, calendar: Self.calendar)
    }
    private var slack: ServiceStatus {
        ServiceStatus(id: "slack", service: "Slack", state: .majorOutage, incident: "Messaging disruption", page: URL(string: "https://slack-status.com")!, checked: now)
    }
    private var speed: SpeedTestResult {
        let ping = #"{"host":"s","samples":[18,21,19,22,20],"lossPercent":0}"#, loaded = #"{"host":"s","samples":[24,26,25],"lossPercent":0}"#
        let json = #"{"date":\#(now.addingTimeInterval(-3600).timeIntervalSinceReferenceDate),"downloadMbps":87.4,"uploadMbps":23.6,"baseline":\#(ping),"downloadLoaded":\#(loaded),"uploadLoaded":\#(loaded),"downloadSeconds":8,"uploadSeconds":8,"transferredBytes":80000000}"#
        return try! JSONDecoder().decode(SpeedTestResult.self, from: Data(json.utf8))
    }

    // MARK: Diagnosis

    @Test func aHealthyLineSaysSoWithTheNumbers() {
        let (answer, cause) = diagnose(input(snapshot(), speed: speed))
        #expect(cause == .fine)
        #expect(answer.tone == .good)
        #expect(answer.spoken == "Your connection looks fine: 20 ms to the internet and no packet loss. Your last speed test got 87 Mbps down and 24 up.")
        #expect(answer.cause == nil)
        #expect(answer.facts.map(\.label) == ["Internet", "Packet loss", "Router", "Wi-Fi signal", "DNS"])
        // Without Pro the healthy answer is the same.
        #expect(diagnose(input(snapshot(), speed: speed), pro: false).answer == answer)
    }

    @Test func weakWiFiIsTheCauseWithPro() {
        let (answer, cause) = diagnose(input(snapshot(rssi: -79)))
        #expect(cause == .wifi)
        #expect(answer.sentence.hasPrefix("Your Wi-Fi signal is weak (-79 dBm), and that’s the bottleneck."))
        #expect(answer.cause == "Weak or noisy Wi-Fi")
        #expect(answer.upsell == nil)
    }

    @Test func withoutProTheProblemIsNamedButNotItsCause() {
        let (answer, cause) = diagnose(input(snapshot(rssi: -79, internet: [140, 150], loss: 6)), pro: false)
        #expect(cause == .locked)
        #expect(answer.sentence == "Your connection is poor right now: 145 ms to the internet and 6% packet loss.")
        #expect(answer.upsell == "Kilobat Pro tells you why, and what to do.")
        #expect(answer.spoken.hasSuffix("Kilobat Pro tells you why, and what to do."))
        #expect(!answer.spoken.contains("Wi-Fi signal"))
        #expect(answer.cause == nil)
    }

    @Test func lossPastTheRouterSaysSinceWhenAndThatItIsInTheReport() {
        // Clean until 21:00, then about 4% loss every minute to 22:30.
        let history = (0..<180).map { minute -> DiagnosticSnapshot in
            let date = now.addingTimeInterval(Double(minute - 180) * 60)
            return snapshot(date, loss: date >= now.addingTimeInterval(-5400) ? (minute % 2 == 0 ? 5 : 3) : 0)
        }
        let (answer, cause) = diagnose(input(snapshot(loss: 4), history: history))
        #expect(cause == .provider)
        let since = SiriAnswers.moment(now.addingTimeInterval(-5400), now: now, calendar: Self.calendar)
        #expect(answer.sentence == "Your Wi-Fi is fine; your provider’s line is losing 4% of packets since \(since). It’s in your provider report.")
        #expect(answer.cause == "Packet loss past the router")
    }

    @Test func aFreshProblemHasNoSince() {
        let history = (0..<10).map { snapshot(now.addingTimeInterval(Double(-$0) * 60), loss: 5) }
        #expect(SiriAnswers.since(history: history, network: snapshot().networkKey, now: now) { _ in true } == nil)
        let (answer, _) = diagnose(input(snapshot(loss: 5), history: history))
        #expect(answer.sentence.contains("of packets right now"))
    }

    @Test func anAppFillingTheLineIsNamed() {
        let busy = [BusyApp(name: "Dropbox", download: 2_000, upload: 4_200_000), BusyApp(name: "Safari", download: 30_000, upload: 1_000)]
        let (answer, cause) = diagnose(input(snapshot(internet: [180, 190], loss: 0), busy: busy))
        #expect(cause == .busyApp)
        #expect(answer.sentence == "Dropbox is uploading at 4.2 MB/s, which is filling your line. Pause it, and everything else should speed up.")
        // On a healthy line it's said more gently.
        #expect(diagnose(input(snapshot(), busy: busy)).answer.sentence.hasPrefix("Your connection is healthy, but Dropbox is uploading"))
    }

    @Test func theSignInPageIsFreeToKnow() {
        let sample = snapshot(internet: [], loss: 100, portal: true, loggedOut: true)
        for pro in [true, false] {
            let (answer, cause) = diagnose(input(sample), pro: pro)
            #expect(cause == .portal)
            #expect(answer.sentence.hasPrefix("The Wi-Fi’s sign-in page logged you out"))
            #expect(answer.upsell == nil)
        }
    }

    @Test func anOutagePastTheRouterSaysWhenItStarted() {
        let outage = NetworkEvent(start: now.addingTimeInterval(-1080), end: nil, network: "Home", kind: "Unreachable", detail: "", routerChecks: 18, routerAnswered: 18)
        let (answer, cause) = diagnose(input(snapshot(internet: [], loss: 100), outage: outage))
        #expect(cause == .offline)
        #expect(answer.sentence.contains("the internet has been down since \(SiriAnswers.moment(outage.start, now: now, calendar: Self.calendar))"))
        let free = diagnose(input(snapshot(internet: [], loss: 100), outage: outage), pro: false)
        #expect(free.cause == .locked)
        #expect(free.answer.spoken == "The internet isn’t answering right now. Kilobat Pro tells you where it breaks.")
    }

    @Test func aServiceOutageOnAGoodLineIsNotYou() {
        for pro in [true, false] {
            let (answer, cause) = diagnose(input(snapshot(), services: [slack]), pro: pro)
            #expect(cause == .serviceOutage)
            #expect(answer.sentence == "Slack is down for everyone, not you — Messaging disruption.")
        }
    }

    @Test func noCheckYetAndNoReplyAreSaidPlainly() {
        #expect(diagnose(input(nil)).cause == .checking)
        let (answer, cause) = diagnose(input(snapshot(internet: [], loss: 100)))
        #expect(cause == .noReply)
        #expect(answer.sentence.hasPrefix("Your router answers, but the ping target didn’t."))
        #expect(diagnose(input(snapshot(router: nil, internet: [], loss: 100, gateway: nil))).cause == .notConnected)
    }

    // MARK: Calls

    private func call(_ build: (inout CallSamples) -> Void) -> CallReport {
        var samples = CallSamples()
        build(&samples)
        return CallAnalysis.report(app: "Zoom", browser: false, start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-1800), network: nil, samples: samples)
    }
    private func pings(_ values: [Double?]) -> [CallSamples.Ping] { values.enumerated().map { .init(at: Double($0.offset), ms: $0.element) } }
    private var frozen: CallReport {
        call { samples in
            samples.internet = pings(Array(repeating: 30, count: 100) + [400, nil, 380] + Array(repeating: 30, count: 100) + [nil, nil] + Array(repeating: 30, count: 100))
            samples.router = pings(Array(repeating: 3, count: 305))
            samples.traffic = [.init(at: 98, app: "Dropbox", upload: 900_000, download: 2_000), .init(at: 200, app: "Dropbox", upload: 1_200_000, download: 0)]
        }
    }

    @Test func theLastCallWithProNamesTheCauseAndTheFix() {
        let answer = SiriAnswers.call(frozen, pro: true, now: now, calendar: Self.calendar)
        let when = SiriAnswers.clock(frozen.start, now: now, calendar: Self.calendar)
        #expect(answer.sentence.hasPrefix("Your Zoom call \(when) had 2 freezes, caused by Dropbox uploading. Pause Dropbox before calls"))
        #expect(answer.cause == "caused by Dropbox uploading")
        #expect(answer.upsell == nil)
    }

    @Test func theLastCallWithoutProGivesTheCountAndAGentleNudge() {
        let answer = SiriAnswers.call(frozen, pro: false, now: now, calendar: Self.calendar)
        let when = SiriAnswers.clock(frozen.start, now: now, calendar: Self.calendar)
        #expect(answer.spoken == "Your Zoom call \(when) had 2 freezes. Kilobat Pro tells you why.")
        #expect(!answer.spoken.contains("Dropbox"))
        #expect(answer.cause == nil)
    }

    @Test func theCallingServicesOwnOutageIsFree() {
        var report = frozen
        report.service = ServiceStatus(id: "zoom", service: "Zoom", state: .majorOutage, incident: "Meetings failing", page: URL(string: "https://status.zoom.us")!, checked: now)
        let answer = SiriAnswers.call(report, pro: false, now: now, calendar: Self.calendar)
        #expect(answer.sentence.contains("Zoom’s status page reported an outage at the time — Meetings failing"))
    }

    @Test func aCleanCallAndNoCalls() {
        let clean = call { samples in
            samples.internet = pings(Array(repeating: 30, count: 300))
            samples.router = pings(Array(repeating: 3, count: 300))
        }
        let answer = SiriAnswers.call(clean, pro: false, now: now, calendar: Self.calendar)
        #expect(answer.sentence.hasSuffix("was clean, with no freezes."))
        #expect(answer.upsell == nil)
        #expect(SiriAnswers.call(nil, pro: true).sentence.hasPrefix("Kilobat hasn’t heard a call yet."))
        #expect(SiriAnswers.call(nil, enabled: false, pro: true).sentence.hasPrefix("Call reports are off."))
    }

    @Test func callTimesReadAsSpoken() {
        #expect(SiriAnswers.clock(now.addingTimeInterval(-3600), now: now, calendar: Self.calendar).hasPrefix("at "))
        #expect(SiriAnswers.clock(now.addingTimeInterval(-86_400), now: now, calendar: Self.calendar).hasPrefix("yesterday at "))
        #expect(SiriAnswers.clock(now.addingTimeInterval(-4 * 86_400), now: now, calendar: Self.calendar).hasPrefix("on Oct 26"))
    }

    // MARK: Status pages

    @Test func statusPagesAnswerIsItThemOrMe() {
        #expect(SiriAnswers.services([slack], lineFine: true).sentence == "Slack is down for everyone, not you — Messaging disruption.")
        #expect(SiriAnswers.services([slack], lineFine: false).sentence == "Slack is down for everyone — Messaging disruption.")
        let fine = ["Zoom", "GitHub"].map { ServiceStatus(id: $0.lowercased(), service: $0, state: .operational, page: URL(string: "https://example.com")!, checked: now) }
        let answer = SiriAnswers.services(fine, lineFine: true)
        #expect(answer.sentence == "Status pages for Zoom and GitHub report no problems.")
        #expect(answer.tone == .good)
        let mixed = SiriAnswers.services(fine + [slack], lineFine: true)
        #expect(mixed.sentence.hasPrefix("Slack is down for everyone, not you"))
        #expect(SiriAnswers.services([], lineFine: true).tone == .unknown)
    }

    // MARK: Usage, leaks, calls ahead, speed

    @Test func whatIsUsingTheInternet() {
        let apps = [BusyApp(name: "Steam", download: 8_400_000, upload: 20_000), BusyApp(name: "Dropbox", download: 0, upload: 1_200_000),
                    BusyApp(name: "Safari", download: 300_000, upload: 1_000), BusyApp(name: "Mail", download: 100, upload: 0)]
        let answer = SiriAnswers.usageNow(apps, download: 8_800_000, upload: 1_300_000)
        #expect(answer.sentence == "Steam is using the most right now, downloading at 8.4 MB/s. Then Dropbox at 1.2 MB/s and Safari at 301 KB/s.")
        #expect(answer.facts.count == 4)
        #expect(SiriAnswers.usageNow([], download: 9_000, upload: 3_000).sentence == "Nothing much right now: all your apps together use 12 KB/s.")
    }

    @Test func dataUsedTodayWithTheBudget() {
        let answer = SiriAnswers.dataUsed(received: 2_900_000_000, sent: 310_000_000, topApps: ["Steam", "Safari", "Mail"],
                                          budget: .init(used: 4_100_000_000, limitGB: 5, cycle: BudgetCycle(period: .monthly)), now: now, calendar: Self.calendar)
        #expect(answer.sentence == "You’ve used 3.21 GB today: 2.9 GB down and 310 MB up, mostly Steam and Safari. This network’s budget: 4.1 of 5 GB used this month.")
        #expect(answer.tone == .caution)
        #expect(SiriAnswers.dataUsed(received: 1_000_000, sent: 0, topApps: [], budget: nil).facts.count == 3)
    }

    @Test func vpnLeaks() {
        let pass = LeakTest.Check(id: "ipv6", status: .pass, title: "IPv6", detail: "")
        let leak = LeakTest(date: now, vpnState: "full", vpn: "Mullvad", tunnel: "utun3", exitAddress: nil,
                            checks: [LeakTest.Check(id: "dns", status: .fail, title: "DNS", detail: "", fix: "Turn on the VPN’s DNS leak protection."), pass], services: [])
        let answer = SiriAnswers.leak(leak)
        #expect(answer.spoken == "Leaks: DNS. Turn on the VPN’s DNS leak protection.")
        #expect(answer.tone == .problem)
        let clean = LeakTest(date: now, vpnState: "full", vpn: nil, tunnel: "utun3", exitAddress: nil, checks: [pass], services: [])
        #expect(SiriAnswers.leak(clean).tone == .good)
        let off = LeakTest(date: now, vpnState: "off", vpn: nil, tunnel: nil, exitAddress: nil, checks: [.init(id: "dns", status: .skipped, title: "DNS", detail: "No VPN carries traffic right now.")], services: [])
        #expect(SiriAnswers.leak(off).sentence == "No VPN carries traffic right now.")
    }

    @Test func readyForACallFollowsTheTiers() {
        let busy = Preflight(date: now, issues: [.init(kind: .app, app: "Dropbox", uploading: true), .init(kind: .wifi)])
        let pro = SiriAnswers.preflight(busy, pro: true)
        #expect(pro.sentence == "Not quite: Dropbox is uploading and Wi-Fi is weak. Turn on call mode in Kilobat to pause Dropbox until the call ends.")
        let free = SiriAnswers.preflight(busy, pro: false)
        #expect(free.spoken == "Not quite: Dropbox is uploading and Wi-Fi is weak. Kilobat Pro can pause them until the call ends.")
        #expect(SiriAnswers.preflight(Preflight(date: now, issues: []), pro: false).tone == .good)
        #expect(SiriAnswers.preflight(Preflight(date: now, issues: [.init(kind: .airDrop)]), pro: false).sentence.hasSuffix("it pauses AirDrop until you turn it off."))
    }

    @Test func speedTestsAreSpokenAsASentence() {
        let answer = SiriAnswers.speed(speed)
        #expect(answer.sentence == "87 Mbps down and 24 up, and latency stays low under load. Good for HD video calls.")
        #expect(!answer.spoken.contains("↓"))
    }

    // MARK: Lookups

    @Test func callsAreFoundByAppOrAsTheLastOne() {
        let older = CallAnalysis.report(app: "Microsoft Teams", browser: false, start: now.addingTimeInterval(-90_000), end: now.addingTimeInterval(-88_000), network: nil, samples: CallSamples())
        let last = frozen, reports = [older, last]
        #expect(SiriLookup.calls(reports).first?.id == last.id)
        #expect(SiriLookup.calls(reports, matching: "the last call").map(\.id) == [last.id, older.id])
        #expect(SiriLookup.calls(reports, matching: "my Teams call").map(\.id) == [older.id])
        #expect(SiriLookup.calls(reports, matching: "FaceTime").isEmpty)
    }

    @Test func servicesAreFoundAsPeopleSayThem() {
        #expect(SiriLookup.services(matching: "Slack").map(\.id) == ["slack"])
        #expect(SiriLookup.services(matching: "the Slack app").map(\.id) == ["slack"])
        #expect(SiriLookup.services(matching: "github.com").map(\.id) == ["github"])
        #expect(SiriLookup.services(matching: "claude").count > 1)
        #expect(SiriLookup.services(matching: "no such thing").isEmpty)
        let suggested = SiriLookup.suggestedServices
        #expect(suggested.count == ServiceCatalog.services.count)
        #expect(suggested.map(\.name) == suggested.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    // MARK: Phrases

    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Apple's rules: at most 10 App Shortcuts, every phrase names the app exactly once and takes at most one parameter,
    /// and all phrases, a parameter's values spelled out, stay under 1,000. Each is a key in AppShortcuts.xcstrings.
}
