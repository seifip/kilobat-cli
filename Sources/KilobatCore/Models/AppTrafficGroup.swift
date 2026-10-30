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

    /// The group of macOS services that download for apps and the system.
    public static let systemDownloads = "system:downloads"

    public static func make(_ apps: [AppTraffic], grouped: Bool) -> [AppTrafficGroup] {
        let buckets = Dictionary(grouping: apps) { app in
            guard grouped else { return app.id }
            if SystemDownloads.service(for: app) != nil { return systemDownloads }
            return (app.ownerPath ?? app.bundlePath.flatMap(ProcessOwnership.outerApplication)).map { "owner:" + $0 } ?? app.id
        }
        return buckets.map { key, members in
            let path = key.hasPrefix("owner:") ? String(key.dropFirst(6)) : nil
            let name = key == systemDownloads ? String(localized: "System downloads") : path.map(displayName) ?? members[0].name
            var summary = AppTraffic(id: key, name: name, bundlePath: path ?? (key == systemDownloads ? nil : members[0].bundlePath))
            for member in members {
                summary.received += member.received; summary.sent += member.sent
                summary.local += member.local; summary.tunnel += member.tunnel
                summary.downloadRate += member.downloadRate; summary.uploadRate += member.uploadRate
                summary.processIDs += member.processIDs
                summary.rates.merge(member.rates) { $1 }
            }
            summary.processIDs = Array(Set(summary.processIDs)).sorted()
            return AppTrafficGroup(id: key, members: members, summary: summary)
        }
    }
}
