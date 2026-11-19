import Foundation
import Testing
@testable import KilobatCore

@MainActor struct WiFiWatchCommandTests {
    @Test func graphAxisSkipsTheUnusedStretchAndWidensForOutliers() {
        #expect(ChannelPlan.axis(band: "5 GHz") == [.init(low: 5170, high: 5350), .init(low: 5470, high: 5850)])
        #expect(ChannelPlan.axis(band: "2.4 GHz") == [.init(low: 2401, high: 2483)])
        let fourteen = NearbyNetwork(id: "a", ssid: "Old", rssi: -70, noise: 0, channel: 14, band: "2.4 GHz", widthMHz: 20)
        #expect(ChannelPlan.axis(band: "2.4 GHz", networks: [fourteen]).first?.high == 2494)
        let unii4 = NearbyNetwork(id: "b", ssid: "New", rssi: -70, noise: 0, channel: 173, band: "5 GHz", widthMHz: 20)
        #expect(ChannelPlan.axis(band: "5 GHz", networks: [unii4]).last?.high == 5875)
        #expect(ChannelPlan.axis(band: "6 GHz").first?.width == 1180)
    }

    @Test func parsesDurationsAndLimits() throws {
        #expect(try WiFiWatchCommand.parse([]) == WiFiWatchCommand())
        #expect(WiFiWatchCommand().duration == WiFiWatchSession.defaultDuration)
        #expect(WiFiWatchCommand().interval == WiFiWatchSession.defaultInterval)
        let command = try WiFiWatchCommand.parse(["--for", "5m", "--every", "20s", "--csv"])
        #expect(command.duration == 300 && command.interval == 20 && command.csv)
        #expect(try WiFiWatchCommand.parse(["--for", "90"]).duration == 90)
        #expect(try WiFiWatchCommand.parse(["--for", "10min"]).duration == 600)
        #expect(throws: DiagnosticError.self) { try WiFiWatchCommand.parse(["--for", "11m"]) }
        #expect(throws: DiagnosticError.self) { try WiFiWatchCommand.parse(["--every", "5s"]) }
        #expect(throws: DiagnosticError.self) { try WiFiWatchCommand.parse(["--for"]) }
        #expect(throws: DiagnosticError.self) { try WiFiWatchCommand.parse(["--loud"]) }
        #expect(WiFiWatchCommand.label(120) == "2 min")
        #expect(WiFiWatchCommand.label(45) == "45 s")
    }
}
