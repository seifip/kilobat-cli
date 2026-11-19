import Foundation
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

    private static func preferences() -> SavedPreferences {
        var preferences = SavedPreferences(); preferences.profile = .travel
        return preferences
    }
    /// Everything derived set: a budget reached, an app limit used up, a metered network.
    private static func derived(_ preferences: SavedPreferences = preferences(), uptime: TimeInterval = 100,
                                killSwitch: KillSwitchPolicy = KillSwitchPolicy()) -> [String: Any] {
        FilterController.policy(preferences, budgetReached: true, quotaReached: ["com.example.app"], metered: true, killSwitch: killSwitch, boot: "A", uptime: uptime)
    }
    private static func lapsed(_ policy: FilterPolicy) -> Bool {
        !policy.budgetReached && policy.quotaReached.isEmpty && !policy.updatersPaused && !policy.syncPaused
    }

    @Test func derivedBlocksCarryALease() {
        #expect(Self.derived()["stateLease"] != nil)
        #expect(FilterController.policy(Self.preferences(), budgetReached: false, boot: "A", uptime: 100)["stateLease"] == nil)
    }

    @Test func theLeaseDoesNotChangeWithinAPeriod() throws {
        func json(_ uptime: TimeInterval) throws -> Data { try JSONSerialization.data(withJSONObject: Self.derived(uptime: uptime), options: .sortedKeys) }
        #expect(try json(100) == json(800))
        #expect(try json(100) != json(900))
    }

    @Test func aRunningAppsBlocksApply() {
        let policy = FilterPolicy(Self.derived(), boot: "A", uptime: 200)
        #expect(policy.budgetReached && policy.quotaReached == ["com.example.app"] && policy.updatersPaused && policy.syncPaused)
        #expect(policy.stateLease == StateLease(boot: "A", until: 1800))
    }

    @Test func theyLapseWhenTheAppStopsRenewing() {
        #expect(Self.lapsed(FilterPolicy(Self.derived(), boot: "A", uptime: 1800)))
    }

    @Test func theyLapseAfterARestart() {
        #expect(Self.lapsed(FilterPolicy(Self.derived(), boot: "B", uptime: 5)))
    }

    @Test func savedRulesNeverLapse() {
        var preferences = Self.preferences()
        preferences.rules[preferences.profile.rawValue] = ["com.example.blocked": false]
        preferences.blockedDomains = ["ads.example"]
        let configuration = Self.derived(preferences, killSwitch: KillSwitchPolicy(armed: true, vpnDown: true))
        let policy = FilterPolicy(configuration, boot: "B", uptime: 99_999)
        #expect(Self.lapsed(policy))
        #expect(policy.rules == ["com.example.blocked": false])
        #expect(policy.blockedEntries == ["ads.example"])
        #expect(policy.defaultAllow == preferences.defaultAllow)
        #expect(policy.killSwitch.armed && policy.killSwitch.vpnDown)
        #expect(policy.decide(.init(app: "com.example.blocked", process: "blocked", host: "example.com")).reason == .killSwitch)
    }

    @Test func aConfigurationWithoutALeaseHoldsAsBefore() {
        var configuration = Self.derived()
        configuration["stateLease"] = nil
        let policy = FilterPolicy(configuration, boot: "B", uptime: 99_999)
        #expect(policy.budgetReached && policy.stateLease == nil)
    }

    @Test func anExpiredBudgetNoLongerBlocks() {
        var preferences = Self.preferences(); preferences.defaultAllow = true
        let configuration = Self.derived(preferences)
        let flow = FilterPolicy.Flow(app: "com.example.other", process: "other", host: "example.com")
        #expect(FilterPolicy(configuration, boot: "A", uptime: 1800).decide(flow).verdict != .block)
        #expect(FilterPolicy(configuration, boot: "A", uptime: 200).decide(flow).verdict == .block)
    }
}

struct StateLeaseTests {
    @Test func aLeaseHoldsForOneToTwoPeriods() {
        #expect(StateLease.issued(boot: "A", uptime: 0).until == 1800)
        #expect(StateLease.issued(boot: "A", uptime: 899).until == 1800)
        #expect(StateLease.issued(boot: "A", uptime: 900).until == 2700)
    }

