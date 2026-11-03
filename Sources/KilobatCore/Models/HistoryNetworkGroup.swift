import Foundation

/// A display-name filter for history. Stored network identities and their usage remain separate.
public struct HistoryNetworkGroup: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let keys: Set<String>

    public static func groups(_ sessions: [String: NetworkSession]) -> [Self] {
        Dictionary(grouping: sessions.keys, by: { sessions[$0]!.name })
            .map { Self(name: $0.key, keys: Set($0.value)) }
            .sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
            }
    }
}
