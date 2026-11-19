import Foundation
import Darwin
import Testing
@testable import KilobatCore

/// The Devices tab's open-ports check and the wider sweep. Connections go only to a listener this test opens on
/// 127.0.0.1; every other address is only judged, never contacted.
struct PortScanTests {
    private let home: [(address: UInt32, mask: UInt32)] = [(0xC0A8_0117, 0xFFFF_FF00)] // 192.168.1.23/24

    // MARK: Only this Mac's own network

    @Test func onlyAddressesOnThisMacsNetwork() {
        #expect(PortScan.allowed("192.168.1.20", subnets: home))
        #expect(PortScan.allowed("127.0.0.1", subnets: []))
        // Another private network, such as one reached through a VPN.
        #expect(!PortScan.allowed("192.168.2.20", subnets: home))
        #expect(!PortScan.allowed("10.8.0.1", subnets: home))
        // The network's own address and its broadcast aren't devices.
        #expect(!PortScan.allowed("192.168.1.0", subnets: home) && !PortScan.allowed("192.168.1.255", subnets: home))
    }
    @Test func neverAPublicAddress() {
        #expect(!PortScan.allowed("8.8.8.8", subnets: home))
        // Even if an interface claims a public network, or a mask that covers everything.
        #expect(!PortScan.allowed("8.8.8.8", subnets: [(0x0808_0800, 0xFFFF_FF00)]))
        #expect(!PortScan.allowed("100.64.0.5", subnets: [(0x6440_0001, 0xFFC0_0000)]))
        #expect(!PortScan.allowed("10.1.2.3", subnets: [(0x0A00_0001, 0)]))
    }
    @Test func onlyPlainIPv4() {
        for text in ["", "not-an-address", "1.2.3", "192.168.1.20:80", "::1", "fe80::1", "-1.2.3.4", "192.168.1.020x"] {
            #expect(!PortScan.allowed(text, subnets: home), "\(text)")
        }
        #expect(PortScan.ipv4("192.168.1.20") == 0xC0A8_0114)
    }
    @Test func refusingAPublicAddressSendsNothing() async {
        await #expect(throws: DiagnosticError.self) { try await PortScan.check("1.1.1.1", subnets: home) }
    }

    // MARK: Against a local listener

    /// A TCP listener on 127.0.0.1 and a port nothing listens on, both picked by the system.
    private final class Listener {
        let descriptor: Int32, port: UInt16
        init?() {
            descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            guard descriptor >= 0, let port = Self.bind(descriptor), listen(descriptor, 8) == 0 else { return nil }
            self.port = port
        }
        deinit { close(descriptor) }
        static func bind(_ descriptor: Int32) -> UInt16? {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard bound == 0 else { return nil }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
            return UInt16(bigEndian: address.sin_port)
        }
        /// A port that was free a moment ago and has nothing listening.
        static func closedPort() -> UInt16? {
            let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            defer { close(descriptor) }
            return bind(descriptor)
        }
    }

    @Test func findsTheOpenPortAndTheClosedOne() async throws {
        let listener = try #require(Listener())
        let closed = try #require(Listener.closedPort())
        let services = [PortScan.Service(port: listener.port, name: "Test service", web: "http"), PortScan.Service(port: closed, name: "Nothing")]
        let report = try await PortScan.check("127.0.0.1", subnets: [], services: services, timeout: 2)
        #expect(report.open.map(\.port) == [listener.port])
        #expect(report.closed == 1 && report.checked == 2 && !report.silentDevice && !report.unreachableDevice)
        #expect(report.seconds < 2)
        #expect(report.url(for: report.open[0])?.absoluteString == "http://127.0.0.1:\(listener.port)")
        #expect(report.summary == "1 of 2 common ports open.")
    }
    @Test func aRepeatedPortIsCheckedOnce() throws {
        let listener = try #require(Listener())
        let states = PortScan.probe("127.0.0.1", ports: [listener.port, listener.port], timeout: 2)
        #expect(states == [listener.port: .open])
    }

    // MARK: What a report says

