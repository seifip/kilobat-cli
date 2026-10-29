import Foundation
import Testing
@testable import KilobatCore

struct StutterTests {
    /// 400 pings at 50 ms around a 5 ms floor, with a 450 ms stall every `period` seconds that the next probes queue behind.
    private func series(period: Double?, count: Int = 400, seed: UInt64 = 7) -> [Double?] {
        var random = SeededRandom(seed)
        var samples: [Double?] = (0..<count).map { _ in 4 + Double(random.next() % 300) / 100 }
        if let period {
            var time = 0.4
            while Int(time / 0.05) < count {
                for (offset, value) in [450.0, 400, 350].enumerated() where Int(time / 0.05) + offset < count { samples[Int(time / 0.05) + offset] = value }
                time += period
            }
        }
        return samples
    }

    @Test func percentilesInterpolateBetweenRanks() {
        #expect(StutterTest.percentile([1, 2, 3, 4], 50) == 2.5)
        #expect(StutterTest.percentile([10], 99) == 10)
        #expect(StutterTest.percentile([], 50) == nil)
        let values = (1...100).map(Double.init)
        #expect(StutterTest.percentile(values, 95)! == 95.05)
        #expect(StutterTest.percentile(values, 100) == 100)
    }
    @Test func consecutiveSlowRepliesAreOneSpike() {
        let samples: [Double?] = [5, 5, 5, 450, 400, nil, 350, 5, 5, 60, 5, 40, 5]
        let spikes = StutterTest.spikes(samples, interval: 0.05)
        #expect(spikes.count == 2)
        #expect(abs(spikes[0].at - 0.15) < 1e-9 && spikes[0].peak == 450 && spikes[0].samples == 3)
        // 60 ms is over both 3× the 5 ms median and 50 ms; 40 ms is under 50 ms.
        #expect(spikes[1].peak == 60)
        // On a slow link 3× the median sets the bar, not 50 ms.
        #expect(StutterTest.spikes([30, 30, 30, 80, 30], interval: 0.05).isEmpty)
    }
    @Test func findsASpikeEverySecond() {
        let result = StutterTest.analyze(series(period: 1.0), target: "router", host: "192.168.1.1")
        #expect(result.spikes.count == 20)
        #expect(abs(result.periodSeconds! - 1.0) < 0.06)
        #expect(result.pattern == .periodic)
        #expect(result.verdict.hasPrefix("Regular spikes about every second on your local network, up to 450 ms."))
        #expect(result.verdict.contains("AirDrop/AWDL"))
        #expect(result.p50! < 8 && result.max == 450)
    }
    @Test func periodicityToleratesAMissedSpike() {
        var times = stride(from: 0.5, to: 20, by: 2.5).map { $0 }
        times.remove(at: 3)
        #expect(abs(StutterTest.period(times)! - 2.5) < 0.01)
        #expect(StutterTest.every(2.5) == "about every 2.5 s")
        #expect(StutterTest.every(1.04) == "about every second")
    }
    @Test func strayExtraSpikesDontHideTheBeat() {
        // Spike times from a real 10 s run to a router on 2.4 GHz: a beat near 1 s with two smaller strays.
        let times = [0.1, 1.1, 2.1, 2.8, 4.0, 5.0, 6.0, 7.0, 7.9, 8.3, 8.9, 9.9]
        #expect(abs(StutterTest.period(times)! - 0.98) < 0.01)
        #expect(StutterTest.period([0.5, 1.5, 2.5, 3.5]) == nil)
    }
    @Test func randomSpikesAreNotPeriodic() {
        var random = SeededRandom(42)
        var time = 0.0, times: [Double] = []
        for _ in 0..<20 { time += 0.1 + Double(random.next() % 2000) / 1000; times.append(time) }
        #expect(StutterTest.period(times) == nil)
        var samples = series(period: nil)
        for spike in times where Int(spike / 0.05) < samples.count { samples[Int(spike / 0.05)] = 300 }
        let result = StutterTest.analyze(samples, target: "router", host: "r")
        #expect(result.pattern == .irregular)
        #expect(result.verdict.contains("irregular"))
    }
    @Test func steadyLinkHasNoSpikes() {
        let result = StutterTest.analyze(series(period: nil), target: "router", host: "r")
        #expect(result.spikes.isEmpty && result.periodSeconds == nil && result.pattern == .steady)
        #expect(result.verdict.hasPrefix("No spikes on your local network."))
        #expect(StutterTest.analyze([nil, nil], target: "internet", host: "1.1.1.1").pattern == .noReplies)
    }
    @Test func verdictNamesWhatUsesTheAirDropLink() {
        let busy = AWDLStatus(available: true, up: true, active: true, users: ["Universal Control"], processes: ["UniversalControl"])
        #expect(StutterTest.analyze(series(period: 1), target: "router", host: "r", awdl: busy).verdict.contains("the AirDrop link was in use by Universal Control"))
        let paused = AWDLStatus(available: true, up: false, active: false)
        #expect(StutterTest.analyze(series(period: 1), target: "router", host: "r", awdl: paused).verdict.contains("isn't the cause"))
    }
    @Test func everyOtherMissingReplyIsRateLimitingNotLoss() {
        let limited: [Double?] = (0..<200).map { $0 > 40 && $0 % 2 == 0 ? nil : 5 }
        let result = StutterTest.analyze(limited, target: "router", host: "r")
        #expect(result.pingLimited)
        #expect(result.verdict.contains("rate limiting"))
        let dropout: [Double?] = (0..<200).map { (100..<150).contains($0) ? nil : 5 }
        #expect(!StutterTest.analyze(dropout, target: "router", host: "r").pingLimited)
    }
    @Test func parsesPingRepliesBySequence() {
        let output = """
        64 bytes from 192.168.1.1: icmp_seq=0 ttl=64 time=4.1 ms
        Request timeout for icmp_seq 1
        64 bytes from 192.168.1.1: icmp_seq=3 ttl=64 time=480.5 ms
        64 bytes from 192.168.1.1: icmp_seq=2 ttl=64 time=520.0 ms
        64 bytes from 192.168.1.1: icmp_seq=2 ttl=64 time=521.0 ms (DUP!)
        64 bytes from 192.168.1.1: icmp_seq=9 ttl=64 time=4.0 ms
        """
        #expect(StutterTest.parse(output, count: 5) == [4.1, nil, 520, 480.5, nil])
    }
    @Test func comparisonSaysWhetherThePauseHelped() {
        let before = StutterTest.analyze(series(period: 1), target: "router", host: "r")
        let after = StutterTest.analyze(series(period: nil), target: "router", host: "r")
        #expect(StutterTest.comparison(before: before, after: after).hasPrefix("With the pause on, spikes dropped from 20 to 0"))
        #expect(StutterTest.comparison(before: before, after: before).contains("unlikely to be the cause"))
        #expect(StutterTest.comparison(before: after, after: after).hasPrefix("There were few spikes"))
    }

