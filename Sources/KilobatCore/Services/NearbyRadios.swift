import AppKit
import Foundation
import Observation

/// The AirDrop link (AWDL): whether it is up and which features hold sockets on it.
public struct AWDLStatus: Codable, Sendable, Equatable {
    public var available: Bool
    public var up: Bool
    public var active: Bool
    public var users: [String]
    public var processes: [String]
    public init(available: Bool, up: Bool, active: Bool, users: [String] = [], processes: [String] = []) {
        self.available = available; self.up = up; self.active = active; self.users = users; self.processes = processes
    }
    public var detail: String {
        guard available else { return "Not on this Mac" }
        guard up else { return "Paused" }
        guard active || !users.isEmpty else { return "Idle" }
        return "Active" + (users.isEmpty ? "" : " · used by " + NearbyRadios.list(users))
    }
    public var summary: String { available ? "AirDrop link " + detail.prefix(1).lowercased() + detail.dropFirst() : "No AirDrop link on this Mac" }
}

public enum AirDropVisibility: String, Codable, Sendable, CaseIterable {
    case everyone = "Everyone", contacts = "Contacts Only", off = "Off"
    public var key: String { switch self { case .everyone: "everyone"; case .contacts: "contacts"; case .off: "off" } }
    public var title: String { self == .off ? "Receiving off" : rawValue }
}

public struct BluetoothDevice: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case headphones, speaker, keyboard, mouse, trackpad, phone, watch, tablet, computer, other
        public var title: String { self == .other ? "Other device" : rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }
    public let id: String
    public let name: String
    public var kind: Kind
    public var connected: Bool
    public init(id: String, name: String, kind: Kind, connected: Bool) { self.id = id; self.name = name; self.kind = kind; self.connected = connected }
    public var audio: Bool { kind == .headphones || kind == .speaker }
    public var input: Bool { kind == .keyboard || kind == .mouse || kind == .trackpad }
    public var symbol: String {
        switch kind {
        case .headphones: name.localizedCaseInsensitiveContains("airpods") ? "airpods" : "headphones"
        case .speaker: "hifispeaker"
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .phone: "iphone"
        case .watch: "applewatch"
        case .tablet: "ipad"
        case .computer: ["macbook", "laptop", "notebook", "thinkpad"].contains { name.localizedCaseInsensitiveContains($0) } ? "laptopcomputer" : "desktopcomputer"
        case .other: "bluetooth"
        }
    }
    /// From the Bluetooth class of device: major 1 computer (minor 6 wearable, 7 tablet), 2 phone, 4 audio,
    /// 5 peripheral (keyboard and pointing bits in the minor class), 7 wearable.
    /// `services` are the 16-bit service classes the device offered at pairing; a phone offers the hands-free
    /// gateway, phonebook or messages even when its class of device says nothing.
    public static func kind(major: UInt32, minor: UInt32, name: String, services: [UInt16] = []) -> Kind {
        let named = kind(type: nil, name: name)
        if named == .other, ![1, 4, 5].contains(major), !Set(services).isDisjoint(with: [0x111F, 0x112F, 0x1132]) { return .phone }
        switch major {
        case 1: return [.watch, .tablet, .phone].contains(named) ? named : minor == 6 ? .watch : minor == 7 ? .tablet : .computer
        case 2: return .phone
        case 7: return minor == 1 ? .watch : named
        case 4: return [5, 0x0A].contains(minor) ? .speaker : .headphones
        case 5:
            if minor & 0x10 != 0 { return .keyboard }
            if minor & 0x20 != 0 { return name.localizedCaseInsensitiveContains("trackpad") ? .trackpad : .mouse }
            return .other
        default: return named
        }
    }
    /// From system_profiler's minor type, falling back to the name. Apple names its devices plainly
    /// ("Philip's Apple Watch", "iPhone"), which is all there is when the class of device says nothing.
    public static func kind(type: String?, name: String) -> Kind {
        let text = ((type ?? "") + " " + name).lowercased()
        if ["headphone", "headset", "airpods", "beats", "buds"].contains(where: text.contains) { return .headphones }
        if text.contains("speaker") || text.contains("homepod") { return .speaker }
        if text.contains("keyboard") { return .keyboard }
        if text.contains("trackpad") { return .trackpad }
        if text.contains("mouse") { return .mouse }
        if text.contains("watch") { return .watch }
        if text.contains("ipad") || text.contains("tablet") { return .tablet }
        if ["macbook", "imac", "mac mini", "mac pro", "mac studio", "laptop", "desktop", "computer"].contains(where: text.contains) { return .computer }
        if text.contains("phone") { return .phone }
        return .other
    }
}

