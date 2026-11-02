import Foundation
import CoreWLAN
import Security
import os

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

/// A sharing failure the sheet can show as it is. `codes` lists each keychain status on the way, for support
/// reports; it never holds the password.
public struct WiFiShareError: LocalizedError, Sendable, Equatable {
    public let message: String
    public let codes: String?
    public init(_ message: String, codes: String? = nil) { self.message = message; self.codes = codes }
    public var errorDescription: String? { message }
}

/// Where macOS may keep a saved Wi-Fi password, in the order Kilobat asks.
public enum WiFiPasswordSource: String, Sendable, CaseIterable {
    /// CoreWLAN's System-keychain lookup. airportd keeps every known network's password there, iCloud-synced
    /// ones included, readable only by itself, so macOS asks for an administrator's password.
    case system
    /// The same "AirPort" item through the Security framework's keychain search list (login, then System),
    /// for when CoreWLAN's own call fails.
    case keychain
    /// CoreWLAN's user-domain lookup. On current macOS it fails with 4097 (an interrupted XPC connection) even
    /// for a network it doesn't know, so it comes last and never hides the System keychain's answer.
    case user
}

public struct WiFiPasswordAttempt: Sendable, Equatable {
    public let source: WiFiPasswordSource
    public let status: OSStatus
}

public enum WiFiPasswordFailure: Sendable, Equatable {
    /// The person cancelled macOS's prompt.
    case cancelled
    /// macOS refused: Deny in the prompt, or a wrong administrator password.
    case denied
    /// macOS couldn't show its prompt, e.g. while the screen is locked.
    case promptUnavailable
    /// No place Kilobat may read has a password for this network.
    case notFound
    /// Any other keychain status.
    case failed(OSStatus)

    public var message: String {
        switch self {
        case .cancelled: String(localized: "Password access was cancelled.")
        case .denied: String(localized: "macOS didn’t allow Kilobat to read this password. Try again and allow access, or look for this network in Apple’s Passwords app.")
        case .promptUnavailable: String(localized: "macOS couldn’t ask for permission to read this password. Make sure your Mac is unlocked, then try again.")
        case .notFound: String(localized: "macOS doesn’t keep a password Kilobat can read for this network. You can look for it in Apple’s Passwords app.")
        case .failed(let status): String(localized: "macOS couldn’t read this network’s saved password (error \(String(status))). You can look for it in Apple’s Passwords app.")
        }
    }
}

public struct WiFiPasswordResult: Sendable {
    public let attempts: [WiFiPasswordAttempt]
    public let password: String?
    public let failure: WiFiPasswordFailure?
    /// "system -25300, keychain -25300, user 4097": the statuses only, for logs and support reports.
    public var codes: String { attempts.map { "\($0.source.rawValue) \($0.status)" }.joined(separator: ", ") }
}

/// Finds a saved Wi-Fi password. `read` is the seam: the live one asks CoreWLAN and the keychain; tests pass a fake.
public struct WiFiPasswordLookup: Sendable {
    public typealias Reader = @Sendable (WiFiPasswordSource, Data) -> (status: OSStatus, password: String?)
    let read: Reader
    public init(read: @escaping Reader) { self.read = read }
    public static let live = WiFiPasswordLookup(read: liveRead)

    enum Kind: Equatable { case found, absent, cancelled, denied, noPrompt, other }

    static func kind(_ status: OSStatus) -> Kind {
        switch status {
        case errSecSuccess: .found
        // Nothing here, or a path this app can't use: CoreWLAN's user domain answers 4097 (NSXPCConnectionInterrupted),
        // and 4099 (NSXPCConnectionInvalid) or a missing entitlement mean the same.
        case errSecItemNotFound, errSecNoSuchKeychain, errSecNotAvailable, errSecMissingEntitlement, 4097, 4099: .absent
        case errSecUserCanceled: .cancelled
        case errSecAuthFailed: .denied
        case errSecInteractionNotAllowed: .noPrompt
        default: .other
        }
    }

