import Testing
@testable import KilobatCore

struct RuleLooseningTests {
    @Test func everyLooseningChangeIsFreeAndEveryTighteningOneIsPro() {
        let cases: [(LooseningChange, Bool)] = [
            (.profile(to: .unrestricted), true),
            (.profile(to: .travel), false),
            (.profile(to: .work), false),
            (.appRule(allowed: true), true),
            (.appRule(allowed: false), false),
            (.removeRule(allowed: false), true),
            (.removeRule(allowed: true), false),
            (.newApps(from: .block, to: .ask), true),
            (.newApps(from: .block, to: .allow), true),
            (.newApps(from: .ask, to: .allow), true),
            (.newApps(from: .allow, to: .ask), false),
            (.newApps(from: .ask, to: .block), false),
            (.newApps(from: .ask, to: .ask), false),
            (.allowApple(true), true),
            (.allowApple(false), false),
            (.filter(on: false), true),
            (.filter(on: true), false),
        ]
        for (change, expected) in cases {
            #expect(RuleLoosening.permitted(change, hasPro: false) == expected, "\(change)")
            #expect(RuleLoosening.permitted(change, hasPro: true), "\(change)")
        }
    }

    @Test func savedRulesAreEnforcedOnlyWithTheFilterOnInAFilteringProfile() {
        var preferences = SavedPreferences()
        preferences.profile = .travel
        #expect(RuleLoosening.enforcedWithoutPro(preferences, filterActive: true, hasPro: false))
        #expect(!RuleLoosening.enforcedWithoutPro(preferences, filterActive: false, hasPro: false))
        #expect(!RuleLoosening.enforcedWithoutPro(preferences, filterActive: true, hasPro: true))
        preferences.profile = .unrestricted
        #expect(!RuleLoosening.enforcedWithoutPro(preferences, filterActive: true, hasPro: false))
    }
}
