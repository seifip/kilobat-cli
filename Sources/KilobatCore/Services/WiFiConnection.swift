import CoreWLAN
import Foundation

public struct WiFiChoice: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let signal: Int
    public let band: String
    public let secured: Bool
    public let enterprise: Bool
    public let weakSecurity: Bool
    public let known: Bool
}
public struct WiFiChoices: Sendable {
    public let powered: Bool
    public let current: String?
    public let networks: [WiFiChoice]
}
/// CoreWLAN calls block. Keep both scans and association off the UI executor.
public actor WiFiConnection {
    private var scanned: [String: CWNetwork] = [:]
    public init() {}
    public func connection() throws -> WiFiChoices {
        guard let interface = CWWiFiClient.shared().interface() else { throw WiFiError.unavailable }
        return WiFiChoices(powered: interface.powerOn(), current: interface.ssid(), networks: [])
    }
    public func scan() throws -> WiFiChoices {
        guard let interface = CWWiFiClient.shared().interface() else { throw WiFiError.unavailable }
        guard interface.powerOn() else { return WiFiChoices(powered: false, current: nil, networks: []) }
        let known = Set(interface.configuration()?.networkProfiles.compactMap { ($0 as? CWNetworkProfile)?.ssid } ?? [])
        let found = try interface.scanForNetworks(withSSID: nil)
        var strongest: [String: CWNetwork] = [:]
        for network in found {
            guard let name = network.ssid, !name.isEmpty else { continue }
            if network.rssiValue > (strongest[name]?.rssiValue ?? -999) { strongest[name] = network }
        }
        scanned = strongest
        let choices = strongest.map { name, network in
            WiFiChoice(id: name, name: name, signal: network.rssiValue,
                       band: network.wlanChannel?.channelBand == .band2GHz ? "2.4 GHz" : network.wlanChannel?.channelBand == .band5GHz ? "5 GHz" : "6 GHz",
                       secured: !network.supportsSecurity(.none), enterprise: network.supportsSecurity(.enterprise),
                       weakSecurity: (network.supportsSecurity(.WEP) || network.supportsSecurity(.wpaPersonal)) && !network.supportsSecurity(.wpa2Personal) && !network.supportsSecurity(.wpa3Personal), known: known.contains(name))
        }.sorted { $0.signal != $1.signal ? $0.signal > $1.signal : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return WiFiChoices(powered: true, current: interface.ssid(), networks: choices)
    }
    public func join(_ id: String, password: String?) throws {
        guard let interface = CWWiFiClient.shared().interface(), let network = scanned[id] else { throw WiFiError.rescan }
        var credential = password
        if credential == nil, let ssid = network.ssidData {
            var saved: NSString?
            if CWKeychainFindWiFiPassword(.user, ssid, &saved) == 0 { credential = saved as String? }
        }
        try associate(interface, to: network, password: credential, typed: password != nil)
    }
    /// Joins `name` on `band`, the strongest access point there, with the password macOS saved: for moving a Mac
    /// from 2.4 GHz to the same router's 5 GHz, under the same name or another. macOS may roam back if 5 GHz is weak.
    public func join(name: String, band: String) throws {
        guard let interface = CWWiFiClient.shared().interface() else { throw WiFiError.unavailable }
        let found = try interface.scanForNetworks(withSSID: nil).filter { $0.ssid == name && Self.band($0.wlanChannel?.channelBand) == band }
        guard let network = found.max(by: { $0.rssiValue < $1.rssiValue }) else { throw WiFiError.rescan }
        var credential: String?
        if let ssid = network.ssidData {
            var saved: NSString?
            if CWKeychainFindWiFiPassword(.user, ssid, &saved) == 0 { credential = saved as String? }
        }
        try associate(interface, to: network, password: credential, typed: false)
    }
    /// Joins `name` on whichever band is strongest, with the password macOS saved: back to the usual Wi-Fi after a
    /// printer's or camera's own network.
    public func join(name: String) throws {
        guard let interface = CWWiFiClient.shared().interface() else { throw WiFiError.unavailable }
        let found = try interface.scanForNetworks(withSSID: nil).filter { $0.ssid == name }
        guard let network = found.max(by: { $0.rssiValue < $1.rssiValue }) else { throw WiFiError.rescan }
        var credential: String?
        if let ssid = network.ssidData {
            var saved: NSString?
            if CWKeychainFindWiFiPassword(.user, ssid, &saved) == 0 { credential = saved as String? }
        }
        try associate(interface, to: network, password: credential, typed: false)
    }
    /// Joins `name` on its strongest access point with `password`, or the one macOS saved when nil: a saved device's Wi-Fi.
    public func join(name: String, password: String?) throws {
        guard let interface = CWWiFiClient.shared().interface() else { throw WiFiError.unavailable }
        let found = try interface.scanForNetworks(withSSID: nil).filter { $0.ssid == name }
        guard let network = found.max(by: { $0.rssiValue < $1.rssiValue }) else { throw WiFiError.rescan }
        var credential = password
        if credential == nil, let ssid = network.ssidData {
            var saved: NSString?
            if CWKeychainFindWiFiPassword(.user, ssid, &saved) == 0 { credential = saved as String? }
        }
        try associate(interface, to: network, password: credential, typed: password != nil)
    }
    /// CoreWLAN can fail an association with a transient error (`tmpErr`, a timeout) while macOS is still switching
    /// networks, then join anyway a moment later. Give it a few seconds before calling it a failure, and say what
    /// went wrong in plain words rather than CoreWLAN's code.
    private func associate(_ interface: CWInterface, to network: CWNetwork, password: String?, typed: Bool) throws {
        let name = network.ssid
        do { try interface.associate(to: network, password: password) } catch {
            for _ in 0..<12 {
                if name != nil, interface.ssid() == name { return }
                Thread.sleep(forTimeInterval: 0.5)
            }
            throw WiFiJoinError(name: name ?? "", underlying: error as NSError, secured: !network.supportsSecurity(.none), hadPassword: password != nil, typed: typed)
        }
        for _ in 0..<6 {
            if name != nil, interface.ssid() == name { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw WiFiError.notConnected
    }
    static func band(_ band: CWChannelBand?) -> String {
        switch band { case .band2GHz: "2.4 GHz"; case .band5GHz: "5 GHz"; case .band6GHz: "6 GHz"; default: "Unknown" }
    }
    public func disconnect() throws {
        guard let interface = CWWiFiClient.shared().interface() else { throw WiFiError.unavailable }
        interface.disassociate()
        guard interface.ssid() == nil else { throw WiFiError.notDisconnected }
    }
    public func power(_ on: Bool) throws {
        guard let interface = CWWiFiClient.shared().interface() else { throw WiFiError.unavailable }
        try interface.setPower(on)
    }
}
/// Why joining a network failed, in words a person can act on. `needsPassword` tells the Wi-Fi menu to ask for one.
public struct WiFiJoinError: LocalizedError {
    public let name: String
    let underlying: NSError
    let secured: Bool
    let hadPassword: Bool
    let typed: Bool

    /// CoreWLAN's timeouts and its `tmpErr`: the network or macOS didn't answer in time, which a retry usually fixes.
    var transient: Bool {
        let text = underlying.localizedDescription + " " + underlying.debugDescription
        return text.contains("tmpErr") || [-3905, -3925, -3931].contains(underlying.code)
    }
    /// A secured network with no saved password Kilobat could read, or a saved or typed password that was refused.
    public var needsPassword: Bool { secured && !transient }

    public var errorDescription: String? {
        if transient { return String(localized: "\(name) didn’t answer in time. Try again in a moment.", comment: "Wi-Fi join failed with a temporary error; the argument is the network name") }
        if secured && typed { return String(localized: "Couldn’t join \(name). Check the password and try again.", comment: "Wi-Fi join with a typed password failed; the argument is the network name") }
        if secured { return String(localized: "Couldn’t join \(name) with the saved password. Enter it to try again.", comment: "Wi-Fi join with the saved password failed; the argument is the network name") }
        return String(localized: "Couldn’t join \(name). Try again, or open Wi-Fi Settings.", comment: "Wi-Fi join failed; the argument is the network name")
    }
}

private enum WiFiError: LocalizedError {
    case unavailable, rescan, notConnected, notDisconnected
    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "No Wi-Fi interface is available.")
        case .rescan: String(localized: "This network is no longer available. Refresh and try again.")
        case .notConnected: String(localized: "The Mac did not join the selected network. Try again or open Wi-Fi Settings.")
        case .notDisconnected: String(localized: "macOS kept the connection active. Use Wi-Fi Settings to disconnect.")
        }
    }
}