    @Test func itEndsWithTimeOrARestart() {
        let lease = StateLease(boot: "A", until: 1800)
        #expect(lease.holds(boot: "A", uptime: 1799))
        #expect(!lease.holds(boot: "A", uptime: 1800))
        #expect(!lease.holds(boot: "B", uptime: 10))
        #expect(lease.holds(boot: "", uptime: 10))
        #expect(StateLease(boot: "", until: 1800).holds(boot: "B", uptime: 10))
    }

    @Test func itRoundTripsThroughTheConfiguration() {
        let lease = StateLease(boot: "A", until: 1800)
        #expect(StateLease(lease.configuration) == lease)
        #expect(StateLease(nil) == nil)
        #expect(StateLease(["boot": "A"]) == nil)
    }

    @Test func thisBootCanBeRead() {
        #expect(!StateLease.currentBoot.isEmpty)
    }
}

/// At launch the filter keeps what it was last given until the app's monitors have looked for themselves.
struct FilterLaunchTests {
    @Test func theSavedKillSwitchAndProtectionAreReadBack() {
        let armed = KillSwitchPolicy(armed: true, vpnDown: true, tunnel: "utun4", allowLAN: false, vpnApps: ["io.example.vpn"])
        let settings = ProtectionSettings(threats: true, trackers: true, allowed: ["example.com"], digest: "abc")
        let configuration = FilterController.policy(SavedPreferences(), budgetReached: false, killSwitch: armed, protection: settings)
        let saved = FilterController.savedState(configuration)
        #expect(saved.killSwitch == armed && saved.protection == settings)
    }

    @Test func nothingSavedMeansOff() {
        #expect(FilterController.savedState(nil).killSwitch == KillSwitchPolicy())
        #expect(FilterController.savedState(nil).protection == ProtectionSettings())
        #expect(FilterController.savedState([:]).killSwitch.armed == false)
    }

    @Test @MainActor func aBuildWithoutTheFilterHasNothingToWaitFor() {
        #expect(FilterController().stateKnown)
    }
}

/// The filter's policy is worked out on a change, not every second; nothing that changes it waits longer than the
/// budget check's interval.
struct PolicySyncScheduleTests {
    /// Holds the schedule as the loop does, so `#expect` can call it.
    private final class Driver {
        var schedule = PolicySyncSchedule()
        func due(filterWantsPolicy: Bool, inputs: () -> PolicySyncSchedule.Inputs, now: Date) -> Bool {
            schedule.due(filterWantsPolicy: filterWantsPolicy, inputs: inputs, now: now)
        }
    }
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func inputs(_ preferences: SavedPreferences = SavedPreferences(), network: String = "home", metered: Bool = false) -> PolicySyncSchedule.Inputs {
        PolicySyncSchedule.Inputs(preferences: preferences, network: network, metered: metered)
    }
    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    @Test func withoutAFilterNothingIsWorkedOut() {
        let schedule = Driver(); var reads = 0
        for second in 0..<30 {
            #expect(!schedule.due(filterWantsPolicy: false, inputs: { reads += 1; return inputs() }, now: at(Double(second))))
        }
        // Not even the cheap inputs are read, and so no usage scan can run.
        #expect(reads == 0)
    }

    @Test func theFilterTurningOnSyncsAtOnce() {
        let schedule = Driver()
        #expect(schedule.due(filterWantsPolicy: true, inputs: { inputs() }, now: at(0)))
        #expect(!schedule.due(filterWantsPolicy: true, inputs: { inputs() }, now: at(1)))
        #expect(!schedule.due(filterWantsPolicy: false, inputs: { inputs() }, now: at(2)))
        #expect(schedule.due(filterWantsPolicy: true, inputs: { inputs() }, now: at(3)))
    }

