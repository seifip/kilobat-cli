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

/// One process's open connections, and the UDP bytes on sockets that name no remote: a socket that sends to
/// servers without connecting to one shows as `*:*`, so where those bytes went can't be told.
public struct ProcessConnections: Sendable, Equatable {
    public var destinations: [OpenDestination] = []
    public var unlabelledUDP: UInt64 = 0
}

public enum OpenConnections {
    public static func sample(pids: Set<Int32>) async -> [OpenDestination] {
        merge(await sampleByProcess(pids: pids).values.map(\.destinations))
    }

    public static func sampleByProcess(pids: Set<Int32>) async -> [Int32: ProcessConnections] {
        guard !pids.isEmpty else { return [:] }
        return await Task.detached(priority: .utility) {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
            process.arguments = ["-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"]
            process.standardOutput = output; process.standardError = Pipe(); process.standardInput = Pipe()
            guard (try? process.run()) != nil else { return [:] }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return parseByProcess(String(decoding: data, as: UTF8.self), pids: pids)
        }.value
    }

    static func parse(_ text: String, pids: Set<Int32>) -> [OpenDestination] {
        merge(parseByProcess(text, pids: pids).values.map(\.destinations))
    }

    /// Process rows (`name.pid,in,out,`) are followed by their connection rows (`tcp4 local<->remote,in,out,`).
    static func parseByProcess(_ text: String, pids: Set<Int32>) -> [Int32: ProcessConnections] {
        var current: Int32?, found: [Int32: [String: OpenDestination]] = [:], unlabelled: [Int32: UInt64] = [:]
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
            let received = UInt64(columns[1]) ?? 0, sent = UInt64(columns[2]) ?? 0
            if address == "*" || port == "*" || port.isEmpty {
                if proto.hasPrefix("udp") { unlabelled[pid, default: 0] += received + sent }
                continue
            }
            guard !isLoopback(address) else { continue }
            var entry = found[pid]?[address] ?? OpenDestination(address: address, ports: [], protocols: [], received: 0, sent: 0, connections: 0)
            entry.ports.insert(port); entry.protocols.insert(proto.hasPrefix("udp") ? "UDP" : "TCP")
            entry.received += received; entry.sent += sent; entry.connections += 1
            found[pid, default: [:]][address] = entry
        }
        var result: [Int32: ProcessConnections] = [:]
        for pid in Set(found.keys).union(unlabelled.keys) {
            result[pid] = ProcessConnections(destinations: sorted(found[pid].map { Array($0.values) } ?? []), unlabelledUDP: unlabelled[pid] ?? 0)
        }
        return result
    }

    static func merge(_ lists: [[OpenDestination]]) -> [OpenDestination] {
        var merged: [String: OpenDestination] = [:]
        for entry in lists.joined() {
            guard var existing = merged[entry.address] else { merged[entry.address] = entry; continue }
            existing.ports.formUnion(entry.ports); existing.protocols.formUnion(entry.protocols)
            existing.received += entry.received; existing.sent += entry.sent; existing.connections += entry.connections
            merged[entry.address] = existing
        }
        return sorted(Array(merged.values))
    }

    static func sorted(_ destinations: [OpenDestination]) -> [OpenDestination] {
        destinations.sorted { $0.total == $1.total ? $0.address < $1.address : $0.total > $1.total }
    }

    static func isLoopback(_ address: String) -> Bool { address.hasPrefix("127.") || address == "::1" }
}
