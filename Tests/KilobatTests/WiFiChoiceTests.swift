import Testing
@testable import KilobatCore

struct WiFiChoiceTests {
    private func network(secured: Bool, known: Bool, enterprise: Bool = false) -> WiFiChoice {
        WiFiChoice(id: "x", name: "x", signal: -60, band: "2.4 GHz", secured: secured, enterprise: enterprise, weakSecurity: false, known: known)
    }

    /// A click on an open network such as Shinkansen_Free_Wi-Fi once did nothing: it waited for a password field that never shows.
    @Test func openAndSavedNetworksJoinOnClick() {
        #expect(network(secured: false, known: false).joinsOnClick)
        #expect(network(secured: true, known: true).joinsOnClick)
        #expect(!network(secured: true, known: false).joinsOnClick)
        #expect(!network(secured: true, known: true, enterprise: true).joinsOnClick)
    }
}
