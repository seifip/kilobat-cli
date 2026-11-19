import Testing
import UserNotifications
@testable import KilobatCore

struct SystemPermissionTests {
    @Test func mapsAuthorizationStatus() {
        #expect(SystemPermission(.notDetermined) == .notAsked)
        #expect(SystemPermission(.denied) == .denied)
        #expect(SystemPermission(.authorized) == .allowed)
        #expect(SystemPermission(.provisional) == .allowed)
    }

    @Test func confirmsOnlyWhenAllowedAndEnabled() {
        #expect(SystemPermission.allowed.confirms(enabled: true))
        #expect(!SystemPermission.denied.confirms(enabled: true))
        #expect(!SystemPermission.notAsked.confirms(enabled: true))
        #expect(!SystemPermission.allowed.confirms(enabled: false))
    }

    @Test func onlyRefusalNeedsSettings() {
        #expect(SystemPermission.denied.needsSettings)
        #expect(!SystemPermission.allowed.needsSettings)
        #expect(!SystemPermission.notAsked.needsSettings)
    }
}
