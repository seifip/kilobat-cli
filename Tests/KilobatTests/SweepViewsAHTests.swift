import Foundation
import Testing
@testable import KilobatCore

struct SweepViewsAHTests {
    static let known: [String: String] = ["router": "GL-MT3000", "pixel": "Pixel 9"]

    static func packs(now: Date) -> [DataPack] {
        let day: TimeInterval = 86_400
        return [
            DataPack(name: "Router plan", bytes: 20_000_000_000, start: now - 20 * day, end: now + 10 * day,
                     networks: DataPackNetworks(keys: ["router": "GL-MT3000"])),
            DataPack(name: "Japan eSIM", bytes: 5_000_000_000, start: now - 5 * day, end: now + 2 * day,
                     networks: DataPackNetworks(keys: ["pixel": "Pixel 9"])),
        ]
    }

    /// Why the pack editor saves the "name contains" text only once it is whole: an edit goes through `DataPacks.add`,
    /// and a first letter matches another pack's network and ends this one.
    @Test func halfTypedNameTextEndsAPackWhileTheWholeWordDoesNot() {
        let now = Date()
        for (text, ends) in [("i", true), ("iPhone", false)] {
            var packs = Self.packs(now: now)
            var edited = packs[0]
            edited.networks = DataPackNetworks(keys: edited.networks.keys, nameContains: text)
            packs.removeAll { $0.id == edited.id }
            DataPacks.add(edited, to: &packs, known: Self.known)
            let router = packs.first { $0.name == "Router plan" }
            #expect((router?.ended != nil) == ends)
            #expect(packs.first { $0.name == "Japan eSIM" }?.ended == nil)
        }
    }
}
