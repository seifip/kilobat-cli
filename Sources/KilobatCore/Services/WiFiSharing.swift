import Foundation
import CoreWLAN
import Security

public struct WiFiShareDetails: Sendable {
    public let name: String
    public let password: String
    public let security: String
    public var qrPayload: String { Self.payload(name: name, password: password, security: security) }
    public static func payload(name: String, password: String, security: String) -> String {
        func escape(_ value: String) -> String {
            value.reduce(into: "") { output, character in
                if "\\;,:\"".contains(character) { output.append("\\") }
                output.append(character)
            }
        }
        return "WIFI:T:\(security);S:\(escape(name));P:\(escape(password));;"
    }
}

extension WiFiConnection {
    /// Called only after an explicit sharing action and device-owner authentication.
    public func shareDetails(expectedName: String) throws -> WiFiShareDetails {
        guard let interface = CWWiFiClient.shared().interface(), interface.ssid() == expectedName,
              let ssid = interface.ssidData() else { throw DiagnosticError(String(localized: "The connected network changed. Reopen sharing for the current network.")) }
        let security = interface.security()
        guard [.none, .WEP, .wpaPersonal, .wpaPersonalMixed, .wpa2Personal, .wpa3Personal, .wpa3Transition].contains(security) else {
            throw DiagnosticError(String(localized: "This network uses enterprise or unsupported security. Share its setup instructions instead of a password."))
        }
        if security == .none { return WiFiShareDetails(name: expectedName, password: "", security: "nopass") }
        var password: NSString?
        var status = CWKeychainFindWiFiPassword(.user, ssid, &password)
        if status == errSecItemNotFound { status = CWKeychainFindWiFiPassword(.system, ssid, &password) }
        guard status == errSecSuccess, let password else {
            throw DiagnosticError(status == errSecUserCanceled ? String(localized: "Password access was cancelled.") : String(localized: "The saved password is unavailable to Kilobat. You can look for this network in Apple’s Passwords app."))
        }
        guard interface.ssid() == expectedName else { throw DiagnosticError(String(localized: "The connected network changed. Try again.")) }
        return WiFiShareDetails(name: expectedName, password: password as String, security: security == .WEP ? "WEP" : "WPA")
    }

    public func restart() async throws {
        guard let interface = CWWiFiClient.shared().interface() else { throw DiagnosticError(String(localized: "No Wi-Fi interface is available.")) }
        guard interface.powerOn() else { try interface.setPower(true); return }
        try interface.setPower(false)
        do { try await Task.sleep(for: .seconds(2)) }
        catch { try interface.setPower(true); throw error }
        try interface.setPower(true)
    }
}
