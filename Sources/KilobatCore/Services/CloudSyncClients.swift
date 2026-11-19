import Foundation

/// Cloud storage clients the filter pauses on a metered network: their connections are refused while the network costs
/// data, and they sync again on their own the moment it doesn't. Nothing in the apps is changed, so there is nothing to
/// restore. iCloud Drive and iCloud Photos sync through macOS's own services, which also carry Messages, Keychain and
/// Find My, so they can't be paused this way. Compiled into the filter too, so it uses Foundation only.
public enum CloudSyncClients {
    public struct Client: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        /// Signing identifier prefixes: the app, its File Provider extension and its helpers share one.
        public let identifierPrefixes: [String]
        /// Executable names, for processes without a bundle (`process:<name>`) and as the filter sees them.
        public let processes: [String]
    }

    /// The reason the filter records, and the journal shows, for a paused sync client's connection.
    public static let reason = "Cloud sync paused on a metered network"

    public static let clients: [Client] = [
        Client(id: "dropbox", name: "Dropbox", identifierPrefixes: ["com.getdropbox.dropbox"], processes: ["Dropbox"]),
        Client(id: "google-drive", name: "Google Drive", identifierPrefixes: ["com.google.drivefs"], processes: ["Google Drive", "DFSFileProviderExtension"]),
        Client(id: "onedrive", name: "OneDrive", identifierPrefixes: ["com.microsoft.OneDrive"], processes: ["OneDrive", "OneDrive File Provider"]),
        Client(id: "box", name: "Box Drive", identifierPrefixes: ["com.box.desktop"], processes: []),
        Client(id: "mega", name: "MEGA", identifierPrefixes: ["mega.mac"], processes: ["MEGAsync", "MEGAclient"]),
        Client(id: "proton-drive", name: "Proton Drive", identifierPrefixes: ["ch.protonmail.drive"], processes: ["Proton Drive"]),
        Client(id: "nextcloud", name: "Nextcloud", identifierPrefixes: ["com.nextcloud.desktopclient"], processes: ["Nextcloud"]),
        Client(id: "backblaze", name: "Backblaze", identifierPrefixes: ["com.backblaze."], processes: ["bztransmit", "bzserv"]),
    ]

    /// The client an app is: by signing identifier, by `process:<name>`, or by the executable name the filter reports.
    public static func client(_ app: String?, process: String? = nil) -> Client? {
        guard let app, !app.isEmpty else { return nil }
        if app.hasPrefix("process:") {
            let name = String(app.dropFirst(8))
            return clients.first { $0.processes.contains(name) }
        }
        return clients.first { client in
            client.identifierPrefixes.contains(where: app.hasPrefix) || process.map { !$0.isEmpty && client.processes.contains($0) } == true
        }
    }
}
