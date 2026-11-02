import Foundation

/// What Kilobat says when Siri, Spotlight or a shortcut asks it something: one or two sentences to speak, a short
/// headline and the measurements for the snippet, and the cause as a value for the next action. Composed here from
/// the same stores the app shows, so the words can be tested; the App Intents only gather the inputs.
public struct SiriAnswer: Sendable, Equatable {
    public enum Tone: String, Sendable { case good, caution, problem, unknown }
    public struct Fact: Sendable, Equatable, Hashable {
        public let label: String
        public let value: String
        public var warning = false
        public init(_ label: String, _ value: String, warning: Bool = false) { self.label = label; self.value = value; self.warning = warning }
    }
    /// The snippet's headline: "Weak or noisy Wi-Fi", "Looking good."
    public let title: String
    /// The key fact and its cause, in a sentence or two.
    public let sentence: String
    public let tone: Tone
    public var facts: [Fact] = []
    /// Said and shown after the sentence when the answer leaves out what Kilobat Pro adds.
    public var upsell: String? = nil
    /// A short name for what's wrong, for the next action in a shortcut. Nil when nothing is, or without Pro.
    public var cause: String? = nil
    public init(title: String, sentence: String, tone: Tone, facts: [Fact] = [], upsell: String? = nil, cause: String? = nil) {
        self.title = title; self.sentence = sentence; self.tone = tone; self.facts = facts; self.upsell = upsell; self.cause = cause
    }
    /// What Siri says.
    public var spoken: String { upsell.map { sentence + " " + $0 } ?? sentence }
}

/// An app moving a lot of data right now, by the thresholds call reports use.
public struct BusyApp: Sendable, Equatable {
    public let name: String
    public let download: Double
    public let upload: Double
    public init(name: String, download: Double, upload: Double) { self.name = name; self.download = download; self.upload = upload }
    public var rate: Double { download + upload }
    public var uploading: Bool { upload / CallAnalysis.uploadLoad >= download / CallAnalysis.downloadLoad }
    /// Enough to slow everything else down: what a call report would blame.
    public var heavy: Bool { upload >= CallAnalysis.uploadLoad || download >= CallAnalysis.downloadLoad }
    public static func from(_ apps: [AppTraffic]) -> [BusyApp] {
        apps.filter { !$0.carrier && $0.rate > 0 }.sorted { $0.rate > $1.rate }
            .map { BusyApp(name: $0.name, download: $0.downloadRate, upload: $0.uploadRate) }
    }
}

/// Everything "why is my internet slow?" is answered from.
public struct NetworkDiagnosisInput: Sendable {
    /// The check just run; nil while Kilobat hasn't finished one.
    public var snapshot: DiagnosticSnapshot?
    /// The health checks of the last day, oldest first, for how long a problem has lasted.
    public var history: [DiagnosticSnapshot] = []
    /// An outage the journal has open: three checks in a row reached nothing past this Mac.
    public var outage: NetworkEvent? = nil
    /// Apps by how much they move right now, busiest first.
    public var busy: [BusyApp] = []
    /// What the status pages of the apps in use said.
    public var services: [ServiceStatus] = []
    /// Router check-up's finding while the router is slowing down over days.
    public var routerSlowing: (headline: String, advice: String?)? = nil
    public var lastSpeed: SpeedTestResult? = nil
    public var now = Date()
    public init(snapshot: DiagnosticSnapshot?, history: [DiagnosticSnapshot] = [], outage: NetworkEvent? = nil, busy: [BusyApp] = [], services: [ServiceStatus] = [],
                routerSlowing: (headline: String, advice: String?)? = nil, lastSpeed: SpeedTestResult? = nil, now: Date = Date()) {
        self.snapshot = snapshot; self.history = history; self.outage = outage; self.busy = busy; self.services = services
        self.routerSlowing = routerSlowing; self.lastSpeed = lastSpeed; self.now = now
    }
}

/// The diagnosis' verdict, for a shortcut's next step and for tests.
public enum NetworkCause: String, Sendable, CaseIterable {
    case checking, notConnected, portal, offline, routerUnreachable, wifi, busyApp, routerLink, provider, dns, unsteady, routerSlowing, serviceOutage, noReply, fine
    /// Something's wrong, and naming it needs Kilobat Pro.
    case locked
}

public enum SiriAnswers {
    // MARK: Why is my internet slow?

