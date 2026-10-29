import Foundation

/// Where an app's open connections go and how much each has moved, from one nettop snapshot.
/// Byte counts are since each connection opened; closed connections drop out.
public struct OpenDestination: Identifiable, Sendable, Equatable {
    public let address: String
    public var ports: Set<String>
    public var protocols: Set<String>
    public var received: UInt64
    public var sent: UInt64
    public var connections: Int
    public var id: String { address }
    public var total: UInt64 { received + sent }
}

public enum OpenConnections {
    public static func sample(pids: Set<Int32>) async -> [OpenDestination] {
        guard !pids.isEmpty else { return [] }
        return await Task.detached(priority: .utility) {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
            process.arguments = ["-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"]
            process.standardOutput = output; process.standardError = Pipe(); process.standardInput = Pipe()
            guard (try? process.run()) != nil else { return [] }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return parse(String(decoding: data, as: UTF8.self), pids: pids)
        }.value
    }

    /// Process rows (`name.pid,in,out,`) are followed by their connection rows (`tcp4 local<->remote,in,out,`).
    static func parse(_ text: String, pids: Set<Int32>) -> [OpenDestination] {
        var current: Int32?, destinations: [String: OpenDestination] = [:]
        for line in text.split(separator: "\n") {
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.count >= 3 else { continue }
            let head = columns[0]
            guard let arrow = head.range(of: "<->") else {
                current = NettopMonitor.parseRow(String(line)).map(\.pid)
                continue
            }
            guard let pid = current, pids.contains(pid), let space = head.firstIndex(of: " ") else { continue }
            let proto = String(head[..<space])
            let (address, port) = TrafficRoute.endpoint(head[arrow.upperBound...], v6: proto.hasSuffix("6"))
            guard address != "*", !isLoopback(address), port != "*", !port.isEmpty else { continue }
            let received = UInt64(columns[1]) ?? 0, sent = UInt64(columns[2]) ?? 0
            var entry = destinations[address] ?? OpenDestination(address: address, ports: [], protocols: [], received: 0, sent: 0, connections: 0)
            entry.ports.insert(port); entry.protocols.insert(proto.hasPrefix("udp") ? "UDP" : "TCP")
            entry.received += received; entry.sent += sent; entry.connections += 1
            destinations[address] = entry
        }
        return destinations.values.sorted { $0.total == $1.total ? $0.address < $1.address : $0.total > $1.total }
    }

    static func isLoopback(_ address: String) -> Bool { address.hasPrefix("127.") || address == "::1" }
}
