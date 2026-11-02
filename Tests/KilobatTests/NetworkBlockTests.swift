import Foundation
import Network
import Testing
@testable import KilobatCore

/// Blocked here, not down: DNS tampering, a cut secure connection and block pages against the honest look-alikes.
/// Hosts are examples and addresses documentation ranges.
struct NetworkBlockDNSTests {
    let green = BlockContext(serviceID: "slack", service: "Slack", status: .operational, statusSentence: "Slack’s status page reports no problems.", place: .wifi)

    func measured(_ system: DNSAnswer, trusted: DNSAnswer? = .addresses(["203.0.113.10"])) -> BlockMeasurements {
        BlockMeasurements(host: "slack.com", system: system, trusted: trusted)
    }

    @Test func aNameMissingHereThatASecureResolverKnowsIsBlocked() throws {
        let block = try #require(NetworkBlockRules.classify(measured(DNSAnswer(.nxdomain)), green))
        #expect(block.state == .blocked && block.signals == [.nameMissing])
        #expect(block.summary == "Slack looks blocked on this Wi-Fi network, not down: its name doesn’t resolve here, while a secure resolver returns its real address.")
        #expect(block.evidence.contains { $0.contains("Cloudflare (1.1.1.1)") && $0.contains("203.0.113.10") })
        #expect(block.evidence.contains("Slack’s status page reports no problems."))
        #expect(block.resolver == "Cloudflare (1.1.1.1)")
    }

    @Test func noAnswerForOneNameWhileOthersResolveIsBlocked() {
        #expect(NetworkBlockRules.signals(measured(DNSAnswer(.noAnswer)), green) == [.nameSilent])
    }

    @Test func aNameThatReallyDoesNotExistIsNeverBlocked() {
        // The secure resolver says NXDOMAIN too: the name doesn't exist anywhere.
        #expect(NetworkBlockRules.classify(measured(DNSAnswer(.nxdomain), trusted: DNSAnswer(.nxdomain)), green) == nil)
        // The secure resolver didn't answer: nothing to compare against.
        #expect(NetworkBlockRules.classify(measured(DNSAnswer(.nxdomain), trusted: nil), green) == nil)
    }

    @Test func dnsThatFailsForEveryNameIsBrokenNotBlocking() {
        var m = measured(DNSAnswer(.noAnswer)); m.systemResolves = false
        #expect(NetworkBlockRules.classify(m, green) == nil)
    }

    @Test func splitHorizonAndCompanyDNSAreLeftAlone() {
        // A VPN's or company's split-DNS resolver for the domain decides the name.
        var context = green; context.scopedResolver = true
        #expect(NetworkBlockRules.classify(measured(DNSAnswer(.nxdomain)), context) == nil)
        // A private address that proves it's the service (an internal mirror) is split-horizon DNS, not a block.
        var mirror = measured(.addresses(["10.20.0.5"])); mirror.systemHandshake = .verified
        #expect(NetworkBlockRules.classify(mirror, green) == nil)
        // Names only private networks know.
        #expect(NetworkBlockRules.classify(BlockMeasurements(host: "wiki.corp", system: .addresses(["10.0.0.4"]), trusted: .addresses(["203.0.113.10"])), green) == nil)
        // The trusted resolver also answers privately: the name really points there.
        #expect(NetworkBlockRules.classify(measured(.addresses(["10.20.0.5"]), trusted: .addresses(["10.20.0.5"])), green) == nil)
    }

    @Test func aSinkholeOrPrivateAnswerForAPublicNameIsBlocked() {
        for sinkhole in ["0.0.0.0", "127.0.0.1", "::", "10.10.34.35"] {
            var m = measured(.addresses([sinkhole])); m.systemHandshake = .noConnect
            #expect(NetworkBlockRules.signals(m, green) == [.privateAnswer], "\(sinkhole)")
        }
    }

    @Test func aCDNsDifferentButValidAddressIsNotTampering() {
        // Geo-DNS: another address that shows a valid certificate for the name.
        var other = measured(.addresses(["198.51.100.40"])); other.systemHandshake = .verified; other.trustedHandshake = .verified
        #expect(NetworkBlockRules.classify(other, green) == nil)
        // The same operator's block of addresses, even before any handshake.
        var neighbour = measured(.addresses(["203.0.113.77"])); neighbour.systemHandshake = .timedOut; neighbour.trustedHandshake = .verified
        #expect(NetworkBlockRules.signals(neighbour, green).contains(.wrongServer) == false)
        // An edge that doesn't connect at all may simply be down.
        var down = measured(.addresses(["198.51.100.40"])); down.systemHandshake = .noConnect; down.trustedHandshake = .verified
        #expect(NetworkBlockRules.classify(down, green) == nil)
    }