    public static func diagnosis(_ input: NetworkDiagnosisInput, pro: Bool, calendar: Calendar = .current) -> (answer: SiriAnswer, cause: NetworkCause) {
        guard let snapshot = input.snapshot else {
            return (SiriAnswer(title: String(localized: "Checking your connection…"),
                               sentence: String(localized: "Kilobat is still checking your connection. Ask again in a few seconds.", comment: "Siri: no health check has finished yet"),
                               tone: .unknown), .checking)
        }
        let facts = diagnosisFacts(snapshot)
        let internet = snapshot.internet.average, loss = snapshot.internet.lossPercent ?? 0
        let outageService = input.services.filter(\.outage).max { $0.state < $1.state }
        // Free and Pro alike: no network, the Wi-Fi's sign-in page, and a service's own outage.
        if snapshot.gateway == nil && internet == nil {
            return (SiriAnswer(title: String(localized: "Not connected"), sentence: String(localized: "Your Mac isn’t connected to a network right now. Join a Wi-Fi network or plug in a cable.", comment: "Siri: no router and no internet"),
                               tone: .problem, facts: facts, cause: String(localized: "Not connected")), .notConnected)
        }
        if snapshot.captivePortal == true {
            let title = snapshot.portalLoggedOut == true ? String(localized: "Logged out by the Wi-Fi’s sign-in page", comment: "Diagnosis: a hotel or café Wi-Fi's sign-in ran out")
                                                          : String(localized: "Network login needed")
            let sentence = snapshot.portalLoggedOut == true
                ? String(localized: "The Wi-Fi’s sign-in page logged you out, so nothing loads until you sign in again. The internet itself isn’t down.", comment: "Siri: a hotel or café Wi-Fi's sign-in ran out")
                : String(localized: "This network wants you to sign in on its login page first. Open any website to get it.", comment: "Siri: a captive portal is in the way")
            return (SiriAnswer(title: title, sentence: sentence, tone: .problem, facts: facts, cause: title), .portal)
        }
        let offline = input.outage != nil
        let lineFine = ServiceTriggers.lineFine(snapshot) && input.outage == nil
        if let service = outageService, lineFine, snapshot.health == .good || !pro {
            return (serviceAnswer(service, notYou: true, facts: facts), .serviceOutage)
        }
        if !pro {
            let answer = freeDiagnosis(snapshot, offline: offline, facts: facts, input: input)
            return (answer, answer.upsell != nil ? .locked : internet == nil ? .noReply : .fine)
        }
        let since = { (bad: ([DiagnosticSnapshot]) -> Bool) in Self.since(history: input.history, network: snapshot.networkKey, now: input.now, bad: bad) }
        let wifi = snapshot.radio.rssi != nil && snapshot.wiredInterface == nil
        func answer(_ cause: NetworkCause, _ title: String, _ sentence: String, tone: SiriAnswer.Tone = .problem) -> (SiriAnswer, NetworkCause) {
            (SiriAnswer(title: title, sentence: sentence, tone: tone, facts: facts, cause: cause == .fine ? nil : title), cause)
        }
        if let outage = input.outage {
            if snapshot.router?.average == nil && snapshot.gateway != nil {
                return answer(.routerUnreachable, String(localized: "Can’t reach the router"),
                              String(localized: "Your Mac can’t reach the router, so the trouble is the Wi-Fi or the router itself. Turn Wi-Fi off and on, then restart the router.", comment: "Siri: the router doesn't answer"))
            }
            let start = moment(outage.start, now: input.now, calendar: calendar)
            return answer(.offline, String(localized: "Internet down past the router"),
                          wifi ? String(localized: "Your Wi-Fi and router are fine, but nothing past them answers: the internet has been down since \(start). It’s in your provider report.", comment: "Siri: an outage beyond the router; the argument is a time such as 9:12 PM")
                               : String(localized: "Your router is fine, but nothing past it answers: the internet has been down since \(start). It’s in your provider report.", comment: "Siri: an outage beyond the router; the argument is a time such as 9:12 PM"))
        }
        if snapshot.radio.health == .poor || snapshot.radio.health == .degraded {
            let title = String(localized: "Weak or noisy Wi-Fi")
            let sentence = snapshot.radio.rssi.map { String(localized: "Your Wi-Fi signal is weak (\($0) dBm), and that’s the bottleneck. Move closer to the router, or use Radar in Kilobat to find a stronger spot.", comment: "Siri; the argument is a signal level such as -78") }
                ?? String(localized: "Your Wi-Fi signal is noisy, and that’s the bottleneck. Move closer to the router, or use Radar in Kilobat to find a stronger spot.", comment: "Siri")
            return answer(.wifi, title, sentence, tone: snapshot.radio.health == .poor ? .problem : .caution)
        }
        let degraded = snapshot.health != .good
        if let app = input.busy.first, app.heavy {
            let rate = TrafficFormat.rate(app.rate)
            let title = String(localized: "\(app.name) is filling your line", comment: "Siri snippet title; the argument is an app such as Dropbox")
            let sentence: String = switch (degraded, app.uploading) {
            case (true, true): String(localized: "\(app.name) is uploading at \(rate), which is filling your line. Pause it, and everything else should speed up.", comment: "Siri; the arguments are an app and a rate such as 4.2 MB/s")
            case (true, false): String(localized: "\(app.name) is downloading at \(rate), which is filling your line. Pause it, and everything else should speed up.", comment: "Siri; the arguments are an app and a rate such as 4.2 MB/s")
            case (false, true): String(localized: "Your connection is healthy, but \(app.name) is uploading at \(rate) and taking most of it. Pause it if other apps feel slow.", comment: "Siri; the arguments are an app and a rate such as 4.2 MB/s")
            case (false, false): String(localized: "Your connection is healthy, but \(app.name) is downloading at \(rate) and taking most of it. Pause it if other apps feel slow.", comment: "Siri; the arguments are an app and a rate such as 4.2 MB/s")
            }
            return answer(.busyApp, title, sentence, tone: degraded ? .problem : .caution)
        }
        if let router = snapshot.router?.average, router > 20 {
            return answer(.routerLink, String(localized: "Slow link to the router"),
                          String(localized: "The link between your Mac and the router is slow: \(ms(router)) to the router. Move closer or pause big transfers before you restart the router.", comment: "Siri; the argument is a latency such as 45 ms"), tone: .caution)
        }
        // No reply at all, with no outage open: the target may just ignore ping.
        if internet == nil { return (fine(snapshot, input: input, facts: facts), .noReply) }
        let routerFine = (snapshot.router?.average ?? 0) <= 20
        if routerFine, loss >= 3 || (internet ?? 0) > 120 {
            let lossy = loss >= 3
            let start = since { checks in
                lossy ? checks.compactMap(\.internet.lossPercent).reduce(0, +) / Double(max(1, checks.count)) >= 2
                      : median(checks.compactMap(\.internet.average)) > 100
            }
            let runLoss = start.map { start in
                let run = input.history.filter { $0.date >= start && $0.networkKey == snapshot.networkKey }.compactMap { $0.internet.lossPercent }
                return run.isEmpty ? loss : run.reduce(0, +) / Double(run.count)
            } ?? loss
            let percent = "\(Int(max(1, runLoss.rounded())))%", latency = ms(internet ?? 0)
            let when = start.map { moment($0, now: input.now, calendar: calendar) }
            let sentence: String = switch (lossy, wifi, when) {
            case (true, true, let when?): String(localized: "Your Wi-Fi is fine; your provider’s line is losing \(percent) of packets since \(when). It’s in your provider report.", comment: "Siri; the arguments are a share such as 4% and a time such as 9:00 PM")
            case (true, false, let when?): String(localized: "Your connection to the router is fine; your provider’s line is losing \(percent) of packets since \(when). It’s in your provider report.", comment: "Siri; the arguments are a share such as 4% and a time such as 9:00 PM")
            case (true, true, nil): String(localized: "Your Wi-Fi is fine; your provider’s line is losing \(percent) of packets right now. If it keeps up, it’s in your provider report.", comment: "Siri; the argument is a share such as 4%")
            case (true, false, nil): String(localized: "Your connection to the router is fine; your provider’s line is losing \(percent) of packets right now. If it keeps up, it’s in your provider report.", comment: "Siri; the argument is a share such as 4%")
            case (false, true, let when?): String(localized: "Your Wi-Fi is fine; the internet past your router is slow, \(latency), since \(when). It’s in your provider report.", comment: "Siri; the arguments are a latency such as 180 ms and a time such as 9:00 PM")
            case (false, false, let when?): String(localized: "Your connection to the router is fine; the internet past it is slow, \(latency), since \(when). It’s in your provider report.", comment: "Siri; the arguments are a latency such as 180 ms and a time such as 9:00 PM")
            case (false, true, nil): String(localized: "Your Wi-Fi is fine; the internet past your router is slow right now, \(latency). The provider may be congested; try again later or another network.", comment: "Siri; the argument is a latency such as 180 ms")
            case (false, false, nil): String(localized: "Your connection to the router is fine; the internet past it is slow right now, \(latency). The provider may be congested; try again later or another network.", comment: "Siri; the argument is a latency such as 180 ms")
            }
            return answer(.provider, lossy ? String(localized: "Packet loss past the router") : String(localized: "Slow internet past the router"), sentence, tone: lossy && loss >= 20 ? .problem : .caution)
        }
        if let dns = snapshot.dnsMilliseconds, dns > 150 {
            return answer(.dns, String(localized: "Slow DNS lookups"),
                          String(localized: "Websites are slow to start loading because name lookups take \(ms(dns)). Try Cloudflare or Google DNS in Kilobat’s Health tab.", comment: "Siri; the argument is a duration such as 320 ms"), tone: .caution)
        }
        if let jitter = snapshot.internet.jitter, jitter > 30 {
            return answer(.unsteady, String(localized: "Unsteady latency"),
                          String(localized: "Your connection is unsteady: replies vary by \(ms(jitter)). A speed test in Kilobat shows whether other transfers make it worse.", comment: "Siri; the argument is a jitter such as 45 ms"), tone: .caution)
        }
        if let router = input.routerSlowing {
            return answer(.routerSlowing, router.headline, [router.headline, router.advice].compactMap { $0 }.joined(separator: " "), tone: .caution)
        }
        if let service = outageService {
            return (serviceAnswer(service, notYou: lineFine, facts: facts), .serviceOutage)
        }
        return (fine(snapshot, input: input, facts: facts), .fine)
    }

