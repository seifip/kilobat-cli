import Foundation

/// Pausing updaters on metered networks: the filter blocks the helpers in `UpdaterHelpers` with an ordinary rule while
/// the network costs data, and lets them through again the moment it doesn't. Nothing in another app or in macOS is
/// changed, so there is nothing to restore. Apps that download their own updates can't be told apart from the app.
public enum UpdaterPause {
    /// The setting; on unless turned off.
    public static func enabled(_ preferences: SavedPreferences) -> Bool { preferences.pauseUpdaters != false }
    /// Whether the filter pauses updaters now: on a metered network with the setting on, or while a Focus filter asks
    /// to on any network. Unrestricted allows every connection, so it never does.
    public static func active(_ preferences: SavedPreferences, metered: Bool) -> Bool {
        (enabled(preferences) && metered || preferences.focusPausesUpdaters == true) && preferences.profile != .unrestricted
    }

    /// An installed app whose updater runs inside the app's own process, so pausing it would mean blocking the app.
    public struct InProcessApp: Codable, Equatable, Sendable {
        public let name: String
        public let path: String
        /// Sparkle or Squirrel.
        public let updater: String
        public init(name: String, path: String, updater: String) { self.name = name; self.path = path; self.updater = updater }
    }

    /// Squirrel (Electron) apps download in the app and hand ShipIt only the install. Sparkle apps do the same unless
    /// they turn on Sparkle's download service (`SUEnableDownloaderService`), which runs apart and can be paused.
    public static func inProcess(_ app: URL) -> InProcessApp? {
        let frameworks = app.appendingPathComponent("Contents/Frameworks"), files = FileManager.default
        let name = AppTrafficGroup.displayName(app.path)
        if files.fileExists(atPath: frameworks.appendingPathComponent("Squirrel.framework").path) { return InProcessApp(name: name, path: app.path, updater: "Squirrel") }
        guard files.fileExists(atPath: frameworks.appendingPathComponent("Sparkle.framework").path) else { return nil }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        // Kilobat holds its own scheduled check on metered networks, so it isn't one that can't be paused.
        if info?["SUEnableDownloaderService"] as? Bool == true || info?["CFBundleIdentifier"] as? String == "co.seifi.kilobat" { return nil }
        return InProcessApp(name: name, path: app.path, updater: "Sparkle")
    }

    /// Apps in these folders, and one folder down (such as Utilities), that update from inside their own process.
    public static func inProcessApps(in folders: [URL] = [URL(fileURLWithPath: "/Applications"),
                                                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]) -> [InProcessApp] {
        let files = FileManager.default
        func children(_ folder: URL) -> [URL] { (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] }
        var apps: [URL] = []
        for folder in folders {
            for item in children(folder) {
                if item.pathExtension == "app" { apps.append(item) } else { apps += children(item).filter { $0.pathExtension == "app" } }
            }
        }
        return apps.compactMap(inProcess).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public struct Report: Codable, Equatable, Sendable {
        public struct Covered: Codable, Equatable, Sendable {
            public let id: String
            public let name: String
            public let detail: String
            /// False for installers that only apply what their app already downloaded.
            public let downloads: Bool
        }
        /// Update bytes on the current network: an updater's own, or a System downloads service's that connected for one.
        public struct Through: Codable, Equatable, Sendable {
            public let name: String
            public let bytes: UInt64
            /// A System downloads service such as nsurlsessiond: its bytes include downloads for other apps.
            public let shared: Bool
            /// The updaters a shared service connected for.
            public let forUpdaters: [String]
        }
        /// The setting.
        public var enabled: Bool
        public var metered: Bool
        /// Whether the filter's policy pauses updaters now.
        public var paused: Bool
        /// Nil when the app isn't running to say.
        public var filterActive: Bool?
        public var covered: [Covered]
        /// Nil without the running app, which counts each process's bytes.
        public var gotThrough: [Through]?
        /// Updater connections the filter stopped in the last 24 hours.
        public var pausedConnections: Int
        public var inProcess: [InProcessApp]
        public var summary: String
        public var limits: String
    }

    public static let limits = String(localized: "The filter stops new connections, so a download already running when the network became metered can finish. Apps that download updates inside their own process can't be paused without blocking the app; bytes macOS services move for several apps at once can't be split.")

    public static func report(_ preferences: SavedPreferences, metered: Bool, filterActive: Bool?, apps: [AppTraffic]?, delegations: [DelegatedFlows],
                              events: [FilterEvent], inProcess: [InProcessApp], now: Date = Date()) -> Report {
        let enabled = enabled(preferences), paused = active(preferences, metered: metered)
        let summary: String = if paused, preferences.focusPausesUpdaters == true, filterActive != false {
                String(localized: "Paused by your Focus: updaters can’t start new connections until the Focus ends.") }
            else if !enabled { String(localized: "Off: updaters run on every network.") }
            else if !metered { String(localized: "On: updaters wait while this Mac is on a metered network. This one isn’t metered, so they run.") }
            else if !paused { String(localized: "This network is metered, but the Unrestricted profile allows every connection, so updaters aren’t paused.") }
            else if filterActive == false { String(localized: "This network is metered, but the network filter is off, so updaters aren’t paused.") }
            else if filterActive == nil { String(localized: "This network is metered: updaters are paused while the Kilobat app’s network filter is on.") }
            else { String(localized: "Paused: updaters can’t start new connections until this Mac leaves the metered network.") }
        let covered = UpdaterHelpers.helpers.map { Report.Covered(id: $0.id, name: $0.name, detail: $0.detail, downloads: $0.downloads) }
        let paused24h = events.filter { $0.reason == UpdaterHelpers.reason && now.timeIntervalSince($0.date) < 86_400 }.count
        return Report(enabled: enabled, metered: metered, paused: paused, filterActive: filterActive, covered: covered,
                      gotThrough: apps.map { through($0, delegations: delegations) }, pausedConnections: paused24h, inProcess: inProcess,
                      summary: summary, limits: limits)
    }

    /// Updaters' own bytes by updater, then System downloads services that connected for an updater, largest first.
    static func through(_ apps: [AppTraffic], delegations: [DelegatedFlows]) -> [Report.Through] {
        var own: [String: UInt64] = [:], shared: [Report.Through] = []
        let servedFor = SystemDownloads.apps(delegations)
        for app in apps where app.internet > 0 {
            if let helper = UpdaterHelpers.helper(app.id) { own[helper.name, default: 0] += app.internet; continue }
            guard let service = SystemDownloads.service(for: app) else { continue }
            var updaters: [String] = []
            for name in (servedFor[service.process] ?? []).compactMap({ UpdaterHelpers.helper($0)?.name }) where !updaters.contains(name) { updaters.append(name) }
            if !updaters.isEmpty { shared.append(.init(name: service.process, bytes: app.internet, shared: true, forUpdaters: updaters)) }
        }
        return (own.map { Report.Through(name: $0.key, bytes: $0.value, shared: false, forUpdaters: []) } + shared)
            .sorted { $0.bytes == $1.bytes ? $0.name < $1.name : $0.bytes > $1.bytes }
    }
}