    // MARK: Low-latency hold

    @Test func holdEndsOnExpiryOrWhenItsAppQuits() {
        let start = Date(timeIntervalSince1970: 0)
        let timed = LowLatencyHold(started: start, seconds: 3600, owner: 1)
        #expect(timed.ending(now: start.addingTimeInterval(3599), appRunning: false) == nil)
        #expect(timed.ending(now: start.addingTimeInterval(3600), appRunning: true) == .expired)
        #expect(timed.ticks == 1800)
        #expect(timed.label(now: start.addingTimeInterval(600)) == "50 min left")
        #expect(timed.label(now: start) == "1 h 0 min left")
        let tied = LowLatencyHold(started: start, seconds: nil, app: (42, "Zoom"), owner: 1)
        #expect(tied.expires == start.addingTimeInterval(4 * 3600))
        #expect(tied.ending(now: start.addingTimeInterval(60), appRunning: true) == nil)
        #expect(tied.ending(now: start.addingTimeInterval(60), appRunning: false) == .appQuit)
        #expect(tied.ending(now: start.addingTimeInterval(4 * 3600), appRunning: true) == .expired)
        #expect(tied.label() == "until Zoom quits")
        #expect(LowLatencyHold(started: start, seconds: 10 * 3600, owner: 1).expires == start.addingTimeInterval(4 * 3600))
    }
    @Test func holdLengthsParseUpToFourHours() {
        #expect(LowLatencyHold.seconds("15m") == 900)
        #expect(LowLatencyHold.seconds("2h") == 7200)
        #expect(LowLatencyHold.seconds("4h") == 14400)
        #expect(LowLatencyHold.seconds("5h") == nil)
        #expect(LowLatencyHold.seconds("0m") == nil)
        #expect(LowLatencyHold.seconds("90s") == nil)
        #expect(LowLatencyHold.seconds("h") == nil)
    }
    @Test func recoveryRestoresOnlyAnOrphanedPause() {
        let marker = LowLatencyHold(seconds: 900, owner: 1)
        #expect(LowLatencyHold.recovery(marker: nil, awdlUp: false, ownerAlive: false) == .none)
        #expect(LowLatencyHold.recovery(marker: marker, awdlUp: false, ownerAlive: true) == .none)
        #expect(LowLatencyHold.recovery(marker: marker, awdlUp: false, ownerAlive: false) == .restore)
        #expect(LowLatencyHold.recovery(marker: marker, awdlUp: true, ownerAlive: false) == .clear)
        #expect(LowLatencyHold.recovery(marker: marker, awdlUp: nil, ownerAlive: false) == .clear)
    }

