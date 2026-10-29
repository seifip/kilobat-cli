import Foundation
import Darwin

/// One process's bytes since the last sample, split by where they went.
public struct ProcessFlow: Equatable, Sendable {
    public var total = ByteCount()
    public var local = ByteCount()
    /// The local bytes that crossed Wi-Fi or Ethernet, which those interfaces' counters include too.
    public var physicalLocal = ByteCount()
    public var tunnel = ByteCount()
    /// Bytes that went to the Internet over Wi-Fi or Ethernet: neither local nor inside a tunnel.
    public var internet: ByteCount { total - local - tunnel }
}

/// A process as last sampled, kept a little while after it drops out of nettop's rows.
struct SeenProcess {
    var traffic: ProcessTraffic
    var started: Date?
    var at: Date
}

enum TrafficAttribution {
    /// Over 2.5 GB a second from one process is no real transfer; its counters were replaced.
    static let ceiling: Double = 2_500_000_000

    /// Bytes since `previous`. A process seen for the first time only sets its baseline, so lifetime traffic
    /// from before monitoring is never imported, unless it started after the last sample: then everything it
    /// moved is new. A reused pid (another start time or name) is a new process; a counter that went backwards
    /// or jumped starts over. Nil means baseline only.
    static func flow(_ process: ProcessTraffic, started: Date?, previous: SeenProcess?, lastSample: Date, elapsed: TimeInterval,
                     physical: (String) -> Bool) -> ProcessFlow? {
        // A process that has since exited has no start time; one with a start time where the last sample had none is new.
        let same = previous.map { $0.traffic.process == process.process && (started == nil || $0.started == started) } ?? false
        let old: [String: ConnectionTraffic]
        var flow = ProcessFlow()
        if same, let previous {
            let before = previous.traffic
            flow.total = ByteCount(received: process.received >= before.received ? process.received - before.received : 0,
                                   sent: process.sent >= before.sent ? process.sent - before.sent : 0)
            let limit = UInt64(ceiling * max(1, elapsed))
            guard flow.total.received <= limit, flow.total.sent <= limit else { return ProcessFlow() }
            old = merged(before.connections)
        } else if let started, started > lastSample {
            flow.total = ByteCount(received: process.received, sent: process.sent)
            old = [:]
        } else { return nil }
        for (id, connection) in merged(process.connections) where connection.route != .internet {
            // A new socket, or a new one on the same endpoints, moved everything it shows.
            let before = old[id].flatMap { connection.received >= $0.received && connection.sent >= $0.sent ? $0 : nil }
            let bytes = ByteCount(received: connection.received - (before?.received ?? 0), sent: connection.sent - (before?.sent ?? 0))
            if connection.route == .tunnel { flow.tunnel += bytes; continue }
            flow.local += bytes
            if physical(connection.interface) { flow.physicalLocal += bytes }
        }
        // The process row is the authority: sockets that closed between samples only show there.
        flow.local = flow.local.capped(flow.total)
        flow.physicalLocal = flow.physicalLocal.capped(flow.local)
        flow.tunnel = flow.tunnel.capped(flow.total - flow.local)
        return flow
    }

    /// Two sockets can show the same endpoints, such as unconnected UDP; their bytes add up.
    static func merged(_ connections: [ConnectionTraffic]) -> [String: ConnectionTraffic] {
        var merged: [String: ConnectionTraffic] = [:]
        for connection in connections {
            if let other = merged[connection.id] {
                merged[connection.id] = ConnectionTraffic(id: connection.id, route: connection.route, interface: connection.interface,
                                                          received: other.received + connection.received, sent: other.sent + connection.sent)
            } else { merged[connection.id] = connection }
        }
        return merged
    }

    /// When the process started; nil once it has exited. sysctl answers for other users' processes too, where proc_pidinfo doesn't.
    static func startTime(_ pid: Int32) -> Date? {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard pid > 0, sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }
}