    private static func freeDiagnosis(_ snapshot: DiagnosticSnapshot, offline: Bool, facts: [SiriAnswer.Fact], input: NetworkDiagnosisInput) -> SiriAnswer {
        if offline {
            return SiriAnswer(title: String(localized: "The internet isn’t answering"), sentence: String(localized: "The internet isn’t answering right now.", comment: "Siri without Kilobat Pro: an outage"),
                              tone: .problem, facts: facts, upsell: String(localized: "Kilobat Pro tells you where it breaks.", comment: "Siri without Kilobat Pro"))
        }
        guard snapshot.internet.average != nil else { return fine(snapshot, input: input, facts: facts) }
        let latency = ms(snapshot.internet.average ?? 0), loss = "\(Int((snapshot.internet.lossPercent ?? 0).rounded()))%"
        switch snapshot.health {
        case .good, .unknown: return fine(snapshot, input: input, facts: facts)
        case .degraded:
            return SiriAnswer(title: String(localized: "Unstable"), sentence: String(localized: "Your connection is unsteady right now: \(latency) to the internet and \(loss) packet loss.", comment: "Siri without Kilobat Pro; the arguments are a latency and a share"),
                              tone: .caution, facts: facts, upsell: String(localized: "Kilobat Pro tells you why, and what to do.", comment: "Siri without Kilobat Pro"))
        case .poor:
            return SiriAnswer(title: String(localized: "Poor connection"), sentence: String(localized: "Your connection is poor right now: \(latency) to the internet and \(loss) packet loss.", comment: "Siri without Kilobat Pro; the arguments are a latency and a share"),
                              tone: .problem, facts: facts, upsell: String(localized: "Kilobat Pro tells you why, and what to do.", comment: "Siri without Kilobat Pro"))
        }
    }

