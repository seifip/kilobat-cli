import Foundation

/// Rank command titles ahead of aliases and descriptions while requiring every query term to match.
public struct CommandSearch {
    private let title: [String]
    private let aliases: [String]
    private let detail: [String]

    public init(title: String, aliases: [String], detail: String) {
        self.title = Self.words(title)
        self.aliases = aliases.flatMap(Self.words)
        self.detail = Self.words(detail)
    }

    public static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    public func rank(_ query: String) -> Int? {
        let terms = Self.words(query)
        func contains(_ term: String, in words: [String]) -> Bool {
            words.contains(where: { $0.hasPrefix(term) }) ||
                zip(words, words.dropFirst()).contains(where: { ($0 + $1).hasPrefix(term) })
        }
        if terms == title { return 0 }
        var score = 1
        for term in terms {
            if title.contains(term) { continue }
            if contains(term, in: title) { score += 1 }
            else if contains(term, in: aliases) { score += 3 }
            else if contains(term, in: detail) { score += 5 }
            else if (title + aliases + detail).contains(where: { $0.contains(term) }) { score += 8 }
            else { return nil }
        }
        return score
    }
}