    @Test func anAddressThatCannotProveItIsTheServiceIsBlocked() throws {
        var m = measured(.addresses(["198.51.100.40"])); m.systemHandshake = .untrusted; m.trustedHandshake = .verified
        let block = try #require(NetworkBlockRules.classify(m, green))
        #expect(block.signals == [.wrongServer])
        #expect(block.summary.contains("198.51.100.40, which can’t prove it’s Slack"))
        // Without the trusted address proving itself, it could be anything.
        m.trustedHandshake = .untrusted
        #expect(NetworkBlockRules.classify(m, green) == nil)
    }

    @Test func theSameAddressAsAMadeUpNameIsAnInventedAnswer() {
        var m = measured(.addresses(["198.51.100.99"])); m.invented = ["198.51.100.99"]; m.systemHandshake = .untrusted; m.trustedHandshake = .verified
        #expect(NetworkBlockRules.signals(m, green) == [.inventedAnswer])
    }
}

struct NetworkBlockTLSTests {
    let green = BlockContext(serviceID: "discord", service: "Discord", status: .operational, place: .mobile)

    func cut(_ own: Handshake, again: Handshake?, control: Handshake?) -> BlockMeasurements {
        var m = BlockMeasurements(host: "discord.com", system: .addresses(["198.51.100.7"]), trusted: .addresses(["198.51.100.7"]))
        m.systemHandshake = own; m.repeatHandshake = again; m.controlHandshake = control; m.trustedHandshake = own
        return m
    }

    @Test func aResetRightAfterTheNameIsSentWhileTheServerAnswersAnotherNameIsBlocked() throws {
        let block = try #require(NetworkBlockRules.classify(cut(.reset, again: .reset, control: .alert), green))
        #expect(block.signals == [.tlsReset])
        #expect(block.summary == "Discord looks blocked on this mobile data connection, not down: the secure connection to discord.com is cut right after it starts, while the same server answers for another name.")
        #expect(block.evidence.contains { $0.hasPrefix("TLS to discord.com is cut right after the handshake starts") })
        #expect(block.next.hasPrefix("Try another network, such as Wi-Fi, or ask your mobile operator."))
        #expect(NetworkBlockRules.signals(cut(.timedOut, again: .timedOut, control: .verified), green) == [.tlsSilent])
    }

    @Test func ordinaryTimeoutsAndOneOffDropsAreNotBlocks() {
        // The server doesn't answer any name: it's the server or the path, not a filter on the name.
        #expect(NetworkBlockRules.classify(cut(.timedOut, again: .timedOut, control: .timedOut), green) == nil)
        #expect(NetworkBlockRules.classify(cut(.reset, again: .reset, control: .reset), green) == nil)
        // The second try went through: one dropped packet.
        #expect(NetworkBlockRules.classify(cut(.reset, again: .verified, control: .alert), green) == nil)
        // TCP never connected and no status page vouches for the service: an ordinary timeout, or the server is down.
        #expect(NetworkBlockRules.classify(cut(.noConnect, again: nil, control: nil), BlockContext(service: "Discord", place: .mobile)) == nil)
    }

    @Test func nothingConnectingCountsOnlyWithAGreenStatusPage() throws {
        var m = BlockMeasurements(host: "discord.com", system: .addresses(["198.51.100.7"]), trusted: .addresses(["198.51.100.7"]))
        m.systemHandshake = .noConnect; m.trustedHandshake = .noConnect
        let block = try #require(NetworkBlockRules.classify(m, green))
        #expect(block.signals == [.unreachable] && block.summary.contains("a problem the status page hasn’t reported yet would look the same"))
        var unknown = green; unknown.status = nil
        #expect(NetworkBlockRules.classify(m, unknown) == nil)
        var degraded = green; degraded.status = .degraded
        #expect(NetworkBlockRules.classify(m, degraded) == nil)
    }

