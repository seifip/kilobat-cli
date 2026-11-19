import Foundation
import Testing
@testable import KilobatCore

struct MacWiFiHardwareTests {
    private func report(_ interface: String) -> Data {
        Data(#"{"SPAirPortDataType":[{"spairport_airport_interfaces":[\#(interface),{"_name":"awdl0","spairport_wireless_mac_address":"00:00:5e:00:53:01"}]}]}"#.utf8)
    }

    @Test func readsTheWiFiInterface() {
        let found = MacWiFiHardware.parse(report(#"""
        {"_name":"en0","spairport_supported_phymodes":"802.11 a/b/g/n/ac/ax","spairport_wireless_card_type":"spairport_wireless_card_type_wifi (0x14E4, 0x4388)","spairport_wireless_firmware_version":"wl0: Aug 26 2026 05:28:29 version 23.10.1042.0.41.51.242 FWID 01-ba1b359c\nIO80211_driverkit-1587.10"}
        """#))
        #expect(found == MacWiFiHardware(chip: "Broadcom 4388", standards: "802.11 a/b/g/n/ac/ax", firmware: "23.10.1042.0.41.51.242"))
        #expect(found?.chipLine == "Broadcom 4388 · 802.11ax")
    }

    @Test func aReportWithoutWiFiIsNothing() {
        #expect(MacWiFiHardware.parse(report(#"{"_name":"en1"}"#)) == nil)
        #expect(MacWiFiHardware.parse(Data("not json".utf8)) == nil)
    }

    @Test func namesWhatItCanAndKeepsTheRest() {
        #expect(MacWiFiHardware.chipName("spairport_wireless_card_type_wifi (0x106b, 0x1a2)") == "Apple 1A2")
        #expect(MacWiFiHardware.chipName("spairport_wireless_card_type_wifi (0x17CB, 0x1103)") == "0x17CB, 0x1103")
        #expect(MacWiFiHardware.chipName("spairport_wireless_card_type_wifi") == nil)
        #expect(MacWiFiHardware.firmwareVersion("Broadcom BCM43xx 1.0 (7.77.111.1)\nmore") == "Broadcom BCM43xx 1.0 (7.77.111.1)")
        #expect(MacWiFiHardware(chip: "Broadcom 4388").chipLine == "Broadcom 4388")
        #expect(MacWiFiHardware(standards: "802.11 a/b/g/n/ac/ax/be").chipLine == "802.11be")
    }
}
