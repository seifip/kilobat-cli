import Foundation

/// Update helpers that run as their own processes, so the filter can pause them on a metered network while the apps
/// they update keep working. Identifiers and executable names are the ones `codesign -dv` shows on installed copies
/// (October 2026). Compiled into the filter too, so it uses Foundation only.
public enum UpdaterHelpers {
    public struct Helper: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let detail: String
        /// Whether it downloads updates itself. Sparkle's and Squirrel's installers apply what the app already downloaded.
        public let downloads: Bool
        /// Signing identifiers, matched exactly.
        public let identifiers: [String]
        /// Identifier prefixes: some apps sign Sparkle's Autoupdate as "Autoupdate-<hash>".
        public let identifierPrefixes: [String]
        /// Executable names, for processes without a bundle (`process:<name>`) and as the filter sees them.
        public let processes: [String]
    }

    /// The reason the filter records, and the journal shows, for a paused updater's connection.
    public static let reason = "Updater paused on a metered network"

    public static let helpers: [Helper] = [
        Helper(id: "google", name: "Google Updater", detail: String(localized: "Updates Chrome and other Google apps, including the older Keystone agent."), downloads: true,
               identifiers: ["com.google.GoogleUpdater", "com.google.Keystone", "com.google.Keystone.Agent"], identifierPrefixes: [],
               processes: ["GoogleUpdater", "GoogleSoftwareUpdate", "GoogleSoftwareUpdateAgent"]),
        Helper(id: "microsoft", name: "Microsoft AutoUpdate", detail: String(localized: "Updates Office, Teams and other Microsoft apps."), downloads: true,
               identifiers: ["com.microsoft.autoupdate2", "com.microsoft.autoupdate.fba", "com.microsoft.autoupdate.cli"], identifierPrefixes: [],
               processes: ["Microsoft AutoUpdate", "Microsoft Update Assistant", "msupdate"]),
        Helper(id: "macos", name: "macOS Software Update", detail: String(localized: "macOS updates and Rapid Security Responses."), downloads: true,
               identifiers: ["com.apple.softwareupdated"], identifierPrefixes: [], processes: ["softwareupdated"]),
        Helper(id: "app-store", name: "App Store downloads", detail: String(localized: "App Store app updates and downloads; the App Store app itself still opens."), downloads: true,
               identifiers: ["com.apple.appstored", "com.apple.appstoreagent", "com.apple.storedownloadd"], identifierPrefixes: [],
               processes: ["appstored", "appstoreagent", "storedownloadd"]),
        Helper(id: "sparkle-downloader", name: "Sparkle downloader", detail: String(localized: "Downloads updates for sandboxed apps that hand them to Sparkle’s download service."), downloads: true,
               identifiers: ["org.sparkle-project.DownloaderService", "org.sparkle-project.Downloader"], identifierPrefixes: [], processes: []),
        Helper(id: "sparkle", name: "Sparkle installer", detail: String(localized: "Autoupdate and Updater.app install and relaunch apps that use Sparkle, after the app downloaded the update."), downloads: false,
               identifiers: ["Autoupdate", "org.sparkle-project.Sparkle.Updater"], identifierPrefixes: ["Autoupdate-"], processes: ["Autoupdate"]),
        Helper(id: "squirrel", name: "Squirrel ShipIt", detail: String(localized: "Installs updates for Electron apps after the app downloaded them."), downloads: false,
               identifiers: ["ShipIt"], identifierPrefixes: [], processes: ["ShipIt"]),
    ]

    /// The helper an app is: by signing identifier, by `process:<name>`, or by the executable name the filter reports.
    public static func helper(_ app: String?, process: String? = nil) -> Helper? {
        guard let app, !app.isEmpty else { return nil }
        if app.hasPrefix("process:") {
            let name = String(app.dropFirst(8))
            return helpers.first { $0.processes.contains(name) }
        }
        return helpers.first { helper in
            helper.identifiers.contains(app) || helper.identifierPrefixes.contains(where: app.hasPrefix)
                || process.map { !$0.isEmpty && helper.processes.contains($0) } == true
        }
    }
}
