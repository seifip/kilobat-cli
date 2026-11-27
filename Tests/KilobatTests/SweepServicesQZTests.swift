import Foundation
import Testing
@testable import KilobatCore

/// Hostile or broken answers from devices on the network, and the services that read them.
struct SweepServicesQZTests {
    private func fixed32(_ number: Int, _ value: Float) -> [UInt8] {
        ProtoWriter.varint(UInt64(number) << 3 | 5) + withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) }
    }
    private func packed(_ values: [Float]) -> [UInt8] {
        values.flatMap { value in withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) } }
    }

    // MARK: Starlink

    @Test func aSkyMapTooLargeToBeRealIsRefused() throws {
        let huge = try #require(ProtoMessage(ProtoWriter.field(2008, message: ProtoWriter.field(1, varint: .max) + ProtoWriter.field(2, varint: 1))))
        #expect(StarlinkSkyMap(response: huge) == nil)
        let overflowing = try #require(ProtoMessage(ProtoWriter.field(2008, message: ProtoWriter.field(1, varint: 1 << 32) + ProtoWriter.field(2, varint: 1 << 32))))
        #expect(StarlinkSkyMap(response: overflowing) == nil)
        let small = try #require(ProtoMessage(ProtoWriter.field(2008, message: ProtoWriter.field(1, varint: 2) + ProtoWriter.field(2, varint: 2)
                                                                     + ProtoWriter.field(3, message: packed([1, 0, -1, 1])))))
        #expect(StarlinkSkyMap(response: small)?.snr == [1, 0, -1, 1])
    }

    @Test func historySamplesThatArentRatesReadAsNothing() throws {
        let body = ProtoWriter.field(1, varint: 4) + ProtoWriter.field(1003, message: packed([.nan, -1, .infinity, 5e6]))
            + ProtoWriter.field(1001, message: packed([.nan, 0, 0, 0])) + ProtoWriter.field(1002, message: packed([.infinity, .nan, 20, 30]))
        let response = try #require(ProtoMessage(ProtoWriter.field(2006, message: body)))
        let history = try #require(StarlinkHistory(response: response))
        #expect(history.downlinkBps == [0, 0, 0, 5e6])
        #expect(history.bytes.down.isFinite && history.bytes.down == 5e6 / 8)
        #expect(history.dropRate == [0, 0, 0, 0])
        #expect(history.latencyMs == [nil, nil, 20, 30])
    }

    @Test func statusNumbersThatArentRealReadAsNothing() throws {
        let stats = fixed32(1, .nan) + fixed32(4, .infinity) + fixed32(6, .infinity) + fixed32(7, 3.4e38)
        let body = ProtoWriter.field(1004, message: stats) + fixed32(1009, .nan) + fixed32(1007, -5) + fixed32(1011, .infinity)
        let response = try #require(ProtoMessage(ProtoWriter.field(2004, message: body)))
        let status = try #require(StarlinkStatus(response: response))
        #expect(status.obstructionValidSeconds == nil)
        #expect(status.obstructionDurationSeconds == nil && status.obstructionIntervalSeconds == nil)
        #expect(status.fractionObstructed == 0 && status.popLatencyMs == nil && status.downlinkBps == 0 && status.azimuth == nil)
        // A sane pair still reads.
        let sane = ProtoWriter.field(1004, message: fixed32(4, 600) + fixed32(6, 2.5) + fixed32(7, 300))
        let saneResponse = try #require(ProtoMessage(ProtoWriter.field(2004, message: sane)))
        let ok = try #require(StarlinkStatus(response: saneResponse))
        #expect(ok.obstructionValidSeconds == 600 && ok.obstructionDurationSeconds == 2.5 && ok.obstructionIntervalSeconds == 300)
    }

    // MARK: Rule inspector

    @Test func theFiltersDottedIPv6EndpointSplits() {
        #expect(RuleInspector.endpoint("2001:db8::1.443") == ("2001:db8::1", "443"))
        #expect(RuleInspector.endpoint("fe80::1%en0.443").host == "fe80::1%en0")
        #expect(RuleInspector.endpoint("::ffff:1.2.3.4") == ("::ffff:1.2.3.4", nil))
        #expect(RuleInspector.endpoint("[2001:db8::1]:443") == ("2001:db8::1", "443"))
        #expect(RuleInspector.endpoint("203.0.113.7:443") == ("203.0.113.7", "443"))
    }

    // MARK: Routers

    private var loopback: RouterSession { RouterSession(pin: nil, loopback: true) }

    @Test func aFritzBoxWithANegativeHostCountListsNoClients() async throws {
        let server = try FakeRouter { request in
            if request.path == "/tr64desc.xml" { return .init(200, RouterFixtures.tr64desc) }
            return .init(200, RouterFixtures.soap("GetHostNumberOfEntries", "urn:dslforum-org:service:Hosts:1", [("NewHostNumberOfEntries", "-1")]))
        }
        await server.start(); defer { server.stop() }
        let box = FritzBox(base: server.base, user: "kilobat", password: "secret", transport: loopback)
        #expect(try await box.readGenericHosts().isEmpty)
    }

    @Test func uptimesAndNumbersThatArentRealReadAsNothing() {
        #expect(RouterHTTP.number("nan") == nil && RouterHTTP.number("inf") == nil && RouterHTTP.number(NSNumber(value: Double.infinity)) == nil)
        #expect(RouterHTTP.number("42") == 42 && RouterHTTP.number(NSNumber(value: 7)) == 7)
        #expect(RouterHTTP.uptime(1e300) == nil && RouterHTTP.uptime(-1) == nil && RouterHTTP.uptime(nil) == nil)
        #expect(RouterHTTP.uptime(86_400) == 86_400)
    }

    @Test func aUniFiUptimeOfNaNPollsWithNoUptime() async throws {
        let devices = #"{"meta":{"rc":"ok"},"data":[{"type":"udm","model":"UDR7","version":"4.3.9","uptime":"nan"}]}"#
        let server = try FakeRouter { request in
            guard request.headers["x-api-key"] == "key-123" else { return .init(401, "{}") }
            switch request.path {
            case "/proxy/network/integration/v1/sites": return .init(200, RouterFixtures.unifiSites)
            case "/proxy/network/integration/v1/sites/88f7af54-98f8-306a-a1c7-c9349722b1f6/clients?offset=0&limit=200": return .init(200, RouterFixtures.unifiClients)
            case "/proxy/network/api/s/default/stat/sta": return .init(200, RouterFixtures.unifiStations)
            case "/proxy/network/api/s/default/stat/device": return .init(200, devices)
            default: return .init(404, "{}")
            }
        }
        await server.start(); defer { server.stop() }
        let poll = try await UniFiConsole(base: server.base, auth: .apiKey("key-123"), transport: loopback).poll()
        #expect(poll.uptime == nil && poll.model == "UDR7")
    }

    @Test(.timeLimit(.minutes(1))) func aDescriptionWithALongRunOfSpacesIsReadQuickly() throws {
        let hostile = Data(("<root><URLBase>" + String(repeating: " ", count: 20_000) + "</device><modelName>" + String(repeating: " ", count: 20_000) + "</root>").utf8)
        let base = try #require(URL(string: "http://192.168.1.1:5000/rootDesc.xml"))
        #expect(RouterCounters.controlURL(description: hostile, base: base) == nil)
        #expect(RouterCounters.modelName(description: hostile) == nil)
        let named = Data("<root><device><friendlyName>Home router</friendlyName><modelName> RT-AX88U </modelName></device></root>".utf8)
        #expect(RouterCounters.modelName(description: named) == "RT-AX88U")
        let plain = Data("""
        <root><URLBase> http://192.168.1.1:49152/ </URLBase><device><friendlyName>Home &amp; Office</friendlyName>
        <serviceList><service><serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType><controlURL>/ctl/CmnIfCfg</controlURL></service></serviceList></device></root>
        """.utf8)
        #expect(RouterCounters.controlURL(description: plain, base: base) == "http://192.168.1.1:49152/ctl/CmnIfCfg")
        #expect(RouterCounters.modelName(description: plain) == "Home & Office")
    }

    // MARK: Service status, traffic

    @Test func anAppleStatusFileWithItsBracesBackwardsThrows() throws {
        let icloud = try #require(ServiceCatalog.services.first { $0.id == "icloud" })
        #expect(throws: (any Error).self) { try ServiceStatusParser.parse(Data("}{".utf8), for: icloud) }
        #expect(throws: (any Error).self) { try ServiceStatusParser.parse(Data("} callback({".utf8), for: icloud) }
    }

    @Test func aProcessNamedWithAnArrowIsNotAConnection() {
        #expect(TrafficRoute.classify("PC<->Mac Bridge.123", interface: "en0") == .internet)
        #expect(TrafficRoute.classify("tcp4 192.168.1.20:5000<->17.1.2.3:443", interface: "en0") == .internet)
        #expect(TrafficRoute.classify("tcp4 192.168.1.20:5000<->192.168.1.30:443", interface: "en0") == .local)
    }

    // MARK: Stream overlay

    @Test func theOverlaySaysWhenItsPortIsTaken() throws {
        let holder = socket(AF_INET, SOCK_STREAM, 0)
        try #require(holder >= 0)
        defer { close(holder) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(holder, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try #require(bound == 0 && listen(holder, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(holder, $0, &length) } }
        let port = UInt16(bigEndian: address.sin_port)
        let overlay = StreamOverlay(port: port)
        #expect(throws: (any Error).self) { try overlay.start() }
    }
}

/// The filter's prompt queue, when an answer lands while a connection is on its way to it.
struct SweepServicesQZApprovalTests {
    private func approval(_ host: String, site: String? = "example.com", app: String = "com.example.app") -> PendingApproval {
        PendingApproval(app: app, process: "app", path: nil, signer: nil, signatureValid: true, pid: 1, uid: 501,
                        destinations: [.init(host: host, address: nil, port: "443")], site: site)
    }

    @Test func aConnectionArrivingAfterTheAnswerIsNotHeld() throws {
        let queue = ApprovalQueue<Int>()
        queue.resume = { _, _ in }
        #expect(queue.hold(1, approval: approval("x.example.com", site: nil)))
        #expect(queue.decide("com.example.app", allowed: true, uid: 501))
        #expect(!queue.hold(2, approval: approval("x.example.com", site: nil)))
        #expect(try JSONDecoder().decode([PendingApproval].self, from: queue.encoded(for: 501)).isEmpty)
        // The second pass still holds when told to, as before.
        #expect(queue.hold(3, approval: approval("x.example.com", site: nil), unlessAnswered: false))
    }

    @Test func aSiteAnsweredForTheDomainIsNotAskedAgain() throws {
        let queue = ApprovalQueue<Int>()
        queue.resume = { _, _ in }
        #expect(queue.hold(1, approval: approval("api.example.com")))
        let shown = try JSONDecoder().decode([PendingApproval].self, from: queue.encoded(for: 501))[0]
        #expect(queue.answer(ApprovalAnswer(shown, allowed: true, scope: .domain), uid: 501))
        #expect(!queue.hold(2, approval: approval("cdn.example.com")))
        #expect(try JSONDecoder().decode([PendingApproval].self, from: queue.encoded(for: 501)).isEmpty)
    }

    @Test func anAppNeverAnsweredIsStillHeld() {
        let queue = ApprovalQueue<Int>()
        queue.resume = { _, _ in }
        #expect(queue.hold(1, approval: approval("x.example.com", site: nil, app: "com.other.app")))
        #expect(queue.hold(2, approval: approval("x.example.com", site: nil, app: "com.other.app")))
    }
}
