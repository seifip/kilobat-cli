import Foundation
import os

public struct AppTrafficGroup: Identifiable {
    public let id: String
    public var members: [AppTraffic]
    public var summary: AppTraffic

    /// Names read from disk, by path: traffic asks for them every second. An app renamed in place keeps its old name
    /// here until Kilobat relaunches.
    private static let names = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    /// The name people know an app by, for the bundle that owns a helper or service.
    public static func displayName(_ path: String) -> String {
        if let known = names.withLock({ $0[path] }) { return known }
        let name = FileManager.default.displayName(atPath: path)
        let short = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        names.withLock { if $0.count >= 1_024 { $0.removeAll() }; $0[path] = short }
        return short
    }

    /// "Claude Code" for the `claude` command-line tool, as the agent log names it, so it doesn't read as a lowercase twin
    /// of the Claude app. Desktop apps keep their bundle's name.
    static func agentName(_ app: AppTraffic) -> String? {
        guard let agent = AgentIdentifier.identify(path: app.bundlePath, name: app.name), !agent.app else { return nil }
        return agent.name
    }

    /// The group of macOS services that download for apps and the system.
    public static let systemDownloads = "system:downloads"

    public static func make(_ apps: [AppTraffic], grouped: Bool) -> [AppTrafficGroup] {
        let buckets = Dictionary(grouping: apps) { app in
            guard grouped else { return app.id }
            if SystemDownloads.service(for: app) != nil { return systemDownloads }
            let owner = app.ownerPath ?? app.bundlePath.flatMap(ProcessOwnership.outerApplication)
                ?? ProcessOwnership.helperApplication(for: app.executablePath ?? app.bundlePath)
            return owner.map { "owner:" + $0 } ?? app.id
        }
        return buckets.map { key, members in
            let path = key.hasPrefix("owner:") ? String(key.dropFirst(6)) : nil
            let name = key == systemDownloads ? String(localized: "System downloads") : path.map(displayName) ?? agentName(members[0]) ?? members[0].name
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
