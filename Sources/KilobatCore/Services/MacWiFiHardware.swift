import Foundation

/// This Mac's own Wi-Fi chip and its firmware, from System Information's report. The report takes several seconds,
/// and the answer can't change until macOS updates and the Mac restarts, so it's read once per launch.
public struct MacWiFiHardware: Equatable, Sendable {
    /// "Broadcom 4388", or the raw ids for a maker Kilobat can't name.
    public var chip: String?
    /// "802.11 a/b/g/n/ac/ax"
    public var standards: String?
    /// "23.10.1042.0.41.51.242"
    public var firmware: String?

    public init(chip: String? = nil, standards: String? = nil, firmware: String? = nil) {
        self.chip = chip; self.standards = standards; self.firmware = firmware
    }

    /// "Broadcom 4388 · 802.11ax": the chip and the newest standard it supports.
    public var chipLine: String? {
        let newest = standards?.split(separator: "/").last.map { $0.replacingOccurrences(of: "802.11", with: "").trimmingCharacters(in: .whitespaces) }
        let parts = [chip, newest.flatMap { $0.isEmpty ? nil : "802.11\($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public static func current() async -> MacWiFiHardware? { await lookup.value }

    private static let lookup = Task.detached(priority: .utility) { () -> MacWiFiHardware? in
        let result = await CommandRunner.run("/usr/sbin/system_profiler", ["SPAirPortDataType", "-json"], timeout: 30)
        return parse(Data(result.output.utf8))
    }

    static func parse(_ data: Data) -> MacWiFiHardware? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reports = root["SPAirPortDataType"] as? [[String: Any]] else { return nil }
        let interfaces = reports.flatMap { $0["spairport_airport_interfaces"] as? [[String: Any]] ?? [] }
        guard let wifi = interfaces.first(where: { $0["spairport_wireless_card_type"] != nil || $0["spairport_wireless_firmware_version"] != nil }) else { return nil }
        let hardware = MacWiFiHardware(chip: (wifi["spairport_wireless_card_type"] as? String).flatMap(chipName),
                                       standards: wifi["spairport_supported_phymodes"] as? String,
                                       firmware: (wifi["spairport_wireless_firmware_version"] as? String).flatMap(firmwareVersion))
        return hardware == MacWiFiHardware() ? nil : hardware
    }

    /// "spairport_wireless_card_type_wifi (0x14E4, 0x4388)" is a PCI maker and device.
    static func chipName(_ cardType: String) -> String? {
        guard let match = cardType.firstMatch(of: /\(0x([0-9A-Fa-f]+),\s*0x([0-9A-Fa-f]+)\)/) else { return nil }
        let device = String(match.2).uppercased()
        switch match.1.uppercased() {
        case "14E4": return "Broadcom \(device)"
        case "106B": return "Apple \(device)"
        default: return "0x\(match.1.uppercased()), 0x\(device)"
        }
    }

    /// The version out of "wl0: Aug 26 2026 05:28:29 version 23.10.1042 FWID 01-ba1b359c\nIO80211…"; otherwise the first line.
    static func firmwareVersion(_ raw: String) -> String? {
        if let match = raw.firstMatch(of: /version\s+(\S+)/) { return String(match.1) }
        let line = raw.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
        return line?.isEmpty == false ? line : nil
    }
}
