import Foundation
import Testing
@testable import KilobatCore

/// Connections › Rules lists every rule wherever it was made, and removing one removes exactly that entry.
struct RuleListTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let slack = "com.tinyspeck.slackmacgap"

    func sample() -> SavedPreferences {
        var preferences = SavedPreferences()
        preferences.rules = ["Work": [slack: true, "process:node": false], "Travel": ["com.apple.Music": false]]
        preferences.temporaryRules = ["Work|com.spotify.client": TemporaryRule(allowed: false, expires: now.addingTimeInterval(600)),
                                      "Travel|com.dropbox.Dropbox": TemporaryRule(allowed: true, expires: now.addingTimeInterval(60)),
                                      "Work|com.old.App": TemporaryRule(allowed: true, expires: now.addingTimeInterval(-60))]
        let old = ConnectionRule(app: slack, host: "a.example", allowed: false, profile: "Work")
        let new = ConnectionRule(app: slack, host: "b.example", port: "443", direction: "outgoing", allowed: true, profile: "Work")
        let timed = ConnectionRule(app: "process:curl", host: "c.example", allowed: false, profile: "Work", expires: now.addingTimeInterval(300))
        let lapsed = ConnectionRule(app: "process:curl", host: "d.example", allowed: false, profile: "Work", expires: now.addingTimeInterval(-1))
        preferences.connectionRules = [old, new, timed, lapsed]
        preferences.blockedHosts = ["tracker.example"]
        preferences.domainExceptions = ["com.apple.Safari": ["cdn.example", "img.example"]]
        preferences.allowedSites = ["shop.example"]
        return preferences
    }

    @Test func everyKindIsListedAndLapsedRulesAreNot() {
        let rules = sample().listedRules(now: now)
        #expect(rules.count == 12)
        #expect(rules.filter { $0.kind == .app }.count == 5)
        #expect(rules.filter { $0.kind == .destination }.count == 3)
        #expect(rules.filter { $0.kind == .domain }.count == 4)
        #expect(!rules.contains { $0.app == "com.old.App" || $0.host == "d.example" })
    }

    @Test func timedRulesComeFirstSoonestToEnd() {
        let rules = sample().listedRules(now: now)
        #expect(rules.prefix(3).map { $0.app } == ["com.dropbox.Dropbox", "process:curl", "com.spotify.client"])
        #expect(rules.dropFirst(3).allSatisfy { $0.expires == nil })
    }

    @Test func destinationRulesAreNewestFirstWithTheirDetails() {
        let destinations = sample().listedRules(now: now).filter { $0.kind == .destination && $0.expires == nil }
        #expect(destinations.map(\.host) == ["b.example", "a.example"])
        #expect(destinations[0].port == "443" && destinations[0].direction == "outgoing" && destinations[0].allowed)
        #expect(destinations[1].port == nil && destinations[1].direction == nil && destinations[1].profile == "Work")
    }

    @Test func domainRulesHoldForEveryAppOrOne() {
        let domains = sample().listedRules(now: now).filter { $0.kind == .domain }
        #expect(domains.first { $0.host == "tracker.example" }.map { !$0.allowed && $0.app == nil && $0.profile == nil } == true)
        #expect(domains.first { $0.host == "cdn.example" }.map { $0.allowed && $0.app == "com.apple.Safari" } == true)
        #expect(domains.first { $0.host == "shop.example" }.map { $0.allowed && $0.app == nil } == true)
    }

    @Test func removingEndsExactlyThatRule() {
        var preferences = sample()
        for rule in preferences.listedRules(now: now) { preferences.remove(rule) }
        #expect(preferences.listedRules(now: now).isEmpty)
        #expect(preferences.rules.isEmpty && preferences.blockedHosts == nil && preferences.domainExceptions == nil && preferences.allowedSites == nil)
        // A lapsed timed rule isn't listed, so it isn't touched either.
        #expect(preferences.temporaryRules?.keys.sorted() == ["Work|com.old.App"] && preferences.connectionRules?.map(\.host) == ["d.example"])

        var one = sample()
        let exception = one.listedRules(now: now).first { $0.host == "cdn.example" }!
        one.remove(exception)
        #expect(one.domainExceptions == ["com.apple.Safari": ["img.example"]])
        let saved = one.listedRules(now: now).first { $0.origin == .app(profile: "Work", key: slack) }!
        one.remove(saved)
        #expect(one.rules["Work"] == ["process:node": false] && one.connectionRules?.count == 4)
    }
}
