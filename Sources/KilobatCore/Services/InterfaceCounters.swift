import Foundation
import Darwin
import CoreWLAN

public struct ByteCount: Sendable, Equatable {
    public var received: UInt64 = 0
    public var sent: UInt64 = 0
    public init(received: UInt64 = 0, sent: UInt64 = 0) { self.received = received; self.sent = sent }
    public var total: UInt64 { received + sent }
    static func + (a: ByteCount, b: ByteCount) -> ByteCount { ByteCount(received: a.received + b.received, sent: a.sent + b.sent) }
    static func += (a: inout ByteCount, b: ByteCount) { a = a + b }
    /// What is left of `a` after taking `b`, never below zero.
    static func - (a: ByteCount, b: ByteCount) -> ByteCount {
        ByteCount(received: a.received > b.received ? a.received - b.received : 0, sent: a.sent > b.sent ? a.sent - b.sent : 0)
    }
    /// Each direction capped at `limit`'s.
    func capped(_ limit: ByteCount) -> ByteCount { ByteCount(received: min(received, limit.received), sent: min(sent, limit.sent)) }
}

/// Bytes each network interface has carried since it came up, from the kernel's 64-bit counters.
/// What Wi-Fi or Ethernet carried is what a carrier bills, whichever process (or none) moved it.
public enum InterfaceCounters {
    /// Every interface's counters; nil when the kernel didn't answer.
    public static func read() -> [String: ByteCount]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        // Interfaces can appear between the two calls.
        length += 4096
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return nil }
        var counters: [String: ByteCount] = [:], offset = 0
        var name = [UInt8](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        buffer.withUnsafeBytes { raw in
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if name.withUnsafeMutableBufferPointer({ $0.withMemoryRebound(to: CChar.self) { if_indextoname(UInt32(message.ifm_index), $0.baseAddress) } }) != nil {
                        counters[String(decoding: name.prefix { $0 != 0 }, as: UTF8.self)] = ByteCount(received: message.ifm_data.ifi_ibytes, sent: message.ifm_data.ifi_obytes)
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return counters
    }

    /// The interfaces whose traffic leaves the Mac for a network in this scope: Wi-Fi and Ethernet (USB tethering
    /// included), not AirDrop's AWDL, loopback, bridges, VPN tunnels or Internet Sharing's access point.
    public static func physical(_ name: String, scope: String, wifi: Set<String>) -> Bool {
        guard name.hasPrefix("en") else { return false }
        switch scope {
        case "wifi": return wifi.contains(name)
        case "wired": return !wifi.contains(name)
        default: return true
        }
    }

    public static func wifiInterfaces() -> Set<String> { Set(CWWiFiClient.shared().interfaceNames() ?? []) }
}

/// Turns interface counters into bytes per sample, starting over rather than guessing when a counter
/// goes backwards, jumps or an interface comes and goes.
public struct InterfaceTally: Sendable {
    private var baseline: [String: ByteCount] = [:]
    /// Over 2.5 GB a second is no real link; it means a counter was reset or replaced.
    static let ceiling: Double = 2_500_000_000

    public init() {}

    public mutating func reset() { baseline = [:] }

    /// Bytes the chosen interfaces carried since the last reading. An interface seen for the first time only sets its baseline.
    public mutating func advance(_ counters: [String: ByteCount], elapsed: TimeInterval, include: (String) -> Bool) -> ByteCount {
        var total = ByteCount(received: 0, sent: 0)
        let limit = UInt64(Self.ceiling * max(1, elapsed))
        for (name, counter) in counters where include(name) {
            defer { baseline[name] = counter }
            guard let old = baseline[name], counter.received >= old.received, counter.sent >= old.sent else { continue }
            let down = counter.received - old.received, up = counter.sent - old.sent
            guard down <= limit, up <= limit else { continue }
            total.received += down; total.sent += up
        }
        baseline = baseline.filter { counters[$0.key] != nil && include($0.key) }
        return total
    }
}
