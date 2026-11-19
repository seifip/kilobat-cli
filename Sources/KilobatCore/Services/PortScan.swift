import Foundation
import Darwin

/// Which common services a device on the local network answers on: one plain TCP connection to each of about thirty
/// well-known ports, closed as soon as it opens, nothing sent. All at once, so the whole check takes about a second.
/// Only for this Mac's own network: a private IPv4 address inside the subnet of one of this Mac's interfaces, or this
/// Mac itself. Never a public address, and never through a VPN to someone else's network.
public enum PortScan {
    public struct Service: Codable, Equatable, Sendable, Identifiable {
        public let port: UInt16
        /// What usually listens there, in plain words.
        public let name: String
        /// A web page a browser can open: `http` or `https`.
        public let web: String?
        public var id: UInt16 { port }
        public init(port: UInt16, name: String, web: String? = nil) { self.port = port; self.name = name; self.web = web }
    }

    /// Home and small-office services people look for: sharing, printing, cameras, remote access, web admin pages.
    public static var common: [Service] {
        [
            Service(port: 21, name: String(localized: "File transfer (FTP)", comment: "Open ports: a service")),
            Service(port: 22, name: String(localized: "Remote login (SSH)", comment: "Open ports: a service")),
            Service(port: 23, name: String(localized: "Old remote login (Telnet)", comment: "Open ports: a service")),
            Service(port: 53, name: String(localized: "DNS", comment: "Open ports: a service")),
            Service(port: 80, name: String(localized: "Web page", comment: "Open ports: a service"), web: "http"),
            Service(port: 139, name: String(localized: "Windows sharing (NetBIOS)", comment: "Open ports: a service")),
            Service(port: 443, name: String(localized: "Secure web page", comment: "Open ports: a service"), web: "https"),
            Service(port: 445, name: String(localized: "File sharing (SMB)", comment: "Open ports: a service")),
            Service(port: 515, name: String(localized: "Printing (LPD)", comment: "Open ports: a service")),
            Service(port: 548, name: String(localized: "Mac file sharing (AFP)", comment: "Open ports: a service")),
            Service(port: 554, name: String(localized: "Camera video (RTSP)", comment: "Open ports: a service")),
            Service(port: 631, name: String(localized: "Printing (IPP)", comment: "Open ports: a service")),
            Service(port: 1400, name: String(localized: "Sonos", comment: "Open ports: a service")),
            Service(port: 1883, name: String(localized: "Smart-home messages (MQTT)", comment: "Open ports: a service")),
            Service(port: 2049, name: String(localized: "File sharing (NFS)", comment: "Open ports: a service")),
            Service(port: 3389, name: String(localized: "Remote desktop (RDP)", comment: "Open ports: a service")),
            Service(port: 5000, name: String(localized: "AirPlay or a web app", comment: "Open ports: a service on port 5000"), web: "http"),
            Service(port: 5001, name: String(localized: "Secure web app", comment: "Open ports: a service on port 5001, such as a NAS"), web: "https"),
            Service(port: 5900, name: String(localized: "Screen sharing (VNC)", comment: "Open ports: a service")),
            Service(port: 7000, name: String(localized: "AirPlay", comment: "Open ports: a service")),
            Service(port: 8000, name: String(localized: "Web page", comment: "Open ports: a service"), web: "http"),
            Service(port: 8008, name: String(localized: "Google Cast", comment: "Open ports: a service")),
            Service(port: 8009, name: String(localized: "Google Cast", comment: "Open ports: a service")),
            Service(port: 8080, name: String(localized: "Web page", comment: "Open ports: a service"), web: "http"),
            Service(port: 8123, name: String(localized: "Home Assistant", comment: "Open ports: a service"), web: "http"),
            Service(port: 8443, name: String(localized: "Secure web page", comment: "Open ports: a service"), web: "https"),
            Service(port: 9100, name: String(localized: "Printing (raw)", comment: "Open ports: a service")),
            Service(port: 32400, name: String(localized: "Plex", comment: "Open ports: a service"), web: "http"),
            Service(port: 62078, name: String(localized: "iPhone or iPad sync", comment: "Open ports: a service")),
        ]
    }
    /// How long a port gets to answer. Local devices answer in milliseconds; a silent port is one that drops the attempt.
    public static let timeout: TimeInterval = 1.2

    public enum State: String, Codable, Sendable { case open, closed, silent, unreachable }

    /// May `address` be checked? Loopback, or a private IPv4 address inside one of `subnets` (this Mac's interfaces,
    /// as LANScan reads them). A public address never; nor a private one on another network, such as a VPN's.
    public static func allowed(_ address: String, subnets: [(address: UInt32, mask: UInt32)]) -> Bool {
        guard let value = ipv4(address) else { return false }
        if value >> 24 == 127 { return true }
        let privateRange = value >> 24 == 10 || value >> 20 == 0xAC1 || value >> 16 == 0xC0A8
        guard privateRange else { return false }
        return subnets.contains { subnet in
            // A /32 or a mask wider than /8 isn't a network a device sits on with this Mac.
            subnet.mask >= 0xFF00_0000 && subnet.mask != 0xFFFF_FFFF && value & subnet.mask == subnet.address & subnet.mask
                && value != subnet.address | ~subnet.mask && value != subnet.address & subnet.mask
        }
    }

