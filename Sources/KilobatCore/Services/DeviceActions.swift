import Foundation
import Darwin

public enum DeviceActions {
    public static func magicPacket(mac: String) throws -> Data {
        let parts = mac.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { throw DiagnosticError("Enter a six-byte MAC address.") }
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6, parts.allSatisfy({ (1...2).contains($0.count) }) else { throw DiagnosticError("Invalid MAC address.") }
        return Data(Array(repeating: UInt8(255), count: 6) + Array(repeating: bytes, count: 16).flatMap { $0 })
    }
    public static func wake(mac: String) throws {
        let packet = try magicPacket(mac: mac)
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw DiagnosticError("Cannot create Wake-on-LAN socket.") }
        defer { close(descriptor) }
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else { throw DiagnosticError("Cannot enable local broadcast.") }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(9).bigEndian; address.sin_addr.s_addr = INADDR_BROADCAST
        let sent = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { destination in
                packet.withUnsafeBytes { sendto(descriptor, $0.baseAddress, $0.count, 0, destination, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard sent == packet.count else { throw DiagnosticError("Wake packet could not be sent: \(String(cString: strerror(errno)))") }
    }
}
