import Foundation
import Testing
@testable import KilobatCore

struct HintPolicyTests {
    let now = Date(timeIntervalSince1970: 2_000_000)
    func allowed(seen: Set<String> = [], showing: Bool = false, done: Bool = true, age: TimeInterval = 7200, last: TimeInterval? = nil) -> Bool {
        HintPolicy.canShow(id: "game", seen: seen, showing: showing, onboardingDone: done, firstSeen: now - age, lastShown: last.map { now - $0 }, now: now)
    }

    @Test func hintsAreRareOnPurpose() {
        #expect(allowed())
        #expect(!allowed(seen: ["game"]), "each shows once")
        #expect(!allowed(showing: true), "one at a time")
        #expect(!allowed(done: false), "never during onboarding")
        #expect(!allowed(age: 600), "not in the first hour")
        #expect(!allowed(last: 3600), "one a day")
        #expect(allowed(last: 90_000))
    }

    @Test func phoneHotspotNames() {
        for name in ["Philip’s iPhone", "佳のAndroid", "AndroidAP_1234", "Galaxy S24", "Pixel 9", "My Hotspot", "Redmi Note"] { #expect(HintPolicy.looksLikePhoneHotspot(name), "\(name)") }
        for name in ["KAMENOI-Wifi", "The Batcave", "Pixelated Cafe", "Opportunity", "MTNY", ""] { #expect(!HintPolicy.looksLikePhoneHotspot(name), "\(name)") }
        #expect(!HintPolicy.looksLikePhoneHotspot(nil))
    }

    @Test func weakSignalMustLast() {
        func readings(_ values: [(TimeInterval, Int?)]) -> [(date: Date, rssi: Int?)] { values.map { (now - $0.0, $0.1) } }
        #expect(HintPolicy.weakSignalLasted(readings([(300, -80), (180, -78), (60, -76)]), now: now))
        #expect(!HintPolicy.weakSignalLasted(readings([(120, -80), (60, -78), (10, -76)]), now: now), "too short")
        #expect(!HintPolicy.weakSignalLasted(readings([(300, -80), (180, -60), (60, -76)]), now: now), "recovered in between")
        #expect(!HintPolicy.weakSignalLasted(readings([(300, nil), (180, -78), (60, -76)]), now: now), "unknown isn't weak")
        #expect(!HintPolicy.weakSignalLasted(readings([(900, -80), (800, -78), (700, -76)]), now: now), "long ago")
    }

    @Test func onlyAFinishedRealOutageCounts() {
        func event(_ kind: String, start: TimeInterval, end: TimeInterval?) -> NetworkEvent { NetworkEvent(start: now - start, end: end.map { now - $0 }, network: "Home", kind: kind, detail: "") }
        #expect(HintPolicy.reportableOutage([event("Unreachable", start: 900, end: 300)], now: now))
        #expect(!HintPolicy.reportableOutage([event("Unreachable", start: 400, end: 300)], now: now), "a blip")
        #expect(!HintPolicy.reportableOutage([event("Unreachable", start: 900, end: nil)], now: now), "still happening")
        #expect(!HintPolicy.reportableOutage([event("Sign-in", start: 900, end: 300)], now: now), "not an outage")
        #expect(!HintPolicy.reportableOutage([event("Unreachable", start: 200_000, end: 190_000)], now: now), "too old")
    }
}