    /// Dotted IPv4 only, in host byte order.
    public static func ipv4(_ text: String) -> UInt32? {
        var address = in_addr()
        guard text.split(separator: ".").count == 4, inet_pton(AF_INET, text, &address) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    /// Checks `services` on `address`, refusing anything `allowed` refuses.
    public static func check(_ address: String, subnets: [(address: UInt32, mask: UInt32)], services: [Service] = common,
                             timeout: TimeInterval = timeout, now: Date = Date()) async throws -> PortReport {
        guard allowed(address, subnets: subnets) else {
            throw DiagnosticError(String(localized: "Kilobat only checks devices on this Mac’s own network.", comment: "Open ports: the address isn't on the local network"))
        }
        let ports = services.map(\.port)
        let start = Date()
        let states = await Task.detached(priority: .utility) { probe(address, ports: ports, timeout: timeout) }.value
        return PortReport(address: address, date: now, services: services, states: states, seconds: Date().timeIntervalSince(start))
    }

    /// One non-blocking connection per port, all at once, then one wait for them together. Each socket is closed the
    /// moment it answers. At most 64 ports.
    static func probe(_ address: String, ports: [UInt16], timeout: TimeInterval) -> [UInt16: State] {
        var target = in_addr()
        guard inet_pton(AF_INET, address, &target) == 1 else { return [:] }
        var states: [UInt16: State] = [:]
        var waiting: [(descriptor: Int32, port: UInt16)] = []
        var seen = Set<UInt16>()
        for port in ports.filter({ seen.insert($0).inserted }).prefix(64) {
            let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            guard descriptor >= 0 else { states[port] = .silent; continue }
            var on: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
            var socketAddress = sockaddr_in()
            socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); socketAddress.sin_family = sa_family_t(AF_INET)
            socketAddress.sin_port = port.bigEndian; socketAddress.sin_addr = target
            let result = withUnsafePointer(to: &socketAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if result == 0 { states[port] = .open; close(descriptor); continue }
            if errno == EINPROGRESS { waiting.append((descriptor, port)); continue }
            states[port] = state(errno)
            close(descriptor)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !waiting.isEmpty {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            var polls = waiting.map { pollfd(fd: $0.descriptor, events: Int16(POLLOUT), revents: 0) }
            let ready = poll(&polls, nfds_t(polls.count), Int32(max(1, remaining * 1000)))
            if ready < 0 && errno != EINTR { break }
            guard ready > 0 else { continue }
            var still: [(descriptor: Int32, port: UInt16)] = []
            for (index, entry) in waiting.enumerated() {
                guard polls[index].revents != 0 else { still.append(entry); continue }
                var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(entry.descriptor, SOL_SOCKET, SO_ERROR, &error, &length)
                states[entry.port] = error == 0 ? .open : state(error)
                close(entry.descriptor)
            }
            waiting = still
        }
        for entry in waiting { states[entry.port] = .silent; close(entry.descriptor) }
        return states
    }

    /// Refused is a closed port on a device that's there; no route means this Mac can't reach it at all.
    static func state(_ error: Int32) -> State {
        switch error {
        case ECONNREFUSED, ECONNRESET: .closed
        case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENETDOWN, EPERM, EACCES: .unreachable
        default: .silent
        }
    }
}

/// One device's open ports, as the Devices tab shows them.
public struct PortReport: Codable, Equatable, Sendable {
    public let address: String
    public let date: Date
    /// The services that answered, in port order.
    public let open: [PortScan.Service]
    public let checked: Int
    public let closed: Int
    public let unreachable: Int
    public let seconds: TimeInterval

    public init(address: String, date: Date, services: [PortScan.Service], states: [UInt16: PortScan.State], seconds: TimeInterval) {
        self.address = address; self.date = date; self.seconds = seconds
        open = services.filter { states[$0.port] == .open }.sorted { $0.port < $1.port }
        checked = services.count
        closed = services.filter { states[$0.port] == .closed }.count
        unreachable = services.filter { states[$0.port] == .unreachable }.count
    }

    /// The device refused or dropped every attempt with no route: this Mac couldn't reach it.
    public var unreachableDevice: Bool { open.isEmpty && unreachable == checked && checked > 0 }
    /// Nothing at all came back: asleep, gone, or it ignores connections it doesn't expect.
    public var silentDevice: Bool { open.isEmpty && closed == 0 && !unreachableDevice }

    public var summary: String {
        if unreachableDevice {
            return String(localized: "This Mac couldn’t reach it. If other devices answer, check that Kilobat is allowed in Privacy & Security › Local Network.", comment: "Open ports: no route to the device")
        }
        if silentDevice {
            return String(localized: "Nothing answered. It may be asleep, gone, or ignoring connections.", comment: "Open ports: no reply at all")
        }
        if open.isEmpty {
            return String(localized: "None of the \(checked) common ports are open.", comment: "Open ports: the device answered but nothing is listening; the argument is how many ports were checked")
        }
        return String(localized: "\(open.count) of \(checked) common ports open.", comment: "Open ports: such as '3 of 29 common ports open'")
    }

    /// The address a browser opens for a web service, such as http://192.168.1.20:8080.
    public func url(for service: PortScan.Service) -> URL? {
        guard let scheme = service.web else { return nil }
        let standard = (scheme == "http" && service.port == 80) || (scheme == "https" && service.port == 443)
        return URL(string: "\(scheme)://\(address)" + (standard ? "" : ":\(service.port)"))
    }
}