    @Test func handshakeErrorsAreToldApart() {
        #expect(NetworkBlockCheck.classify(.posix(.ECONNRESET)) == .reset)
        #expect(NetworkBlockCheck.classify(.tls(-9806)) == .reset)
        #expect(NetworkBlockCheck.classify(.tls(-9824)) == .alert)
        #expect(NetworkBlockCheck.classify(.posix(.ETIMEDOUT)) == .timedOut)
        #expect(Handshake.alert.answered && Handshake.untrusted.answered && !Handshake.reset.answered && Handshake.timedOut.cut && !Handshake.noConnect.cut)
    }
}

struct NetworkBlockPageTests {
    let green = BlockContext(serviceID: "slack", service: "Slack", status: .operational, place: .home)

    @Test func http451OrARedirectAwayBacksUpAFinding() {
        var m = BlockMeasurements(host: "slack.com", system: .addresses(["0.0.0.0"]), trusted: .addresses(["203.0.113.10"]))
        m.systemHandshake = .noConnect; m.plainStatus = 451
        #expect(NetworkBlockRules.signals(m, green) == [.privateAnswer, .blockPage])
        m.plainStatus = 302; m.plainLocation = "http://warning.example.net/blocked?site=slack.com"
        #expect(NetworkBlockRules.signals(m, green).contains(.blockPage))
        #expect(NetworkBlockRules.classify(m, green)?.evidence.contains { $0.contains("a redirect to warning.example.net") } == true)
        // The service's own redirect to HTTPS isn't a block page.
        m.plainLocation = "https://app.slack.com/"
        #expect(!NetworkBlockRules.signals(m, green).contains(.blockPage))
    }

    @Test func aBlockPageAloneProvesTooLittle() {
        var m = BlockMeasurements(host: "slack.com", system: .addresses(["203.0.113.10"]), trusted: .addresses(["203.0.113.10"]))
        m.systemHandshake = .verified; m.plainStatus = 302; m.plainLocation = "http://elsewhere.example.org/"
        #expect(NetworkBlockRules.classify(m, green) == nil)
    }
}

struct NetworkBlockExclusionTests {
    let nxdomain = BlockMeasurements(host: "slack.com", system: DNSAnswer(.nxdomain), trusted: .addresses(["203.0.113.10"]))

    @Test func aSignInPageKilobatsOwnBlocksAndAnOutageWin() {
        #expect(NetworkBlockRules.classify(nxdomain, BlockContext(service: "Slack", portal: true)) == nil)
        #expect(NetworkBlockRules.classify(nxdomain, BlockContext(service: "Slack", kilobatBlocks: true)) == nil)
        #expect(NetworkBlockRules.classify(nxdomain, BlockContext(service: "Slack", status: .majorOutage)) == nil)
        #expect(NetworkBlockRules.classify(nxdomain, BlockContext(service: "Slack", status: .partialOutage)) == nil)
    }

    @Test func throughAVPNItSaysSoAndTheBlockIsTheVPNPaths() throws {
        let block = try #require(NetworkBlockRules.classify(nxdomain, BlockContext(service: "Slack", status: .operational, vpn: "Work VPN", place: .wifi)))
        #expect(block.vpn == "Work VPN")
        #expect(block.evidence.contains { $0.contains("went through your VPN (Work VPN)") })
        #expect(block.next.hasPrefix("Try without the VPN or on another network, or ask your VPN provider."))
    }

    @Test func withoutAStatusPageItDoesNotSayNotDown() throws {
        let block = try #require(NetworkBlockRules.classify(nxdomain, BlockContext(place: .public)))
        #expect(block.summary == "slack.com looks blocked on this public Wi-Fi: its name doesn’t resolve here, while a secure resolver returns its real address.")
    }