    @Test func nothingChangedWaitsForTheBudgetCheck() {
        let schedule = Driver()
        let due = (0...10).filter { schedule.due(filterWantsPolicy: true, inputs: { inputs() }, now: at(Double($0))) }
        #expect(due == [0, 5, 10])
        #expect(PolicySyncSchedule.budgetCheckEvery == 5)
    }

    @Test func aRuleChangeSyncsAtOnce() {
        let schedule = Driver(); var preferences = SavedPreferences()
        #expect(schedule.due(filterWantsPolicy: true, inputs: { inputs(preferences) }, now: at(0)))
        preferences.rules[preferences.profile.rawValue] = ["com.example.app": false]
        #expect(schedule.due(filterWantsPolicy: true, inputs: { inputs(preferences) }, now: at(1)))
        preferences.blockedDomains = ["example.com"]
        #expect(schedule.due(filterWantsPolicy: true, inputs: { inputs(preferences) }, now: at(2)))
        #expect(!schedule.due(filterWantsPolicy: true, inputs: { inputs(preferences) }, now: at(3)))
    }

    @Test func aNetworkOrCostChangeSyncsAtOnce() {
        let schedule = Driver(); var preferences = SavedPreferences()
        #expect(schedule.due(filterWantsPolicy: true, inputs: { inputs(preferences) }, now: at(0)))
        #expect(schedule.due(filterWantsPolicy: true, inputs: { inputs(preferences, network: "café") }, now: at(1)))
        #expect(schedule.due(filterWantsPolicy: true, inputs: { inputs(preferences, network: "café", metered: true) }, now: at(2)))
        preferences.setCost(.metered, for: "café")
        #expect(schedule.due(filterWantsPolicy: true, inputs: { inputs(preferences, network: "café", metered: true) }, now: at(3)))
        #expect(!schedule.due(filterWantsPolicy: true, inputs: { inputs(preferences, network: "café", metered: true) }, now: at(4)))
    }

    @Test func aTemporaryRuleExpiringSyncs() {
        let schedule = Driver(); var preferences = SavedPreferences()
        preferences.temporaryRules = [preferences.profile.rawValue + "|com.example.app": TemporaryRule(allowed: true, expires: at(2.5))]
        let due = (0...6).filter { schedule.due(filterWantsPolicy: true, inputs: { inputs(preferences) }, now: at(Double($0))) }
        // 0: the filter is new; 3: the rule ran out between 2 and 3.
        #expect(due == [0, 3])
        // Another profile's rule isn't in this policy.
        var other = SavedPreferences()
        other.temporaryRules = ["not-this-profile|com.example.app": TemporaryRule(allowed: true, expires: at(1.5))]
        #expect(!PolicySyncSchedule.temporaryExpired(other, after: at(1), upTo: at(2)))
    }

    @Test func aClockSetBackDoesNotStallTheBudgetCheck() {
        let schedule = Driver()
        #expect(schedule.due(filterWantsPolicy: true, inputs: { inputs() }, now: at(0)))
        #expect(schedule.due(filterWantsPolicy: true, inputs: { inputs() }, now: at(-3_600)))
        #expect(!schedule.due(filterWantsPolicy: true, inputs: { inputs() }, now: at(-3_599)))
    }

    /// A budget or app limit reached between changes is in the filter's policy within `budgetCheckEvery` seconds,
    /// whatever the moment it is reached and whatever else happens around it.
    @Test func aBudgetReachedIsInThePolicyWithinTheFallback() {
        for reachedAt in 0..<40 {
            for changeEvery in [0, 3, 7] {
                let schedule = Driver(); var preferences = SavedPreferences(), seen: Int?
                for second in 0..<60 {
                    if changeEvery > 0, second % changeEvery == 0 { preferences.rules[preferences.profile.rawValue] = ["app\(second)": true] }
                    let due = schedule.due(filterWantsPolicy: true, inputs: { inputs(preferences) }, now: at(Double(second)))
                    // A sync works the budget out as it is at that moment.
                    if due, second >= reachedAt, seen == nil { seen = second }
                }
                #expect(seen != nil && seen! - reachedAt <= Int(PolicySyncSchedule.budgetCheckEvery))
            }
        }
    }
}
