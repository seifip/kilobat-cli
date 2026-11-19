import Foundation

/// What a confirmation for several things at once names: the first few, and how many it left out.
public enum ConfirmationSummary {
    /// Distinct, non-empty names in their given order, at most `limit`, and the count of distinct names beyond them.
    public static func names(_ all: [String], limit: Int = 4) -> (shown: [String], more: Int) {
        var seen = Set<String>(), distinct: [String] = []
        for name in all.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !name.isEmpty && seen.insert(name).inserted { distinct.append(name) }
        let shown = Array(distinct.prefix(max(0, limit)))
        return (shown, distinct.count - shown.count)
    }
    /// "Cursor, Slack, Zoom" or, with some left out, "Cursor, Slack, Zoom, Xcode, …" — joined the way the locale lists things.
    public static func list(_ all: [String], limit: Int = 4, locale: Locale = .current) -> String {
        let (shown, more) = names(all, limit: limit)
        let formatter = ListFormatter(); formatter.locale = locale
        let joined = more > 0 ? shown.joined(separator: ", ") + ", …" : (formatter.string(from: shown) ?? shown.joined(separator: ", "))
        return joined
    }
}
