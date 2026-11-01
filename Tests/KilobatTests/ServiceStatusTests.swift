import Foundation
import Testing
@testable import KilobatCore

struct ServiceStatusTests {
    private let now = ServiceStatusParser.date("2026-10-31T12:00:00Z")!
    private func service(_ id: String) -> StatusService { ServiceCatalog.services.first { $0.id == id }! }
    private func parse(_ fixture: String, _ id: String) throws -> ServiceStatus {
        try ServiceStatusParser.parse(Data(fixture.utf8), for: service(id), now: now)
    }

    // MARK: Statuspage

    @Test func readsAStatuspageIncidentAsTheHeadline() throws {
        let status = try parse(ServiceStatusFixtures.statuspageMinor, "epic")
        #expect(status.state == .degraded)
        #expect(status.incident == "Epic Games Store iOS Issue")
        #expect(status.page.absoluteString == "https://stspg.io/rw2pchzb9hd7")
        #expect(status.started == ServiceStatusParser.date("2026-10-30T22:10:47.039Z"))
        #expect(status.sentence(notYou: true) == "Epic Games reports problems on its side — Epic Games Store iOS Issue")
    }

    @Test func aMajorOutageIsDownForEveryone() throws {
        let status = try parse(ServiceStatusFixtures.statuspageCritical, "epic")
        #expect(status.state == .majorOutage)
        #expect(status.outage)
        #expect(status.sentence(notYou: true) == "Epic Games is down for everyone, not you — Fortnite login failures")
        #expect(status.sentence(notYou: false) == "Epic Games is down for everyone — Fortnite login failures")
    }

    @Test func greenPagesSayNoProblemsAndKeepThePage() throws {
        let github = try parse(ServiceStatusFixtures.statuspageOperational, "github")
        #expect(github.state == .operational)
        #expect(github.incident == nil)
        #expect(github.page.absoluteString == "https://www.githubstatus.com")
        #expect(github.sentence(notYou: true) == "GitHub’s status page reports no problems.")
        let openai = try parse(ServiceStatusFixtures.incidentioOperational, "chatgpt")
        #expect(openai.state == .operational)
        #expect(openai.sentence(notYou: true) == "OpenAI’s status page reports no problems with ChatGPT.")
    }

    /// A fix in place doesn't make a green page red, even when the incident was major (MongoDB's had been monitored for weeks).
    @Test func monitoredIncidentsDontRaiseAGreenPage() throws {
        #expect(try parse(ServiceStatusFixtures.statuspageMonitoring, "figma").state == .operational)
        #expect(try parse(ServiceStatusFixtures.statuspageMonitoringMajor, "figma").state == .operational)
        #expect(try parse(ServiceStatusFixtures.statuspageMonitoring, "figma").incident == nil)
    }

    /// Cloudflare's indicator read "major" with no incident: a few data centers rerouted, as every day.
    @Test func cloudflareCountsIncidentsNotItsIndicator() throws {
        let status = try parse(ServiceStatusFixtures.statuspageRerouted, "cloudflare")
        #expect(status.state == .operational)
        // The same page read as an ordinary one would call it a partial outage.
        let plain = StatusService(id: "x", name: "X", feed: .statuspage(URL(string: "https://example.com")!), page: URL(string: "https://example.com")!, apps: [], hosts: [])
        #expect(try ServiceStatusParser.parse(Data(ServiceStatusFixtures.statuspageRerouted.utf8), for: plain, now: now).state == .partialOutage)
    }

    @Test func maintenanceInProgressNamesTheWindow() throws {
        let status = try parse(ServiceStatusFixtures.statuspageMaintenance, "epic")
        #expect(status.state == .maintenance)
        #expect(status.incident == "Fortnite: Downtime for v43.00 Update")
        #expect(status.problem && !status.outage)
        // Zoom's page stays green through a weeks-long window marked No Operational Impact; so does Kilobat.
        #expect(try parse(ServiceStatusFixtures.statuspageQuietMaintenance, "zoom").state == .operational)
    }

    // MARK: Custom formats

