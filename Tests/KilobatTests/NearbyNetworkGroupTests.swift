import Testing
@testable import KilobatCore

struct NearbyNetworkGroupTests {
    private func radio(_ id: String, _ ssid: String, _ rssi: Int, _ band: String = "5 GHz") -> NearbyNetwork {
        NearbyNetwork(id: id, ssid: ssid, rssi: rssi, noise: -90, channel: 36, band: band, widthMHz: 80)
    }

    @Test func aMeshBecomesOneRowLedByItsStrongestRadio() {
        let groups = NearbyNetworkGroup.group([radio("a", "Home", -60), radio("b", "Cafe", -50), radio("c", "Home", -40, "2.4 GHz")])
        #expect(groups.map(\.id) == ["Home", "Cafe"])
        #expect(groups[0].radios.map(\.id) == ["c", "a"])
        #expect(groups[0].strongest.rssi == -40)
        #expect(groups[0].bands == "2.4 + 5 GHz")
        #expect(groups[1].bands == "5 GHz")
    }

    @Test func hiddenNetworksStayApart() {
        let groups = NearbyNetworkGroup.group([radio("x", NearbyNetworkGroup.hiddenName, -50), radio("y", NearbyNetworkGroup.hiddenName, -60)])
        #expect(groups.map(\.id) == ["x", "y"])
    }
}