    @Test func errorsMeanClosedUnreachableOrSilent() {
        #expect(PortScan.state(ECONNREFUSED) == .closed)
        #expect(PortScan.state(EHOSTUNREACH) == .unreachable && PortScan.state(ENETUNREACH) == .unreachable)
        #expect(PortScan.state(ETIMEDOUT) == .silent)
    }
    @Test func theSummaryTellsSilenceFromNoRoute() {
        let services = Array(PortScan.common.prefix(3))
        func report(_ state: PortScan.State) -> PortReport {
            PortReport(address: "192.168.1.20", date: Date(), services: services, states: Dictionary(uniqueKeysWithValues: services.map { ($0.port, state) }), seconds: 1)
        }
        #expect(report(.silent).silentDevice && report(.silent).summary.hasPrefix("Nothing answered"))
        #expect(report(.unreachable).unreachableDevice && report(.unreachable).summary.contains("Local Network"))
        #expect(report(.closed).summary == "None of the 3 common ports are open.")
    }
    @Test func webPagesOpenAtTheirAddress() {
        let report = PortReport(address: "192.168.1.20", date: Date(), services: [], states: [:], seconds: 0)
        #expect(report.url(for: PortScan.Service(port: 80, name: "", web: "http"))?.absoluteString == "http://192.168.1.20")
        #expect(report.url(for: PortScan.Service(port: 443, name: "", web: "https"))?.absoluteString == "https://192.168.1.20")
        #expect(report.url(for: PortScan.Service(port: 8443, name: "", web: "https"))?.absoluteString == "https://192.168.1.20:8443")
        #expect(report.url(for: PortScan.Service(port: 22, name: "")) == nil)
    }
    @Test func theCommonListIsShortAndNamed() {
        let ports = PortScan.common.map(\.port)
        #expect(Set(ports).count == ports.count && ports.count <= 64)
        #expect(ports.contains(445) && ports.contains(631) && ports.contains(22) && PortScan.common.allSatisfy { !$0.name.isEmpty })
    }

    // MARK: Sweeps beyond a /24

    @Test func aWideNetworkIsSweptUpToASlash22() {
        let address: UInt32 = 0x0A00_0505 // 10.0.5.5 on a /16
        #expect(LANScan.hosts(address: address, mask: 0xFFFF_0000).count == 253)
        let wide = LANScan.hosts(address: address, mask: 0xFFFF_0000, widest: 22)
        #expect(wide.count == 1021 && wide.first == "10.0.4.1" && wide.last == "10.0.7.254" && !wide.contains("10.0.5.5"))
        // Asking for more than the cap still gets the cap.
        #expect(LANScan.hosts(address: address, mask: 0xFFFF_0000, widest: 16).count == 1021)
        // A network smaller than the cap is swept whole, and never past its own edge.
        #expect(LANScan.hosts(address: 0xC0A8_0117, mask: 0xFFFF_FE00, widest: 22).count == 509)
        #expect(LANScan.hosts(address: 0xC0A8_0117, mask: 0xFFFF_FF00, widest: 22).count == 253)
        #expect(LANScan.hosts(address: 0x0808_0808, mask: 0xFFFF_0000, widest: 22).isEmpty)
    }
    @Test func theWholeSweepIsOfferedWithItsTime() throws {
        let capped = try #require(LANScan.sweepSize(address: 0x0A00_0505, mask: 0xFFFF_0000))
        #expect(capped.nearby == 253 && capped.whole == 1021 && capped.prefix == 22 && capped.capped)
        #expect(capped.seconds == 6)
        let slash23 = try #require(LANScan.sweepSize(address: 0xC0A8_0117, mask: 0xFFFF_FE00))
        #expect(slash23.whole == 509 && slash23.prefix == 23 && !slash23.capped)
        // Nothing to choose on a /24 or a public network.
        #expect(LANScan.sweepSize(address: 0xC0A8_0117, mask: 0xFFFF_FF00) == nil)
        #expect(LANScan.sweepSize(address: 0x0808_0808, mask: 0xFFFF_0000) == nil)
    }
}