    @Test func slack() throws {
        #expect(try parse(ServiceStatusFixtures.slackOK, "slack").state == .operational)
        let down = try parse(ServiceStatusFixtures.slackIncident, "slack")
        #expect(down.state == .partialOutage)
        #expect(down.incident == "Slack Real-Time Connection Disruption")
        #expect(down.page.absoluteString == "https://slack-status.com/2026-10/58a30c7fc8aa3e80")
        #expect(down.sentence(notYou: true) == "Part of Slack is down for everyone, not you — Slack Real-Time Connection Disruption")
    }

    @Test func googleWorkspaceOpenIncidentsByProduct() throws {
        let meet = try parse(ServiceStatusFixtures.googleIncidents, "meet")
        #expect(meet.state > .operational)
        #expect(meet.incident?.isEmpty == false)
        #expect(meet.incident?.contains("**") == false)
        #expect(meet.page.absoluteString.hasPrefix("https://www.google.com/appsstatus/dashboard/incidents/"))
        #expect(meet.sentence(notYou: false).hasPrefix("Google Meet"))
        // Ended incidents and other products don't count.
        let gmail = try parse(ServiceStatusFixtures.googleIncidents, "gmail")
        #expect(gmail.state == .operational)
        #expect(gmail.sentence(notYou: true) == "Google’s status page reports no problems with Gmail.")
    }

    @Test func googleSummaryLines() {
        #expect(ServiceStatusParser.summaryLine("**Summary:**\nMitigating elevated error rate.\n**Description:**\nMore") == "Mitigating elevated error rate.")
        #expect(ServiceStatusParser.summaryLine("# Incident Report\n## Summary\nStarting at 20:15 US/Pacific, Meet was down.") == "Starting at 20:15 US/Pacific, Meet was down.")
        #expect(ServiceStatusParser.summaryLine("**Summary**\nSome Meet customers may see an issue") == "Some Meet customers may see an issue")
    }

    @Test func appleOngoingEventsOnly() throws {
        let icloud = try parse(ServiceStatusFixtures.appleStatus, "icloud")
        #expect(icloud.state == .partialOutage)
        #expect(icloud.incident == "iCloud Mail: Some users are unable to send or receive email.")
        #expect(icloud.owner == "Apple")
        // Resolved events, such as the App Store's and Apple Business's that day, are history.
        #expect(try parse(ServiceStatusFixtures.appleStatus, "app-store").state == .operational)
        #expect(try parse(ServiceStatusFixtures.appleStatus, "facetime").sentence(notYou: true) == "Apple’s status page reports no problems with FaceTime.")
        // Served wrapped in a callback, as the file has been, it still reads.
        let wrapped = "jsonCallback(" + ServiceStatusFixtures.appleStatus + ");"
        #expect(try ServiceStatusParser.parse(Data(wrapped.utf8), for: service("icloud"), now: now).state == .partialOutage)
    }

    @Test func microsoftConsumerServices() throws {
        #expect(try parse(ServiceStatusFixtures.microsoftOK, "teams").state == .operational)
        let teams = try parse(ServiceStatusFixtures.microsoftDegraded, "teams")
        #expect(teams.state == .degraded)
        #expect(teams.incident == "Some users can’t join meetings")
        // Seven fractional digits, as Microsoft writes them.
        #expect(abs((teams.started?.timeIntervalSince(ServiceStatusParser.date("2026-10-31T09:12:00Z")!)) ?? 99) < 1)
        #expect(try parse(ServiceStatusFixtures.microsoftDegraded, "onedrive").state == .operational)
    }

    @Test func statusIOMaintenance() throws {
        let gitlab = try parse(ServiceStatusFixtures.statusIOMaintenance, "gitlab")
        #expect(gitlab.state == .maintenance)
        #expect(gitlab.incident == "Upcoming maintenance for the Customers Portal")
    }