public enum NearbyRadios {
    public static func list(_ names: [String]) -> String {
        names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
    /// `up` is false while the interface is down (paused); `active` is the link status.
    public static func parseInterface(_ output: String) -> (up: Bool, active: Bool)? {
        guard let flags = output.split(separator: "\n").first, flags.contains("flags=") else { return nil }
        let up = flags.contains("<UP,") || flags.contains(",UP,") || flags.contains("<UP>")
        return (up, up && output.contains("status: active"))
    }
    /// Commands with a socket scoped to one of `scopes`, from `lsof -F pcn`. lsof writes a scoped
    /// link-local address with its interface index after fe80 (fe80:d:: is index 13), or as %awdl0.
    public static func scopedProcesses(lsof: String, scopes: Set<Int>, names: Set<String>) -> [String] {
        var command = "", found: Set<String> = []
        for line in lsof.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            if tag == "c" { command = value.replacingOccurrences(of: "\\x20", with: " ") }
            guard tag == "n", !command.isEmpty else { continue }
            if names.contains(where: { value.contains("%" + $0) }) { found.insert(command); continue }
            for scope in DiagnosticProbe.matches("\\[fe80:([0-9a-fA-F]{1,4}):", in: value).compactMap({ Int($0, radix: 16) }) where scopes.contains(scope) {
                found.insert(command)
            }
        }
        return found.sorted()
    }
    /// What a person would call the feature behind a process on the AirDrop link.
    public static func feature(_ process: String) -> String {
        let name = process.lowercased()
        if name == "sharingd" { return "AirDrop" }
        if name.hasPrefix("universalcontrol") { return "Universal Control" }
        if name.hasPrefix("sidecar") { return "Sidecar" }
        if name.contains("screencontinuity") || name.contains("iphone mirroring") { return "iPhone Mirroring" }
        if name == "rapportd" { return "Continuity and Handoff" }
        if name.hasPrefix("continuitycapture") { return "Continuity Camera" }
        if name.hasPrefix("airplay") { return "AirPlay" }
        return process
    }
    public static func awdlStatus() async -> AWDLStatus {
        let interface = await CommandRunner.run("/sbin/ifconfig", ["awdl0"])
        guard interface.status == 0, let state = parseInterface(interface.output) else { return AWDLStatus(available: false, up: false, active: false) }
        guard state.up else { return AWDLStatus(available: true, up: false, active: false) }
        let indices: [Int] = ["awdl0", "llw0"].map { (name: String) in Int(if_nametoindex(name)) }
        let scopes = Set(indices.filter { $0 > 0 })
        let sockets = await CommandRunner.run("/usr/sbin/lsof", ["-nP", "-i6", "+c", "0", "-F", "pcn"], timeout: 5)
        let processes = scopedProcesses(lsof: sockets.output, scopes: scopes, names: ["awdl0", "llw0"])
        var users: [String] = []
        for feature in processes.map(feature) where !users.contains(feature) { users.append(feature) }
        return AWDLStatus(available: true, up: true, active: state.active, users: users, processes: processes)
    }

    /// The saved setting. Only System Settings can change it: sharingd doesn't apply a written
    /// preference and refuses other apps without Apple's entitlement.
    public static func airDropVisibility() -> AirDropVisibility? {
        (UserDefaults(suiteName: "com.apple.sharingd")?.string(forKey: "DiscoverableMode")).flatMap(AirDropVisibility.init(rawValue:))
    }
    public static let airDropSettings = URL(string: "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension")!
    public static func openAirDropSettings() { NSWorkspace.shared.open(airDropSettings) }

    public static func parseSystemProfiler(_ data: Data) -> [BluetoothDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controller = (root["SPBluetoothDataType"] as? [[String: Any]])?.first else { return [] }
        var devices: [BluetoothDevice] = []
        for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
            for entry in controller[key] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    let info = value as? [String: Any] ?? [:]
                    devices.append(BluetoothDevice(id: info["device_address"] as? String ?? name, name: name,
                                                   kind: BluetoothDevice.kind(type: info["device_minorType"] as? String, name: name), connected: connected))
                }
            }
        }
        return sorted(devices)
    }
    public static func sorted(_ devices: [BluetoothDevice]) -> [BluetoothDevice] {
        devices.sorted { $0.connected != $1.connected ? $0.connected : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    /// Bluetooth and 2.4 GHz Wi-Fi share the same radio band; audio and input devices are the ones you notice.
    public static func sharesBand(_ device: BluetoothDevice, wifiBand: String?) -> Bool {
        wifiBand == "2.4 GHz" && device.connected && (device.audio || device.input)
    }
    public static func coexistence(wifiBand: String?, devices: [BluetoothDevice], fasterNetwork: String? = nil) -> String? {
        let sharing = devices.filter { sharesBand($0, wifiBand: wifiBand) }.map(\.name)
        guard !sharing.isEmpty else { return nil }
        let move = fasterNetwork.map { "Switch to \($0) (5 GHz) if you can." } ?? "A 5 GHz network avoids that."
        return "Your Wi-Fi is on 2.4 GHz, the band \(list(sharing)) \(sharing.count == 1 ? "also uses" : "also use"). Calls and audio may stutter. " + move
    }
    /// Plain words for an IOReturn from opening or closing a Bluetooth connection.
    public static func connectionError(_ status: Int32, connecting: Bool, name: String) -> String? {
        guard status != 0 else { return nil }
        return connecting ? "\(name) didn't connect. Make sure it's on, nearby and not connected to another device." : "\(name) didn't disconnect. Try again, or use Bluetooth Settings."
    }
}

/// AirDrop link and visibility, refreshed on demand.
@MainActor @Observable public final class NearbyStore {
    public private(set) var awdl: AWDLStatus?
    public private(set) var visibility: AirDropVisibility?
    public private(set) var refreshing = false
    public init() {}
    public func refresh() async {
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        visibility = NearbyRadios.airDropVisibility()
        awdl = await NearbyRadios.awdlStatus()
    }
}

/// Bluetooth devices and connect/disconnect, with the IOBluetooth calls supplied by the app so this stays testable.
@MainActor @Observable public final class BluetoothState {
    public var devices: [BluetoothDevice] = []
    public private(set) var busy: Set<String> = []
    public var error: String?
    public var link: (@Sendable (String, Bool) async -> Int32)?
    public init() {}
    public func toggle(_ device: BluetoothDevice) async {
        guard let link, !busy.contains(device.id) else { return }
        busy.insert(device.id); error = nil
        let connecting = !device.connected
        let status = await link(device.id, connecting)
        busy.remove(device.id)
        if let message = NearbyRadios.connectionError(status, connecting: connecting, name: device.name) { error = message; return }
        if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index].connected = connecting }
        devices = NearbyRadios.sorted(devices)
    }
}
