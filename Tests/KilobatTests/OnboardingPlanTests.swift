import Foundation
import Testing
@testable import KilobatCore

struct OnboardingPlanTests {
    func steps(_ goals: Set<OnboardingGoal>, pro: Bool = false, trial: Bool = true) -> [OnboardingFirstStep] {
        OnboardingPlan.firstSteps(goals: goals, hasPro: pro, trialAvailable: trial)
    }
    func link(_ goals: Set<OnboardingGoal>, pro: Bool = false, trial: Bool = true) -> Bool {
        OnboardingPlan.offersTrialLink(steps: steps(goals, pro: pro, trial: trial), hasPro: pro, trialAvailable: trial)
    }

    @Test func noGoalsMeansANetworkCheck() {
        for pro in [false, true] { for trial in [false, true] { #expect(steps([], pro: pro, trial: trial) == [.open(.wifi)]) } }
    }
    @Test func freeGoalsOpenDirectlyAndKeepTheTrialLink() {
        #expect(steps([.wifi, .realtime]) == [.open(.wifi), .open(.realtime)])
        #expect(link([.wifi, .realtime]))
    }
    @Test func proGoalsStartTheTrialFirst() {
        #expect(steps([.data, .agents, .blocking]) == [.trialThenOpen(.data), .trialThenOpen(.agents), .trialThenOpen(.blocking)])
        #expect(!link([.data, .agents, .blocking]))
    }
    @Test func withoutATrialProGoalsFallBackToUsageOnce() {
        #expect(steps([.data, .agents, .blocking], trial: false) == [.usage])
        #expect(!link([.data, .agents, .blocking], trial: false))
    }
    @Test func mixedGoalsKeepTheFreeOne() {
        #expect(steps([.wifi, .data], trial: false) == [.open(.wifi), .usage])
    }
    @Test func proOwnersOpenEverythingDirectly() {
        #expect(steps([.data, .blocking], pro: true) == [.open(.data), .open(.blocking)])
        #expect(!link([.data, .blocking], pro: true))
    }
    @Test func orderFollowsTheGoalsNotInsertion() {
        #expect(steps([.blocking, .wifi], pro: true).first == .open(.wifi))
    }
    @Test func onlyThreeGoalsNeedPro() {
        #expect(OnboardingGoal.allCases.filter(\.needsPro) == [.data, .agents, .blocking])
        #expect(OnboardingGoal.realtime.menuItems == ["menu.latency", "menu.game"])
    }
}
