import Foundation

/// Blocklist subscriptions as the app, `kilobat blocklists --json` and `get_blocklists` show them: each list with its
/// entries, when it last changed and was checked, and why the last check failed (the last good copy stays in use).
public struct BlocklistStatus: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let url: String
        public let on: Bool
        public let entries: Int
        /// Lines Kilobat can't use, such as Adblock rules beyond `||domain^`.
        public let skipped: Int?
        public let updated: Date?
        public let checked: Date?
        public let error: String?
    }
    public let lists: [Row]
    /// Whether the network filter that enforces them is on; nil when the app didn't say.
    public let filterActive: Bool?
    public let maximumLists: Int
    public let maximumEntriesPerList: Int
    public let maximumMegabytes: Int

    public static func make(_ preferences: SavedPreferences, state: ProtectionState, filterActive: Bool?) -> BlocklistStatus {
        let rows = (preferences.blocklistSubscriptions ?? []).map { subscription in
            let entry = state.lists[subscription.id]
            return Row(id: subscription.id, name: subscription.name, url: subscription.url, on: subscription.on, entries: entry?.entries ?? 0,
                       skipped: entry?.skipped, updated: entry?.updated, checked: entry?.checked, error: entry?.error)
        }
        return BlocklistStatus(lists: rows, filterActive: filterActive, maximumLists: BlocklistSubscription.maximumCount,
                               maximumEntriesPerList: BlocklistSubscription.maximumEntries, maximumMegabytes: BlocklistSubscription.maximumBytes >> 20)
    }

    /// One list's state in words: "48,213 domains · updated 2 h ago", or the error with the copy kept.
    public static func detail(_ row: Row, now: Date = Date()) -> String {
        if !row.on { return String(localized: "Off", comment: "Blocklist subscription: turned off") }
        let entries = row.entries.formatted()
        if let error = row.error {
            return row.entries > 0 ? String(localized: "Kept the last good copy (\(entries) entries). \(error)", comment: "Blocklist subscription: the update failed")
                                   : String(localized: "Couldn’t download: \(error)", comment: "Blocklist subscription: the first download failed")
        }
        guard let updated = row.updated else { return String(localized: "Downloads when the network filter is on", comment: "Blocklist subscription: not downloaded yet") }
        let when = updated.formatted(.relative(presentation: .named))
        return String(localized: "\(entries) entries · updated \(when)", comment: "Blocklist subscription, e.g. 48,213 entries · updated 2 hours ago")
    }
}
