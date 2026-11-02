import Foundation
import Testing
@testable import KilobatCore

/// Connect your router: digest authentication, the local-address rule, each protocol's parsing from recorded answers,
/// the HTTP flows against a local fake server, counters into rates and daily totals, the merge with the Devices tab,
/// the call cause, router uptime as restarts, the Keychain (in memory) and the CLI. No real router is asked.
@Suite(.serialized) struct RouterIntegrationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var loopback: RouterSession { RouterSession(pin: nil, loopback: true) }

    // MARK: Digest, addresses, certificates

    @Test func digestMatchesRFC2617AndCountsRequests() throws {
        // RFC 2617 §3.5's example.
        #expect(DigestChallenge.response(user: "Mufasa", password: "Circle Of Life", realm: "testrealm@host.com", nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093",
                                         method: "GET", uri: "/dir/index.html", qop: "auth", nc: "00000001", cnonce: "0a4f113b") == "6629fae49393a05397450978507c4ef1")
        var challenge = try #require(DigestChallenge(header: #"Digest realm="HTTPS Access", nonce="A1B2,C3", algorithm=MD5, qop="auth,auth-int", opaque="xyz""#))
        #expect(challenge.realm == "HTTPS Access" && challenge.nonce == "A1B2,C3" && challenge.qop == "auth" && challenge.opaque == "xyz")
        let first = challenge.authorization(user: "kilobat", password: "pw", method: "POST", uri: "/upnp/control/hosts", cnonce: "c0ffee")
        let second = challenge.authorization(user: "kilobat", password: "pw", method: "POST", uri: "/upnp/control/hosts", cnonce: "c0ffee")
        #expect(first.hasPrefix("Digest ") && first.contains(#"username="kilobat""#) && first.contains("nc=00000001") && second.contains("nc=00000002"))
        let expected = DigestChallenge.response(user: "kilobat", password: "pw", realm: "HTTPS Access", nonce: "A1B2,C3", method: "POST", uri: "/upnp/control/hosts",
                                                qop: "auth", nc: "00000001", cnonce: "c0ffee")
        #expect(DigestChallenge.parameters(String(first.dropFirst(7)))["response"] == expected)
        #expect(DigestChallenge(header: #"Basic realm="x""#) == nil)
        #expect(DigestChallenge(header: #"Digest realm="x""#) == nil)
    }

    @Test func onlyLocalAddressesGetCredentials() throws {
        for local in ["192.168.178.1", "10.0.0.1", "172.16.0.1", "172.31.255.254", "169.254.1.1"] { #expect(RouterAddress.isLocal(local)) }
        for other in ["8.8.8.8", "172.32.0.1", "100.64.0.1", "127.0.0.1", "192.169.0.1", "fritz.box", "::1"] { #expect(!RouterAddress.isLocal(other)) }
        #expect(RouterAddress.isLocal("127.0.0.1", loopback: true))
        #expect(try RouterAddress.resolve("192.168.178.1:49000").absoluteString == "http://192.168.178.1:49000")
        #expect(try RouterAddress.resolve("https://10.0.0.1/some/path?x=1").absoluteString == "https://10.0.0.1")
        #expect(throws: RouterAPIError.notLocal) { try RouterAddress.resolve("http://8.8.8.8") }
        #expect(throws: RouterAPIError.notLocal) { try RouterAddress.resolve("http://admin:pw@192.168.1.1") }
        #expect(throws: RouterAPIError.notLocal) { try RouterAddress.resolve("ftp://192.168.1.1") }
        #expect(throws: RouterAPIError.notLocal) { try RouterAddress.resolve("http://127.0.0.1:8080") }
        #expect(CertificatePin.display("a1b2c3") == "A1:B2:C3")
        #expect(CertificatePin.fingerprint(Data("x".utf8)).count == 64)
    }

    @Test func transportRefusesPublicAddressesBeforeSending() async {
        let session = RouterSession(pin: nil)
        await #expect(throws: RouterAPIError.notLocal) { _ = try await session.send(URLRequest(url: URL(string: "http://93.184.216.34/")!)) }
        await #expect(throws: RouterAPIError.notLocal) { _ = try await session.send(URLRequest(url: URL(string: "http://127.0.0.1:9/")!)) }
    }

    // MARK: FRITZ!Box TR-064

    @Test func tr064ParsesAnswersFaultsServicesAndTheHostList() throws {
        let info = TR064.parse(Data(RouterFixtures.getInfo.utf8))
        #expect(info.fault == nil && info.values["NewUpTime"] == "86400" && info.values["NewModelName"] == "FRITZ!Box 7590")
        #expect(TR064.parse(Data(RouterFixtures.notAuthorized.utf8)).fault == 606)
        let services = TR064.services(Data(RouterFixtures.tr64desc.utf8))
        #expect(services[FritzBox.hosts] == "/upnp/control/hosts" && services[FritzBox.wan] == "/upnp/control/wancommonifconfig1")
        // The documented example's mismatched closing tag doesn't lose the list.
        let hosts = TR064.hosts(Data(RouterFixtures.hostList.utf8))
        #expect(hosts.map(\.mac) == ["00:00:5e:00:53:31", "00:00:5e:00:53:44", "00:00:5e:00:53:20"])
        #expect(hosts[0].name == "Sams-MacBook-Air" && hosts[1].name == "Ritas-iPad" && hosts[2].name == "Bedroom & TV")
        #expect(hosts.map(\.active) == [true, true, false] && hosts[2].address == "192.0.2.20")
        // TR-064 has no per-device counters.
        #expect(hosts.allSatisfy { $0.down == nil && $0.downRate == nil })
        let monitor = TR064.monitorRates(TR064.parse(Data(RouterFixtures.onlineMonitor.utf8)).values)
        #expect(monitor.down == 3_200_000 && monitor.up == 210_000)
        let link = TR064.utilization(TR064.parse(Data(RouterFixtures.linkProperties.utf8)).values)
        #expect(link.down == 1_500_000 && link.up == 60_000)
    }

    /// A FRITZ!Box: 401 with a digest challenge, then answers once the response hash is right.
    static func fakeFritz(password: String = "secret", limited: Bool = false) throws -> FakeRouter {
        try FakeRouter { request in
            if request.path == "/tr64desc.xml" { return .init(200, RouterFixtures.tr64desc) }
            let action = request.headers["soapaction"].flatMap { $0.split(separator: "#").last }.map { String($0.dropLast()) } ?? ""
            if action == "GetSecurityPort" { return .init(200, RouterFixtures.securityPort) }
            let nonce = "F758BE72FB999CEA"
            guard let header = request.headers["authorization"], header.hasPrefix("Digest ") else {
                return .init(401, "", headers: ["WWW-Authenticate": #"Digest realm="HTTPS Access", nonce="\#(nonce)", algorithm=MD5, qop="auth""#])
            }
            let params = DigestChallenge.parameters(String(header.dropFirst(7)))
            let expected = DigestChallenge.response(user: params["username"] ?? "", password: password, realm: "HTTPS Access", nonce: nonce, method: request.method,
                                                    uri: params["uri"] ?? "", qop: params["qop"], nc: params["nc"] ?? "", cnonce: params["cnonce"] ?? "")
            guard params["username"] == "kilobat", params["uri"] == request.path, params["response"] == expected else {
                return .init(401, "", headers: ["WWW-Authenticate": #"Digest realm="HTTPS Access", nonce="\#(nonce)", algorithm=MD5, qop="auth""#])
            }
            if request.path.hasPrefix("/devicehostlist.lua") { return .init(200, RouterFixtures.hostList) }
            if limited, ["GetInfo", "X_AVM-DE_GetHostListPath", "GetTotalBytesReceived", "GetTotalBytesSent", "X_AVM-DE_GetOnlineMonitor"].contains(action) {
                return .init(500, RouterFixtures.notAuthorized)
            }
            if request.headers["soapaction"]?.contains("UserInterface:1#GetInfo") == true { return .init(200, RouterFixtures.userInterface) }
            switch action {
            case "GetInfo": return .init(200, RouterFixtures.getInfo)
            case "X_AVM-DE_GetHostListPath": return .init(200, RouterFixtures.hostListPath)
            case "GetTotalBytesReceived": return .init(200, RouterFixtures.totalReceived)
            case "GetTotalBytesSent": return .init(200, RouterFixtures.totalSent)
            case "X_AVM-DE_GetOnlineMonitor": return .init(200, RouterFixtures.onlineMonitor)
            case "GetCommonLinkProperties": return .init(200, RouterFixtures.linkProperties)
            case "GetHostNumberOfEntries": return .init(200, RouterFixtures.hostCount)
            case "GetGenericHostEntry":
                let index = Int(request.text.components(separatedBy: "<NewIndex>").last?.prefix { $0.isNumber } ?? "0") ?? 0
                return .init(200, RouterFixtures.genericHost(index))
            default: return .init(500, RouterFixtures.notAuthorized)
            }
        }
    }

    @Test func fritzBoxSignsInWithDigestAndReadsHostsLineAndUptime() async throws {
        let server = try Self.fakeFritz(); await server.start(); defer { server.stop() }
        let box = FritzBox(base: server.base, user: "kilobat", password: "secret", transport: loopback)
        #expect(try await box.securityPort() == 49443)
        let poll = try await box.poll()
        #expect(poll.model == "FRITZ!Box 7590" && poll.firmware == "154.08.00" && poll.uptime == 86400)
        #expect(poll.clients.count == 3 && !poll.perDevice && poll.missing.isEmpty)
        #expect(poll.wan == RouterWAN(down: 4_294_967_000, up: 123_456_789, downRate: 3_200_000, upRate: 210_000, bits: 32))
        // The first SOAP request goes without credentials and gets the challenge (URLSession itself may try it once more
        // unsigned); every request after the first signed one carries the digest from the start.
        let soap = server.requests.filter { $0.method == "POST" && $0.headers["soapaction"]?.contains("GetSecurityPort") == false }
        let unsigned = soap.prefix { $0.headers["authorization"] == nil }
        #expect((1...2).contains(unsigned.count) && unsigned.allSatisfy { $0.headers["soapaction"]?.contains("#GetInfo") == true })
        #expect(soap.dropFirst(unsigned.count).allSatisfy { $0.headers["authorization"]?.hasPrefix("Digest ") == true } && soap.count == unsigned.count + 6)
        #expect(!server.requests.contains { $0.text.contains("secret") || ($0.headers["authorization"] ?? "").contains("secret") })
        // The box's own firmware check, read and never acted on.
        #expect(poll.update == RouterFirmware(product: "FRITZ!OS", installed: "8.00", available: "8.10", updateAvailable: true, url: "http://127.0.0.1"))
        #expect(poll.update?.line == "FRITZ!OS 8.10 is available; you’re on 8.00.")
        let actions = server.requests.compactMap { $0.headers["soapaction"] }
        #expect(!actions.contains { action in ["DoUpdate", "CheckUpdate", "DoManualUpdate", "Reboot"].contains { action.contains($0) } })
        await #expect(throws: RouterAPIError.self) { _ = try await box.call("urn:dslforum-org:service:UserInterface:1", "X_AVM-DE_DoUpdate") }
        await #expect(throws: RouterAPIError.self) { _ = try await box.call("urn:dslforum-org:service:DeviceConfig:1", "Reboot") }
    }

    @Test func firmwareVersionsAndOpenWrtsReleaseList() throws {
        #expect(RouterFirmware.fritzVersion("154.08.10") == "8.10" && RouterFirmware.fritzVersion("7.16.1") == "7.16.1" && RouterFirmware.fritzVersion("") == nil)
        #expect(RouterFirmware.isNewer("7.16.2", than: "7.16.1") && RouterFirmware.isNewer("7.17", than: "7.16.1") && !RouterFirmware.isNewer("7.16", than: "7.16.0"))
        #expect(!RouterFirmware.isNewer("7.16.1 (stable)", than: "7.16.1") && !RouterFirmware.isNewer("beta", than: "7.16"))
        let releases = try #require(OpenWrtReleases.parse(Data(RouterFixtures.owVersions.utf8)))
        #expect(releases.stable == "25.12.6" && releases.oldstable == "24.10.8")
        // A newer point release in the same series first; the next series only once this one is no longer supported.
        #expect(releases.newer(than: "24.10.0") == "24.10.8" && releases.newer(than: "24.10.8") == nil)
        #expect(releases.newer(than: "25.12.5") == "25.12.6" && releases.newer(than: "25.12.6") == nil)
        #expect(releases.newer(than: "23.05.5") == "25.12.6")
        #expect(releases.newer(than: "SNAPSHOT") == nil && releases.newer(than: "24.10.0-rc1") == nil)
        let quiet = RouterFirmware(product: "RouterOS", installed: "7.16.1", available: nil, updateAvailable: false, url: nil)
        #expect(quiet.line == nil)
        #expect(RouterOSREST.update(["installed-version": "7.16.1", "latest-version": "7.16.2"], base: URL(string: "https://192.0.2.1")!)?.available == "7.16.2")
        #expect(RouterOSREST.update(["installed-version": "7.16.1", "latest-version": "7.16.1"], base: URL(string: "https://192.0.2.1")!)?.updateAvailable == false)
        // Before anyone ran Check For Updates, RouterOS has no latest version: no reminder, no guess.
        #expect(RouterOSREST.update(["installed-version": "7.16.1", "latest-version": ""], base: URL(string: "https://192.0.2.1")!)?.updateAvailable == false)
    }

    @Test func firmwareReminderForRoutersKilobatCanOnlyName() {
        var record = RouterRecord(network: "home", mac: "00:00:5e:00:53:01", name: "Home", lastSeen: now)
        record.since = now
        #expect(!record.firmwareDue(now: now.addingTimeInterval(200 * 86_400)))
        record.maker = "AVM Audiovisuelles Marketing und Computersysteme GmbH"
        #expect(!record.firmwareDue(now: now.addingTimeInterval(89 * 86_400)) && record.firmwareDue(now: now.addingTimeInterval(91 * 86_400)))
        let report = RouterReport(record, now: now.addingTimeInterval(91 * 86_400))
        #expect(report.firmware?.guide == "https://kilobat.app/routers/fritzbox#firmware" && report.firmware?.line.isEmpty == false)
        record.firmwareChecked = now.addingTimeInterval(80 * 86_400)
        #expect(!record.firmwareDue(now: now.addingTimeInterval(100 * 86_400)))
        #expect(RouterGuides.slug(maker: "Ubiquiti Inc") == "ubiquiti-unifi" && RouterGuides.slug(maker: "MikroTik") == "mikrotik" && RouterGuides.firmware(maker: "OpenWrt") == nil)
        #expect(RouterGuides.slug(maker: "NETGEAR Inc") == nil && RouterGuides.slug(maker: "TP-Link") == nil)
    }

    @Test @MainActor func routerWatchLearnsTheMakerAndWhenFirmwareWasChecked() throws {
        let watch = RouterWatch(directory: nil)
        watch.vendor = { _ in "MikroTik" }
        let snapshot = DiagnosticSnapshot(date: now, radio: RadioSample(bssid: "00:00:5e:00:53:a1", ssid: "Home", interface: "en0", rssi: -55, noise: -92, transmitMbps: 866, channel: 36, band: "5 GHz"),
                                          gateway: "192.0.2.1", router: PingResult(host: "192.0.2.1", samples: [3, 3, 3, 3], lossPercent: 0),
                                          internet: PingResult(host: "1.1.1.1", samples: [20], lossPercent: 0), dnsMilliseconds: 15, dnsServers: ["192.0.2.1"],
                                          captivePortal: false, networkService: "Wi-Fi")
        watch.ingest(snapshot, mac: "00:00:5e:00:53:01", busy: false, interval: 60, date: now)
        let network = try #require(watch.records.first?.network)
        #expect(watch.records.first?.maker == "MikroTik" && watch.records.first?.since == now)
        watch.firmwareChecked(network: network, at: now.addingTimeInterval(10))
        #expect(watch.records.first?.firmwareChecked == now.addingTimeInterval(10))
    }

    @Test func fritzBoxUserWithFewRightsStillListsDevicesAndTheLineRate() async throws {
        let server = try Self.fakeFritz(limited: true); await server.start(); defer { server.stop() }
        let poll = try await FritzBox(base: server.base, user: "kilobat", password: "secret", transport: loopback).poll()
        #expect(poll.missing == ["rights"] && poll.uptime == nil && poll.wan?.down == nil)
        #expect(poll.clients.map(\.name) == ["Sams-MacBook-Air", "Ritas-iPad"] && poll.clients.map(\.active) == [true, false])
        #expect(poll.wan?.downRate == 1_500_000 && poll.wan?.upRate == 60_000)
    }

    @Test func fritzBoxWrongPasswordIsUnauthorized() async throws {
        let server = try Self.fakeFritz(password: "other"); await server.start(); defer { server.stop() }
        await #expect(throws: RouterAPIError.unauthorized) { _ = try await FritzBox(base: server.base, user: "kilobat", password: "secret", transport: loopback).poll() }
    }

    // MARK: UniFi

    @Test func unifiStationsReadTrafficFromTheClientsSide() throws {
        let rows = try #require((try JSONSerialization.jsonObject(with: Data(RouterFixtures.unifiStations.utf8)) as? [String: Any])?["data"] as? [[String: Any]])
        let ipad = try #require(UniFiConsole.station(rows[0])), tv = try #require(UniFiConsole.station(rows[1]))
        // tx is what the access point sent the client: its download.
        #expect(ipad.down == 5_368_709_120 && ipad.up == 104_857_600 && ipad.downRate == 3_900_000.5 && ipad.name == "Ritas-iPad")
        #expect(tv.down == 2_147_483_648 && tv.up == 52_428_800 && tv.downRate == 800_000 && tv.name == "tv")
    }

    static func fakeUniFi(legacy: Bool = true, account: Bool = false) throws -> FakeRouter {
        try FakeRouter { request in
            if account {
                if request.path == "/api/auth/login" {
                    return request.text.contains(#""password":"pw""#) ? .init(200, "{}", headers: ["Set-Cookie": "TOKEN=abc123; path=/; HttpOnly", "X-Updated-CSRF-Token": "csrf1"]) : .init(401, "{}")
                }
                guard request.headers["cookie"] == "TOKEN=abc123", request.headers["x-csrf-token"] == "csrf1" else { return .init(401, RouterFixtures.unifiLoginRequired) }
            } else if request.headers["x-api-key"] != "key-123" { return .init(401, #"{"statusCode":401,"statusName":"UNAUTHORIZED"}"#) }
            switch request.path {
            case "/proxy/network/integration/v1/sites": return .init(200, RouterFixtures.unifiSites)
            case "/proxy/network/integration/v1/sites/88f7af54-98f8-306a-a1c7-c9349722b1f6/clients?offset=0&limit=200": return .init(200, RouterFixtures.unifiClients)
            case "/proxy/network/api/s/default/stat/sta": return legacy ? .init(200, RouterFixtures.unifiStations) : .init(401, RouterFixtures.unifiLoginRequired)
            case "/proxy/network/api/s/default/stat/device": return legacy ? .init(200, RouterFixtures.unifiDevices) : .init(401, RouterFixtures.unifiLoginRequired)
            default: return .init(404, "{}")
            }
        }
    }

    @Test func unifiWithAnAPIKeyMergesTheOfficialListWithStatistics() async throws {
        let server = try Self.fakeUniFi(); await server.start(); defer { server.stop() }
        let console = UniFiConsole(base: server.base, auth: .apiKey("key-123"), transport: loopback)
        let poll = try await console.poll()
        #expect(poll.perDevice && poll.missing.isEmpty && poll.uptime == 259_200 && poll.model == "UDR7")
        let ipad = try #require(poll.clients.first { $0.mac == "00:00:5e:00:53:44" })
        // The official API's name wins over the host name.
        #expect(ipad.name == "Rita’s iPad" && ipad.downRate == 3_900_000.5)
        #expect(poll.update?.installed == "4.3.9" && poll.update?.available == "4.4.6" && poll.update?.updateAvailable == true)
        #expect(poll.wan?.downRate == 4_800_000 && poll.wan?.down == 9_000_000_000)
    }

    @Test func unifiWithoutTheOlderAPISaysWholeHomeOnly() async throws {
        let server = try Self.fakeUniFi(legacy: false); await server.start(); defer { server.stop() }
        let poll = try await UniFiConsole(base: server.base, auth: .apiKey("key-123"), transport: loopback).poll()
        #expect(!poll.perDevice && poll.missing == ["legacyAPI"] && poll.clients.count == 2 && poll.clients.allSatisfy { !$0.counted })
        await #expect(throws: RouterAPIError.unauthorized) { _ = try await UniFiConsole(base: server.base, auth: .apiKey("wrong"), transport: loopback).poll() }
    }

    @Test func unifiLocalAccountSignsInWithACookie() async throws {
        let server = try Self.fakeUniFi(account: true); await server.start(); defer { server.stop() }
        let poll = try await UniFiConsole(base: server.base, auth: .account(user: "kilobat", password: "pw"), transport: loopback).poll()
        #expect(poll.perDevice && poll.clients.count == 2)
        await #expect(throws: RouterAPIError.unauthorized) { _ = try await UniFiConsole(base: server.base, auth: .account(user: "kilobat", password: "no"), transport: loopback).poll() }
    }

    // MARK: MikroTik

    @Test func routerOSDurationsAndByteCounts() {
        // 1 week 2 days 3:04:05, and 5 days 3:04:05.
        #expect(RouterOSREST.uptime("1w2d3h4m5s") == TimeInterval(788_645))
        #expect(RouterOSREST.uptime("5d03:04:05") == TimeInterval(443_045))
        #expect(RouterOSREST.uptime("45s") == 45 && RouterOSREST.uptime("0s") == 0)
        #expect(RouterOSREST.uptime("") == nil && RouterOSREST.uptime("soon") == nil)
        #expect(RouterOSREST.bytes("12345") == 12345 && RouterOSREST.bytes("2048.0MiB") == 2_147_483_648 && RouterOSREST.bytes("3.5KiB") == 3584)
        #expect(RouterOSREST.bytes("lots") == nil)
        #expect(RouterMeter.delta(from: UInt64.max, to: 10, bits: 32) == 10)
        for invalid in ["-1MiB", "NaNKiB", "infTiB", "999999999999999999TiB"] { #expect(RouterOSREST.bytes(invalid) == nil) }
    }

    static func fakeRouterOS(kids: Bool = true, queues: String = RouterFixtures.rosQueues) throws -> FakeRouter {
        try FakeRouter { request in
            guard request.headers["authorization"] == RouterHTTP.basic("kilobat", "pw") else { return .init(401, #"{"error":401,"message":"Unauthorized"}"#) }
            switch request.path {
            case "/rest/system/resource": return .init(200, RouterFixtures.rosResource)
            case "/rest/ip/dhcp-server/lease": return .init(200, RouterFixtures.rosLeases)
            case "/rest/ip/kid-control/device": return .init(200, kids ? RouterFixtures.rosKids : "[]")
            case "/rest/queue/simple": return .init(200, queues)
            case "/rest/interface/list/member": return .init(200, RouterFixtures.rosListMembers)
            case "/rest/interface": return .init(200, RouterFixtures.rosInterfaces)
            case "/rest/system/package/update": return request.method == "GET" ? .init(200, RouterFixtures.rosPackageUpdate) : .init(400, "")
            default: return .init(404, #"{"error":404,"message":"Not Found"}"#)
            }
        }
    }

    @Test func routerOSCountsDevicesFromKidControlOrSimpleQueues() async throws {
        let server = try Self.fakeRouterOS(); await server.start(); defer { server.stop() }
        let poll = try await RouterOSREST(base: server.base, user: "kilobat", password: "pw", transport: loopback).poll()
        #expect(poll.perDevice && poll.missing.isEmpty && poll.model == "hAP ax^3" && poll.firmware == "7.16.1 (stable)")
        #expect(poll.uptime == TimeInterval(788_645))
        let tv = try #require(poll.clients.first { $0.mac == "00:00:5e:00:53:20" })
        #expect(tv.name == "Bedroom TV" && tv.down == 2_147_483_648 && tv.up == 52_428_800)
        #expect(poll.clients.first { $0.mac == "00:00:5e:00:53:61" }?.active == false)
        #expect(poll.wan == RouterWAN(down: 90_000_000_000, up: 8_000_000_000))
        #expect(poll.update?.line == "RouterOS 7.16.2 is available; you’re on 7.16.1.")
        // Read only: never check-for-updates, download or install.
        #expect(server.requests.allSatisfy { $0.method == "GET" })

        let queues = try Self.fakeRouterOS(kids: false); await queues.start(); defer { queues.stop() }
        let fromQueues = try await RouterOSREST(base: queues.base, user: "kilobat", password: "pw", transport: loopback).poll()
        #expect(fromQueues.perDevice && fromQueues.missing == ["kidControl", "queues"])
        // A queue's bytes are upload/download from its target's side; the /24 queue names no one device.
        #expect(fromQueues.clients.first { $0.mac == "00:00:5e:00:53:20" }?.down == 2_147_483_648)
        #expect(fromQueues.clients.first { $0.mac == "00:00:5e:00:53:44" }?.down == nil)
        await #expect(throws: RouterAPIError.unauthorized) { _ = try await RouterOSREST(base: server.base, user: "kilobat", password: "no", transport: loopback).poll() }
    }

    @Test func routerOSNeverAttributesAMultiTargetQueueToOneDevice() async throws {
        let response = #"[{"target":"192.0.2.20/32,192.0.2.44/32","bytes":"100/200","disabled":"false"}]"#
        let server = try Self.fakeRouterOS(kids: false, queues: response); await server.start(); defer { server.stop() }
        let poll = try await RouterOSREST(base: server.base, user: "kilobat", password: "pw", transport: loopback).poll()
        #expect(!poll.perDevice && poll.clients.allSatisfy { $0.down == nil && $0.up == nil })
    }

    // MARK: OpenWrt

    @Test func nlbwmonTablesByMAC() throws {
        let table = try #require(OpenWrtUbus.nlbw(Data(RouterFixtures.owNlbw.utf8)))
        #expect(table.count == 2 && table["00:00:5e:00:53:44"]?.down == 5_368_709_120 && table["00:00:5e:00:53:44"]?.up == 104_857_600)
        #expect(OpenWrtUbus.nlbw(Data("{}".utf8)) == nil)
    }

    static func fakeOpenWrt(nlbw: Bool = true, expireOnce: Bool = false) throws -> FakeRouter {
        let expired = Expiry(expireOnce)
        return try FakeRouter { request in
            guard request.path == "/ubus", let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let id = body["id"], let params = body["params"] as? [Any], params.count == 4,
                  let session = params[0] as? String, let object = params[1] as? String, let method = params[2] as? String else { return .init(400, "") }
            let args = params[3] as? [String: Any] ?? [:]
            if object == "session", method == "login" {
                return .init(200, args["password"] as? String == "pw" ? RouterFixtures.ubus(id, 0, RouterFixtures.owLogin) : RouterFixtures.ubus(id, 6))
            }
            guard session == "c1ed6c7b025d0caca723a816fa61b668" else { return .init(200, #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32002,"message":"Access denied"}}"#) }
            if expired.take() { return .init(200, #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32002,"message":"Access denied"}}"#) }
            switch (object, method) {
            case ("luci-rpc", "getHostHints"): return .init(200, RouterFixtures.ubus(id, 0, RouterFixtures.owHints))
            case ("system", "info"): return .init(200, RouterFixtures.ubus(id, 0, RouterFixtures.owInfo))
            case ("system", "board"): return .init(200, RouterFixtures.ubus(id, 0, RouterFixtures.owBoard))
            case ("network.interface.wan", "status"): return .init(200, RouterFixtures.ubus(id, 0, RouterFixtures.owWAN))
            case ("network.device", "status"): return .init(200, RouterFixtures.ubus(id, 0, args["name"] as? String == "eth1" ? RouterFixtures.owDevice : "{}"))
            case ("file", "exec"):
                guard nlbw, args["command"] as? String == "/usr/libexec/nlbwmon-action", (args["params"] as? [String]) == ["download", "-g", "mac"] else { return .init(200, RouterFixtures.ubus(id, 6)) }
                let stdout = String(data: try! JSONSerialization.data(withJSONObject: [RouterFixtures.owNlbw]), encoding: .utf8)!.dropFirst().dropLast()
                return .init(200, RouterFixtures.ubus(id, 0, "{\"code\":0,\"stdout\":\(stdout)}"))
            default: return .init(200, RouterFixtures.ubus(id, 3))
            }
        }
    }
    final class Expiry: @unchecked Sendable {
        private var left: Bool; private let lock = NSLock()
        init(_ once: Bool) { left = once }
        func take() -> Bool { lock.withLock { defer { left = false }; return left } }
    }

    @Test func openWrtReadsHintsUptimeTheLineAndNlbwmon() async throws {
        let server = try Self.fakeOpenWrt(expireOnce: true); await server.start(); defer { server.stop() }
        let poll = try await OpenWrtUbus(base: server.base, user: "root", password: "pw", transport: loopback).poll()
        #expect(poll.perDevice && poll.missing.isEmpty && poll.uptime == 432_000 && poll.model == "GL.iNet GL-MT6000" && poll.firmware == "OpenWrt 24.10.0")
        #expect(poll.clients.first { $0.mac == "00:00:5e:00:53:44" }?.down == 5_368_709_120)
        #expect(poll.clients.first { $0.mac == "00:00:5e:00:53:61" }?.active == false)
        #expect(poll.wan == RouterWAN(down: 70_000_000_000, up: 6_000_000_000))
        // An expired session signs in again once.
        #expect(server.requests.filter { $0.text.contains(#""login""#) }.count == 2)

        let plain = try Self.fakeOpenWrt(nlbw: false); await plain.start(); defer { plain.stop() }
        let whole = try await OpenWrtUbus(base: plain.base, user: "root", password: "pw", transport: loopback).poll()
        #expect(!whole.perDevice && whole.missing == ["nlbwmon"] && whole.clients.allSatisfy { $0.down == nil })
        await #expect(throws: RouterAPIError.unauthorized) { _ = try await OpenWrtUbus(base: server.base, user: "root", password: "no", transport: loopback).poll() }
    }

    // MARK: Counters, daily totals, merge

    @Test func meterTurnsCountersIntoRatesThroughResetsAndWraps() {
        #expect(RouterMeter.delta(from: 100, to: 250) == 150)
        // A counter that went back started again: what it shows now is new traffic.
        #expect(RouterMeter.delta(from: 9_000_000, to: 1_000) == 1_000)
        // A 32-bit counter near its top wrapped.
        #expect(RouterMeter.delta(from: 4_294_967_000, to: 704, bits: 32) == 1_000)
        var meter = RouterMeter()
        let first = meter.step("a", down: 1_000, up: 100, at: now)
        #expect(first == nil)
        let step = meter.step("a", down: 11_000, up: 600, at: now.addingTimeInterval(10))
        #expect(step?.down == 10_000 && step?.up == 500 && step?.downRate == 1_000 && step?.upRate == 50)
        // Too long a gap, or a jump no line carries, isn't trusted.
        let gap = meter.step("a", down: 12_000, up: 700, at: now.addingTimeInterval(7210))
        let jump = meter.step("a", down: 100_000_012_000, up: 700, at: now.addingTimeInterval(7220))
        #expect(gap == nil && jump == nil)
    }

    @Test func ledgerKeepsTodaysTotalsPerDeviceFor30Days() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        var ledger = HomeUsageLedger()
        ledger.add("00:00:5e:00:53:44", down: 1_000, up: 10, at: now, calendar: calendar)
        ledger.add("00:00:5e:00:53:44", down: 500, up: 5, at: now.addingTimeInterval(60), calendar: calendar)
        ledger.add(HomeUsageLedger.home, down: 9_000, up: 90, at: now, calendar: calendar)
        ledger.add("old", down: 1, up: 1, at: now.addingTimeInterval(-31 * 86_400), calendar: calendar)
        ledger.add("zero", down: 0, up: 0, at: now, calendar: calendar)
        #expect(ledger.today(now: now, calendar: calendar)["00:00:5e:00:53:44"] == .init(down: 1_500, up: 15))
        #expect(ledger.total(HomeUsageLedger.home, on: now, calendar: calendar)?.bytes == 9_090)
        #expect(ledger.today(now: now, calendar: calendar)["zero"] == nil)
        ledger.prune(now: now, calendar: calendar)
        #expect(ledger.days.count == 1 && HomeUsageLedger.day(now, calendar: calendar) == "2027-01-15")
        // The day after, today is empty again.
        #expect(ledger.today(now: now.addingTimeInterval(86_400), calendar: calendar).isEmpty)
    }

    private func network() -> DeviceNetwork {
        var book = DeviceBook()
        book.setHome(true, network: "home", name: "Home")
        book.observe([DeviceSighting(mac: "00:00:5e:00:53:44", address: "192.0.2.44", hostname: "Ritas-iPad.local."),
                      DeviceSighting(mac: "00:00:5e:00:53:20", address: "192.0.2.20")], network: "home", name: "Home", vendor: { _ in "Samsung" }, now: now)
        book.rename(mac: "00:00:5e:00:53:20", to: "Bedroom TV", network: "home")
        return book.networks["home"]!
    }

    @Test func mergeKeysOnMACAndPrefersThePersonsNames() {
        let clients = [RouterClient(mac: "00:00:5E:00:53:20", address: "192.0.2.20", name: "tv"),
                       RouterClient(mac: "00:00:5e:00:53:44", address: "192.0.2.44", name: "iPad"),
                       RouterClient(mac: "00:00:5e:00:53:31", address: "192.0.2.31", name: "Sams-MacBook-Air"),
                       RouterClient(mac: "00:00:5e:00:53:77", address: "192.0.2.77", name: "printer-hall"),
                       RouterClient(mac: "00:00:5e:00:53:88", address: "192.0.2.88", active: false),
                       RouterClient(mac: "ff:ff:ff:ff:ff:ff")]
        let peer = HouseholdLive(summary: HouseholdSummary(id: "a1", name: "Sam’s MacBook", down: 3_900_000, up: 41_000, apps: ["Steam"], call: false, at: now), received: now, address: "192.0.2.31")
        let rates = ["00:00:5e:00:53:20": HomeUsageMerge.Rate(down: 800_000, up: 12_000), "00:00:5e:00:53:31": .init(down: 3_800_000, up: 40_000)]
        let rows = HomeUsageMerge.devices(clients: clients, rates: rates, today: ["00:00:5e:00:53:20": .init(down: 2_000_000, up: 50_000)], known: network(),
                                          peers: [peer], thisMac: .init(mac: nil, address: "192.0.2.77", down: 10, up: 5), perDevice: true, now: now)
        // Busiest first; offline devices with nothing today and broadcast addresses left out.
        #expect(rows.map(\.mac) == ["00:00:5e:00:53:31", "00:00:5e:00:53:20", "00:00:5e:00:53:77", "00:00:5e:00:53:44"])
        #expect(rows[0].name == "Sam’s MacBook" && rows[0].pairedMac && rows[0].apps == ["Steam"] && rows[0].source == "router")
        #expect(rows[1].name == "Bedroom TV" && rows[1].todayDown == 2_000_000 && rows[1].down == 800_000)
        // This Mac, which the router hasn't counted yet, shows its own numbers.
        #expect(rows[2].thisMac && rows[2].name == "printer-hall" && rows[2].source == "thisMac" && rows[2].down == 10)
        #expect(rows[3].name == "Ritas-iPad")

        // A router that counts only the line: paired Macs and this Mac report themselves, the rest is "others".
        let whole = HomeUsageMerge.devices(clients: clients, rates: rates, today: [:], known: network(), peers: [peer],
                                           thisMac: .init(mac: nil, address: "192.0.2.77", down: 100_000, up: 5_000), perDevice: false, now: now)
        #expect(whole.first { $0.pairedMac }?.source == "pairedMac" && whole.first { $0.thisMac }?.source == "thisMac")
        #expect(whole.filter { $0.source == nil }.allSatisfy { $0.down == nil && $0.todayDown == nil })
        let others = HomeUsageMerge.others(home: .init(down: 5_000_000, up: 100_000), devices: whole)
        #expect(others?.down == 1_000_000 && others?.up == 54_000)
        // A paired Mac whose report is stale says nothing.
        let stale = HomeUsageMerge.devices(clients: clients, rates: [:], today: [:], known: nil, peers: [peer], thisMac: nil, perDevice: false, now: now.addingTimeInterval(60))
        #expect(!stale.contains { $0.pairedMac })
    }

    // MARK: The store: Keychain (in memory), files, home only, Pro

    @MainActor private func store(_ folder: URL, secrets: RouterSecretStore, home: Bool = true, pro: Bool = true) -> HomeUsageStore {
        let store = HomeUsageStore(directory: folder, secrets: secrets)
        store.loopback = true
        store.transport = { RouterSession(pin: $0, loopback: true) }
        store.allowed = { pro }
        store.network = { HouseholdNetwork(key: "home", name: "Home", home: home) }
        return store
    }

    @Test @MainActor func connectingKeepsTheSecretInTheKeychainOnly() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-router-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try Self.fakeRouterOS(); await server.start(); defer { server.stop() }
        let secrets = MemoryRouterSecrets()
        let usage = store(folder, secrets: secrets)
        var uptimes: [TimeInterval] = []
        usage.onUptime = { _, uptime, _ in uptimes.append(uptime) }
        let outcome = await usage.connect(RouterDraft(kind: .mikrotik, entered: server.base.absoluteString, user: "kilobat", secret: "pw"))
        #expect(outcome == .connected)
        let connection = try #require(usage.connection(for: "home"))
        #expect(secrets.secret(for: connection.id) == "pw" && connection.model == "hAP ax^3" && connection.user == "kilobat")
        let file = try String(contentsOf: folder.appendingPathComponent(HomeUsageStore.bookFile), encoding: .utf8)
        #expect(file.contains("hAP ax^3") && !file.contains("\"pw\""))
        #expect(uptimes.count == 1)
        let report = usage.report()
        #expect(report.state == .ok && report.router?.measures == "perDevice" && report.devices.count == 2)
        // A second read gives rates and today's totals.
        let first = try #require(usage.latest?.date)
        usage.ingest(RouterPoll(date: first.addingTimeInterval(10), clients: [RouterClient(mac: "00:00:5e:00:53:44", address: "192.0.2.44", down: 5_368_709_120 + 10_000_000, up: 104_857_600 + 100_000)],
                                perDevice: true), connection: connection)
        let later = usage.report()
        #expect(later.devices.first?.down == 1_000_000 && later.devices.first?.todayDown == 10_000_000)
        #expect(later.home?.down == nil && usage.lineRate() == nil) // LAN-inclusive client counters never become WAN totals.
        // The CLI reads what the app saved without the app.
        #expect(HomeUsageStore.load(directory: folder).book.routers.count == 1)
        usage.disconnect()
        #expect(usage.connection(for: "home") == nil && secrets.secret(for: connection.id) == nil && usage.report().state == .notConnected)
    }

    @Test @MainActor func connectingRefusesAwayFromHomeAndWithAWrongPassword() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-router-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try Self.fakeRouterOS(); await server.start(); defer { server.stop() }
        let secrets = MemoryRouterSecrets()
        let away = store(folder, secrets: secrets, home: false)
        guard case .failed = await away.connect(RouterDraft(kind: .mikrotik, entered: server.base.absoluteString, user: "kilobat", secret: "pw")) else { Issue.record("connected away from home"); return }
        let usage = store(folder, secrets: secrets)
        guard case .failed(let message) = await usage.connect(RouterDraft(kind: .mikrotik, entered: server.base.absoluteString, user: "kilobat", secret: "nope")) else { Issue.record("connected"); return }
        #expect(message == RouterAPIError.unauthorized.errorDescription && secrets.ids().isEmpty && usage.book.routers.isEmpty)
        // Never to a public address, whatever was typed.
        guard case .failed(let away) = await usage.connect(RouterDraft(kind: .mikrotik, entered: "https://203.0.113.9", user: "kilobat", secret: "pw")) else { Issue.record("connected"); return }
        #expect(away == RouterAPIError.notLocal.errorDescription)
    }

    @Test @MainActor func reportSaysProAndHomeAndPrunesOrphanSecrets() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-router-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try Self.fakeOpenWrt(); await server.start(); defer { server.stop() }
        let secrets = MemoryRouterSecrets(["stale-id": "old"])
        let usage = store(folder, secrets: secrets)
        usage.releases = { OpenWrtReleases.parse(Data(RouterFixtures.owVersions.utf8)) }
        var checked: [String] = []
        usage.onFirmware = { network, _ in checked.append(network) }
        #expect(await usage.connect(RouterDraft(kind: .openwrt, entered: server.base.absoluteString, user: "root", secret: "pw")) == .connected)
        // OpenWrt 24.10.0 against OpenWrt's own list: the newer point release in its series, and the router's own flash page.
        #expect(usage.firmware?.available == "24.10.8" && usage.firmware?.source == "openwrt.org" && checked == ["home"])
        #expect(usage.report().router?.update?.url?.hasSuffix("/cgi-bin/luci/admin/system/flash") == true)
        usage.pruneSecrets()
        #expect(secrets.ids().count == 1 && secrets.secret(for: "stale-id") == nil)
        usage.allowed = { false }
        #expect(usage.report().state == .needsPro)
        usage.network = { HouseholdNetwork(key: "home", name: "Home", home: false) }
        #expect(usage.report().state == .notHome && usage.current == nil)
        // The CLI's disconnect without the app.
        #expect(try HomeUsageStore.forget(network: "home", directory: folder)?.kind == .openwrt)
        #expect(HomeUsageStore.load(directory: folder).book.routers.isEmpty)
    }

    private final class FailingSecrets: RouterSecretStore {
        let memory = MemoryRouterSecrets()
        var failWrites = false
        func secret(for id: String) -> String? { memory.secret(for: id) }
        func set(_ secret: String, for id: String) -> Bool { !failWrites && memory.set(secret, for: id) }
        func remove(_ id: String) { memory.remove(id) }
        func ids() -> [String] { memory.ids() }
    }

    @Test @MainActor func proIsRequiredBeforeSendingRouterCredentials() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-router-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try Self.fakeRouterOS(); await server.start(); defer { server.stop() }
        let usage = store(folder, secrets: MemoryRouterSecrets(), pro: false)
        guard case .failed = await usage.connect(RouterDraft(kind: .mikrotik, entered: server.base.absoluteString, user: "kilobat", secret: "pw")) else {
            Issue.record("connected without Pro"); return
        }
        #expect(server.requests.isEmpty && usage.book.routers.isEmpty)
    }

    @Test @MainActor func failedSecretReplacementKeepsTheWorkingConnection() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-router-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try Self.fakeRouterOS(); await server.start(); defer { server.stop() }
        let secrets = FailingSecrets(), usage = store(folder, secrets: secrets)
        let draft = RouterDraft(kind: .mikrotik, entered: server.base.absoluteString, user: "kilobat", secret: "pw")
        #expect(await usage.connect(draft) == .connected)
        let previous = try #require(usage.connection(for: "home"))
        secrets.failWrites = true
        guard case .failed = await usage.connect(draft) else { Issue.record("saved a secret despite failure"); return }
        #expect(usage.connection(for: "home")?.id == previous.id && secrets.secret(for: previous.id) == "pw")
        #expect(HomeUsageStore.load(directory: folder).book.routers.first?.id == previous.id)
    }

    @Test @MainActor func aMissingCredentialStaysVisibleAndStopsBackgroundRetries() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-router-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try Self.fakeRouterOS(); await server.start(); defer { server.stop() }
        let secrets = MemoryRouterSecrets(), usage = store(folder, secrets: secrets)
        #expect(await usage.connect(RouterDraft(kind: .mikrotik, entered: server.base.absoluteString, user: "kilobat", secret: "pw")) == .connected)
        let connection = try #require(usage.connection(for: "home"))
        secrets.remove(connection.id)
        let relaunched = store(folder, secrets: secrets)
        await relaunched.refresh()
        #expect(relaunched.report().state == .needsAttention)
        let count = server.requests.count
        await relaunched.tick(now: Date().addingTimeInterval(1000))
        #expect(relaunched.report().state == .needsAttention && server.requests.count == count)
    }

    @Test @MainActor func failedConnectionFileWriteKeepsThePreviousCredential() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-router-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try Self.fakeRouterOS(); await server.start(); defer { server.stop() }
        let secrets = MemoryRouterSecrets(), usage = store(folder, secrets: secrets)
        let draft = RouterDraft(kind: .mikrotik, entered: server.base.absoluteString, user: "kilobat", secret: "pw")
        #expect(await usage.connect(draft) == .connected)
        let previous = try #require(usage.connection(for: "home"))
        // A directory in place of the connection file makes an atomic file write fail without changing disk permissions.
        let book = folder.appendingPathComponent(HomeUsageStore.bookFile)
        try FileManager.default.removeItem(at: book)
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: false)
        guard case .failed = await usage.connect(draft) else { Issue.record("reported success despite file failure"); return }
        #expect(usage.connection(for: "home")?.id == previous.id && secrets.secret(for: previous.id) == "pw")
        #expect(secrets.ids() == [previous.id] && usage.persistenceError != nil)
    }

    @Test @MainActor func readingsCountersAndDailyTotalsStayOnTheirHomeNetwork() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-router-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try Self.fakeRouterOS(); await server.start(); defer { server.stop() }
        let usage = store(folder, secrets: MemoryRouterSecrets())
        let draft = RouterDraft(kind: .mikrotik, entered: server.base.absoluteString, user: "kilobat", secret: "pw")
        #expect(await usage.connect(draft) == .connected)
        let first = try #require(usage.connection(for: "home"))
        let date = try #require(usage.latest?.date)
        let camera = "00:00:5e:00:53:44"
        func sample(_ date: Date, down: UInt64) -> RouterPoll {
            RouterPoll(date: date, clients: [RouterClient(mac: camera, name: "Sample camera", down: down, up: 100)],
                       wan: RouterWAN(down: down, up: 100), perDevice: true)
        }
        usage.ingest(sample(date.addingTimeInterval(10), down: 6_000_000_000), connection: first)
        #expect(usage.report().devices.first?.todayDown != nil && usage.deviceRates() != nil)
        usage.network = { HouseholdNetwork(key: "second-home", name: "Second home", home: true) }
        #expect(await usage.connect(draft) == .connected)
        let second = try #require(usage.connection(for: "second-home"))
        // First counters on the other router do not become a huge rate or inherit the first home's totals.
        #expect(usage.report().devices.allSatisfy { $0.down == nil && $0.todayDown == nil })
        let secondDate = try #require(usage.latest?.date)
        usage.ingest(sample(secondDate.addingTimeInterval(10), down: 5_368_709_120 + 1000), connection: second)
        #expect(usage.report().devices.first?.todayDown == 1000)
        usage.network = { HouseholdNetwork(key: "home", name: "Home", home: true) }
        let returned = usage.report()
        #expect(returned.state == .connecting && returned.devices.isEmpty && returned.updated == nil)
        #expect(usage.deviceRates() == nil && usage.lineRate() == nil && !usage.fresh)
        usage.network = { HouseholdNetwork(key: "second-home", name: "Second home", home: true) }
        usage.allowed = { false }
        #expect(usage.deviceRates() == nil && usage.lineRate() == nil)
        #expect(usage.report(now: secondDate.addingTimeInterval(1000)).state == .needsPro)
        usage.allowed = { true }
        #expect(usage.report(now: secondDate.addingTimeInterval(1000)).devices.allSatisfy { $0.down == nil && $0.up == nil })
    }

    // MARK: Call causes

    private func call(_ build: (inout CallSamples) -> Void) -> CallReport {
        var samples = CallSamples()
        samples.internet = (0..<900).map { .init(at: Double($0), ms: (600..<604).contains($0) ? nil : 27) }
        samples.router = (0..<900).map { .init(at: Double($0), ms: 3) }
        build(&samples)
        return CallAnalysis.report(app: "Zoom", browser: false, start: now, end: now.addingTimeInterval(900), network: nil, samples: samples)
    }

    @Test func routerCountedDeviceOutranksPairedMacsAndArrivals() throws {
        let card = call { samples in
            samples.household = [.init(at: 598, upload: 30_000, download: 3_800_000)]
            samples.arrivals = [.init(at: 420, name: "a new Samsung device")]
            samples.peers = [.init(at: 601, name: "Sam’s MacBook", upload: 200_000, download: 50_000, app: "Dropbox")]
            samples.routerPerDevice = true
            samples.routerDevices = [.init(at: 596, mac: "00:00:5e:00:53:20", name: "Bedroom TV", upload: 10_000, download: 3_700_000),
                                     .init(at: 596, mac: "00:00:5e:00:53:31", name: "Sam’s MacBook", upload: 200_000, download: 50_000, app: "Dropbox")]
        }
        let cause = try #require(card.freezes.first?.cause)
        #expect(cause.kind == .otherDevice && cause.router == true && cause.device == "Bedroom TV" && cause.uploading == false && cause.kilobat == nil)
        #expect(card.household == true && card.verdict.contains("Bedroom TV"))
        #expect(card.advice?.contains("Your router counted Bedroom TV") == true)
        #expect(cause.phrase == "while Bedroom TV was busy with network traffic")
        #expect(card.advice?.contains("don’t prove internet usage") == true)
    }

    @Test func routerCountedPairedMacKeepsItsApp() throws {
        let card = call { samples in
            samples.routerPerDevice = true
            samples.routerDevices = [.init(at: 605, mac: "00:00:5e:00:53:31", name: "Sam’s MacBook", upload: 40_000, download: 3_900_000, app: "Steam")]
        }
        let cause = try #require(card.freezes.first?.cause)
        #expect(cause.router == true && cause.device == "Sam’s MacBook" && cause.deviceApp == "Steam" && cause.kilobat == true)
        #expect(cause.phrase.contains("Steam") && card.advice?.contains("Steam") == true)
    }

    @Test func quietRouterDevicesFallBackToPairedMacsThenArrivals() throws {
        let peer = call { samples in
            samples.household = [.init(at: 598, upload: 30_000, download: 3_800_000)]
            samples.arrivals = [.init(at: 420, name: "a new Samsung device")]
            samples.peers = [.init(at: 601, name: "Sam’s MacBook", upload: 40_000, download: 3_900_000, app: "Steam")]
            samples.routerPerDevice = true
            samples.routerDevices = [.init(at: 596, mac: "00:00:5e:00:53:20", name: "Bedroom TV", upload: 1_000, download: 9_000)]
        }
        #expect(peer.freezes.first?.cause.device == "Sam’s MacBook" && peer.freezes.first?.cause.router == nil)
        let arrival = call { samples in
            samples.household = [.init(at: 598, upload: 30_000, download: 3_800_000)]
            samples.arrivals = [.init(at: 420, name: "a new Samsung device")]
        }
        #expect(arrival.freezes.first?.cause.device == "a new Samsung device")
        // A busy device far from the freeze isn't it.
        let far = call { samples in
            samples.routerPerDevice = true
            samples.routerDevices = [.init(at: 300, mac: "00:00:5e:00:53:20", name: "Bedroom TV", upload: 1_000, download: 9_000_000)]
        }
        #expect(far.freezes.first?.cause.kind == .beyondRouter && far.household == true)
    }

    // MARK: Router check-up

    @Test func routerUptimeRecordsRestartsItReports() {
        var record = RouterRecord(network: "home", mac: "00:00:5e:00:53:01", name: "Home", lastSeen: now)
        let learned = record.reported(uptime: 86_400, at: now)
        #expect(!learned && record.booted == now.addingTimeInterval(-86_400) && record.restarts.isEmpty)
        // The same boot read again, a second off.
        let same = record.reported(uptime: 86_401 + 600, at: now.addingTimeInterval(600))
        #expect(!same)
        // A seen outage then the router's own word: one restart, now certain.
        record.restarted(at: now.addingTimeInterval(3_000), source: .outage, outageSeconds: 90)
        let confirmed = record.reported(uptime: 30, at: now.addingTimeInterval(3_100))
        #expect(confirmed && record.restarts.count == 1 && record.restarts[0].source == .router)
        // A restart Kilobat never saw, overnight.
        let unseen = record.reported(uptime: 600, at: now.addingTimeInterval(40_000))
        #expect(unseen)
        #expect(record.restarts.count == 2 && record.restarts[1].source == .router && record.restarts[1].date == now.addingTimeInterval(39_400))
        let report = RouterReport(record, now: now.addingTimeInterval(40_060))
        #expect(report.uptimeSeconds == 660 && report.restarts.first?.source == "router")
    }

    // MARK: CLI and detection

    @Test func routerCommandParsing() throws {
        #expect(try RouterCommand.parse(["router"]) == .checkup(RouterReport.Options()))
        var all = RouterReport.Options(); all.all = true; all.json = true
        #expect(try RouterCommand.parse(["router", "--all", "--json"]) == .checkup(all))
        #expect(try RouterCommand.parse(["router", "connect"]) == .connect(kind: nil, json: false))
        #expect(try RouterCommand.parse(["router", "connect", "FRITZBOX", "--json"]) == .connect(kind: .fritzbox, json: true))
        #expect(try RouterCommand.parse(["router", "connect", "fritz!box"]) == .connect(kind: .fritzbox, json: false))
        #expect(try RouterCommand.parse(["router", "devices", "--json"]) == .devices(json: true))
        #expect(try RouterCommand.parse(["router", "disconnect"]) == .disconnect(json: false))
        for bad in [["router", "connect", "netgear"], ["router", "connect", "upnp"], ["router", "devices", "extra"], ["router", "connect", "a", "b"], ["router", "--loud"]] {
            #expect(throws: DiagnosticError.self) { try RouterCommand.parse(bad) }
        }
        // No step ever asks to type a password into the CLI.
        for kind in RouterKind.connectable { #expect(!RouterSetup.steps(kind).isEmpty && !RouterSetup.steps(kind).joined().contains("--password")) }
    }

    @Test func detectionRecognisesEachRouter() async throws {
        #expect(RouterDetect.guess(vendor: "AVM Audiovisuelles Marketing und Computersysteme") == .fritzbox)
        #expect(RouterDetect.guess(vendor: "Ubiquiti Inc") == .unifi && RouterDetect.guess(vendor: "Routerboard.com") == .mikrotik && RouterDetect.guess(vendor: nil) == nil)
        #expect(RouterDetect.recognise(RouterFixtures.tr64desc, port: 49000) == .fritzbox)
        #expect(RouterDetect.recognise("<title>UniFi OS</title>", port: nil) == .unifi)
        #expect(RouterDetect.recognise("<title>RouterOS router configuration page</title>", port: nil) == .mikrotik)
        #expect(RouterDetect.recognise("<meta http-equiv=\"refresh\" content=\"0; URL=cgi-bin/luci/\" />", port: nil) == .openwrt)
        #expect(RouterDetect.recognise("<html>Welcome</html>", port: nil) == nil)
        // Public addresses are never probed.
        #expect(await RouterDetect.detect(gateway: "203.0.113.1", vendor: nil) == nil)
    }
}
