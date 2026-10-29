import Foundation

public struct AppTrafficGroup: Identifiable {
    public let id: String
    public var members: [AppTraffic]
    public var summary: AppTraffic

    /// The name people know an app by, for the bundle that owns a helper or service.
    public static func displayName(_ path: String) -> String {
        let name = FileManager.default.displayName(atPath: path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    public static func make(_ apps: [AppTraffic], grouped: Bool) -> [AppTrafficGroup] {
        let buckets = Dictionary(grouping: apps) { app in
            grouped ? (app.ownerPath ?? app.bundlePath.flatMap(ProcessOwnership.outerApplication)).map { "owner:" + $0 } ?? app.id : app.id
        }
        return buckets.map { key, members in
            let path = key.hasPrefix("owner:") ? String(key.dropFirst(6)) : nil
            let name = path.map(displayName) ?? members[0].name
            var summary = AppTraffic(id: key, name: name, bundlePath: path ?? members[0].bundlePath)
            for member in members {
                summary.received += member.received; summary.sent += member.sent
                summary.downloadRate += member.downloadRate; summary.uploadRate += member.uploadRate
                summary.processIDs += member.processIDs
            }
            summary.processIDs = Array(Set(summary.processIDs)).sorted()
            return AppTrafficGroup(id: key, members: members, summary: summary)
        }
    }
}
