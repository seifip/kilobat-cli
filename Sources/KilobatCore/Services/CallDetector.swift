import CoreAudio
import Foundation

/// Which app is on a call: a calling app or a browser that holds the microphone. Read from Core Audio's list of
/// processes running audio input, which needs no permission and never touches the audio itself.
public enum CallDetector {
    public struct Call: Equatable, Sendable {
        public let app: String
        public let browser: Bool
        /// Bundle-ID prefixes and process names whose traffic is the call's own, so it is never blamed for a freeze.
        public let own: [String]
    }

    /// Bundle-ID prefixes of calling apps, the name to show, and other processes that carry their calls.
    static let apps: [(prefixes: [String], name: String, browser: Bool, carriers: [String])] = [
        (["us.zoom."], "Zoom", false, []),
        (["com.microsoft.teams"], "Microsoft Teams", false, []),
        (["com.apple.FaceTime", "com.apple.avconferenced"], "FaceTime", false, ["avconferenced", "identityservicesd"]),
        (["com.tinyspeck.slackmacgap"], "Slack", false, []),
        (["com.cisco.webex", "Cisco-Systems.Spark"], "Webex", false, []),
        (["com.hnc.Discord"], "Discord", false, []),
        (["com.skype."], "Skype", false, []),
        (["net.whatsapp.WhatsApp", "desktop.WhatsApp"], "WhatsApp", false, []),
        (["ru.keepcoder.Telegram", "org.telegram.desktop"], "Telegram", false, []),
        (["org.whispersystems.signal-desktop"], "Signal", false, []),
        (["com.google.Chrome"], "Chrome", true, []),
        (["company.thebrowser.Browser"], "Arc", true, []),
        (["company.thebrowser.dia"], "Dia", true, []),
        (["com.microsoft.edgemac"], "Edge", true, []),
        (["org.mozilla.firefox"], "Firefox", true, []),
        (["com.brave.Browser"], "Brave", true, []),
        (["com.apple.Safari", "com.apple.WebKit"], "Safari", true, []),
    ]

    /// The call for these microphone users, preferring a calling app over a browser.
    public static func call(microphone bundleIDs: [String]) -> Call? {
        let matches = apps.filter { entry in bundleIDs.contains { id in entry.prefixes.contains { id.hasPrefix($0) } } }
        guard let entry = matches.first(where: { !$0.browser }) ?? matches.first else { return nil }
        return Call(app: entry.name, browser: entry.browser, own: entry.prefixes + entry.carriers)
    }

    /// Bundle IDs of the processes recording audio right now; nil where macOS doesn't list audio processes.
    public static func microphoneUsers() -> [String]? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return nil }
        return objects.compactMap { object in
            var input: UInt32 = 0
            guard read(object, kAudioProcessPropertyIsRunningInput, &input), input != 0 else { return nil }
            var bundle: Unmanaged<CFString>?
            guard read(object, kAudioProcessPropertyBundleID, &bundle), let id = bundle?.takeRetainedValue() as String?, !id.isEmpty else { return nil }
            return id
        }
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }
}
