import Foundation
import Testing
@testable import KilobatCore

struct FirewallTests {
    @Test func blocklistTakesWildcardsAddressesAndRanges() throws {
        let list = """
        *.ads.example
        203.0.113.7
        198.51.100.0/24
        2001:db8::/32
        0.0.0.0
        127.0.0.1
        0.0.0.0 tracker.example
        """
        #expect(try DomainPolicy.parseList(Data(list.utf8)) == ["198.51.100.0/24", "2001:db8::/32", "203.0.113.7", "ads.example", "tracker.example"])
        #expect(DomainPolicy.entry("*.Example.COM") == "example.com")
        #expect(DomainPolicy.entry("10.0.0.0/33") == nil && DomainPolicy.entry("0.0.0.0/0") == nil && DomainPolicy.entry("::1") == nil)

        let entries = ["198.51.100.0/24", "2001:db8::/32", "203.0.113.7", "ads.example"]
        #expect(DomainPolicy.blocked("cdn.ads.example", app: "a", domains: entries, exceptions: [:]) == "ads.example")
        #expect(DomainPolicy.blocked(nil, address: "198.51.100.42", app: "a", domains: entries, exceptions: [:]) == "198.51.100.0/24")
        #expect(DomainPolicy.blocked("safe.example", address: "203.0.113.7", app: "a", domains: entries, exceptions: [:]) == "203.0.113.7")
        #expect(DomainPolicy.blocked(nil, address: "2001:db8:1::5", app: "a", domains: entries, exceptions: [:]) == "2001:db8::/32")
        // IPv4-mapped IPv6 addresses match IPv4 entries, and an app's exception wins.
        #expect(DomainPolicy.blocked(nil, address: "::ffff:203.0.113.7", app: "a", domains: entries, exceptions: [:]) == "203.0.113.7")
        #expect(DomainPolicy.blocked(nil, address: "203.0.113.7", app: "a", domains: entries, exceptions: ["a": ["203.0.113.0/28"]]) == nil)
        #expect(DomainPolicy.blocked("other.example", address: "192.0.2.1", app: "a", domains: entries, exceptions: [:]) == nil)
    }

    @Test func policyDecidesInTheFiltersOrder() {
        var preferences = SavedPreferences(); preferences.profile = .travel
        func decide(_ change: (inout SavedPreferences) -> Void = { _ in }, budget: Bool = false, app: String? = "com.example.App",
                    host: String = "api.example.com", address: String? = nil, apple: Bool = false, recent: Bool? = nil) -> FilterPolicy.Reason {
            var copy = preferences; change(&copy)
            return FilterPolicy(FilterController.policy(copy, budgetReached: budget))
                .decide(.init(app: app, process: "App", host: host, address: address), appleSigned: { apple }, recentDecision: recent).reason
        }
        #expect(decide() == .newAppDefault(false))
        #expect(decide { $0.defaultAllow = true } == .newAppDefault(true))
        #expect(decide { $0.askNewApps = true } == .askNewApps)
        #expect(decide({ $0.askNewApps = true; $0.allowApple = true }, apple: true) == .appleSoftware)
        #expect(decide({ $0.askNewApps = true }, recent: false) == .recentDecision(false))
        #expect(decide { $0.rules = ["Travel": ["com.example.App": true]] } == .appRule(true))
        // The budget stops saved allow rules, but not temporary ones or connection rules.
        #expect(decide({ $0.rules = ["Travel": ["com.example.App": true]] }, budget: true) == .budget)
        if case .temporaryRule = decide({ $0.temporaryRules = ["Travel|com.example.App": TemporaryRule(allowed: true, expires: Date().addingTimeInterval(600))] }, budget: true) {} else { Issue.record("temporary rule should win over the budget") }
        // Hand-blocked hosts and ranges apply, and a connection rule wins over them.
        #expect(decide({ $0.blockedHosts = ["203.0.113.0/24"] }, host: "203.0.113.9", address: "203.0.113.9") == .blocklist("203.0.113.0/24"))
        let rule = ConnectionRule(app: "com.example.App", host: "api.example.com", allowed: true, profile: "Travel")
        if case .connectionRule = decide({ $0.blockedHosts = ["example.com"]; $0.connectionRules = [rule] }) {} else { Issue.record("connection rule should win") }
        #expect(decide({ $0.profile = .unrestricted; $0.blockedHosts = ["example.com"] }) == .unrestricted)
        #expect(decide(app: nil) == .noAppRule && decide(budget: true, app: nil) == .budget)
    }