    @Test func garbageIsAnErrorNotAnOutage() async {
        #expect(throws: (any Error).self) { try parse("<html>Service Unavailable</html>", "github") }
        let checker = ServiceStatusChecker { _ in throw URLError(.timedOut) }
        let status = await checker.check(service("github"), now: now)
        #expect(status.state == .unknown)
        #expect(!status.problem)
        #expect(status.sentence(notYou: true) == "Kilobat couldn’t read GitHub’s status page.")
    }

    @Test func oneRequestPerPageWhileFresh() async {
        actor Counter { var urls: [URL] = []; func add(_ url: URL) { urls.append(url) } }
        let counter = Counter()
        let checker = ServiceStatusChecker { url in await counter.add(url); return Data(ServiceStatusFixtures.googleIncidents.utf8) }
        let google = ["meet", "gmail", "google-drive"].map(service)
        let first = await checker.check(google, now: now)
        #expect(first.map(\.id) == ["meet", "gmail", "google-drive"])
        _ = await checker.check([service("gmail")], now: now.addingTimeInterval(60))
        #expect(await counter.urls.count == 1)
        _ = await checker.check([service("gmail")], now: now.addingTimeInterval(ServiceStatusChecker.freshFor + 1))
        #expect(await counter.urls.count == 2)
    }

    // MARK: Apps and sites to services

    @Test func mapsAppsAndHostsToServices() {
        #expect(ServiceCatalog.services(forApp: "com.tinyspeck.slackmacgap").map(\.id) == ["slack"])
        #expect(ServiceCatalog.services(forApp: "us.zoom.xos").map(\.id) == ["zoom"])
        #expect(ServiceCatalog.services(forApp: "com.microsoft.teams2").map(\.id) == ["teams"])
        #expect(ServiceCatalog.services(forApp: "process:claude").map(\.id) == ["claude-code"])
        #expect(ServiceCatalog.services(forApp: "process:claudette").isEmpty)
        #expect(ServiceCatalog.services(forApp: "com.apple.Safari").isEmpty)
        #expect(ServiceCatalog.services(forHost: "api.github.com").map(\.id) == ["github"])
        #expect(ServiceCatalog.services(forHost: "files.slack-edge.com.").map(\.id) == ["slack"])
        #expect(ServiceCatalog.services(forHost: "notgithub.com").isEmpty)
        #expect(Set(ServiceCatalog.services(forHost: "acme.atlassian.net").map(\.id)) == ["jira", "confluence"])
        #expect(ServiceCatalog.services(forCallApp: "Microsoft Teams").map(\.id) == ["teams"])
        #expect(ServiceCatalog.services(forCallApp: "FaceTime").map(\.id) == ["facetime"])
        #expect(ServiceCatalog.services(forCallApp: "Chrome").isEmpty)
    }

    @Test func findsWhatPeopleType() {
        #expect(ServiceCatalog.find("slack").map(\.id) == ["slack"])
        #expect(ServiceCatalog.find("Google Meet").map(\.id) == ["meet"])
        #expect(ServiceCatalog.find("https://github.com/apple/swift").map(\.id) == ["github"])
        #expect(ServiceCatalog.find("teams").map(\.id) == ["teams"])
        #expect(ServiceCatalog.find("openai").map(\.id) == ["chatgpt", "codex", "openai-api"])
        #expect(ServiceCatalog.find("chatgpt").map(\.id) == ["chatgpt"])
        #expect(ServiceCatalog.find("claude").map(\.id) == ["claude", "claude-code", "anthropic-api"])
        #expect(ServiceCatalog.find("claude code").map(\.id) == ["claude-code"])
        #expect(ServiceCatalog.find("us.zoom.xos").map(\.id) == ["zoom"])
        #expect(ServiceCatalog.find("myspace").isEmpty)
    }

