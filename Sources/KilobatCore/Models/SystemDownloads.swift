import Foundation

/// macOS services that download for apps and for the system. nettop sees only the service; the network filter
/// also sees the app a connection was made for, so with filtering on Kilobat can say "nsurlsessiond for Music".
public enum SystemDownloads {
    public struct Service: Sendable, Equatable {
        public let process: String
        /// The signing identifier the filter reports for it.
        public let identifier: String
        public let detail: String
    }

    public static let services: [Service] = [
        Service(process: "nsurlsessiond", identifier: "com.apple.nsurlsessiond", detail: String(localized: "Background transfers apps hand to macOS: podcasts, music, app content.")),
        Service(process: "mobileassetd", identifier: "com.apple.mobileassetd", detail: String(localized: "System assets such as Apple Intelligence and Siri models, voices, fonts and dictionaries.")),
        Service(process: "com.apple.MobileAsset.DownloadService.Builtin", identifier: "com.apple.MobileAsset.DownloadService.Builtin", detail: String(localized: "Downloads system assets for mobileassetd.")),
        Service(process: "softwareupdated", identifier: "com.apple.softwareupdated", detail: String(localized: "macOS updates and Rapid Security Responses.")),
        Service(process: "appstored", identifier: "com.apple.appstored", detail: String(localized: "App Store downloads and app updates.")),
        Service(process: "appstoreagent", identifier: "com.apple.appstoreagent", detail: String(localized: "App Store downloads and app updates.")),
        Service(process: "storedownloadd", identifier: "com.apple.storedownloadd", detail: String(localized: "App Store downloads and app updates.")),
        Service(process: "cloudd", identifier: "com.apple.cloudd", detail: String(localized: "iCloud sync for apps that use CloudKit.")),
        Service(process: "bird", identifier: "com.apple.bird", detail: String(localized: "iCloud Drive file sync.")),
        Service(process: "fileproviderd", identifier: "com.apple.fileproviderd", detail: String(localized: "Files for cloud storage apps built on File Provider.")),
        Service(process: "AssetCache", identifier: "com.apple.AssetCache", detail: String(localized: "Content Caching: Apple downloads kept for other devices on this network."))
    ]

    /// The service an app row is, by its `process:` id or its name.
    public static func service(for app: AppTraffic) -> Service? {
        let process = app.id.hasPrefix("process:") ? String(app.id.dropFirst(8)) : app.name
        return services.first { $0.process == process || $0.identifier == app.id }
    }

    /// Apps the filter saw each service connect for, most recent first, by service process name.
    public static func apps(_ flows: [DelegatedFlows]) -> [String: [String]] {
        var apps: [String: [String]] = [:]
        for flow in flows.sorted(by: { $0.last > $1.last }) {
            guard let service = services.first(where: { $0.identifier == flow.process || $0.process == flow.process }) else { continue }
            if !(apps[service.process] ?? []).contains(flow.app) { apps[service.process, default: []].append(flow.app) }
        }
        return apps
    }
}

/// Command-line tools with network traffic that are neither apps nor part of macOS, such as node, python,
/// deno, bun or a Go binary under the home folder or Homebrew: shown with their path so an unknown agent stands out.
public enum CommandLineTools {
    static let systemPrefixes = ["/System/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/usr/lib/", "/bin/", "/sbin/",
                                 "/Library/Apple/", "/Library/Developer/CommandLineTools/", "/private/var/db/", "/Applications/Xcode"]

    public static func unrecognized(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains(".app/"), !path.contains(".appex/"), !path.contains(".framework/"),
              !path.contains(".xpc/"), !path.contains(".systemextension/") else { return false }
        return !systemPrefixes.contains { path.hasPrefix($0) }
    }
}
