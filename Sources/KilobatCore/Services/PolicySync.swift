import Foundation

/// When `FilterController.observe` works the filter's policy out again. It asks once a second; working out the budget
/// and the app limits scans usage history, so that happens on a change and otherwise every `budgetCheckEvery`
/// seconds, and none of it happens while no filter is there to take a policy.
///
/// Every input of `FilterController.policy`, and what notices it changing:
/// - preferences (profile, rules, temporary and destination rules, blocklist and exceptions, ask and allow-Apple, the
///   updater and sync pauses, limits, budget modes and cycles, data packs, network costs), edited here, by the CLI, a
///   Focus filter, a profile schedule or a hotspot switching to Travel: compared every tick, a change syncs at once.
/// - the network the Mac is on (`networkKey`): compared every tick, a change syncs at once.
/// - metered (the path's cost, the network's cost setting, a data pack): compared every tick, a change syncs at once.
/// - a temporary rule's expiry: the tick that passes it syncs (the filter also compares the time itself).
/// - budget reached and app limits reached, which move as bytes are counted and when a cycle or pack rolls over:
///   worked out on every sync above, and otherwise at most `budgetCheckEvery` seconds apart.
/// - the filter turning on (or starting to install): the tick that sees it syncs.
/// - the kill switch and Protection: not here; their `didSet` in `FilterController` saves them at once.
public struct PolicySyncSchedule {
    /// How long a budget or app limit can be reached before the filter hears of it, when nothing else changed. Bytes
    /// are sampled, so a limit is already enforced a little late; this bounds how much later.
    public static let budgetCheckEvery: TimeInterval = 5

    /// What is compared every tick: cheap to read, unlike the budget and app limits.
    public struct Inputs: Equatable {
        public var preferences: SavedPreferences
        public var network: String
        public var metered: Bool
        public init(preferences: SavedPreferences, network: String, metered: Bool) {
            self.preferences = preferences; self.network = network; self.metered = metered
        }
    }

    private var wanted = false
    private var last: Inputs?
    private var lastSync: Date?

    public init() {}

    /// Whether to work everything out and sync now. `inputs` is read only while a filter wants a policy.
    public mutating func due(filterWantsPolicy: Bool, inputs: () -> Inputs, now: Date = Date()) -> Bool {
        guard filterWantsPolicy else { wanted = false; last = nil; lastSync = nil; return false }
        let current = inputs()
        let became = !wanted, changed = current != last
        let expired = lastSync.map { Self.temporaryExpired(current.preferences, after: $0, upTo: now) } ?? false
        // A clock set back makes the interval negative; that counts as due rather than as "not yet".
        let stale = lastSync.map { !(0..<Self.budgetCheckEvery).contains(now.timeIntervalSince($0)) } ?? true
        wanted = true; last = current
        guard became || changed || expired || stale else { return false }
        lastSync = now
        return true
    }

    /// A temporary rule of the current profile ran out in (after, upTo].
    static func temporaryExpired(_ preferences: SavedPreferences, after: Date, upTo now: Date) -> Bool {
        let prefix = preferences.profile.rawValue + "|"
        return (preferences.temporaryRules ?? [:]).contains { $0.key.hasPrefix(prefix) && $0.value.expires > after && $0.value.expires <= now }
    }
}
