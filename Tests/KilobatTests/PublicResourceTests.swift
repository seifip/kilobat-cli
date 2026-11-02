import Foundation
import Testing
@testable import KilobatCore

struct PublicResourceTests {
    @Test func publicPackageBundlesOfflineLookupData() throws {
        let resource = try #require(GeoIP.resources.first)
        // The first lookup is the SwiftPM module bundle, independent of an installed app.
        #expect(resource.path.contains("KilobatCLI_KilobatCore.bundle"))
        for name in ["countries.deflate", "centroids.json", "oui.deflate", "networks.deflate"] {
            #expect(FileManager.default.fileExists(atPath: resource.appendingPathComponent(name).path), "missing bundled resource: \(name)")
        }
        #expect(GeoIP.shared.available)
        #expect(NetworkOwners.shared.available)
        #expect(NetworkOwners.shared.owner("140.82.121.4") == "github")
        #expect(GeoIP.shared.country("1.1.1.1") != nil)
        #expect(DeviceVendors.shared.vendor(for: "00:1b:63:00:00:01") == "Apple")
    }
}
