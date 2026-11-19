import Foundation
import Testing
@testable import KilobatCore

struct FilterPolicyCacheTests {
    /// A profile with a full blocklist and some destination rules, as the app saves it for the filter.
    private func configuration(entries: Int = 10_000, profile: NetworkProfile = .travel, budgetReached: Bool = false,
                               defaultAllow: Bool = false) -> [String: Any] {
        var preferences = SavedPreferences(); preferences.profile = profile; preferences.defaultAllow = defaultAllow
        preferences.blockedDomains = (0..<entries).map { "host\($0).example" }
        preferences.blockedHosts = ["198.51.100.0/24", "2001:db8::/32"]
        preferences.domainExceptions = ["com.example.App": ["host7.example"]]
        // A saved rule keeps its id, so two configurations built from the same preferences are equal.
        var rule = ConnectionRule(app: "com.example.App", host: "rule.example", allowed: false, profile: profile.rawValue)
        rule.id = UUID(uuidString: "00000000-0000-0000-0000-000000000032")!
        preferences.connectionRules = [rule]
        // Round-trip through a property list, so values arrive as they do from NEFilterProviderConfiguration.
        let saved = FilterController.policy(preferences, budgetReached: budgetReached, boot: "A", uptime: 100)
        return Self.roundTrip(saved)
    }
    private static func roundTrip(_ saved: [String: Any]) -> [String: Any] {
        let data = try! PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0)
        return try! PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    }
    private let flow = FilterPolicy.Flow(app: "com.example.Other", process: "Other", host: "cdn.unlisted.example", address: "203.0.113.9", port: "443")
    private let app = FilterPolicy.Flow(app: "com.example.App", process: "App", host: "cdn.unlisted.example", address: "203.0.113.9", port: "443")

    @Test func timings() {
        // A separately built equal dictionary: a fresh property-list copy, since other suites running alongside can
        // change shared preferences state between two calls to `configuration()`.
        let saved = configuration(), clock = ContinuousClock()
        let equal = Self.roundTrip(saved)
        let entries = saved["blockedDomains"] as! [String], exceptions = saved["domainExceptions"] as! [String: [String]]
        let build = clock.measure { for _ in 0..<50 { _ = FilterPolicy(saved) } } / 50
        let policy = FilterPolicy(saved)
        let decide = clock.measure { for _ in 0..<50 { _ = policy.decide(flow) } } / 50
        // What every decision paid for the blocklist before it was compiled.
        let uncompiled = clock.measure { for _ in 0..<50 { _ = DomainPolicy.blocked(flow.host, address: flow.address, app: flow.app!, domains: entries, exceptions: exceptions) } } / 50
        let cache = FilterPolicyCache(); _ = cache.policy(for: saved)
        let hit = clock.measure { for _ in 0..<50 { _ = cache.policy(for: equal) } } / 50
        print("TIMING (debug build, 10,000 entries) build one policy: \(build)  decide one unlisted flow: \(decide)  uncompiled blocklist check: \(uncompiled)  cache hit: \(hit)")
        #expect(cache.builds == 1)
    }

    @Test func compiledBlocklistAgreesWithBlocked() {
        let entries = ["198.51.100.0/24", "2001:db8::/32", "203.0.113.7", "ads.example", "*.Wild.Example.", "track.example"]
        let exceptionSets: [[String: [String]]] = [[:], ["allowed.app": ["track.example"]], ["allowed.app": ["198.51.100.0/25", "*.WILD.example"]]]
        let cases: [(String?, String?)] = [
            ("cdn.ads.example", nil), ("ads.example", nil), ("notads.example", nil), ("ADS.Example.", nil), ("x.wild.example", nil),
            ("wild.example", nil), ("a.track.example", nil), ("nottrack.example", nil), (nil, "198.51.100.42"), (nil, "198.51.101.1"),
            (nil, "2001:db8::1"), (nil, "2001:db9::1"), ("203.0.113.7", nil), (nil, "::ffff:198.51.100.9"), ("host.example", "203.0.113.7"),
            (nil, nil), ("", nil), ("fe80::1%en0", nil),
        ]
        for exceptions in exceptionSets {
            let compiled = DomainPolicy.Compiled(domains: entries, exceptions: exceptions)
            for (host, address) in cases {
                for app in ["allowed.app", "other.app"] {
                    #expect(compiled.first(host, address: address, app: app) == DomainPolicy.blocked(host, address: address, app: app, domains: entries, exceptions: exceptions),
                            "\(host ?? "nil") \(address ?? "nil") \(app) \(exceptions)")
                }
            }
        }
    }

    @Test func settingEntriesAfterInitStillBlocks() {
        var policy = FilterPolicy(); policy.defaultAllow = true; policy.blockedEntries = ["upload.example"]
        #expect(policy.decide(.init(app: "a", process: "a", host: "x.upload.example")).reason == .blocklist("upload.example"))
        policy.domainExceptions = ["a": ["upload.example"]]
        #expect(policy.decide(.init(app: "a", process: "a", host: "x.upload.example")).reason == .newAppDefault(true))
    }

    @Test func sameConfigurationParsesOnce() {
        let cache = FilterPolicyCache(), saved = configuration(entries: 3)
        _ = cache.policy(for: saved); _ = cache.policy(for: saved); _ = cache.policy(for: Self.roundTrip(saved))
        #expect(cache.builds == 1)
    }

    @Test func aChangedRuleDecidesTheNextFlow() {
        let cache = FilterPolicyCache(), a = configuration(entries: 3)
        var b = a; b["rules"] = ["com.example.App": true]
        #expect(cache.policy(for: a).decide(app).reason == .newAppDefault(false))
        #expect(cache.policy(for: b).decide(app).reason == .appRule(true))
        #expect(cache.policy(for: a).decide(app).reason == .newAppDefault(false))
        #expect(cache.builds == 3)
    }

    /// Changes one value, whatever its type, so the configuration is no longer equal.
    private static func changed(_ value: Any) -> Any {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return !number.boolValue }
        if let number = value as? NSNumber { return number.doubleValue + 1 }
        if let text = value as? String { return text + "x" }
        if let list = value as? [Any] { return list + ["changed.example"] }
        if var dictionary = value as? [String: Any] {
            // A nested value changes when there is one; an empty dictionary gains one.
            if let key = dictionary.keys.sorted().first { dictionary[key] = changed(dictionary[key]!) } else { dictionary["changed"] = true }
            return dictionary
        }
        Issue.record("A saved value of a type the test doesn't know: \(type(of: value))")
        return value
    }

    @Test func everySavedKeyInvalidates() {
        // Every key the app saves, the lease included.
        let saved = configuration(entries: 3, budgetReached: true)
        #expect(saved["stateLease"] != nil)
        let cache = FilterPolicyCache(); _ = cache.policy(for: saved)
        var builds = 1
        for key in saved.keys.sorted() {
            var copy = saved; copy[key] = Self.changed(saved[key]!)
            _ = cache.policy(for: copy); builds += 1
            #expect(cache.builds == builds, "a change to \(key) was not noticed")
            _ = cache.policy(for: saved); builds += 1
        }
        // And the nested dictionaries' values one by one.
        for key in ["killSwitch", "protection", "stateLease"] {
            let nested = saved[key] as! [String: Any]
            for inner in nested.keys {
                var copy = saved, changedNested = nested
                changedNested[inner] = Self.changed(nested[inner]!)
                copy[key] = changedNested
                _ = cache.policy(for: copy); builds += 1
                #expect(cache.builds == builds, "a change to \(key).\(inner) was not noticed")
                _ = cache.policy(for: saved); builds += 1
            }
        }
    }

    @Test func aNestedChangeInvalidates() {
        let saved = configuration(entries: 3), cache = FilterPolicyCache()
        _ = cache.policy(for: saved)
        var domains = saved; var list = saved["blockedDomains"] as! [String]; list[1] = "other.example"; domains["blockedDomains"] = list
        var exceptions = saved; exceptions["domainExceptions"] = ["com.example.App": ["host8.example"]]
        var rules = saved; rules["connectionRules"] = Self.changed(saved["connectionRules"]!)
        for copy in [domains, exceptions, rules] { _ = cache.policy(for: copy) }
        #expect(cache.builds == 4)
        #expect(cache.policy(for: domains).blockedEntries[1] == "other.example")
    }

    @Test func expiryIsJudgedAtDecisionTime() {
        let t = Date(timeIntervalSince1970: 2_000_000_000)
        var saved = configuration(entries: 3); saved["temporary"] = ["com.example.App": ["allowed": true, "expires": t.timeIntervalSince1970]]
        let cache = FilterPolicyCache()
        let before = cache.policy(for: saved).decide(app, now: t.addingTimeInterval(-1)).reason
        let after = cache.policy(for: saved).decide(app, now: t.addingTimeInterval(1)).reason
        if case .temporaryRule = before {} else { Issue.record("expected the temporary rule, got \(before)") }
        if case .temporaryRule = after { Issue.record("an expired temporary rule still decided") }
        #expect(cache.builds == 1)
    }

    @Test func killSwitchPauseIsJudgedAtDecisionTime() {
        let t = Date(timeIntervalSince1970: 2_000_000_000)
        var saved = configuration(entries: 3); saved["killSwitch"] = KillSwitchPolicy(armed: true, vpnDown: true, allowedUntil: t).configuration
        let cache = FilterPolicyCache()
        #expect(cache.policy(for: saved).decide(flow, now: t.addingTimeInterval(-1)).reason != .killSwitch)
        #expect(cache.policy(for: saved).decide(flow, now: t.addingTimeInterval(1)).reason == .killSwitch)
        #expect(cache.builds == 1)
    }

    /// The lease is judged on every call, against that call's clock, never baked into the kept policy.
    @Test func aLapsedLeaseIsHonouredWithACachedPolicy() {
        let saved = configuration(entries: 3, budgetReached: true, defaultAllow: true), cache = FilterPolicyCache()
        #expect(cache.policy(for: saved, boot: "A", uptime: 200).decide(flow).reason == .budget)
        let lapsed = cache.policy(for: saved, boot: "A", uptime: 1_800)
        #expect(!lapsed.budgetReached && lapsed.decide(flow).reason == .newAppDefault(true))
        #expect(!cache.policy(for: saved, boot: "B", uptime: 5).budgetReached)
        // The kept policy itself still holds the block: a clock read before the lease ends applies it again.
        #expect(cache.policy(for: saved, boot: "A", uptime: 1_799).decide(flow).reason == .budget)
        // Rules saved by the person don't lapse with it.
        #expect(lapsed.decide(.init(app: "com.example.App", process: "App", host: "rule.example")).verdict == .block)
        #expect(cache.builds == 1)
        // Once the app renews, the renewed configuration decides the next flow.
        var renewed = saved; renewed["stateLease"] = StateLease.issued(boot: "A", uptime: 1_700).configuration
        #expect(cache.policy(for: renewed, boot: "A", uptime: 1_800).decide(flow).reason == .budget)
        #expect(cache.builds == 2)
    }

    @Test func aChangedConfigurationIsHonouredOnTheNextCall() {
        let reached = configuration(entries: 3, budgetReached: true, defaultAllow: true), cache = FilterPolicyCache()
        let cleared = configuration(entries: 3, budgetReached: false, defaultAllow: true)
        #expect(cache.policy(for: reached, boot: "A", uptime: 200).decide(flow).reason == .budget)
        #expect(cache.policy(for: cleared, boot: "A", uptime: 201).decide(flow).reason == .newAppDefault(true))
        #expect(cache.policy(for: reached, boot: "A", uptime: 202).decide(flow).reason == .budget)
        #expect(cache.builds == 3)
    }

    @Test func concurrentCallsAgree() {
        nonisolated(unsafe) let travel = configuration(entries: 3, profile: .travel), work = configuration(entries: 3, profile: .work)
        let cache = FilterPolicyCache()
        let mismatches = Mismatches()
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let saved = index.isMultiple(of: 2) ? travel : work
            if cache.policy(for: saved).profile != saved["profile"] as? String { mismatches.add() }
        }
        #expect(mismatches.count == 0)
    }
}

private final class Mismatches: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
