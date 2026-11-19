import Foundation

/// Where a Settings link lands: the names of the pages, the group anchors and old anchors, and the rule that turns an
/// anchor into its page. The app's `SettingsIndex` supplies the rows; `SettingsAnchorsTests` checks every link, search
/// row and page anchor in the app's sources against these.
public enum SettingsAnchors {
    /// The pages, in sidebar order; the app's `SettingsPage` cases carry the same names.
    public static let pages = ["general", "notifications", "filter", "protection", "data", "calls", "checks", "privacy", "pro"]
    /// Older anchors, from before Settings had pages, and the row or group each now means.
    public static let aliases = ["network": "filtergroup", "quotas": "limits"]
    /// Group anchors that aren't search rows of their own, and their page.
    public static let groups = ["menubar": "general", "filtergroup": "filter", "streaming": "calls"]

    /// The page an anchor is on: a page's own name, a group's or a row's (`rows` maps each search row's anchor to its page).
    public static func page(for anchor: String, rows: [String: String]) -> String? {
        let anchor = aliases[anchor] ?? anchor
        if pages.contains(anchor) { return anchor }
        return groups[anchor] ?? rows[anchor]
    }
}
