import Testing
@testable import KilobatCore

struct FilterBudgetTests {
    @Test @MainActor func unrestrictedBypassesBudgetAndSavedDenials() {
        var preferences = SavedPreferences()
        preferences.profile = .unrestricted
        preferences.defaultAllow = false
        let policy = FilterController().policy(preferences, budgetReached: true)
        #expect(policy["unrestricted"] as? Bool == true)
        #expect(policy["budgetReached"] as? Bool == false)
    }

    @Test @MainActor func restrictedProfileRetainsBudgetEnforcement() {
        var preferences = SavedPreferences()
        preferences.profile = .travel
        let policy = FilterController().policy(preferences, budgetReached: true)
        #expect(policy["unrestricted"] as? Bool == false)
        #expect(policy["budgetReached"] as? Bool == true)
    }
}