    @Test func theAdviceIsNeutral() {
        for place in NetworkPlace.allCases {
            let block = NetworkBlockRules.classify(nxdomain, BlockContext(service: "Slack", status: .operational, place: place))
            let words = (block?.next ?? "").lowercased()
            #expect(!words.isEmpty)
            for banned in ["vpn", "proxy", "tor ", "change dns", "switch dns", "1.1.1.1", "bypass", "unblock"] { #expect(!words.contains(banned), "\(place): \(banned)") }
        }
    }

    @Test func theDoctorChecksOnlyWhenNothingElseExplainsTheFailure() {
        func report(_ steps: [DoctorStep], hops: [DoctorHop] = [], services: [ServiceStatus]? = nil) -> DoctorReport {
            var report = DoctorReport(target: "https://slack.com", host: "slack.com", app: nil, verdict: "", next: "", steps: steps, hops: hops, date: Date())
            report.services = services
            return report
        }
        let dns = DoctorStep(layer: "DNS", status: .failed, detail: "slack.com didn’t resolve with your DNS.")
        #expect(ConnectionDoctor.blockChecks(report([dns])) == [.network])
        #expect(ConnectionDoctor.blockChecks(report([DoctorStep(layer: "Wi-Fi sign-in", status: .failed, detail: ""), dns])).isEmpty)
        #expect(ConnectionDoctor.blockChecks(report([DoctorStep(layer: "Kilobat rules", status: .failed, detail: ""), dns])).isEmpty)
        #expect(ConnectionDoctor.blockChecks(report([DoctorStep(layer: "DNS", status: .failed, detail: "", cues: [.privateResolver])])).isEmpty)
        #expect(ConnectionDoctor.blockChecks(report([DoctorStep(layer: "App proxy", status: .failed, detail: "")])).isEmpty)
        let outage = ServiceStatus(id: "slack", service: "Slack", state: .majorOutage, page: URL(string: "https://slack-status.com")!, checked: Date())
        #expect(ConnectionDoctor.blockChecks(report([dns], services: [outage])).isEmpty)
        // A server that answers 451, or sends you to its regional page, is asked about the region.
        let refused = DoctorHop(url: "https://api.example.com/", host: "api.example.com", method: "HEAD", status: 451, error: nil)
        #expect(ConnectionDoctor.blockChecks(report([DoctorStep(layer: "Server", status: .warning, detail: "")], hops: [refused])) == [.region])
        let regional = DoctorHop(url: "https://claude.ai/app-unavailable-in-region", host: "claude.ai", method: "HEAD", status: 200, error: nil)
        #expect(ConnectionDoctor.blockChecks(report([], hops: [regional])) == [.region])
        #expect(ConnectionDoctor.blockChecks(report([]), appError: #"{"error":{"code":"unsupported_country_region_territory"}}"#) == [.region])
    }

    @Test func aFindingLeadsTheVerdictAndIsInTheJSON() throws {
        let sample = NetworkBlockSamples.report()
        #expect(sample.verdict.hasPrefix("Slack looks blocked on this public Wi-Fi, not down"))
        #expect(sample.steps.last?.layer == "Network block" && sample.steps.last?.status == .failed && !sample.ok)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let object = try #require(try JSONSerialization.jsonObject(with: encoder.encode(sample)) as? [String: Any])
        let block = try #require(object["block"] as? [String: Any])
        #expect(block["state"] as? String == "blocked" && block["signals"] as? [String] == ["nameMissing"] && block["place"] as? String == "public")
    }
}

struct RegionRefusalTests {
    let context = BlockContext(serviceID: "openai-api", service: "OpenAI API", status: .operational, place: .wifi)
    func country(_ code: String) -> String { GeoIP.Country(code: code).name }

    @Test func knownRegionalErrorsAreRecognised() {
        let openAI = #"{"error":{"code":"unsupported_country_region_territory","message":"Country, region, or territory not supported","param":null,"type":"request_forbidden"}}"#
        #expect(RegionRefusal.match(openAI)?.company == "OpenAI")
        #expect(RegionRefusal.match("OpenAI's services are not available in your country. (error=unsupported_country)")?.company == "OpenAI")
        #expect(RegionRefusal.match(#"{"error":{"code":400,"message":"User location is not supported for the API use.","status":"FAILED_PRECONDITION"}}"#)?.company == "Google")
        #expect(RegionRefusal.match("API Error: 400 Access to Anthropic models is not allowed from unsupported countries, regions, or territories.")?.company == "Anthropic")
        #expect(RegionRefusal.match("https://claude.ai/app-unavailable-in-region")?.company == "Anthropic")
        // An ordinary refusal says nothing about a region.
        #expect(RegionRefusal.match(#"{"error":{"type":"authentication_error","message":"invalid x-api-key"}}"#) == nil)
    }