    private static func fine(_ snapshot: DiagnosticSnapshot, input: NetworkDiagnosisInput, facts: [SiriAnswer.Fact]) -> SiriAnswer {
        guard let latency = snapshot.internet.average else {
            let sentence = snapshot.router?.average == nil
                ? String(localized: "Neither the router nor the internet answered this check. If pages don’t load, turn Wi-Fi off and on, then ask again.", comment: "Siri")
                : String(localized: "Your router answers, but the ping target didn’t. Some networks block ping, so this alone doesn’t mean the internet is down.", comment: "Siri")
            return SiriAnswer(title: String(localized: "Taking a closer look."), sentence: sentence, tone: .unknown, facts: facts)
        }
        let loss = Int((snapshot.internet.lossPercent ?? 0).rounded())
        var sentence = loss == 0 ? String(localized: "Your connection looks fine: \(ms(latency)) to the internet and no packet loss.", comment: "Siri; the argument is a latency such as 18 ms")
                                 : String(localized: "Your connection looks fine: \(ms(latency)) to the internet and \(loss)% packet loss.", comment: "Siri; the arguments are a latency such as 18 ms and a percentage")
        if let speed = input.lastSpeed, input.now.timeIntervalSince(speed.date) < 7 * 86_400 {
            sentence += " " + String(localized: "Your last speed test got \(mbps(speed.downloadMbps)) Mbps down and \(mbps(speed.uploadMbps)) up.", comment: "Siri; the arguments are speeds such as 87 and 24")
        } else {
            sentence += " " + String(localized: "If one app is still slow, the trouble may be on its side.", comment: "Siri, after a healthy check")
        }
        return SiriAnswer(title: String(localized: "Looking good."), sentence: sentence, tone: .good, facts: facts)
    }

    static func diagnosisFacts(_ snapshot: DiagnosticSnapshot) -> [SiriAnswer.Fact] {
        var facts: [SiriAnswer.Fact] = []
        let loss = snapshot.internet.lossPercent
        facts.append(.init(String(localized: "Internet"), snapshot.internet.average.map(ms) ?? "—", warning: (snapshot.internet.average ?? 0) > 120))
        if let loss { facts.append(.init(String(localized: "Packet loss"), "\(Int(loss.rounded()))%", warning: loss >= 3)) }
        if let router = snapshot.router?.average { facts.append(.init(String(localized: "Router"), ms(router), warning: router > 20)) }
        if let rssi = snapshot.radio.rssi, snapshot.wiredInterface == nil { facts.append(.init(String(localized: "Wi-Fi signal"), "\(rssi) dBm", warning: snapshot.radio.health != .good)) }
        if let dns = snapshot.dnsMilliseconds { facts.append(.init(String(localized: "DNS"), ms(dns), warning: dns > 150)) }
        return facts
    }

