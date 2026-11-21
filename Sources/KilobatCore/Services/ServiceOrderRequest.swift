import Foundation

// Compiled into Kilobat's helper too (KilobatPowerHelper, which runs as root), so Foundation only.

/// One network service as `networksetup -listnetworkserviceorder` lists it.
public struct NetworkServiceEntry: Codable, Equatable, Sendable {
    public var name: String
    public var hardwarePort: String?
    /// The BSD interface, en0 or en8; nil for a VPN or a service with no device.
    public var device: String?
    public var enabled: Bool
    public init(name: String, hardwarePort: String? = nil, device: String? = nil, enabled: Bool = true) {
        self.name = name; self.hardwarePort = hardwarePort; self.device = device; self.enabled = enabled
    }
}

/// The network service order: which service macOS reaches the internet through when more than one is connected. The
/// first connected service in the order gets the default route and DNS; the others keep their own subnets, so a Mac can
/// reach a robot's or camera's Wi-Fi while a tethered phone carries the internet.
public enum ServiceOrder {
    /// `networksetup -listnetworkserviceorder`:
    ///
    ///     An asterisk (*) denotes that a network service is disabled.
    ///     (1) iPhone USB
    ///     (Hardware Port: iPhone USB, Device: en8)
    ///
    ///     (*) Bluetooth PAN
    ///     (Hardware Port: Bluetooth PAN, Device: en5)
    public static func parse(_ output: String) -> [NetworkServiceEntry] {
        var entries: [NetworkServiceEntry] = []
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("("), let close = line.firstIndex(of: ")") else { continue }
            let tag = line[line.index(after: line.startIndex)..<close]
            if line.hasPrefix("(Hardware Port:") {
                guard !entries.isEmpty else { continue }
                let body = line.dropFirst().dropLast(line.hasSuffix(")") ? 1 : 0)
                for part in body.components(separatedBy: ", ") {
                    if part.hasPrefix("Hardware Port: ") { entries[entries.count - 1].hardwarePort = String(part.dropFirst("Hardware Port: ".count)) }
                    if part.hasPrefix("Device: ") {
                        let device = String(part.dropFirst("Device: ".count)).trimmingCharacters(in: .whitespaces)
                        entries[entries.count - 1].device = device.isEmpty ? nil : device
                    }
                }
                continue
            }
            guard tag == "*" || Int(tag) != nil else { continue }
            let name = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            entries.append(NetworkServiceEntry(name: name, enabled: tag != "*"))
        }
        return entries
    }

    /// The order with `service` moved to the top, everything else as it was; nil when it isn't listed or is already first.
    public static func promoting(_ service: String, in order: [String]) -> [String]? {
        guard order.contains(service), order.first != service else { return nil }
        return [service] + order.filter { $0 != service }
    }

    /// The order to put back: the saved one, for the services still listed, with any added since kept in their current
    /// place relative to the others. Nil when `current` no longer has `promoted` first: the order was changed elsewhere
    /// (System Settings, another app), and Kilobat leaves the person's own choice alone.
    public static func restored(saved: [String], current: [String], promoted: String) -> [String]? {
        guard current.first == promoted else { return nil }
        let listed = Set(current)
        var result = saved.filter { listed.contains($0) }
        let known = Set(result)
        // A service that's new since the switch goes after the one it follows now, or first if it leads.
        for (index, name) in current.enumerated() where !known.contains(name) {
            if let before = current[..<index].last(where: { result.contains($0) && $0 != promoted }), let at = result.firstIndex(of: before) {
                result.insert(name, at: result.index(after: at))
            } else if name == promoted {
                result.append(name)
            } else {
                result.insert(name, at: 0)
            }
        }
        return result == current ? nil : result
    }
}

/// What the app asks Kilobat's helper to do: the whole service order, as `networksetup -ordernetworkservices` needs
/// it, checked against what's there now. The helper checks it again, so it can only ever reorder the listed services.
public struct ServiceOrderRequest: Codable, Equatable, Sendable {
    public var order: [String]
    /// The order the app read before asking; the change is refused if it differs now.
    public var expected: [String]
    public init(order: [String], expected: [String]) { self.order = order; self.expected = expected }

    /// networksetup's arguments, or nil unless `order` names exactly the services listed now, each once, and the order
    /// now is the one the app saw.
    public func arguments(current: [String]) -> [String]? {
        guard !order.isEmpty, order.count <= 64, order.count == current.count, Set(order) == Set(current), Set(order).count == order.count,
              current == expected,
              order.allSatisfy({ !$0.isEmpty && $0.count <= 128 && !$0.hasPrefix("-") && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) })
        else { return nil }
        return ["-ordernetworkservices"] + order
    }
}
