import Foundation

/// `kilobat devices`: what it was asked to do, parsed apart from running it so the parsing can be tested.
public enum DeviceCommand: Equatable, Sendable {
    /// The neighbour cache with each device's standing; `all` adds remembered devices that aren't here now.
    case list(all: Bool, bonjour: Bool, json: Bool)
    /// An empty name removes it.
    case name(mac: String, name: String)
    case mark(mac: String, verdict: DeviceVerdict)

    public static let usage = "Use devices [--all] [--bonjour] [--json], devices name <MAC> <name> or devices mark <MAC> mine|unknown|ignored."

    /// `args` starts with "devices". A piped run appends --json, which naming and marking ignore.
    public static func parse(_ args: [String]) throws -> DeviceCommand {
        let rest = Array(args.dropFirst())
        switch rest.first {
        case "name":
            let words = rest.dropFirst().filter { $0 != "--json" }
            guard words.count >= 2, let mac = MACAddress.normalized(words[words.startIndex]) else {
                throw DiagnosticError("Use devices name <MAC-address> <name>; an empty name (\"\") removes it.")
            }
            return .name(mac: mac, name: words.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines))
        case "mark":
            let words = rest.dropFirst().filter { $0 != "--json" }
            guard words.count == 2, let mac = MACAddress.normalized(words[words.startIndex]),
                  let verdict = DeviceVerdict(rawValue: words[words.startIndex + 1].lowercased()) else {
                throw DiagnosticError("Use devices mark <MAC-address> mine|unknown|ignored.")
            }
            return .mark(mac: mac, verdict: verdict)
        default:
            let flags: Set<String> = ["--all", "--bonjour", "--json"]
            guard let unexpected = rest.first(where: { !flags.contains($0) }) else {
                return .list(all: rest.contains("--all"), bonjour: rest.contains("--bonjour"), json: rest.contains("--json"))
            }
            throw DiagnosticError("Unexpected '\(unexpected)'. " + usage)
        }
    }
}

/// One device for `kilobat devices --json` and MCP list_devices: the neighbour cache's fields, plus what Kilobat
/// remembers about it on this network.
public struct DeviceListing: Codable, Sendable, Equatable {
    public let address: String
    public let mac: String
    public let interface: String
    /// The name to show: the person's, else the device's own, else its maker's, else its address.
    public let name: String
    /// new (joined since Kilobat began watching, not answered yet), known (yours, or there when watching began),
    /// unknown (you said you don't know it) or ignored; nil when Kilobat hasn't recorded this network.
    public let status: KnownDevice.Status?
    public let verdict: DeviceVerdict?
    /// The name the person gave it.
    public let friendlyName: String?
    public let hostname: String?
    public let vendor: String?
    /// A private (randomised) Wi-Fi address, which has no maker and may change.
    public let privateAddress: Bool
    public let firstSeen: Date?
    public let lastSeen: Date?
    /// In the neighbour cache right now.
    public let present: Bool

    /// The cache's rows annotated from `network`; with `all`, also the devices it remembers that aren't in the cache.
    public static func rows(live: [LANDevice], network: DeviceNetwork?, names: [String: String], all: Bool = false) -> [DeviceListing] {
        var listed: Set<String> = []
        var rows: [DeviceListing] = live.map { row in
            let mac = MACAddress.normalized(row.mac) ?? row.mac.lowercased()
            let known = network?.index(of: mac).map { network!.devices[$0] }
            if let known { listed.insert(known.mac) }
            let given = known?.name ?? names[mac] ?? names[row.mac]
            return DeviceListing(address: row.address, mac: mac, interface: row.interface,
                                 name: given ?? known?.label ?? (row.name == row.address ? row.address : row.name),
                                 status: known?.status, verdict: known?.verdict, friendlyName: given, hostname: known?.hostname, vendor: known?.vendor,
                                 privateAddress: MACAddress.locallyAdministered(mac), firstSeen: known?.firstSeen, lastSeen: known?.lastSeen, present: true)
        }
        if all, let network {
            for device in network.devices where !listed.contains(device.mac) {
                rows.append(DeviceListing(address: device.address ?? "", mac: device.mac, interface: "", name: device.label, status: device.status, verdict: device.verdict,
                                          friendlyName: device.name, hostname: device.hostname, vendor: device.vendor, privateAddress: device.privateAddress,
                                          firstSeen: device.firstSeen, lastSeen: device.lastSeen, present: false))
            }
        }
        return rows
    }
}
