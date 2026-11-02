import CoreWLAN
import Foundation

extension DiagnosticProbe {
    /// The joined network's radios. `activeScan` asks the Wi-Fi to scan for this network now (a second or two
    /// off-channel); otherwise it reads the results macOS kept from its own last scan, which costs nothing.
    /// BSSIDs need Location permission: without it, `current` is nil and the scan holds nothing.
    public func nodeReading(activeScan: Bool) -> NodeReading {
        guard let wifi = CWWiFiClient.shared().interface(), wifi.powerOn(), let ssid = wifi.ssid(), let channel = wifi.wlanChannel() else {
            return NodeReading(date: Date(), ssid: nil, current: nil, transmitMbps: nil, scan: [])
        }
        let supported = Set(wifi.supportedWLANChannels()?.compactMap { Self.band($0.channelBand) } ?? [])
        let current = wifi.bssid().map { bssid in
            NodeRadio(bssid: bssid, rssi: wifi.rssiValue(), channel: channel.channelNumber, band: Self.band(channel.channelBand) ?? "Unknown", widthMHz: Self.width(channel.channelWidth))
        }
        var networks = wifi.cachedScanResults() ?? []
        if activeScan, let data = wifi.ssidData(), let found = try? wifi.scanForNetworks(withSSID: data) { networks = found }
        let scan = networks.filter { $0.ssid == ssid }.compactMap { network -> NodeRadio? in
            guard let bssid = network.bssid, let wlan = network.wlanChannel else { return nil }
            return NodeRadio(bssid: bssid, rssi: network.rssiValue, channel: wlan.channelNumber, band: Self.band(wlan.channelBand) ?? "Unknown", widthMHz: Self.width(wlan.channelWidth))
        }
        return NodeReading(date: Date(), ssid: ssid, current: current, transmitMbps: wifi.transmitRate() > 0 ? wifi.transmitRate() : nil,
                           scan: scan, supportedBands: supported.isEmpty ? ["2.4 GHz", "5 GHz"] : supported)
    }
}

/// How a reconnect went: which way Kilobat moved the Mac and the radio it ended up on.
public struct NodeMove: Sendable {
    public enum Method: String, Codable, Sendable {
        /// Joined the better node's radio directly, with the network's saved password.
        case associate
        /// Turned Wi-Fi off and on; macOS joined the strongest radio it heard.
        case power
    }
    public let method: Method
    public let bssid: String?
    public let rssi: Int?
}

extension WiFiConnection {
    /// Moves the Mac to one of `targets` (the better node's BSSIDs) on `ssid`. First it joins the strongest of those
    /// radios directly, passing no password so macOS uses the one it saved for the network; when that fails or lands
    /// elsewhere, it turns Wi-Fi off and on, after which macOS joins the strongest radio it hears. Both work for an
    /// ordinary user unless Wi-Fi Settings › Advanced requires an administrator to change networks or turn Wi-Fi on or off.
    public func moveToNode(_ targets: Set<String>, ssid: String) async throws -> NodeMove {
        guard let interface = CWWiFiClient.shared().interface() else { throw DiagnosticError(String(localized: "No Wi-Fi interface is available.")) }
        guard interface.powerOn(), interface.ssid() == ssid, let data = interface.ssidData() else {
            throw DiagnosticError(String(localized: "The Mac isn’t on that Wi-Fi any more.", comment: "Reconnecting to a closer mesh node: the network changed"))
        }
        let wanted = Set(targets.compactMap(MeshNodes.normalize))
        let found = (try? interface.scanForNetworks(withSSID: data)) ?? []
        if let network = found.filter({ $0.bssid.flatMap(MeshNodes.normalize).map(wanted.contains) ?? false }).max(by: { $0.rssiValue < $1.rssiValue }) {
            if (try? interface.associate(to: network, password: nil)) != nil, let now = await Self.joined(interface, ssid: ssid, timeout: 10), wanted.contains(now) {
                return NodeMove(method: .associate, bssid: now, rssi: interface.rssiValue())
            }
        }
        try await restart()
        let now = await Self.joined(interface, ssid: ssid, timeout: 30)
        return NodeMove(method: .power, bssid: now, rssi: now == nil ? nil : interface.rssiValue())
    }

    /// The BSSID once the Mac is back on `ssid`, or nil after `timeout` seconds.
    private static func joined(_ interface: CWInterface, ssid: String, timeout: Double) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if interface.ssid() == ssid, let bssid = interface.bssid().flatMap(MeshNodes.normalize), interface.rssiValue() != 0 { return bssid }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }
}