    @Test func only451OrTheServicesOwnWordsOverAVerifiedConnectionCount() {
        #expect(RegionRefusal.signal(status: 451, body: "", location: nil, verified: true)?.0 == .legal451)
        // Over plain HTTP the network could have written it.
        #expect(RegionRefusal.signal(status: 451, body: "", location: nil, verified: false) == nil)
        #expect(RegionRefusal.signal(status: 403, body: #"{"error":{"code":"unsupported_country_region_territory"}}"#, location: nil, verified: true)?.0 == .regionError)
        #expect(RegionRefusal.signal(status: 403, body: "Forbidden", location: nil, verified: true) == nil)
        #expect(RegionRefusal.signal(status: 200, body: "", location: "https://claude.ai/app-unavailable-in-region", verified: true)?.1?.company == "Anthropic")
    }

    @Test func theVerdictNamesTheServiceAndTheCountryTheConnectionAppearsIn() {
        let pattern = RegionRefusal.match("unsupported_country_region_territory")
        let block = RegionRefusal.finding(host: "api.openai.com", who: "OpenAI", signal: .regionError, pattern: pattern, context: context, exit: "DE", zone: "DE")
        #expect(block.state == .regionUnavailable && block.title == "Not available in your region")
        #expect(block.summary == "OpenAI says its service isn’t available in your region. Your connection currently appears to be in \(country("DE")).")
        #expect(block.timeZoneCountry == nil && !block.evidence.contains { $0.contains("time zone") })
        #expect(block.next.contains("this network isn’t blocking it") && !block.next.lowercased().contains("vpn") && !block.next.lowercased().contains("proxy"))
        let legal = RegionRefusal.finding(host: "api.example.com", who: "Example", signal: .legal451, pattern: nil, context: context, exit: nil, zone: nil)
        #expect(legal.summary == "Example refuses this request for legal reasons (HTTP 451), which services use when they aren’t offered in a region. Kilobat couldn’t tell which country your connection appears to be in.")
    }

    @Test func anExitInAnotherCountryIsNoted() {
        let pattern = RegionRefusal.match("app-unavailable-in-region")
        var vpn = context; vpn.vpn = "utun4"
        let through = RegionRefusal.finding(host: "claude.ai", who: "Anthropic", signal: .regionError, pattern: pattern, context: vpn, exit: "US", zone: "FR")
        #expect(through.evidence.contains { $0.contains("VPN (utun4)") && $0.contains("may not be where you are") })
        #expect(through.timeZoneCountry == "FR" && through.evidence.contains { $0.contains("time zone is set to \(country("FR"))") })
        var mobile = context; mobile.place = .mobile
        let roaming = RegionRefusal.finding(host: "claude.ai", who: "Anthropic", signal: .regionError, pattern: pattern, context: mobile, exit: "GB", zone: "ES")
        #expect(roaming.evidence.contains { $0.contains("roaming eSIM") } && roaming.exitCountry == "GB")
        // Pasted from the app, it says so rather than naming the host as the source.
        let pasted = RegionRefusal.finding(host: "api.openai.com", who: "OpenAI", signal: .regionError, pattern: RegionRefusal.match("unsupported_country_region_territory"),
                                           context: context, exit: "DE", zone: nil, fromApp: true)
        #expect(pasted.evidence.first?.hasPrefix("The error the app got says") == true)
    }

    @Test func theTimeZonesCountryComesFromZoneTab() {
        let table = "# comment\nDE\t+5230+01322\tEurope/Berlin\tmost of Germany\nES\t+4024-00341\tEurope/Madrid\tSpain (mainland)\n"
        #expect(RegionRefusal.country(ofTimeZone: "Europe/Madrid", table: table) == "ES")
        #expect(RegionRefusal.country(ofTimeZone: "Mars/Olympus", table: table) == nil)
    }
}

struct NetworkBlockSupportTests {
    @Test func dohAnswersAreRead() {
        // Header: id 0, response, rcode; one question for example.com A; one A answer.
        let question: [UInt8] = [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0, 0, 1, 0, 1]
        func reply(_ rcode: UInt8, answers: [[UInt8]] = []) -> Data {
            Data([0, 0, 0x81, 0x80 | rcode, 0, 1, 0, UInt8(answers.count), 0, 0, 0, 0] + question + answers.flatMap { [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4] + $0 })
        }
        #expect(NetworkBlockCheck.parseAnswer(reply(0, answers: [[203, 0, 113, 10]])) == .addresses(["203.0.113.10"]))
        #expect(NetworkBlockCheck.parseAnswer(reply(3)) == DNSAnswer(.nxdomain))
        #expect(NetworkBlockCheck.parseAnswer(reply(2)) == DNSAnswer(.noAnswer))
        #expect(NetworkBlockCheck.parseAnswer(Data([1, 2, 3])) == nil)
    }