    @Test func doctorUsesTheSamePolicy() {
        var preferences = SavedPreferences(); preferences.profile = .travel; preferences.blockedHosts = ["*.ads.example"]
        let policy = ConnectionDoctor.Policy(preferences: preferences, filterActive: true, budgetReached: false)
        #expect(ConnectionDoctor.rules(host: "x.ads.example", port: "443", app: nil, policy: policy).detail.contains("ads.example on your blocklist"))
        preferences.askNewApps = true
        let ask = ConnectionDoctor.rules(host: "api.example.com", port: "443", app: "com.example.New", policy: .init(preferences: preferences, filterActive: true, budgetReached: false))
        #expect(ask.status == .warning && ask.detail.contains("asks before"))
    }

    @Test func historySplitsSentAndReceivedPerApp() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let hour = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 12))!
        let usage = [
            UsageEntry(date: hour.addingTimeInterval(30), received: 900, sent: 100, apps: ["Safari": 600, "Music": 400], appsSent: ["Safari": 100, "Music": 0]),
            UsageEntry(date: hour.addingTimeInterval(90), received: 300, sent: 100, apps: ["Safari": 400]),
            UsageEntry(date: hour.addingTimeInterval(-60), received: 5, sent: 5, apps: ["Safari": 10]),
        ]
        let now = hour.addingTimeInterval(1_800)
        let period = BandwidthPeriod.history(usage, app: "Safari", range: .hour, now: now, calendar: calendar)
        #expect(period.start == hour && period.buckets.count == 60)
        // The second entry predates the split, so Safari's bytes divide by the period's 3:1 ratio.
        #expect(period.sent == 200 && period.received == 800)
        #expect(period.buckets[0].sent == 100 && period.buckets[1].received == 300)
        #expect(period.peak?.at == hour && period.peak?.rate == 600.0 / 60)
        let earlier = BandwidthPeriod.history(usage, app: "Safari", range: .hour, offset: 1, now: now, calendar: calendar)
        #expect(earlier.received + earlier.sent == 10)
        let everything = BandwidthPeriod.history(usage, app: nil, range: .day, now: now, calendar: calendar)
        #expect(everything.buckets.count == 24 && everything.received == 1_205 && everything.sent == 205)
        #expect(BandwidthPeriod.history(usage, app: "Mail", range: .month, now: now, calendar: calendar).peak == nil)
    }

    @Test func insightComparesWithUsualAndSharesTheMac() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 12))!
        var usage = (1...4).map { back in
            UsageEntry(date: today.addingTimeInterval(-Double(back) * 86_400), received: 100, sent: 0, apps: ["Sync": 100], networkKey: "home")
        }
        usage.append(UsageEntry(date: today, received: 900, sent: 100, apps: ["Sync": 300, "Mail": 700], networkKey: "home"))
        usage.append(UsageEntry(date: today.addingTimeInterval(60), received: 0, sent: 0, apps: ["Sync": 0], networkKey: "phone"))
        usage.append(UsageEntry(date: today.addingTimeInterval(120), received: 100, sent: 0, apps: ["Sync": 100], networkKey: "phone"))
        let insight = BandwidthInsight.make(usage, app: "Sync", range: .day, now: today.addingTimeInterval(3_600), calendar: calendar)
        #expect(insight.networks.map(\.key) == ["home", "phone"] && insight.networks.map(\.bytes) == [300, 100])
        #expect(insight.comparedWithUsual == 4)
        #expect(insight.share == 400.0 / 1_100)
        #expect(BandwidthInsight.make(usage, app: "Mail", range: .day, now: today.addingTimeInterval(3_600), calendar: calendar).comparedWithUsual == nil)
    }

    @Test func periodFindsNetworkChanges() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let usage = [UsageEntry(date: start.addingTimeInterval(-60), received: 1, sent: 0, apps: [:], networkKey: "home"),
                     UsageEntry(date: start.addingTimeInterval(30), received: 1, sent: 0, apps: [:], networkKey: "home"),
                     UsageEntry(date: start.addingTimeInterval(60), received: 1, sent: 0, apps: [:], networkKey: "phone"),
                     UsageEntry(date: start.addingTimeInterval(90), received: 1, sent: 0, apps: [:]),
                     UsageEntry(date: start.addingTimeInterval(120), received: 1, sent: 0, apps: [:], networkKey: "home")]
        let period = BandwidthPeriod(start: start, end: start.addingTimeInterval(3_600), buckets: [])
        let changes = period.networkChanges(usage)
        #expect(changes.map(\.key) == ["phone", "home"] && changes.first?.date == start.addingTimeInterval(60))
    }

    @MainActor @Test func compactingKeepsTheSentSplit() {
        // Both samples sit inside one hour, three days back, so they merge into one bucket.
        let now = Date(), old = Calendar.current.dateInterval(of: .hour, for: now.addingTimeInterval(-3 * 86_400))!.start.addingTimeInterval(60)
        let usage = [
            UsageEntry(date: old, received: 90, sent: 10, apps: ["curl": 100], appsSent: ["curl": 10]),
            UsageEntry(date: old.addingTimeInterval(60), received: 50, sent: 50, apps: ["curl": 100]),
        ]
        let merged = TrafficStore.compact(usage, now: now)
        #expect(merged.count == 1 && merged[0].apps["curl"] == 200 && merged[0].appsSent?["curl"] == 60)
    }

    @Test func liveSeriesPadsAndSums() {
        var a = LiveSeries(), b = LiveSeries()
        a.append(down: 10, up: 1); a.append(down: 20, up: 2)
        b.append(down: 5, up: 5)
        let recent = a.recent(4)
        #expect(recent.down == [0, 0, 10, 20] && recent.up == [0, 0, 1, 2])
        let sum = LiveSeries.sum([a, b])
        #expect(sum.down == [10, 25] && sum.up == [1, 7])
        let live = BandwidthPeriod.live(a, now: Date())
        #expect(live.buckets.count == 60 && live.received == 30 && live.sent == 3)
    }

    @Test func accessPolicyParsesAndMatches() {
        let policy = InternetAccessPolicy.parse([
            "ApplicationDescription": "Takes screenshots.", "DeveloperName": "MTW", "Website": "javascript:alert(1)",
            "Connections": [
                ["Host": "*.cleanshot.cloud, *.cleanshot.com", "Port": "443", "NetworkProtocol": "TCP", "Purpose": "Uploads.", "Relevance": "Essential", "DenyConsequences": "Uploads fail."],
                ["Host": "api.example.com", "Port": 8443, "Purpose": "Sync.", "IsIncoming": true],
                ["Host": "", "Purpose": "Nothing."],
            ],
        ])
        #expect(policy?.developer == "MTW" && policy?.website == nil && policy?.connections.count == 2)
        #expect(policy?.connections[0].hosts == ["*.cleanshot.cloud", "*.cleanshot.com"] && policy?.connections[0].essential == true)
        #expect(policy?.connections[1].port == "8443" && policy?.connections[1].incoming == true)
        #expect(policy?.connection(for: "eu.cleanshot.com")?.purpose == "Uploads.")
        #expect(policy?.connection(for: "cleanshot.com") == nil)
        #expect(policy?.connection(for: "API.example.com")?.purpose == "Sync.")
        #expect(InternetAccessPolicy.parse(["Connections": []]) == nil)
    }

    @Test func openConnectionsGroupByRemoteAddress() {
        let snapshot = """
        ,bytes_in,bytes_out,
        Safari.501,1500,700,
        tcp4 192.168.1.5:50000<->17.253.1.1:443,1000,500,
        tcp4 192.168.1.5:50001<->17.253.1.1:443,500,200,
        udp6 fe80::1%en0.5353<->*.*,0,0,
        tcp4 127.0.0.1:5000<->127.0.0.1:6000,9,9,
        tcp6 2a00::5.50002<->2606:4700::1.443,40,4,
        Other.777,5,5,
        tcp4 10.0.0.2:4000<->1.2.3.4:443,5,5,
        """
        let destinations = OpenConnections.parse(snapshot, pids: [501])
        #expect(destinations.map(\.address) == ["17.253.1.1", "2606:4700::1"])
        #expect(destinations[0].received == 1500 && destinations[0].sent == 700 && destinations[0].connections == 2 && destinations[0].ports == ["443"])
    }

    @Test func geoLookupFindsTheEnclosingRange() {
        let starts: [UInt32] = [0, 100, 200], codes: [UInt16] = [1, 2, 3]
        #expect(GeoIP.lookup(UInt32(150), in: starts, codes: codes) == 2)
        #expect(GeoIP.lookup(UInt32(200), in: starts, codes: codes) == 3)
        #expect(GeoIP.lookup(UInt32(5), in: [10], codes: [1]) == nil)
        #expect(GeoIP.isPrivate([192, 168, 1, 1]) && GeoIP.isPrivate([100, 64, 0, 1]) && !GeoIP.isPrivate([8, 8, 8, 8]))
        #expect(GeoIP.Country(code: "DE").flag == "🇩🇪")
    }

    @Test func relayActionsCarryArguments() {
        #expect(AppRelay.known("decide|allow|process:curl|") && AppRelay.known("approvals") && !AppRelay.known("evil|scan"))
    }
}
