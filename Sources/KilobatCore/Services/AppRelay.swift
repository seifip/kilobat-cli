import AppKit
import Foundation

/// Lets the CLI read what only the running app can see. macOS hides Wi-Fi names from processes
/// without Location permission, and the filter state lives in the app, so the CLI asks the app.
/// A request carries a whitelisted action name and a reply ID; the few actions that take arguments check them.
public enum AppRelay {
    public static let appBundleID = "co.seifi.kilobat"
    public static let actions: Set<String> = ["scan", "connection", "approvals", "decide", "agent", "bluetooth", "lid", "updaters", "power", "uploads"]
    /// An action may carry arguments after a `|`, such as `decide|allow|com.example.App`.
    static func known(_ action: String) -> Bool { actions.contains(String(action.prefix { $0 != "|" })) }
    static let request = Notification.Name("co.seifi.kilobat.relay.request")
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat/relay")
    }

    public static var appRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID).isEmpty }

    /// Asks the running app and waits for its reply. Returns nil when the app is not running or does not answer in time.
    public static func ask(_ action: String, timeout: Duration = .seconds(8)) async -> Data? {
        guard known(action), appRunning else { return nil }
        let id = UUID().uuidString, reply = directory.appendingPathComponent(id + ".json")
        DistributedNotificationCenter.default().postNotificationName(request, object: action + ":" + id, userInfo: nil, deliverImmediately: true)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: reply) {
                try? FileManager.default.removeItem(at: reply)
                return data
            }
            // Agent hooks wait for this, so the reply is checked often.
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    /// App side: answers requests with `handler`, which returns JSON for an action.
    @MainActor public static func serve(_ handler: @escaping @MainActor (String) async -> Data?) -> NSObjectProtocol {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Replies the CLI gave up on.
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] { try? FileManager.default.removeItem(at: file) }
        return DistributedNotificationCenter.default().addObserver(forName: request, object: nil, queue: .main) { note in
            // The request id comes last: an action's arguments may themselves contain colons (process:name).
            guard let object = note.object as? String, let colon = object.lastIndex(of: ":"),
                  case let action = String(object[..<colon]), known(action),
                  let id = UUID(uuidString: String(object[object.index(after: colon)...])) else { return }
            Task { @MainActor in
                guard let data = await handler(action) else { return }
                let file = directory.appendingPathComponent(id.uuidString + ".json")
                try? data.write(to: file, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
    }
}