    @Test func picksWhatKilobatDownChecks() throws {
        #expect(try ServiceCatalog.pick(["slack", "github.com", "Slack"], all: false, running: []).map(\.id) == ["slack", "github"])
        #expect(try ServiceCatalog.pick([], all: false, running: ["us.zoom.xos", "com.apple.Safari", "com.tinyspeck.slackmacgap", "us.zoom.ZoomPhone"]).map(\.id) == ["zoom", "slack"])
        #expect(try ServiceCatalog.pick([], all: true, running: []).count == ServiceCatalog.services.count)
        #expect(throws: ServiceCatalog.Unknown.self) { try ServiceCatalog.pick(["slack"], all: true, running: []) }
        #expect(throws: ServiceCatalog.Unknown.self) { try ServiceCatalog.pick(["myspace"], all: false, running: []) }
    }

    @Test func catalogIsWellFormed() {
        let ids = ServiceCatalog.services.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ServiceCatalog.services.count >= 30)
        for service in ServiceCatalog.services {
            #expect(service.feed.url.scheme == "https")
            #expect(service.page.scheme == "https")
            #expect(!service.apps.isEmpty || !service.hosts.isEmpty, "\(service.id) maps to nothing")
        }
    }

    // MARK: Triggers

    private func snapshot(rssi: Int = -55, internet: [Double] = [20, 21, 22], loss: Double = 0, portal: Bool? = false) -> DiagnosticSnapshot {
        DiagnosticSnapshot(date: now, radio: RadioSample(ssid: "Home", interface: "en0", rssi: rssi, noise: -92, transmitMbps: 600, channel: 36, band: "5 GHz"),
                           gateway: "192.168.1.1", router: PingResult(host: "192.168.1.1", samples: [3, 3, 4], lossPercent: 0),
                           internet: PingResult(host: "1.1.1.1", samples: internet, lossPercent: loss), dnsMilliseconds: 20, dnsServers: [],
                           captivePortal: portal, networkService: "Wi-Fi")
    }

    @Test func notYouOnlyWhenTheLineCheckedOut() {
        #expect(ServiceTriggers.lineFine(snapshot()))
        #expect(!ServiceTriggers.lineFine(nil))
        #expect(!ServiceTriggers.lineFine(snapshot(portal: true)))
        #expect(!ServiceTriggers.lineFine(snapshot(rssi: -82)))
        #expect(!ServiceTriggers.lineFine(snapshot(loss: 40)))
        // No ping replies: Health can't tell, so neither can Kilobat.
        #expect(!ServiceTriggers.lineFine(snapshot(internet: [])))
    }

    @Test func checksTheAppsInUseNow() {
        let apps = [AppTraffic(id: "com.tinyspeck.slackmacgap", name: "Slack", downloadRate: 2_000),
                    AppTraffic(id: "com.getdropbox.dropbox", name: "Dropbox", downloadRate: 0),
                    AppTraffic(id: "com.apple.Safari", name: "Safari", downloadRate: 90_000)]
        #expect(ServiceTriggers.services(active: apps, frontmost: "us.zoom.xos").map(\.id) == ["zoom", "slack"])
        #expect(ServiceTriggers.services(active: apps, frontmost: nil).map(\.id) == ["slack"])
    }

    private func doctor(_ steps: [(String, DoctorStep.Status)], host: String = "app.slack.com") -> DoctorReport {
        ConnectionDoctor.report(host, host, nil, steps.map { DoctorStep(layer: $0.0, status: $0.1, detail: "") })
    }
    private func status(_ state: ServiceStatus.State, incident: String? = "Messaging delays") -> ServiceStatus {
        ServiceStatus(id: "slack", service: "Slack", state: state, incident: state == .operational ? nil : incident, page: URL(string: "https://slack-status.com")!, checked: now)
    }

    @Test func anOutageLeadsTheConnectionCheckWhenThisMacIsFine() {
        let report = doctor([("Network", .ok), ("DNS", .ok), ("IPv4", .ok), ("Server", .failed)])
        #expect(ServiceTriggers.services(for: report).map(\.id) == ["slack"])
        let checked = ConnectionDoctor.withServiceStatus(report, statuses: [status(.majorOutage)])
        #expect(checked.verdict == "Slack is down for everyone, not you — Messaging delays")
        #expect(checked.next.contains("The server is having problems."))
        #expect(checked.steps.last?.layer == "Status page")
        #expect(checked.steps.last?.status == .warning)
        #expect(checked.services?.first?.state == .majorOutage)
    }

    @Test func anOutageIsASideNoteWhenThisMacIsTheProblem() {
        let report = doctor([("Network", .failed)])
        #expect(!ServiceTriggers.pointsBeyondThisMac(report))
        let checked = ConnectionDoctor.withServiceStatus(report, statuses: [status(.partialOutage)])
        #expect(checked.verdict == "Your Mac isn’t connected.")
        #expect(checked.next.contains("Part of Slack is down for everyone — Messaging delays"))
        #expect(!checked.next.contains("not you"))
    }

    @Test func aGreenPageIsSaidNotGuessedPast() {
        let report = doctor([("Network", .ok), ("Server", .failed)])
        let checked = ConnectionDoctor.withServiceStatus(report, statuses: [status(.operational)])
        #expect(checked.verdict == report.verdict)
        #expect(checked.steps.last?.detail == "Slack’s status page reports no problems.")
        #expect(checked.steps.last?.status == .ok)
        // An unreadable page is skipped, and the verdict stays the check's own.
        let unread = ConnectionDoctor.withServiceStatus(report, statuses: [status(.unknown)])
        #expect(unread.verdict == report.verdict)
        #expect(unread.steps.last?.status == .skipped)
    }

    @Test func maintenanceDoesntOverrideAWorkingRequest() {
        let report = doctor([("Network", .ok), ("Server", .ok)])
        let checked = ConnectionDoctor.withServiceStatus(report, statuses: [status(.maintenance, incident: "Database upgrade")])
        #expect(checked.verdict == report.verdict)
        #expect(checked.next.contains("Slack is under maintenance — Database upgrade"))
    }

    @Test func callsCheckTheServiceOnlyWhenFrozenBeyondTheRouter() {
        func call(_ app: String, browser: Bool = false, beyond: Bool) -> CallReport {
            var samples = CallSamples()
            samples.internet = (0..<200).map { .init(at: Double($0), ms: (100..<104).contains($0) ? nil : 30) }
            samples.router = (0..<200).map { .init(at: Double($0), ms: beyond ? 3 : (100..<104).contains($0) ? nil : 3) }
            return CallAnalysis.report(app: app, browser: browser, start: now, end: now.addingTimeInterval(200), network: nil, samples: samples)
        }
        #expect(ServiceTriggers.callNeedsCheck(call("Zoom", beyond: true)))
        #expect(!ServiceTriggers.callNeedsCheck(call("Zoom", beyond: false)))
        #expect(!ServiceTriggers.callNeedsCheck(call("Chrome", browser: true, beyond: true)))
        #expect(!ServiceTriggers.callNeedsCheck(call("Signal", beyond: true)))
        let later = ServiceStatus(id: "zoom", service: "Zoom", state: .majorOutage, incident: "x", started: now.addingTimeInterval(3600), page: URL(string: "https://www.zoomstatus.com")!, checked: now)
        #expect(!ServiceTriggers.relevant(later, toCallEnding: now.addingTimeInterval(200)))
        #expect(ServiceTriggers.relevant(status(.operational), toCallEnding: now))
        #expect(later.reported == "Zoom’s status page reported an outage at the time — x")
    }

    @Test func callReportsWithoutTheFieldStillDecode() throws {
        var samples = CallSamples()
        samples.internet = (0..<90).map { .init(at: Double($0), ms: 30) }
        let card = CallAnalysis.report(app: "Zoom", browser: false, start: now, end: now.addingTimeInterval(90), network: nil, samples: samples)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as! [String: Any]
        object["service"] = nil
        let decoded = try JSONDecoder().decode(CallReport.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.service == nil)
        var withService = card
        withService.service = status(.partialOutage)
        #expect(try JSONDecoder().decode(CallReport.self, from: JSONEncoder().encode(withService)).service?.state == .partialOutage)
    }

    @Test func aServiceOutageChangesTheCallAdvice() {
        var samples = CallSamples()
        samples.internet = (0..<200).map { .init(at: Double($0), ms: (100..<104).contains($0) ? nil : 30) }
        samples.router = (0..<200).map { .init(at: Double($0), ms: 3) }
        var card = CallAnalysis.report(app: "Slack", browser: false, start: now, end: now.addingTimeInterval(200), network: nil, samples: samples)
        card.household = true
        #expect(card.advice == "If it keeps happening, the report for your provider shows it over time.")
        card.service = status(.majorOutage)
        #expect(card.advice == "That was Slack’s own trouble, not your line, so there’s nothing to change here.")
        card.service = status(.operational)
        #expect(card.advice == "If it keeps happening, the report for your provider shows it over time.")
    }

    // MARK: Watch: failing connections and rate limits

    @Test func readsConnectionsStillOpening() {
        let text = """
        ,state,
        Slack Helper.4120,,
        tcp4 192.0.2.10:50012<->203.0.113.5:443,SynSent,
        tcp4 192.0.2.10:50013<->203.0.113.5:443,SynSent,
        tcp4 192.0.2.10:50014<->203.0.113.9:443,Established,
        tcp4 127.0.0.1:50015<->127.0.0.1:8080,SynSent,
        zoom.us.4200,,
        tcp4 192.0.2.10:50020<->203.0.113.7:443,Established,
        Other.4300,,
        tcp4 192.0.2.10:50030<->203.0.113.8:443,SynSent,
        """
        #expect(ConnectionStates.parse(text, pids: [4120, 4200]) == [4120: ["203.0.113.5", "203.0.113.5"], 4200: []])
    }

    @Test func failingMeansTwoSamplesInARowOrThreeAtOnce() {
        var apps = FailingApps()
        let results = [["slack": 1, "zoom": 0], ["slack": 1, "zoom": 0], ["slack": 0, "zoom": 3], ["slack": 1]].map { apps.update($0) }
        #expect(results == [[], ["slack"], ["zoom"], []])
    }

    @Test func notifiesOncePerIncidentAndRateLimits() {
        var policy = ServiceAlertPolicy()
        func other(_ id: String, _ state: ServiceStatus.State, incident: String? = "x") -> ServiceStatus {
            ServiceStatus(id: id, service: id, state: state, incident: incident, page: URL(string: "https://x.example")!, checked: now)
        }
        let decisions = [
            (status(.majorOutage), 0.0),
            (status(.majorOutage), 600),
            // A renamed incident within half an hour is the same trouble.
            (status(.majorOutage, incident: "Messaging delays, update"), 900),
            (status(.majorOutage, incident: "Huddles failing"), 2000),
            // Maintenance and a plain colour change never notify.
            (other("zoom", .maintenance, incident: "Upgrade"), 0),
            (other("zoom", .degraded, incident: nil), 0),
        ].map { policy.shouldAlert($0.0, now: now.addingTimeInterval($0.1)) }
        #expect(decisions == [true, false, false, true, false, false])
        // Three an hour at most.
        var busy = ServiceAlertPolicy()
        let burst = [("a", 0.0), ("b", 1), ("c", 2), ("d", 10), ("d", 3700)].map { busy.shouldAlert(other($0.0, .partialOutage), now: now.addingTimeInterval($0.1)) }
        #expect(burst == [true, true, true, false, true])
        // The day's record survives a restart.
        let restored = try? JSONDecoder().decode(ServiceAlertPolicy.self, from: JSONEncoder().encode(policy))
        #expect(restored == policy)
    }

    @MainActor @Test func problemsListOnlyFreshTroubleWorstFirst() async {
        let watch = ServiceWatch()
        watch.checker = ServiceStatusChecker { url in
            url.host == "slack-status.com" ? Data(ServiceStatusFixtures.slackIncident.utf8) : Data(ServiceStatusFixtures.statuspageOperational.utf8)
        }
        await watch.check([service("slack"), service("github")])
        #expect(watch.problems().map(\.id) == ["slack"])
        #expect(watch.problems(now: Date().addingTimeInterval(ServiceWatch.listedFor + 1)).isEmpty)
    }
}
