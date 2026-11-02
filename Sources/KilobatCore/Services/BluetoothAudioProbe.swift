import CoreAudio
import CoreWLAN
import Foundation

/// Reads macOS's sound output from Core Audio: which device, whether it is Bluetooth, whether anything plays to it and
/// whether its microphone records. Needs no permission and never touches the sound itself.
///
/// Core Audio has no public count of Bluetooth dropouts: `kAudioDeviceProcessorOverload` reaches only the process whose
/// own audio callback overran, and the Bluetooth stack's retransmissions and buffer underruns stay inside bluetoothd and
/// coreaudiod. So Kilobat can't hear a crackle; it reads the conditions that cause one.
public enum BluetoothAudioProbe {
    public static func output() -> BluetoothAudioOutput? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var device = AudioObjectID(0), input = AudioObjectID(0)
        guard read(system, kAudioHardwarePropertyDefaultOutputDevice, &device), device != 0 else { return nil }
        var transport: UInt32 = 0
        guard read(device, kAudioDevicePropertyTransportType, &transport), BluetoothAudioOutput.transport(transport) != nil else { return nil }
        var running: UInt32 = 0, rate: Float64 = 0
        _ = read(device, kAudioDevicePropertyDeviceIsRunningSomewhere, &running)
        _ = read(device, kAudioDevicePropertyNominalSampleRate, &rate)
        var name: Unmanaged<CFString>?
        let label = read(device, kAudioObjectPropertyName, &name) ? (name?.takeRetainedValue() as String?) : nil
        var inputTransport: UInt32 = 0, inputRunning: UInt32 = 0
        if read(system, kAudioHardwarePropertyDefaultInputDevice, &input), input != 0 {
            _ = read(input, kAudioDevicePropertyTransportType, &inputTransport)
            _ = read(input, kAudioDevicePropertyDeviceIsRunningSomewhere, &inputRunning)
        }
        return BluetoothAudioOutput.reading(name: label ?? String(localized: "Bluetooth headphones"), outputTransport: transport, running: running != 0,
                                            sampleRate: rate > 0 ? rate : nil, inputTransport: inputTransport == 0 ? nil : inputTransport, inputRunning: inputRunning != 0)
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }

    /// Wi-Fi names macOS remembers. Reading them doesn't scan; without Location permission macOS may hide them.
    public static func knownNetworks() -> Set<String> {
        Set(CWWiFiClient.shared().interface()?.configuration()?.networkProfiles.compactMap { ($0 as? CWNetworkProfile)?.ssid } ?? [])
    }

    /// Bytes the Wi-Fi interface carried, both ways, for a rate between two readings.
    public static func wifiBytes(interface: String?) -> UInt64? {
        guard let interface, let counters = InterfaceCounters.read()?[interface] else { return nil }
        return counters.total
    }

    /// A scan young enough to judge crowding and a 5 GHz network by: from the last half hour.
    public static func recentScan(_ scans: [SavedScan], now: Date = Date()) -> [NearbyNetwork] {
        guard let last = scans.last, now.timeIntervalSince(last.date) <= 1800 else { return [] }
        return last.networks
    }
}
