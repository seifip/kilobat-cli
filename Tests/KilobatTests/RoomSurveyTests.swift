import Foundation
import Testing
@testable import KilobatCore

struct RoomSurveyTests {
    // Two nodes of "Home": one in the living room (…:10, …:11 for its 5 GHz radio) and one in the office (…:40).
    func spot(_ name: String, joined: String, rssi: Int, nearby: [(String, Int)], minutes: Double = 0, ssid: String = "Home") -> SavedSpot {
        SavedSpot(name: name, date: Date(timeIntervalSince1970: 1_000_000 + minutes * 60),
                  radio: RadioSample(bssid: joined, ssid: ssid, interface: "en0", rssi: rssi, noise: -92, transmitMbps: 400, channel: 36, band: "5 GHz"),
                  nearby: nearby.map { SeenRadio(bssid: $0.0, ssid: $0.0.hasPrefix("02") ? "Neighbour" : ssid, rssi: $0.1) })
    }
    let living = "00:00:5e:00:53:10", office = "00:00:5e:00:60:40", neighbour = "02:aa:bb:cc:dd:01"

    @Test func roomsGroupByNameAndKeepTheLatestReading() {
        let spots = [spot("Kitchen", joined: living, rssi: -60, nearby: [], minutes: 0),
                     spot("Office", joined: office, rssi: -50, nearby: [], minutes: 1),
                     spot("kitchen ", joined: living, rssi: -66, nearby: [], minutes: 2)]
        let rooms = RoomSurvey.rooms(spots)
        #expect(rooms.map(\.id) == ["kitchen", "office"])
        #expect(rooms[0].readings == 2 && rooms[0].rssi == -66 && rooms[0].grade == .fair)
        #expect(RoomSurvey.grade(-50) == .good && RoomSurvey.grade(-72) == .weak && RoomSurvey.grade(-70) == .fair)
    }

    @Test func aRoomIsSuggestedOnlyWhenItIsClearlyClosest() {
        let spots = [spot("Living room", joined: living, rssi: -45, nearby: [(living, -45), (office, -78), (neighbour, -70)]),
                     spot("Office", joined: office, rssi: -48, nearby: [(living, -80), (office, -48), (neighbour, -60)])]
        #expect(RoomSurvey.suggest(nearby: [SeenRadio(bssid: living, ssid: "Home", rssi: -47), SeenRadio(bssid: office, ssid: "Home", rssi: -76),
                                            SeenRadio(bssid: neighbour, ssid: "Neighbour", rssi: -72)], spots: spots) == "Living room")
        // Halfway between, neither is clearly closer.
        #expect(RoomSurvey.suggest(nearby: [SeenRadio(bssid: living, ssid: "Home", rssi: -62), SeenRadio(bssid: office, ssid: "Home", rssi: -63),
                                            SeenRadio(bssid: neighbour, ssid: "Neighbour", rssi: -65)], spots: spots) == nil)
        // Too few access points to tell rooms apart.
        #expect(RoomSurvey.suggest(nearby: [SeenRadio(bssid: living, ssid: "Home", rssi: -45)], spots: spots) == nil)
    }

    @Test func nodesAreNamedByTheRoomWhereTheyAreStrongest() {
        let rooms = RoomSurvey.rooms([spot("Living room", joined: living, rssi: -44, nearby: [(living, -44), (office, -77)]),
                                      spot("Office", joined: office, rssi: -50, nearby: [(office, -50), (living, -79)], minutes: 1),
                                      spot("Bedroom", joined: living, rssi: -75, nearby: [(living, -75), (office, -74)], minutes: 2)])
        #expect(RoomSurvey.nodeName(living, rooms: rooms) == "Living room access point")
        // The 5 GHz radio of the same box counts as the same node.
        #expect(RoomSurvey.nodeName("00:00:5e:00:53:11", rooms: rooms) == "Living room access point")
        #expect(RoomSurvey.nodeName(office, rooms: rooms, names: [office: "Upstairs"]) == "Upstairs")
    }

    @Test func adviceOnlySaysWhatTheReadingsShow() {
        // The Mac stayed on the living-room node in the bedroom while the office node was 14 dB stronger.
        let stuck = RoomSurvey.rooms([spot("Living room", joined: living, rssi: -45, nearby: [(living, -45), (office, -80)]),
                                      spot("Bedroom", joined: living, rssi: -76, nearby: [(living, -76), (office, -62)], minutes: 1)])
        #expect(stuck[1].closer?.bssid == office)
        #expect(RoomSurvey.advice(stuck).first?.contains("stayed on a farther access point") == true)
        // Weak with two nodes and nothing closer: the edge of the Wi-Fi. No distances or directions.
        let edge = RoomSurvey.rooms([spot("Living room", joined: living, rssi: -45, nearby: [(living, -45), (office, -80)]),
                                     spot("Garden", joined: office, rssi: -78, nearby: [(office, -78), (living, -84)], minutes: 1)])
        #expect(RoomSurvey.advice(edge).first?.contains("edge of your Wi-Fi") == true)
        // One router.
        let single = RoomSurvey.rooms([spot("Living room", joined: living, rssi: -45, nearby: [(living, -45)]),
                                       spot("Bedroom", joined: living, rssi: -77, nearby: [(living, -77)], minutes: 1)])
        #expect(RoomSurvey.advice(single).first?.contains("far from your router") == true)
        for line in RoomSurvey.advice(stuck) + RoomSurvey.advice(edge) + RoomSurvey.advice(single) { #expect(!line.contains(" m ") && !line.contains("metre")) }
        // All good.
        let fine = RoomSurvey.rooms([spot("Living room", joined: living, rssi: -45, nearby: []), spot("Office", joined: office, rssi: -55, nearby: [], minutes: 1)])
        #expect(RoomSurvey.advice(fine) == ["Every room you saved has good signal."])
        #expect(RoomSurvey.advice(Array(fine.prefix(1))).isEmpty)
    }

    @Test func oldSpotsWithoutAFingerprintStillDecode() throws {
        let old = #"{"id":"6B3C2E1A-0000-4000-8000-000000000001","name":"Desk","date":0,"radio":{"ssid":"Home","interface":"en0","rssi":-60,"noise":-92,"transmitMbps":400,"channel":36,"band":"5 GHz"}}"#
        let spot = try JSONDecoder().decode(SavedSpot.self, from: Data(old.utf8))
        #expect(spot.nearby == nil && RoomSurvey.rooms([spot]).first?.name == "Desk")
    }
}
