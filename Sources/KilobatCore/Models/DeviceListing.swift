import Foundation

/// `kilobat devices`: what it was asked to do, parsed apart from running it so the parsing can be tested.
public enum DeviceCommand: Equatable, Sendable {
    /// The neighbour cache with each device's standing; `all` adds remembered devices that aren't here now.
    case list(all: Bool, bonjour: Bool, json: Bool)
    /// An empty name removes it.
    case name(mac: String, name: String)
    case mark(mac: String, verdict: DeviceVerdict)
    /// Nil goes back to Kilobat's own reading.
    case type(mac: String, type: DeviceType?)

    public static let usage = "Use devices [--all] [--bonjour] [--json], devices name <MAC> <name>, devices mark <MAC> mine|unknown|ignored or devices type <MAC> <type>|auto."
    static let typeWords = (DeviceType.allCases.map(\.rawValue) + ["auto"]).joined(separator: "|")

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
        case "type":
            let words = rest.dropFirst().filter { $0 != "--json" }
            guard words.count == 2, let mac = MACAddress.normalized(words[words.startIndex]) else {
                throw DiagnosticError("Use devices type <MAC-address> \(typeWords).")
            }
            let word = words[words.startIndex + 1].lowercased()
            if word == "auto" { return .type(mac: mac, type: nil) }
            guard let type = DeviceType.parse(word) else { throw DiagnosticError("Unknown type '\(word)'. Use one of \(typeWords).") }
            return .type(mac: mac, type: type)
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
    /// What kind of device it is: camera, doorbell, tv (TV or streaming stick), casting, speaker, printer, plug (smart
    /// plug or switch), hub, console, phone (phone or tablet), computer, drone (drone or action camera), router, nas or unknown.
    public let type: DeviceType
    /// set (the user chose it), high, medium or low; nil when the type is unknown.
    public let confidence: DeviceTypeConfidence?
    /// How the app says it: "Camera (Wyze)", "Probably a camera (Wyze)", "Maybe a smart plug or switch".
    public let typeLabel: String
    /// What gave the type away, such as "Google Cast" or "its maker".
    public let typeEvidence: String?
    /// HomeKit, Matter, Thread border router.
    public let tags: [DeviceTag]

    /// The cache's rows annotated from `network`; with `all`, also the devices it remembers that aren't in the cache.
    public static func rows(live: [LANDevice], network: DeviceNetwork?, names: [String: String], all: Bool = false) -> [DeviceListing] {
        var listed: Set<String> = []
        var rows: [DeviceListing] = live.map { row in
            let mac = MACAddress.normalized(row.mac) ?? row.mac.lowercased()
            let known = network?.index(of: mac).map { network!.devices[$0] }
            if let known { listed.insert(known.mac) }
            let given = known?.name ?? names[mac] ?? names[row.mac]
            let guess = known?.guess(router: known?.mac == network?.router) ?? .unknown
            return DeviceListing(address: row.address, mac: mac, interface: row.interface,
                                 name: given ?? known?.label ?? (row.name == row.address ? row.address : row.name),
                                 status: known?.status, verdict: known?.verdict, friendlyName: given, hostname: known?.hostname, vendor: known?.vendor,
                                 privateAddress: MACAddress.locallyAdministered(mac), firstSeen: known?.firstSeen, lastSeen: known?.lastSeen, present: true,
                                 type: guess.type, confidence: guess.confidence, typeLabel: guess.label, typeEvidence: guess.evidence, tags: known?.tags ?? [])
        }
        if all, let network {
            for device in network.devices where !listed.contains(device.mac) {
                let guess = device.guess(router: device.mac == network.router)
                rows.append(DeviceListing(address: device.address ?? "", mac: device.mac, interface: "", name: device.label, status: device.status, verdict: device.verdict,
                                          friendlyName: device.name, hostname: device.hostname, vendor: device.vendor, privateAddress: device.privateAddress,
                                          firstSeen: device.firstSeen, lastSeen: device.lastSeen, present: false,
                                          type: guess.type, confidence: guess.confidence, typeLabel: guess.label, typeEvidence: guess.evidence, tags: device.tags))
            }
        }
        return rows
    }
}
