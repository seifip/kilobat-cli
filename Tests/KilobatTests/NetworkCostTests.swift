import Foundation
import Testing
@testable import KilobatCore

@MainActor struct NetworkCostTests {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func wifi(_ ssid: String?) -> DiagnosticSnapshot {
        DiagnosticSnapshot(date: Date(), radio: RadioSample(ssid: ssid, interface: "en0", rssi: -50, noise: -90, transmitMbps: 100, channel: 1, band: "2.4 GHz"), gateway: "192.168.1.1", router: nil,
                           internet: PingResult(host: "test", samples: [10], lossPercent: 0), dnsMilliseconds: 1, dnsServers: [], captivePortal: false, networkService: "Wi-Fi")
    }
    /// A phone on USB, with Wi-Fi joined alongside or off.
    private func tethered(alongside ssid: String?) -> DiagnosticSnapshot {
        DiagnosticSnapshot(date: Date(), radio: RadioSample(ssid: ssid, interface: ssid == nil ? nil : "en0", rssi: nil, noise: nil, transmitMbps: nil, channel: nil, band: nil), gateway: "172.20.10.1", router: nil,
                           internet: PingResult(host: "test", samples: [10], lossPercent: 0), dnsMilliseconds: 1, dnsServers: [], captivePortal: false, networkService: "iPhone USB", wiredInterface: "en7")
    }

    @Test func theEffectiveCostIsYoursOrMacOS() {
        #expect(NetworkCost.automatic.metered(os: true) && !NetworkCost.automatic.metered(os: false))
        #expect(NetworkCost.metered.metered(os: false) && !NetworkCost.unmetered.metered(os: true))
        var preferences = SavedPreferences()
        #expect(preferences.cost(of: "phone") == .automatic)
        preferences.setCost(.metered, for: "phone")
        preferences.networkCost?["odd"] = "free"
        #expect(preferences.cost(of: "phone") == .metered && preferences.cost(of: "odd") == .automatic)
        preferences.setCost(.automatic, for: "phone"); preferences.setCost(.automatic, for: "odd")
        #expect(preferences.networkCost == nil)
    }

    @Test func jsonKeepsMacOSAndTheEffectiveCostApart() {
        let marked = NetworkCost.metered.fields(os: false), freed = NetworkCost.unmetered.fields(os: true), automatic = NetworkCost.automatic.fields(os: true)
        #expect(marked["metered"] as? Bool == true && marked["osMetered"] as? Bool == false && marked["meteredSource"] as? String == "you")
        #expect(freed["metered"] as? Bool == false && freed["osMetered"] as? Bool == true && freed["meteredSource"] as? String == "you")
        #expect(automatic["metered"] as? Bool == true && automatic["osMetered"] as? Bool == true && automatic["meteredSource"] as? String == "macOS")
    }

    @Test func aTetheredPhoneIsTheSameNetworkWithWiFiOnOrOff() {
        let alongside = tethered(alongside: "Home"), alone = tethered(alongside: nil)
        #expect(alongside.networkKey == alone.networkKey && alongside.networkKey != wifi("Home").networkKey)
        #expect(alongside.networkName == "iPhone USB" && alongside.networkIdentified && alone.networkIdentified)
        #expect(wifi("Home").networkIdentified && !wifi(nil).networkIdentified)
    }

    @Test func aManuallyMeteredNetworkSwitchesToTravelAndRestores() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let store = TrafficStore(directory: path, startMonitoring: false)
        let phone = tethered(alongside: nil), cafe = wifi("Cafe")
        store.preferences.profile = .work
        store.pathChanged(connected: true, expensive: false, kind: "Ethernet")
        store.switchNetwork(phone)
        #expect(!store.metered && store.preferences.profile == .work)
        #expect(store.setCost(.metered))
        #expect(store.metered && !store.osExpensive && store.preferences.profile == .travel)
        store.switchNetwork(cafe)
        #expect(!store.metered && store.preferences.profile == .work)
        store.switchNetwork(phone)
        #expect(store.preferences.profile == .travel)
        store.setCost(.automatic)
        #expect(!store.metered && store.preferences.profile == .work && store.preferences.networkCost == nil)

        // macOS calls the café metered; marking it unmetered keeps Work.
        store.switchNetwork(cafe)
        store.pathChanged(connected: true, expensive: true, kind: "Wi-Fi")
        #expect(store.preferences.profile == .travel)
        store.setCost(.unmetered)
        #expect(!store.metered && store.preferences.profile == .work)
    }

    @Test func aProfileChosenForTheNetworkIsKept() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let store = TrafficStore(directory: path, startMonitoring: false)
        let phone = tethered(alongside: nil)
        store.pathChanged(connected: true, expensive: false, kind: "Ethernet")
        store.switchNetwork(phone)
        store.preferences.profile = .work
        store.rememberNetwork()
        store.setCost(.metered)
        #expect(store.metered && store.preferences.profile == .work && store.preferences.autoProfileFrom == nil)
    }

    @Test func aNetworkKilobatCantTellApartRefusesACost() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let store = TrafficStore(directory: path, startMonitoring: false)
        #expect(!store.setCost(.metered))
        store.switchNetwork(wifi(nil))
        #expect(!store.networkIdentified && !store.setCost(.metered) && store.preferences.networkCost == nil)
        store.flush(); store.resetSession()
        #expect(store.networkSessions[store.networkKey]?.identified == false)
        store.switchNetwork(wifi("Home"))
        #expect(store.setCost(.metered) && store.networkSessions[store.networkKey]?.identified == nil)
    }

    @Test func hotspotsMarkedBefore13BecomeMeteredNetworks() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let store = TrafficStore(directory: path, startMonitoring: false)
        store.networkSessions = ["android": NetworkSession(name: "AndroidAP"), "hidden": NetworkSession(name: "Wi-Fi", identified: false), "pixel": NetworkSession(name: "Pixel")]
        store.preferences.setCost(.unmetered, for: "pixel")
        store.switchNetwork(wifi("Cafe"))
        #expect(store.adoptHotspots(["AndroidAP", "Cafe", "Pixel", "Wi-Fi", "Elsewhere"]) == ["Wi-Fi", "Elsewhere"])
        #expect(store.preferences.cost(of: "android") == .metered && store.metered)
        #expect(store.preferences.cost(of: "pixel") == .unmetered && store.preferences.cost(of: "hidden") == .automatic)
    }

    @Test func scheduledSpeedTestsSkipMeteredNetworks() {
        let due = Date().addingTimeInterval(-60)
        #expect(DiagnosticStore.scheduledTestDue(next: due, hours: 6, connected: true, metered: false, busy: false))
        #expect(!DiagnosticStore.scheduledTestDue(next: due, hours: 6, connected: true, metered: true, busy: false))
        #expect(!DiagnosticStore.scheduledTestDue(next: Date().addingTimeInterval(60), hours: 6, connected: true, metered: false, busy: false))
    }
}
