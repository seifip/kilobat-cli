import Foundation

/// What someone came for: sets what the menu bar shows and which first step the last onboarding screen offers.
public enum OnboardingGoal: String, CaseIterable, Identifiable, Sendable {
    case wifi, data, realtime, agents, blocking
    public var id: String { rawValue }
    /// The menu bar readings this goal turns on.
    public var menuItems: [String] {
        switch self { case .wifi: ["menu.latency"]; case .data: ["menu.budget"]; case .realtime: ["menu.latency", "menu.game"]; case .agents, .blocking: [] }
    }
    /// Its first step opens a Pro screen: budgets, History's agent log, rules.
    public var needsPro: Bool {
        switch self { case .data, .agents, .blocking: true; case .wifi, .realtime: false }
    }
}

/// One row on onboarding's last screen.
public enum OnboardingFirstStep: Hashable, Sendable {
    /// Open the goal's own screen.
    case open(OnboardingGoal)
    /// Start the free trial, then open the goal's own screen.
    case trialThenOpen(OnboardingGoal)
    /// Somewhere free that still answers the goal: what is using the connection.
    case usage
}

public enum OnboardingPlan {
    /// The steps for the chosen goals, in the goals' own order. Nobody is sent to a locked screen: a Pro goal starts the
    /// trial first when one can be started, and otherwise falls back to the free usage view (listed once).
    public static func firstSteps(goals: Set<OnboardingGoal>, hasPro: Bool, trialAvailable: Bool) -> [OnboardingFirstStep] {
        var steps: [OnboardingFirstStep] = []
        for goal in OnboardingGoal.allCases where goals.contains(goal) {
            let step: OnboardingFirstStep = !goal.needsPro || hasPro ? .open(goal) : trialAvailable ? .trialThenOpen(goal) : .usage
            if !steps.contains(step) { steps.append(step) }
        }
        return steps.isEmpty ? [.open(.wifi)] : steps
    }
    /// The separate trial offer is redundant once a listed step already starts it.
    public static func offersTrialLink(steps: [OnboardingFirstStep], hasPro: Bool, trialAvailable: Bool) -> Bool {
        guard !hasPro, trialAvailable else { return false }
        return !steps.contains { if case .trialThenOpen = $0 { true } else { false } }
    }
}
