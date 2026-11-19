import Foundation

/// macOS's Local Network permission, for a connection to a device on this network, as the connection check judges it.
/// Kilobat can't read another app's permission. What it can see: whether its own connection to the same address works,
/// whether macOS held its own connection back for want of the permission (the path's unsatisfied reason, TN3179), and
/// the error the app got. A denied app's connection to a local address fails at once with "No route to host"
/// (EHOSTUNREACH), where a device that's really unreachable makes the connection wait and time out.
public enum LocalNetworkCheck {
    public enum Finding: Equatable, Sendable {
        /// This process itself is held back: Kilobat, or the app the CLI or MCP server runs in.
        case selfDenied(address: String, proven: Bool)
        /// Kilobat connects; the app got "No route to host".
        case appSuspect(address: String)
        /// Kilobat connects and the app has nothing open there: if it fails at once, this is where to look.
        case appHint(address: String)
    }

    /// A local network address in TN3179's sense, near enough: private IPv4 on Wi-Fi or Ethernet, IPv4 link-local, IPv6
    /// link-local and unique local, multicast and broadcast. Not loopback, and not 100.64.0.0/10, which VPNs such as
    /// Tailscale use and which isn't a local network.
    public static func isLocal(_ address: String) -> Bool {
        let address = address.components(separatedBy: "%").first ?? address
        guard let bytes = AddressRange.parse(address) else { return false }
        if bytes.count == 4 {
            return bytes[0] == 10 || (bytes[0] == 172 && bytes[1] & 0xF0 == 16) || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 169 && bytes[1] == 254) || bytes[0] >= 224
        }
        return (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80) || bytes[0] & 0xFE == 0xFC || bytes[0] == 0xFF
    }

    /// The app's error says "No route to host", as curl, Node, Python, Go, Java and Apple's own errors put it.
    public static func saysNoRoute(_ error: String?) -> Bool {
        guard let error else { return false }
        return error.range(of: #"(?i)no route to host|EHOSTUNREACH|errno[\s=:\[]*65\b|\[Errno 65\]|POSIXErrorCode\(rawValue: 65\)|NSPOSIXErrorDomain Code=65\b"#, options: .regularExpression) != nil
    }

    /// The finding for one target, or nil when Local Network access doesn't come into it.
    /// `local` is the first local address the target resolved to; `selfDenied` and `selfInstant` describe this process's own
    /// attempt; `selfConnected` whether it reached the address; `appOpen` whether the named app already has a connection there.
    public static func judge(local: String?, isGateway: Bool, selfDenied: Bool, selfInstant: Bool, selfConnected: Bool,
                             app: String?, appError: String?, appOpen: Bool) -> Finding? {
        guard let local else { return nil }
        if selfDenied { return .selfDenied(address: local, proven: true) }
        // The router itself answers apps that lack the permission in the reports, so an instant refusal there is something else.
        if selfInstant, !isGateway, !selfConnected { return .selfDenied(address: local, proven: false) }
        guard selfConnected, !appOpen else { return nil }
        if saysNoRoute(appError) { return .appSuspect(address: local) }
        return app != nil ? .appHint(address: local) : nil
    }

    public static let settingsPath = String(localized: "System Settings › Privacy & Security › Local Network", comment: "Where macOS lists apps' Local Network access")

    /// Who this check runs as: Kilobat when it's the app, else the app the command line runs in.
    public static var runsInApp: Bool { Bundle.main.bundlePath.hasSuffix(".app") && Bundle.main.bundleIdentifier?.hasPrefix("co.seifi.kilobat") == true }

    /// The step, verdict and next step for a finding, in the app's words. `app` is the app's name as shown.
    public static func words(_ finding: Finding, app: String?, host: String, inApp: Bool = runsInApp) -> (step: DoctorStep, verdict: String?, next: String) {
        let name = app ?? String(localized: "the app", comment: "Local Network check: stands in for an app's name")
        switch finding {
        case .selfDenied(let address, let proven):
            let detail: String
            if inApp {
                detail = proven ? String(localized: "macOS held back Kilobat’s connection to \(address): Local Network access is off for Kilobat.", comment: "Local Network check")
                    : String(localized: "macOS refused Kilobat’s connection to \(address) at once with “No route to host”, which is how it blocks an app without Local Network access.", comment: "Local Network check")
            } else {
                detail = proven ? String(localized: "macOS held back this check’s connection to \(address): Local Network access is off for the app it runs in, such as your terminal or editor.", comment: "Local Network check from the command line")
                    : String(localized: "macOS refused this check’s connection to \(address) at once with “No route to host”, which is how it blocks an app without Local Network access. Here that’s the app the check runs in, such as your terminal or editor.", comment: "Local Network check from the command line")
            }
            let next = inApp ? String(localized: "Turn on Kilobat in \(settingsPath), then check again.", comment: "Local Network check; the argument is a System Settings path")
                : String(localized: "Turn on the app you ran this from in \(settingsPath), quit and reopen it, then check again. Apple’s Terminal doesn’t need it.", comment: "Local Network check from the command line; the argument is a System Settings path")
            let verdict = switch (inApp, proven) {
            case (true, true): String(localized: "macOS is blocking Kilobat from your local network.", comment: "Local Network check verdict")
            case (true, false): String(localized: "macOS may be blocking Kilobat from your local network.", comment: "Local Network check verdict")
            case (false, true): String(localized: "macOS is blocking this check from your local network.", comment: "Local Network check verdict from the command line")
            case (false, false): String(localized: "macOS may be blocking this check from your local network.", comment: "Local Network check verdict from the command line")
            }
            return (DoctorStep(layer: "Local Network", status: .failed, detail: detail), verdict, next)
        case .appSuspect(let address):
            let detail = String(localized: "Kilobat connects to \(address), but \(name) got “No route to host”. When an app gets that at once for a device on your own network while other apps reach it, macOS is usually blocking its Local Network access.", comment: "Local Network check; the arguments are an address and an app")
            let next = String(localized: "To test it, open \(settingsPath), turn on \(name), quit and reopen it, then try again. If it isn’t listed, turn on the app it runs in, such as your terminal or editor.", comment: "Local Network check; the arguments are a System Settings path and an app")
            return (DoctorStep(layer: "Local Network", status: .warning, detail: detail),
                    String(localized: "The network reaches \(host). macOS may be blocking \(name) from your local network.", comment: "Local Network check verdict; the arguments are a host and an app"), next)
        case .appHint(let address):
            let detail = String(localized: "\(address) is on your local network, and Kilobat reaches it. If \(name) fails at once with “No route to host”, macOS may be blocking its Local Network access.", comment: "Local Network check; the arguments are an address and an app")
            let next = String(localized: "If \(name) still can’t connect, check it in \(settingsPath), then quit and reopen it.", comment: "Local Network check; the arguments are an app and a System Settings path")
            return (DoctorStep(layer: "Local Network", status: .skipped, detail: detail), nil, next)
        }
    }

    /// A finished check on made-up readings, for the debug snapshots: DBeaver got "No route to host" from a NAS that Kilobat reaches.
    public static func sampleReport(date: Date = Date()) -> DoctorReport {
        let local = words(.appSuspect(address: "192.168.1.20"), app: "DBeaver", host: "nas.lan", inApp: true)
        return DoctorReport(target: "nas.lan:5432", host: "nas.lan", app: "org.jkiss.dbeaver.core.product", verdict: local.verdict ?? "", next: local.next,
                            steps: [DoctorStep(layer: "Network", status: .ok, detail: "Online; the router at 192.168.1.1 answers."),
                                    DoctorStep(layer: "DNS", status: .ok, detail: "nas.lan → 192.168.1.20 in 3 ms from 192.168.1.1."),
                                    local.step,
                                    DoctorStep(layer: "IPv4", status: .ok, detail: "192.168.1.20: connected in 4 ms.")], date: date)
    }
}
