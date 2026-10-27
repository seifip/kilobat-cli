import Foundation

public struct AppTrafficGroup: Identifiable {
    public let id: String
    public var members: [AppTraffic]
    public var summary: AppTraffic

    public static func make(_ apps: [AppTraffic], grouped: Bool) -> [AppTrafficGroup] {
        let buckets = Dictionary(grouping: apps) { app in
            grouped ? (app.ownerPath ?? app.bundlePath.flatMap(ProcessOwnership.outerApplication)).map { "owner:" + $0 } ?? app.id : app.id
        }
        return buckets.map { key, members in
            let path = key.hasPrefix("owner:") ? String(key.dropFirst(6)) : nil
            let name = path.map { Bundle(path: $0)?.object(forInfoDictionaryKey: "CFBundleName") as? String ?? URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? members[0].name
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
