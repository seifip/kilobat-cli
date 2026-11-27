import Foundation
import SystemConfiguration

/// Tells when the default route or a VPN tunnel changes, the moment macOS records it, so the connection status doesn't
/// wait for the next periodic check.
public final class RouteWatch: @unchecked Sendable {
    private var store: SCDynamicStore?
    private let onChange: @Sendable () -> Void
    private let keys: [String], patterns: [String]
    /// The system proxy's key, for a watcher that only cares when the proxy settings change.
    public static let proxyKeys = ["State:/Network/Global/Proxies"]
    public init(keys: [String] = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"],
                // A tunnel's own address changes when a VPN moves to another server, with the default route staying on it.
                patterns: [String] = ["State:/Network/Interface/(utun|ipsec|ppp)[0-9]+/IPv4"],
                onChange: @escaping @Sendable () -> Void) { self.keys = keys; self.patterns = patterns; self.onChange = onChange }

    var monitoring: Bool { store != nil }
    public func start() {
        guard store == nil else { return }
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<RouteWatch>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let created = SCDynamicStoreCreate(nil, "Kilobat route watch" as CFString, callback, &context) else { return }
        guard SCDynamicStoreSetNotificationKeys(created, keys as CFArray, patterns as CFArray), SCDynamicStoreSetDispatchQueue(created, .main) else { return }
        store = created
    }
}
