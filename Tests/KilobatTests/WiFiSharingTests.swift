import Foundation
import Security
import Testing
@testable import KilobatCore

/// The saved-password lookup with a fake keychain; nothing here reads a real password.
struct WiFiSharingTests {
    final class FakeKeychain: @unchecked Sendable {
        var answers: [WiFiPasswordSource: (OSStatus, String?)]
        private(set) var asked: [WiFiPasswordSource] = []
        private(set) var ssids: [Data] = []
        init(_ answers: [WiFiPasswordSource: (OSStatus, String?)]) { self.answers = answers }
        var lookup: WiFiPasswordLookup {
            WiFiPasswordLookup { source, ssid in
                self.asked.append(source); self.ssids.append(ssid)
                let answer = self.answers[source] ?? (errSecItemNotFound, nil)
                return (answer.0, answer.1)
            }
        }
    }
    let ssid = Data("Studio Wi-Fi".utf8)

    @Test func systemKeychainAnswersEvenWhenTheUserDomainIsBroken() {
        // The reported bug: CoreWLAN's user domain answers 4097, which used to skip the System keychain.
        let keychain = FakeKeychain([.system: (errSecSuccess, "fake-secret"), .user: (4097, nil)])
        let result = keychain.lookup.find(ssid: ssid)
        #expect(result.password == "fake-secret")
        #expect(result.failure == nil)
        #expect(keychain.asked == [.system])
        #expect(keychain.ssids == [ssid])
    }

    @Test func securityFrameworkCoversAFailingCoreWLANCall() {
        let keychain = FakeKeychain([.system: (-25299, nil), .keychain: (errSecSuccess, "fake-secret")])
        let result = keychain.lookup.find(ssid: ssid)
        #expect(result.password == "fake-secret")
        #expect(keychain.asked == [.system, .keychain])
    }

    @Test func userDomainIsTheLastResort() {
        let keychain = FakeKeychain([.user: (errSecSuccess, "fake-secret")])
        let result = keychain.lookup.find(ssid: ssid)
        #expect(result.password == "fake-secret")
        #expect(keychain.asked == [.system, .keychain, .user])
    }

    @Test func absentEverywhereIsNotFoundWithEveryCode() {
        let keychain = FakeKeychain([.user: (4097, nil)])
        let result = keychain.lookup.find(ssid: ssid)
        #expect(result.password == nil)
        #expect(result.failure == .notFound)
        #expect(result.codes == "system -25300, keychain -25300, user 4097")
        #expect(result.failure?.message.contains("Passwords app") == true)
    }

    @Test func cancelOrDenyStopsSoMacOSAsksOnce() {
        let cancelled = FakeKeychain([.system: (errSecUserCanceled, nil), .keychain: (errSecSuccess, "fake-secret")])
        #expect(cancelled.lookup.find(ssid: ssid).failure == .cancelled)
        #expect(cancelled.asked == [.system])
        let denied = FakeKeychain([.system: (errSecAuthFailed, nil), .keychain: (errSecSuccess, "fake-secret")])
        let result = denied.lookup.find(ssid: ssid)
        #expect(result.failure == .denied)
        #expect(result.password == nil)
        #expect(denied.asked == [.system])
    }

    @Test func noPromptAndUnknownStatusesAreReported() {
        let locked = FakeKeychain([.system: (errSecInteractionNotAllowed, nil)])
        #expect(locked.lookup.find(ssid: ssid).failure == .promptUnavailable)
        let odd = FakeKeychain([.keychain: (-25299, nil), .user: (4097, nil)])
        let result = odd.lookup.find(ssid: ssid)
        #expect(result.failure == .failed(-25299))
        #expect(result.failure?.message.contains("-25299") == true)
    }

    @Test func emptySuccessKeepsLooking() {
        let keychain = FakeKeychain([.system: (errSecSuccess, ""), .keychain: (errSecSuccess, "fake-secret")])
        #expect(keychain.lookup.find(ssid: ssid).password == "fake-secret")
    }

    @Test func statusKinds() {
        #expect(WiFiPasswordLookup.kind(errSecSuccess) == .found)
        for absent: OSStatus in [errSecItemNotFound, errSecNoSuchKeychain, errSecNotAvailable, errSecMissingEntitlement, 4097, 4099] {
            #expect(WiFiPasswordLookup.kind(absent) == .absent)
        }
        #expect(WiFiPasswordLookup.kind(errSecUserCanceled) == .cancelled)
        #expect(WiFiPasswordLookup.kind(errSecAuthFailed) == .denied)
        #expect(WiFiPasswordLookup.kind(errSecInteractionNotAllowed) == .noPrompt)
        #expect(WiFiPasswordLookup.kind(errSecDecode) == .other)
    }

    @Test func failuresNeverCarryThePassword() {
        let keychain = FakeKeychain([.system: (errSecAuthFailed, "fake-secret")])
        let result = keychain.lookup.find(ssid: ssid)
        #expect(result.password == nil)
        #expect(!result.codes.contains("fake-secret"))
        #expect(!(result.failure?.message.contains("fake-secret") ?? true))
    }

    @Test func networkNamesCompareLikeMacOS() {
        #expect(WiFiShareNetwork.same(connected: "Café", expected: "Cafe\u{301}"))
        #expect(WiFiShareNetwork.same(connected: "Studio Wi-Fi", expected: "Studio Wi-Fi"))
        #expect(!WiFiShareNetwork.same(connected: "StudioWi-Fi", expected: "Studio Wi-Fi"))
        #expect(!WiFiShareNetwork.same(connected: "Studio Wi-Fi ", expected: "Studio Wi-Fi"))
        #expect(!WiFiShareNetwork.same(connected: nil, expected: "Studio Wi-Fi"))
    }
}