    // MARK: AirDrop link and Bluetooth

    @Test func interfaceFlagsAndStatus() {
        let active = "awdl0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n\tstatus: active\n"
        #expect(NearbyRadios.parseInterface(active)! == (true, true))
        let down = "awdl0: flags=8822<BROADCAST,SMART,SIMPLEX,MULTICAST> mtu 1500\n\tstatus: inactive\n"
        #expect(NearbyRadios.parseInterface(down)! == (false, false))
        #expect(NearbyRadios.parseInterface("ifconfig: interface awdl0 does not exist") == nil)
    }
    @Test func lsofScopedAddressesNameTheProcesses() {
        let lsof = """
        p730
        csharingd
        f24
        n*:65253
        f25
        n[fe80:d::f08c:f4ff:fe48:286d]:62105->[fe80:d::9488:cfff:fefa:5578]:64916
        p812
        cidentityservicesd
        f9
        n[fe80:14::c0a8:502d:fc3f:93a7]:1024->[fe80:14::6e87:f2b9:6aae:8fdd]:1024
        p900
        cUniversalControl
        f4
        n[fe80::1%awdl0]:5000
        p901
        crapportd
        f3
        n[fe80:e::1]:49152
        p902
        cCodex\\x20Helper
        f3
        n[fe80::1]:80
        """
        let processes = NearbyRadios.scopedProcesses(lsof: lsof, scopes: [13, 14], names: ["awdl0", "llw0"])
        #expect(processes == ["UniversalControl", "rapportd", "sharingd"])
        #expect(processes.map(NearbyRadios.feature) == ["Universal Control", "Continuity and Handoff", "AirDrop"])
        #expect(NearbyRadios.feature("SidecarRelay") == "Sidecar")
        #expect(NearbyRadios.feature("ScreenContinuityAgent") == "iPhone Mirroring")
        #expect(NearbyRadios.feature("SomethingElse") == "SomethingElse")
        let status = AWDLStatus(available: true, up: true, active: true, users: ["Universal Control", "AirDrop"])
        #expect(status.summary == "AirDrop link active · used by Universal Control and AirDrop")
        #expect(AWDLStatus(available: true, up: false, active: false).summary == "AirDrop link paused")
    }
    @Test func bluetoothKindsAndBandSharingAdvice() {
        #expect(BluetoothDevice.kind(major: 4, minor: 6, name: "Philip's AirPods Pro") == .headphones)
        #expect(BluetoothDevice.kind(major: 4, minor: 5, name: "Kitchen") == .speaker)
        #expect(BluetoothDevice.kind(major: 5, minor: 0x10, name: "Magic Keyboard") == .keyboard)
        #expect(BluetoothDevice.kind(major: 5, minor: 0x20, name: "Magic Trackpad") == .trackpad)
        #expect(BluetoothDevice.kind(major: 5, minor: 0x20, name: "MX Master") == .mouse)
        #expect(BluetoothDevice.kind(major: 2, minor: 3, name: "iPhone") == .phone)
        #expect(BluetoothDevice.kind(major: 0, minor: 0, name: "Philip’s Apple Watch") == .watch)
        #expect(BluetoothDevice.kind(major: 7, minor: 1, name: "Fitbit") == .watch)
        #expect(BluetoothDevice.kind(major: 1, minor: 7, name: "Tab") == .tablet)
        #expect(BluetoothDevice.kind(major: 1, minor: 3, name: "Philip’s MacBook Pro") == .computer)
        #expect(BluetoothDevice.kind(type: nil, name: "Philip’s iPhone") == .phone)
        #expect(BluetoothDevice.kind(type: nil, name: "Philip’s iPad") == .tablet)
        #expect(BluetoothDevice.kind(type: "Headphones", name: "Philip的AirPods Pro") == .headphones)
        #expect(BluetoothDevice.kind(type: nil, name: "SEIFI-P17") == .other)
        // A phone whose class of device says nothing still offers the hands-free gateway or phonebook.
        #expect(BluetoothDevice.kind(major: 0, minor: 0, name: "SEIFI-P17", services: [0x1105, 0x111F]) == .phone)
        #expect(BluetoothDevice.kind(major: 0, minor: 0, name: "SEIFI-P17", services: [0x110B]) == .other)
        #expect(BluetoothDevice(id: "x", name: "AirPods Pro", kind: BluetoothDevice.kind(type: "Headphones", name: "AirPods Pro"), connected: true).symbol == "airpods")
        #expect(BluetoothDevice(id: "y", name: "Sony WH-1000XM5", kind: .headphones, connected: true).symbol == "headphones")
        let pods = BluetoothDevice(id: "a", name: "AirPods Pro", kind: .headphones, connected: true)
        let keyboard = BluetoothDevice(id: "b", name: "Magic Keyboard", kind: .keyboard, connected: true)
        let watch = BluetoothDevice(id: "c", name: "Watch", kind: .other, connected: true)
        let off = BluetoothDevice(id: "d", name: "Old Speaker", kind: .speaker, connected: false)
        #expect(NearbyRadios.coexistence(wifiBand: "5 GHz", devices: [pods]) == nil)
        #expect(NearbyRadios.coexistence(wifiBand: "2.4 GHz", devices: [watch, off]) == nil)
        #expect(NearbyRadios.coexistence(wifiBand: "2.4 GHz", devices: [pods, keyboard, watch], fasterNetwork: "Home 5G")
                == "Your Wi-Fi is on 2.4 GHz, the band AirPods Pro and Magic Keyboard also use. Calls and audio may stutter. Switch to Home 5G (5 GHz) if you can.")
    }
    @Test func systemProfilerListsConnectedFirst() {
        let json = #"{"SPBluetoothDataType":[{"device_connected":[{"AirPods Pro":{"device_address":"74:77","device_minorType":"Headphones"}}],"device_not_connected":[{"Apple Watch":{"device_address":"9C:1A"}},{"Magic Keyboard":{"device_address":"28:D5","device_minorType":"Keyboard"}}]}]}"#
        let devices = NearbyRadios.parseSystemProfiler(Data(json.utf8))
        #expect(devices.map(\.name) == ["AirPods Pro", "Apple Watch", "Magic Keyboard"])
        #expect(devices.map(\.kind) == [.headphones, .watch, .keyboard])
        #expect(devices.first?.connected == true)
        #expect(NearbyRadios.parseSystemProfiler(Data("nope".utf8)).isEmpty)
    }
    @MainActor @Test func togglingABluetoothDeviceReportsFailurePlainly() async {
        let state = BluetoothState()
        state.devices = [BluetoothDevice(id: "a", name: "AirPods Pro", kind: .headphones, connected: false)]
        state.link = { _, connect in connect ? 0 : -536_870_212 }
        await state.toggle(state.devices[0])
        #expect(state.devices[0].connected && state.error == nil && state.busy.isEmpty)
        await state.toggle(state.devices[0])
        #expect(state.devices[0].connected)
        #expect(state.error == "AirPods Pro didn't disconnect. Try again, or use Bluetooth Settings.")
    }
}

/// A small deterministic generator so the synthetic series are the same on every run.
struct SeededRandom {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
}
