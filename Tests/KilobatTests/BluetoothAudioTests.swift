import Foundation
import Testing
@testable import KilobatCore

struct BluetoothAudioTests {
    /// Core Audio's four-character transport codes, as `kAudioDevicePropertyTransportType` returns them.
    private enum Transport { static let bluetooth: UInt32 = 0x626C_7565, bluetoothLE: UInt32 = 0x626C_6561, builtIn: UInt32 = 0x626C_746E, usb: UInt32 = 0x7573_6220, airPlay: UInt32 = 0x6169_7270 }

    private func output(microphone: Bool = false) -> BluetoothAudioOutput {
        BluetoothAudioOutput(name: "AirPods Pro", transport: .classic, playing: true, microphone: microphone, sampleRate: microphone ? 24_000 : 48_000)
    }
    private func conditions(_ edit: (inout BluetoothAudioConditions) -> Void = { _ in }) -> BluetoothAudioConditions {
        var value = BluetoothAudioConditions()
        value.wifiBand = "5 GHz"; value.wifiChannel = 44; value.wifiName = "Home"; value.airDropActive = false; value.wifiBytesPerSecond = 20_000
        edit(&value)
        return value
    }

    // MARK: Detection

    @Test func onlyBluetoothTransportsCount() {
        #expect(BluetoothAudioOutput.transport(Transport.bluetooth) == .classic)
        #expect(BluetoothAudioOutput.transport(Transport.bluetoothLE) == .le)
        for other in [Transport.builtIn, Transport.usb, Transport.airPlay, 0] { #expect(BluetoothAudioOutput.transport(other) == nil) }
    }
    @Test func readsPlayingAndTheMicrophone() {
        // Built-in speakers: not Bluetooth, so nothing to say.
        #expect(BluetoothAudioOutput.reading(name: "MacBook Pro Speakers", outputTransport: Transport.builtIn, running: true, sampleRate: 48_000, inputTransport: Transport.builtIn, inputRunning: true) == nil)
        // Music: AirPods out, the Mac's own microphone idle.
        let music = BluetoothAudioOutput.reading(name: "AirPods Pro", outputTransport: Transport.bluetooth, running: true, sampleRate: 48_000, inputTransport: Transport.builtIn, inputRunning: false)
        #expect(music?.playing == true && music?.microphone == false && music?.transport == .classic)
        // A call on the AirPods' own microphone.
        let call = BluetoothAudioOutput.reading(name: "AirPods Pro", outputTransport: Transport.bluetooth, running: true, sampleRate: 48_000, inputTransport: Transport.bluetooth, inputRunning: true)
        #expect(call?.microphone == true)
        // Hands-free rate on the output even when the input reads otherwise.
        #expect(BluetoothAudioOutput.reading(name: "Headset", outputTransport: Transport.bluetooth, running: true, sampleRate: 16_000, inputTransport: nil, inputRunning: false)?.microphone == true)
        // Connected but silent: not playing, so no microphone either.
        let idle = BluetoothAudioOutput.reading(name: "AirPods Pro", outputTransport: Transport.bluetoothLE, running: false, sampleRate: 24_000, inputTransport: Transport.bluetooth, inputRunning: true)
        #expect(idle?.playing == false && idle?.microphone == false && idle?.transport == .le)
    }
    @Test func profilerSignalAndDeviceMatch() throws {
        let json = #"{"SPBluetoothDataType":[{"device_connected":[{"AirPods Pro":{"device_address":"AA-BB-CC-00-11-22","device_minorType":"Headphones","device_rssi":"-61"}},{"Magic Keyboard":{"device_address":"AA-BB-CC-00-11-33","device_minorType":"Keyboard","device_rssi":"127"}}],"device_not_connected":[{"Old Speaker":{"device_address":"AA-BB-CC-00-11-44","device_minorType":"Speaker","device_rssi":"-50"}}]}]}"#
        let devices = NearbyRadios.parseSystemProfiler(Data(json.utf8))
        #expect(devices.first { $0.name == "AirPods Pro" }?.rssi == -61)
        #expect(devices.first { $0.name == "Magic Keyboard" }?.rssi == nil)
        #expect(devices.first { $0.name == "Old Speaker" }?.rssi == nil)
        // Core Audio names the output as the device does; failing that, the only connected headphones are it.
        #expect(BluetoothAudioWatch.match("AirPods Pro", devices.filter(\.connected))?.rssi == -61)
        #expect(BluetoothAudioWatch.match("Kitchen", devices.filter(\.connected))?.name == "AirPods Pro")
        var filled = BluetoothAudioConditions()
        BluetoothAudioWatch.fill(&filled, output: "AirPods Pro", devices: devices)
        #expect(filled.bluetoothRSSI == -61 && filled.otherBluetoothDevices == 1)
        // A device saved before the signal was recorded still decodes.
        let old = try JSONDecoder().decode(BluetoothDevice.self, from: Data(#"{"id":"x","name":"AirPods","kind":"headphones","connected":true}"#.utf8))
        #expect(old.rssi == nil)
    }

    // MARK: Risks

    @Test func eachConditionIsOneRisk() {
        #expect(BluetoothAudioCheck(output: output(), conditions: conditions()).risks.isEmpty)
        let all = conditions {
            $0.wifiBand = "2.4 GHz"; $0.wifiChannel = 6; $0.channelCrowding = 180; $0.airDropActive = true
            $0.wifiBytesPerSecond = 3_000_000; $0.bluetoothRSSI = -80; $0.otherBluetoothDevices = 4
        }
        #expect(BluetoothAudioCheck(output: output(), conditions: all).risks == BluetoothAudioRisk.allCases)
        // Crowding counts only on 2.4 GHz; a busy 5 GHz channel doesn't share Bluetooth's band.
        #expect(BluetoothAudioCheck(output: output(), conditions: conditions { $0.channelCrowding = 400 }).risks.isEmpty)
        // Just under each line.
        let under = conditions { $0.wifiBytesPerSecond = 2_400_000; $0.bluetoothRSSI = -71; $0.otherBluetoothDevices = 3 }
        #expect(BluetoothAudioCheck(output: output(), conditions: under).risks.isEmpty)
        // Unknowns are never risks.
        var unknown = BluetoothAudioConditions(); unknown.wifiBand = nil
        #expect(BluetoothAudioCheck(output: output(), conditions: unknown).risks.isEmpty)
        // Traffic only counts while on Wi-Fi.
        #expect(BluetoothAudioCheck(output: output(), conditions: conditions { $0.wifiBand = nil; $0.wifiBytesPerSecond = 9_000_000 }).risks.isEmpty)
    }
    @Test func scoreAndLevel() {
        let band = BluetoothAudioCheck(output: output(), conditions: conditions { $0.wifiBand = "2.4 GHz" })
        #expect(band.score == 3 && band.level == .some && !band.lineUp)
        let bandAndAirDrop = BluetoothAudioCheck(output: output(), conditions: conditions { $0.wifiBand = "2.4 GHz"; $0.airDropActive = true })
        #expect(bandAndAirDrop.score == 5 && bandAndAirDrop.level == .high && bandAndAirDrop.lineUp)
        // On a call the same conditions weigh a little more: hands-free mode has less room for retries.
        let onCall = BluetoothAudioCheck(output: output(microphone: true), conditions: conditions { $0.airDropActive = true })
        #expect(onCall.score == 3 && onCall.level == .some)
        let clear = BluetoothAudioCheck(output: output(microphone: true), conditions: conditions())
        #expect(clear.score == 0 && clear.level == .clear && !clear.shows)
        // Said it crackles: shown even with nothing in the way.
        #expect(BluetoothAudioCheck(output: output(), conditions: conditions(), reported: true).shows)
    }

    // MARK: Advice

    @Test func adviceComesInOrder() {
        let check = BluetoothAudioCheck(output: output(), conditions: conditions {
            $0.wifiBand = "2.4 GHz"; $0.wifiChannel = 6; $0.channelCrowding = 200; $0.quieterChannel = 11
            $0.airDropActive = true; $0.airDropUsers = ["AirDrop"]; $0.wifiBytesPerSecond = 4_000_000; $0.busiestApp = "Steam"; $0.busiestUploading = false
            $0.bluetoothRSSI = -80
            $0.fasterBand = FasterBand(name: "Home-5G", band: "5 GHz", rssi: -60, sameName: false, known: true)
        })
        let advice = check.advice
        #expect(advice.map(\.risk) == [.wifi24, .crowdedChannel, .airDrop, .heavyTraffic, .weakBluetooth])
        #expect(advice[0].action == .joinFasterBand && advice[0].text.contains("Home-5G") && advice[0].text.contains("AirPods Pro"))
        #expect(advice[1].text.contains("channel 11"))
        #expect(advice[2].action == .pauseAirDrop && advice[2].text.hasPrefix("AirDrop is scanning"))
        #expect(advice[3].text.contains("Steam") && advice[3].action == nil)
        #expect(advice[4].text.contains("bag"))
    }
    @Test func fiveGHzWordingFollowsWhatKilobatCanDo() {
        func first(_ faster: FasterBand?, name: String? = "Home") -> BluetoothAudioAdvice {
            BluetoothAudioCheck(output: output(), conditions: conditions { $0.wifiBand = "2.4 GHz"; $0.wifiName = name; $0.fasterBand = faster }).advice[0]
        }
        // No scan or nothing found: name the likely network, no button.
        #expect(first(nil).text.contains("Home-5G") && first(nil).action == nil)
        // Not remembered: macOS needs the password, so Kilobat can't join it.
        #expect(first(FasterBand(name: "Home 5GHz", band: "5 GHz", rssi: -60, sameName: false, known: false)).action == nil)
        // The same name on 5 GHz, remembered: Kilobat can move the Mac.
        let same = first(FasterBand(name: "Home", band: "5 GHz", rssi: -60, sameName: true, known: true))
        #expect(same.action == .joinFasterBand && same.text.contains("same name"))
    }
    @Test func airDropUsersAreNamed() {
        let check = BluetoothAudioCheck(output: output(), conditions: conditions { $0.airDropActive = true; $0.airDropUsers = ["AirDrop", "Universal Control"] })
        #expect(check.advice[0].text.hasPrefix("Universal Control") && check.advice[0].action == .pauseAirDrop)
    }
    @Test func reportedWithNothingInTheWayPointsAtDistance() {
        let check = BluetoothAudioCheck(output: output(microphone: true), conditions: conditions(), reported: true)
        #expect(check.advice.count == 2 && check.advice[0].risk == nil && check.advice[0].text.contains("bag"))
        // On a call, the Mac's microphone keeps the headphones in their high-quality mode.
        #expect(check.advice[1].text.contains("microphone"))
        #expect(check.headline.contains("nothing"))
    }

    // MARK: Measuring

    @Test func picksAFasterBand() {
        func network(_ name: String, _ band: String, _ rssi: Int, channel: Int = 36) -> NearbyNetwork {
            NearbyNetwork(id: name + band + String(rssi), ssid: name, rssi: rssi, noise: -95, channel: channel, band: band, widthMHz: 80)
        }
        let scan = [network("Home", "2.4 GHz", -50, channel: 6), network("Home-5G", "5 GHz", -62), network("Neighbour", "5 GHz", -55), network("Cafe", "5 GHz", -40)]
        // Named like this one and remembered beats a stronger stranger.
        #expect(BluetoothAudioCheck.fasterBand(current: "Home", band: "2.4 GHz", networks: scan, known: ["Home", "Home-5G"])?.name == "Home-5G")
        // Not remembered, but clearly the same router's.
        let unknown = BluetoothAudioCheck.fasterBand(current: "Home", band: "2.4 GHz", networks: scan, known: ["Home"])
        #expect(unknown?.name == "Home-5G" && unknown?.known == false)
        // The same name on 5 GHz comes first.
        let same = BluetoothAudioCheck.fasterBand(current: "Home", band: "2.4 GHz", networks: scan + [network("Home", "5 GHz", -66)], known: ["Home"])
        #expect(same?.sameName == true && same?.known == true)
        // Too weak to be worth it, already on 5 GHz, or no name to go by.
        #expect(BluetoothAudioCheck.fasterBand(current: "Home", band: "2.4 GHz", networks: [network("Home-5G", "5 GHz", -82)], known: ["Home-5G"]) == nil)
        #expect(BluetoothAudioCheck.fasterBand(current: "Home", band: "5 GHz", networks: scan, known: ["Home-5G"]) == nil)
        #expect(BluetoothAudioCheck.fasterBand(current: nil, band: "2.4 GHz", networks: scan, known: ["Home-5G"]) == nil)
        // "Home 2.4G" and "Home 5G" are one router's.
        #expect(BluetoothAudioCheck.fasterBand(current: "Home 2.4G", band: "2.4 GHz", networks: [network("Home 5G", "5 GHz", -60)], known: [])?.name == "Home 5G")
    }
    @Test func crowdingLeavesOutTheMacsOwnNetwork() {
        func network(_ name: String, _ channel: Int, _ rssi: Int) -> NearbyNetwork {
            NearbyNetwork(id: name + String(channel), ssid: name, rssi: rssi, noise: -95, channel: channel, band: "2.4 GHz", widthMHz: 20)
        }
        let scan = [network("Home", 6, -40), network("Flat 2", 6, -55), network("Flat 3", 6, -60), network("Flat 4", 5, -58), network("Far", 1, -88)]
        let result = BluetoothAudioCheck.crowding(channel: 6, band: "2.4 GHz", ownName: "Home", networks: scan)
        #expect(result != nil && result!.crowding > 80 && result!.quieter == 11)
        // Alone on the channel: nothing quieter to suggest.
        #expect(BluetoothAudioCheck.crowding(channel: 6, band: "2.4 GHz", ownName: "Home", networks: [network("Home", 6, -40)])?.quieter == nil)
        #expect(BluetoothAudioCheck.crowding(channel: 36, band: "5 GHz", ownName: "Home", networks: scan) == nil)
        // Old scans don't count.
        let now = Date()
        #expect(BluetoothAudioProbe.recentScan([SavedScan(date: now.addingTimeInterval(-3600), networks: scan)], now: now).isEmpty)
        #expect(BluetoothAudioProbe.recentScan([SavedScan(date: now.addingTimeInterval(-600), networks: scan)], now: now).count == scan.count)
    }

    // MARK: Notifications

    @Test func notifiesOncePerSessionAfterCausesSettle() {
        var notifier = BluetoothAudioNotifier()
        func observe(playing: Bool, lineUp: Bool, now: Date) -> Bool { notifier.observe(playing: playing, lineUp: lineUp, now: now) }
        let start = Date(timeIntervalSince1970: 1_000_000)
        func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
        // One cause is not enough.
        #expect(!observe(playing: true, lineUp: false, now: at(0)))
        // Two line up, but must hold for 20 seconds.
        #expect(!observe(playing: true, lineUp: true, now: at(5)))
        #expect(!observe(playing: true, lineUp: true, now: at(15)))
        #expect(observe(playing: true, lineUp: true, now: at(25)))
        // Once a session.
        #expect(!observe(playing: true, lineUp: true, now: at(60)))
        // A short pause keeps the session.
        #expect(!observe(playing: false, lineUp: false, now: at(120)))
        #expect(!observe(playing: true, lineUp: true, now: at(200)))
        #expect(!observe(playing: true, lineUp: true, now: at(230)))
        #expect(notifier.session?.started == at(0))
    }
    @Test func aNewSessionWaitsOutTheSpacing() {
        var notifier = BluetoothAudioNotifier()
        func observe(playing: Bool, lineUp: Bool, now: Date) -> Bool { notifier.observe(playing: playing, lineUp: lineUp, now: now) }
        let start = Date(timeIntervalSince1970: 2_000_000)
        func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
        _ = notifier.observe(playing: true, lineUp: true, now: at(0))
        #expect(observe(playing: true, lineUp: true, now: at(30)))
        // Ten minutes of silence ends the session; the next one an hour later is too soon for another notification.
        _ = notifier.observe(playing: false, lineUp: false, now: at(700))
        #expect(notifier.session == nil && notifier.ended)
        #expect(!observe(playing: true, lineUp: true, now: at(3_600)))
        #expect(!observe(playing: true, lineUp: true, now: at(3_630)))
        // Five hours after the first, a new session may notify again.
        _ = notifier.observe(playing: false, lineUp: false, now: at(4_000))
        #expect(!observe(playing: true, lineUp: true, now: at(18_000)))
        #expect(observe(playing: true, lineUp: true, now: at(18_030)))
    }
    @Test func causesThatComeAndGoStartTheClockAgain() {
        var notifier = BluetoothAudioNotifier()
        func observe(playing: Bool, lineUp: Bool, now: Date) -> Bool { notifier.observe(playing: playing, lineUp: lineUp, now: now) }
        let start = Date(timeIntervalSince1970: 3_000_000)
        func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
        #expect(!observe(playing: true, lineUp: true, now: at(0)))
        #expect(!observe(playing: true, lineUp: false, now: at(10)))
        #expect(!observe(playing: true, lineUp: true, now: at(25)))
        #expect(observe(playing: true, lineUp: true, now: at(45)))
    }

    // MARK: Calls

    @Test func callNoteNeedsBluetoothForAThirdOfTheCall() {
        func sample(_ index: Int, _ risks: [BluetoothAudioRisk]) -> CallSamples.BluetoothAudio {
            .init(at: Double(index * 5), device: "AirPods Pro", microphone: true, risks: risks)
        }
        // A short stretch on AirPods in a long call says nothing.
        #expect(BluetoothCallNote.from((0..<10).map { sample($0, [.wifi24]) }, calledFor: 100) == nil)
        // AirDrop in a fifth of the checks is below the quarter that counts; 2.4 GHz all along is in.
        let samples = (0..<100).map { sample($0, $0 % 5 == 0 ? [.wifi24, .airDrop] : [.wifi24]) }
        let note = BluetoothCallNote.from(samples, calledFor: 120)
        #expect(note?.risks == [.wifi24] && note?.device == "AirPods Pro" && note?.microphone == true)
        #expect(note?.sentence?.contains("2.4 GHz") == true && note?.advice?.contains("5 GHz") == true)
        // Nothing in the way: the note stays, without a sentence.
        #expect(BluetoothCallNote.from((0..<50).map { sample($0, []) }, calledFor: 50)?.sentence == nil)
    }
    @Test func callReportCarriesTheNote() throws {
        var samples = CallSamples()
        samples.internet = (0..<120).map { .init(at: Double($0), ms: 30) }
        samples.router = (0..<120).map { .init(at: Double($0), ms: 3) }
        samples.audioChecks = 24
        samples.bluetoothAudio = (0..<24).map { .init(at: Double($0 * 5), device: "AirPods Pro", microphone: true, risks: [.wifi24, .airDrop]) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let card = CallAnalysis.report(app: "Zoom", browser: false, start: start, end: start.addingTimeInterval(120), network: nil, samples: samples)
        #expect(card.clean && card.bluetooth?.risks == [.wifi24, .airDrop])
        let decoded = try JSONDecoder().decode(CallReport.self, from: JSONEncoder().encode(card))
        #expect(decoded.bluetooth == card.bluetooth)
        // Reports saved before this decode without it.
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as! [String: Any]
        old["bluetooth"] = nil
        #expect(try JSONDecoder().decode(CallReport.self, from: JSONSerialization.data(withJSONObject: old)).bluetooth == nil)
    }

    // MARK: CLI

    @Test func parsesTheCommand() throws {
        #expect(try BluetoothCommand.parse(["bluetooth"]) == .devices(json: false))
        #expect(try BluetoothCommand.parse(["bluetooth", "--json"]) == .devices(json: true))
        #expect(try BluetoothCommand.parse(["bluetooth", "audio"]) == .audio(json: false))
        #expect(try BluetoothCommand.parse(["bluetooth", "audio", "--json"]) == .audio(json: true))
        #expect(try BluetoothCommand.parse(["bluetooth", "--json", "audio"]) == .audio(json: true))
        #expect(try BluetoothCommand.parse(["bluetooth", "--audio"]) == .audio(json: false))
        #expect(throws: DiagnosticError.self) { try BluetoothCommand.parse(["bluetooth", "audio", "now"]) }
        #expect(throws: DiagnosticError.self) { try BluetoothCommand.parse(["bluetooth", "airpods"]) }
    }
}