    /// When a problem began: the start of the latest run of 15-minute stretches whose checks on this network were bad
    /// together (`bad` judges a stretch's checks), within the last day. Nil when it's newer than 20 minutes, so "since" is only said when it means something.
    public static func since(history: [DiagnosticSnapshot], network: String, now: Date, bad: ([DiagnosticSnapshot]) -> Bool) -> Date? {
        let window: TimeInterval = 900
        let samples = history.filter { $0.networkKey == network && $0.date <= now && now.timeIntervalSince($0.date) <= 86_400 }
        guard !samples.isEmpty else { return nil }
        let buckets = Dictionary(grouping: samples) { Int($0.date.timeIntervalSinceReferenceDate / window) }
        var bucket = Int(now.timeIntervalSinceReferenceDate / window)
        var start: Date?
        // The current stretch may have no check yet; one empty stretch is a gap, two end the run.
        var empty = 0
        while bucket >= buckets.keys.min() ?? bucket {
            if let checks = buckets[bucket] {
                guard bad(checks) else { break }
                start = checks.map(\.date).min(); empty = 0
            } else {
                empty += 1
                if empty > 1 { break }
            }
            bucket -= 1
        }
        guard let start, now.timeIntervalSince(start) >= 1200 else { return nil }
        return start
    }

    // MARK: Why did my call freeze?

