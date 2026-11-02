import Foundation
import Testing
@testable import KilobatCore

@MainActor struct OutageCreditTests {
    private let utc: Calendar = { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!; return calendar }()
    private let table = OutageCreditTable.bundled

    /// 2026-10-05 is a Monday.
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10) -> Date {
        utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }
    private var october: DateInterval { CreditTally.month(of: date(15, 12), calendar: utc) }
    private func outage(_ start: Date, _ end: Date) -> NetworkEvent {
        NetworkEvent(start: start, end: end, network: "Home", kind: "Unreachable", detail: "", routerChecks: 30, routerAnswered: 30)
    }
    private func tally(_ events: [NetworkEvent], starlink: [StarlinkOutage] = [], sleeps: [DateInterval] = []) -> CreditTally {
        CreditTally.make(events: events, starlink: starlink, sleeps: sleeps, network: "Home", from: october.start, to: october.end, now: date(31, 23, month: 10))
    }
    private func estimate(_ policy: String, _ tally: CreditTally, price: Double? = nil, capDays: Int? = nil) -> CreditEstimate {
        CreditEstimate.make(policy: table.policy(id: policy), tally: tally, monthlyPrice: price, capDays: capDays, calendar: utc)
    }

    // MARK: Table

    @Test func everyPolicyHasASourceAndADateChecked() {
        #expect(table.policies.count >= 8)
        for policy in table.policies {
            #expect(policy.source.hasPrefix("https://"), "\(policy.id)")
            #expect(policy.checked == "2026-10-31", "\(policy.id)")
            #expect(["high", "medium"].contains(policy.confidence), "\(policy.id)")
        }
        for provider in table.providers {
            // A provider names a policy that exists, or says why it has none.
            #expect(provider.policy.map { table.policy(id: $0) != nil } ?? (provider.note != nil), "\(provider.id)")
        }
        let asns = table.providers.flatMap(\.asns)
        #expect(Set(asns).count == asns.count)
        #expect(table.policy(id: "uk-ofcom")?.credit.amount == 10.34)
    }

    @Test func matchesTheProviderByASNThenByName() {
        #expect(table.match(asn: 7922, organization: nil, country: "US")?.id == "us-xfinity")
        #expect(table.match(asn: 14593, organization: nil, country: "DE")?.id == "starlink")
        #expect(table.match(asn: 6871, organization: "Plusnet British Telecommunications Limited", country: "GB")?.id == "gb-plusnet")
        #expect(table.match(asn: 64512, organization: "BT-UK-AS British Telecommunications Limited", country: "GB")?.id == "gb-bt")
        #expect(table.match(asn: nil, organization: "Telefónica de España S.A.U.", country: "ES")?.id == "es-movistar")
        // "Orange" names networks in many countries; the country has to agree.
        #expect(table.match(asn: nil, organization: "Orange S.A.", country: "FR")?.id == "fr-orange")
        #expect(table.match(asn: nil, organization: "Orange S.A.", country: "PL") == nil)
        #expect(table.match(asn: 64512, organization: "Example Fibre Ltd", country: "GB") == nil)
        #expect(table.choices(country: "GB").first?.country == "GB")
    }

    @Test func aLawCoversEveryProviderInItsCountryButOfcomOnlyItsMembers() {
        #expect(table.policy(for: nil, country: "DE")?.id == "de-tkg58")
        #expect(table.policy(for: nil, country: "ES")?.id == "es-rd899")
        #expect(table.policy(for: nil, country: "IT")?.id == "it-agcom")
        #expect(table.policy(for: nil, country: "GB") == nil)
        #expect(table.policy(for: table.provider("gb-sky"), country: nil)?.id == "uk-ofcom")
        #expect(table.policy(for: table.provider("us-spectrum"), country: "US") == nil)
        #expect(table.policy(for: table.provider("starlink"), country: "DE") == nil)
    }

    // MARK: Tally

    @Test func countsOnlyOutagesProvenBeyondTheRouter() {
        let events = [outage(date(6, 9), date(6, 11)),
                      NetworkEvent(start: date(7, 9), end: date(7, 10), network: "Home", kind: "Unreachable", detail: "", routerChecks: 8, routerAnswered: 0),
                      NetworkEvent(start: date(8, 9), end: date(8, 9, 30), network: "Home", kind: "Unreachable", detail: ""),
                      NetworkEvent(start: date(9, 9), end: date(9, 9, 30), network: "Home", kind: "Unreachable", detail: "", routerChecks: 10, routerAnswered: 7),
                      NetworkEvent(start: date(10, 9), end: date(10, 15), network: "Café", kind: "Unreachable", detail: "", routerChecks: 10, routerAnswered: 10),
                      NetworkEvent(start: date(11, 9), end: date(11, 15), network: "Home", kind: "Wi-Fi roam", detail: "")]
        let result = tally(events)
        #expect(result.outages.count == 1)
        #expect(result.totalSeconds == 7200)
        #expect(result.localSeconds == 3600)
        #expect(result.unprovenSeconds == 3600)
        #expect(result.longest?.routerAnswered == 30)
    }

    @Test func aWiFiSignInPageIsNeverTheProvidersOutage() {
        // The sign-in page blocks the internet while the router answers, which would otherwise look like the provider.
        let events = [NetworkEvent(start: date(6, 9), end: date(6, 15), network: "Home", kind: "Wi-Fi sign-in", detail: "", routerChecks: 40, routerAnswered: 40),
                      outage(date(7, 9), date(7, 10))]
        let result = tally(events)
        #expect(result.outages.count == 1 && result.totalSeconds == 3600)
        #expect(result.portalSeconds == 6 * 3600)
        #expect(CreditText.excluded(result)?.contains("sign-in page") == true)
        #expect(!estimate("us-att", result, price: 62).qualifying.contains(date(6, 9)))
    }

    @Test func theJournalLogsASignInPageAsItsOwnEvent() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let journal = NetworkJournal(directory: path); journal.alerts = false
        let sample = DiagnosticSnapshot(date: Date(), radio: RadioSample(ssid: "Hotel", interface: "en0", rssi: -50, noise: -90, transmitMbps: 100, channel: 1, band: "5 GHz"), gateway: "192.168.1.1",
                                        router: PingResult(host: "192.168.1.1", samples: [3], lossPercent: 0), internet: PingResult(host: "1.1.1.1", samples: [], lossPercent: 100),
                                        dnsMilliseconds: nil, dnsServers: [], captivePortal: true, networkService: "Wi-Fi")
        let none = PingResult(host: "8.8.8.8", samples: [], lossPercent: 100), start = Date()
        for i in 0..<4 { journal.ingest(sample, secondary: none, httpReachable: false, date: start.addingTimeInterval(Double(i) * 60)) }
        #expect(journal.events.last?.kind == "Wi-Fi sign-in")
        let result = CreditTally.make(events: journal.events, network: "Hotel", from: start.addingTimeInterval(-60), to: start.addingTimeInterval(3600), now: start.addingTimeInterval(600))
        #expect(result.outages.isEmpty && result.portalSeconds > 0)
    }

    @Test func oldOutagesFallBackToSavedChecks() {
        func sample(_ at: Date, router: Double?) -> DiagnosticSnapshot {
            DiagnosticSnapshot(date: at, radio: RadioSample(ssid: "Home", interface: "en0", rssi: -50, noise: -90, transmitMbps: 100, channel: 1, band: "5 GHz"), gateway: "192.168.1.1",
                               router: router.map { PingResult(host: "192.168.1.1", samples: [$0], lossPercent: 0) }, internet: PingResult(host: "1.1.1.1", samples: [], lossPercent: 100),
                               dnsMilliseconds: nil, dnsServers: [], captivePortal: false, networkService: "Wi-Fi")
        }
        let event = NetworkEvent(start: date(6, 9), end: date(6, 9, 10), network: "Home", kind: "Unreachable", detail: "")
        let samples = (0..<10).map { sample(date(6, 9, $0), router: 3) }
        let result = CreditTally.make(events: [event], samples: samples, network: "Home", from: october.start, to: october.end, now: date(31, 0))
        #expect(result.outages.count == 1 && result.outages[0].routerChecks == 10)
    }

    @Test func neverCountsTimeTheMacWasAsleep() {
        let result = tally([outage(date(6, 10), date(6, 14))], sleeps: [DateInterval(start: date(6, 11), end: date(6, 12))])
        #expect(result.totalSeconds == 3 * 3600)
        #expect(result.asleepSeconds == 3600)
        #expect(result.longest.map { $0.seconds } == 7200)
        // The two parts share the outage's 30 checks instead of each claiming all of them.
        #expect(result.outages.map(\.routerChecks) == [10, 20])
        #expect(CreditText.excluded(result)?.contains("asleep") == true)
    }

    @Test func starlinksNetworkSideCountsOnceAndTheSetupSideNever() {
        let dish = [StarlinkOutage(cause: .noSatellites, start: date(6, 10, 30), seconds: 3 * 3600),
                    StarlinkOutage(cause: .obstructed, start: date(12, 10), seconds: 3600),
                    StarlinkOutage(cause: .noPings, start: date(13, 10), seconds: 600)]
        let result = tally([outage(date(6, 10), date(6, 12))], starlink: dish)
        #expect(result.outages.count == 2)
        #expect(result.outages[0].start == date(6, 10) && result.outages[0].end == date(6, 13, 30))
        #expect(result.outages[0].sources == [.kilobat, .starlink])
        #expect(result.totalSeconds == 3.5 * 3600 + 600)
    }

    @Test func clipsToTheMonth() {
        let result = tally([outage(date(30, 22, month: 9), date(1, 2))])
        #expect(result.totalSeconds == 2 * 3600)
    }

    // MARK: Policy maths

    @Test func ofcomPaysEachDayAfterTwoWorkingDays() {
        // Reported Monday 10:00: Tuesday and Wednesday are the two working days, so the credit starts Thursday.
        let deadline = CreditEstimate.deadline(for: tally([outage(date(5, 10), date(9, 12))]).outages[0], threshold: table.policy(id: "uk-ofcom")!.threshold, calendar: utc)
        #expect(deadline == date(8, 0))
        let result = estimate("uk-ofcom", tally([outage(date(5, 10), date(9, 12))]))
        #expect(result.qualifies && result.days == 2 && result.amount == 20.68 && result.currency == "GBP")
        // Reported on a Friday evening, the weekend doesn't count.
        let friday = tally([outage(date(9, 18), date(14, 1))]).outages[0]
        #expect(CreditEstimate.deadline(for: friday, threshold: table.policy(id: "uk-ofcom")!.threshold, calendar: utc) == date(14, 0))
        #expect(!estimate("uk-ofcom", tally([outage(date(5, 10), date(7, 20))])).qualifies)
        #expect(estimate("uk-ofcom", tally([outage(date(5, 0), date(31, 0))]), capDays: 10).amount == 103.4)
    }

    @Test func germanyPaysTheHigherOfTheAmountAndTheShare() {
        // Monday to Sunday: days 3 and 4 at the first tier, day 5 at the second.
        let week = tally([outage(date(5, 0), date(11, 0))])
        #expect(estimate("de-tkg58", week, price: 40).amount == 20)
        #expect(estimate("de-tkg58", week, price: 80).amount == 32)
        let unpriced = estimate("de-tkg58", week)
        #expect(unpriced.amount == 20 && unpriced.atLeast && !unpriced.needsPrice)
        #expect(!estimate("de-tkg58", tally([outage(date(5, 0), date(7, 23))])).qualifies)
    }

    @Test func xfinityCreditsProRataAfterADay() {
        // October has 31 days.
        let long = estimate("us-xfinity", tally([outage(date(6, 0), date(7, 7))]), price: 93)
        #expect(long.qualifies && long.amount == 3.88)
        #expect(long.askBy == date(7, 7).addingTimeInterval(120 * 86_400))
        #expect(!estimate("us-xfinity", tally([outage(date(6, 0), date(6, 20))]), price: 93).qualifies)
        let unpriced = estimate("us-xfinity", tally([outage(date(6, 0), date(7, 7))]))
        #expect(unpriced.qualifies && unpriced.amount == nil && unpriced.needsPrice)
    }

    @Test func attCreditsADayPerOutageUpToTheMonth() {
        let result = estimate("us-att", tally([outage(date(6, 9), date(6, 9, 25)), outage(date(10, 0), date(12, 2)), outage(date(14, 9), date(14, 9, 10))]), price: 62)
        #expect(result.days == 4 && result.amount == 8)
        #expect(estimate("us-att", tally([outage(date(1, 0), date(31, 0)), outage(date(31, 1), date(31, 1, 30)), outage(date(31, 2), date(31, 2, 30))]), price: 62).amount == 62)
    }

    @Test func spainAddsUpDaytimeHoursOverTheMonth() {
        let daytime = tally([outage(date(6, 9), date(6, 12)), outage(date(7, 14), date(7, 17, 30))])
        let result = estimate("es-rd899", daytime, price: 31 * 24)
        #expect(result.qualifies && result.amount == 6.5)
        // A night outage doesn't count toward the six hours.
        #expect(!estimate("es-rd899", tally([outage(date(6, 22), date(7, 7)), outage(date(8, 9), date(8, 10))]), price: 50).qualifies)
    }

    @Test func italyPaysFromTheFirstDay() {
        #expect(estimate("it-agcom", tally([outage(date(6, 9), date(7, 12))])).amount == 12)
    }

    @Test func noPolicyMeansNoAmount() {
        let result = CreditEstimate.make(policy: nil, tally: tally([outage(date(6, 9), date(8, 9))]), monthlyPrice: 80)
        #expect(!result.qualifies && result.amount == nil)
        #expect(CreditText.verdict(result, tally: tally([]), provider: "Spectrum", policy: nil) == CreditText.noPolicy)
    }

    // MARK: Claim

    @Test func theDraftHasTheDatesTheEvidenceAndThePolicy() {
        let month = tally([outage(date(5, 10), date(9, 12)), outage(date(20, 8), date(20, 8, 40))])
        let report = CreditReport.make(settings: CreditSettings(provider: "gb-bt", monthlyPrice: 35), tally: month)
        let text = report.claim.text
        #expect(text.contains(CreditClaim.accountPlaceholder) && text.contains(CreditClaim.namePlaceholder))
        #expect(text.contains("Hello BT"))
        for outage in month.outages { #expect(text.contains(CreditText.span(outage))) }
        #expect(text.contains("router kept answering (60 of 60 checks)"))
        #expect(text.contains("Ofcom automatic compensation"))
        #expect(text.contains("may qualify for a credit of about " + CreditText.money(20.68, "GBP")))
        #expect(text.contains("attached"))
        #expect(!text.lowercased().contains("guarantee") && !text.contains("you owe"))
        #expect(report.claimURL?.host == "www.bt.com")

        let unknown = CreditReport.make(settings: CreditSettings(provider: "us-spectrum"), tally: month)
        #expect(unknown.verdict == CreditText.noPolicy)
        #expect(unknown.claim.text.contains("Please let me know whether a credit is available"))
    }

    @Test func theDraftSumsShortDishDrops() {
        let drops = (0..<40).map { StarlinkOutage(cause: .noSatellites, start: date(6, 10, $0), seconds: 20) }
        let report = CreditReport.make(settings: CreditSettings(provider: "starlink"), tally: tally([], starlink: drops))
        #expect(report.claim.body.contains("40 shorter outages"))
        #expect(report.claim.body.contains("Starlink dish logged 40 outages"))
    }

    // MARK: Notification

    @Test func notifiesOncePerOutageAndAtMostDaily() {
        let now = date(9, 12)
        let result = estimate("uk-ofcom", CreditTally.make(events: [NetworkEvent(start: date(5, 10), end: nil, network: "Home", kind: "Unreachable", detail: "", routerChecks: 50, routerAnswered: 50)],
                                                            network: "Home", from: october.start, to: october.end, now: now))
        let key = CreditAlert.due(result, notified: [], last: nil, now: now)
        #expect(key == CreditAlert.key(date(5, 10)))
        #expect(CreditAlert.due(result, notified: [key!], last: nil, now: now) == nil)
        #expect(CreditAlert.due(result, notified: [], last: now.addingTimeInterval(-3600), now: now) == nil)
        // An outage that crossed long ago isn't news.
        #expect(CreditAlert.due(result, notified: [], last: nil, now: date(20, 12)) == nil)
    }

    // MARK: Lookup and journal

    @Test func readsRIPEstatReplies() {
        #expect(ProviderLookup.asn(fromNetworkInfo: Data(#"{"data":{"asns":["7922"],"prefix":"73.0.0.0/8"}}"#.utf8)) == 7922)
        #expect(ProviderLookup.asn(fromNetworkInfo: Data(#"{"data":{"asns":[],"prefix":null}}"#.utf8)) == nil)
        #expect(ProviderLookup.holder(fromOverview: Data(#"{"data":{"holder":"COMCAST-7922 - Comcast Cable Communications, LLC"}}"#.utf8))?.contains("Comcast") == true)
        let lookup = ProviderLookup(address: "203.0.113.9", asn: 64512, organization: "COMCAST-7922 - Comcast Cable Communications, LLC", country: "US")
        #expect(lookup.provider()?.id == "us-xfinity")
    }

    @Test func theJournalCountsRouterRepliesDuringAnOutage() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let journal = NetworkJournal(directory: path); journal.alerts = false
        func sample(router: Bool) -> DiagnosticSnapshot {
            DiagnosticSnapshot(date: Date(), radio: RadioSample(ssid: "Home", interface: "en0", rssi: -50, noise: -90, transmitMbps: 100, channel: 1, band: "5 GHz"), gateway: "192.168.1.1",
                               router: router ? PingResult(host: "192.168.1.1", samples: [3], lossPercent: 0) : nil, internet: PingResult(host: "1.1.1.1", samples: [], lossPercent: 100),
                               dnsMilliseconds: nil, dnsServers: [], captivePortal: false, networkService: "Wi-Fi")
        }
        let none = PingResult(host: "8.8.8.8", samples: [], lossPercent: 100), start = Date()
        for i in 0..<5 { journal.ingest(sample(router: i != 4), secondary: none, httpReachable: false, date: start.addingTimeInterval(Double(i) * 60)) }
        let event = try #require(journal.events.last)
        #expect(event.routerChecks == 5 && event.routerAnswered == 4)
    }

    @Test func cliOptionsParse() throws {
        let options = try CreditOptions.parse(["credit", "--provider", "gb-bt", "--price", "35.5", "--month", "2026-09", "--draft", "--json"])
        #expect(options.provider == "gb-bt" && options.price == 35.5 && options.draft && options.json)
        #expect(options.month == .named(year: 2026, month: 9))
        #expect(try CreditOptions.parse(["credit", "--month", "last"]).month == .last)
        #expect(try CreditOptions.parse(["credit"]).month == .this)
        #expect(throws: (any Error).self) { try CreditOptions.parse(["credit", "--price", "free"]) }
        #expect(throws: (any Error).self) { try CreditOptions.parse(["credit", "--month", "2026-13"]) }
        #expect(throws: (any Error).self) { try CreditOptions.parse(["credit", "--provider", "nope"]) }
        #expect(throws: (any Error).self) { try CreditOptions.parse(["credit", "--frobnicate"]) }
        #expect(try CreditOptions.parse(["credit", "providers", "--country", "gb"]).listCountry == "GB")
    }
}
