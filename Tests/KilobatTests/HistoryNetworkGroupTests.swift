import Testing
@testable import KilobatCore

struct HistoryNetworkGroupTests {
    @Test func repeatedNamesIncludeEverySavedIdentityExactlyOnce() {
        let sessions = [
            "wifi-a": NetworkSession(name: "Wi-Fi", identified: false),
            "wifi-b": NetworkSession(name: "Wi-Fi", identified: false),
            "hassi-a": NetworkSession(name: "Hassi Appart"),
            "hassi-b": NetworkSession(name: "Hassi Appart"),
            "usb": NetworkSession(name: "iPhone USB")
        ]
        let groups = HistoryNetworkGroup.groups(sessions)
        #expect(groups.count == 3)
        #expect(groups.first { $0.name == "Hassi Appart" }?.keys == ["hassi-a", "hassi-b"])
        #expect(groups.first { $0.name == "Wi-Fi" }?.keys == ["wifi-a", "wifi-b"])
        #expect(groups.flatMap(\.keys).count == sessions.count)
        #expect(Set(groups.flatMap(\.keys)) == Set(sessions.keys))
    }

    @Test func namesRemainExactAndSortForPeople() {
        let groups = HistoryNetworkGroup.groups([
            "z": NetworkSession(name: "Room 10"),
            "a": NetworkSession(name: "Room 2"),
            "b": NetworkSession(name: "all")
        ])
        #expect(groups.map(\.name) == ["all", "Room 2", "Room 10"])
        #expect(HistoryNetworkGroup.groups([:]).isEmpty)
    }
}
