import Foundation
import Testing
@testable import KilobatCore

struct DeviceServiceIntegrationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let camera = "00:00:5e:00:53:01"
    private let printer = "00:00:5e:00:53:02"

    private func service(_ type: String, address: String, txt: [String: String]) -> BonjourService {
        BonjourService(type: type, name: "Private room label", addresses: [address], txt: txt.mapValues { Data($0.utf8) })
    }

    @Test @MainActor func resolvedAddressesEnrichOnlyTheMatchingNetworkWithoutKeepingFriendlyNames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let registry = DeviceRegistry(directory: folder)
        registry.observe([DeviceSighting(mac: camera, address: "192.0.2.10", hostname: "same-name")], network: "home-a", name: "Sample A", now: now)
        registry.observe([DeviceSighting(mac: camera, address: "192.0.2.10", hostname: "same-name")], network: "home-b", name: "Sample B", now: now)
        registry.observeServices([service("_hap._tcp", address: "192.0.2.10", txt: ["ci": "17", "md": "Sample Cam", "fn": "Private room label"])], network: "home-a", now: now)
        let found = try #require(registry.device(mac: camera, network: "home-a"))
        #expect(found.guess().type == .camera)
        #expect(found.hostname == "same-name")
        #expect(registry.device(mac: camera, network: "home-b")?.signals == nil)
        #expect(!String(decoding: try JSONEncoder().encode(found.signals), as: UTF8.self).contains("Private room label"))
        #expect(registry.devices(on: "home-a").count == 1)
    }

    @Test @MainActor func ambiguousStaleOrMissingAddressesCannotAssignAType() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let registry = DeviceRegistry(directory: folder)
        registry.observe([DeviceSighting(mac: camera, address: "192.0.2.10"), DeviceSighting(mac: printer, address: "192.0.2.10")], network: "sample", name: "Sample", now: now)
        let announced = service("_ipp._tcp", address: "192.0.2.10", txt: ["ty": "Sample Printer"])
        registry.observeServices([announced], network: "sample", now: now)
        #expect(registry.devices(on: "sample").allSatisfy { $0.signals == nil })
        registry.observeServices([announced], network: "missing", now: now)
        #expect(registry.devices(on: "missing").isEmpty)
        registry.observe([DeviceSighting(mac: camera, address: "192.0.2.11")], network: "sample", name: "Sample", now: now)
        registry.observeServices([service("_hap._tcp", address: "192.0.2.11", txt: ["ci": "17"])], network: "sample", now: now.addingTimeInterval(601))
        #expect(registry.devices(on: "sample").allSatisfy { $0.signals == nil })
    }

    @Test @MainActor func modelSignalsPreserveTheUsersTypeOverrideAndIgnoreVirtualGroups() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let registry = DeviceRegistry(directory: folder)
        registry.observe([DeviceSighting(mac: camera, address: "192.0.2.10")], network: "sample", name: "Sample", now: now)
        registry.setType(.camera, mac: camera, network: "sample")
        registry.observeServices([service("_googlecast._tcp", address: "192.0.2.10", txt: ["md": "Google Cast Group", "ca": "4132"])], network: "sample", now: now)
        #expect(registry.device(mac: camera, network: "sample")?.signals == nil)
        registry.observeServices([service("_ipp._tcp", address: "192.0.2.10", txt: ["ty": "Sample Printer"])], network: "sample", now: now)
        #expect(registry.device(mac: camera, network: "sample")?.guess().type == .camera)
        #expect(registry.device(mac: camera, network: "sample")?.signals?.models == ["Sample Printer"])
    }
}
