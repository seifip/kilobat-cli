import AppKit

/// Keeps the Mac awake only while one app is in front, for reading or presenting. It holds its own assertion,
/// apart from awake sessions and agent runs, so the app losing focus or quitting ends nothing else.
public struct FrontmostCondition: Codable, Equatable, Sendable {
    /// The app's bundle ID.
    public let app: String
    public let name: String
    /// Keep the display on too; otherwise only idle sleep is held and the screen may dim.
    public let display: Bool
    /// Ends the condition even while the app is in front.
    public let until: Date?
    public init(app: String, name: String, display: Bool, until: Date? = nil) {
        self.app = app; self.name = name; self.display = display; self.until = until
    }
    public var title: String { String(localized: "While \(name) is in front") }
}

/// Which app came to the front and which quit, from the workspace's own activation events. No polling,
/// and nothing that simulates input or presence.
@MainActor public final class FrontmostWatcher {
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    public init(activated: @escaping @MainActor @Sendable (String?) -> Void, terminated: @escaping @MainActor @Sendable (String?) -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let id = Self.bundle(note)
            Task { @MainActor in activated(id) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            let id = Self.bundle(note)
            Task { @MainActor in terminated(id) }
        })
    }
    deinit { observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver) }
    private nonisolated static func bundle(_ note: Notification) -> String? { (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier }

    /// The bundle ID of the app in front now.
    public static var current: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

    /// Apps with a window that could come to the front, by name; Kilobat itself left out.
    public static func apps() -> [(id: String, name: String, path: String?)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() && $0.bundleIdentifier != nil && $0.localizedName != nil }
            .map { ($0.bundleIdentifier!, $0.localizedName!, $0.bundleURL?.path) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A bundle ID, or an app's name as running or as installed in the usual folders: Keynote, "Google Chrome".
    public static func resolve(_ text: String) -> (id: String, name: String)? {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }
        if let app = apps().first(where: { $0.id.caseInsensitiveCompare(query) == .orderedSame || $0.name.caseInsensitiveCompare(query) == .orderedSame }) { return (app.id, app.name) }
        if query.contains("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) { return (query, FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")) }
        let name = query.hasSuffix(".app") ? String(query.dropLast(4)) : query
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        for folder in folders {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(name + ".app")
            if let id = Bundle(url: url)?.bundleIdentifier { return (id, name) }
        }
        return nil
    }
}
