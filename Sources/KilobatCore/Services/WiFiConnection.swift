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
        try interface.associate(to: network, password: credential)
        guard interface.ssid() == network.ssid else { throw WiFiError.notConnected }
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