    public static func call(_ report: CallReport?, enabled: Bool = true, pro: Bool, now: Date = Date(), calendar: Calendar = .current) -> SiriAnswer {
        guard let report else {
            return enabled ? SiriAnswer(title: String(localized: "No calls yet"), sentence: String(localized: "Kilobat hasn’t heard a call yet. After each Zoom, Meet, Teams, FaceTime or other call, it writes a report of what got in the way.", comment: "Siri: no call reports"), tone: .unknown)
                           : SiriAnswer(title: String(localized: "Call reports are off"), sentence: String(localized: "Call reports are off. Turn them on in Kilobat’s settings, and Kilobat explains each call’s freezes.", comment: "Siri: call reports are turned off"), tone: .unknown)
        }
        let when = clock(report.start, now: now, calendar: calendar)
        let head: String = report.browser ? String(localized: "Your call in \(report.app) \(when)", comment: "Siri: the start of a call report sentence; the arguments are a browser such as Safari and a time such as “at 2:15 PM”")
                                          : String(localized: "Your \(report.app) call \(when)", comment: "Siri: the start of a call report sentence; the arguments are an app such as Zoom and a time such as “at 2:15 PM”")
        var facts = [SiriAnswer.Fact(String(localized: "Length"), Duration.seconds(max(60, report.seconds)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))),
                     SiriAnswer.Fact(String(localized: "Freezes"), "\(report.freezes.count)", warning: !report.freezes.isEmpty)]
        if let median = report.median { facts.append(.init(String(localized: "Ping"), ms(median))) }
        facts.append(.init(String(localized: "Packet loss"), String(format: "%.1f%%", report.lossPercent), warning: report.lossPercent >= 2))
        // The calling service's own outage is free to know, as in the notification.
        let service = report.service.flatMap { $0.problem ? $0.reported : nil }
        if report.clean {
            return SiriAnswer(title: report.count, sentence: String(localized: "\(head) was clean, with no freezes.", comment: "Siri; the argument is like “Your Zoom call at 2:15 PM”"), tone: .good, facts: facts)
        }
        let tone: SiriAnswer.Tone = report.freezes.count >= 3 ? .problem : .caution
        guard pro else {
            let sentence = report.freezes.isEmpty ? String(localized: "\(head) had no network freezes, but the Mac was overloaded.", comment: "Siri; the argument is like “Your Zoom call at 2:15 PM”")
                : String(localized: "\(head) had \(report.count).", comment: "Siri; the arguments are like “Your Zoom call at 2:15 PM” and “3 freezes”")
            return SiriAnswer(title: report.count, sentence: [sentence, service].compactMap { $0 }.joined(separator: " "), tone: tone, facts: facts,
                              upsell: String(localized: "Kilobat Pro tells you why.", comment: "Siri without Kilobat Pro, after a call report"))
        }
        let sentence: String
        if report.freezes.isEmpty {
            sentence = String(localized: "\(head) had no network freezes, but the Mac was overloaded.", comment: "Siri; the argument is like “Your Zoom call at 2:15 PM”") + (report.macDetail.map { " " + $0 } ?? "")
        } else {
            let verdict = report.verdict
            // "3 freezes, caused by …" or "3 freezes: 2 caused by …": the count leads, so it reads on from "had".
            sentence = String(localized: "\(head) had \(verdict).", comment: "Siri; the arguments are like “Your Zoom call at 2:15 PM” and “3 freezes, caused by Dropbox uploading”")
                + (report.advice.map { " " + $0 } ?? "")
        }
        let cause = report.causes.first.map { $0.cause.phrase } ?? (report.strain.isEmpty ? nil : String(localized: "Mac overloaded", comment: "Call report: the network was fine but the Mac itself was struggling"))
        return SiriAnswer(title: report.verdict, sentence: sentence, tone: tone, facts: facts, cause: cause)
    }

    // MARK: Is Slack down?

    /// One service, or the services of the apps in use. `lineFine` only when this Mac's own check passed, so "not you" is earned.
    public static func services(_ statuses: [ServiceStatus], lineFine: Bool) -> SiriAnswer {
        let read = statuses.filter { $0.state != .unknown }
        guard !statuses.isEmpty else {
            return SiriAnswer(title: String(localized: "No status pages to check"), sentence: String(localized: "None of the apps you’re using now has a status page Kilobat knows. Ask about one by name, such as Slack or Zoom.", comment: "Siri"), tone: .unknown)
        }
        guard !read.isEmpty else {
            let status = statuses[0]
            return SiriAnswer(title: status.state.title, sentence: status.sentence(notYou: false), tone: .unknown, facts: serviceFacts(statuses))
        }
        let problems = read.filter(\.problem).sorted { $0.state > $1.state }
        if let worst = problems.first {
            var answer = serviceAnswer(worst, notYou: lineFine && worst.outage, facts: serviceFacts(statuses))
            if problems.count > 1 {
                let others = problems.dropFirst().map(\.service).formatted(.list(type: .and))
                answer = SiriAnswer(title: answer.title, sentence: answer.sentence + " " + String(localized: "\(others) report problems too.", comment: "Siri; the argument lists services such as Zoom and GitHub"),
                                    tone: answer.tone, facts: answer.facts, cause: answer.cause)
            }
            return answer
        }
        let sentence = read.count == 1 ? read[0].sentence(notYou: false)
            : String(localized: "Status pages for \(read.map(\.service).formatted(.list(type: .and))) report no problems.", comment: "Health; the argument lists services such as Slack and Zoom")
        return SiriAnswer(title: String(localized: "No problems reported", comment: "A service's status page shows everything working"), sentence: sentence, tone: .good, facts: serviceFacts(statuses))
    }

    private static func serviceAnswer(_ status: ServiceStatus, notYou: Bool, facts: [SiriAnswer.Fact]) -> SiriAnswer {
        let sentence = status.sentence(notYou: notYou)
        return SiriAnswer(title: status.alertTitle(), sentence: sentence.hasSuffix(".") ? sentence : sentence + ".", tone: status.outage ? .problem : .caution,
                          facts: facts, cause: status.alertTitle())
    }

    private static func serviceFacts(_ statuses: [ServiceStatus]) -> [SiriAnswer.Fact] {
        statuses.prefix(6).map { SiriAnswer.Fact($0.service, $0.state.title, warning: $0.problem) }
    }

    // MARK: What's using my internet?

    public static func usageNow(_ apps: [BusyApp], download: Double, upload: Double) -> SiriAnswer {
        let top = apps.filter { $0.rate >= 5_000 }.sorted { $0.rate > $1.rate }.prefix(3)
        let total = TrafficFormat.rate(download + upload)
        var facts = top.map { SiriAnswer.Fact($0.name, "↓ \(TrafficFormat.rate($0.download))  ↑ \(TrafficFormat.rate($0.upload))", warning: $0.heavy) }
        facts.append(.init(String(localized: "All apps"), "↓ \(TrafficFormat.rate(download))  ↑ \(TrafficFormat.rate(upload))"))
        guard let first = top.first else {
            return SiriAnswer(title: String(localized: "Quiet right now"), sentence: String(localized: "Nothing much right now: all your apps together use \(total).", comment: "Siri; the argument is a rate such as 12 KB/s"), tone: .good, facts: facts)
        }
        var sentence = first.uploading
            ? String(localized: "\(first.name) is using the most right now, uploading at \(TrafficFormat.rate(first.rate)).", comment: "Siri; the arguments are an app and a rate")
            : String(localized: "\(first.name) is using the most right now, downloading at \(TrafficFormat.rate(first.rate)).", comment: "Siri; the arguments are an app and a rate")
        let rest = top.dropFirst().map { String(localized: "\($0.name) at \(TrafficFormat.rate($0.rate))", comment: "Siri: an app and its rate, in a list such as “Dropbox at 1.2 MB/s and Safari at 300 KB/s”") }
        if !rest.isEmpty { sentence += " " + String(localized: "Then \(rest.formatted(.list(type: .and))).", comment: "Siri; the argument lists apps with rates") }
        return SiriAnswer(title: String(localized: "\(first.name) uses the most", comment: "Siri snippet title; the argument is an app"), sentence: sentence, tone: first.heavy ? .caution : .good, facts: facts)
    }

    // MARK: How much data have I used?

    public struct Budget: Sendable {
        public let used: UInt64
        public let limitGB: Double
        public let cycle: BudgetCycle
        public init(used: UInt64, limitGB: Double, cycle: BudgetCycle) { self.used = used; self.limitGB = limitGB; self.cycle = cycle }
    }

    /// Today's internet use on every network, and the current network's budget when it has one worth saying.
    public static func dataUsed(received: UInt64, sent: UInt64, topApps: [String], budget: Budget?, now: Date = Date(), calendar: Calendar = .current) -> SiriAnswer {
        let total = TrafficFormat.bytes(received + sent), down = TrafficFormat.bytes(received), up = TrafficFormat.bytes(sent)
        let apps = topApps.prefix(2)
        var sentence = apps.isEmpty ? String(localized: "You’ve used \(total) today: \(down) down and \(up) up.", comment: "Siri; the arguments are amounts such as 3.2 GB")
            : String(localized: "You’ve used \(total) today: \(down) down and \(up) up, mostly \(apps.formatted(.list(type: .and))).", comment: "Siri; the arguments are amounts such as 3.2 GB, then apps")
        var facts = [SiriAnswer.Fact(String(localized: "Today"), total), .init(String(localized: "Download"), down), .init(String(localized: "Upload"), up)]
        var tone = SiriAnswer.Tone.good
        if let budget, budget.limitGB > 0 {
            let used = (Double(budget.used) / 1_000_000_000).formatted(.number.precision(.fractionLength(0...1)))
            let fraction = Double(budget.used) / (budget.limitGB * 1_000_000_000)
            sentence += " " + String(localized: "This network’s budget: \(used) of \(budget.limitGB.formatted()) GB used \(budget.cycle.period.phrase).", comment: "Siri; the arguments are amounts in GB and a period such as “this month”")
            facts.append(.init(String(localized: "Budget"), budget.cycle.progress(used: budget.used, limitGB: budget.limitGB, now: now, calendar: calendar), warning: fraction >= 0.8))
            if fraction >= 1 { tone = .problem } else if fraction >= 0.8 { tone = .caution }
        }
        return SiriAnswer(title: String(localized: "\(total) today", comment: "Siri snippet title; the argument is an amount such as 3.2 GB"), sentence: sentence, tone: tone, facts: facts)
    }

    // MARK: Is my VPN leaking?

    public static func leak(_ test: LeakTest) -> SiriAnswer {
        let facts = test.checks.map { SiriAnswer.Fact($0.title, word($0.status), warning: $0.status == .fail) }
        if test.checks.allSatisfy({ $0.status == .skipped }) {
            return SiriAnswer(title: String(localized: "No VPN to check"), sentence: test.summary, tone: .unknown, facts: facts)
        }
        guard let failed = test.checks.first(where: { $0.status == .fail }) else {
            return SiriAnswer(title: String(localized: "No leaks found"), sentence: test.summary, tone: .good, facts: facts)
        }
        return SiriAnswer(title: String(localized: "Your VPN is leaking"), sentence: [test.summary, failed.fix].compactMap { $0 }.joined(separator: " "), tone: .problem, facts: facts,
                          cause: test.checks.filter { $0.status == .fail }.map(\.title).formatted(.list(type: .and)))
    }

    private static func word(_ status: LeakTest.Status) -> String {
        switch status {
        case .pass: String(localized: "Stays in the VPN", comment: "Leak test result for one check")
        case .fail: String(localized: "Leaks", comment: "Leak test result for one check")
        case .warning: String(localized: "Check", comment: "Leak test result for one check: worth a look")
        case .skipped: String(localized: "Not checked", comment: "Leak test result for one check")
        }
    }

    // MARK: Am I ready for my call?

    public static func preflight(_ result: Preflight, pro: Bool) -> SiriAnswer {
        let facts = result.issues.map { SiriAnswer.Fact(String(localized: "Issue"), $0.phrase.prefix(1).uppercased() + $0.phrase.dropFirst(), warning: true) }
        guard let first = result.issues.first else {
            return SiriAnswer(title: String(localized: "Ready for your call"), sentence: String(localized: "You’re ready: the line looks good, and nothing is hogging it.", comment: "Siri before a call"), tone: .good)
        }
        let holdable = result.holdable
        var sentence = String(localized: "Not quite: \(result.issues.map(\.phrase).formatted(.list(type: .and))).", comment: "Siri before a call; the argument is like “Dropbox is uploading and Wi-Fi is weak”")
        var upsell: String?
        if !holdable.isEmpty {
            if pro { sentence += " " + String(localized: "Turn on call mode in Kilobat to pause \(holdable.formatted(.list(type: .and))) until the call ends.", comment: "Siri before a call; the argument lists apps") }
            else { upsell = String(localized: "Kilobat Pro can pause them until the call ends.", comment: "Notification before a meeting, without Pro") }
        } else {
            let fix: String = switch first.kind {
            case .app: String(localized: "Pause \(first.app ?? "that app") before the call.", comment: "Siri before a call; the argument is an app")
            case .wifi: String(localized: "Move closer to the router, or use Radar to find a stronger spot.", comment: "Call report advice")
            case .unstable: String(localized: "If it keeps dropping, use another network or a hotspot for the call.", comment: "Siri before a call")
            case .airDrop: String(localized: "Turn on low latency before calls; it pauses AirDrop until you turn it off.", comment: "Call report advice")
            case .mac: first.app.map { String(localized: "Quit \($0) during calls, or turn off video effects in the call app.", comment: "Call report advice; the argument is a process") }
                ?? String(localized: "Quit heavy apps during calls, or turn off video effects in the call app.", comment: "Call report advice")
            }
            sentence += " " + fix
        }
        return SiriAnswer(title: String(localized: "Not quite ready"), sentence: sentence, tone: result.issues.contains { $0.kind == .unstable || $0.kind == .wifi } ? .problem : .caution,
                          facts: facts, upsell: upsell, cause: result.summary)
    }

    // MARK: How fast is my internet?

    public static func speed(_ result: SpeedTestResult) -> SiriAnswer {
        let down = mbps(result.downloadMbps), up = mbps(result.uploadMbps)
        let load: String = switch result.bufferbloat {
        case "Low": String(localized: "and latency stays low under load", comment: "Siri, after a speed test")
        case "Moderate": String(localized: "and latency rises a little under load", comment: "Siri, after a speed test")
        case "High": String(localized: "but latency climbs a lot under load", comment: "Siri, after a speed test")
        default: String(localized: "and latency under load couldn’t be judged", comment: "Siri, after a speed test")
        }
        let video = result.videoReadiness
        let calls: String
        if video == "Low bandwidth" { calls = String(localized: "Too slow for video calls.", comment: "Siri, after a speed test") }
        else if !result.callCautionReasons.isEmpty { calls = String(localized: "Video calls may stutter.", comment: "Siri, after a speed test") }
        else if video.hasPrefix("1080p") { calls = String(localized: "Good for HD video calls.", comment: "Siri, after a speed test") }
        else { calls = String(localized: "Fine for video calls at lower quality.", comment: "Siri, after a speed test") }
        let sentence = String(localized: "\(down) Mbps down and \(up) up, \(load). \(calls)", comment: "Siri, after a speed test; the arguments are speeds, a phrase about latency under load, and a sentence about video calls")
        let tone: SiriAnswer.Tone = video == "Low bandwidth" || result.bufferbloat == "High" ? .problem : result.callCautionReasons.isEmpty ? .good : .caution
        var facts = [SiriAnswer.Fact(String(localized: "Download"), "\(down) Mbps"), .init(String(localized: "Upload"), "\(up) Mbps")]
        if let idle = result.baseline.average { facts.append(.init(String(localized: "Ping"), ms(idle))) }
        if let added = result.addedLatency { facts.append(.init(String(localized: "Under load"), "+" + ms(added), warning: added >= 60)) }
        return SiriAnswer(title: String(localized: "\(down) Mbps down", comment: "Siri snippet title after a speed test"), sentence: sentence, tone: tone, facts: facts)
    }

    // MARK: Words

    static func ms(_ value: Double) -> String { "\(Int(value.rounded())) ms" }
    static func mbps(_ value: Double) -> String { value >= 10 ? "\(Int(value.rounded()))" : value.formatted(.number.precision(.fractionLength(0...1))) }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// "9:12 PM" today, "yesterday, 9:12 PM", else the date and time: for "since …".
    static func moment(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar, timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "yesterday, \(time)", comment: "Siri: since when; the argument is a time such as 9:12 PM")
        }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar, timeZone: calendar.timeZone))
    }

    /// "at 9:12 PM" today, "yesterday at 9:12 PM", else the date and time.
    static func clock(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar, timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "at \(time)", comment: "Siri: when something happened today; the argument is a time such as 9:12 PM") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "yesterday at \(time)", comment: "Siri: when something happened; the argument is a time such as 9:12 PM")
        }
        let day = date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar, timeZone: calendar.timeZone))
        return String(localized: "on \(day) at \(time)", comment: "Siri: when something happened; the arguments are a date such as Oct 30 and a time")
    }
}

