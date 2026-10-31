import Foundation

/// The VPN kill switch as the app works it out from the setting, the license, the filter and the VPN. The filter only
/// enforces what `policy` says (`KillSwitchPolicy`); this is where arming, pausing and the words come from.
///
/// It arms the first time the VPN carries all traffic after the setting is on, and stays armed until the Mac restarts
/// or the setting goes off, across network changes: joining a new café network before the VPN reconnects is exactly
/// when apps would leak. Turning it on with no VPN running therefore never cuts the Mac off.
public struct KillSwitchState: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        /// The setting is off.
        case off
        /// On, but Kilobat Pro isn't active, so nothing is enforced.
        case needsPro
        /// On, but the network filter is off, so nothing can be blocked.
        case needsFilter
        /// On, waiting to see the VPN carry all traffic once before it arms.
        case waiting
        /// Armed, and the VPN carries all traffic.
        case protected
        /// Armed, the VPN is down, new connections are blocked.
        case blocking
        /// Armed and the VPN is down, but the person allowed traffic for a few minutes.
        case allowed
    }

    public var status: Status
    public var enabled: Bool
    public var allowLAN: Bool
    public var armed: Bool
    /// The default route goes through a tunnel.
    public var vpnUp: Bool
    /// The VPN's name when macOS lists exactly one connected.
    public var vpnName: String?
    /// The tunnel interface carrying the default route, such as utun4.
    public var tunnel: String?
    public var allowedUntil: Date?
    public var filterActive: Bool

    /// How long "Allow for 5 minutes" lets traffic through.
    public static let allowMinutes = 5

    public init(status: Status, enabled: Bool, allowLAN: Bool = true, armed: Bool = false, vpnUp: Bool = false, vpnName: String? = nil, tunnel: String? = nil,
                allowedUntil: Date? = nil, filterActive: Bool = false) {
        self.status = status; self.enabled = enabled; self.allowLAN = allowLAN; self.armed = armed; self.vpnUp = vpnUp; self.vpnName = vpnName
        self.tunnel = tunnel; self.allowedUntil = allowedUntil; self.filterActive = filterActive
    }

    /// Whether the setting is on; stored as nil while off.
    public static func enabled(_ preferences: SavedPreferences) -> Bool { preferences.killSwitch == true }
    public static func allowLAN(_ preferences: SavedPreferences) -> Bool { preferences.killSwitchLAN != false }

    /// The state for this moment. `armed` comes from `arm`; `exit` is the latest reading of the route and VPN list.
    public static func evaluate(_ preferences: SavedPreferences, pro: Bool, filterActive: Bool, exit: ExitPath, armed: Bool, now: Date = Date()) -> KillSwitchState {
        let enabled = enabled(preferences), vpnUp = exit.vpn == .full
        let until = preferences.killSwitchAllowedUntil.flatMap { $0 > now ? $0 : nil }
        let status: Status = !enabled ? .off : !pro ? .needsPro : !filterActive ? .needsFilter : !armed ? .waiting
            : vpnUp ? .protected : until != nil ? .allowed : .blocking
        return KillSwitchState(status: status, enabled: enabled, allowLAN: allowLAN(preferences), armed: armed && enabled && pro, vpnUp: vpnUp,
                               vpnName: exit.vpnName, tunnel: vpnUp ? exit.interface : nil, allowedUntil: status == .allowed ? until : nil, filterActive: filterActive)
    }

    /// The boot the kill switch was armed on, after this reading: it arms when the VPN carries all traffic with the
    /// setting on, stays armed for the rest of that boot, and is forgotten when the setting goes off or the Mac restarts.
    public static func arm(armedBoot: Double?, boot: Double, enabled: Bool, vpnUp: Bool) -> Double? {
        guard enabled else { return nil }
        if armedBoot == boot { return boot }
        return vpnUp ? boot : nil
    }

    /// When this Mac booted, in seconds since 1970, which tells one boot from the next.
    public static func bootTime() -> Double {
        var time = timeval(), size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else { return 0 }
        return Double(time.tv_sec)
    }

    /// What the filter gets. Only an armed kill switch the filter can enforce carries anything.
    public func policy(vpnApps: [String] = []) -> KillSwitchPolicy {
        guard [.protected, .blocking, .allowed].contains(status) else { return KillSwitchPolicy() }
        return KillSwitchPolicy(armed: true, vpnDown: !vpnUp, tunnel: tunnel, allowedUntil: allowedUntil, allowLAN: allowLAN, vpnApps: vpnApps)
    }

    /// Whether new connections are being refused now.
    public var blocking: Bool { status == .blocking }

    // MARK: Words

    public var title: String {
        switch status {
        case .off: String(localized: "VPN kill switch is off")
        case .needsPro: String(localized: "VPN kill switch needs Kilobat Pro")
        case .needsFilter: String(localized: "VPN kill switch needs the network filter")
        case .waiting: String(localized: "Kill switch waiting for your VPN")
        case .protected: vpnName.map { String(localized: "Kill switch on · \($0) is up") } ?? String(localized: "Kill switch on · VPN is up")
        case .blocking: String(localized: "Blocked: VPN is down")
        case .allowed: String(localized: "Kill switch paused until \((allowedUntil ?? Date()).formatted(date: .omitted, time: .shortened))")
        }
    }

    public var detail: String {
        switch status {
        case .off: String(localized: "Blocks new connections whenever your VPN is down, so nothing leaks over café or hotel Wi-Fi.")
        case .needsPro: String(localized: "The setting is kept, but nothing is blocked without Kilobat Pro.")
        case .needsFilter: String(localized: "Nothing can be blocked while the network filter is off. Turn it on to use the kill switch.")
        case .waiting: String(localized: "It arms the first time your VPN carries all traffic, so turning it on without a VPN never cuts you off.")
        case .protected: String(localized: "If the VPN drops, Kilobat blocks new connections until it’s back.")
        case .blocking:
            allowLAN ? String(localized: "Reconnect your VPN. Until it’s back, only your VPN app, network login pages, Kilobat and the local network can connect.")
                : String(localized: "Reconnect your VPN. Until it’s back, only your VPN app, network login pages and Kilobat can connect.")
        case .allowed: String(localized: "Traffic flows without the VPN until then. If it’s still down, Kilobat blocks again.")
        }
    }

    /// For `kilobat vpn --json`, `conditions` and MCP. `state` is null when only the saved setting is known.
    public static func json(_ state: KillSwitchState?, preferences: SavedPreferences?) -> [String: Any] {
        let preferences = preferences ?? SavedPreferences()
        guard let state else {
            return ["enabled": enabled(preferences), "allowLAN": allowLAN(preferences), "state": NSNull(), "armed": NSNull(), "vpnUp": NSNull(), "allowedUntil": NSNull(),
                    "filterActive": NSNull(), "summary": enabled(preferences) ? "On. Open the Kilobat app to see whether it is armed; it watches the VPN and tells the filter." : "Off."]
        }
        return ["enabled": state.enabled, "allowLAN": state.allowLAN, "state": state.status.rawValue, "armed": state.armed, "vpnUp": state.vpnUp,
                "allowedUntil": state.allowedUntil.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(), "filterActive": state.filterActive,
                "summary": state.title + ". " + state.detail]
    }

    /// One line for `kilobat vpn` and `kilobat conditions`, from `json`.
    public static func line(_ value: [String: Any]) -> String {
        let enabled = value["enabled"] as? Bool == true
        guard let state = value["state"] as? String else { return enabled ? "on · open the Kilobat app to see whether it is armed" : "off · kilobat settings kill-switch on" }
        let words = ["off": "off · kilobat settings kill-switch on", "needsPro": "on, but it needs Kilobat Pro", "needsFilter": "on, but the network filter is off",
                     "waiting": "on · arms the first time the VPN carries all traffic", "protected": "on · armed, the VPN is up",
                     "blocking": "BLOCKING · the VPN is down; new connections wait until it’s back", "allowed": "paused"]
        var line = words[state] ?? state
        if state == "allowed", let until = (value["allowedUntil"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) }) {
            line += " until " + until.formatted(date: .omitted, time: .shortened)
        }
        if enabled, ["waiting", "protected", "blocking", "allowed"].contains(state) { line += value["allowLAN"] as? Bool == false ? " · local network blocked too" : " · local network allowed" }
        return line
    }

    /// The limits, worded the same in Settings, the CLI and the docs.
    public static let limits = String(localized: "Only new connections are blocked; ones already open keep going, though most die with the tunnel they used. If Kilobat quits, the filter keeps the last state it got and still blocks when the VPN’s tunnel goes away: open Kilobat to allow traffic or turn this off.")
}
