import AppKit

/// VPN apps by their makers' bundle identifiers, for naming the VPN when it doesn't register with macOS's VPN list
/// (`scutil --nc list`), as NordVPN's app doesn't. Only a name for the menu: nothing is decided from it.
public enum VPNApps {
    static let prefixes = ["com.nordvpn.", "com.expressvpn.", "com.surfshark.", "net.mullvad.", "ch.protonvpn.", "ch.protonmail.vpn",
                           "com.privateinternetaccess.", "com.windscribe.", "com.cyberghost", "net.ivpn.", "com.cloudflare.1dot1dot1dot1",
                           "io.tailscale.", "com.wireguard.", "net.tunnelblick.", "com.viscosityvpn.", "org.openvpn.", "com.cisco.anyconnect",
                           "com.cisco.secureclient", "com.paloaltonetworks.GlobalProtect", "com.fortinet."]

    public static func isVPN(_ bundleID: String?) -> Bool { bundleID.map { id in prefixes.contains { id.hasPrefix($0) } } == true }

    /// Bundle identifiers macOS lists as a VPN service that is disconnected, such as Tailscale while it's off.
    public static func disconnected(_ scutil: String) -> Set<String> {
        Set(scutil.split(separator: "\n").compactMap { line in
            guard line.contains("(Disconnected)") else { return nil }
            return DiagnosticProbe.matches(#"\[VPN:([^\]]+)\]"#, in: String(line)).first
        })
    }

    /// The one running VPN app, by name, leaving out any macOS says is disconnected; nil when none or several run.
    @MainActor public static func running(disconnected: Set<String> = [], apps: [NSRunningApplication] = NSWorkspace.shared.runningApplications) -> String? {
        var names: [String: String] = [:]
        for app in apps {
            guard let id = app.bundleIdentifier, isVPN(id), !disconnected.contains(where: { id.hasPrefix($0) || $0.hasPrefix(id) }) else { continue }
            // One app often runs several processes (menu-bar agent, helper); they count once, by maker.
            let maker = prefixes.first { id.hasPrefix($0) } ?? id
            let name = app.localizedName ?? id
            if names[maker] == nil || name.count < names[maker]!.count { names[maker] = name }
        }
        return names.count == 1 ? names.values.first : nil
    }
}