/// Finding what Siri or a shortcut names: a call report, a status page.
public enum SiriLookup {
    /// "the last call", "my Zoom call": reports newest first, those whose app matches the words when there are any.
    public static func calls(_ reports: [CallReport], matching text: String? = nil) -> [CallReport] {
        let newest = reports.sorted { $0.start > $1.start }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty else { return newest }
        let generic: Set<String> = ["call", "calls", "the", "my", "last", "latest", "recent", "meeting"]
        let words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !generic.contains($0) }
        guard !words.isEmpty else { return newest }
        return newest.filter { report in words.allSatisfy { report.app.lowercased().contains($0) } }
    }

    /// Status pages for what a person says: "Slack", "google meet", "github.com", "claude" (every part of Anthropic's page).
    public static func services(matching text: String) -> [StatusService] {
        let found = ServiceCatalog.find(text)
        if !found.isEmpty { return found }
        // "the Slack", "Slack app": the same words without filler.
        let filler: Set<String> = ["the", "app", "service", "website", "site", "is", "down"]
        let words = text.lowercased().split(separator: " ").map(String.init).filter { !filler.contains($0) }
        return words.isEmpty ? [] : ServiceCatalog.find(words.joined(separator: " "))
    }

    /// The services Siri can name in "Is … down": every page in the catalog, by name.
    public static var suggestedServices: [StatusService] { ServiceCatalog.services.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
}