    @Test func theTrustedResolverIsCloudflareUnlessQuad9IsChosen() {
        #expect(TrustedResolver.chosen(nil) == .cloudflare)
        var preferences = SavedPreferences(); preferences.blockCheckResolver = "quad9"
        #expect(TrustedResolver.chosen(preferences) == .quad9 && TrustedResolver.quad9.url.host == "9.9.9.9")
        preferences.blockCheckResolver = "something"
        #expect(TrustedResolver.chosen(preferences) == .cloudflare && TrustedResolver.cloudflare.url.absoluteString == "https://1.1.1.1/dns-query")
    }

    @Test func theNetworkKindIsWhatKilobatKnows() {
        #expect(NetworkPlace.of(cellular: false, metered: true, signInSeen: true, home: true, wifi: true, wired: false) == .mobile)
        #expect(NetworkPlace.of(cellular: false, metered: false, signInSeen: true, home: false, wifi: true, wired: false) == .public)
        #expect(NetworkPlace.of(cellular: false, metered: false, signInSeen: false, home: true, wifi: true, wired: false) == .home)
        #expect(NetworkPlace.of(cellular: false, metered: false, signInSeen: false, home: false, wifi: false, wired: true) == .wired)
    }

    @Test func oneNotificationPerServicePerNetworkPerDay() throws {
        var policy = BlockAlertPolicy()
        let block = try #require(NetworkBlockSamples.blocks().first)
        let morning = Date(timeIntervalSince1970: 1_793_000_000)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let first = policy.shouldAlert(block, network: "home", now: morning, calendar: calendar)
        let again = policy.shouldAlert(block, network: "home", now: morning.addingTimeInterval(3_600), calendar: calendar)
        let elsewhere = policy.shouldAlert(block, network: "hotel", now: morning.addingTimeInterval(3_600), calendar: calendar)
        let tomorrow = policy.shouldAlert(block, network: "home", now: morning.addingTimeInterval(86_400), calendar: calendar)
        #expect(first && !again && elsewhere && tomorrow)
    }

    @Test func theWatchListsBlocksForTheNetworkTheyWereMeasuredOn() async throws {
        await MainActor.run {
            let watch = ServiceWatch()
            let block = NetworkBlockSamples.blocks()[0]
            watch.record(block, network: "hotel")
            #expect(watch.blocked(network: "hotel").map(\.serviceID) == ["slack"])
            #expect(watch.blocked(network: "home").isEmpty)
            #expect(watch.blocked(network: "hotel", now: Date().addingTimeInterval(ServiceWatch.blockListedFor + 1)).isEmpty)
            watch.record(NetworkBlockSamples.blocks()[1], network: "café")
            #expect(watch.blocked(network: "hotel").isEmpty && watch.blocked(network: "café").count == 1)
        }
    }
}

struct ConnectionCheckCommandTests {
    @Test func whyAndDoctorParseTheSameFlags() throws {
        let command = try ConnectionCheckCommand.parse(["doctor", "api.openai.com", "--error", #"{"error":{"code":"unsupported_country_region_territory"}}"#, "--json"])
        #expect(command.target == "api.openai.com" && command.json && command.appError?.contains("unsupported_country") == true)
        let full = try ConnectionCheckCommand.parse(["why", "--app", "com.tinyspeck.slackmacgap", "slack.com", "--context", "vm"])
        #expect(full.target == "slack.com" && full.app == "com.tinyspeck.slackmacgap" && full.context == .vm && !full.json)
    }

    @Test func badFlagsSayWhatTheyTake() {
        #expect(throws: ConnectionCheckCommand.Failure.self) { try ConnectionCheckCommand.parse(["why"]) }
        #expect(throws: ConnectionCheckCommand.Failure(message: "--error takes the error the app got, such as its message or JSON body.")) {
            try ConnectionCheckCommand.parse(["why", "slack.com", "--error"])
        }
        #expect(throws: ConnectionCheckCommand.Failure(message: ConnectionCheckCommand.usage)) { try ConnectionCheckCommand.parse(["why", "slack.com", "--bypass"]) }
        #expect(throws: ConnectionCheckCommand.Failure.self) { try ConnectionCheckCommand.parse(["why", "slack.com", "--app", "slack"]) }
    }
}