    /// Asks each source in turn. Stops at a password, or when the person cancels or denies a prompt, so macOS
    /// never asks twice for one share.
    public func find(ssid: Data) -> WiFiPasswordResult {
        var attempts: [WiFiPasswordAttempt] = []
        for source in WiFiPasswordSource.allCases {
            let answer = read(source, ssid)
            attempts.append(WiFiPasswordAttempt(source: source, status: answer.status))
            switch Self.kind(answer.status) {
            case .found:
                if let password = answer.password, !password.isEmpty { return WiFiPasswordResult(attempts: attempts, password: password, failure: nil) }
            case .cancelled: return WiFiPasswordResult(attempts: attempts, password: nil, failure: .cancelled)
            case .denied: return WiFiPasswordResult(attempts: attempts, password: nil, failure: .denied)
            case .absent, .noPrompt, .other: continue
            }
        }
        let kinds = attempts.map { Self.kind($0.status) }
        let failure: WiFiPasswordFailure
        if kinds.contains(.noPrompt) { failure = .promptUnavailable }
        else if let other = attempts.first(where: { Self.kind($0.status) == .other }) { failure = .failed(other.status) }
        else { failure = .notFound }
        return WiFiPasswordResult(attempts: attempts, password: nil, failure: failure)
    }

    @Sendable static func liveRead(_ source: WiFiPasswordSource, _ ssid: Data) -> (status: OSStatus, password: String?) {
        switch source {
        case .system, .user:
            var password: NSString?
            let status = CWKeychainFindWiFiPassword(source == .system ? .system : .user, ssid, &password)
            return (status, password as String?)
        case .keychain:
            // The item's account is the SSID as text; an SSID that isn't UTF-8 can only be found through CoreWLAN.
            guard let account = String(data: ssid, encoding: .utf8) else { return (errSecItemNotFound, nil) }
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "AirPort",
                                        kSecAttrAccount as String: account, kSecMatchLimit as String: kSecMatchLimitOne,
                                        kSecReturnData as String: true]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            guard status == errSecSuccess else { return (status, nil) }
            guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else { return (errSecDecode, nil) }
            return (status, password)
        }
    }
}

public enum WiFiShareNetwork {
    /// Whether the network the sheet was opened for is still the connected one. The name comes from the same
    /// CWInterface.ssid() the sheet showed; Swift compares it by canonical equivalence, so a composed and a
    /// decomposed "é" match, while extra or different spaces mean a different network, as they do to macOS.
    public static func same(connected: String?, expected: String) -> Bool { connected == expected }
}

extension WiFiConnection {
    private static let log = Logger(subsystem: "co.seifi.kilobat", category: "wifi-share")

    /// Called only after an explicit sharing action and device-owner authentication.
    public func shareDetails(expectedName: String, lookup: WiFiPasswordLookup = .live) throws -> WiFiShareDetails {
        guard let interface = CWWiFiClient.shared().interface(), WiFiShareNetwork.same(connected: interface.ssid(), expected: expectedName),
              let ssid = interface.ssidData() else { throw WiFiShareError(String(localized: "The connected network changed. Reopen sharing for the current network.")) }
        let security = interface.security()
        guard [.none, .WEP, .wpaPersonal, .wpaPersonalMixed, .wpa2Personal, .wpa3Personal, .wpa3Transition].contains(security) else {
            throw WiFiShareError(String(localized: "This network uses enterprise or unsupported security. Share its setup instructions instead of a password."))
        }
        if security == .none { return WiFiShareDetails(name: expectedName, password: "", security: "nopass") }
        let result = lookup.find(ssid: ssid)
        // Statuses only: never the password.
        Self.log.notice("Wi-Fi password lookup: \(result.codes, privacy: .public) -> \(result.failure.map { "\($0)" } ?? "found", privacy: .public)")
        guard let password = result.password else {
            throw WiFiShareError(result.failure?.message ?? WiFiPasswordFailure.notFound.message, codes: result.codes)
        }
        guard interface.ssidData() == ssid else { throw WiFiShareError(String(localized: "The connected network changed. Try again.")) }
        return WiFiShareDetails(name: expectedName, password: password, security: security == .WEP ? "WEP" : "WPA")
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
